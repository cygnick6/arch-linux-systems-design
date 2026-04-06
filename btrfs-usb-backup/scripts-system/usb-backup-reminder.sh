#!/usr/bin/env bash

# ==============================================================================
# usb-backup-reminder.sh
# External Btrfs USB Backup Reminder Script
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
# - usb-backup-reminder.timer triggers usb-backup-reminder.service, which
#       executes this script
#
# This script:
# - Creates the flag file 'backup-due', which is necessary for the backup to
#       initialize
# - Reminds the user to insert the target USB device
# - Attempt to trigger the backup script, in case the target USB device is
#       already inserted
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
# ERROR HANDLER
################################################################################

error_handler() {

    error "Error on usb-backup-reminder.sh line $LINENO"
    notify "Backup reminder error"
    log_declare "usb-backup-reminder.sh exited with errors"
    exit 1

}

trap error_handler ERR

################################################################################
# PREPARE LOCAL DIRECTORIES
################################################################################

prepare_local_directories

################################################################################
# DECLARATION
################################################################################

log_declare "usb-backup-reminder.sh started"

################################################################################
# VALIDATE CONF
################################################################################

validate_user_name_conf
validate_backup_uuid_conf

################################################################################
# CREATE FLAG FILE backup-due
################################################################################

touch "$BACKUP_DUE_FLAG"

log "Created backup-due flag"

################################################################################
# NOTIFY USER
################################################################################

notify "Reminder - insert target USB device to backup"

################################################################################
# ATTEMPT BACKUP
################################################################################

log "Attempting backup in case target USB device is detectable"

systemctl start usb-backup-main.service

################################################################################
# FINALIZE
################################################################################

log_declare "usb-backup-reminder.sh finished"
