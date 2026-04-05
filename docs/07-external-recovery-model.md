# External Recovery Model

This document describes part of the core of this architecture’s design: the architecture for an *external* backup layer.

## 1. Recovery Overview

The recovery model consists of three layers:
1. Internal snapshot layer - internal snapshot creation and rollback for protection from software failure
2. External backup layer - external backup strategies for protection from hardware failure or loss
3. Automated replication layer - remove part of the human element for a deterministic model

The architecture shown below addresses this system’s **automated** and **external** backup architecture:
1. ~~*Internal snapshot layer*~~ *(already implemented)*
2. *External backup layer*
3. *Automated replication layer*


## 2. External Recovery Design Principles

- Btrfs snapshot-based
- Root and home have different recovery domains
- Both root and home backups will be stored as fully replicated snapshots of the current system
- Home will additionally be backed up on a file-level basis for portability
- `/boot` is not internally snapshotted or backed up - it is reconstructed from the restored `@` snapshot when needed
- `/boot` is treated as ever-derivable from the current or newly restored `@` subvolume
- Offline, externally-sourced rollbacks are available even if the system is unbootable
- External backup automation is deterministic and inspectable

External backups solve a different type of problem than an internal snapshot layer. External backups are intended to be used for system recovery if the internal snapshot layer is unavailable.

In this architecture, external backups will be managed completely by the `btrfs-usb-backup` system provided in this repository. This system was designed around the architecture provided in this documentation.

The `btrfs-usb-backup` system is:
- *Transparent* - the generated snapshots and logs and the mechanisms behind the system are inspectable
- *Deterministic* - given the same snapshots state, configuration, and target device, the system will produce the same results
- *Idempotent* - repeated system operations avoid corruption or duplication
- *Convergent* - even if the state changes (incomplete or unstaged backups, missing parent snapshots for incremental sends), the system self-heals and operates normally
- *Configuration-agnostic* - changes to system configuration (target device UUID, maximum snapshots for retention, file paths, etc) do not require migration or manual intervention


## 3. External Backup Strategy

The targeted external backup strategy will automatically:
- Backup snapshots of `@` and `@home`
- Backup a file-level copy of `@home`

For incremental snapshot transmission using `btrfs send -p`, the backup system relies on pairs of parent snapshots existing between the local Arch system and the target Btrfs backup USB device. This means that the local Arch system keeps a copy of each existing remote snapshot.

## 3.1 External Backup Flow

1. Follow a schedule for backups (weekly)
2. When a backup is scheduled to start, the system prompts the user to insert the target Btrfs backup USB device
3. A backup will commence if it is:
    - manually called for by the user at any time and the target Btrfs backup USB device is inserted and available
    - scheduled and the target Btrfs backup USB device is already inserted and available
    - scheduled and the Arch system detects that the target Btrfs backup USB device becomes inserted and available

## 3.2 External Backup Process

During a backup:
- The target Btrfs backup USB drive is automatically mounted and unmounted as needed
- Snapshots of `@` and `@home` are sent, either fully or incrementally if a pair of possible parents exist both locally and remotely
- A file-level backup of `@home` is sent, either fully or incrementally if one already exists
- All sent backups are verified before unstaging (for completeness, not bootability)
- Both local and remote snapshot pairs are pruned, removing the oldest pair after the max number (as set in `usb-backup.conf`) is reached
    - This is similar to how `Snapper` manages internal snapshots based on quantity
- Unpaired snapshots (which may accumulate during fatal backup errors such as power loss) are pruned both locally and remotely
- Decrements a counter file (as set in `usb-backup.conf`) and conditionally executes a Btrfs scrub to verify health of the target Btrfs backup USB device


## 4. Install btrfs-usb-backup

The entire `btrfs-usb-backup` system is available within this repository. See [its README](../btrfs/usb/backup/README.md) for all documentation, including installation. A quick overview is provided here.

### 4.1 Installation

Download the repository locally and run the `install.sh` script to install all components to their locations and give them the correct privileges.

### 4.2 Required Configurations

Manual configuration is required in `/etc/usb-backup.conf` and `/usr/lib/udev/rules.d/99-usb-backup.rules`.

The `username` of the target user must be supplied in `usb-backup.conf` for notifications to work. This may be disabled in `usb-backup.conf`.

The `UUID` of the target Btrfs backup USB device must be supplied in:
- The configuration file: `usb-backup.conf`
- The udev rule: `99-usb-backup.rules`


## 5. btrfs-usb-backup Usage

The entire `btrfs-usb-backup` system is available within this repository. See [its README](../btrfs/usb/backup/README.md) for all documentation, including usage. An overview is provided here.

### 5.1 Manual Usage

The user may manually execute the following scripts: `/usr/bin/`
- `usb-backup-now.sh` - manually call for and execute a backup (ignoring the schedule)
- `usb-backup-scrub-now.sh` - manually execute a Btrfs scrub of the target Btrfs backup USB device (ignoring and resetting the scrub countdown file)
- `usb-backup-status.sh` - receive CLI printout for the health and status of the backup system

### 5.2 Logging

The `btrfs-usb-backup` system utilizes both Journald and local log files for logging.

`logrotate` is used to compress and store older logs. The configuration can be found at `/etc/logrotate.d/usb-backup`.

Local log files: `/var/log/usb-backup/...`
- `usb-backup.log` - normal usage log
- `usb-backup-error.log` - script error log
- `usb-backup-root-receive-dump.log` - dumps from executed `btrfs receive`s with `@` snapshots
- `usb-backup-home-receive-dump.log` - dumps from executed `btrfs receive`s with `@home` snapshots
- `usb-backup-scrub-dump.log` - dumps from executed `btrfs scrub`s

### 5.3 State Integer Counter Files

The `btrfs-usb-backup` system stores counter files of select events: `/var/lib/usb-backup/counters/`
- `backup-success-count`
- `scrub-countdown`
- `scrub-success-count`

### 5.4 State Flag Files

The `btrfs-usb-backup` system utilizes flag files to convey system state.

The `/var/lib/usb-backup/flags/backup-due` flag file is used to inform the system that a backup is scheduled to start.

The system also includes informational, non state-derived flag files: `/var/lib/usb-backup/flags/`
- `backup-in-progress`
- `scrub-in-progress`

### 5.5 State Timestamp Files

The `btrfs-usb-backup` system stores timestamps of select events: `/var/lib/usb-backup/timestamps/`
- `first-successful-backup`
- `last-prompted-backup`
- `last-attempted-backup`
- `last-successful-backup`
- `last-prompted-scrub`
- `last-attempted-scrub`
- `last-successful-scrub`

### 5.6 State Scrub Status File

The `btrfs-usb-backup` system stores the top-level status of the last successful Btrfs scrub: `/var/lib/usb-backup/last-scrub-result`


## 6. Multiple Backups (Offsite)

To satisfy part of the basic 3-2-1 data protection rule, consider using the `btrfs-usb-backup` system to:
- Maintain a local, easily accessibly USB backup on a weekly basis
- Also maintain another USB backup that will be stored offsite, to be used over a longer time period

This may look like keeping a Btrfs backup USB device in your home for weekly use, as well as keeping another at a trusted friend or family member’s house - running that backup whenever you visit.

> Note that encryption of the target Btrfs backup USB drive is not yet implemented; this may not be a feasible backup strategy for everyone

Currently, the `btrfs-usb-backup` system requires the user to manually configure the `UUID` of the target Btrfs backup USB device. The system will continue to operate even if the `UUID` is changed back and forth.

To create and maintain offsite backups:
- Manually change the `UUID` to the offsite value in both `/etc/usb-backup.conf` and `/usr/lib/udev/rules.d/99-usb-backup.rules`
- Manually execute `/usr/bin/usb-backup-now.sh` to perform a backup
- Optionally perform a Btrfs scrub: `/usr/bin/usb-backup-scrub-now.sh`
- Change back the `UUID` to the local value in both `/etc/usb-backup.conf` and `/usr/lib/udev/rules.d/99-usb-backup.rules`


## 7. Externally-Sourced Recovery

An external *backup* strategy is now established, but the external *recovery* strategy must now also be established.

Snapshot backups were created with the intent that the entire system state, as recorded by `@` and `@home`, may be recovered.

### 7.1 Snapshot Selection

The `btrfs-usb-backup` system is designed to enable transparent, deterministic recovery. The backup `@` and `@home` snapshots are named `date_time_processID`, and the most recent snapshot pairs of the same name should be investigated for bootability first.

- When performing system recovery using these snapshot backups, only use `@` and `@home` snapshots of the same name - snapshots that were generated at the same time and by the same backup process
- Using snapshots of different names may lead to issues as they were taken from different points in the system state

### 7.2 System Recovery

An externally-sourced, offline rollback must be performed to rollback the remote `@` and `@home` snapshots onto the Arch system.

- Boot into a live environment
- Mount the Btrfs backup USB and the top-level subvolume of the target Arch system to their own mountpoints
- Prepare the Arch system for new `@` and `@home` subvolumes
- Use `btrfs send ... | receive ...` to transmit the target snapshot from the Btrfs backup USB to the designated locations on the Arch system
- Change the new subvolumes to read-write
- Unmount the top-level subvolume of the Arch system
- Mount the restored Arch system normally, as per the contents of the newly restored `@`’s `fstab` file
- Change root and rebuild `/boot` from the contents of the newly restored `@`
- Exit chroot, unmount everything, and reboot


## 8. Failure Modes

### 8.1 Accounted For

The `btrfs-usb-backup` system accounts for:
- No possible parent snapshots for incremental sends (transmit fully)
- Backup completeness
    - Snapshot and file-level backups are checked for completeness before unstaging
    - `Btrfs scrub` is used periodically to check health of backup file system
- Pruning old backups to free up space
- Total power loss during a backup (unstaged backups, unpaired snapshots are handled)

On a recovery level:
- Root file system corruption
- User data loss
- Disk failure
- Unbootable system state

### 8.2 Not Accounted For

The `btrfs-usb-backup` system **does not** account for:
- Automatic checks for bootability
- Simultaneous loss of Arch system and backup device(s)


## 9. Internal Milestone Snapshots

For extra control over the development of the Arch system, the `@root_milestone_snapshots` and `@home_milestone_snapshots` subvolumes created in the [BIOS](02-bios-base-installation.md#6.-btrfs-file-system--subvolume-layout) or [UEFI Base Installation](03-uefi-base-installation.md#6.-btrfs-file-system--subvolume-layout) may be used.

At this stage in the system installation, the base installation, internal recovery layer, graphical stack, and external recovery layer are all installed. Beyond this point, it may be useful to have access to this system state.

`Snapper` will not be used to manage root milestone snapshots to avoid `Snapper`’s automated cleanup.

### 9.1 Create Internal Milestone Snapshots

Create read-only `@` and `@home` snapshots named `07-external-recovery-model`:
```bash
btrfs subvolume snapshot -r / /.root-milestone-snapshots/07-external-recovery-model
btrfs subvolume snapshot -r /home /.home-milestone-snapshots/07-external-recovery-model
```

### 9.2 Milestone Rollback

The entire system state (consisting of `@` and `@home`) may be rolled back to at any point. Perform an offline, internally-sourced rollback of `@` and `@home` to do so.

A general offline, internally-sourced rollback procedure is discussed in the [Internal Offline Rollback section](04-internal-recovery-model.md#42-offline-rollback) and more explicitly in the [Milestone Rollback Section](04-internal-recovery-model.md#52-root-milestone-rollback), both in the Internal Recovery Model document. Perform both root and home rollbacks, in order to preserve total system state (`@home` may have configurations files).


## 10. External Recovery Model Summary

This architecture established a Btrfs snapshot-based external recovery strategy, making use of the transparent and deterministic `btrfs-usb-backup` system. TODO


## 11. Next Steps

At this stage, the system provides:
- Base installation
    - Encrypted root file system
    - Structured Btrfs subvolume layout
    - Deterministic boot process
    - System maintenance and hardware monitoring
- Internal recovery strategy
    - Automated internal snapshot creation and management
    - Strategies for internally-sourced recovery
    - Milestone snapshot(s) created
- Graphical stack
    - TODO
- External recovery strategy
    - Automated, transparent, deterministic backup strategy using `btrfs-usb-backup`
    - Externally-sourced recovery strategy
    
The next layer of this architecture is TODO
