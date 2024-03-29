#!/bin/bash

# Copyright (c) 2024, The beep-projects contributors
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
# This script will clone the condocam.ai repo and guide you through the configuration
# steps to flash the project onto a sd card.
# For a full description see https://github.com/beep-projects/condocam.ai/readme.md

#######################################
# print an error message and exit with given code.
# Globals:
#   None
# Arguments:
#   $1 the error message to print
#   $2 optional exit code
# Outputs:
#   Prints error message to stdout
#   returns with exit code if given
#######################################
function error {
    printf "%s\n" "${1}" >&2 ## Send message to stderr.
    exit "${2-1}" ## Return a code specified by $2, or 1 by default.
}

mkdir temp
cd temp || error "temp was not created"
#make sure there is no old stuff present
if [[ -d "condocam.ai" ]]; then
  rm -rf "condocam.ai"
fi
git clone https://github.com/beep-projects/condocam.ai
cd condocam.ai || error "git clone failed"

read -rp "Enter hostname for your pi: " HOSTNAME
sed -i "s/^HOSTNAME=.*/HOSTNAME=${HOSTNAME}/" condocam-pi/firstrun.sh

read -rp "Enter username for the default user on your pi: " USERNAME
sed -i "s/^USERNAME=.*/USERNAME=${USERNAME}/" condocam-pi/firstrun.sh

read -rp "Enter password for the default user on your pi: " PASSWORD
mkpasswd "${PASSWORD}" --method=SHA-256 -S "beepprojects" | (read -r PWD && PWD=$(printf '%s\n' "$PWD" | sed 's/[[\.*^$/]/\\&/g') && sed -i "s/^PASSWD=.*/PASSWD='${PWD}'/" condocam-pi/firstrun.sh)

read -rp "Enter the SSID of your WiFi: " SSID
sed -i "s/^SSID=.*/SSID=${SSID}/" condocam-pi/firstrun.sh
wpa_passphrase "${SSID}" | grep "\spsk" | cut -d '=' -f 2 | (read -r PWD && PWD=$(printf '%s\n' "$PWD" | sed 's/[[\.*^$/]/\\&/g') && sed -i "s/^WPA_PASSPHRASE=.*/WPA_PASSPHRASE=${PWD}/" condocam-pi/firstrun.sh)

read -rp "Enter the api token of your bot: " BOT_TOKEN
sed -i "s/^BOT_TOKEN=.*/BOT_TOKEN=${BOT_TOKEN}/" condocam-pi/firstrun.sh


ENABLE_ENC28J60=false && sed -i "s/^ENABLE_ENC28J60=.*/ENABLE_ENC28J60=${ENABLE_ENC28J60}/" condocam-pi/firstrun.sh
USE_LATEST_RASPI_OS=false && sed -i "s/^USE_LATEST_RASPI_OS=.*/USE_LATEST_RASPI_OS=${USE_LATEST_RASPI_OS}/" ./install_condocam.ai.sh

./install_condocam.ai.sh