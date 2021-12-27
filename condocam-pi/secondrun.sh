#!/bin/bash
#
# Copyright (c) 2021, The beep-projects contributors
# this file originated from https://github.com/beep-projects
# Do not remove the lines above.
# The rest of this source code is subject to the terms of the Mozilla Public License.
# You can obtain a copy of the MPL at <https://www.mozilla.org/MPL/2.0/>.
#
# This file is inspired by the firstrun.sh, generated by the Raspberry Pi Imager https://www.raspberrypi.org/software/
#
# This file will be called after the network has been configured by firstrun.sh
# It updates the system, installs motioneye and configures all attached USB cameras
# It also sets up telegram as command interface and activates people detection using OpenCV for the camera images
# This script downloads a lot of stuff, so it will take a while to run
# For a full description see https://github.com/beep-projects/condocam.ai/readme.md
#


#######################################
# Checks if any user is holding one of the various lock files used by apt
# and waits until they become available. 
# Warning, you might get stuck forever in here
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   None
#######################################
function waitForApt() {
  while sudo fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock >/dev/null 2>&1; do
   echo waiting for access to apt lock files ...
   sleep 1
  done
}

# redirect output to 'secondrun.log':
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>/boot/secondrun.log 2>&1

echo "START secondrun.sh"
#the following variables should be set by firstrun.sh
BOT_TOKEN=COPY_BOT_TOKEN_HERE
ENABLE_RASPAP=false
#fixed configs
SERVICE_FOLDER=/etc/systemd/system
TELEGRAM_FOLDER=/etc/telegram
TELEGRAM_CONF="${TELEGRAM_FOLDER}/telegram.conf"
CONDOCAM_FOLDER=/etc/condocam
CONDOCAM_IMAGE_FOLDER=/var/log/condocam/images
CONDOCAMBOT_CONF="${CONDOCAM_FOLDER}/condocambot.conf"
PROTOTXT="MobileNetSSD_deploy.prototxt.txt"
CAFFEEMODEL="MobileNetSSD_deploy.caffemodel"

echo "create required directories"
echo "mkdir -p ${CONDOCAM_FOLDER}"
sudo mkdir -p "${CONDOCAM_FOLDER}"
echo "mkdir -p ${CONDOCAM_IMAGE_FOLDER}"
sudo mkdir -p "${CONDOCAM_IMAGE_FOLDER}"
echo "mkdir -p ${TELEGRAM_FOLDER}"
sudo mkdir -p "${TELEGRAM_FOLDER}"

#first we setup telegram, so we can send status messages to the user
echo "installing utilities missing in Raspberry OS, but needed by this script"
waitForApt
sudo apt install -y bc jq
#setup the telegram bot
echo "I am now setting up the telegram communication"
#make sure that the telegram scrip uses the configured TELEGRAM_CONF
sudo sed -i "s/^FILE_CONF=.*/FILE_CONF=${TELEGRAM_CONF//\//\\/}/" /boot/files/telegram
sudo cp /boot/files/telegram.conf "${TELEGRAM_CONF}"
sudo cp /boot/files/telegram /usr/local/sbin/telegram
sudo chmod +x /usr/local/sbin/telegram

echo "configuring telegram bot"
echo "curl -X GET \"https://api.telegram.org/bot${BOT_TOKEN}/getUpdates\""
#for this call to be successfull, there must be one new message in the bot chat, not older than 24h
UPDATEJSON=$( curl -X GET "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" )
echo "${UPDATEJSON}"
#get the client_id for sending the messages to the created telegram bot
CHAT_ID=$( echo "${UPDATEJSON}" | jq '.result | .[0].message.chat.id' )
#get the information for the condocambot.conf
LAST_UPDATE_ID=$( echo "${UPDATEJSON}" | jq '.result | .[0].update_id' )
#note, the condocambot is not very picky, the sender of the first message it sees, will be the owner
ADMIN_ID=$( echo "${UPDATEJSON}" | jq '.result | .[0].message.from.id' )
ADMIN_IS_BOT=$( echo "${UPDATEJSON}" | jq '.result | .[0].message.from.is_bot' )
ADMIN_FIRST_NAME=$( echo "${UPDATEJSON}" | jq '.result | .[0].message.from.first_name' )
ADMIN_LANGUAGE_CODE=$( echo "${UPDATEJSON}" | jq '.result | .[0].message.from.language_code' )

#write the configuration for the telegram bot
sudo sed -i "s/api-key=.*/api-key=${BOT_TOKEN}/" "${TELEGRAM_CONF}"
sudo sed -i "s/user-id=.*/user-id=${CHAT_ID}/" "${TELEGRAM_CONF}"
telegram --success --text "telegram bot is installed successfully, continuing to install the rest of the system."


#first we want to update the system and install packaged
echo "updating the system"
sudo apt update
waitForApt
sudo apt full-upgrade -y
#arp-scan is needed by the presence detection of devices and fail2ban you add some security to the system
waitForApt
sudo apt install -y arp-scan fail2ban

#write the condocambot.conf file
echo
echo "write the condocambot.conf file"
echo "BOT_TOKEN=${BOT_TOKEN}" | sudo tee "${CONDOCAMBOT_CONF}" #this call creates the file, the others append to it
echo "LAST_UPDATE_ID=${LAST_UPDATE_ID}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "CHAT_ID=${CHAT_ID}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "ADMIN_ID=${ADMIN_ID}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "ADMIN_IS_BOT=${ADMIN_IS_BOT}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "ADMIN_FIRST_NAME=${ADMIN_FIRST_NAME}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "ADMIN_LANGUAGE_CODE=${ADMIN_LANGUAGE_CODE}" | sudo tee -a "${CONDOCAMBOT_CONF}"
#make sure that the condocambot.sh is using the created conf file
sudo sed -i "s/^CONF_FILE=.*/CONF_FILE=${CONDOCAMBOT_CONF//\//\\/}/" /boot/files/condocambot.sh
sudo sed -i "s/^CONDOCAM_IMAGE_FOLDER=.*/CONDOCAM_IMAGE_FOLDER=${CONDOCAM_IMAGE_FOLDER//\//\\/}/" /boot/files/condocambot.sh

telegram --success --text "system is apt updated, next step is to install motion and motionEye"

#just follow the guide on https://github.com/ccrisan/motioneye/wiki/Install-On-Raspbian to install motioneye

#install motion and all dependencies
echo "installing motion and all dependencies"
sudo apt install -y motion

echo "installing motioneye dependencies"
sudo apt install -y python-pip python-dev libssl-dev libcurl4-openssl-dev libjpeg-dev libz-dev python-pil

echo "installing motioneye"
sudo pip install motioneye

#don't do this step from the installation guide, we do not want to use the default config
#sudo cp /usr/local/share/motioneye/extra/motioneye.conf.sample /etc/motioneye/motioneye.conf

#find all connected USB cameras and add them to motioneye
#Note: each cam creates two interfaces, the first one should be the video, the second one the meta data
v4l2-ctl --list-devices
USBCAMS=$( v4l2-ctl --list-devices | awk '/\(usb-/{getline; print}' )
echo "USB cameras:"
echo "${USBCAMS}"
#add all USBCAMS to motion and motioneye
CAMID=0
for CAM in $USBCAMS
do
	#get maximum resolution of CAM
	RESOLUTION=$( v4l2-ctl --list-formats-ext -d "${CAM}" | grep Size | cut -d " " -f3 | sort -u -n -tx -k1 -k2 | tail -1 )
	WIDTH=$(echo "${RESOLUTION}" | cut -f1 -dx)
	HEIGHT=$(echo "${RESOLUTION}" | cut -f2 -dx)
	echo "configuring ${CAM}"
	echo "resolution = ${RESOLUTION}"
	#creat config for CAM
	CAMID=$((CAMID+1))
	echo "camera name = Camera${CAMID}"
	## @id $CAMID
	sudo sed -i "s/@id .*/@id ${CAMID}/" /boot/files/template-camera.conf
	#set motion detection threshold to 1% of all pixels
	THRESH=$(echo "(${WIDTH}*${HEIGHT}*0.01)/1" | bc)
	#threshold $THRESH
	sudo sed -i "s/threshold .*/threshold ${THRESH}/" /boot/files/template-camera.conf
	#set motion detection max_threshold to 2.5% of all pixels
	MAX_THRESH=$(echo "(${WIDTH}*${HEIGHT}*0.025)/1" | bc)
	#threshold_maximum $THRESH
	sudo sed -i "s/threshold_maximum .*/threshold_maximum ${MAX_THRESH}/" /boot/files/template-camera.conf
	#snapshot_filename Cam${CAMID}_%Y-%m-%d-%H-%M-%S
	sudo sed -i "s/snapshot_filename .*/snapshot_filename Cam${CAMID}_\%Y-\%m-\%d-\%H-\%M-\%S/" /boot/files/template-camera.conf
	#picture_filename Cam${CAMID}_%Y-%m-%d-%H-%M-%S
	sudo sed -i "s/picture_filename .*/picture_filename Cam${CAMID}_\%Y-\%m-\%d-\%H-\%M-\%S/" /boot/files/template-camera.conf
	#target_dir ${CONDOCAM_IMAGE_FOLDER}/Camera${CAMID}
	sudo sed -i "s/target_dir .*/target_dir ${CONDOCAM_IMAGE_FOLDER//\//\\/}\/Camera${CAMID}/" /boot/files/template-camera.conf
	#stream_port 808$CAMID
	sudo sed -i "s/stream_port .*/stream_port 808${CAMID}/" /boot/files/template-camera.conf
	#text_left Camera1
	sudo sed -i "s/text_left .*/text_left Camera${CAMID}/" /boot/files/template-camera.conf
	#videodevice $CAM, adjust the command for the / in the path $CAM
	sudo sed -i 's,videodevice .*,'"videodevice ${CAM}"',' "/boot/files/template-camera.conf"
	#camera_name Camera1
	sudo sed -i "s/camera_name .*/camera_name Camera${CAMID}/" /boot/files/template-camera.conf
	#height 1080
	sudo sed -i "s/height .*/height ${HEIGHT}/" /boot/files/template-camera.conf
	#width 1920
	sudo sed -i "s/width .*/width ${WIDTH}/" /boot/files/template-camera.conf
	#update all occurences of the motioneye.conf
	sudo sed -i "s/ \".*\/motioneye.conf\"/ \"${CONDOCAM_FOLDER//\//\\/}\/motioneye.conf\"/" /boot/files/template-camera.conf
	#copy the config to the motioneye folder
	echo "cp /boot/files/template-camera.conf \"${CONDOCAM_FOLDER}/camera-${CAMID}.conf\""
	sudo cp /boot/files/template-camera.conf "${CONDOCAM_FOLDER}/camera-${CAMID}.conf"

	#add CAM.config to motion.conf
	sudo bash -c "echo \"camera camera-${CAMID}.conf\" >> /boot/files/template-motion.conf"

done
echo "all cameras configured, copying config files to ${CONDOCAM_FOLDER}"
#move the conf files to the motioneye folder
echo "cp /boot/files/template-motion.conf ${CONDOCAM_FOLDER}/motion.conf"
sudo cp /boot/files/template-motion.conf "${CONDOCAM_FOLDER}/motion.conf"

#make sure the paths configured in motioneye.conf are consistent with the paths configured here
sudo sed -i "s/conf_path .*/conf_path ${CONDOCAM_FOLDER//\//\\/}/" "${CONDOCAM_FOLDER}/motioneye.conf"
sudo sed -i "s/media_path .*/media_path ${CONDOCAM_IMAGE_FOLDER//\//\\/}/" "${CONDOCAM_FOLDER}/motioneye.conf"
echo "cp /boot/files/motioneye.conf ${CONDOCAM_FOLDER}/motioneye.conf"
sudo cp /boot/files/motioneye.conf "${CONDOCAM_FOLDER}/motioneye.conf"
#echo "rm /boot/files/template-camera.conf"
#sudo rm /boot/files/template-camera.conf

telegram --success --text "motion and motionEye are now installed, next one up is OpenCV and its dependencies for people detection"

echo "install python stuff and dependecies for people recognition with opencv"
waitForApt
sudo apt install -y libatlas-base-dev python3-pip openexr libgtk-3-dev
#numpy only supports python3
#make sure to use -U because numpy is already installed but needs an update
sudo pip3 install -U numpy opencv-utils opencv-python imutils watchdog filetype

echo "Install motioneye.service to run at startup and start the motioneye server:"
ExecStart="/usr/local/bin/meyectl startserver -c \"${CONDOCAM_FOLDER}/motioneye.conf\""
sudo sed -i "s/ExecStart=.*/ExecStart=${ExecStart//\//\\/}/" /boot/files/motioneye.service
sudo cp /boot/files/motioneye.service "${SERVICE_FOLDER}/motioneye.service"

echo "Install condocam_detection.service to run at startup:"
ExecStart="python3 \"${CONDOCAM_FOLDER}/condocam_image_watchdog.py\" -p \"$CONDOCAM_IMAGE_FOLDER\""
sudo sed -i "s/ExecStart=.*/ExecStart=${ExecStart//\//\\/}/" /boot/files/condocam_detection.service
sudo sed -i "s/_PROTOTXT=.*/_PROTOTXT=\"${PROTOTXT//\//\\/}\"/" /boot/files/condocam_image_watchdog.py
sudo sed -i "s/_CAFFEEMODEL=.*/_CAFFEEMODEL=\"${CAFFEEMODEL//\//\\/}\"/" /boot/files/condocam_image_watchdog.py
sudo sed -i "s/WorkingDirectory=.*/WorkingDirectory=${CONDOCAM_FOLDER//\//\\/}/" /boot/files/condocam_detection.service
echo "cp /boot/files/${PROTOTXT} ${CONDOCAM_FOLDER}/${PROTOTXT}"
sudo cp "/boot/files/${PROTOTXT}" "${CONDOCAM_FOLDER}/${PROTOTXT}"
echo "cp /boot/files/${CAFFEEMODEL} ${CONDOCAM_FOLDER}/${CAFFEEMODEL}"
sudo cp "/boot/files/${CAFFEEMODEL}" "${CONDOCAM_FOLDER}/${CAFFEEMODEL}"
sudo cp /boot/files/condocam_image_watchdog.py "${CONDOCAM_FOLDER}/condocam_image_watchdog.py"
sudo cp /boot/files/condocam_detection.service "${SERVICE_FOLDER}/condocam_detection.service"

echo "Install condocambot.service to run at startup"
ExecStart="${CONDOCAM_FOLDER}/condocambot.sh"
sudo sed -i "s/ExecStart=.*/ExecStart=${ExecStart//\//\\/}/" /boot/files/condocambot.service
sudo sed -i "s/WorkingDirectory=.*/WorkingDirectory=${CONDOCAM_FOLDER//\//\\/}/" /boot/files/condocambot.service
sudo cp /boot/files/condocambot.sh "${CONDOCAM_FOLDER}/condocambot.sh"
sudo chmod 755 "${CONDOCAM_FOLDER}/condocambot.sh"
sudo cp /boot/files/condocambot.service "${SERVICE_FOLDER}/condocambot.service"

#reload the service deamons and start the newly installed services
sudo systemctl daemon-reload
sudo systemctl enable condocambot.service
#sudo systemctl start condocambot.service
sudo systemctl enable motioneye.service
#sudo systemctl start motioneye.service
sudo systemctl enable condocam_detection.service
#sudo systemctl start condocam_detection.service

if $ENABLE_RASPAP; then
  #install raspap
  telegram --warning --text "I am installing now RaspAP, remember to secure this system after the setup is finished!"
  curl -sL https://install.raspap.com | bash -s -- --yes
fi

telegram --success --text "All packages are installed now, I am just doing some clean up and then I will be available for you."

echo "remove autoinstalled packages" 
waitForApt
sudo apt -y autoremove

echo "add run /boot/thirdrun.sh command to cmdline.txt file for next reboot"
sudo sed -i '$s|$| systemd.run=/boot/thirdrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target\n|' /boot/cmdline.txt

#disable the service that started this script
sudo systemctl disable secondrun.service
echo "DONE secondrun.sh, rebooting the system"

sleep 2
sudo reboot
