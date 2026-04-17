#!/usr/bin/env bash

# ==============================================================================
# usb-backup-scrub-now.sh
# External Btrfs USB Manual Scrub Script
#
# github.com/cygnick6/arch-linux-systems-design/btrfs-usb-backup
#
## LOGGING CONTEXT ##
# - log() and stdout are sent to journald and to local LOG_FILE
# - error() and stderr are sent to journald and to local ERROR_LOG_FILE
# - Btrfs scrub output is logged to local SCRUB_DUMP_LOG_FILE
#
## SCRUB STATUS FILE CONTEXT ##
# - The result of the last successful scrub is saved to LAST_SCRUB_RESULT_FILE
#
## SOURCING CONTEXT ##
# This script sources:
# - usb-backup.conf
# - usb-backup-lib.sh
#
## FLAG FILE CONTEXT: 'scrub-in-progress ##
# - Both this script (usb-backup-scrub-now.sh) and usb-backup-main.sh automatically
#       create and remove the flag file 'scrub-in-progress'
#
## EXECUTION CONTEXT ##
# - This script is only ever executed manually by the user
#
# This script:
# - Uses flock to detect if another usb-backup operation is running
# - Mounts the target USB device
# - Manually executes a scrub of the target USB device
# - Resets SCRUB_COUNTDOWN_FILE, rather than conditionally decrementing
# - Unmounts the target USB device
# ==============================================================================

################################################################################
# INITIALIZE
################################################################################

set -euo pipefail
set -o errtrace
IFS=$'\n\t'
umask 077

################################################################################
# SOURCE CONF & LIB
################################################################################

_CONF_FILE="/etc/usb-backup.conf"
_LIB_FILE="/usr/lib/usb-backup/usb-backup-lib.sh"

if [[ -f "$_CONF_FILE" ]]; then

    source "$_CONF_FILE"

    if [[ -z "$USER_UID" && -n "$USER_NAME" ]]; then

        USER_UID=$(id -u "$USER_NAME")

    fi

else

    echo "usb-backup.conf not found - exiting" >&2
    exit 1

fi

if [[ -f "$_LIB_FILE" ]]; then

    source "$_LIB_FILE"

else

    echo "usb-backup-lib.sh not found - exiting" >&2
    exit 1

fi

################################################################################
# LOGGING
################################################################################

stdout_stderr_log_to_file

################################################################################
# ERROR & CLEANUP HANDLER
################################################################################

cleanup_handler() {

    notify "Manual scrub error"

    log "Starting cleanup"

    unmount_usb_drive

    log "Finished cleanup"
    log_declare "usb-backup-scrub-now.sh exited with errors"

}

trap error_handler ERR

################################################################################
# PREPARE LOCAL DIRECTORIES
################################################################################

prepare_local_directories

################################################################################
# DECLARATION
################################################################################

log_declare "usb-backup-scrub-now.sh started"

################################################################################
# VALIDATE CONF
################################################################################

validate_user_name_conf
validate_high_priority_conf

################################################################################
# CHECK IF EXECUTED AS ROOT
################################################################################

if [[ "$EUID" -ne 0 ]]; then

    printf "This script must be run as root\n" >&2
    printf "Use a privilege escalation utility such as sudo\n" >&2
    error "usb-backup-status.sh not executed as root"
    exit 1

fi

################################################################################
# DETECT TARGET DEVICE
################################################################################

detect_usb_drive manual

################################################################################
# LOCK FILE SYSTEM
################################################################################

lock_fs manual

################################################################################
# MOUNT TARGET DEVICE
################################################################################

mount_usb_drive manual

################################################################################
# SCRUB MANUAL EXECUTION
################################################################################

scrub_management manual

################################################################################
# FINALIZE
################################################################################

printf "Manual Btrfs scrub finished\n"

log_declare "usb-backup-scrub-now.sh finished"
