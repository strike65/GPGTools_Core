#!/usr/bin/perl -w

# Known bugs and shortcomings:
#
# hdiutil will sometimes create a floppy disk image (type=3 or type=4) for
# small images; the alias record we create for the background image always
# records the volume's type as 5, and so the background will be blank on
# small images.
#
# It would be convenient if this script also handled applying the EULA.
#

use File::stat;
use File::Spec;
use File::Copy           ();
use File::Basename;
use File::Temp;
use Cwd;
use Carp;
use strict;
use lib dirname(__FILE__) . "/lib";
use Mac::Finder::DSStore qw( writeDSDBEntries makeEntries );
use Mac::Alias::Parse    qw( packAliasRec );
use DiskImage;
use MIME::Base64         qw( );

# This is the difference between the Mac epoch (00:00:00 Jan 1, 1904 UTC) and the
# usual Unix epoch (00:00:00 Jan 1, 1970 UTC). Could probably calculate this
# at runtime using timegm.
# 66 years, 17 of which were leap years.
my($mac_epoch_offset) = ( 66 * 365 + 17 ) * 24 * 60 * 60;
my($mac_tz_offset) = -25200; # insanity!

#
# MacOSX includes a stat()-like syscall named getattrlist. See its manpage
# for more details. This is a pair of functions which call getattrlist and
# setattrlist using perl's syscall function.
#
{
    use constant { SYS_getattrlist => 220,
                   SYS_setattrlist => 221 };

    # Attributes. These must be in the order described in the manpage,
    # because that is the order they are placed in the buffer by the kernel.
    my(@attrs) = (
        # Fld Bit  Name                Inline  Unpacker  OOL
        [  0,  31, 'returned_attrs',     20,   'LLLLL',     0  ],
        [  0,   0, 'name',                8,   '*',      1024  ],
        [  0,   6, 'objpermanentid',      8,   'LL',        0  ],
        [  0,   9, 'crtime',              8,   'LL',        0  ],
        [  0,  10, 'modtime',             8,   'LL',        0  ],
        [  0,  11, 'chgtime',             8,   'LL',        0  ],
        [  0,  12, 'acctime',             8,   'LL',        0  ],
        [  0,  13, 'bkuptime',            8,   'LL',        0  ],
        [  0,  14, 'fndrinfo',           32,   'a4a4nnnn',  0  ],
        [  1,  31, 'vol_info',            0                    ],
        [  1,   0, 'vol_fstype',          4,   'L',         0  ],
        [  1,   1, 'vol_signature',       4,   'L',         0  ],
        [  1,  12, 'vol_mountpoint',      8,   '*',      1024  ],
        [  1,  13, 'vol_name',            8,   '*',        64  ],
    );
    sub syscall_getattrlist {
        my($path, @requested) = @_;
        
        # Is this the BEST THING EVER? Yes, yes it is. Er, wait, I mean
        # the opposite thing. This is terrible.
        
        my($reqattr, $attr, $attrlist, $outbuf, $maxsize, @bits);
        @bits = ( 0, 0, 0, 0, 0 );
        
        $maxsize = 8;
        
        # getattrlist has two disjoint behaviors: one for file/folder
        # information (ala stat) and one for volume information (ala
        # statfs). To retrieve volume info, we request the vol_info
        # attr, which doesn't return any information but enables the
        # other volume attributes.
        unshift(@requested, 'vol_info') if grep { /^vol_/ } @requested;

        # Always request the returned_attrs bitmap so we know what we
        # are parsing.
        unshift(@requested, 'returned_attrs');
        
      FIELD:
        foreach $reqattr (@requested) {
            foreach $attr (@attrs) {
                next unless $attr->[2] eq $reqattr;
                $bits[$attr->[0]] |= ( 1 << $attr->[1] );
                $maxsize += $attr->[3];
                $maxsize += $attr->[5] if @{$attr} >= 5;
                next FIELD;
            }
            croak "Unknown attribute \"$reqattr\"";
        }
        
        $attrlist = pack('SSLLLLL',
                         scalar(@bits), # Bitmap count
                         0,             # Reserved/padding
                         @bits);
        $outbuf = "\x00" x $maxsize;
        
        my($r) = syscall(SYS_getattrlist, $path, $attrlist, $outbuf, $maxsize, 0);
        croak "getattrlist($path): $!\n"
            if $r == -1;

        # Retrieve the buffer size (first field) and the returned_attrs bitmap
        # (next five words).
        my($outbufsize, @retbits) = unpack('LLLLLL', $outbuf);

        # Walk through the rest of the buffer and unpack everything.
        my($cursor, %result, $value);
        $outbuf = substr($outbuf, 0, $outbufsize);
        $cursor = 4;
        foreach $attr (@attrs) {
            if ($retbits[$attr->[0]] & (1 << $attr->[1])) {
                if ($attr->[4] eq '*') {
                    # Out-of-line (variable size) data.
                    my($offset, $length) = unpack('lL', substr($outbuf, $cursor, 8));
                    $value = substr($outbuf, $cursor + $offset, $length);
                    $cursor += 8;
                } else {
                    # Inline, fixed-size data.
                    my($fmt, $size) = @{$attr}[4, 3];
                    $value = [ unpack($fmt, substr($outbuf, $cursor, $size)) ];
                    $value = $value->[0] if @$value == 1;
                    $cursor += $size;
                }
                
                $result{$attr->[2]} = $value;
            }
        }
        
        %result;
    }

    sub syscall_setfinderinfo {
        my($path, $type, $creator, $finderFlags) = @_;
        
        # This is just a special case of setattrlist(). The syscall takes a buffer
        # in the same format as returned by getattrlist, above, except
        # without the initial length word.

        my($bits) = pack('SSLLLLL',
                         5,       # bitmapcount
                         0,       # reserved/padding
                         0x4000,  # ATTR_CMN_FNDRINFO
                         0, 0, 0, 0);
        my($data) = pack('a4a4nnnn n8',
                        $type, $creator,
                        $finderFlags,
                        0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0);
        my($r) = syscall(SYS_setattrlist, $path, $bits, $data, length($data), 0);
        croak "setattrlist($path): $!\n"
            if $r == -1;
    }
}




&main;

sub main {
    my($bgImage, $outfile, %locations, @copyin, %symlinks);
    my($volname, $iconsize, $labelsize, $volicon, $topx, $topy, $width, $height);

    # Default values of some settings
    $iconsize = 128;
    $labelsize = 12;
    $topx = $topy = 100;

    # Parse the command-line arguments
    while (@ARGV) {
        my($opt) = shift @ARGV;
        if ($opt eq '-image') {
            die "Only one bg image can be specified\n" if $bgImage;
            $bgImage = shift @ARGV;
            die "$bgImage does not exist\n" unless -e $bgImage;
        } elsif ($opt eq '-file') {
            my($pos) = shift @ARGV;
            my($file) = shift @ARGV;
            die "source file '$file' does not exist\n" unless -e $file;
            $locations{basename($file)} = &iloc($pos);
            push(@copyin, $file);
        } elsif ($opt eq '-symlink') {
            my($pos) = shift @ARGV;
            my($dest) = shift @ARGV;
            my($res) = basename($dest);
            $locations{$res} = &iloc($pos);
            $symlinks{$res} = $dest;
        } elsif ($opt eq '-volname') {
            $volname = shift @ARGV;
        } elsif ($opt eq '-volicon') {
            $volicon = shift @ARGV;
            die "volume icon image '$volicon' does not exist\n" unless -e $volicon;
            die "volume icon image '$volicon' is not a .icns\n" unless $volicon =~ /\.icns$/i;
        } elsif ($opt eq '-icon-size') {
            $iconsize = shift @ARGV;
        } elsif ($opt eq '-label-size') {
            $labelsize = shift @ARGV;
		} elsif ($opt eq '-window-pos') {
			my($pos) = shift @ARGV;
			($topx, $topy) = @{ &iloc($pos) };
		} elsif ($opt eq '-window-size') {
			my($pos) = shift @ARGV;
			($width, $height) = @{ &iloc($pos) };
        } elsif ($opt !~ /^-/) {
            die "Only one output file can be specified\n" if $outfile;
            $outfile = $opt;
        } else {
            die "Run $0 without arguments for usage.\n";
        }
    }
    
    # Validate, and print usage summary if args are missing/invalid.
    if (!$bgImage || !$outfile || !@copyin) {
        printUsage();
    }
    
    die "Output file '$outfile' already exists!\n"
        if -e $outfile;

	my $tempdir = File::Temp->newdir();
	my $tmpdmg = "$tempdir/tmp.dmg";


    # Invoke hdiutil (via DiskImage) to create a disk image
    # of the right size, copy most of the content in, and
    # mount it somewhere.
    my(@hdiutil_opts) = ( dmg  => $tmpdmg,
                          fs   => 'HFS+' );
    push(@hdiutil_opts,   name => $volname) if $volname;
    push(@hdiutil_opts,   src  => \@copyin);
    our($dmg) = create DiskImage( @hdiutil_opts );

    $dmg->attach;
	$SIG{__DIE__} = \&detach_handler;

    my($mnt) = $dmg->mountpoint;
    
    # Copy the background image in.
    my($imgfile) = $mnt . '/' . basename($bgImage);
    File::Copy::copy($bgImage, $imgfile);

    # And the volume icon.
    if ($volicon) {
		File::Copy::copy($volicon, "$mnt/.VolumeIcon.icns");

        &syscall_setfinderinfo("$mnt/.VolumeIcon.icns",
                               'icns', "\0\0\0\0",
                               0x4000);  # kIsInvisible

        &syscall_setfinderinfo("$mnt/.",
                               "\0\0\0\0", "\0\0\0\0",
                               0x0400);  # kHasCustomIcon
    }

    # Create symlinks as needed.
    foreach my $afile (keys %symlinks) {
        symlink($symlinks{$afile}, "$mnt/$afile") or die "symlink: $!";
    }

    # Compute the DSDB entries we will want to write to the .DS_Store.
    my(@dsdb);

    # Toplevel entries for the initial view.
    push(@dsdb, &windowEntries($mnt, $imgfile, $iconsize, $labelsize, $topx, $topy, $width, $height));

    # Icon location for each file.
    foreach my $afile (keys %locations) {
        push(@dsdb, &makeEntries($afile, Iloc_xy => $locations{$afile}));
    }

    # Write out the .DS_Store file.
    &writeDSDBEntries("$mnt/.DS_Store", @dsdb);
    
    # Detach the image.
	undef $SIG{__DIE__};
    $dmg->detach;
	
	
	# Convert the image.
	$dmg->convert("UDBZ", $outfile);

    print "\n\nDone.\n";
}






sub iloc {
    my($str) = @_;
    unless($str =~ /^(\d+)[, ]+(\d+)$/) {
        die "Bad position spec '$str' (example: '122,15')\n";
    }
    return [ $1, $2 ];
}

sub detach_handler {
	our $dmg;
    $dmg->detach;
}

sub printUsage {
        die <<"ETX";
Usage: $0 [options] outfile.dmg
	-image file.png      Background image to use (mandatory)
	-volname  SomeName   Volume name
	-volicon  file.icns  Volume icon
	-file X,Y somefile   A file to include and where to place it
	-symlink X,Y dest    A symlink to include and where to place it
	-icon-size  pts      Size of file icons
	-label-size pts      Size of filenames
	-window-pos  X,Y     Position of upper-left window corner on screen

At least one -file must be specified. Multiple files and symlinks
may be specified. If only one file is specified, and it is a directory,
its contents will be the toplevel items of the disk image; if several
are specified, the directories themselves will be the toplevel items.
This is inconvenient but it's the way hdiutil behaves.

The background may be a PNG, JPEG, JP2000, or perhaps other formats.
ETX
}


#
# This function computes the DSDB records for the toplevel window
# itself, giving it a background image, putting it in icon-view mode
# with extraneous decorations turned off, and setting the window
# bounds to match the size of the background image.
#
sub windowEntries {
    my($root, $background, $iconsize, $labelsize, $topx, $topy, $width, $height) = @_;
    my($rootstat, $bgstat);
    my($mactype);

    # /usr/bin/sips is an image query tool that ships with OSX
    open(SIPS, "sips -g pixelHeight -g pixelWidth -g format '$background' |") || die;
    while(<SIPS>) {
        if (/\bpixelWidth: (\d+)/) {
            $width = $1 unless defined $width;
        }
        elsif (/\bpixelHeight: (\d+)/) {
            $height = $1 unless defined $height;
        }
        elsif (/\bformat: jpeg\b/) {
            $mactype = 'JPEG';
        }
        elsif (/\bformat: png\b/) {
            $mactype = 'PNGf';
        }
        elsif (/\bformat: gif\b/) {
            $mactype = 'GIFf';
        }
        elsif (/\bformat: jp2\b/) {
            $mactype = 'jp2 ';
        }
    }
    ( close(SIPS) &&
      defined($width) &&
      defined($height) )|| die "Could not query image dimensions, died";
    
    if (defined($mactype)) {
        &syscall_setfinderinfo($background,
                               $mactype,    # File type
                               "\0\0\0\0",      # Creator
                               0x4000);     # kIsInvisible
    }

    my($pictAlias);

    my($pictAliasFields) = &dmgFileAlias($root, $background);

    # For some reason, the background won't show if I include the inode_path
    # array. Not sure if I'm computing the inode path incorrectly or if it's
    # somehow inapplicable here.
    delete $pictAliasFields->{'inode_path'};
    
    $pictAlias = &packAliasRec(%$pictAliasFields);

    return &makeEntries(".",             # DSDB entries for the root
                        vstl => 'icnv',  # open in icon view mode

                        ICVO => 1,
                        icvt => $labelsize,
                        icvo => pack('A4 n A4 A4 n*',
                                     "icv4", $iconsize, "none", "botm",
                                     0, 0, 0, 0, 4, 0),  

                        # Background image
                        BKGD => pack('A4 N nn', 'PctB', length($pictAlias), 0, 0),
                        pict => $pictAlias,

                        # Window dimensions and settings
                        fwvh => $height,
                        fwsw => 20,
                        fwi0_flds => [ $topy, $topx, $topy+$height, $topx+$width, "icnv", 0, 0 ],

                        icgo => "\0\0\0\0\0\0\0\4",
        );
}

#
# This synthesizes an alias record that will resolve to the background image
# inside the disk image, without including a lot of extraneous (and, on
# the receiving system, incorrect) information about the location of the
# disk image file itself.
#
sub dmgFileAlias {
    my($mountpoint, $file) = @_;
    my($mountpointstat, $bgstat, $dstat);
    my(%alis, $result, @ipath, @ppath);

    $file = File::Spec->rel2abs( $file, $mountpoint );
    ( $mountpointstat = stat($mountpoint) )
        or croak "$mountpoint: stat: $!\n";
    ( $bgstat = stat($file) )
        or croak "$file: stat: $!\n";

    die "$file is not on the same filesystem as $mountpoint, died"
        if $mountpointstat->dev != $bgstat->dev;
    
    $file = Cwd::abs_path($file);
    my($fname, $dname) = fileparse($file);
    $dstat = stat($dname);

    # Build up the alias record fields needed by Mac::Alias::Parse::packAliasRec.
    %alis = (
        appinfo => 'Perl',             # Has no effect, may as well have fun
        target => {
            kind => 0,                 # 0=plain file
            inode => $bgstat->ino,     # target inode
            name => $fname,            # short (old-HFS-compatible) name
            long_name => $fname,       # full POSIX name
#           created, createdUTC =>..., # Extra stats retrieved by getattrlist
#           type, creator...
        },
        folder => {                    # Attributes of folder containing target
            inode => $dstat->ino,
            name => basename($dname)
        },
        volume => {                    # Attributes of volume containing target
#            name => ...,
#            created, signature, type, flags, fsid => ...
            type => 5,                 # Other ejectable (disk image)
        },

#        posix_path => ...,
    );
    
    # Build the inode-path and posix-path of the target
    # by walking up to the mount point.
    unshift(@ppath, $fname);
    do {
        push(@ipath, $dstat->ino);
        unshift(@ppath, basename($dname));
        $dname = dirname($dname);
        $dstat = stat($dname);
    } while($dstat && $dstat->dev == $mountpointstat->dev && $dstat->ino != $ipath[-1]);
    pop(@ipath);      # Don't include the mountpoint's inode
    $ppath[0] = '';
    
    $alis{'inode_path'} = [ @ipath ];
    delete $alis{'folder'}->{'name'} if !@ipath;  # Mount point itself has no name here.
    $alis{'posix_path'} = join('/', @ppath);

    # Use getattrlist to retrieve the file-creation time (not returned by
    # stat because it's not POSIX) and the Mac type/creator codes.
    my(%finfo) = &syscall_getattrlist($file, 'fndrinfo', 'crtime');
    if ($finfo{'crtime'}) {
        $alis{'target'}->{'created'} = $finfo{'crtime'}->[0] + $mac_epoch_offset + $mac_tz_offset;
        $alis{'target'}->{'createdUTC'} = $finfo{'crtime'}->[0] + $mac_epoch_offset;
    }
    if ($finfo{'fndrinfo'}) {
        my($tp, $cr) = @{$finfo{'fndrinfo'}}[0, 1];
        @{$alis{'target'}}{'type'} = $tp
            unless ( $tp eq "\0\0\0\0" or $tp eq '    ' or $tp eq '????' );
        @{$alis{'target'}}{'creator'} = $cr
            unless ( $cr eq "\0\0\0\0" or $cr eq '    ' or $cr eq '????' );
    }
    
    # Retrieve Mac-specific attributes of the containing volume.
    my(%volinfo) = &syscall_getattrlist($mountpoint, 'vol_name', 'vol_fstype', 'vol_signature');
    if ($volinfo{'vol_name'}) {
        my($n) = $volinfo{'vol_name'};
        chop $n;
        $alis{'volume'}->{'name'} = $n;
        $alis{'volume'}->{'long_name'} = $n;
    }
    if (exists($volinfo{'vol_signature'})) {
        $alis{'volume'}->{'signature'} = pack('n', $volinfo{'vol_signature'});
    }

    %volinfo = &syscall_getattrlist($mountpoint, 'crtime');
    if ($volinfo{'crtime'}) {
        $alis{'volume'}->{'created'} = $volinfo{'crtime'}->[0] + $mac_epoch_offset + $mac_tz_offset;
        $alis{'volume'}->{'createdUTC'} = $volinfo{'crtime'}->[0] + $mac_epoch_offset;
    }

    \%alis;
}




1;
