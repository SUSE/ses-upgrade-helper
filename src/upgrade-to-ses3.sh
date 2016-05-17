#!/bin/bash
# 
# Copyright (c) 2016, SUSE LLC
# All rights reserved.
# 
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
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# ==============================================================================
# upgrade-to-ses3.sh
# ------------------
#
# Sets out to upgrade a SES2/2.1 Installation to SES3.
#
# ==============================================================================

# Various globals
scriptname=$(basename "$0")
upgrade_doc="http://docserv.suse.de/documents/Storage_3/ses-admin/single-html/#ceph.upgrade.2.1to3"
usage="usage: $scriptname\n"
txtbold=$(tput bold)
txtnorm=$(tput sgr0)
txtred=$(tput setaf 1)
txtgreen=$(tput setaf 2)
txtwhite=$(tput setaf 7)

out_err () {
    local msg=$1
    echo "${txtbold}${txtred}ERROR: ${msg}${txtnorm}"
}

out_info () {
    local msg="$1"
    echo "${txtbold}${txtwhite}INFO: %{msg}${txtnorm}"
}

# Returns 0 on Y and 1 on N.
get_permission () {
    local msg=$1
    local choice=""

    if [ -z "$msg" ]
    then
        msg="Perform the aforementioned action?"
    fi
    msg="$msg (Y/N):"

    while [ 1 ]
    do
        echo "$msg"
        read choice
        case $choice in
            [Yy] | [Yy][Ee][Ss])
                return 0
                ;;
            [Nn] | [Nn][Oo])
                return 1
                ;;
            *)
                out_err "Invalid input."
                ;;
        esac
    done
}

# Wrapper to query user whether they really want to run a particular function.
# If empty $msg parameter passed, we will use the get_permission() default.
run_func () {
    if [ "$#" -lt 2 ]
    then
        out_err "$FUNCNAME: Too few arguments."
        exit 1
    fi

    local msg=$1
    shift
    local func=$1
    shift

    get_permission "$msg"
    if [ "$?" -eq 0 ]
    then
        "$func" "$@"
    fi

    if [ "$?" -ne 0 ]
    then
        # TODO: We hit some problem... Handle it here, or let each operation
        #       handle itself, or...?
    fi
}


# ------------------------------------------------------------------------------
# Operations
# ------------------------------------------------------------------------------
set_crush_tunables () {
}

stop_ceph_daemons () {
}

rename_ceph_user_and_group () {
}

disable_radosgw_services () {
}

disable_restart_on_update () {
}

zypper_dup () {
}

restore_original_restart_on_update () {
}

chown_var_lib () {
}

enable_radosgw_services () {
}

finish () {
}

# 
# main
# ------------------------------------------------------------------------------

printf "${txtbold}${txtgreen}SES2.X to SES3 Upgrade${txtnorm}\n\n"

# Script needs to be run as root.
if [ "$EUID" -ne 0 ]
then
    out_err "Please run this script as root."
    exit 1
fi
