#!/usr/bin/bash
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
# bash install_condocam.ai.sh ;
# or pass the path of the sdcard
# bash install_condocam.ai.sh /dev/mmcblk0 ;

#######################################
# Print error message.
# Globals:
#   None
# Arguments:
#   $1 = Error message
#   $2 = return code (optional, default 1)
# Outputs:
#   Prints an error message to stderr
#######################################
function error() {
    printf "%s\n" "${1}" >&2 ## Send message to stderr.
    exit "${2-1}" ## Return a code specified by $2, or 1 by default.
}

#######################################
# Checks if internet can be accessed
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
    #wget should be available on most Linux distributions
    if wget -q --spider http://google.com; then
      break # we are online
    else
      #we are still offline
      echo ["$(date +%T)"] waiting for internet access ...
      sleep 1
    fi
  done
}

echo 
echo "=============================================================="
echo " WARNING  WARNING  WARNING  WARNING  WARNING  WARNING  WARNING"
echo "=============================================================="
echo 
echo "This script will make use of dd to flash a SD card. This has the potential to break your system."
echo "By continuing, you confirm that you know what you are doing and that you will double check every step of this script"
read -rp "press Y to continue " -n 1 -s
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi 

echo 
echo "=============================================================="
echo " initializing script"
echo "=============================================================="
echo 

# SD card path
if [ "${1}" ]; then
  SD_CARD_PATH="${1}"
else
  SD_CARD_PATH="/dev/mmcblk0"
fi

RPI_IMAGE_URL="https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2022-04-07/2022-04-04-raspios-bullseye-arm64-lite.img.xz"
USE_LATEST_RASPI_OS=false

RASPI_OS_TYPE="lite" # or "full"
RASPI_CPU_TYPE="arm64" # or "armhf

RASPI_OS_ID="raspios_${RASPI_OS_TYPE}_${RASPI_CPU_TYPE}"

#get HOSTNAME for raspberry pi from firstrun.sh
RPI_HOST_NAME=$( grep "^HOSTNAME=" condocam-pi/firstrun.sh | cut -d "=" -f 2 )
#get USERNAME for raspberry pi from firstrun.sh
RPI_USER_NAME=$( grep "^USERNAME=" condocam-pi/firstrun.sh | cut -d "=" -f 2 )

echo "SD_CARD_PATH = ${SD_CARD_PATH}"
echo "RPI_HOST_NAME = ${RPI_HOST_NAME}"

echo 
echo "=============================================================="
echo " check SD card path"
echo "=============================================================="
echo 

echo "please make sure that your SD card is inserted to this computer"
echo "press any key to continue ..."
read -rn 1 -s
echo

DISKNAME=$( echo "${SD_CARD_PATH}" | rev | cut -d "/" -f 1 | rev )

if ! lsblk | grep -q "${DISKNAME}" ; then
  error "FAIL: Disk with name ${DISKNAME} not found, exiting"
fi

echo "CHECK OK: Disk with name ${DISKNAME} exists"

if [ -b "${SD_CARD_PATH}" ]; then
  echo "CHECK OK: Path ${SD_CARD_PATH} exists"
else
  error "FAIL: SD card at ${SD_CARD_PATH} not found, exiting"
fi

#show available disks for final check
echo "=============================================================="
echo " available disks"
echo "=============================================================="
echo "lsblk | grep disk"
lsblk | grep disk
echo

echo "This script will dd an image of Raspberry Pi OS over whatever is located at ${SD_CARD_PATH}"
echo "Please check the above listing and confirm that you want to write the image on $DISKNAME"
read -rp "Press Y to continue" -n 1 -s
echo
if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
    exit 1
fi 

echo "USE_LATEST_RASPI_OS==${USE_LATEST_RASPI_OS}"
if [[ ${USE_LATEST_RASPI_OS} == true ]] ; then
  echo 
  echo "=============================================================="
  echo " get URL of latest Raspberry Pi OS 64bit image"
  echo "=============================================================="
  echo 

  echo "get rasbian os information data from server";
  rm operating-systems-categories.json
  wget https://downloads.raspberrypi.org/operating-systems-categories.json

  RPI_IMAGE_URL=$( <operating-systems-categories.json grep "${RASPI_OS_ID}" | grep urlHttp | sed -e 's/.*\: \"\(.*\)\".*/\1/' )
  echo "latest image URL is: ${RPI_IMAGE_URL}"
fi
RPI_IMAGE_HASH_URL="${RPI_IMAGE_URL}.sha256"

echo 
echo "=============================================================="
echo " download and check Raspberry Pi OS"
echo "=============================================================="
echo 

RPI_IMAGE_XZ=$(basename "${RPI_IMAGE_URL}")
RPI_IMAGE_HASH=$(basename "${RPI_IMAGE_HASH_URL}")
RPI_IMAGE="${RPI_IMAGE_XZ//.xz/}"

if [ -f "${RPI_IMAGE}" ]; then
  echo "${RPI_IMAGE} file found. Skipping download."
elif [ -f "${RPI_IMAGE_XZ}" ]; then
  echo "${RPI_IMAGE_XZ} file found. Skipping download."
else
  echo "downloading Raspberry Pi OS image from server. please wait ..."
  rm   "${RPI_IMAGE_XZ}.downloading"
  wget "${RPI_IMAGE_URL}" -O "${RPI_IMAGE_XZ}.downloading"
  mv   "${RPI_IMAGE_XZ}.downloading" "${RPI_IMAGE_XZ}"

  echo "downloading hash file for image file from server. please wait ..."
  rm "${RPI_IMAGE_HASH}"
  wget "${RPI_IMAGE_HASH_URL}"

  echo "checking hash value of image file"
  HASH_OK=$( sha256sum -c "${RPI_IMAGE_HASH}" | grep "${RPI_IMAGE_XZ}: OK" )
  if [ -z "${HASH_OK}" ]; then
    error "hash does not match, aborting"
  else
    echo "hash is ok"
  fi
fi

echo 
echo "=============================================================="
echo " extract image file"
echo "=============================================================="
echo 

echo "extract the Raspberry Pi OS image"
if [ -f "${RPI_IMAGE}" ]; then
  echo "file found, skip the extract"
else
  echo "extracting file. please wait a few minutes ..."
  echo "unxz ${RPI_IMAGE_XZ}"
  unxz "${RPI_IMAGE_XZ}"
fi

echo 
echo "=============================================================="
echo " write image to SD card"
echo "=============================================================="
echo 

echo "unmount SD card $DISKNAME"
#echo "press any key to continue..."
#read -rn 1 -s

mount | grep "${DISKNAME}" | cut -d " " -f 3 | while read -r line ; do
    echo "sudo umount ${line}"
    sudo umount "${line}"
done
echo

echo "SD card used for the following operations is located at: ${SD_CARD_PATH}"
echo "press any key to continue..."
read -rn 1 -s
echo

echo "wipe SD card: sudo wipefs -a ${SD_CARD_PATH}"
#echo "press any key to continue..."
#read -rn 1 -s
sudo wipefs -a "${SD_CARD_PATH}"
echo

echo "write image file to SD card: sudo dd bs=8M if=${RPI_IMAGE} of=${SD_CARD_PATH} status=progress"
#echo "press any key to continue..."
#read -rn 1 -s
#echo "writing image to SD card ..."
sudo dd bs=8M if="${RPI_IMAGE}" of="${SD_CARD_PATH}" status=progress
echo

echo 
echo "=============================================================="
echo " mount SD card"
echo "=============================================================="
echo 
sleep 3 #give the system some time to detect the new formatted disks

echo "mount SD card"
UUID=$( lsblk -f | grep "${DISKNAME}" | grep boot | rev | xargs | cut -d " " -f1 | rev )
echo "udisksctl mount -b \"/dev/disk/by-uuid/${UUID}\""
udisksctl mount -b "/dev/disk/by-uuid/${UUID}"
RPI_PATH=$( mount | grep "${DISKNAME}" | cut -d " " -f 3 )

#echo "press any key to continue..."
#read -rn 1 -s
#echo

echo 
echo "=============================================================="
echo " setting root=PARTUUID in cmdline.txt"
echo "=============================================================="
echo 

echo "the UUID of the root partition might have changed for the downloaded image. Updating the entry in cmdline.txt"
PARTUUID=$( sudo blkid | grep rootfs | grep -oP '(?<=PARTUUID=\").*(?=\")' )
echo "set PARTUUID=$PARTUUID for rootfs in condocam-pi/cmdline.txt"
sed -i "s/\(.*PARTUUID=\)[^ ]*\( .*\)/\1$PARTUUID\2/" condocam-pi/cmdline.txt

echo 
echo "=============================================================="
echo " copy files to SD card"
echo "=============================================================="
echo 

echo "copy files to ${RPI_PATH}"
echo "cp -r condocam-pi/* ${RPI_PATH}"
cp -r condocam-pi/* "${RPI_PATH}"
echo

#echo "press any key to continue..."
#read -rn 1 -s
#echo

echo 
echo "=============================================================="
echo " enable hdmi_force_hotplug"
echo "=============================================================="
echo 
# enable hdmi_force_hotplug in the Rapberry Pi config.txt
# this is quite helpful if you want to connect a display for some reason to a running condocam.ai. E.g. for debugging problems
echo "sed -i \"/hdmi_force_hotplug=/c\hdmi_force_hotplug=1\" \"${RPI_PATH}/config.txt\""

sed -i "/hdmi_force_hotplug=/c\hdmi_force_hotplug=1" "${RPI_PATH}/config.txt"

echo 
echo "=============================================================="
echo " setup telegram bot!"
echo "=============================================================="
echo 

echo "BEFORE you continue, send /start to your telegram bot!"
echo "This script will get stuck in an endless loop, if you don't do it ..."
echo 
#######################################
# Try to obtain the chat_id from messages with command /start.
#######################################
BOT_TOKEN=$( grep "^BOT_TOKEN=" condocam-pi/firstrun.sh | cut -d "=" -f 2 )
if [[ ! ${BOT_TOKEN} =~ ^[0-9]{8,10}:[0-9a-zA-Z_-]{35}$ ]]; then
  error "\"${BOT_TOKEN}\" does not seem to be a valid bot token. Please correct your entry in condocam-pi/firstrun.sh."
fi
CURL_RESULT=$(curl --silent --insecure "https://api.telegram.org/bot${BOT_TOKEN}/getMe")
echo "${CURL_RESULT}" | grep '"ok":true' > /dev/null || { error "Your bot token could not be validated. Reason: ${CURL_RESULT}. Please correct your entry in condocam-pi/firstrun.sh"; }

update_json=""
while [[ -z "${CHAT_ID}" ]] || [[ -z "${ADMIN_ID}" ]] || [[ -z "${ADMIN_IS_BOT}" ]] || [[ -z "${ADMIN_FIRST_NAME}" ]] || [[ -z "${ADMIN_LANGUAGE_CODE}" ]] || [[ -z "${LAST_UPDATE_ID}" ]]; do
  update_json=$( telegram.bot --get_updates --bottoken "${BOT_TOKEN}" )
 	UPDATE_TYPE="message" # direct message
	if [[ $( echo "${UPDATEJSON}" | jq '.result | .[0].message' ) = "null" ]]; then
	  UPDATE_TYPE="my_chat_member" # message via group
	fi

  CHAT_ID=$( echo "${update_json}" | jq ".result | [.[].${UPDATE_TYPE} | select(.text==\"/start\")][-1].chat.id" )
  ADMIN_ID=$( echo "${update_json}" | jq ".result | [.[].${UPDATE_TYPE} | select(.text==\"/start\")][-1].from.id" )
  ADMIN_IS_BOT=$( echo "${update_json}" | jq ".result | [.[].${UPDATE_TYPE} | select(.text==\"/start\")][-1].from.is_bot" )
  ADMIN_FIRST_NAME=$( echo "${update_json}" | jq ".result | [.[].${UPDATE_TYPE} | select(.text==\"/start\")][-1].from.first_name" )
  ADMIN_LANGUAGE_CODE=$( echo "${update_json}" | jq ".result | [.[].${UPDATE_TYPE} | select(.text==\"/start\")][-1].from.language_code" )
  LAST_UPDATE_ID=$( echo "${update_json}" | jq ".result | [select(.[].${UPDATE_TYPE}.text==\"/start\")][] | .[-1].update_id" )
  
  if [[ -z "${CHAT_ID}" ]] || [[ -z "${ADMIN_ID}" ]] || [[ -z "${LAST_UPDATE_ID}" ]]; then
    echo "please send /start to bot #${BOT_TOKEN}, I am still waiting ..."
    sleep 10
  else #TODO check the globals for these files
    printf "CHAT_ID: %s, ADMIN_ID: %s, LAST_UPDATE_ID: %s\n" "$CHAT_ID" "$ADMIN_ID" "$LAST_UPDATE_ID"
    sed -i "s/^CHAT_ID=.*/CHAT_ID=$CHAT_ID/" condocam-pi/secondrun.sh
    sed -i "s/^ADMIN_ID=.*/ADMIN_ID=$ADMIN_ID/" condocam-pi/secondrun.sh
    sed -i "s/^ADMIN_IS_BOT=.*/ADMIN_IS_BOT=$ADMIN_IS_BOT/" condocam-pi/secondrun.sh
    sed -i "s/^ADMIN_FIRST_NAME=.*/ADMIN_FIRST_NAME=$ADMIN_FIRST_NAME/" condocam-pi/secondrun.sh
    sed -i "s/^ADMIN_LANGUAGE_CODE=.*/ADMIN_LANGUAGE_CODE=$ADMIN_LANGUAGE_CODE/" condocam-pi/secondrun.sh
    sed -i "s/^LAST_UPDATE_ID=.*/LAST_UPDATE_ID=$LAST_UPDATE_ID/" condocam-pi/secondrun.sh
    break
  fi
done

echo 
echo "=============================================================="
echo " unmount SD card"
echo "=============================================================="
echo 

echo "unmount SD card"
sudo umount "${RPI_PATH}"
echo "all work is done. Please insert the SD card into your raspberry pi"
echo "NOTE: when starting up, your raspberry pi should reboot 4 times until all setup work is finished and condocam.ai is up and running. Be patient!"

echo
echo "///////////////////////////////////////////////////////////////"
echo
echo "               ssh -x ${RPI_USER_NAME}@${RPI_HOST_NAME}.local"
echo "               http://${RPI_HOST_NAME}:8765/"
echo
echo "///////////////////////////////////////////////////////////////"
echo
exit;
