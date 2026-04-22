#!/usr/bin/env bash

# ==============================================================================
# usb-backup-main.sh
# External Btrfs USB Backup Script
#
# github.com/cygnick6/arch-linux-systems-design/btrfs-usb-backup
#
## LOGGING CONTEXT ##
# - log() and stdout are sent to journald and to local LOG_FILE
# - error() and stderr are sent to journald and to local ERROR_LOG_FILE
# - @ receiving is dumped to local ROOT_RECEIVE_DUMP_LOG_FILE
# - @home receiving is dumped to local HOME_RECEIVE_DUMP_LOG_FILE
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
## FLAG FILE CONTEXT: 'backup-due' ##
# - usb-backup-reminder.timer triggers usb-backup-reminder.service, which
#   executes usb-backup-reminder.sh, which creates the flag file
#   'backup-due'
# - usb-backup-now.sh may be used to manually create the flag file
#   'backup-due'. usb-backup-now.sh then executes this script
#
## FLAG FILE CONTEXT: 'backup-in-progress' ##
# - This script automatically creates and removes the flag file
#   'backup-in-progress'
#
## FLAG FILE CONTEXT: 'scrub-in-progress' ##
# - Both this script (usb-backup-main.sh) and usb-scrub-now.sh automatically
#       create and remove the flag file 'scrub-in-progress'
#
## EXECUTION CONTEXT ##
# - A udev rule, configured with the UUID of the target Btrfs-formatted USB
#       drive, triggers usb-backup-main.service which executes this script. If the
#       'backup-due' flag file is set, insert the target USB drive to execute
#       this script and start a backup
# - usb-backup-reminder.service also executes this script, in case the USB
#       drive is already inserted when usb-backup-reminder.timer triggers
# - usb-backup-now.sh may be used to manually execute this script
#
# This script:
# - Checks if the flag file 'backup-due' exists
# - Sets and automatically removes the flag file 'backup-in-progress'
# - Checks for and mounts the target USB drive
# - Creates local @ and @home snapshots
# - Sends these snapshots to the USB drive either:
#     - fully replicating, if a possible parent does not exist
#     - incrementally, if a possible parent does exist
# - Incrementally copies a file-level /home backup, sourced from the newly
#       created @home snapshot, to the USB drive
# - Prunes local and remote, paired and unpaired snapshots if more than max
#       set in usb-backup-conf
# - Unmounts the USB drive
#
# This backup strategy utilizes incremental snapshot sends.
# For incremental sending:
# - A full replication must be sent first (handled by this script)
# - An identically named parent snapshot must exist both locally and remotely
#
# After consecutive backups:
# - A max quantity of MAX_SNAPSHOTS @ and @home snapshots exist both locally and
#       remotely
# - One file-level backup of /home exists remotely
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

    notify "Backup error"

    log "Starting cleanup"

    umount "$TOP_LEVEL_SOURCE_MOUNTPOINT" 2>/dev/null || true

    unmount_usb_drive

    rm "$BACKUP_IN_PROGRESS_FLAG" "$SCRUB_IN_PROGRESS_FLAG"

    log "Finished cleanup"
    log_declare "usb-backup-main.sh exited with errors"

}

trap error_handler ERR

################################################################################
# PREPARE LOCAL DIRECTORIES
################################################################################

prepare_local_directories

################################################################################
# DECLARATION
################################################################################

log_declare "usb-backup-main.sh started"

date --iso-8601=seconds > "$LAST_BACKUP_PROMPT_TIMESTAMP_FILE"

################################################################################
# VALIDATE CONF
################################################################################

validate_user_name_conf
validate_high_priority_conf

################################################################################
# CHECK FLAG backup-due
################################################################################

if [[ ! -f "$BACKUP_DUE_FLAG" ]]; then

    log "backup-due flag not set - exiting quietly"
    log_declare "usb-backup-main.sh finished"
    exit 0

fi

################################################################################
# DETECT TARGET DEVICE
################################################################################

detect_usb_drive

################################################################################
# DECLARE BACKUP START
################################################################################

touch "$BACKUP_IN_PROGRESS_FLAG"
notify "Backup started"

date --iso-8601=seconds > "$LAST_BACKUP_ATTEMPT_TIMESTAMP_FILE"

################################################################################
# LOCK FILE SYSTEM
################################################################################

lock_fs

################################################################################
# MOUNT TARGET DEVICE
################################################################################

mount_usb_drive

################################################################################
# PREPARE REMOTE DIRECTORIES
################################################################################

if ! mountpoint -q "$MOUNTPOINT"; then

    error "Nothing mounted to target mountpoint"
    exit 1

fi

case "$MOUNTPOINT" in
    "/"|"/home"|"/root"|"/var"|"/usr"|"/etc")

        error "Unsafe mountpoint"
        exit 1

        ;;

esac

[[ "$MOUNTPOINT" == "" ]] && exit 1

mkdir -p "$DEST_DIR"

create_destination "$DEST_ROOT_SNAP_DIR"
create_destination "$DEST_HOME_SNAP_DIR"

reset_staging_dir "$DEST_ROOT_SNAP_STAGING_DIR"
reset_staging_dir "$DEST_HOME_SNAP_STAGING_DIR"

if btrfs subvolume show "$DEST_HOME_RSYNC_STAGING_DIR" &>/dev/null; then

    btrfs subvolume delete -c "$DEST_HOME_RSYNC_STAGING_DIR"

    while btrfs subvolume show "$DEST_HOME_RSYNC_STAGING_DIR" &>/dev/null; do

        sleep 0.2

    done

fi

################################################################################
# CREATE NEW LOCAL SNAPSHOTS
################################################################################

if mountpoint -q "$TOP_LEVEL_SOURCE_MOUNTPOINT"; then

    error "Top-level source mountpoint already in use"
    exit 1

fi

mount -o subvolid=5 "$BTRFS_SOURCE_DEVICE" "$TOP_LEVEL_SOURCE_MOUNTPOINT"

if ! mountpoint -q "$TOP_LEVEL_SOURCE_MOUNTPOINT"; then

    error "Failed to mount top-level source subvolume"
    exit 1

fi

# Do not edit needlessly
# Backup system relies on inherent sorting and atomicity
_SNAPSHOT_NAME=$(date +"%Y-%m-%d_%H-%M-%S")_$$

_ROOT_SNAP="$LOCAL_ROOT_SNAP_DIR/$_SNAPSHOT_NAME"
_HOME_SNAP="$LOCAL_HOME_SNAP_DIR/$_SNAPSHOT_NAME"

log "Creating new local snapshots: $_SNAPSHOT_NAME"

btrfs subvolume snapshot -r "$TOP_LEVEL_SOURCE_MOUNTPOINT"/@ "$_ROOT_SNAP"
btrfs subvolume snapshot -r "$TOP_LEVEL_SOURCE_MOUNTPOINT"/@home "$_HOME_SNAP"

btrfs filesystem sync "$TOP_LEVEL_SOURCE_MOUNTPOINT"

umount "$TOP_LEVEL_SOURCE_MOUNTPOINT"

log "Finished creating new local snapshots: $_SNAPSHOT_NAME"

################################################################################
# FIND PARENT SNAPSHOT FUNCTION
################################################################################

find_parent_snapshot() {

    local local_dir="$1"
    local remote_dir="$2"

    local snap
    local parent=""

    mapfile -t snaps < <(get_sorted_subvol_names "$local_dir")

    for snap in "${snaps[@]}"; do

        if btrfs subvolume show "$remote_dir/$snap" &>/dev/null; then

            parent="$snap"

        fi

    done

    if [[ ! -e "$local_dir/$parent" ]]; then

        error "Targeted parent snapshot does not exist locally"
        exit 1

    fi

    if [[ ! -e "$remote_dir/$parent" ]]; then

        error "Targeted parent snapshot does not exist remotely"
        exit 1

    fi

    echo "$parent"

}

################################################################################
# ROOT SNAPSHOT TRANSMISSION
################################################################################

log "Initializing @ transmission: $_SNAPSHOT_NAME"

runtime_mount_check

if [[ ! -d "$DEST_ROOT_SNAP_STAGING_DIR" ]]; then

    error "Staging dir missing before receive: $DEST_ROOT_SNAP_STAGING_DIR"
    exit 1

fi

log "DEBUG: staging dir info"
btrfs subvolume show "$DEST_ROOT_SNAP_STAGING_DIR" || true
ls -la "$DEST_ROOT_SNAP_STAGING_DIR"
log "DEBUG: existing subvolumes in staging parent"
btrfs subvolume list "$MOUNTPOINT" | grep "$_SNAPSHOT_NAME" || true

if btrfs subvolume show "$DEST_ROOT_SNAP_STAGING_DIR/$_SNAPSHOT_NAME" &>/dev/null; then

    error "Subvolume already exists before receive: $_SNAPSHOT_NAME"
    exit 1

fi

_ROOT_PARENT=$(find_parent_snapshot \
    "$LOCAL_ROOT_SNAP_DIR" "$DEST_ROOT_SNAP_DIR")

if [[ -n "$_ROOT_PARENT" ]]; then

    if [[ "$LOG_TO_FILE" == "true" ]] && \
        [[ "$LOG_FILE_RECEIVE_DUMP" == "true" ]]; then

        step_start "Transmit staged @ incrementally (logged)" "$MOUNTPOINT"

        set +e

        btrfs send --compressed-data \
            -p "$LOCAL_ROOT_SNAP_DIR/$_ROOT_PARENT" "$_ROOT_SNAP" | \
        btrfs receive --dump >> "$ROOT_RECEIVE_DUMP_LOG_FILE" 2>&1

        _PS=("${PIPESTATUS[@]}")

        _RC1=${_PS[0]:-1}
        _RC2=${_PS[1]:-1}

        step_end "$DEST_ROOT_SNAP_STAGING_DIR"

        if (( _RC1 == 0 && _RC2 == 0 )); then

            log "STEP SUCCESS | $_STEP_DESC | duration=${_STEP_DURATION}s"

        else

            error "STEP FAIL    | $_STEP_DESC | send_rc=$_RC1 recv_rc=$_RC2 | duration=${_STEP_DURATION}s"
            exit 1

        fi

        set -e

    else

        step_start "Transmit staged @ incrementally" "$MOUNTPOINT"

        set +e

        btrfs send --compressed-data \
            -p "$LOCAL_ROOT_SNAP_DIR/$_ROOT_PARENT" "$_ROOT_SNAP" | \
        btrfs receive "$DEST_ROOT_SNAP_STAGING_DIR"

        _PS=("${PIPESTATUS[@]}")

        _RC1=${_PS[0]:-1}
        _RC2=${_PS[1]:-1}

        step_end "$DEST_ROOT_SNAP_STAGING_DIR"

        if (( _RC1 == 0 && _RC2 == 0 )); then

            log "STEP SUCCESS | $_STEP_DESC | duration=${_STEP_DURATION}s"

        else

            error "STEP FAIL    | $_STEP_DESC | send_rc=$_RC1 recv_rc=$_RC2 | \
                duration=${_STEP_DURATION}s"
            exit 1

        fi

        set -e

    fi

    log "Finished staged @ incremental send: $_SNAPSHOT_NAME"

else

    if [[ "$LOG_TO_FILE" == "true" ]] && \
       [[ "$LOG_FILE_RECEIVE_DUMP" == "true" ]]; then

        step_start "Transmit staged @ fully (logged)" "$MOUNTPOINT"

        set +e

        btrfs send --compressed-data "$_ROOT_SNAP" | \
        btrfs receive --dump >> "$ROOT_RECEIVE_DUMP_LOG_FILE" 2>&1

        _PS=("${PIPESTATUS[@]}")

        _RC1=${_PS[0]:-1}
        _RC2=${_PS[1]:-1}

         step_end "$DEST_ROOT_SNAP_STAGING_DIR"

        if (( _RC1 == 0 && _RC2 == 0 )); then

            log "STEP SUCCESS | $_STEP_DESC | duration=${_STEP_DURATION}s"

        else

            error "STEP FAIL    | $_STEP_DESC | send_rc=$_RC1 recv_rc=$_RC2 | \
                duration=${_STEP_DURATION}s"
            exit 1

        fi

        set -e

        # step_start "Transmit staged @ fully (debug)" "$MOUNTPOINT"
        #
        # set +e
        #
        # btrfs send --compressed-data "$_ROOT_SNAP" | \
        # btrfs receive "$DEST_ROOT_SNAP_STAGING_DIR" \
        #     >> /tmp/btrfs-receive.stdout.log \
        #     2>> /tmp/btrfs-receive.stderr.log
        #
        # echo "receive stdout"
        # cat /tmp/btrfs-receive.stdout.log
        # echo "receive stderr"
        # cat /tmp/btrfs-receive.stderr.log
        #
        # _PS=("${PIPESTATUS[@]}")
        #
        # _RC1=${_PS[0]:-1}
        # _RC2=${_PS[1]:-1}
        #
        # step_end "$DEST_ROOT_SNAP_STAGING_DIR"
        #
        # if (( _RC1 == 0 && _RC2 == 0 )); then
        #
        #     log "STEP SUCCESS | $_STEP_DESC | duration=${_STEP_DURATION}s"
        #
        # else
        #
        #     error "STEP FAIL    | $_STEP_DESC | send_rc=$_RC1 recv_rc=$_RC2 | \
        #         duration=${_STEP_DURATION}s"
        #     exit 1
        #
        # fi
        #
        # set -e

    else

        step_start "Transmit staged @ fully" "$MOUNTPOINT"

        set +e

        btrfs send --compressed-data "$_ROOT_SNAP" | \
        btrfs receive "$DEST_ROOT_SNAP_STAGING_DIR"

        _PS=("${PIPESTATUS[@]}")

        _RC1=${_PS[0]:-1}
        _RC2=${_PS[1]:-1}

        step_end "$DEST_ROOT_SNAP_STAGING_DIR"

        if (( _RC1 == 0 && _RC2 == 0 )); then

            log "STEP SUCCESS | $_STEP_DESC | duration=${_STEP_DURATION}s"

        else

            error "STEP FAIL    | $_STEP_DESC | send_rc=$_RC1 recv_rc=$_RC2 | \
                duration=${_STEP_DURATION}s"
            exit 1

        fi

        set -e

    fi

    log "Finished staged @ full send: $_SNAPSHOT_NAME"

fi

log "DEBUG: contents of staging dir after receive"
find "$DEST_ROOT_SNAP_STAGING_DIR" -maxdepth 2 -print

log "Checking received @"

_STAGED_ROOT_SNAP_PATH="$DEST_ROOT_SNAP_STAGING_DIR/$_SNAPSHOT_NAME"

if ! _STAGED_ROOT_INFO=$(btrfs subvolume show \
    "$_STAGED_ROOT_SNAP_PATH" 2>/dev/null); then

    error "Staged received @ missing - exiting"
    exit 1

fi

if ! grep -qi "Readonly:.*yes" <<< "$_STAGED_ROOT_INFO"; then

    error "Staged received @ not read-only - exiting"
    exit 1

fi

log "Staged received @ passed checks"
log "Unstaging received @"

btrfs subvolume snapshot \
    "$_STAGED_ROOT_SNAP_PATH" \
    "$DEST_ROOT_SNAP_DIR/$_SNAPSHOT_NAME"

btrfs subvolume delete -c "$_STAGED_ROOT_SNAP_PATH"

log "Finished unstaging received @"
log "@ transmission completed: $_SNAPSHOT_NAME"

################################################################################
# HOME SNAPSHOT TRANSMISSION
################################################################################

log "Initializing @home transmission: $_SNAPSHOT_NAME"

runtime_mount_check

if [[ -e "$DEST_HOME_SNAP_STAGING_DIR/$_SNAPSHOT_NAME" ]]; then

    error "Staging path already exists before receive: $_SNAPSHOT_NAME"
    exit 1

fi

_HOME_PARENT=$(find_parent_snapshot \
    "$LOCAL_HOME_SNAP_DIR" "$DEST_HOME_SNAP_DIR")

if [[ -n "$_HOME_PARENT" ]]; then

    if [[ "$LOG_TO_FILE" == "true" ]] && \
       [[ "$LOG_FILE_RECEIVE_DUMP" == "true" ]]; then

        step_start "Transmit staged @home incrementally (logged)" "$MOUNTPOINT"

        set +e

        btrfs send --compressed-data \
            -p "$LOCAL_HOME_SNAP_DIR/$_HOME_PARENT" "$_HOME_SNAP" | \
        btrfs receive --dump >> "$HOME_RECEIVE_DUMP_LOG_FILE" 2>&1

        _PS=("${PIPESTATUS[@]}")

        _RC1=${_PS[0]:-1}
        _RC2=${_PS[1]:-1}

        step_end "$DEST_HOME_SNAP_STAGING_DIR"

        if (( _RC1 == 0 && _RC2 == 0 )); then

            log "STEP SUCCESS | $_STEP_DESC | duration=${_STEP_DURATION}s"

        else

            error "STEP FAIL    | $_STEP_DESC | send_rc=$_RC1 recv_rc=$_RC2 | \
                duration=${_STEP_DURATION}s"
            exit 1

        fi

        set -e

    else

        step_start "Transmit staged @home incrementally" "$MOUNTPOINT"

        set +e

        btrfs send --compressed-data \
            -p "$LOCAL_HOME_SNAP_DIR/$_HOME_PARENT" "$_HOME_SNAP" | \
        btrfs receive "$DEST_HOME_SNAP_STAGING_DIR"

        _PS=("${PIPESTATUS[@]}")

        _RC1=${_PS[0]:-1}
        _RC2=${_PS[1]:-1}

        step_end "$DEST_HOME_SNAP_STAGING_DIR"

        if (( _RC1 == 0 && _RC2 == 0 )); then

            log "STEP SUCCESS | $_STEP_DESC | duration=${_STEP_DURATION}s"

        else

            error "STEP FAIL    | $_STEP_DESC | send_rc=$_RC1 recv_rc=$_RC2 | \
                duration=${_STEP_DURATION}s"
            exit 1

        fi

        set -e

    fi

    log "Finished staged @home incremental send: $_SNAPSHOT_NAME"

else

    if [[ "$LOG_TO_FILE" == "true" ]] && \
       [[ "$LOG_FILE_RECEIVE_DUMP" == "true" ]]; then

        step_start "Transmit staged @home fully (logged)" "$MOUNTPOINT"

        set +e

        btrfs send --compressed-data "$_HOME_SNAP" | \
        btrfs receive --dump >> "$HOME_RECEIVE_DUMP_LOG_FILE" 2>&1

        _PS=("${PIPESTATUS[@]}")

        _RC1=${_PS[0]:-1}
        _RC2=${_PS[1]:-1}

        step_end "$DEST_HOME_SNAP_STAGING_DIR"

        if (( _RC1 == 0 && _RC2 == 0 )); then

            log "STEP SUCCESS | $_STEP_DESC | duration=${_STEP_DURATION}s"

        else

            error "STEP FAIL    | $_STEP_DESC | send_rc=$_RC1 recv_rc=$_RC2 | \
                duration=${_STEP_DURATION}s"
            exit 1

        fi

        set -e

    else

        step_start "Transmit staged @home fully" "$MOUNTPOINT"

        set +e

        btrfs send --compressed-data "$_HOME_SNAP" | \
        btrfs receive "$DEST_HOME_SNAP_STAGING_DIR"

        _PS=("${PIPESTATUS[@]}")

        _RC1=${_PS[0]:-1}
        _RC2=${_PS[1]:-1}

        step_end "$DEST_HOME_SNAP_STAGING_DIR"

        if (( _RC1 == 0 && _RC2 == 0 )); then

            log "STEP SUCCESS | $_STEP_DESC | duration=${_STEP_DURATION}s"

        else

            error "STEP FAIL    | $_STEP_DESC | send_rc=$_RC1 recv_rc=$_RC2 | \
                duration=${_STEP_DURATION}s"
            exit 1

        fi

        set -e

    fi

    log "Finished staged @home full send: $_SNAPSHOT_NAME"

fi

log "Checking received @home"

_STAGED_HOME_SNAP_PATH="$DEST_HOME_SNAP_STAGING_DIR/$_SNAPSHOT_NAME"

if ! _STAGED_HOME_INFO=$(btrfs subvolume show \
    "$_STAGED_HOME_SNAP_PATH" 2>/dev/null); then

    error "Staged received @home missing - exiting"
    exit 1

fi

if ! grep -qi "Readonly:.*yes" <<< "$_STAGED_HOME_INFO"; then

    error "Staged received @home not read-only - exiting"
    exit 1

fi

log "Staged received @home passed checks"
log "Unstaging received @home"

btrfs subvolume snapshot \
    "$_STAGED_HOME_SNAP_PATH" \
    "$DEST_HOME_SNAP_DIR/$_SNAPSHOT_NAME"

btrfs subvolume delete -c "$_STAGED_HOME_SNAP_PATH"

log "Finished unstaging received @home"
log "@home transmission completed: $_SNAPSHOT_NAME"

################################################################################
# RSYNC HOME SNAPSHOT
################################################################################

if [[ "$HOME_RSYNC" == "true" ]]; then

    if [[ "$_HOME_SNAP" == "" ]]; then

        error "_HOME_SNAP unnassigned"
        exit 1

    fi

    if [[ ! -d "$_HOME_SNAP" ]]; then

        error "Assigned _HOME_SNAP is not a directory"
        exit 1

    fi

    log "Starting rsync of @home ($_SNAPSHOT_NAME)"

    if [[ -z "$DEST_HOME_RSYNC_DIR" ]] \
        || [[ "$DEST_HOME_RSYNC_DIR" == "/" ]]; then

        error "Unsafe home rsync destination"
        exit 1

    fi

    case "$DEST_HOME_RSYNC_DIR" in
        /home/*|/root/*|/etc/*|/usr/*|/var/*|"")
            ;;
        *)

            error "Unsafe rsync target"
            exit 1

            ;;

    esac

    runtime_mount_check

    log "Preparing rsync staging"

    if btrfs subvolume show "$DEST_HOME_RSYNC_DIR" &>/dev/null; then

        log "Existing rsync backup found - snapshotting to staging area"

        btrfs subvolume snapshot \
            "$DEST_HOME_RSYNC_DIR" \
            "$DEST_HOME_RSYNC_STAGING_DIR"

    else

        log "No previous rsync backup - creating empty staging area"

        btrfs subvolume create "$DEST_HOME_RSYNC_STAGING_DIR"

    fi

    _RSYNC_EXCLUDES=()

    for dir in "${HOME_RSYNC_IGNORE_DIRS[@]}"; do

        _RSYNC_EXCLUDES+=(--exclude="./$dir")

    done

    if (( ${#_RSYNC_EXCLUDES[@]} > 0 )); then

        log "rsync exclusions: $(printf '%s ' "${HOME_RSYNC_IGNORE_DIRS[@]}")"

    else

        log "No rsync exclusions"

    fi

    step_start "Backup file-level @home (rsync)" "$MOUNTPOINT"

    rsync -aHAX --delete-delay --numeric-ids --one-file-system \
        "${_RSYNC_EXCLUDES[@]}" \
        "$_HOME_SNAP/" "$DEST_HOME_RSYNC_STAGING_DIR/"

    step_end "$DEST_HOME_RSYNC_STAGING_DIR"

    log "Checking staged @home rsync backup"

    if [[ ! -d "$DEST_HOME_RSYNC_STAGING_DIR" ]] || \
    ! find "$DEST_HOME_RSYNC_STAGING_DIR" \
        -mindepth 1 -print -quit | grep -q .; then

        error "Staged rsync @home backup invalid - exiting"
        exit 1

    fi

    log "@Staged home rsync backup passed checks"

    if btrfs subvolume show "$DEST_HOME_RSYNC_DIR" &>/dev/null; then

        log "Deleting previous @home rsync backup"

        btrfs subvolume delete -c "$DEST_HOME_RSYNC_DIR"

        while btrfs subvolume show "$DEST_HOME_RSYNC_DIR" &>/dev/null; do

            sleep 0.2

        done

        log "Deleted previous @home rsync backup"

    else

        log "No @home rsync backup exists to overwrite"

    fi

    log "Unstaging @home rsync backup"

    btrfs subvolume snapshot \
        "$DEST_HOME_RSYNC_STAGING_DIR" \
        "$DEST_HOME_RSYNC_DIR"

    btrfs subvolume delete -c "$DEST_HOME_RSYNC_STAGING_DIR"

    log "Finished unstaging @home rsync backup"
    log "Finished rsync of @home: $_SNAPSHOT_NAME"

else

    log "File-level backup of @home using rsync disabled - skipping"

fi

################################################################################
# PRUNE PAIRED FUNCTION
################################################################################

prune_paired() {

    local local_dir="$1"
    local remote_dir="$2"
    local max="$3"

    local -a local_snaps=()
    local -a remote_snaps=()
    local s

    case "$remote_dir" in
        "$MOUNTPOINT"/*) ;;
        *)

            error "Refusing prune outside backup mount"
            exit 1

            ;;

    esac

    mapfile -t local_snaps < <(get_sorted_subvol_names "$local_dir")
    mapfile -t remote_snaps < <(get_sorted_subvol_names "$remote_dir")

    local -A remote_map
    local paired=()

    for s in "${remote_snaps[@]}"; do

        remote_map["$s"]=1

    done

    for s in "${local_snaps[@]}"; do

        if [[ -n "${remote_map[$s]:-}" ]]; then

            paired+=("$s")

        fi

    done

    local count="${#paired[@]}"

    if (( count <= max )); then

        return

    fi

    local remove=$((count - max))
    local snap

    for ((i=0; i<remove; i++)); do

        snap="${paired[$i]}"

        log "Deleting paired snapshot $snap"

        if [[ -d "$remote_dir/$snap" ]]; then

            btrfs subvolume delete -c "$remote_dir/$snap" \
                || error "Failed deleting remote snapshot $snap"

        fi

        if btrfs subvolume show "$local_dir/$snap" &>/dev/null; then

            btrfs subvolume delete -c "$local_dir/$snap" \
                || error "Failed deleting local snapshot $snap"
        fi

    done

}

################################################################################
# PRUNE UNPAIRED FUNCTION
################################################################################

prune_unpaired() {

    local target_dir="$1"
    local partner_dir="$2"
    local max="$3"

    local -a target_snaps=()
    local -a partner_snaps=()
    local s

    case "$target_dir" in
        "$MOUNTPOINT"/*) ;;
        *)

            error "Refusing prune outside backup mount"
            exit 1

            ;;

    esac

    mapfile -t target_snaps < <(get_sorted_subvol_names "$target_dir")
    mapfile -t partner_snaps < <(get_sorted_subvol_names "$partner_dir")

    local -A partner_map

    for s in "${partner_snaps[@]}"; do

        partner_map["$s"]=1

    done

    local unpaired=()

    for s in "${target_snaps[@]}"; do

        if [[ -z "${partner_map[$s]:-}" ]]; then

            unpaired+=("$s")

        fi

    done

    local count="${#unpaired[@]}"

    if (( count <= max )); then

        return

    fi

    local remove=$((count - max))
    local snap

    for ((i=0; i<remove; i++)); do

        snap="${unpaired[$i]}"

        log "Deleting unpaired snapshot $snap"

        btrfs subvolume delete -c "$target_dir/$snap" \
            || error "Failed deleting unpaired snapshot $snap"

    done

}

################################################################################
# EXECUTE PRUNING
################################################################################

if [[ "$PRUNE_PAIRED" == "true" ]]; then

    log "Starting paired pruning"

    prune_paired "$LOCAL_ROOT_SNAP_DIR" "$DEST_ROOT_SNAP_DIR" \
               "$MAX_ROOT_PAIRED_SNAPS"
    prune_paired "$LOCAL_HOME_SNAP_DIR" "$DEST_HOME_SNAP_DIR" \
               "$MAX_HOME_PAIRED_SNAPS"

    log "Finished paired pruning"

else

    log "Paired pruning disabled - skipping"

fi

if [[ "$PRUNE_UNPAIRED" == "true" ]]; then

    log "Starting unpaired pruning"

    prune_unpaired "$LOCAL_ROOT_SNAP_DIR" "$DEST_ROOT_SNAP_DIR" \
                   "$MAX_ROOT_UNPAIRED_SNAPS"
    prune_unpaired "$LOCAL_HOME_SNAP_DIR" "$DEST_HOME_SNAP_DIR" \
                   "$MAX_HOME_UNPAIRED_SNAPS"

    prune_unpaired "$DEST_ROOT_SNAP_DIR" "$LOCAL_ROOT_SNAP_DIR" \
                   "$MAX_ROOT_UNPAIRED_SNAPS"
    prune_unpaired "$DEST_HOME_SNAP_DIR" "$LOCAL_HOME_SNAP_DIR" \
                   "$MAX_HOME_UNPAIRED_SNAPS"

    log "Finished unpaired pruning"

else

    log "Unpaired pruning disabled - skipping"

fi

################################################################################
# SYNC
################################################################################

sync

################################################################################
# SCRUB
################################################################################

scrub_management

################################################################################
# UNMOUNT TARGET DEVICE
################################################################################

unmount_usb_drive

################################################################################
# FINALIZE
################################################################################

log "Finalizing backup"

rm -f "$BACKUP_DUE_FLAG" "$BACKUP_IN_PROGRESS_FLAG"

increment_count_file "$BACKUP_SUCCESS_COUNT_FILE"

date --iso-8601=seconds > "$LAST_BACKUP_SUCCESS_TIMESTAMP_FILE"

if [[ ! -f "$FIRST_BACKUP_SUCCESS_TIMESTAMP_FILE" ]]; then

    date --iso-8601=seconds > "$FIRST_BACKUP_SUCCESS_TIMESTAMP_FILE"

fi

log_declare "usb-backup-main.sh finished"
notify "Backup completed"
