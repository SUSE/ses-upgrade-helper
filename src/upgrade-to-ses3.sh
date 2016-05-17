#!/bin/bash
# 
# SES 2.1 -> 3.0 upgrade helper script
#
# Copyright (c) 2016, SUSE LLC
# All rights reserved.
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#

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

out_red () {
    local msg=$1
    printf "${txtbold}${txtred}${msg}${txtnorm}"
}

out_white () {
    local msg=$1
    printf "${txtbold}${txtwhite}${msg}${txtnorm}"
}

out_green () {
    local msg=$1
    printf "${txtbold}${txtgreen}${msg}${txtnorm}"
}

out_err () {
    local msg=$1
    out_red "ERROR: ${msg}"
}

out_info () {
    local msg="$1"
    out_white "INFO: ${msg}"
}

# Be sure that the user wants to abort the upgrade process.
maybe_abort () {
    local choice=""

    out_red "Are you sure you want to abort? - y/N (N): "
    read choice
    case $choice in
        [Yy] | [Yy][Ee][Ss])
            out_red "Aborted.\n"
            exit
            ;;
        [Nn] | [Nn][Oo] | "")
            :
            ;;
        *)
            :
            ;;
    esac
}

# Returns 0 on Y and 1 on N.
get_permission () {
    local msg=$1
    local choice=""

    if [ -z "$msg" ]
    then
        msg="Run this operation?"
    fi
    msg="$msg - Y/N/Abort (Y)"

    while [ 1 ]
    do
        printf "$msg: "
        read choice
        case $choice in
            [Yy] | [Yy][Ee][Ss] | "")
                return 0
                ;;
            [Nn] | [Nn][Oo])
                return 1
                ;;
            [Aa] | [Aa][Bb][Oo][Rr][Tt])
                return 2
                ;;
            *)
                out_err "Invalid input.\n"
                ;;
        esac
    done
}

# Wrapper to query user whether they really want to run a particular function.
# If empty $msg parameter passed, we will use the get_permission() default.
# If empty $desc parameter passed, no function description will be output.
run_func () {
    if [ "$#" -lt 3 ]
    then
        out_err "$FUNCNAME: Too few arguments."
        exit 1
    fi

    local msg=$1
    shift
    local desc=$1
    shift
    local func=$1
    shift

    out_green "\n${func}(): "
    out_white "${desc}\n"

    get_permission "$msg"

    case $? in
        0)
            # Run the function $func.
            "$func" "$@"
            if [ "$?" -ne 0 ]
            then
                # TODO: We hit some problem... Handle it here, or let each operation
                #       handle itself, or...?
                :
            fi
            ;;
        1)
            # No-op. User does not wish to run $func.
            :
            ;;
        2)
            # User aborted the process
            maybe_abort
            ;;
        *)
            # No-op. Do nothing.
            :
            ;;
    esac
}


# ------------------------------------------------------------------------------
# Operations
# ------------------------------------------------------------------------------
set_crush_tunables () {
    printf "Inside $FUNCNAME\n"
}

stop_ceph_daemons () {
    printf "Inside $FUNCNAME\n"
}

rename_ceph_user_and_group () {
    printf "Inside $FUNCNAME\n"
}

disable_radosgw_services () {
    printf "Inside $FUNCNAME\n"
}

disable_restart_on_update () {
    printf "Inside $FUNCNAME\n"
}

zypper_dup () {
    printf "Inside $FUNCNAME\n"
}

restore_original_restart_on_update () {
    printf "Inside $FUNCNAME\n"
}

chown_var_lib_ceph () {
    printf "Inside $FUNCNAME\n"
}

enable_radosgw_services () {
    printf "Inside $FUNCNAME\n"
}

finish () {
    printf "Inside $FUNCNAME\n"
}


# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------

out_green "SES2.X to SES3 Upgrade${txtnorm}\n"

# Script needs to be run as root.
if [ "$EUID" -ne 0 ]
then
    out_err "Please run this script as root."
    exit 1
fi

# run_func "permission_msg" "function_description" "function_name" ["function_args" ...]
run_func "" "Set CRUSH Tunables" "set_crush_tunables"
run_func "" "Stop Ceph Daemons" "stop_ceph_daemons"
run_func "" "Rename Ceph User and Group" "rename_ceph_user_and_group"
run_func "" "Disable Existing RADOSGW Services (Naming Change)" "disable_radosgw_services"
run_func "" "Disable CEPH_AUTO_RESTART_ON_UPGRADE Sysconfig Option" "disable_restart_on_update"
run_func "" "Perform Distribution Update" "zypper_dup"
run_func "" "Restore CEPH_AUTO_RESTART_ON_UPGRADE Sysconfig Option" "restore_original_restart_on_update"
run_func "" "Change Ownership of /var/lib/ceph" "chown_var_lib_ceph"
run_func "" "Re-Enable Previously Disabled RADOSGW Services with Correct Naming Convention" "enable_radosgw_services"
run_func "" "Finish Up" "finish"

printf "\n${txtbold}${txtgreen}SES2.X to SES3 Upgrade Completed${txtnorm}\n\n"
