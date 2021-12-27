#!/usr/bin/bash

# Copyright (c) 2021, The beep-projects contributors
# this file originated from https://github.com/beep-projects
# Do not remove the lines above.
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see https://www.gnu.org/licenses/

#load variables stored in condocambot.conf
CONF_FILE=/etc/condocam/condocambot.conf
TIMEOUT=60 #long polling intervall = 10 minutes
attackLimit=3 #how many unauthorized requests are allowed before the bot shuts down itself
CONDOCAM_IMAGE_FOLDER=/var/log/condocam/images

#some telegram icon codes for easy use
ICON_INFO=2139
ICON_WARN=26A0

if [ ! -f "$CONF_FILE" ]
then
  echo "File '${CONF_FILE}' not found. I can't run without this."
  echo "(hint, it should have been created by secondrun.sh)"
  exit
fi
# shellcheck source=./condocambot.conf
source "${CONF_FILE}"

#check if all variables are present
CONF_IS_COMPLETE=true
variables=("${BOT_TOKEN}" "${LAST_UPDATE_ID}" "${CHAT_ID}" "${ADMIN_ID}" "${ADMIN_IS_BOT}" "${ADMIN_FIRST_NAME}" "${ADMIN_LANGUAGE_CODE}")
for variable in "${variables[@]}"
do
  if [ -z "${variable}" ]; then
    echo "missing variable ${variable} in ${CONF_FILE}"
    CONF_IS_COMPLETE=false
  fi
done
case $CONF_IS_COMPLETE in
  (false) exit 0;; #indicate no failure, so that the service does not get restarted
esac
#get the number of cameras (I assume it is at least 1)
numOfCams=$( <motion.conf grep -c "camera camera-.*\.conf" )
nextUpdateId=$((LAST_UPDATE_ID+1))
attackCount=0

#everything is loaded, now define some functions

#######################################
# Checks for known devices on the network
# and activates or deactivates the motion detection
# Globals:
#   HOMIES
#   numOfCams
# Arguments:
#   None
# Outputs:
#   send messages via telegram about state changes
#######################################
function checkDevicePresence() {
  #if no HOMIES are defines, we can exit immedeately
  if [[ ! -v HOMIES[@] ]] || [ ${#HOMIES[@]} -eq 0 ]; then
    return 0
  fi
  declare -a peopleNames
  presenceDetected=false
  #arp-scan for present devices
  #arp-scan is pretty unreliable, so we have to do multiple scans
  for i in {1..5}
  do
    readarray -t devices < <( sudo arp-scan -l | grep -o -E '([[:alnum:]]{1,2}:){5}[[:alnum:]]{1,2}' )
    for mac in "${devices[@]}"
    do
      if [ ${HOMIES[${mac}]+foobar} ]; then
        echo "${HOMIES[${mac}]} is at home"
        peopleNames+=("${HOMIES[${mac}]}")
        presenceDetected=true 
      fi
    done
  done
  echo "peopleNames: ${peopleNames[*]}"
  #get motion detection (md) status
  mdOn=false
  i=1
  while [[ $i -le numOfCams ]] ; do
    shopt -s nocasematch
    if [[ $( curl -s "http://localhost:7999/${i}/detection/status" | grep -o -E "status (.*)$" | cut -f2- -d" " ) == "active" ]]; then
      mdOn=true
      break
    fi
    i=$((i+1))
  done
  if $presenceDetected && $mdOn; then
    setMotionDetectionState off
  elif ! $presenceDetected && ! $mdOn; then
    setMotionDetectionState on
  fi 
}

#######################################
# Activates or deactivates the motion detection
# based on the given state
# Globals:
#   ICON_INFO
#   numOfCams
# Arguments:
#   targetState
# Outputs:
#   send the state change via telegram
#######################################
function setMotionDetectionState () {
  targetState=$1
  case $targetState in
    on)
      i=1
      #start motion for each camera
      while [[ $i -le numOfCams ]] ; do
        curl -s "http://localhost:7999/${i}/detection/start" >/dev/null
        i=$((i+1))
      done
      telegram --quiet --icon $ICON_INFO --title "Motion Detection" --text "turned on"
      ;;
    off)
      i=1
      #pause motion for each camera
      while [[ $i -le numOfCams ]] ; do
        curl -s "http://localhost:7999/${i}/detection/pause" >/dev/null
        i=$((i+1))
      done
      telegram --quiet --icon $ICON_INFO --title "Motion Detection" --text "turned off"
      ;;
    *)
      telegram --quiet --icon $ICON_INFO --title "Motion Detection" --text "unknown target state \"${targetState}\""
      ;;
  esac
}

#start the bot loop for continuously checking for updates on the telegram channel
telegram --quiet --icon $ICON_INFO --text "Awaiting orders!"
while :
do
  #check for present devices and toggle md
  #TODO fix and activate this
  #checkDevicePresence
  #check if there is a new update on telegram
  #TODO getUpdates is not supported by telegram, it should be added
  updateJSON=$( curl -s -X GET "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?timeout=$TIMEOUT&offset=$nextUpdateId" )
  result=$( echo "${updateJSON}" | jq '.result' )

  if [ -n "${updateJSON}" ] && [ "${result}" != "[]" ]; then
    #the bot received an update
    #parse the received JSON data
    lastUpdateID=$( echo "${updateJSON}" | jq '.result | .[0].update_id' )
    adminID=$( echo "${updateJSON}" | jq '.result | .[0].message.from.id' )
    adminIsBot=$( echo "${updateJSON}" | jq '.result | .[0].message.from.is_bot' )
    adminFirstName=$( echo "${updateJSON}" | jq '.result | .[0].message.from.first_name' )
    adminLanguageCode=$( echo "${updateJSON}" | jq '.result | .[0].message.from.language_code' )
    #no matter if this request was legitimate, the nextUpdateId has to be increased, for not receiving this update again
    nextUpdateId=$((lastUpdateID+1))
    sed -i "s/^LAST_UPDATE_ID=.*/LAST_UPDATE_ID=$lastUpdateID/" $CONF_FILE
    if [ "${adminID}" != "${ADMIN_ID}" ] || [ "${adminIsBot}" != "${ADMIN_IS_BOT}" ] || [ "${adminFirstName}" != "${ADMIN_FIRST_NAME}" ] || [ "${adminLanguageCode}" != "${ADMIN_LANGUAGE_CODE}" ]; then
      #this is an authorized request. Process it.
      command=$( echo "${updateJSON}" | jq '.result | .[0].message.text' )
      command="${command%\"}" 
      command="${command#\"}"
      text=""
      case "${command}" in
        /help)
          read -r -d '' helpText <<-'TXTEOF'
		/help - shows this info
		/ping - returns pong to show that the bot is running
		/reboot - reboots the bot server
		/shutdown - shuts down the bot server
		/restartme - restarts the motioneye.service
		/uptime - returns the results of the _uptime_ command on the bot server
		/df - returns the result of _df -h_ on the bot server
		/status - returns the system status
		/snapshot - gets snapshots from all cameras
		/mdon - enables motion detection on all cameras
		/mdoff - disables motion detection on all cameras
		/setcommands - sends the commands list to @BotFather
		TXTEOF
          telegram --quiet --question  --title "help" --text "${helpText}"
          ;;
        /ping)
          telegram --quiet --icon $ICON_INFO --text "pong"
          ;;
        /reboot)
          telegram --quiet --icon $ICON_INFO --text "condocam.ai will reboot now"
          sudo reboot -f
          ;;
        /shutdown)
          telegram --quiet --icon $ICON_INFO --text "condocam.ai will shutdown now"
          sudo shutdown now
          ;;
        /restartme)
          telegram --quiet --icon $ICON_INFO --text "motioneye.service will be restarted"
          sudo systemctl restart motioneye.service
          ;;
        /status)
          motioneyeStatus=$( systemctl status motioneye.service | grep "^   Active" )
          condocambotStatus=$( systemctl status condocambot.service | grep "^   Active" )
          condocamDetectionStatus=$( systemctl status condocam_detection.service | grep "^   Active" )
          i=1
          detectionStatus=""
          while [[ $i -le numOfCams ]] ; do
            detectionStatus="${detectionStatus}\n*Camera${i} detection status:* "$( curl -s "http://localhost:7999/${i}/detection/status" | grep "status" | awk '{print $NF}' )
            i=$((i+1))
          done
          cpuTemp=$( vcgencmd measure_temp | grep -oE '[0-9]*\.[0-9]*')"°C"
          status="*motioneye.service:*\n${motioneyeStatus}\n*condocambot.service:*\n${condocambotStatus}\n*condocam_detection.service:*\n${condocamDetectionStatus}\n*number of cameras: *${numOfCams}${detectionStatus}\n*CPU temp: *$cpuTemp"
          telegram --quiet --icon $ICON_INFO --title "status" --text "${status}"
          ;;
        /snapshot)
          i=1
          # the sleeps in the following are a hack to work around the unpredictable link creation by motion
          while [[ $i -le numOfCams ]] ; do
            curl -s "http://localhost:7999/${i}/action/snapshot" >/dev/null
            while [ ! -f "${CONDOCAM_IMAGE_FOLDER}/Camera${i}/lastsnap.jpg" ]; do sleep 1; done #give the system some time to respond
              telegram --quiet --photo "${CONDOCAM_IMAGE_FOLDER}/Camera${i}/lastsnap.jpg"
              i=$((i+1))
          done
          sleep 2 #give the system some time to respond
          i=1
          # the handling of the lastsnap.jpg link is weird, so it is better to remove the link
          # in order to get a link to a new image the next time a snapshot is requested again
          while [[ $i -le numOfCams ]] ; do
            sudo rm "${CONDOCAM_IMAGE_FOLDER}/Camera${i}/lastsnap.jpg"
            i=$((i+1))
          done
          ;;
        /uptime)
          text=$( uptime )
          telegram --quiet --icon $ICON_INFO --title "uptime" --text "${text}"
          ;;
        /df)
          text=$( df -h )
          telegram --quiet --icon $ICON_INFO --title "disk usage" --text "${text}"
          ;;
        /mdon | /mdoff | "/motiondetection "* | "/md "*)
          targetState=$( echo "${command}" | cut -d' ' -f2 )
          if [[ "${targetState}" == /md* ]]; then
            targetState=$( echo $"${command}" | cut -d'd' -f2 )
          fi
          setMotionDetectionState "${targetState}"
          ;;
        /setcommands)
        #be carfull with the formatting of this. It took me a while to write the JSON in a format which gets accepted by @BotFather
          commandsList='{"commands": [
              {"command": "help", "description": "show commands list"},
              {"command": "ping", "description": "return pong"},
              {"command": "reboot", "description": "reboot bot server"},
              {"command": "shutdown", "description": "shut down bot server"},
              {"command": "restartme", "description": "restart motioneye.service"},
              {"command": "status", "description": "get system status"},
              {"command": "snapshot", "description": "get snapshots from all cameras"},
              {"command": "uptime", "description": "call uptime"},
              {"command": "df", "description": "call df -h"},
              {"command": "mdon", "description": "enable motion detection"},
              {"command": "mdoff", "description": "disable motion detection"},
              {"command": "setcommands", "description": "update commands at @BotFather"}
            ]}'
          # setMyCommands is not supported by telegram
          # TODO add it later to that
          curl -s "https://api.telegram.org/bot$BOT_TOKEN/setMyCommands" -H "Content-Type: application/json" -d "$commandsList" >/dev/null
          ;;
        /start)
          #nothing to do, but it is a telegram bot default command, so I should catch it
          telegram --quiet --icon $ICON_INFO --text "Awaiting orders!"
          ;;
        *)
          telegram --quiet --icon $ICON_INFO --title "unknown command" --text "command \"${command}\" not understood"
          ;;
      esac
    else
      #unauthorized request
      attackCount=$((attackCount+1))
      if [ $attackCount -ge $attackLimit ]; then
        telegram --quiet --error --title "ALARM" --text "I am receiving unauthorized requests. I am shutting myself down."
        sleep 5
        exit 0 #indicate no failure, so that the service does not get restarted
      fi
    fi
  fi #else the getUpdate just timed out, start waiting again
done
#we should not end up here
telegram --quiet --icon $ICON_WARN --text "I'm done for now! Service script exited."
