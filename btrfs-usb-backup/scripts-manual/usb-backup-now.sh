#!/usr/bin/env bash

# ==============================================================================
# usb-backup-now.sh
# External Btrfs USB Manual Backup Script
#
# github.com/cygnick6/arch-linux-systems-design/btrfs-usb-backup
#
## LOGGING CONTEXT ##
# - log() and stdout are sent to journald and to local LOG_FILE
# - error() and stderr are sent to journald and to local ERROR_LOG_FILE
#
## SOURCING CONTEXT ##
# This script sources:
# - usb-backup.conf
# - usb-backup-lib.sh
#
## EXECUTION CONTEXT ##
# - This script is only ever executed manually by the user
#
# This script:
# - Manually creates the 'backup-due' flag file, rather than waiting
#   for the usb-backup-reminder.timer to do so
#       - usb-backup-reminder.timer is unaffected by this
# - Manually attempts to executes usb-backup-main.sh, which will operate
#       normally
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

    notify "Manual backup error"
    log_declare "usb-backup-now.sh exited with errors"

}

trap error_handler ERR

################################################################################
# PREPARE LOCAL DIRECTORIES
################################################################################

prepare_local_directories

################################################################################
# DECLARATION
################################################################################

log_declare "usb-backup-now.sh started"
notify "Manual backup requested"

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
# CREATE FLAG backup-due
################################################################################

touch "$BACKUP_DUE_FLAG"

log "Created backup-due flag"

################################################################################
# PROMPT FOR BACKUP
################################################################################

printf "Manually prompting for backup\n"
log "Launching usb-backup-main.sh"

systemctl start usb-backup-main.service

################################################################################
# FINALIZE
################################################################################

log_declare "usb-backup-now.sh finished"
