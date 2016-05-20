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
DEBUG=true
scriptname=$(basename "$0")
upgrade_doc="https://www.suse.com/documentation/ses-3/book_storage_admin/data/cha_ceph_upgrade.html"
usage="usage: $scriptname\n"

# Codes
success=0
yes=0
skipped=1
no=1
failure=2
aborted=3

ceph_sysconfig_file="/etc/sysconfig/ceph"
# Pulled from /etc/sysconfig/ceph and used to store original value.
ceph_auto_restart_on_upgrade_var="CEPH_AUTO_RESTART_ON_UPGRADE"
ceph_auto_restart_on_upgrade_val=""

# Function arrays. Since bash can't do multidimensional associate arrays, this
# seemed like a decent fallback.
func_names=() # Array that will contain function names.
func_descs=() # Array that will contain corresponding function descriptions.
funcs_done=() # Array that will whether corresponding functions have completed
preflight_check_funcs=() # Array of funcs that perform various global pre-flight checks.
preflight_check_descs=() # Array of preflight function descriptions.
preflight_passed=true    # Assume global preflight checks will succeed.

txtbold=$(tput bold)
txtnorm=$(tput sgr0)
txtred=$(tput setaf 1)
txtgreen=$(tput setaf 2)
txtwhite=$(tput setaf 7)

out_debug () {
    local msg=$1
    [[ "$DEBUG" = true ]] && printf "$msg\n"
}

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
    local msg="Are you sure you want to abort? - Y[es]/N[o] (N)"
    local choice=""

    while [ 1 ]
    do
        out_red "$msg: "
        read choice
        case $choice in
            [Yy] | [Yy][Ee][Ss])
		return "$yes"
                ;;
            [Nn] | [Nn][Oo] | "")
		return "$no"
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

# Returns $yes on Yes and $no on No and $aborted on Abort.
get_permission () {
    local msg="Run this operation? - Y[es]/N[o]/A[bort] (Y)"
    local choice=""

    while [ 1 ]
    do
        printf "$msg: "
        read choice
        case $choice in
            [Yy] | [Yy][Ee][Ss] | "")
		return "$yes"
                ;;
            [Nn] | [Nn][Oo])
		return "$no"
                ;;
            [Aa] | [Aa][Bb][Oo][Rr][Tt])
		# If $yes, return $aborted, otherwise continue asking.
		confirm_abort || continue
		return "$aborted"
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
    if [ "$#" -ne 4 ]
    then
        out_err "$FUNCNAME: Invalid number of arguments. Please provide four."
        exit 1
    fi

    local func=$1
    shift
    local desc=$1
    shift
    local index=$1
    shift
    local track=$1
    shift

    out_debug "DEBUG: about to run ${func}()"
    out_white "\n${desc}\n"

    # Run the function $func. It will:
    #   1. Perform necessary checks.
    #   2. If needed, get the user's permission.
    #   3. Run and return a value:
    #      i.   0 - success.
    #      ii.  1 - did not run.
    #      iii. 2 - failure.
    #      iv.  3 - abort
    "$func" "$@"
    local func_ret=$?
    case $func_ret in
        "$success")
	    [[ "$track" = true ]] && func_done[$index]=true
            ;;
        "$skipped")
            # No-op. User does not wish to run $func.
	    out_white "Skipped!\n"
            ;;
        "$failure")
	    # TODO: We hit some problem... Handle it here, or let each operation
	    #       handle itself, or...?
	    out_red "Failed!\n"
	    ;;
	"$aborted")
            # User aborted the process
            abort
            ;;
        *)
            # No-op. Do nothing.
            :
            ;;
    esac

    return "$func_ret"
}

# ------------------------------------------------------------------------------
# Global pre-flight functions.
# ------------------------------------------------------------------------------
running_as_root () {
    # Script needs to be run as root.
    if [ "$EUID" -ne 0 ]
    then
	out_err "Please run this script as root.\n"
	return "$failure"
    fi

    return "$success"
}

preflight_check_funcs+=("running_as_root")
preflight_check_descs+=(
"Checking if script is running as root
====================================
su/sudo are just fine."
)

# ------------------------------------------------------------------------------
# Operations
# ------------------------------------------------------------------------------
set_crush_tunables () {
    # TODO: Preflight maybe should include checking if the cluster is up?
    ceph --version &>/dev/null || return "$skipped"
    get_permission || return "$?"

    ceph osd crush tunables optimal || return "$failure"
}

stop_ceph_daemons () {
    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    systemctl stop ceph.target || return "$failure"
}

rename_ceph_user_and_group () {
    local old_cephadm_user="ceph"     # Our old SES2 cephadm user (ceph-deploy).
    local new_cephadm_user="cephadm"  # Our new SES3 cephadm user (ceph-deploy).
    local func_ret="$success"

    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    # Only perform the rename if old_cephadm_user exists.
    if getent passwd "$old_cephadm_user" >/dev/null
    then
        # Rename old_cephadm_user to new_cephadm_user (ceph -> cephadm).
        # TODO: more clever error handling.
        usermod -l "$new_cephadm_user" "$old_cephadm_user" || func_ret="$failure"
    else
        func_ret="$skipped"
    fi

    return "$func_ret"
}

disable_radosgw_services () {
    local rgw_conf_section_prefix="client.radosgw"
    local rgw_service_prefix="ceph-radosgw@"
    local not_complete=false

    # TODO: Perform pre-flight checks
    ceph-conf --version &>/dev/null || return "$skipped"
    get_permission || return "$?"

    for rgw_conf_section_name in $(ceph-conf --list-sections "$rgw_conf_section_prefix")
    do
        # rgw_conf_section_name -> [client.radosgw.some_host_name]
        # Derived rgw_service_instace -> some_host_name
        local rgw_service_instance="${rgw_conf_section_name#${rgw_conf_section_prefix}.}"

        # disable ceph-radosgw@some_host_name
        systemctl disable "${rgw_service_prefix}${rgw_service_instance}" || not_complete=true
    done

    # If we failed at least once above, indicate this to the user.
    if [ "$not_complete" = true ]
    then
       return "$failed"
    fi
}

disable_restart_on_update () {
    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    while IFS="=" read key val
    do
        case "$key" in
            "$ceph_auto_restart_on_upgrade_var")
                ceph_auto_restart_on_upgrade_val="$val"
                ;;
            *)
                continue
                ;;
        esac
    done <"$ceph_sysconfig_file"

    sed -i "s/^${ceph_auto_restart_on_upgrade_var}.*/${ceph_auto_restart_on_upgrade_var}=no/" "$ceph_sysconfig_file"
}

zypper_dup () {
    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    zypper dist-upgrade || return "$failure"
}

restore_original_restart_on_update () {
    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    if [ ! -z "$ceph_auto_restart_on_upgrade_val" ]
    then
        sed -i "s/^${ceph_auto_restart_on_upgrade_var}.*/${ceph_auto_restart_on_upgrade_var}=${ceph_auto_restart_on_upgrade_val}/" "$ceph_sysconfig_file"
    fi
}

chown_var_lib_ceph () {
    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    out_info "This may take some time depending on the number of files on the OSD mounts.\n"
    chown -R ceph:ceph /var/lib/ceph || return "$failure"
}

enable_radosgw_services () {
    local rgw_conf_section_prefix="client.radosgw"
    local rgw_service_prefix="ceph-radosgw@"
    local rgw_instance_prefix="radosgw"
    local not_complete=false

    # TODO: Perform pre-flight checks
    ceph-conf --version &>/dev/null || return "$skipped"
    get_permission || return "$?"

    for rgw_conf_section_name in $(ceph-conf --list-sections "$rgw_conf_section_prefix")
    do
        # rgw_conf_section_name -> [client.radosgw.some_host_name]
        # Derived rgw_service_instace -> some_host_name
        local rgw_service_instance="${rgw_conf_section_name#${rgw_conf_section_prefix}.}"

        # enable ceph-radosgw@radosgw.some_host_name
        systemctl enable "${rgw_service_prefix}${rgw_instance_prefix}.${rgw_service_instance}" || not_complete=true
    done

    # If we failed at least once above, indicate this to the user.
    if [ "$not_complete" = true ]
    then
       return "$failed"
    fi
}

finish () {
    # TODO: Noop for now.
    :
}

func_names+=("set_crush_tunables")
func_descs+=(
"Set CRUSH tunables
==================
This will set OSD CRUSH tunables to optimal. WARNING: if you have customized
tunables, select \"No\" at the prompt."
)
func_names+=("stop_ceph_daemons")
func_descs+=(
"Stop Ceph Daemons
=================
Stop all Ceph daemons. Please select \"Yes\" as this is a needed step."
)
func_names+=("rename_ceph_user_and_group")
func_descs+=(
"Rename Ceph user and group
==========================
SES2 ran \`ceph-deploy\` under the username \"ceph\". With SES3,
Ceph daemons run as user \"ceph\" in group \"ceph\". This will
rename the adminstrative user \"ceph\" to \"cephadm\"."
)
func_names+=("disable_radosgw_services")
func_descs+=(
"Disable SES2 RADOSGW services
=============================
Since the naming convention has changed, before upgrade we need to temporarily
disable the RGW services. They will be re-enabled after the upgrade."
)
func_names+=("disable_restart_on_update")
func_descs+=(
"Disable CEPH_AUTO_RESTART_ON_UPGRADE sysconfig option
=====================================================
Since we will be performing additional steps after the upgrade, we do not
want the services to be restarted automatically. We will restart them manually
after the upgrade and restore the sysconfig option to is original value"
)
func_names+=("zypper_dup")
func_descs+=(
"Zypper distribution upgrade
===========================
This step upgrades the system (zypper dist-upgrade)"
)
func_names+=("restore_original_restart_on_update")
func_descs+=(
"Restore CEPH_AUTO_RESTART_ON_UPGRADE sysconfig option
=====================================================
Restores this sysconfig option to the value saved in the \"Disable\" step above."
)
func_names+=("chown_var_lib_ceph")
func_descs+=(
"Set ownership of /var/lib/ceph
==============================
This step may take a long time if your OSDs have a lot of data in them."
)
func_names+=("enable_radosgw_services")
func_descs+=(
"Re-enable RADOSGW services
==========================
Now that the ceph packages have been upgraded, we re-enable the RGW
services using the SES3 naming convention."
)
func_names+=("finish")
func_descs+=(
"Update has been Finished
========================
Please go ahead and:
  1. Reboot
  2. Wait for HEALTH_OK
  3. Then move on to the next node"
)

# Functions have not yet been called. Set their done flags to false.
for i in "${!func_names[@]}"
do
    func_done[$i]=false
done

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------

out_green "SES2.X to SES3 Upgrade${txtnorm}\n\n"
out_green "Running Pre-flight Checks...\n"
out_green "============================\n"

for i in "${!preflight_check_funcs[@]}"
do
    run_func "${preflight_check_funcs[$i]}" "${preflight_check_descs[$i]}" "$i" false || preflight_passed=false
done

if [ "$preflight_passed" = false ]
then
    abort
fi

out_green "Pre-flight Checks Succeeded!\n"
out_green "============================\n"

for i in "${!func_names[@]}"
do
    run_func "${func_names[$i]}" "${func_descs[$i]}" "$i" true
done

out_green "\nSES2.X to SES3 Upgrade Completed\n\n"

output_incomplete_functions
