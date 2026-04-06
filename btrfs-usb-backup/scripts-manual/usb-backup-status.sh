#!/usr/bin/env bash

# ==============================================================================
# usb-backup-status.sh
# External Btrfs USB Backup Status Script
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
# - Prints the health, usage, status of the overall backup system.
# ==============================================================================

################################################################################
# INITIALIZE
################################################################################

set -euo pipefail
set -o errtrace
IFS=$'\n\t'
shopt -s nullglob
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

    notify "System status retrieval error"
    log_declare "usb-backup-status.sh exited with errors"

}

trap error_handler ERR

################################################################################
# PREPARE LOCAL DIRECTORIES
################################################################################

prepare_local_directories

################################################################################
# VALIDATE CONF
################################################################################

validate_user_name_conf
validate_backup_uuid_conf

################################################################################
# DECLARATION
################################################################################

log_declare "usb-backup-status.sh started"

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
# COUNT PAIRED SNAPS FUNCTION
################################################################################

count_paired_snaps () {

    local local_dir="$1"
    local remote_dir="$2"

    local count=0

    for s in "$local_dir"/*; do

        s="${s##*/}"

        if [[ -d "$remote_dir/$s" ]]; then

            ((count++))

        fi

    done

    echo "$count"
}


################################################################################
# COUNT UNPAIRED SNAPS FUNCTION
################################################################################

count_unpaired_snaps() {

    local target_dir="$1"
    local partner_dir="$2"

    local count=0

    for s in "$target_dir"/*; do

        s="${s##*/}"

        if [[ ! -d "$partner_dir/$s" ]]; then

            ((count++))

        fi

    done

    echo "$count"
}


################################################################################
# PRINT FILE CONTENTS FUNCTION
################################################################################

print_file_contents() {

    local text="$1"
    local file="$2"

    if [[ -f "$file" ]]; then

        printf "%-35s %s\n" "$text:" "$(<"$file")"

    else

        printf "%-35s %s\n" "$text:" "file not created yet"

    fi

}

################################################################################
# PRINT STATUS
################################################################################

printf "============================\n"
printf "= USB Backup System Status =\n"
printf "============================\n"
printf "\n"

# Schedule

printf "Schedule:\n"
printf -- "---------\n"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then

    printf "Backup or scrub currently running\n"

else

    if [[ -f "$BACKUP_DUE_FLAG" ]]; then

        printf "Backup ready to start\n"

    else

        printf "Backup not scheduled right now\n"

    fi

fi

printf "\n"

# Target backup device

printf "Target Backup Device Status:\n"
printf -- "----------------------------\n"

_DEVICE_UUID=$(blkid -U "$BACKUP_UUID" 2>/dev/null || true)

if [[ -z "$_DEVICE_UUID" ]]; then

    printf "Currently not detectable\n"

else

    printf "Currently detectable\n"

fi

printf "\n"

# Paired snapshot counts

_ROOT_PAIRED_SNAPS_COUNT=$(count_paired_snaps \
    "$LOCAL_ROOT_SNAP_DIR" "$DEST_ROOT_SNAP_DIR")

_HOME_PAIRED_SNAPS_COUNT=$(count_paired_snaps \
    "$LOCAL_HOME_SNAP_DIR" "$DEST_HOME_SNAP_DIR")

printf "Existing Paired Snapshot Count / Max:\n"
printf -- "-------------------------------------\n"

printf "%-35s %s\n" "Root" "$_ROOT_PAIRED_SNAPS_COUNT / $MAX_ROOT_PAIRED_SNAPS"
printf "%-35s %s\n" "Home" "$_HOME_PAIRED_SNAPS_COUNT / $MAX_HOME_PAIRED_SNAPS"

printf "\n"

# Unpaired snapshot counts

if (( MAX_ROOT_UNPAIRED_SNAPS + MAX_HOME_UNPAIRED_SNAPS != 0 )); then

    _LOCAL_ROOT_UNPAIRED_SNAPS_COUNT=$(count_unpaired_snaps \
        "$LOCAL_ROOT_SNAP_DIR" "$DEST_ROOT_SNAP_DIR")

    _REMOTE_ROOT_UNPAIRED_SNAPS_COUNT=$(count_unpaired_snaps \
        "$DEST_ROOT_SNAP_DIR" "$LOCAL_ROOT_SNAP_DIR")

    _LOCAL_HOME_UNPAIRED_SNAPS_COUNT=$(count_unpaired_snaps \
        "$LOCAL_HOME_SNAP_DIR" "$DEST_HOME_SNAP_DIR")

    _REMOTE_HOME_UNPAIRED_SNAPS_COUNT=$(count_unpaired_snaps \
        "$DEST_HOME_SNAP_DIR" "$LOCAL_HOME_SNAP_DIR")

    printf "Unpaired snapshots:\n"
    printf -- "-------------------\n"

    printf "%-35s %s\n" "Local root" "$_LOCAL_ROOT_UNPAIRED_SNAPS_COUNT"
    printf "%-35s %s\n" "Remote root" "$_REMOTE_ROOT_UNPAIRED_SNAPS_COUNT"

    printf "%-35s %s\n" \
           "Total unpaired root / max" \
           "$((_LOCAL_ROOT_UNPAIRED_SNAPS_COUNT + \
               _REMOTE_ROOT_UNPAIRED_SNAPS_COUNT)) / \
           $MAX_ROOT_UNPAIRED_SNAPS"

    printf "%-35s %s\n" "Local home" "$_LOCAL_HOME_UNPAIRED_SNAPS_COUNT"
    printf "%-35s %s\n" "Remote home" "$_REMOTE_HOME_UNPAIRED_SNAPS_COUNT"

    printf "%-35s %s\n" \
        "Total unpaired home / max" \
        "$((_LOCAL_HOME_UNPAIRED_SNAPS_COUNT + \
            _REMOTE_HOME_UNPAIRED_SNAPS_COUNT)) / $MAX_HOME_UNPAIRED_SNAPS"

    printf "\n"

fi

# /home rsync

printf "File-level /home rsync:\n"
printf -- "-----------------------\n"

if [[ -d "$DEST_HOME_RSYNC_DIR" ]] && \
   compgen -G "$DEST_HOME_RSYNC_DIR/*" > /dev/null; then

    printf "%-35s %s\n" "File-level rsync /home backup" "Exists"

else

    printf "%-35s %s\n" "File-level rsync /home backup" "Does not exist"

fi

printf "\n"

# Backups

printf "Backup Status:\n"
printf -- "--------------\n"

print_file_contents "First backup success" \
    "$FIRST_BACKUP_SUCCESS_TIMESTAMP_FILE"

print_file_contents "Last backup prompt" \
    "$LAST_BACKUP_PROMPT_TIMESTAMP_FILE"

print_file_contents "Last backup attempt" \
    "$LAST_BACKUP_ATTEMPT_TIMESTAMP_FILE"

print_file_contents "Last backup success" \
    "$LAST_BACKUP_SUCCESS_TIMESTAMP_FILE"

print_file_contents "Total successful backups" \
    "$BACKUP_SUCCESS_COUNT_FILE"

printf "\n"

# Scrubs

printf "Scrub Status:\n"
printf -- "-------------\n"

print_file_contents "Last scrub prompt" "$LAST_SCRUB_PROMPT_TIMESTAMP_FILE"

print_file_contents "Last scrub attempt" "$LAST_SCRUB_ATTEMPT_TIMESTAMP_FILE"

print_file_contents "Last scrub success" "$LAST_SCRUB_SUCCESS_TIMESTAMP_FILE"

print_file_contents "Backups since last scrub attempt" "$SCRUB_COUNTDOWN_FILE"

print_file_contents "Total successful scrubs" "$SCRUB_SUCCESS_COUNT_FILE"

printf "\n"

# Backup drive health

printf "USB Backup Drive Health:\n"
printf -- "------------------------\n"

print_file_contents "At last successful scrub" "$LAST_SCRUB_RESULT_FILE"

################################################################################
# FINALIZE
################################################################################

log_declare "usb-backup-status.sh finished"
