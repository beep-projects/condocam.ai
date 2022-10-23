#!/bin/bash
#
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
#
# This file is inspired by the firstrun.sh, generated by the Raspberry Pi Imager https://www.raspberrypi.org/software/
#
# This file will be called after the network has been configured by firstrun.sh
# It updates the system, installs motioneye and configures all attached USB cameras
# It also sets up telegram.bot as command interface and activates people detection using OpenCV for the camera images
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
   echo ["$(date +%T)"] waiting for access to apt lock files ...
   sleep 1
  done
}

#######################################
# Checks if internet cann be accessed
# and waits until they become available. 
# Warning, you might get stuck forever in here
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   None
#######################################
function waitForInternet() {
  until nc -zw1 google.com 443 >/dev/null 2>&1;  do
    #newer Raspberry Pi OS versions do not have nc preinstalled, but wget is still there
    if wget -q --spider http://google.com; then
      break # we are online
    else
      #we are still offline
      echo ["$(date +%T)"] waiting for internet access ...
      sleep 1
    fi
  done
}

# redirect output to 'secondrun.log':
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>/boot/secondrun.log 2>&1

echo "START secondrun.sh"
# the following variables should be set by firstrun.sh
BOT_TOKEN=COPY_BOT_TOKEN_HERE
ENABLE_RASPAP=false
# fixed configs
SERVICE_FOLDER=/etc/systemd/system
CONDOCAM_FOLDER=/etc/condocam
CONDOCAM_IMAGE_FOLDER=/var/log/condocam/images
CONDOCAMBOT_CONF="${CONDOCAM_FOLDER}/condocambot.conf"
PROTOTXT="MobileNetSSD_deploy.prototxt.txt"
CAFFEEMODEL="MobileNetSSD_deploy.caffemodel"
# check the arch, as armv6l systems are not properly supported
ARCH=$(arch)

echo "create required directories"
echo "mkdir -p ${CONDOCAM_FOLDER}"
sudo mkdir -p "${CONDOCAM_FOLDER}"
echo "mkdir -p ${CONDOCAM_IMAGE_FOLDER}"
sudo mkdir -p "${CONDOCAM_IMAGE_FOLDER}"

# internet connectivity is required for installing required packages and updating the system
waitForInternet

# first we setup telegram, so we can send status messages to the user
echo "installing utilities missing in Raspberry OS, but needed by this script"
waitForApt
echo "sudo apt install -y bc jq"
sudo apt install -y bc jq
#setup the telegram bot
echo "I am now setting up the telegram communication"
# make sure that the telegram scrip uses the configured TELEGRAM_CONF
#sudo sed -i "s/^FILE_CONF=.*/FILE_CONF=${TELEGRAM_CONF//\//\\/}/" /boot/files/telegram
#sudo cp /boot/files/telegram.conf "${TELEGRAM_CONF}"
#sudo cp /boot/files/telegram /usr/local/sbin/telegram
#sudo chmod +x /usr/local/sbin/telegram
wget https://github.com/beep-projects/telegram.bot/releases/download/v1.0.0/telegram.bot
chmod 755 telegram.bot
sudo ./telegram.bot --install

echo "configuring telegram bot"
echo "telegram.bot --get_updates --bottoken ${BOT_TOKEN}"
# for this call to be successfull, there must be one new message in the bot chat, not older than 24h
UPDATEJSON=$( telegram.bot --get_updates --bottoken ${BOT_TOKEN} )
echo "${UPDATEJSON}"
#get the information for the condocambot.conf
LAST_UPDATE_ID=$( echo "${UPDATEJSON}" | jq '.result | .[0].update_id' )
# get the client_id for sending the messages to the created telegram bot
UPDATE_TYPE="message"
if [[ $( echo "${UPDATEJSON}" | jq '.result | .[0].message' ) = "null" ]]; then
  UPDATE_TYPE="my_chat_member"
fi

CHAT_ID=$( echo "${UPDATEJSON}" | jq ".result | .[0].${UPDATE_TYPE}.chat.id" )
# note, the condocambot is not very picky, the sender of the first message it sees, will be the owner
ADMIN_ID=$( echo "${UPDATEJSON}" | jq ".result | .[0].${UPDATE_TYPE}.from.id" )
ADMIN_IS_BOT=$( echo "${UPDATEJSON}" | jq ".result | .[0].${UPDATE_TYPE}.from.is_bot" )
ADMIN_FIRST_NAME=$( echo "${UPDATEJSON}" | jq ".result | .[0].${UPDATE_TYPE}.from.first_name" )
ADMIN_LANGUAGE_CODE=$( echo "${UPDATEJSON}" | jq ".result | .[0].${UPDATE_TYPE}.from.language_code" )

telegram.bot --bottoken "${BOT_TOKEN}" --chatid "${CHAT_ID}" --success --text "telegram.bot is installed successfully, continuing to install the rest of the system."

if [[ "${ARCH}" == "armv6l" ]]; then
	telegram.bot --bottoken "${BOT_TOKEN}" --chatid "${CHAT_ID}" --warning --text "You are trying to run **condocam.ai** on an **armv6l** based system, which is **not** properly supported.\n
	Installation will continue, but **people detection** will not be enabled, because **OpenCV** has no packages available for this system and you might experience problems with **Motion** itself.\n
	If you know how to fix these issue, please contribute to the project."
fi

# now we want to update the system and install packages
echo "updating the system"
waitForApt
sudo apt update
waitForApt
sudo apt full-upgrade -y
# arp-scan is needed by the presence detection of devices and fail2ban you add some security to the system
waitForApt
echo "sudo apt install -y arp-scan fail2ban"
sudo apt install -y arp-scan fail2ban

# write the condocambot.conf file
echo
echo "write the condocambot.conf file"
echo "BOT_TOKEN=${BOT_TOKEN}" | sudo tee "${CONDOCAMBOT_CONF}" #this call creates the file, the others append to it
echo "LAST_UPDATE_ID=${LAST_UPDATE_ID}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "CHAT_ID=${CHAT_ID}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "ADMIN_ID=${ADMIN_ID}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "ADMIN_IS_BOT=${ADMIN_IS_BOT}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "ADMIN_FIRST_NAME=${ADMIN_FIRST_NAME}" | sudo tee -a "${CONDOCAMBOT_CONF}"
echo "ADMIN_LANGUAGE_CODE=${ADMIN_LANGUAGE_CODE}" | sudo tee -a "${CONDOCAMBOT_CONF}"
# make sure that the condocambot.sh is using the created conf file
sudo sed -i "s/^CONF_FILE=.*/CONF_FILE=${CONDOCAMBOT_CONF//\//\\/}/" /boot/files/condocambot.sh
sudo sed -i "s/^CONDOCAM_IMAGE_FOLDER=.*/CONDOCAM_IMAGE_FOLDER=${CONDOCAM_IMAGE_FOLDER//\//\\/}/" /boot/files/condocambot.sh

telegram.bot --bottoken "${BOT_TOKEN}" --chatid "${CHAT_ID}" --success --text "system is apt updated, next step is to install motion and motionEye"

# just follow the guide on https://github.com/ccrisan/motioneye/wiki/Install-On-Raspbian to install motioneye

# install motion and all dependencies
echo "installing motion and all dependencies"
if [[ "${ARCH}" == "armv6l" ]]; then
	wget https://github.com/Motion-Project/motion/releases/download/release-4.4.0/bullseye_motion_4.4.0-1_armhf.deb
	sudo apt install -y ./bullseye_motion_4.4.0-1_armhf.deb
else
	wget https://github.com/Motion-Project/motion/releases/download/release-4.4.0/bullseye_motion_4.4.0-1_arm64.deb
	sudo apt install -y ./bullseye_motion_4.4.0-1_arm64.deb
fi
# Disable motion service, motionEye controls motion
sudo systemctl stop motion
sudo systemctl disable motion 

# motion did not create the log folder and then complained about missing permissions
# create the folder if it does not exist
motionLogDir="/var/log/motion"
if [[ ! -e ${motionLogDir} ]]; then
    sudo mkdir -p ${motionLogDir}
    #motion user should be in group motion
    sudo chown root:motion ${motionLogDir}
    #make read and writable for user and group, others read only
    sudo chmod 664 ${motionLogDir}
fi

echo "installing motioneye dependencies"
echo "sudo apt install -y libssl-dev libcurl4-openssl-dev libjpeg-dev libz-dev"
sudo apt install -y libssl-dev libcurl4-openssl-dev libjpeg-dev libz-dev
#sudo apt install -y python-pip python-dev libssl-dev libcurl4-openssl-dev libjpeg-dev libz-dev python-pil
# this part is getting ugly because motioneye requires the deprecated python2.7
# be sure to use python2.7 and make python link to python2
echo "sudo apt install -y python-is-python2 python-dev-is-python2"
sudo apt install -y python-is-python2 python-dev-is-python2
# get pip for python 2.7 which is no longer in the Raspberry Pi OS repositories
wget https://bootstrap.pypa.io/pip/2.7/get-pip.py
# install pip
sudo python get-pip.py
# install pillow, which is also no longer available in the Raspberry Pi OS repositories
sudo pip install pillow

echo "installing motioneye"
sudo pip install motioneye

# don't do this step from the installation guide, we do not want to use the default config
# sudo cp /usr/local/share/motioneye/extra/motioneye.conf.sample /etc/motioneye/motioneye.conf

# find all connected USB cameras and add them to motioneye
# Note: each camera creates two interfaces, the first one should be the video, the second one the meta data
v4l2-ctl --list-devices
USBCAMS=$( v4l2-ctl --list-devices | awk '/\(usb-/{getline; print}' )
echo "USB cameras:"
echo "${USBCAMS}"
# add all USBCAMS to motion and motioneye
CAMID=0
for CAM in $USBCAMS
do
	# get maximum resolution of CAM
	RESOLUTION=$( v4l2-ctl --list-formats-ext -d "${CAM}" | grep Size | cut -d " " -f3 | sort -u -n -tx -k1 -k2 | tail -1 )
	WIDTH=$(echo "${RESOLUTION}" | cut -f1 -dx)
	HEIGHT=$(echo "${RESOLUTION}" | cut -f2 -dx)
	echo "configuring ${CAM}"
	echo "resolution = ${RESOLUTION}"
	# creat config for CAM
	CAMID=$((CAMID+1))
	echo "camera name = Camera${CAMID}"
	## @id $CAMID
	sudo sed -i "s/@id .*/@id ${CAMID}/" /boot/files/template-camera.conf
	# set motion detection threshold to 1% of all pixels
	THRESH=$(echo "(${WIDTH}*${HEIGHT}*0.01)/1" | bc)
	# set motion detection max_threshold to 10% of all pixels
	MAX_THRESH=$(echo "(${WIDTH}*${HEIGHT}*0.1)/1" | bc)
	# set different values if WIDTH or HEIGHT is > 1000px
	if [[ ${WIDTH} -gt 1000 ]] || [[ ${HEIGHT} -gt 1000 ]] ; then
		THRESH=$(echo "(${WIDTH}*${HEIGHT}*0.003)/1" | bc)
		MAX_THRESH=$(echo "(${WIDTH}*${HEIGHT}*0.03)/1" | bc)
	fi
	# threshold $THRESH
	sudo sed -i "s/threshold .*/threshold ${THRESH}/" /boot/files/template-camera.conf
	# threshold_maximum $MAX_THRESH
	sudo sed -i "s/threshold_maximum .*/threshold_maximum ${MAX_THRESH}/" /boot/files/template-camera.conf
	# snapshot_filename Cam${CAMID}_%Y-%m-%d-%H-%M-%S
	sudo sed -i "s/snapshot_filename .*/snapshot_filename Cam${CAMID}_\%Y-\%m-\%d-\%H-\%M-\%S/" /boot/files/template-camera.conf
	# picture_filename Cam${CAMID}_%Y-%m-%d-%H-%M-%S
	sudo sed -i "s/picture_filename .*/picture_filename Cam${CAMID}_\%Y-\%m-\%d-\%H-\%M-\%S/" /boot/files/template-camera.conf
	# target_dir ${CONDOCAM_IMAGE_FOLDER}/Camera${CAMID}
	sudo sed -i "s/target_dir .*/target_dir ${CONDOCAM_IMAGE_FOLDER//\//\\/}\/Camera${CAMID}/" /boot/files/template-camera.conf
	# stream_port 808$CAMID
	sudo sed -i "s/stream_port .*/stream_port 808${CAMID}/" /boot/files/template-camera.conf
	# text_left Camera1
	sudo sed -i "s/text_left .*/text_left Camera${CAMID}/" /boot/files/template-camera.conf
	# videodevice $CAM, adjust the command for the / in the path $CAM
	sudo sed -i 's,videodevice .*,'"videodevice ${CAM}"',' "/boot/files/template-camera.conf"
	# camera_name Camera1
	sudo sed -i "s/camera_name .*/camera_name Camera${CAMID}/" /boot/files/template-camera.conf
	# height 1080
	sudo sed -i "s/height .*/height ${HEIGHT}/" /boot/files/template-camera.conf
	# width 1920
	sudo sed -i "s/width .*/width ${WIDTH}/" /boot/files/template-camera.conf
	# update all occurences of the motioneye.conf
	sudo sed -i "s/ \".*\/motioneye.conf\"/ \"${CONDOCAM_FOLDER//\//\\/}\/motioneye.conf\"/" /boot/files/template-camera.conf
	# copy the config to the motioneye folder
	echo "cp /boot/files/template-camera.conf \"${CONDOCAM_FOLDER}/camera-${CAMID}.conf\""
	sudo cp /boot/files/template-camera.conf "${CONDOCAM_FOLDER}/camera-${CAMID}.conf"

	# add CAM.config to motion.conf
	sudo bash -c "echo \"camera camera-${CAMID}.conf\" >> /boot/files/template-motion.conf"

done
echo "all cameras configured, copying config files to ${CONDOCAM_FOLDER}"
#move the conf files to the motioneye folder
echo "cp /boot/files/template-motion.conf ${CONDOCAM_FOLDER}/motion.conf"
sudo cp /boot/files/template-motion.conf "${CONDOCAM_FOLDER}/motion.conf"

#make sure the paths configured in motioneye.conf are consistent with the paths configured here
sudo sed -i "s/conf_path .*/conf_path ${CONDOCAM_FOLDER//\//\\/}/" "/boot/files/motioneye.conf"
sudo sed -i "s/media_path .*/media_path ${CONDOCAM_IMAGE_FOLDER//\//\\/}/" "/boot/files/motioneye.conf"
echo "cp /boot/files/motioneye.conf ${CONDOCAM_FOLDER}/motioneye.conf"
sudo cp /boot/files/motioneye.conf "${CONDOCAM_FOLDER}/motioneye.conf"
#echo "rm /boot/files/template-camera.conf"
#sudo rm /boot/files/template-camera.conf

if [[ "${ARCH}" == "armv6l" ]]; then
	telegram.bot --bottoken "${BOT_TOKEN}" --chatid "${CHAT_ID}" --success --text "motion and motionEye are now installed, skipping now OpenCV, which is not supported by your system.
	Without this, people detection will not work."
else
	telegram.bot --bottoken "${BOT_TOKEN}" --chatid "${CHAT_ID}" --success --text "motion and motionEye are now installed, next one up is OpenCV and its dependencies for enabling people detection"
	echo "install python3 dependecies for people detection with OpenCV"
	waitForApt
	echo "sudo apt install -y libatlas-base-dev python3-pip openexr libgtk-3-dev"
	sudo apt install -y libatlas-base-dev python3-pip openexr libgtk-3-dev
	# numpy only supports python3
	# make sure to use -U because numpy is already installed on Raspberry Pi OS but needs an update
	sudo pip3 install -U numpy opencv-utils opencv-python imutils watchdog filetype
fi

echo "Install motioneye.service to run at startup and start the motioneye server:"
ExecStart="/usr/local/bin/meyectl startserver -c \"${CONDOCAM_FOLDER}/motioneye.conf\""
sudo sed -i "s/ExecStart=.*/ExecStart=${ExecStart//\//\\/}/" /boot/files/motioneye.service
sudo cp /boot/files/motioneye.service "${SERVICE_FOLDER}/motioneye.service"

if [[ "${ARCH}" == "armv6l" ]]; then
	echo "Install condocam_detection.service, but not enable it to run at startup:"
else
	echo "Install condocam_detection.service to run at startup:"
fi
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

# reload the service deamons and start the newly installed services
sudo systemctl daemon-reload
sudo systemctl enable condocambot.service
#sudo systemctl start condocambot.service
sudo systemctl enable motioneye.service
#sudo systemctl start motioneye.service
if [[ "${ARCH}" != "armv6l" ]]; then
	sudo systemctl enable condocam_detection.service
	#sudo systemctl start condocam_detection.service
else
	telegram.bot --bottoken "${BOT_TOKEN}" --chatid "${CHAT_ID}" --warning --text "condocam_detection.service is not enabled. Compile **python-opencv** on your pi and enable the service manually."
fi


if $ENABLE_RASPAP; then
  #install raspap
  telegram.bot --bottoken "${BOT_TOKEN}" --chatid "${CHAT_ID}" --warning --text "I am installing now RaspAP, remember to secure this system after the setup is finished!"
  curl -sL https://install.raspap.com | bash -s -- --yes
fi

telegram.bot --bottoken "${BOT_TOKEN}" --chatid "${CHAT_ID}" --success --text "All packages are installed now, I am just doing some clean up and then I will be available for you at http://${HOSTNAME}:8765"

echo "remove autoinstalled packages" 
waitForApt
echo "sudo apt -y autoremove"
sudo apt -y autoremove

echo "add run /boot/thirdrun.sh command to cmdline.txt file for next reboot"
sudo sed -i '$s|$| systemd.run=/boot/thirdrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target\n|' /boot/cmdline.txt

#disable the service that started this script
sudo systemctl disable secondrun.service
echo "DONE secondrun.sh, rebooting the system"

sleep 2
sudo reboot
