#!/bin/bash
#
# SES upgrade helper script
#
# Copyright (c) 2016, SUSE LLC
# All rights reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#

# ==============================================================================
# upgrade-ses.sh
# --------------
#
# Sets out to upgrade a SES Installation.
#
# ==============================================================================

# Various globals
DEBUG=false
SES_VER="devel" # Replaced during build with SES version to which we will upgrade.
scriptname=$(basename "$0")
upgrade_doc="https://www.suse.com/documentation/ses-${SES_VER}/book_storage_admin/data/cha_ceph_upgrade.html"

# Codes
uninit=-1
success=0 # $success and $yes return the same value for get_permission handling.
yes=0
skipped=1
failure=2
aborted=3
user_skipped=4 # $user_skipped and $no return the same value for get_permission handling.
no=4
func_abort=254
assert_err=255

ceph_sysconfig_file="/etc/sysconfig/ceph"
ceph_conf_file="/etc/ceph/ceph.conf"
ceph_radosgw_pkg="ceph-radosgw"
ceph_radosgw_disabled_services_datafile="/tmp/ceph_radosgw_disabled_services.out"
# Pulled from /etc/sysconfig/ceph and used to store original value.
ceph_auto_restart_on_upgrade_var="CEPH_AUTO_RESTART_ON_UPGRADE"
ceph_auto_restart_on_upgrade_datafile="/tmp/ceph_auto_restart_on_upgrade.out"

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

usage_msg="usage: $scriptname [options]
options:
\t-c, --conf <config file>
\t\tLoad specific configuration file. Default is $ceph_conf_file.

\t-n, --non-interactive
\t\tRun in non-interactive mode. All upgrade operations will be
\t\texecuted with no input from the user.

\t-s, --skip-osd-parttype-check
\t\tSkip the OSD partition type checks. Only skip this check if
\t\tyou are certain your OSD journal and data partitions are of
\t\tthe correct type, or because this check is gating an upgrade
\t\tthat you must complete regardless of potential OSD health.

\t-h, --help
\t\tPrint this usage message.
"

out_bold () {
    local msg=$1
    [[ "$interactive" = true ]] && printf "${txtnorm}${txtbold}${msg}${txtnorm}" || printf -- "$msg"
}

out_norm () {
    local msg=$1
    printf "${txtnorm}${msg}"
}

out_debug () {
    local msg=$1
    [[ "$DEBUG" = true ]] && printf "$msg\n"
}

out_red () {
    local msg=$1
    [[ "$interactive" = true ]] && printf "${txtnorm}${txtred}${msg}${txtnorm}" || printf -- "$msg"
}

out_bold_red () {
    local msg=$1
    [[ "$interactive" = true ]] && printf "${txtnorm}${txtbold}${txtred}${msg}${txtnorm}" || printf -- "$msg"
}

out_bold_green () {
    local msg=$1
    [[ "$interactive" = true ]] && printf "${txtnorm}${txtbold}${txtgreen}${msg}${txtnorm}" || printf -- "$msg"
}

out_err () {
    local msg=$1
    out_bold_red "ERROR: $msg"
}

out_warn () {
    local msg=$1
    out_red "WARN: $msg"
}

out_info () {
    local msg="$1"
    out_bold "INFO: $msg"
}

assert () {
    local msg="$1"
    out_bold_red "FATAL: $msg"
    exit "$assert_err"
}

usage_exit () {
    ret_code="$1"
    out_norm "$usage_msg"
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
	out_bold_red "$prompt"
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

# Returns $yes if all upgrade functions succeeded. Otherwise returns $no.
upgrade_funcs_succeeded () {
    for i in "${!upgrade_funcs[@]}"
    do
        [[ "${upgrade_funcs_ret_codes[$i]}" = "$failure" ]] && return "$no"
    done

    return "$yes"
}

# Return $yes is user skipped any upgrade functions. Otherwise return $no.
upgrade_funcs_user_skipped () {
    for i in "${!upgrade_funcs[@]}"
    do
	[[ "${upgrade_funcs_ret_codes[$i]}" = "$user_skipped" ]] && return "$yes"
    done

    return "$no"
}

_output_final_report_failures () {
    out_bold_red "\nWARNING: "
    out_bold "One or more upgrade functions have failed!\n"
    out_bold "         It is advisable to diagnose the failures and re-run $scriptname.\n"
}

_output_final_report_success () {
    out_bold_green "\nSUCCESS: "
    out_bold "Upgrade has completed without any detected failures.\n"
    out_bold "         Please go ahead and:\n"
    out_norm "         1. Re-run any functions which you unintentionally skipped\n"
    out_norm "         2. Reboot\n"
    out_norm "         3. Wait for HEALTH_OK or HEALTH_WARN in case status also displays:\n"
    out_norm "            \"crush map has legacy tunables (require bobtail, min is firefly)\"\n"
    out_norm "         4. Then move on to the next node\n"
}

_output_final_report_list_failures () {
    local failed_info_line_output=false

    for i in "${!upgrade_funcs[@]}"
    do
        if [ "${upgrade_funcs_ret_codes[$i]}" = "$failure" ]
        then
            if [ $failed_info_line_output = false ]
            then
                out_bold "\nFunctions which have failed (in this invocation of $scriptname):\n"
                out_bold "-----------------------------------------------------------------------\n"
                failed_info_line_output=true
            fi
            out_red "${upgrade_func_descs[$i]}\n" | sed -n 1p
        fi
    done
    [[ "$failed_info_line_output" = true ]] &&
        out_bold "-----------------------------------------------------------------------\n"
}

_output_final_report_list_user_skipped () {
    local user_skipped_info_line_output=false

    for i in "${!upgrade_funcs[@]}"
    do
	if [ "${upgrade_funcs_ret_codes[$i]}" = "$user_skipped" ]
        then
            if [ $user_skipped_info_line_output = false ]
            then
                out_bold "\nFunctions which have been skipped by the user (in this invocation of $scriptname):\n"
                out_bold "-----------------------------------------------------------------------------------------\n"
                user_skipped_info_line_output=true
            fi
            out_norm "${upgrade_func_descs[$i]}\n" | sed -n 1p
        fi
    done
    [[ "$user_skipped_info_line_output" = true ]] &&
        out_bold "-----------------------------------------------------------------------------------------\n"
}

output_final_report () {
    local aborting=false
    [[ -n "$1" ]] && "$1" && aborting=true

    out_bold "----------------------- "
    out_bold_green "Report"
    out_bold " -----------------------\n"

    if [ "$aborting" = true ]
    then
        upgrade_funcs_succeeded || _output_final_report_failures
    else
        upgrade_funcs_succeeded && _output_final_report_success || _output_final_report_failures
    fi

    _output_final_report_list_failures
    _output_final_report_list_user_skipped

    out_bold "\nFor additional upgrade information, please visit:\n"
    out_bold "$upgrade_doc\n\n"
}

abort () {
    local msg="$1"
    [[ -n "$msg" ]] && out_bold_red "FATAL: $msg"
    out_bold_red "\nAborting...\n\n"
    output_final_report true
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
	out_bold "$prompt"
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
	assert "${funcname}: Invalid number of arguments (${actual}). Please provide ${expected}.\n"
    fi
}

run_preflight_check () {
    assert_number_of_args $FUNCNAME $# 2

    local func=$1
    shift
    local desc=$1
    shift

    out_debug "DEBUG: about to run pre-flight check ${func}()"
    out_norm "${desc}\n"
    out_norm "\n"

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
    out_norm "\n\n${desc}\n\n"

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
		out_bold "Skipped!\n"
		;;
	    "$failure")
                # Interactive mode failure case fails the current upgrade operation
                # and continues. Non-interactive mode aborts on failure.
		upgrade_funcs_ret_codes[$index]="$failure"
		out_bold_red "Failed!\n"
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
		out_bold "Skipped!\n"
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
_check_ceph_user_belongs_to_ceph_group () {
    local new_ceph_user="ceph"        # SES3+ daemons run as this user.
    local new_ceph_group="ceph"       # SES3+ user "ceph" belongs to this group.

    # 1. If user $new_ceph_user exists and belongs to $new_ceph_group, indicates
    # that we are using the SES3+ ceph user and group format.
    if getent passwd "$new_ceph_user" &>/dev/null
    then
        [[ $(id -g -n "$new_ceph_user") = "$new_ceph_group" ]] && return "$yes"
    fi
    return "$no"
}

running_as_root () {
    test "$EUID" -eq 0
}

user_ceph_not_in_use () {
    # Two possible cases where this function returns success:
    # 1. user ceph is not in use
    # 2. user ceph is in use, but it is not the archane 'ceph' admin user.
    local ceph_user="ceph"

    if ps -u "$ceph_user" &>/dev/null
    then
        _check_ceph_user_belongs_to_ceph_group
    else
        return "$success"
    fi
}

ceph_conf_file_exists () {
    [[ ! -z "$ceph_conf_file" && -e "$ceph_conf_file" ]]
}

_check_parttype () {
    local part_path="$1"
    local expected_parttype_uid="$2"
    local blkid_out="/tmp/ses-upgrade-helper-blkid.out"
    local osd_guide="https://www.suse.com/documentation/ses-${SES_VER}/singlehtml/book_storage_admin/book_storage_admin.html#bp.osd_on_exisitng_partitions"
    local failure_detected=false
    local warning_detected=false

    if ! blkid -o udev -p "$part_path" > "$blkid_out" 2> /dev/null
    then
        # Failed to get valid blkid output. Unable to verify.
        out_warn "${part_path} is an invalid partition.\n"
        out_norm "  This is likely an inactive OSD and may be skipped.\n"
        warning_detected=true
    else
        source "$blkid_out"
        if [ "$ID_PART_ENTRY_SCHEME" != "gpt" ]
        then
            out_err "$part_path is not a GPT partition.\n"
            out_norm "  Fix per $osd_guide\n"
            failure_detected=true
        fi

        if [ "$ID_PART_ENTRY_TYPE" != "$expected_parttype_uid" ]
        then
            out_err "$part_path is of an invalid partition type.\n"
            out_norm "  Fix per $osd_guide\n"
            failure_detected=true
        fi
    fi
    rm "$blkid_out"

    # Failure trumps all other things.
    [[ "$failure_detected" = true ]] && return "$failure"
    [[ "$warning_detected" = true ]] && return "$skipped"
    return "$success"
}

# Verify journal and data partitions are GPT and have the correct partition
# type set.  Otherwise, alert the user and point at how to fix.
check_osd_parttypes () {
    local osd_base_dir=/var/lib/ceph/osd
    local failure_detected=false
    local warning_detected=false
    local data_parttype_uid="4fbd7e29-9d25-41b8-afd0-062c0ceff05d"
    local journal_parttype_uid="45b0969e-9b03-4f30-b4c6-b4b80ceff106"
    local fsid=""

    # Check if the user wants to skip this check.
    [[ "$skip_osd_parttype_check" = true ]] &&
        out_warn "Skipping this check.\n" &&
        return "$success"

    # If no OSD dir found, this is not a storage node, so assume success.
    if [ ! -d "$osd_base_dir" ]
    then
        out_info "$osd_base_dir not found. This does not appear to be a storage node.\n"
        return "$success"
    fi

    for osd_dir in ${osd_base_dir}/*
    do
        out_bold "\nVerifying OSD journal and data paritions for: $osd_dir\n"
        if [ ! -d "$osd_dir" ]
        then
            out_warn "$osd_dir is not a directory. Skipping.\n"
            warning_detected=true
            continue
        fi

        # Verify journal. Skip if journal is a file.
        if [ ! -e "${osd_dir}/journal" ]
        then
            out_warn "${osd_dir}/journal file/symlink not found. Unable to check partition type.\n"
            out_norm "  This is likely an invalid OSD directory and may be skipped.\n"
            warning_detected=true
        elif [ ! -f "${osd_dir}/journal" ]
        then
            _check_parttype "${osd_dir}/journal" "$journal_parttype_uid"
            local func_ret="$?"
            if [ "$func_ret" = "$failure" ]
            then
                failure_detected=true
            elif [ "$func_ret" = "$skipped" ]
            then
                warning_detected=true
            fi
        fi

        # Verify data partition.
        if [ ! -e "${osd_dir}/fsid" ]
        then
            out_warn "${osd_dir}/fsid file not found. Unable to check OSD data partition type.\n"
            out_norm "  This is likely an invalid OSD directory and may be skipped.\n"
            warning_detected=true
        else
            fsid=`cat "${osd_dir}/fsid" 2>/dev/null`
            if [ -z "$fsid" ]
            then
                out_warn "${osd_dir}/fsid does not contain a data fsid. Unable to check partition type.\n"
                out_norm "  This is likely an invalid OSD directory and may be skipped.\n"
                warning_detected=true
            else
                _check_parttype "/dev/disk/by-partuuid/${fsid}" "$data_parttype_uid"
                local func_ret="$?"
                if [ "$func_ret" = "$failure" ]
                then
                    failure_detected=true
                elif [ "$func_ret" = "$skipped" ]
                then
                    warning_detected=true
                fi
            fi
        fi
    done
    out_norm "\n"

    [[ "$failure_detected" = true ]] && return "$failure"

    [[ "$warning_detected" = true ]] &&
        out_bold "Review any OSD partition WARN messages above. If you are confident they are expected and caused by:\n" &&
        out_bold "  1. Invalid OSD directories\n" &&
        out_bold "  2. Inactive OSDs\n" &&
        out_bold "Proceed with the upgrade.\n\n"

    return "$success"
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
In SES2, the user \"ceph\" was created to run ceph-deploy. In SES3 and beyond,
all Ceph daemons run as user and group \"ceph\". Since it is preferable to have no
ordinary \"ceph\" user in the system when the upgrade is performed, this script
will check if there is an existing \"ceph\" user and rename it to \"cephadm\"
if it exists and is not the Ceph daemon user. For this rename operation to work,
the \"ceph\" user must not be in use. (It could be in use, for example, if you
logged in as \"ceph\" and ran this script using sudo.) If this check fails,
find processes owned by user \"ceph\" and terminate those processes. Then re-run
the script."
)

preflight_check_funcs+=("ceph_conf_file_exists")
preflight_check_descs+=(
"Ensure Ceph configuration file exists on the system
===================================================
An existing Ceph configuration file needs to be present on the system in order
for ${scriptname} to extract various aspects of the configuration. The default
configuration file is: ${ceph_conf_file}. This can be overridden with the \`-c\`
option. See: \`${scriptname} -h\`"
)

preflight_check_funcs+=("check_osd_parttypes")
preflight_check_descs+=(
"Check OSD journal and data partition types
===========================================
On a storage node, each directory entry in /var/lib/ceph/osd/ should reflect an
OSD. It should contain a journal file or a link to a journal partition, as well
as an fsid file depicting the UUID of the OSD data partition. OSD journal and data
partitions must be of the correct partition type.
This check will generate a fatal error if the journal or data partitions are of an
invalid partition type and point the admin to a repair guide. The upgrade script
can then be re-run.
This check will generate warnings if an OSD directory is found under
/var/lib/ceph/osd/ that appears invalid/inactive (i.e. contains an invalid/non-existent
\'fsid\' or \'journal\' entry). The admin will then have the option, based on knowledge
of their cluster, to proceed with the upgrade."
)


# ------------------------------------------------------------------------------
# Operations
# ------------------------------------------------------------------------------
stop_ceph_daemons () {
    get_permission || return "$?"

    systemctl stop ceph.target || return "$failure"
}

_rename_ceph_user_sudoers () {
    local sudoers_file="/etc/sudoers"
    local sudoers_dir="/etc/sudoers.d"
    local old_cephadm_user="$1"
    local new_cephadm_user="$2"

    # Ensure usernames are not null.
    [[ -n "$old_cephadm_user" && -n "$new_cephadm_user" ]] ||
        assert "NULL ceph admin user name(s) provided.\n"

    # /etc/sudoers.d/ceph (in SES2.1)
    local sudoers_user_file="${sudoers_dir}/${old_cephadm_user}"

    # If $sudoers_file or $sudoers_user_file do not exist, there is not much
    # we can do here.  Emit a warning and return success.
    [[ ! -e "$sudoers_file" && ! -e "$sudoers_user_file" ]] &&
        out_warn "No sudoers entry or file found for user \"${old_cephadm_user}\".  Skipping.\n" &&
        return "$success"

    # Match all $old_cephadm_user entries that start at the beginning of a line
    # and conclude at a word boundary. Replace with $new_cephadm_user.
    # sed returns 0 whether or not matches occur.
    if [ -e "$sudoers_file" ]
    then
        sed -i "s/^${old_cephadm_user}\b/${new_cephadm_user}/g" "$sudoers_file" ||
            return "$failure"
    fi

    # Also possible that instead of /etc/sudoers, the admin user's sudo status
    # is represented by a file in /etc/sudoers.d/${old_cephadm_user}.
    if [ -e "$sudoers_user_file" ]
    then
        sed -i "s/^${old_cephadm_user}\b/${new_cephadm_user}/g" "$sudoers_user_file" ||
            return "$failure"
        mv "$sudoers_user_file" "${sudoers_dir}/${new_cephadm_user}" ||
            return "$failure"
    fi

    return "$success"
}

rename_ceph_user () {
    local old_cephadm_user="ceph"     # Our old SES2 cephadm user (ceph-deploy).
    local new_cephadm_user="cephadm"  # Our new SES3+ cephadm user (ceph-deploy).
    local new_ceph_user="ceph"        # SES3+ daemons run as this user.
    local new_ceph_group="ceph"       # SES3+ user "ceph" belongs to this group.
    local not_complete=false

    # Local preflight checks.
    # 1. If user $new_ceph_user exists and belongs to $new_ceph_group, skip this
    #    upgrade function.
    _check_ceph_user_belongs_to_ceph_group && return "$skipped"
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
    # signalling that the $old_cephadm_user no longer exists (i.e. because we have
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
    [[ -z "$new_cephadm_group" ]] && out_bold_red "FATAL: could not determine gid of new cephadm user" && return "$func_abort"
    [[ "$new_cephadm_group" = "ceph" ]] && out_bold_red "FATAL: new cephadm user is in group \"ceph\" - this is not allowed!" && return "$func_abort"

    _rename_ceph_user_sudoers "$old_cephadm_user" "$new_cephadm_user" || return "$failure"

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
    # If get_radosgw_conf_section_names() legitimately fails, then we return
    # $func_abort. Since this is a preflight, we don't want to loop in
    # run_upgrade_func(), so return $func_abort instead of $failure.
    radosgw_conf_section_names=$(get_radosgw_conf_section_names) || return "$func_abort"
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
    out_bold "The following enabled RADOSGW instances have been selected for disablement on this node:\n"
    for rgw_service_instance in "${enabled_rgw_instances[@]}"
    do
        out_norm "  $rgw_service_instance\n"
    done
    out_norm "\n"
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
    local ceph_auto_restart_on_upgrade_val=""

    [[ ! -e "$ceph_sysconfig_file" ]] && return "$skipped"

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

    # If the tmp file does not exist, create and echo existing value for later restoration
    [[ ! -e "$ceph_auto_restart_on_upgrade_datafile" ]] &&
        echo "${ceph_auto_restart_on_upgrade_var}=${ceph_auto_restart_on_upgrade_val}" > "$ceph_auto_restart_on_upgrade_datafile"

    sed -i "s/^${ceph_auto_restart_on_upgrade_var}.*/${ceph_auto_restart_on_upgrade_var}=no/" "$ceph_sysconfig_file"
}

zypper_dup () {
    get_permission || return "$?"

    if [ "$interactive" = true ]
    then
	zypper dist-upgrade || return "$failure"
    else
	zypper --non-interactive dist-upgrade --auto-agree-with-licenses || return "$failure"
    fi
}

restore_original_restart_on_update () {
    local ceph_auto_restart_on_upgrade_val=""

    # Local preflight checks
    [[ -e "$ceph_auto_restart_on_upgrade_datafile" ]] || return "$skipped"

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
    done <"$ceph_auto_restart_on_upgrade_datafile"
    # Restore local $IFS to global version.
    IFS="$G_IFS"

    sed -i "s/^${ceph_auto_restart_on_upgrade_var}.*/${ceph_auto_restart_on_upgrade_var}=${ceph_auto_restart_on_upgrade_val}/" "$ceph_sysconfig_file"
    rm "$ceph_auto_restart_on_upgrade_datafile"
}

chown_var_lib_ceph () {
    # Local preflight checks
    [[ -d "/var/lib/ceph" ]] || return "$skipped"

    get_permission || return "$?"

    out_info "This may take some time depending on the number of files on the OSD mounts.\n"
    chown -R ceph:ceph /var/lib/ceph || return "$failure"
}

chown_var_log_ceph () {
    # Local preflight checks
    [[ -d "/var/log/ceph" ]] || return "$skipped"

    get_permission || return "$?"

    chown -R ceph:ceph /var/log/ceph || return "$failure"
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
    out_bold "The following RADOSGW instances have been disabled on this node and can now be properly re-enabled:\n"
    for rgw_service_instance in "${disabled_rgw_instances[@]}"
    do
        out_norm "  $rgw_service_instance\n"
    done
    out_norm "\n"
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
        out_bold_red "\nThe following disabled RADOSGW instances were not properly re-enabled:\n"
        out_norm "$ceph_radosgw_disabled_services_datafile:\n"
        cat "$ceph_radosgw_disabled_services_datafile"
        out_norm "\n"
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
SES2 ran \`ceph-deploy\` under the username \"ceph\". With SES3
and beyond, Ceph daemons run as user \"ceph\" in group \"ceph\". The
upgrade scripting will create these with the proper parameters, provided
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
This step upgrades the packages on the system by running \"zypper dist-upgrade\".
If you prefer to upgrade by some other means (e.g. SUSE Manager), do that now, but
do not reboot the system - just select \"No\" to skip this step when the
package upgrade finishes."
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
upgrade_funcs+=("chown_var_log_ceph")
upgrade_func_descs+=(
"Set ownership of /var/log/ceph
==============================
Recursively set the ownerhip of /var/log/ceph to ceph:ceph. All ceph daemons
in SES3 and beyond will run as user \"ceph\"."
)
upgrade_funcs+=("enable_radosgw_services")
upgrade_func_descs+=(
"Re-enable RADOS Gateway services
================================
Now that the ceph packages have been upgraded, we re-enable the RGW
services using the SES3, and beyond, naming convention. There is no danger
in answering Yes here. If there are no RADOS Gateway instances configured on
this node, the step will be skipped automatically."
)
upgrade_funcs+=("standardize_radosgw_logfile_location")
upgrade_func_descs+=(
"Configure RADOS Gateway instances to log in default location
============================================================
SES2 ceph-deploy added a \"log_file\" entry to ceph.conf setting a custom
location for the RADOS Gateway log file in ceph.conf. In SES3 and beyond,
the best practice is to let the RADOS Gateway log to its default location,
\"/var/log/ceph\", like the other Ceph daemons. If in doubt, just say Yes."
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

# By default, verify OSD partition types, but provide a switch to disable this
# check.
skip_osd_parttype_check=false

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
        -s | --skip-osd-parttype-check)
            skip_osd_parttype_check=true
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

out_bold_green "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n"
out_bold_green "===== Welcome to the SES-${SES_VER} Upgrade =====\n"
out_bold_green "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n"
out_bold_green "\n"
out_bold_green "Running pre-flight checks...\n"
out_bold_green "\n"

preflight_failures=false
for i in "${!preflight_check_funcs[@]}"
do
    if run_preflight_check "${preflight_check_funcs[$i]}" "${preflight_check_descs[$i]}"
    then
        out_bold_green "PASSED\n\n"
    else
        out_bold_red "FAILED\n\n"
        preflight_failures=true
    fi
done
[[ "$preflight_failures" = true ]] && abort "One or more pre-flight checks failed\n"

out_bold_green "\nRunning upgrade functions...\n"

for i in "${!upgrade_funcs[@]}"
do
    run_upgrade_func "${upgrade_funcs[$i]}" "${upgrade_func_descs[$i]}" "$i"
done

out_bold_green "\n-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n"
out_bold_green "========== SES-${SES_VER} Upgrade Script has Finished ==========\n"
out_bold_green "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n\n"

output_final_report
