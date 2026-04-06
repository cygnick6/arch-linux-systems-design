#!/usr/bin/env bash

# ==============================================================================
# usb-backup-lib.sh
# btrfs-usb-backup System Library Script
#
# github.com/cygnick6/arch-linux-systems-design/btrfs-usb-backup
#
## SOURCING CONTEXT ##
# This script assumes that usb-backup.conf was sourced directly before sourcing
#     this script
#
## EXECUTION CONTEXT ##
# This script is sourced by:
# - usb-backup-now.sh
# - usb-backup-reminder.sh
# - usb-backup-status.sh
# - usb-backup-main.sh
# - usb-backup-scrub-now.sh
#
# This script:
# - Defines functions used in all backup scripts
# ==============================================================================

################################################################################
# INITIALIZE
################################################################################

set -o errtrace
IFS=$'\n\t'

################################################################################
# LOGGING FUNCTIONS
################################################################################

stdout_stderr_log_to_file() {

    if [[ "$LOG_TO_FILE" == "true" ]]; then

        exec > >(tee -a "$LOG_FILE")
        exec 2> >(tee -a "$ERROR_LOG_FILE" >&2)

    fi

}

log_declare() {

    local msg

    msg="$(date --iso-8601=seconds) [usb-backup] $*"

    printf -- "----------------------------------------\n"
    printf -- "%s\n" "$msg"
    printf -- "----------------------------------------\n"

}

log() {

    local msg

    msg="$(date --iso-8601=seconds) [usb-backup] $*"

    printf "%s\n" "$msg"

}

error() {

    local msg

    msg="$(date --iso-8601=seconds) [usb-backup] ERROR: $*"

    printf "%s\n" "$msg" >&2

}

run_step() {

    local description="$1"
    local command="$2"
    local disk_path="${3:-}"

    log "STEP START   | $description"
    log "STEP CMD     | $command"

    local start_time
    start_time=$(date +%s)

    local disk_before=""

    if [[ -n "$disk_path" ]] && mountpoint -q "$disk_path"; then

        disk_before=$(df -h --output=used "$disk_path" | tail -1 | xargs)
        log "STEP DISK    | before=$disk_before path=$disk_path"

    fi

    local stderr_tmp=$(mktemp)

    set +e
    bash -o pipefail -c "$command" 2> >(tee -a "$stderr_tmp" >&2)
    rc=$?
    set -e

    local end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    if [[ -n "$disk_path" ]] && mountpoint -q "$disk_path"; then

        local disk_after
        disk_after=$(df -h --output=used "$disk_path" | tail -1 | xargs)
        log "STEP DISK    | after=$disk_after path=$disk_path"

    fi

    if (( rc == 0 )); then

        log "STEP SUCCESS | $description | duration=${duration}s"

    else

        error "STEP FAIL    | $description | rc=$rc | duration=${duration}s"

        if [[ -s "$stderr_tmp" ]]; then

            error "STEP STDERR  | $description"
            sed 's/^/stderr: /' "$stderr_tmp" >&2

        fi

    fi

    rm -f "$stderr_tmp"

    if (( rc != 0 )); then

        error "$description failed"

    fi

    return $rc

}

run_step_cmd() {

    local description="$1"
    local disk_path="$2"
    local cmd

    cmd=$(cat)
    run_step "$description" "$cmd" "$disk_path"

}

################################################################################
# NOTIFICATION FUNCTION
################################################################################

# Send desktop notifications via the user's DBus session

notify() {

    local msg="$*"

    _USER_UID="$(id -u "$USER_NAME" 2>/dev/null || true)"

    if [[ "$NOTIFY_USER" != "true" ]] || \
       [[ -z "$USER_NAME" ]] || \
       [[ -z "$_USER_UID" ]] || \
       [[ ! -S "/run/user/$_USER_UID/bus" ]] || \
       ! command -v notify-send >/dev/null 2>&1; then

        return

    fi

    sudo -u "$USER_NAME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$_USER_UID/bus" \
        notify-send "USB Backup" "$msg"

}

################################################################################
# VALIDATE USER_NAME CONF
################################################################################

validate_user_name_conf () {

    if [[ "$NOTIFY_USER" == "true" ]] && [[ -z "$USER_NAME" ]]; then

        log "Manual configuration of usb-backup.conf required - \
             configure USER_NAME for notifications"
        error "Manual configuration of usb-backup.conf required - \
               configure USER_NAME for notifications"
        exit 1

    fi

}

################################################################################
# VALIDATE BACKUP_UUID CONF
################################################################################

validate_backup_uuid_conf () {

    if [[ -z "$BACKUP_UUID" ]]; then

        log "Manual configuration of usb-backup.conf required - \
             configure BACKUP_UUID"
        error "Manual configuration of usb-backup.conf required - \
               configure BACKUP_UUID"
        notify "Manual config needed in usb-backup.conf"
        exit 1

    fi

}

################################################################################
# PREPARE LOCAL DIRECTORIES FUNCTION
################################################################################

prepare_local_directories() {

    mkdir -p "$LOCAL_ROOT_SNAP_DIR" "$LOCAL_HOME_SNAP_DIR" "$LOCK_DIR" \
             "$STATE_DIR" "$STATE_COUNTER_DIR" "$STATE_FLAG_DIR" \
             "$STATE_TIMESTAMP_DIR" "$LOG_DIR"

    chmod 700 "$STATE_DIR"
    chmod 700 "$LOCK_DIR"

}

################################################################################
# LOCK FILE SYSTEM FUNCTION
################################################################################

lock_fs() {

    local arg="${1:-}"

    local manual=false
    if [[ "$arg" == "manual" ]]; then

        manual=true

    fi

    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then

        log "Backup or scrub already running - quietly exiting"

        if [[ "$manual" == "true" ]]; then

            printf "Backup or scrub already running - quietly exiting\n"

        fi

        exit 0

    fi

}

################################################################################
# DETECT DEVICE FUNCTION
################################################################################

detect_usb_drive() {

    local arg="${1:-}"

    local manual=false
    if [[ "$arg" == "manual" ]]; then

        manual=true

    fi

    _DEVICE_UUID=$(blkid -U "$BACKUP_UUID" 2>/dev/null || true)

    if [[ -z "$_DEVICE_UUID" ]]; then

        log "Backup device not found - exiting quietly"

        if [[ "$manual" == "true" ]]; then

            printf "Backup device not found - exiting quietly\n"

        fi

        exit 0

    fi

    _LABEL=$(blkid -o value -s LABEL "$_DEVICE_UUID")

    if [[ "$_LABEL" != "$BACKUP_LABEL" ]]; then

        error "Detected device label $_LABEL is not target label \
               $BACKUP_LABEL - exiting"

        if [[ "$manual" == "true" ]]; then

            printf "Detected device label $_LABEL is not target label \
               $BACKUP_LABEL - exiting\n"

        fi

        exit 1

    fi

    _FSTYPE=$(blkid -o value -s TYPE "$_DEVICE_UUID")

    if [[ "$_FSTYPE" != "btrfs" ]]; then

        error "Detected device $_LABEL not Btrfs - exiting"

        if [[ "$manual" == "true" ]]; then

            printf "Detected device $_LABEL not Btrfs - exiting\n"

        fi

        exit 1

    fi

    log "Viable backup device detected. Label: $_LABEL; UUID: $_DEVICE_UUID"

    if [[ "$manual" == "true" ]]; then

        printf "Viable backup device detected\n"

    fi

}

################################################################################
# MOUNT FUNCTION
################################################################################

mount_usb_drive() {

    local arg="${1:-}"

    local manual=false
    if [[ "$arg" == "manual" ]]; then

        manual=true

    fi

    mkdir -p "$MOUNTPOINT"

    if ! mountpoint -q "$MOUNTPOINT"; then

        mount -o noatime UUID="$BACKUP_UUID" "$MOUNTPOINT"

    fi

    _MOUNTED_UUID=$(blkid -s UUID -o value \
        "$(findmnt -n -o SOURCE "$MOUNTPOINT")")
    _MOUNTED_LABEL=$(findmnt -n -o LABEL "$MOUNTPOINT")

    if [[ "$_MOUNTED_UUID" != "$BACKUP_UUID" ]]; then

        error "Incorrect device mounted at $MOUNTPOINT. \
               Label: $_MOUNTED_LABEL; UUID: $_MOUNTED_UUID"
        printf "Incorrect device mounted at $MOUNTPOINT. \
               Label: $_MOUNTED_LABEL; UUID: $_MOUNTED_UUID) - exiting\n"
        exit 1

    fi

    if ! findmnt -n -o FSTYPE "$MOUNTPOINT" | grep -q btrfs; then

        error "Mountpoint file system is not Btrfs after mounting - exiting"

        if [[ "$manual" == "true" ]]; then

            printf "Mountpoint file system is not Btrfs after mounting \
                    - exiting\n"

        fi

        exit 1

    fi

    log "Backup drive mounted. Label: $_MOUNTED_LABEL; UUID: $_MOUNTED_UUID"

    if [[ "$manual" == "true" ]]; then

        printf "Backup drive mounted\n"

    fi

}

################################################################################
# UNMOUNT FUNCTION
################################################################################

unmount_usb_drive() {

    local arg="${1:-}"

    local manual=false
    if [[ "$arg" == "manual" ]]; then

        manual=true

    fi

    log "Attempting to unmount target USB"

    if mountpoint -q "$MOUNTPOINT"; then

        if umount "$MOUNTPOINT"; then

            log "Backup drive unmounted successfully"
            notify "Unmount successful"

            if [[ "$manual" == "true" ]]; then

                printf "Backup drive umounted successfully\n"

            fi

        else

            log "Backup drive busy - attempting again"

            sleep 1

            if umount "$MOUNTPOINT"; then

                log "Backup drive unmounted successfully - second attempt"

                if [[ "$manual" == "true" ]]; then

                    printf "Backup drive umounted successfully - second attempt\n"

                fi

            else

                log "Backup drive busy - attempting lazy unmount"

                if umount -l "$MOUNTPOINT"; then

                    log "Lazy unmount successful - \
                         two failed normal unmount attempts prior"

                    if [[ "$manual" == "true" ]]; then

                        printf "Backup drive umounted lazily - \
                                two failed normal unmount attempts prior\n"

                    fi

                else

                    error "Failed to unmount backup drive"
                    notify "Unmount failed"

                    if [[ "$manual" == "true" ]]; then

                        printf "Error: failed to unmount backup drive\n"

                    fi

                    exit 1

                fi

            fi

        fi

    else

        log "No device mounted at "$MOUNTPOINT" - skipping unmount"

    fi

}

################################################################################
# SCRUB MANAGEMENT FUNCTION
################################################################################

scrub_management() {

    local arg="${1:-}"

    local manual=false
    if [[ "$arg" == "manual" ]]; then

        manual=true

    fi

    if [[ "$SCRUB" != "true" ]] && [[ "$manual" == "false" ]]; then

        return

    fi

    date --iso-8601=seconds > "$LAST_SCRUB_PROMPT_TIMESTAMP_FILE"

    log "Evaluating scrub countdown"

    if [[ ! -f "$SCRUB_COUNTDOWN_FILE" ]]; then

        echo "$SCRUB_INTERVAL" > "$SCRUB_COUNTDOWN_FILE"
        log "Initialized scrub-countdown to $SCRUB_INTERVAL"

    fi

    local -i count

    if [[ "$manual" == true ]]; then

        count=0
        log "Manual scrub requested"

    else

        count=$(<"$SCRUB_COUNTDOWN_FILE" 2>/dev/null || echo "$SCRUB_INTERVAL")

        if ! [[ "$count" =~ ^[0-9]+$ ]]; then

            log "Invalid scrub-countdown value - resetting"

            count="$SCRUB_INTERVAL"
        fi

    fi

    if (( count <= 0 )); then

        touch "$SCRUB_IN_PROGRESS_FLAG"

        log "Scrub starting on $MOUNTPOINT"
        notify "Btrfs scrub starting"

        date --iso-8601=seconds > "$LAST_SCRUB_ATTEMPT_TIMESTAMP_FILE"

        if [[ "$LOG_TO_FILE" == "true" ]] && \
           [[ "$LOG_FILE_SCRUB_DUMP" == "true" ]]; then

            btrfs scrub start -B -R "$MOUNTPOINT" >> "$SCRUB_DUMP_LOG_FILE" 2>&1

        else

            btrfs scrub start -B -R "$MOUNTPOINT" > /dev/null 2>&1

        fi

        local scrub_execution_status=$?
        if (( scrub_execution_status == 0 )); then

            count=$((count - 1))

            increment_count_file "$SCRUB_SUCCESS_COUNT_FILE"

            date --iso-8601=seconds > "$LAST_SCRUB_SUCCESS_TIMESTAMP_FILE"

            local status=$(btrfs scrub status -R "$MOUNTPOINT")
            local error_line=$(echo "$status" | grep "error summary")
            if echo "$error_line" | grep -Eq '=[1-9]'; then

                echo "ERRORS DETECTED" > "$LAST_SCRUB_RESULT_FILE"
                log "Scrub completed successfully"
                log "Scrub status: ERRORS DETECTED"
                error "Scrub status: ERRORS DETECTED"
                notify "Btrfs scrub finished. Status: ERRORS DETECTED"
                notify "USB backup drive may be corrupted"

            else

                echo "OK" > "$LAST_SCRUB_RESULT_FILE"
                log "Scrub completed successfully"
                log "Scrub status: OK"
                notify "Btrfs scrub finished. Status: OK"

            fi

        else

            error "Scrub failed"
            notify "Btrfs scrub failed"

        fi

        if [[ "$manual" == "true" ]] && \
           [[ "$MANUAL_SCRUB_RESETS_COUNTDOWN" == "true" ]]; then

            echo "$SCRUB_INTERVAL" > "$SCRUB_COUNTDOWN_FILE"
            log "scrub-countdown reset to $SCRUB_INTERVAL"

        elif [[ "$manual" == "false" ]]; then

            echo "$count" > "$SCRUB_COUNTDOWN_FILE"
            log "scrub-countdown value: $count"

        fi

    fi

    rm -f "$SCRUB_IN_PROGRESS_FLAG"

}

################################################################################
# INCREMENT COUNT FILE FUNCTION
################################################################################

increment_count_file() {

    local count_file="$1"

    if [[ ! -f "$count_file" ]]; then

        echo 0 > "$count_file"

    fi

    local previous_value=$(<"$count_file")
    ((previous_value++))
    echo "$previous_value" > "$count_file"

}
