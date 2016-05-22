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
DEBUG=false
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
assert_err=255

ceph_sysconfig_file="/etc/sysconfig/ceph"
# Pulled from /etc/sysconfig/ceph and used to store original value.
ceph_auto_restart_on_upgrade_var="CEPH_AUTO_RESTART_ON_UPGRADE"
ceph_auto_restart_on_upgrade_val=""

# Function arrays. Since bash can't do multidimensional associate arrays, this
# seemed like a decent fallback.
upgrade_funcs=() # Array that will contain upgrade function names.
upgrade_func_descs=() # Array that will contain corresponding upgrade function descriptions.
upgrade_funcs_done=() # Array to which we will append names of upgrade functions that have completed
preflight_check_funcs=() # Array of funcs that perform various global pre-flight checks.
preflight_check_descs=() # Array of preflight function descriptions.

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
    [[ "$interactive" = true ]] && printf "${txtbold}${txtred}${msg}${txtnorm}" || printf -- "$msg"
}

out_white () {
    local msg=$1
    [[ "$interactive" = true ]] && printf "${txtbold}${txtwhite}${msg}${txtnorm}" || printf -- "$msg"
}

out_green () {
    local msg=$1
    [[ "$interactive" = true ]] && printf "${txtbold}${txtgreen}${msg}${txtnorm}" || printf -- "$msg"
}

out_err () {
    local msg=$1
    out_red "ERROR: $msg"
}

out_info () {
    local msg="$1"
    out_white "INFO: $msg"
}

# Be sure that the user wants to abort the upgrade process.
confirm_abort () {
    local msg="Are you sure you want to abort?"
    local answers="Y[es]/N[o] (N)"
    local prompt="[$msg - $answers]> "
    local choice=""

    while true
    do
	out_red "$prompt"
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
    for i in "${!upgrade_funcs[@]}"
    do
	if [ "${upgrade_funcs_done[$i]}" = false ]
	then
	    out_white "${upgrade_funcs[$i]}\n"
	fi
    done
    out_green "These functions should now be performed manually per:\n"
    out_white "$upgrade_doc\n"
}

abort () {
    out_red "Aborting...\n\n"
    output_incomplete_functions
    exit "$aborted"
}

# Returns $yes on Yes, $no on No and $aborted on Abort.
get_permission () {
    local msg="Run this operation?"
    local answers="Y[es]/N[o]/A[bort] (Y)"
    local prompt="[$msg - $answers]> "
    local choice=""

    [[ "$interactive" = false ]] && return "$yes"

    while true
    do
	printf "$prompt"
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

# Takes two arguments: the actual number of arguments passed to the function
# and the expected number.
assert_number_of_args () {
    local funcname=$1
    local actual=$2
    local expected=$3
    # assert that we have $expected number of arguments - no more, no less!
    if [[ "$actual" != "$expected" ]]
    then
        out_err "${funcname}: Invalid number of arguments (${actual}). Please provide ${expected}.\n"
	exit $assert_err
    fi
}

run_preflight_check () {
    assert_number_of_args $FUNCNAME $# 2

    local func=$1
    shift
    local desc=$1
    shift

    out_debug "DEBUG: about to run pre-flight check ${func}()"
    out_white "${desc}\n"
    out_white "\n"

    "$func" "$@"
}

# Wrapper to query user whether they really want to run a particular upgrade
# function.
run_upgrade_func () {
    assert_number_of_args $FUNCNAME $# 3

    local func=$1
    shift
    local desc=$1
    shift
    local index=$1
    shift

    out_debug "\nDEBUG: about to run ${func}()"
    out_white "\n\n${desc}\n\n"

    # Run the function $func. It will:
    #   1. Perform necessary checks.
    #   2. If needed, get the user's permission.
    #   3. Run and return a value:
    #      i.   0 - success.
    #      ii.  1 - did not run.
    #      iii. 2 - failure.
    #      iv.  3 - abort
    local func_ret="$failure"
    while [ "$func_ret" = "$failure" ]
    do
	"$func" "$@"
	func_ret="$?"
	case $func_ret in
	    "$success")
		upgrade_funcs_done[$index]=true
		;;
	    "$skipped")
		# No-op. User does not wish to run $func.
		out_white "Skipped!\n"
		;;
	    "$failure")
                # Interactive mode failure case fails the current upgrade operation
                # and continues. Non-interactive mode aborts on failure.
		out_red "Failed!\n"
                [[ "$interactive" = false ]] && abort
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
    done

    return "$func_ret"
}

# ------------------------------------------------------------------------------
# Global pre-flight functions.
# ------------------------------------------------------------------------------
running_as_root () {
    test "$EUID" -eq 0
}

user_ceph_not_in_use () {
    ! ps -u ceph &>/dev/null
}

preflight_check_funcs+=("running_as_root")
preflight_check_descs+=(
"Checking if script is running as root
=====================================
The upgrade script must run as root (su/sudo are fine as long as no user
\"ceph\" is involved)."
)
preflight_check_funcs+=("user_ceph_not_in_use")
preflight_check_descs+=(
"Check if user \"ceph\" is being used to run any programs
======================================================
In SES2, the user \"ceph\" was created to run ceph-deploy. In SES3, all Ceph
daemons run as user \"ceph\". During the upgrade process, we provide the option
to rename \"ceph\", thus we need to ensure that no processes are currently
running as this user. Please terminate any such processes."
)
# ------------------------------------------------------------------------------
# Operations
# ------------------------------------------------------------------------------
stop_ceph_daemons () {
    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    systemctl stop ceph.target || return "$failure"
}

rename_ceph_user_and_group () {
    local old_cephadm_user="ceph"     # Our old SES2 cephadm user (ceph-deploy).
    local new_cephadm_user="cephadm"  # Our new SES3 cephadm user (ceph-deploy).

    # Local preflight checks.
    # If $old_cephadm_user is not present on the system, skip this upgrade function.
    getent passwd "$old_cephadm_user" &>/dev/null || return "$skipped"
    get_permission || return "$?"

    usermod -l "$new_cephadm_user" "$old_cephadm_user" && return "$success" || return "$failure"
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
    [[ "$not_complete" = true ]] && return "$failure" || return "$success"
}

disable_restart_on_update () {
    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    local G_IFS="$IFS" # Save global $IFS.
    local IFS="="      # Local $IFS used in read loop below.

    while read key val
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
    # Restore local $IFS to global version.
    IFS="$G_IFS"

    sed -i "s/^${ceph_auto_restart_on_upgrade_var}.*/${ceph_auto_restart_on_upgrade_var}=no/" "$ceph_sysconfig_file"
}

zypper_dup () {
    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    if [ "$interactive" = true ]
    then
	zypper dist-upgrade || return "$failure"
    else
	zypper --non-interactive --terse dist-upgrade || return "$failure"
    fi
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
    [[ "$not_complete" = true ]] && return "$failure" || return "$success"
}

# Jewel based radosgw zones contain a new "meta_heap" structure which need a
# corresponding pool: "${zone_name}.rgw.meta"
populate_radosgw_zone_meta_heap () {
    local not_complete=false

    # Preflight
    radosgw-admin --version &>/dev/null || return "$skipped"
    get_permission || return "$?"

    local zone_list=$(radosgw-admin zone list) || return "$failure"
    zone_list="${zone_list//$'\n'/}" # Flatten zone_list.

    local G_IFS="$IFS"
    local IFS=','
    zone_arr=( $(echo "$zone_list" | grep -o "zones.*" | awk '{for(i=3;i<=NF-1;++i)printf $i}') )
    IFS="$G_IFS"

    for zone in "${zone_arr[@]}"
    do
	zone="${zone%\"}" # Remove leading quotes.
	zone="${zone#\"}" # Remove trailing quotes.
	local zone_file="/tmp/${zone}.json"
	radosgw-admin zone get --rgw-zone="${zone}" > "$zone_file" || not_complete=true
	sed -i "s/\"metadata_heap\": \"\"/\"metadata_heap\": \"${zone}.rgw.meta\"/" "$zone_file" || not_complete=true
	radosgw-admin zone set --rgw-zone="${zone}" < "$zone_file" || not_complete=true
	rm "$zone_file"
    done

    # If we failed at least once above, indicate this to the user.
    [[ "$not_complete" = true ]] && return "$failure" || return "$success"
}

finish () {
    # TODO: Noop for now.
    :
}

upgrade_funcs+=("stop_ceph_daemons")
upgrade_func_descs+=(
"Stop Ceph Daemons
=================
Stop all Ceph daemons. Please select \"Yes\" as this is a needed step."
)
upgrade_funcs+=("rename_ceph_user_and_group")
upgrade_func_descs+=(
"Rename Ceph user and group
==========================
SES2 ran \`ceph-deploy\` under the username \"ceph\". With SES3,
Ceph daemons run as user \"ceph\" in group \"ceph\". This will
rename the adminstrative user \"ceph\" to \"cephadm\"."
)
upgrade_funcs+=("disable_radosgw_services")
upgrade_func_descs+=(
"Disable SES2 RADOSGW services
=============================
Since the naming convention has changed, before upgrade we need to temporarily
disable the RGW services. They will be re-enabled after the upgrade."
)
upgrade_funcs+=("disable_restart_on_update")
upgrade_func_descs+=(
"Disable CEPH_AUTO_RESTART_ON_UPGRADE sysconfig option
=====================================================
Since we will be performing additional steps after the upgrade, we do not
want the services to be restarted automatically. We will restart them manually
after the upgrade and restore the sysconfig option to is original value"
)
upgrade_funcs+=("zypper_dup")
upgrade_func_descs+=(
"Zypper distribution upgrade
===========================
This step upgrades the system by running \"zypper dist-upgrade\".
If you prefer to upgrade by some other means (e.g. SUSE Manager),
do that now, but do not reboot the system. Select Skip when the upgrade
finishes.
)
upgrade_funcs+=("restore_original_restart_on_update")
upgrade_func_descs+=(
"Restore CEPH_AUTO_RESTART_ON_UPGRADE sysconfig option
=====================================================
Restores this sysconfig option to the value saved in the \"Disable\" step above."
)
upgrade_funcs+=("chown_var_lib_ceph")
upgrade_func_descs+=(
"Set ownership of /var/lib/ceph
==============================
This step may take a long time if your OSDs have a lot of data in them."
)
upgrade_funcs+=("enable_radosgw_services")
upgrade_func_descs+=(
"Re-enable RADOSGW services
==========================
Now that the ceph packages have been upgraded, we re-enable the RGW
services using the SES3 naming convention."
)
upgrade_funcs+=("populate_radosgw_zone_meta_heap")
upgrade_func_descs+=(
"Populate RADOSGW zone metadata heap with to-be-created pool
===========================================================
SES2 did not contain a metadata heap structure as part of a RADOSGW zone. When
upgrading to SES3, the zone configuration must be modified to contain a metadata
heap pool, which will then be created (it not present) on RADOSGW start."
)
upgrade_funcs+=("finish")
upgrade_func_descs+=(
"Update has been Finished
========================
Please go ahead and:
  1. Reboot
  2. Wait for HEALTH_OK
  3. Then move on to the next node"
)

# Functions have not yet been called. Set their done flags to false.
for i in "${!upgrade_funcs[@]}"
do
    upgrade_funcs_done[$i]=false
done

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------

# By default, we run as an interactive script. Pass --non-interactive to run in,
# you guessed it, non interactive mode.
interactive=true

# Parse our command line options
while [ "$#" -ge 1 ]
do
    case $1 in
	--non-interactive)
	    interactive=false
	    ;;
    esac
    shift
done

out_green "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n"
out_green "===== SES2.X to SES3 Upgrade =====\n"
out_green "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n"
out_green "\n"
out_green "Running pre-flight checks...\n"
out_green "\n"

preflight_failures=false
for i in "${!preflight_check_funcs[@]}"
do
    if run_preflight_check "${preflight_check_funcs[$i]}" "${preflight_check_descs[$i]}"
    then
        out_green "PASSED\n\n"
    else
        out_red "FAILED\n\n"
        preflight_failures=true
    fi
done
[[ "$preflight_failures" = true ]] && out_white "One or more pre-flight checks failed\n" && exit 255

out_green "\n"
out_green "\nRunning upgrade functions...\n"

for i in "${!upgrade_funcs[@]}"
do
    run_upgrade_func "${upgrade_funcs[$i]}" "${upgrade_func_descs[$i]}" "$i"
done

out_green "\n-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n"
out_green "===== SES2.X to SES3 Upgrade Completed =====\n"
out_green "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n\n"

output_incomplete_functions
