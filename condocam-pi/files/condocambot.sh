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

# define global variables

# shellcheck disable=SC1091
CONF_FILE=/etc/condocam/condocambot.conf
TIMEOUT=60 # long polling intervall = 10 minutes, but get's currently ignored by the Telegram server
attackLimit=3 # how many unauthorized requests are allowed before the bot shuts down itself
CONDOCAM_IMAGE_FOLDER=/var/log/condocam/images

# this script runs the LiStaBot scripts in subshells and communicates with them via a named pipe
# these handles are uses for cleaning up on exit
NAMED_PIPE_OUT=condocam_to_lista_pipe
LISTA_BOT_PID=0
LISTA_WATCHDOG_PID=0

# global variables loaded from CONF_FILE
BOT_TOKEN=""
LAST_UPDATE_ID=""
CHAT_ID=""
ADMIN_ID=""
ADMIN_IS_BOT=""
ADMIN_FIRST_NAME=""
ADMIN_LANGUAGE_CODE=""

#######################################
# Cleanup function called by a trap on SIGINT, SIGTERM, and EXIT
# Globals:
#   NAMED_PIPE_OUT
#   LISTA_BOT_PID
#   LISTA_WATCHDOG_PID
# Arguments:
#   None
# Outputs:
#   Removes NAMED_PIPE_OUT and kills the processes
#   LISTA_BOT_PID and LISTA_WATCHDOG_PID
#######################################
trap_cleanup() {
  # Close any open named pipes
  rm -f $NAMED_PIPE_OUT
  # Terminate any running subshells
  pkill -P $LISTA_BOT_PID
  pkill -P $LISTA_WATCHDOG_PID
  # inform admin about the exit reason
  telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --title "condocambot exits" --text "Received signal $1\. Exiting\."
  # Exit the script
  exit
}
# Register the cleanup function to be executed when SIGINT is received
trap "trap_cleanup SIGINT" SIGINT
trap "trap_cleanup SIGTERM" SIGTERM
trap "trap_cleanup EXIT" EXIT

#######################################
# Starts the lista_watchdog.sh and lista_bot.sh and
# create the named pipe for forwarding commands to lista_bot.sh
# Globals:
#   NAMED_PIPE_OUT
#   LISTA_BOT_PID
#   LISTA_WATCHDOG_PID
# Arguments:
#   None
# Outputs:
#   Creates NAMED_PIPE_OUT and starts processes
#   LISTA_BOT_PID and LISTA_WATCHDOG_PID
#######################################
start_lista_scripts() {
  # Create named pipe
  if [[ ! -p $NAMED_PIPE_OUT ]]; then
    mkfifo $NAMED_PIPE_OUT
  fi
  if pgrep -x "lista_bot.sh" >/dev/null; then
    LISTA_BOT_PID=$(pgrep -x "lista_bot.sh")
  else
    lista_bot.sh &
    LISTA_BOT_PID=$!
  fi  
  if pgrep -x "lista_watchdog.sh" >/dev/null; then
    LISTA_WATCHDOG_PID=$(pgrep -x "lista_watchdog.sh")
  else
    lista_watchdog.sh &
    LISTA_WATCHDOG_PID=$!
  fi  
}

# load variables stored in condocambot.conf
if [ ! -f "$CONF_FILE" ]
then
  echo "File '${CONF_FILE}' not found. I can't run without this."
  echo "(hint, it should have been created by secondrun.sh)"
  exit
fi
# shellcheck source=./condocambot.conf
source "${CONF_FILE}"

# check if all variables are present
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
  (false) exit 0;; # indicate no failure, so that the service does not get restarted
esac
# get the number of cameras (I assume it is at least 1)
numOfCams=$( <motion.conf grep -c "camera camera-.*\.conf" )
nextUpdateId=$((LAST_UPDATE_ID+1))
attackCount=0

# everything is loaded, now define some functions

#######################################
# Activates or deactivates the motion detection
# based on the given state
# Globals:
#   numOfCams
# Arguments:
#   targetState
# Outputs:
#   send the state change via telegram.bot
#######################################
function setMotionDetectionState () {
  targetState=$1
  case $targetState in
    on)
      i=1
      # start motion for each camera
      while [[ $i -le numOfCams ]] ; do
        curl -s "http://localhost:7999/${i}/detection/start" >/dev/null
        i=$((i+1))
      done
      telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --title "Motion Detection" --text "turned on"
      ;;
    off)
      i=1
      # pause motion for each camera
      while [[ $i -le numOfCams ]] ; do
        curl -s "http://localhost:7999/${i}/detection/pause" >/dev/null
        i=$((i+1))
      done
      telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --title "Motion Detection" --text "turned off"
      ;;
    *)
      telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --title "Motion Detection" --text "unknown target state \"${targetState}\""
      ;;
  esac
}

function escapeReservedCharacters() {
  STRING=$1
  STRING="${STRING//\(/\\\(}"
  STRING="${STRING//\)/\\\)}"
  STRING="${STRING//\[/\\\[}"
  STRING="${STRING//\]/\\\]}"
  STRING="${STRING//\_/\\\_}"
  STRING="${STRING//\*/\\\*}"
  STRING="${STRING//\~/\\\~}"
  STRING="${STRING//\`/\\\`}"
  STRING="${STRING//\|/\\\|}"
  echo "${STRING}"
}

declare -a commandsList
commandsList=("mdon=enable motion detection"
              "mdoff=disable motion detection"
              "snapshot=get snapshots from all cameras"
              "servicestatus=service status"
              "systemstatus=system status"
              "gcl=CPU load Top 5"
              "gru=RAM usage Top 5"
              "uptime=uptime"
              "df=df -h"
              "gconf=get the config file"
              "restartme=restart motioneye.service"
              "restartbot=restart condocambot.service"
              "reboot=reboot bot server"
              "shutdown=shut down bot server"
              "help=show commands list"
              "setcommands=update commands at @BotFather")
telegram.bot -bt "${BOT_TOKEN}" --set_commands "${commandsList[@]}"

# start the bot loop for continuously checking for updates on the telegram channel
telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --text "Condocambot is ready\!"
# start lista_bot.sh and lista_watchdg.sh
start_lista_scripts
while :
do
  # check if there is a new update on telegram
  # TODO getUpdates is not supported by telegram, it should be added
  #updateJSON=$( curl -s -X GET "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?timeout=$TIMEOUT&offset=$nextUpdateId" )
  updateJSON=$( telegram.bot -bt "${BOT_TOKEN}" -q --get_updates --timeout ${TIMEOUT} --offset ${nextUpdateId} )
  result=$( echo "${updateJSON}" | jq '.result' )

  if [ -n "${updateJSON}" ] && [ "${result}" != "[]" ]; then
    # the bot received an update
    # parse the received JSON data
    lastUpdateID=$( echo "${updateJSON}" | jq '.result | .[0].update_id' )
    adminID=$( echo "${updateJSON}" | jq '.result | .[0].message.from.id' )
    adminIsBot=$( echo "${updateJSON}" | jq '.result | .[0].message.from.is_bot' )
    adminFirstName=$( echo "${updateJSON}" | jq '.result | .[0].message.from.first_name' )
    adminLanguageCode=$( echo "${updateJSON}" | jq '.result | .[0].message.from.language_code' )
    # no matter if this request was legitimate, the nextUpdateId has to be increased, for not receiving this update again
    nextUpdateId=$((lastUpdateID+1))
    sed -i "s/^LAST_UPDATE_ID=.*/LAST_UPDATE_ID=$lastUpdateID/" $CONF_FILE
    if [ "${adminID}" != "${ADMIN_ID}" ] || [ "${adminIsBot}" != "${ADMIN_IS_BOT}" ] || [ "${adminFirstName}" != "${ADMIN_FIRST_NAME}" ] || [ "${adminLanguageCode}" != "${ADMIN_LANGUAGE_CODE}" ]; then
      # this is an authorized request. Process it.
      command=$( echo "${updateJSON}" | jq '.result | .[0].message.text' )
      command="${command%\"}" 
      command="${command#\"}"
      text=""
      case "${command}" in
        # forward updateJSON to listabot for processing of these commands
        /systemstatus | /gcl | /gru | /uptime | /df | /getconfig | /gconf | /setdisklimit | /sdl | /setcpulimit | /scl | \
        /setramlimit | /srl | /setcheckinterval | /sci | /getcpuloadtopx | /gcl | /getramusagetopx | /gru )
          if ! ps -p $LISTA_BOT_PID > /dev/null 2>&1; then
            # if lista_bot.sh died for some reason, restart it
            start_lista_scripts
          fi
          #echo "[condocambot.sh] updateJSON to pipe == ${updateJSON}"
          echo "${updateJSON}" > $NAMED_PIPE_OUT
        ;;
        # process condocambot commands
        /help)
          read -r -d '' helpText <<-'TXTEOF'
		/mdon - enables motion detection on all cameras
		/mdoff - disables motion detection on all cameras
		/snapshot - gets snapshots from all cameras
		/servicestatus - returns the status of the services
		/systemstatus - returns the system status
    /gcl - get CPU load Top 5
    /gru - get RAM usage Top 5
		/uptime - returns the results of the _uptime_ command on the bot server
		/df - returns the result of _df -h_ on the bot server
    /getconfig - get the content of listabot.conf
        Short /gconf
    /setdisklimit [VALUE] - set the alert threshold for disk usage to [VALUE] percent. Only integers allowed. 
        Short /sdl
    /setcpulimit [VALUE] - set the alert threshold for cpu usage to [VALUE] percent. Only integers allowed.
        Short /scl
    /setramlimit [VALUE] - set the alert threshold for ram usage to [VALUE] percent. Only integers allowed.
        Short /srl
    /setcheckinterval [VALUE] - set the time interval in which the watchdog checks the limits to [VALUE] seconds.
        Short /sci
    /getcpuloadtopx [VALUE1] [VALUE2]- get the [VALUE1] processes causing the highest CPU load. 
        If omitted, [VALUE1] defaults to 5. You can pass [VALUE2] to set the line width of the output.
        [VALUE2] defaults to 120.
        Short /gcl
    /getramusagetopx [VALUE1] [VALUE2] - get the [VALUE1] processes having the highest RAM usage.
        If omitted, [VALUE1] defaults to 5. You can pass [VALUE2] to set the line width of the output.
        [VALUE2] defaults to 120.
        Short /gru
		/restartme - restarts the motioneye.service
		/restartbot - restarts the condocambot.service
		/reboot - reboot the bot server
		/shutdown - shut down the bot server
		/help - shows this info
		/setcommands - sends the commands list to @BotFather
TXTEOF
          telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --question --title "help" --text "${helpText}"
          ;;
        /reboot)
          telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --text "The server will reboot now\. Back in a sec!"
          sudo reboot -f
          ;;
        /shutdown)
          telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --text "The server will shutdown now\. Good bye!"
          sudo shutdown now
          ;;
        /restartme)
          telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --text "motioneye\.service will be restarted"
          sudo systemctl restart motioneye.service
          ;;
        /restartbot)
          telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --text "condocambot\.service will be restarted"
          sudo systemctl restart condocambot.service
          ;;
        /servicestatus)
          motioneyeStatus=$( systemctl status motioneye.service | grep "^[ ]*Active" )
          motioneyeStatus=$( escapeReservedCharacters "${motioneyeStatus}" )
          condocambotStatus=$( systemctl status condocambot.service | grep "^[ ]*Active" )
          condocambotStatus=$( escapeReservedCharacters "${condocambotStatus}" )
          condocamDetectionStatus=$( systemctl status condocam_detection.service | grep "^[ ]*Active" )
          condocamDetectionStatus=$( escapeReservedCharacters "${condocamDetectionStatus}" )
          i=1
          detectionStatus=""
          while [[ $i -le numOfCams ]] ; do
            detectionStatus="${detectionStatus}\n*Camera${i} detection status:* "$( curl -s "http://localhost:7999/${i}/detection/status" | grep "status" | awk '{print $NF}' )
            i=$((i+1))
          done
          cpuTemp=$( vcgencmd measure_temp | grep -oE '[0-9]*\.[0-9]*')"°C"
          status="*motioneye\.service:*\n${motioneyeStatus}\n*condocambot\.service:*\n${condocambotStatus}\n*condocam\_detection\.service:*\n${condocamDetectionStatus}\n*number of cameras:* ${numOfCams}${detectionStatus}\n*CPU temp:* ${cpuTemp}"
          telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --title "status" --text "${status}"
          ;;
        /snapshot)
          i=1
          # the sleeps in the following are a hack to work around the unpredictable link creation by motion
          while [[ $i -le numOfCams ]] ; do
            j=0
            curl -s "http://localhost:7999/${i}/action/snapshot" >/dev/null
            while [ ! -f "${CONDOCAM_IMAGE_FOLDER}/Camera${i}/lastsnap.jpg" ]; do
              j=$((j+1)); #counter for not sleeping forever if snapshot is not created
              if [[ $j -ge 10 ]]; then
                break
              else
                sleep 1
              fi
            done # give the system some time to respond
            if [[ $j -ge 10 ]]; then
                telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --error --text "Could not get a snapshot from Camera${i}\!"
              else
                telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --photo "${CONDOCAM_IMAGE_FOLDER}/Camera${i}/lastsnap.jpg"
                sleep 1
                # the handling of the lastsnap.jpg link is weird, so it is better to remove the link
                # in order to get a link to a new image the next time a snapshot is requested again
                sudo rm "${CONDOCAM_IMAGE_FOLDER}/Camera${i}/lastsnap.jpg"
            fi
            i=$((i+1))
          done
          ;;
        /mdon | /mdoff | "/motiondetection "* | "/md "*)
          targetState=$( echo "${command}" | cut -d' ' -f2 )
          if [[ "${targetState}" == /md* ]]; then
            targetState=$( echo $"${command}" | cut -d'd' -f2 )
          fi
          setMotionDetectionState "${targetState}"
          ;;
        /setcommands)
          telegram.bot -bt "${BOT_TOKEN}" --set_commands "${commandsList[@]}"
          ;;
        /start)
          # nothing to do, but it is a telegram bot default command, so I should catch it
          telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --text "Condocambot is ready\!"
          ;;
        *)
          telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --info --title "unknown command" --text "command \"${command}\" not understood"
          ;;
      esac
    else
      # unauthorized request
      attackCount=$((attackCount+1))
      if [ $attackCount -ge $attackLimit ]; then
        telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --error --title "ALARM" --text "I am receiving unauthorized requests\. I am shutting myself down\."
        sleep 5
        exit 0 # indicate no failure, so that the service does not get restarted
      fi
    fi
  fi # else the getUpdate just timed out, start waiting again
done
# we should not end up here
telegram.bot -bt "${BOT_TOKEN}" -cid "${CHAT_ID}" -q --warning --text "I'm done for now\! Service script exited\."
