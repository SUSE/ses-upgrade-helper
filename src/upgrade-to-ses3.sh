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

# Codes
uninit=-1
success=0 # $success and $yes return the same value for get_permission handling.
yes=0
skipped=1
failure=2
aborted=3
user_skipped=4 # $user_skipped and $no return the same value for get_permission handling.
no=4
assert_err=255

ceph_sysconfig_file="/etc/sysconfig/ceph"
ceph_conf_file="/etc/ceph/ceph.conf"
ceph_radosgw_pkg="ceph-radosgw"
ceph_radosgw_disabled_services_datafile="/tmp/ceph_radosgw_disabled_services.out"
# Pulled from /etc/sysconfig/ceph and used to store original value.
ceph_auto_restart_on_upgrade_var="CEPH_AUTO_RESTART_ON_UPGRADE"
ceph_auto_restart_on_upgrade_val=""

# Function arrays. Since bash can't do multidimensional associate arrays, this
# seemed like a decent fallback.
upgrade_funcs=() # Array that will contain upgrade function names.
upgrade_func_descs=() # Array that will contain corresponding upgrade function descriptions.
upgrade_funcs_exit_codes=() # Array which will store exit codes of upgrade functions.
preflight_check_funcs=() # Array of funcs that perform various global pre-flight checks.
preflight_check_descs=() # Array of preflight function descriptions.

txtbold=$(tput bold)
txtnorm=$(tput sgr0)
txtred=$(tput setaf 1)
txtgreen=$(tput setaf 2)
txtwhite=$(tput setaf 7)

usage_msg="usage: $scriptname [options]
options:
\t-c, --conf <config file>
\t\tLoad specific configuration file. Default is $ceph_conf_file.

\t-n, --non-interactive
\t\tRun in non-interactive mode. All upgrade operations will be 
\t\texecuted with no input from the user.

\t-h, --help
\t\tPrint this usage message.
"
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

usage_exit () {
    ret_code="$1"
    printf "$usage_msg"
    [[ -z "$ret_code" ]] && exit "$success" || exit "$ret_code"
}

# echo list of radosgw configuration section names found in ceph.conf. These
# correspond to radosgw instances.
get_radosgw_conf_section_names () {
    local rgw_conf_section_prefix="client.radosgw"

    ceph-conf --version &>/dev/null || return "$failure"

    ceph-conf -c "$ceph_conf_file" --list-sections "$rgw_conf_section_prefix" 2>/dev/null || return "$failure"
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
    out_green "Functions which have failed (in this invocation of $scriptname):\n\n"
    for i in "${!upgrade_funcs[@]}"
    do
	[[ "${upgrade_funcs_ret_codes[$i]}" = "$failure" ]] && out_red "${upgrade_func_descs[$i]}\n" | sed -n 1p
    done
    out_green "\nFunctions which have been skipped by the user (in this invocation of $scriptname):\n\n"
    for i in "${!upgrade_funcs[@]}"
    do
	[[ "${upgrade_funcs_ret_codes[$i]}" = "$user_skipped" ]] && out_white "${upgrade_func_descs[$i]}\n" | sed -n 1p
    done
    out_green "\nWhen re-running $scriptname, run the above functions.\n\n"
    out_green "For additional upgrade information, please visit:\n"
    out_white "$upgrade_doc\n"
}

abort () {
    out_red "\nAborting...\n\n"
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
		confirm_abort && return "$aborted"
		continue
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
		upgrade_funcs_ret_codes[$index]="$success"
		;;
	    "$skipped")
		# Local function preflights have skipped the function.
		upgrade_funcs_ret_codes[$index]="$skipped"
		out_white "Skipped!\n"
		;;
	    "$failure")
                # Interactive mode failure case fails the current upgrade operation
                # and continues. Non-interactive mode aborts on failure.
		upgrade_funcs_ret_codes[$index]="$failure"
		out_red "Failed!\n"
                [[ "$interactive" = false ]] && abort
		;;
	    "$aborted")
		# User aborted the process
		abort
		;;
	    "$user_skipped")
		# User has decided to skip the function. This may have happened
		# without actually performing anything more than local function
		# preflights, or it may have happened after the upgrade function
		# has failed 1+ times. Only set the exit code to $user_skipped
		# if it is not already set to $failure.
		[[ "${upgrade_funcs_ret_codes[$index]}" = "$failure" ]] || upgrade_funcs_ret_codes[$index]="$user_skipped"
		out_white "Skipped!\n"
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

ceph_conf_file_exists () {
    [[ ! -z "$ceph_conf_file" && -e "$ceph_conf_file" ]]
}

preflight_check_funcs+=("running_as_root")
preflight_check_descs+=(
"Check that script is running as root
====================================
The upgrade script must run as root. If this check fails, it means you are not
running it as root (sudo/su are fine as long as they are not run as the
\"ceph\" user)."
)
preflight_check_funcs+=("user_ceph_not_in_use")
preflight_check_descs+=(
"Check for processes owned by user \"ceph\"
========================================
In SES2, the user \"ceph\" was created to run ceph-deploy. In SES3, all Ceph
daemons run as user and group \"ceph\". Since it is preferable to have no
ordinary \"ceph\" user in the system when the upgrade is performed, this script
will check if there is an existing \"ceph\" user and rename it to \"cephadm\"
if it exists. For this rename operation to work, the \"ceph\" user must not be
in use. (It could be in use, for example, if you logged in as \"ceph\" and ran
this script using sudo.) If this check fails, find processes owned by user
\"ceph\" and terminate those processes. Then re-run the script."
)

preflight_check_funcs+=("ceph_conf_file_exists")
preflight_check_descs+=(
"Ensure Ceph configuration file exists on the system
===================================================
An existing Ceph configuration file needs to be present on the system in order
for ${scriptname} to extract various aspects of the configuration. The default
configuration file is: ${ceph_conf_file}. This can be overriden with the \`-c\`
option. See: \`${scriptname} -h\`"
)



# ------------------------------------------------------------------------------
# Operations
# ------------------------------------------------------------------------------
stop_ceph_daemons () {
    # TODO: Perform pre-flight checks
    get_permission || return "$?"

    systemctl stop ceph.target || return "$failure"
}

rename_ceph_user () {
    local old_cephadm_user="ceph"     # Our old SES2 cephadm user (ceph-deploy).
    local new_cephadm_user="cephadm"  # Our new SES3 cephadm user (ceph-deploy).
    local new_ceph_user="ceph"        # SES3 daemons run as this user.
    local new_ceph_group="ceph"       # SES3 user "ceph" belongs to this group.
    local not_complete=false

    # Local preflight checks.
    # 1. If user $new_ceph_user exists and belongs to $new_ceph_group, skip this
    #    upgrade function.
    if getent passwd "$new_ceph_user" &>/dev/null
    then
        [[ $(id -g -n "$new_ceph_user") = "$new_ceph_group" ]] && return "$skipped"
    fi
    # 2. If $old_cephadm_user is not present on the system, skip this upgrade function.
    getent passwd "$old_cephadm_user" &>/dev/null || return "$skipped"
    # 3. We hit a case where: We have a $new_ceph_user that is _not_ in $new_ceph_group
    #    _and_ we also have a $new_cephadm_user present. This is a bad state 
    #    (we have 2 administrative type users and the usermod -l will fail)
    #    that requires manual intervention.
    getent passwd "$new_cephadm_user" &>/dev/null &&
        out_err "Both $old_cephadm_user and $new_ceph_admin administrative users exist! \nPlease backup the home directories of both users, and then remove the $new_cephadm_user from the system (retaining both backups).\nOn retry, we will move $old_cephadm_user to $new_cephadm_user.\n" &&
        return "$failure"
    # Finally, get the user's permission.
    get_permission || return "$?"

    # If the rename fails, report error and don't proceed further, unless $?==6,
    # signalling that the $old_cephadm_user no longer exists (ie. because we have
    # already renamed it.
    # Remainder of operations, on failure, set not_complete flag. User will need to
    # handle the rename and chown themselves as the system is in a non-standard state.
    usermod -l "$new_cephadm_user" "$old_cephadm_user"
    if [ "$?" -ne 0 ]
    then
        if [ "$?" -ne 6 ]
        then
            return "$failure"
        fi
    fi

    local new_cephadm_group=$(id -g -n "$new_cephadm_user")
    # assert sanity
    [[ -z "$new_cephadm_group" ]] && out_red "FATAL: could not determine gid of new cephadm user" && return $assert_err
    [[ "$new_cephadm_group" = "ceph" ]] && out_red "FATAL: new cephadm user is in group \"ceph\" - this is not allowed!" && return $assert_err
    # make sure cephadm has a usable home directory
    if [ -d "/home/${old_cephadm_user}" ]
    then
        mv "/home/${old_cephadm_user}" "/home/${new_cephadm_user}" || not_complete=true
    else
        mkdir "/home/${new_cephadm_user}" || not_complete=true
        chmod 0755 "/home/${new_cephadm_user}" || not_complete=true
    fi
    chown -R "$new_cephadm_user":"$new_cephadm_group" "/home/${new_cephadm_user}" || not_complete=true
    usermod -d "/home/$new_cephadm_user" $new_cephadm_user || not_complete=true

    [[ "$not_complete" = true ]] &&
        out_err "Failed to ensure that new ceph administrative user ${new_cephadm_user} has a proper home directory.\n" &&
        return "$failure"

    return "$success"
}

disable_radosgw_services () {
    local rgw_conf_section_prefix="client.radosgw"
    local rgw_service_prefix="ceph-radosgw@"
    local not_complete=false
    local enabled_rgw_instances=()

    # Local preflight checks
    ceph-conf --version &>/dev/null || return "$skipped"
    # Check if ceph-radosgw package installed.
    rpm -qi "$ceph_radosgw_pkg" &>/dev/null || return "$skipped"
    # If we get_radosgw_conf_section_names() legitimately fails, then we return
    # $assert_err. Since this is a preflight, we don't want to loop in run_upgrade_func(),
    # so return $assert_err instead of $failure.
    radosgw_conf_section_names=$(get_radosgw_conf_section_names) || return "$assert_err"
    for rgw_conf_section_name in $radosgw_conf_section_names
    do
        # rgw_conf_section_name -> [client.radosgw.some_host_name]
        # Derived rgw_service_instace -> some_host_name
        local rgw_service_instance="${rgw_conf_section_name#${rgw_conf_section_prefix}.}"
        systemctl is-enabled "${rgw_service_prefix}${rgw_service_instance}" &>/dev/null && enabled_rgw_instances+=("$rgw_service_instance")
    done
    # Don't prompt for permission if no enabled rgw instances, just skip.
    [[ "${#enabled_rgw_instances[@]}" -eq 0 ]] && return "$skipped"

    # Done with our local preflights. Output list of instances we want to disable
    # and get permission to do so.
    out_white "The following enabled RADOSGW instances have been selected for disablement on this node:\n"
    for rgw_service_instance in "${enabled_rgw_instances[@]}"
    do
        printf "  $rgw_service_instance\n"
    done
    printf "\n"
    get_permission || return "$?"

    # Clear out $ceph_radosgw_disabled_services_datafile.
    echo "# Disabled RADOSGW instances:" > "$ceph_radosgw_disabled_services_datafile"
    for rgw_service_instance in "${enabled_rgw_instances[@]}"
    do
        # disable ceph-radosgw@some_host_name
        # Note: systemctl disable always returns $success :/
        systemctl disable "${rgw_service_prefix}${rgw_service_instance}" &&
            echo "$rgw_service_instance" >> "$ceph_radosgw_disabled_services_datafile" ||
                not_complete=true
    done

    # If we failed at least once above, indicate this to the user. However,
    # given the above "Note:", we really can't fail.
    [[ "$not_complete" = true ]] && return "$failure"

    return "$success"
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
	zypper --non-interactive dist-upgrade || return "$failure"
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
    local rgw_service_prefix="ceph-radosgw@"
    local rgw_instance_prefix="radosgw"
    local not_complete=false
    local disabled_rgw_instances=()

    # Local preflight checks
    ceph-conf --version &>/dev/null || return "$skipped"
    # Check if ceph-radosgw package installed.
    rpm -qi "$ceph_radosgw_pkg" &>/dev/null || return "$skipped"
    # Check that $ceph_radosgw_disabled_services_datafile exists. If not, we did
    # not disable any services in disable_radosgw_services().
    [[ -e "$ceph_radosgw_disabled_services_datafile" ]] || return "$skipped"
    # Pull in the rgw instances we disabled in disable_readosgw_services()
    while read rgw_service_instance
    do
        case "$rgw_service_instance" in
            ''|\#*)
                continue
                ;;
            *)
                disabled_rgw_instances+=("$rgw_service_instance")
                ;;
        esac
    done <"$ceph_radosgw_disabled_services_datafile"
    # Don't prompt for permission if no disabled rgw instances, just skip.
    [[ "${#disabled_rgw_instances[@]}" -eq 0 ]] && return "$skipped"

    # Done with our local preflights. Output list of disabled instances that we
    # want to enable and get permission to do so.
    out_white "The following RADOSGW instances have been disabled on this node and can now be properly re-enabled:\n"
    for rgw_service_instance in "${disabled_rgw_instances[@]}"
    do
        printf "  $rgw_service_instance\n"
    done
    printf "\n"
    get_permission || return "$?"

    for rgw_service_instance in "${disabled_rgw_instances[@]}"
    do
        # Enable ceph-radosgw@radosgw.some_host_name and remove the entry from
        # $ceph_radosgw_disabled_services_datafile indicating it was successfully
        # re-enabled.
        systemctl enable "${rgw_service_prefix}${rgw_instance_prefix}.${rgw_service_instance}" &&
            sed -i "/^${rgw_service_instance}/d" "$ceph_radosgw_disabled_services_datafile" ||
                not_complete=true
    done

    # If we failed at least once above, indicate this to the user and dump the list
    # of service instances we were not able to enable. This should not happen as
    # systemctl will happily take any instance name.
    if [ "$not_complete" = true ]
    then
        out_red "\nThe following disabled RADOSGW instances were not properly re-enabled:\n"
        printf "$ceph_radosgw_disabled_services_datafile:\n"
        cat "$ceph_radosgw_disabled_services_datafile"
        printf "\n"
        return "$failure"
    else
        rm "$ceph_radosgw_disabled_services_datafile"
        return "$success"
    fi
}

standardize_radosgw_logfile_location () {
    local log_file_exp="\(log_file\|log file\) = \/var\/log\/ceph-radosgw\/.*client.radosgw*"
    # Local preflight checks.
    get_permission || return "$?"

    # Heavy handedly remove log_file entries matching:
    # /var/log/ceph-radosgw/client.radosgw.*
    sed -i "/${log_file_exp}/d" "$ceph_conf_file" || return "$failure"
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
upgrade_funcs+=("rename_ceph_user")
upgrade_func_descs+=(
"Rename Ceph user
================
SES2 ran \`ceph-deploy\` under the username \"ceph\". With SES3,
Ceph daemons run as user \"ceph\" in group \"ceph\". The upgrade
scripting will create these with the proper parameters, provided
they do not exist in the system. Therefore, we now rename any
existing user \"ceph\" to \"cephadm\". If in doubt, say Y here."

)
upgrade_funcs+=("disable_radosgw_services")
upgrade_func_descs+=(
"Disable SES2 RADOS Gateway services
===================================
Since the naming convention has changed, before upgrade we need to
temporarily disable the RGW services. They will be re-enabled after
the upgrade. It is safe to answer Y here even if there are no RADOS
Gateway instances configured on this node."
)
upgrade_funcs+=("disable_restart_on_update")
upgrade_func_descs+=(
"Disable CEPH_AUTO_RESTART_ON_UPGRADE sysconfig option
=====================================================
Since we will be performing additional steps after the upgrade, we do
not want the services to be restarted automatically. Therefore, this
step modifies \"/etc/sysconfig/ceph\" to ensure that this option is
set to \"no\". The previous option is saved so it can be restored after
the upgrade is completed. If in doubt, answer Y."
)
upgrade_funcs+=("zypper_dup")
upgrade_func_descs+=(
"Zypper distribution upgrade
===========================
This step upgrades the system by running \"zypper dist-upgrade\". If you
prefer to upgrade by some other means (e.g. SUSE Manager), do that now, but
do not reboot the system - just select Skip when the upgrade finishes."
)
upgrade_funcs+=("restore_original_restart_on_update")
upgrade_func_descs+=(
"Restore CEPH_AUTO_RESTART_ON_UPGRADE sysconfig option
=====================================================
Restores this sysconfig option to the value saved in the \"Disable\" step 
above."
)
upgrade_funcs+=("chown_var_lib_ceph")
upgrade_func_descs+=(
"Set ownership of /var/lib/ceph
==============================
This step is critical to the proper functioning of the Ceph cluster and
should only be skipped if you already recursively changed the ownership
yourself and are sure you did it correctly. There is no danger in answering
Yes here even if you have already done this step before."
)
upgrade_funcs+=("enable_radosgw_services")
upgrade_func_descs+=(
"Re-enable RADOS Gateway services
================================
Now that the ceph packages have been upgraded, we re-enable the RGW
services using the SES3 naming convention. There is no danger in answering
Yes here. If there are no RADOS Gateway instances configured on this node,
the step will be skipped automatically."
)
upgrade_funcs+=("standardize_radosgw_logfile_location")
upgrade_func_descs+=(
"Configure RADOS Gateway instances to log in default location
============================================================
SES2 ceph-deploy added a \"log_file\" entry to ceph.conf setting a custom
location for the RADOS Gateway log file in ceph.conf. In SES3, the best
practice is to let the RADOS Gateway log to its default location,
\"/var/log/ceph\", like the other Ceph daemons. If in doubt, just say Yes."
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

# Set exit code for each upgrade function to $uninit (-1).
for i in "${!upgrade_funcs[@]}"
do
    upgrade_funcs_exit_codes[$i]="$uninit"
done

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------

trap abort INT

# By default, we run as an interactive script. Pass --non-interactive to run in,
# you guessed it, non interactive mode.
interactive=true

# Parse our command line options
while [ "$#" -ge 1 ]
do
    case $1 in
	-n | --non-interactive)
	    interactive=false
	    ;;
        -c | --conf)
            ceph_conf_file="$2"
            shift
            ;;
        -h | --help)
            usage_exit
            ;;
	*)  # unrecognized option
	    usage_exit
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
[[ "$preflight_failures" = true ]] && out_white "One or more pre-flight checks failed\n" && exit "$assert_err"

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
