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

set -euo pipefail
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

################################################################################
# ERROR HANDLER
################################################################################

error_handler() {

    local exit_code=$?
    local func src line

    error "Error occurred. Exit code: $exit_code"
    error "Stack trace:"

    for i in "${!FUNCNAME[@]}"; do

        func="${FUNCNAME[$i]}"
        src="${BASH_SOURCE[$i]}"
        line="${BASH_LINENO[$((i-1))]}"

        [[ "$i" -eq 0 ]] && continue

        error "  at ${func} (${src}:${line})"

    done

    cleanup_handler

    exit "$exit_code"

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
        return 1

    fi

}

################################################################################
# VALIDATE HIGH PRIORITY CONF
################################################################################

validate_high_priority_conf () {

    if [[ -z "$BACKUP_UUID" ]]; then

        log "Manual configuration of usb-backup.conf required - \
             configure BACKUP_UUID"
        error "Manual configuration of usb-backup.conf required - \
               configure BACKUP_UUID"
        notify "Manual config needed in usb-backup.conf"
        return 1

    fi

    case "$MOUNTPOINT" in
        "/"|"/home"|"/var"|"/usr"|"/etc")

            error "Unsafe MOUNTPOINT configured"
            return 1

            ;;

    esac

}

################################################################################
# PREPARE LOCAL DIRECTORIES FUNCTION
################################################################################

prepare_local_directories() {

    mkdir -p "$TOP_LEVEL_SOURCE_MOUNTPOINT" "$LOCK_DIR" "$LOCAL_ROOT_SNAP_DIR" \
             "$LOCAL_HOME_SNAP_DIR" "$STATE_DIR" "$STATE_COUNTER_DIR" \
             "$STATE_FLAG_DIR" "$STATE_TIMESTAMP_DIR" "$LOG_DIR"

    chmod 700 "$TOP_LEVEL_SOURCE_MOUNTPOINT"
    chmod 700 "$LOCK_DIR"
    chmod 700 "$STATE_DIR"

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

        return 1

    fi

    _FSTYPE=$(blkid -o value -s TYPE "$_DEVICE_UUID")

    if [[ "$_FSTYPE" != "btrfs" ]]; then

        error "Detected device $_LABEL not Btrfs - exiting"

        if [[ "$manual" == "true" ]]; then

            printf "Detected device $_LABEL not Btrfs - exiting\n"

        fi

        return 1

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

        log "Mounting UUID=$BACKUP_UUID at $MOUNTPOINT"

        if ! mount -o noatime UUID="$BACKUP_UUID" "$MOUNTPOINT"; then

            error "Mount command failed"
            return 1

        fi

    else

        log "$MOUNTPOINT already mounted"

    fi

    _MOUNTED_SOURCE=$(findmnt -n -o SOURCE "$MOUNTPOINT")
    _MOUNTED_UUID=$(blkid -s UUID -o value "$_MOUNTED_SOURCE")
    _MOUNTED_FSTYPE=$(findmnt -n -o FSTYPE "$MOUNTPOINT")

    if [[ "$_MOUNTED_UUID" != "$BACKUP_UUID" ]]; then

        error "Wrong device mounted at $MOUNTPOINT (UUID mismatch)"
        return 1

    fi

    if [[ "$_MOUNTED_FSTYPE" != "btrfs" ]]; then

        error "Mounted filesystem is not Btrfs"
        return 1

    fi

    log "Mount verified: UUID=$_MOUNTED_UUID FSTYPE=$_MOUNTED_FSTYPE"

    local test_file="$MOUNTPOINT/.mount-test-$$"

    if ! touch "$test_file"; then

        error "Write test failed on mounted filesystem"
        return 1

    fi

    rm -f "$test_file"

    log "Mount write tests passed"
    log "USB device mounted successfully"

    log "Mount table after mount:"
    findmnt -rno TARGET,SOURCE,FSTYPE | grep "$MOUNTPOINT" || true

}

################################################################################
# CREATE DESTINATION FUNCTION
################################################################################

create_destination() {

    local su="$1"

    if btrfs subvolume show "$su" &>/dev/null; then

        return

    fi

    if [[ -e "$su" ]]; then

        error "Path exists but is not a subvolume: $su"
        return 1

    fi

    btrfs subvolume create "$su"

}

################################################################################
# RESET REMOTE STAGING FUNCTION
################################################################################

reset_staging_dir() {

    local dir="$1"

    log "Resetting staging subvolume: $dir"

    if [[ -e "$dir" ]] && ! btrfs subvolume show "$dir" &>/dev/null; then
        error "Staging path exists but is not a subvolume: $dir"
        return 1
    fi

    if btrfs subvolume show "$dir" &>/dev/null; then

        log "Deleting child subvolumes inside staging"

        while IFS= read -r subvol; do

            local full_path="$subvol"
            [[ "$subvol" != /* ]] && full_path="$MOUNTPOINT/$subvol"

            if [[ "$full_path" != "$MOUNTPOINT"* ]]; then

                error "Refusing unsafe subvolume delete: $full_path"
                return 1

            fi

            log "Deleting subvolume: $full_path"

            btrfs subvolume delete "$full_path" || {
                error "Failed deleting subvolume: $full_path"
                return 1
            }
        done < <(
            btrfs subvolume list -o "$dir" \
            | awk '{print $NF}' \
            | sort -r
        )

        case "$dir" in
            "$MOUNTPOINT"/*) ;;
            *)

                error "Refusing to operate outside mountpoint: $dir"
                return 1

                ;;

        esac

        log "Deleting staging subvolume itself"

        btrfs subvolume delete "$dir" || {
            error "Failed deleting staging subvolume: $dir"
            return 1
        }

        for i in {1..50}; do

            if ! btrfs subvolume show "$dir" &>/dev/null; then

                break

            fi

            sleep 0.2

        done

        if btrfs subvolume show "$dir" &>/dev/null; then

            error "Staging subvolume deletion did not complete"
            return 1

        fi

    fi

    btrfs subvolume create "$dir" || {
        error "Failed to create staging subvolume: $dir"
        return 1
    }

    btrfs filesystem sync "$MOUNTPOINT"

    log "Staging reset complete: $dir"

}

################################################################################
# SORT SUBVOLS FUNCTION
################################################################################

get_sorted_subvol_names() {

    local dir="$1"
    local -a out=()
    local s

    for s in "$dir"/*; do

        [[ -d "$s" ]] || continue
        btrfs subvolume show "$s" &>/dev/null || continue

        out+=("${s##*/}")

    done

    IFS=$'\n' printf '%s\n' "${out[@]}" | sort

}

################################################################################
# RUNTIME VERIFY MOUNTED FILE SYSTEM
################################################################################

runtime_mount_check() {

    local uuid
    uuid=$(findmnt -n -o UUID "$MOUNTPOINT")

    if [[ "$uuid" != "$BACKUP_UUID" ]]; then

        error "Mounted filesystem UUID mismatch during runtime"
        return 1

    fi

    if ! findmnt -n -o FSTYPE "$MOUNTPOINT" | grep -q btrfs; then

        error "Refusing to operate: $MOUNTPOINT \
            is not a mounted Btrfs filesystem"
        return 1

    fi

}

################################################################################
# COMMAND WRAPPERS
################################################################################

step_start() {

    _STEP_DESC="$1"
    _STEP_DISC_PATH="${2:-}"

    log "STEP START   | $_STEP_DESC"

    _STEP_START_TIME=$(date +%s)

    if [[ -n "$_STEP_DISC_PATH" ]] && mountpoint -q "$_STEP_DISC_PATH"; then

        _STEP_DISC_BEFORE=$(df -h --output=used "$_STEP_DISC_PATH" | tail -1 | xargs)
        log "STEP DISK    | before=$_STEP_DISC_BEFORE path=$_STEP_DISC_PATH"

    else

        _STEP_DISC_BEFORE=""

    fi

}

step_end() {

    local dir="${1:-}"

    if [[ -n "$dir" ]]; then

        sync -f "$dir"

    fi

    local end_time
    end_time=$(date +%s)
    _STEP_DURATION=$(( end_time - _STEP_START_TIME ))

    if [[ -n "$_STEP_DISC_PATH" ]] && mountpoint -q "$_STEP_DISC_PATH"; then

        local disk_after
        disk_after=$(df -h --output=used "$_STEP_DISC_PATH" | tail -1 | xargs)

        log "STEP DISK    | after=$disk_after path=$_STEP_DISC_PATH"

    fi

    _STEP_DISC_PATH=""

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

                printf "Backup drive unmounted successfully\n"

            fi

        else

            log "Backup drive busy - attempting again"

            sleep 1

            if umount "$MOUNTPOINT"; then

                log "Backup drive unmounted successfully - second attempt"

                if [[ "$manual" == "true" ]]; then

                    printf "Backup drive unmounted successfully - second attempt\n"

                fi

            else

                log "Backup drive busy - attempting lazy unmount"

                if umount -l "$MOUNTPOINT"; then

                    log "Lazy unmount successful - \
                         two failed normal unmount attempts prior"

                    if [[ "$manual" == "true" ]]; then

                        printf "Backup drive unmounted lazily - \
                                two failed normal unmount attempts prior\n"

                    fi

                else

                    error "Failed to unmount backup drive"
                    notify "Unmount failed"

                    if [[ "$manual" == "true" ]]; then

                        printf "Error: failed to unmount backup drive\n"

                    fi

                    return 1

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

    SCRUB_ERRORS_THIS_RUN=0

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
                SCRUB_ERRORS_THIS_RUN=1
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
