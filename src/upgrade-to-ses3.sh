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

# Function arrays. Since bash can't do multidimensional associate arrays, this
# seemed like a decent fallback.
func_names=() # Array that will contain function names.
func_descs=() # Array that will contain corresponding function descriptions.
funcs_done=() # Array that will whether corresponding functions have completed

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
confirm_abort () {
    local choice=""

    while [ 1 ]
    do
        out_red "Are you sure you want to abort? - y/N (N): "
        read choice
        case $choice in
            [Yy] | [Yy][Ee][Ss])
                return 0
                ;;
            [Nn] | [Nn][Oo] | "")
                return 1
                ;;
            *)
                out_err "Invalid input.\n"
                ;;
        esac
    done
}

output_incomplete_functions () {
    out_green "Functions which have not yet been called or have failed:\n"
    for i in "${!func_names[@]}"
    do
	if [ "${func_done[$i]}" = false ]
	then
	    out_white "${func_names[$i]}\n"
	fi
    done
    out_green "These functions should now be performed manually per:\n"
    out_white "$upgrade_doc\n"
}

abort () {
    out_red "Aborting...\n\n"
    output_incomplete_functions
    exit
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
                confirm_abort
                if [ "$?" -eq 0 ]
                then
                    return 2
                else
                    continue
                fi
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
    if [ "$#" -lt 4 ]
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
    local index=$1
    shift

    out_green "\n${func}(): "
    out_white "${desc}\n"

    get_permission "$msg"
    local permission_ret=$?
    case $permission_ret in
        0)
            # Run the function $func.
            "$func" "$@"
            local func_ret=$?
            if [ "$func_ret" -eq 0 ]
            then
                func_done[$index]=true
            else
                # TODO: We hit some problem... Handle it here, or let each operation
                #       handle itself, or...?
                echo "Failed with: $func_ret"
            fi
            ;;
        1)
            # No-op. User does not wish to run $func.
            :
            ;;
        2)
            # User aborted the process
            abort
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
    systemctl stop ceph.target
}

rename_ceph_user_and_group () {
    printf "Inside $FUNCNAME\n"
}

disable_radosgw_services () {
    local rgw_conf_section_prefix="client.radosgw"
    local rgw_service_prefix="ceph-radosgw@"
    local not_complete=false

    # TODO: check if `ceph-conf` exists?
    for rgw_conf_section_name in $(ceph-conf --list-sections "$rgw_conf_section_prefix")
    do
        # rgw_conf_section_name -> [client.radosgw.some_host_name]
        # Derived rgw_service_instace -> some_host_name
        local rgw_service_instance="${rgw_conf_section_name#${rgw_conf_section_prefix}.}"

        # disable ceph-radosgw@some_host_name
        systemctl disable "${rgw_service_prefix}${rgw_service_instance}"

        if [ "$?" -ne 0 ]
        then
            not_complete=true
        fi
    done

    # If we failed at least once above, indicate this to the user.
    if [ "$not_complete" = true ]
    then
       return 1
    fi
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
    local rgw_conf_section_prefix="client.radosgw"
    local rgw_service_prefix="ceph-radosgw@"
    local rgw_instance_prefix="radosgw"
    local not_complete=false

    # TODO: check if `ceph-conf` exists?
    for rgw_conf_section_name in $(ceph-conf --list-sections "$rgw_conf_section_prefix")
    do
        # rgw_conf_section_name -> [client.radosgw.some_host_name]
        # Derived rgw_service_instace -> some_host_name
        local rgw_service_instance="${rgw_conf_section_name#${rgw_conf_section_prefix}.}"

        # enable ceph-radosgw@radosgw.some_host_name
        systemctl enable "${rgw_service_prefix}${rgw_instance_prefix}.${rgw_service_instance}"

        if [ "$?" -ne 0 ]
        then
            not_complete=true
        fi
    done

    # If we failed at least once above, indicate this to the user.
    if [ "$not_complete" = true ]
    then
       return 1
    fi
}

finish () {
    printf "Inside $FUNCNAME\n"
}

func_names+=("set_crush_tunables")
func_descs+=("Set CRUSH tunables.")
func_names+=("stop_ceph_daemons")
func_descs+=("Stop Ceph Daemons.")
func_names+=("rename_ceph_user_and_group")
func_descs+=("Rename Ceph user and group.")
func_names+=("disable_radosgw_services")
func_descs+=("Disable SES2 RADOSGW services, as naming convention has changed.")
func_names+=("disable_restart_on_update")
func_descs+=("Disable the CEPH_AUTO_RESTART_ON_UPGRADE sysconfig option.")
func_names+=("zypper_dup")
func_descs+=("Perform Zypper distribution update.")
func_names+=("restore_original_restart_on_update")
func_descs+=("Restore original CEPH_AUTO_RESTART_ON_UPGRADE sysconfig option.")
func_names+=("chown_var_lib_ceph")
func_descs+=("Recursively change ownership of /var/lib/ceph to ceph:ceph.")
func_names+=("enable_radosgw_services")
func_descs+=("Re-enable RADOSGW services using new SES3 naming convention.")
func_names+=("finish")
func_descs+=("Finish.")

# Functions have not yet been called.
for i in "${!func_names[@]}"
do
    func_done[$i]=false
done

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------

out_green "SES2.X to SES3 Upgrade${txtnorm}\n"

# Script needs to be run as root.
if [ "$EUID" -ne 0 ]
then
    out_err "Please run this script as root.\n"
    exit 1
fi

# run_func "permission_msg" "function_description" "function_name" ["function_args" ...]
for i in "${!func_names[@]}"
do
    run_func "" "${func_descs[$i]}" "${func_names[$i]}" "$i"
done

out_green "\nSES2.X to SES3 Upgrade Completed\n\n"

output_incomplete_functions
