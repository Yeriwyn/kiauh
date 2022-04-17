#!/bin/bash

#=======================================================================#
# Copyright (C) 2020 - 2022 Dominik Willner <th33xitus@gmail.com>       #
#                                                                       #
# This file is part of KIAUH - Klipper Installation And Update Helper   #
# https://github.com/th33xitus/kiauh                                    #
#                                                                       #
# This file may be distributed under the terms of the GNU GPLv3 license #
#=======================================================================#

set -e

#=================================================#
#=============== INSTALL OCTOPRINT ===============#
#=================================================#

function octoprint_systemd() {
  local services
  services=$(find "${SYSTEMD}" -maxdepth 1 -regextype posix-extended -regex "${SYSTEMD}/octoprint(-[^0])?[0-9]*.service")
  echo "${services}"
}

function octoprint_setup_dialog(){
  status_msg "Initializing OctoPrint installation ..."

  local klipper_count
  klipper_count=$(klipper_systemd | wc -w)
  top_border
  if [ -f "${INITD}/klipper" ] || [ -f "${SYSTEMD}/klipper.service" ]; then
    printf "|${green}%-55s${white}|\n" " 1 Klipper instance was found!"
  elif [ "${klipper_count}" -gt 1 ]; then
    printf "|${green}%-55s${white}|\n" " ${klipper_count} Klipper instances were found!"
  else
    echo -e "| ${yellow}INFO: No existing Klipper installation found!${default}         |"
  fi
  echo -e "| Usually you need one OctoPrint instance per Klipper   |"
  echo -e "| instance. Though you can install as many as you wish. |"
  bottom_border

  local count
  while [[ ! (${count} =~ ^[1-9]+((0)+)?$) ]]; do
    read -p "${cyan}###### Number of OctoPrint instances to set up:${default} " count
    if [[ ! (${count} =~ ^[1-9]+((0)+)?$) ]]; then
      error_msg "Invalid Input!\n"
    else
      echo
      while true; do
        read -p "${cyan}###### Install ${count} instance(s)? (Y/n):${default} " yn
        case "${yn}" in
          Y|y|Yes|yes|"")
            select_msg "Yes"
            status_msg "Installing ${count} OctoPrint instance(s) ... \n"
            octoprint_setup "${count}"
            break;;
          N|n|No|no)
            select_msg "No"
            error_msg "Exiting OctoPrint setup ...\n"
            break;;
          *)
            error_msg "Invalid Input!\n";;
        esac
      done
    fi
  done
}

function octoprint_setup(){
  local instances="${1}"
  ### check and install all dependencies
  dep=(
    git
    wget
    python-pip
    python-dev
    libyaml-dev
    build-essential
    python-setuptools
    python-virtualenv
  )
  dependency_check "${dep[@]}"

  ### check for tty and dialout usergroups and add reboot permissions
  check_usergroups
  add_reboot_permission

  ### install octoprint
  install_octoprint

  ### set up instances
  if [ "${instances}" -eq 1 ]; then
    create_single_octoprint_instance
  else
    create_multi_octoprint_instance "${instances}"
  fi

  ### step 6: enable and start all instances
  do_action_service "enable" "octoprint"
  do_action_service "start" "octoprint"

  ### confirm message
  [ "${instances}" -eq 1 ] && confirm_msg="OctoPrint has been set up!"
  [ "${instances}" -gt 1 ] && confirm_msg="${instances} OctoPrint instances have been set up!"
  print_confirm "${confirm_msg}"
  print_op_ip_list "${instances}"
}

function install_octoprint(){
  ### create and activate the virtualenv
  [ ! -d "${OCTOPRINT_ENV}" ] && mkdir -p "${OCTOPRINT_ENV}"
  status_msg "Installing python virtual environment..."
  cd "${OCTOPRINT_ENV}" && virtualenv --python=python3 venv
  ### activate virtualenv
  source venv/bin/activate
  status_msg "Installing OctoPrint ..."
  pip install pip --upgrade
  pip install --no-cache-dir octoprint
  ok_msg "Download complete!"
  ### leave virtualenv
  deactivate
}

function create_config_yaml(){
  local basedir=${1} tmp_printer=${2} restart_cmd=${3}

  /bin/sh -c "cat > ${basedir}/config.yaml" << CONFIGYAML
serial:
    additionalPorts:
    - ${tmp_printer}
    disconnectOnErrors: false
    port: ${tmp_printer}
server:
    commands:
        serverRestartCommand: ${restart_cmd}
        systemRestartCommand: sudo shutdown -r now
        systemShutdownCommand: sudo shutdown -h now
CONFIGYAML
}

function create_single_octoprint_instance(){
  local port=5000
  local basedir="${HOME}/.octoprint"
  local tmp_printer="/tmp/printer"
  local config_yaml="${basedir}/config.yaml"
  local restart_cmd="sudo service octoprint restart"

  status_msg "Creating OctoPrint instance ..."
  sudo /bin/sh -c "cat > ${SYSTEMD}/octoprint.service" << OCTOPRINT
[Unit]
Description=Starts OctoPrint on startup
After=network-online.target
Wants=network-online.target

[Service]
Environment="LC_ALL=C.UTF-8"
Environment="LANG=C.UTF-8"
Type=simple
User=${USER}
ExecStart=${OCTOPRINT_ENV}/venv/bin/octoprint --basedir ${basedir} --config ${config_yaml} --port=${port} serve

[Install]
WantedBy=multi-user.target
OCTOPRINT

  ### create the config.yaml
  if [ ! -f "${basedir}/config.yaml" ]; then
    status_msg "Creating config.yaml ..."
    [ ! -d "${basedir}" ] && mkdir "${basedir}"
    create_config_yaml "${basedir}" "${tmp_printer}" "${restart_cmd}"
    ok_msg "Config created!"
  fi
}

function create_multi_octoprint_instance(){
  local i=1 port=5000 instances=${1}
  while [ "${i}" -le "${instances}" ]; do
    ### multi instance variables
    local basedir="${HOME}/.octoprint-${i}"
    local tmp_printer="/tmp/printer-${i}"
    local config_yaml="${basedir}/config.yaml"
    local restart_cmd="sudo service octoprint-${i} restart"

    ### create instance
    status_msg "Creating instance #${i} ..."
    sudo /bin/sh -c "cat > ${SYSTEMD}/octoprint-${i}.service" << OCTOPRINT
[Unit]
Description=Starts OctoPrint instance ${instances} on startup
After=network-online.target
Wants=network-online.target

[Service]
Environment="LC_ALL=C.UTF-8"
Environment="LANG=C.UTF-8"
Type=simple
User=${USER}
ExecStart=${OCTOPRINT_ENV}/venv/bin/octoprint --basedir ${basedir} --config ${config_yaml} --port=${port} serve

[Install]
WantedBy=multi-user.target
OCTOPRINT

    ### create the config.yaml
    if [ ! -f "${basedir}/config.yaml" ]; then
      status_msg "Creating config.yaml for instance #${i}..."
      [ ! -d "${basedir}" ] && mkdir "${basedir}"
      create_config_yaml "${basedir}" "${tmp_printer}" "${restart_cmd}"
      ok_msg "Config #${i} created!"
    fi

    ### enable instance
    sudo systemctl enable "octoprint-${i}.service"
    ok_msg "OctoPrint instance ${i} created!"

    ### launching instance
    status_msg "Launching OctoPrint instance ${i} ..."
    sudo systemctl start "octoprint-${i}"

    i=$((i+1))
    port=$((port+1))
  done
}

function add_reboot_permission(){
  #create a backup if file already exists
  if [ -f /etc/sudoers.d/octoprint-shutdown ]; then
    sudo mv /etc/sudoers.d/octoprint-shutdown /etc/sudoers.d/octoprint-shutdown.old
  fi
  #create new permission file
  status_msg "Add reboot permission to user '${USER}' ..."
  cd "${HOME}" && echo "${USER} ALL=NOPASSWD: /sbin/shutdown" > octoprint-shutdown
  sudo chown 0 octoprint-shutdown
  sudo mv octoprint-shutdown /etc/sudoers.d/octoprint-shutdown
  ok_msg "Permission set!"
}

function print_op_ip_list(){
  local ip instances="${1}" i=1 port=5000
  ip=$(hostname -I | cut -d" " -f1)
  while [ "${i}" -le "${instances}" ] ; do
    echo -e "   ${cyan}● Instance ${i}:${white} ${ip}:${port}"
    port=$((port+1))
    i=$((i+1))
  done && echo
}

#=================================================#
#=============== REMOVE OCTOPRINT ================#
#=================================================#

function remove_octoprint(){
  ###remove all octoprint services
  [ -z "$(octoprint_systemd)" ] && return
  status_msg "Removing Moonraker Systemd Services ..."
  for service in $(octoprint_systemd | cut -d"/" -f5)
  do
    status_msg "Removing ${service} ..."
    sudo systemctl stop "${service}"
    sudo systemctl disable "${service}"
    sudo rm -f "${SYSTEMD}/${service}"
    ok_msg "Done!"
  done
  ### reloading units
  sudo systemctl daemon-reload
  sudo systemctl reset-failed

  ### remove sudoers file
  if [ -f /etc/sudoers.d/octoprint-shutdown ]; then
    sudo rm -rf /etc/sudoers.d/octoprint-shutdown
  fi

  ### remove OctoPrint directory
  if [ -d "${HOME}/OctoPrint" ]; then
    status_msg "Removing OctoPrint directory ..."
    rm -rf "${HOME}/OctoPrint" && ok_msg "Directory removed!"
  fi

  ###remove .octoprint directories
  if ls -d "${HOME}"/.octoprint* 2>/dev/null 1>&2; then
    for folder in $(ls -d ${HOME}/.octoprint*)
    do
      status_msg "Removing ${folder} ..." && rm -rf "${folder}" && ok_msg "Done!"
    done
  fi

  ### remove octoprint_port from ~/.kiauh.ini
  sed -i "/^octoprint_port=/d" "${INI_FILE}"

  print_confirm "OctoPrint successfully removed!"
}

#=================================================#
#=============== OCTOPRINT STATUS ================#
#=================================================#

function octoprint_status(){
  local sf_count status
  sf_count="$(octoprint_systemd | wc -w)"

  ### remove the "SERVICE" entry from the data array if a moonraker service is installed
  local data_arr=(SERVICE "${OCTOPRINT_DIR}")
  [ "${sf_count}" -gt 0 ] && unset "data_arr[0]"

  ### count+1 for each found data-item from array
  local filecount=0
  for data in "${data_arr[@]}"; do
    [ -e "${data}" ] && filecount=$(("${filecount}" + 1))
  done

  if [ "${filecount}" == "${#data_arr[*]}" ]; then
    status="$(printf "${green}Installed: %-5s${white}" "${sf_count}")"
  elif [ "${filecount}" == 0 ]; then
    status="${red}Not installed!${white}  "
  else
    status="${yellow}Incomplete!${white}     "
  fi
  echo "${status}"
}