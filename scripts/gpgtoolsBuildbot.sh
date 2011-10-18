#!/bin/bash
# ##############################################################################
#
# Buildbot start script for GPGTools
#
# @version  1.0 (2011-10-15)
# @author   Alex
# @url      http://gpgtools.org
# @url      https://raw.github.com/GPGTools/GPGTools_Core/master/resources/master.cfg
# @todo     Just an initial version, a lot of things todo
# @history  1.0 Initial version
#
# ##############################################################################

cd /Data/Temp/GPGTools_QA/

# config #######################################################################
name_master="gpgtools-master"
name_slave="gpgtools-slave"
url_master="http://localhost:8010/waterfall"
url_config="https://raw.github.com/GPGTools/GPGTools_Core/master/resources/master.cfg"
conf_port="localhost:9989"
conf_pwd="pass"
conf_slave="example-slave"
# ##############################################################################


# menu #########################################################################
while true; do
  echo "========================================="
  echo "What do you want to do?"
  echo " 0) Exit"
  echo " 1) Start master and slave"
  echo " 2) Stop master and slave"
  echo " 3) Show buildbot"
  echo " 4) Reload config"
  echo " 5) Invoke change for all projects"
  echo " 6) Invoke change for specific project"
  echo "========================================="
  echo -n "Your choice: "

  read input
  if [ "$input" == "0" ]; then
    exit 0
  elif [ "$input" == "1" ]; then
    # start master #############################################################
    if [ "`which buildbot`" == "" ]; then easy_install buildbot; fi
    if [ ! -d "$name_master" ]; then buildbot create-master "$name_master"; fi
    if [ ! -f "$name_master/master.cfg" ]; then curl "$url_config" > "$name_master/master.cfg"; fi
    if [ "`ps waux|grep -i python|grep $name_master`" == "" ]; then buildbot start "$name_master"; fi
    # ##########################################################################

    # start slave ##################################################################
    if [ "`which buildslave`" == "" ]; then easy_install buildbot-slave; fi
    if [ ! -d "$name_slave" ]; then buildslave create-slave "$name_slave" "$conf_port" "$conf_slave" "$conf_pwd"; fi
    if [ "`ps waux|grep -i python|grep $name_slave`" == "" ]; then nice -n 15 buildslave start "$name_slave"; fi
    # ##############################################################################
  elif [ "$input" == "2" ]; then
    buildslave stop "$name_slave"
    buildbot stop "$name_master"
  elif [ "$input" == "3" ]; then
    open "$url_master"
  elif [ "$input" == "4" ]; then
    buildbot reconfig "$name_master"
  elif [ "$input" == "5" ]; then
    buildbot sendchange --project "all" --master "$conf_port" --who "script" manual
  elif [ "$input" == "6" ]; then
    echo -n "Which project: "
    read project
    buildbot sendchange --project "$project" --master "$conf_port" --who "script" manual
  fi
done
# ##############################################################################
