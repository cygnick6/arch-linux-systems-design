# UEFI Base Installation

This document describes the UEFI flavored base system installation for the architecture defined in this repository.

> Lost? There are two separate implementations of this architecture’s base installation - this one for UEFI and [another](02-bios-base-installation.md) for BIOS hardware

In addition to base installation, subvolumes for root and home snapshots will be created and mounted in preparation for the [Internal](04-internal-recovery-model.md) and [External Recovery](07-external-recovery-model.md) Models.

This installation specifically targets:
- **Modern UEFI systems**
- Secure boot disabled
- GUID Partition Table (GPT)
- Full root encryption using LUKS2
- Btrfs with structured subvolumes
- No LVM
- No keyfile-based unlock
- Passphrase-based disk unlock at boot
- BusyBox rather than systemd used for initramfs (early boot = minimal and predictable)
- GRUB as bootloader

This document assumes familiarity with the [standard Arch installation flow](https://wiki.archlinux.org/title/Installation_guide).


## 1. Installation Assumptions

- System and Arch environment booted in UEFI mode
- Disk device identified (e.g., /dev/sdX)
- Network connectivity established
- System clock synchronized
- Arch mirror servers selected (e.g., Reflector used in the live environment)


## 2. Partition Layout

The obligatory EFI System Partition (ESP) is unencrypted.

Root is fully encrypted.

**Target Layout**

| Device    | Size        | Role                          |
|-----------|-------------|-------------------------------|
| /dev/sdX1 | 512M        | EFI System Partition (ef00)   |
| /dev/sdX2 | *Remainder* | LUKS2 container -> Btrfs root |

No LVM layer is used.


## 3. Create Partitions

The GUID fdisk (`gdisk`) utility may be used to create a GUID Partition Table (GPT) and its partitions.

Enter the `gdisk` interactive environment:
```bash
gdisk /dev/sdX
```

Input `?` to list available actions.

Create a fresh GPT.

Create the partitions, using type codes to correctly identify the BIOS boot partition:
- 1st partition: size `512M`, type code `ef00` (EFI System Partition)
- 2nd partition: remainder of disk, type code `8300` (Linux filesystem)


## 4. Format the EFI System Partition

```bash
mkfs.fat -F32 /dev/sdX1
```


## 5. Encrypt the Root Partition

Format, define the passphrase, and open the encrypted container:
```bash
cryptsetup luksFormat --type luks2 /dev/sdX2
cryptsetup open /dev/sdX2 cryptroot
```

This creates `/dev/mapper/cryptroot`. All subsequent file system operations target this mapped device.


## 6. Btrfs File System & Subvolume Layout

Format the file system in the encrypted container as Btrfs:
```bash
mkfs.btrfs /dev/mapper/cryptroot
```

Mount the file system:
```bash
mount /dev/mapper/cryptroot /mnt
```

Create subvolumes in a flat layout:
```bash
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home

btrfs subvolume create /mnt/@root_snapshots
btrfs subvolume create /mnt/@home_snapshots

btrfs subvolume create /mnt/@root_backup_snapshots
btrfs subvolume create /mnt/@home_backup_snapshots

btrfs subvolume create /mnt/@root_milestone_snapshots
btrfs subvolume create /mnt/@home_milestone_snapshots

btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@var_lib
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_spool
btrfs subvolume create /mnt/@var_tmp
```

Disable Copy-on-Write (CoW) where log files will be stored:
```bash
chattr +C /mnt/@var_log
```

An overview of the mount options used:
- `noatime` - reduce unnecessary write operations
- `compress=zstd` - efficient read operations and space usage
- `compress=no` - the transient contents of the `@var/` subvolumes are not worth compressing
- `subvol=` - subvolume to mount from `/dev/mapper/cryptroot`

Unmount the file system and mount the subvolumes using mount options, followed by the `EFI System Parition`:
```bash
umount /mnt

mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mount --mkdir -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home

mount --mkdir -o noatime,compress=zstd,subvol=@root_snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount --mkdir -o noatime,compress=zstd,subvol=@home_snapshots /dev/mapper/cryptroot /mnt/home/.snapshots

mount --mkdir -o noatime,compress=zstd,subvol=@root_backup_snapshots /dev/mapper/cryptroot /mnt/.backup-snapshots
mount --mkdir -o noatime,compress=zstd,subvol=@home_backup_snapshots /dev/mapper/cryptroot /mnt/home/.backup-snapshots

mount --mkdir -o noatime,compress=zstd,subvol=@root_milestone_snapshots /dev/mapper/cryptroot /mnt/.milestone-snapshots
mount --mkdir -o noatime,compress=zstd,subvol=@home_milestone_snapshots /dev/mapper/cryptroot /mnt/home/.milestone-snapshots

mount --mkdir -o noatime,compress=no,subvol=@var_cache /dev/mapper/cryptroot /mnt/var/cache
mount --mkdir -o noatime,compress=no,subvol=@var_lib /dev/mapper/cryptroot /mnt/var/lib
mount --mkdir -o noatime,compress=no,subvol=@var_log /dev/mapper/cryptroot /mnt/var/log
mount --mkdir -o noatime,compress=no,subvol=@var_spool /dev/mapper/cryptroot /mnt/var/spool
mount --mkdir -o noatime,compress=no,subvol=@var_tmp /dev/mapper/cryptroot /mnt/var/tmp

mount --mkdir /dev/sdX1 /mnt/boot
```

- `compress=no` is used for the select high-churn `@var` subvolumes


## 7. Base System Installation

Install essential packages:
```bash
pacstrap -K /mnt base linux linux-firmware cryptsetup btrfs-progs grub
```

- Note that the external USB backup system included in this architecture makes use of `sudo` for notification support (it’s one line in `usb-backup-lib.sh` - edit it yourself if you like)

Consider also installing:
- CPU microcode (`intel-ucode` or `amd-ucode`)
- `networkmanager`
- a firewall
- `reflector`, a tool for Arch mirror server selection
- `sudo`, a privilege escalation utility
- `xdg-user-dirs` for user XDG home directory management
- `tlp` for *laptop* power management tools
- `btrfsmaintenance` for a structured system maintenance toolkit
- `smartmontools` for automated hardware reporting
- a console text editor
- a font, e.g. one may be set for vconsole readability
- packages for accessing man and info pages (`man-db man-pages texinfo`)

Generate the `fstab` file:
```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

Change root:
```bash
arch-chroot /mnt
```


## 8. Initramfs Configuration (Encryption Hook)

This configuration uses the BusyBox-based initramfs (via `base` and `udev` hooks) rather than `systemd`.

Edit `/etc/mkinitcpio.conf`:
- Replace `systemd` with `udev`
- Remove `sd-vconsole`
- Add `encrypt` after `block` and before `filesystems`
- Ensure `keyboard` and `keymap` appear before `encrypt`

Example:
```
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems fsck)
```

Regenerate initramfs:
```bash
mkinitcpio -P
```

This enables early userspace unlocking of the LUKS container during boot.


## 9. GRUB Configuration for Encrypted Root

Edit `/etc/default/grub`, informing `GRUB` on how to handle the encrypted root.

To manually retrieve the UUID of the encrypted root partition (not the PARTUUID):
```bash
blkid /dev/sdX2
```

Optionally append the correct UUID, commented, to the `/etc/default/grub` file in one line:
```bash
blkid -s UUID -o value /dev/sdX2 | sed 's/^/# /' >> /etc/default/grub
```

Edit `/etc/default/grub` and add the paramaters (use copy and paste if the UUID was appended):
```
GRUB_CMDLINE_LINUX="cryptdevice=UUID=<recorded-UUID>:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@"
```

Install `GRUB` (UEFI target):
```bash
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=GRUB
```

- If `grub-install` fails and is asking to set `GRUB_ENABLE_CRYPTODISK=y`, that means `GRUB` is incorrectly looking in the encrypted `/` for `/boot`. This architecture targets having a separate, unencrypted `/boot`

Generate the configuration:
```bash
grub-mkconfig -o /boot/grub/grub.cfg
```

## 10. Pre-Reboot Configuration

In the live chrooted environment, proceed with the standard base configuration:
- Timezone
- Locale
- Hostname
- Root password

Exit chroot, safely unmount, and reboot into the system.


## 11. Post-Boot Configuration

Proceed with base configuration:
- Networking
- Firewall
- Time and NTP servers
- Arch mirror server selection
- User creation
- User privilege escalation

This architecture also covers several more configurations at this step.

### 11.1 Linger

Enable linger for a user to allow the use of their `systemd user` services, if a display manager will not be used to start user sessions:
```bash
loginctl enable-linger UserName
```

### 11.2 Home Directories

`xdg-user-dirs` may be installed for XDG home directory management.

Log in as the non-root user to configure XDG home directories for them.

Create and configure the default selection of XDG home directories:
```bash
xdg-user-dirs-update
```

Edit `~/.config/user-dirs.dirs` to personalize the XDG home directory selections. You may also need to manually create each directory, before running `xdg-user-dirs-update` again to flush customizations.

### 11.3 Power Management

`tlp` may be installed for laptop power management.

Enable its service:
```bash
systemctl enable --now tlp
```

Optionally add laptop-lid functionality by editing values in `/etc/systemd/logind.conf`:
```ini
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=ignore
```


## 12. System Maintenance

This architecture makes use of the following:
- `btrfsmaintenance` - Btrfs system maintenance (Btrfs scrub, filtered Btrfs balance, TRIM)
- `smartmontools` - hardware health monitoring and testing tools for drives

### 12.1 Target Schedule

Scheduled system maintence and tests are staggered to separate disk usage and limit competition.

The target system maintenance weekly schedule (including the weekly backup schedule) is listed below:

| Day       | Weekly?        | Time  | Role                   |
|-----------|----------------|-------|------------------------|
| Monday    | Weekly         | 18:00 | SMART short test       |
| Tuesday   | Weekly         | 19:00 | Filtered Btrfs balance |
| Wednesday | Weekly         | 18:00 | TRIM                   |
| Thursday  | -              | -     | -                      |
| Friday    | Weekly         | 17:00 | Btrfs usb backup       |
| Saturday  | First of month | 10:00 | SMART long test        |
| Saturday  | Weekly         | 14:30 | Btrfs scrub            |
| Sunday    | -              | -     | -                      |

This target schedule is customizable - keep in mind the following:
- This schedule targets daily-use laptop scenario - systems left on 24/7 should use a different schedule
- Most of the tasks here may have persistant timers - the next time the system is powered on, the task will trigger if the system was not powered on for a scheduled task
- Only SMART tests (via `smartmontools`) will not execute for the period if the system is powered off
- High load tasks are best run while connected to AC power, e.g. Btrfs scrub and filtered Btrfs balance

Tasks are arranged this way because they each have different loads on the system:
- Light load tasks
    - SMART short test
    - TRIM
- Moderate load tasks
    - Filtered Btrfs balance
- High load tasks
    - Btrfs usb backup
    - Btrfs scrub
    - SMART long test
    
Given the target schedule, randomized delay is introduced in some tasks to reduce contention after missed schedules:
- Filtered Btrfs balance
- Btrfs scrub

> This configuration will assume that the user will have the system connected to AC power for most scheduled Btrfs balances and Btrfs scrubs. On occasions where the system is not when a Btrfs balance or Btrfs scrub is scheduled, then it will be put off until the system is on AC power *and* rebooted

### 12.2 Configure btrfsmaintenance

`btrfsmaintenance` may be installed for structured control over system maintenance tasks including Btrfs balance, Btrfs scrub, and TRIM.

Btrfs balance:
- Reclaim space and prevent chunk imbalance

Btrfs scrub:
- Verify data integrity and detect corruption
- Btrfs scrub will not attempt to self-heal in this architecture as redundant copies in a RAID configuration are not used

TRIM:
- Inform SSD about unused blocks

Ensure the config directory is created:
```bash
sudo mkdir -p /etc/sysconfig
```

Create if needed, and edit `/etc/sysconfig/btrfsmaintenance` to contain the following:
```ini
BTRFS_SCRUB_PERIOD="none"
BTRFS_BALANCE_PERIOD="none"

BTRFS_BALANCE_ARGS="-dusage=75 -musage=75"

BTRFS_SCRUB_PRIORITY="idle"
BTRFS_BALANCE_PAUSE="yes"
BTRFS_SCRUB_PAUSE="yes"
```

### 12.3 Configure Services

A couple high load services should be edited and told to only trigger when the system is connected to AC power.

Edit `btrfs-scrub.service`:
```bash
systemctl edit btrfs-scrub.service
```

Add to `btrfs-scrub.service`:
```ini
[Unit]
ConditionACPower=true
```

Edit `btrfs-balance.service`:
```bash
systemctl edit btrfs-balance.service
```

Add to `btrfs-balance.service`:
```ini
[Unit]
ConditionACPower=true
```

### 12.4 Configure Timers

The services defined by `btrfsmaintenance` required timers to start. Granual control can be gained by manually configuring each timer, instead of having `btrfsmaintenance` configure them.

Edit `btrfs-balance.timer`:
```bash
systemctl edit btrfs-balance.timer
```

Add to `btrfs-balance.timer`:
```ini
[Timer]
OnCalendar=
OnCalendar=Tue *-*-* 19:00:00
Persistent=true
RandomizedDelaySec=1h
```

Edit `btrfs-scrub.timer`:
```bash
systemctl edit btrfs-scrub.timer
```

Add to `btrfs-scrub.timer`:
```ini
[Timer]
OnCalendar=
OnCalendar=Sat *-*-* 14:30:00
Persistent=true
RandomizedDelaySec=1h
```

Edit `fstrim.timer`:
```bash
systemctl edit fstrim.timer
```

Add to `fstrim.timer`:
```ini
[Timer]
OnCalendar=
OnCalendar=Wed *-*-* 18:00:00
Persistent=true
```

Enable timers:
```bash
systemctl enable --now btrfs-balance.timer
systemctl enable --now btrfs-scrub.timer
systemctl enable --now fstrim.timer
```

### 12.5 SMART (smartmontools)

`smartmontools` may be installed for hardware health monitoring tools for drives.

SMART:
- **S**elf-**M**onitoring **A**nalysis and **R**eporting **T**echnology

Detects things like:
- Read/write errors
- Wear leveling issues (SSD lifespan)
- Reallocated sectors (HHD)
- Temperature problems

Edit the file `/etc/smartd.conf`:
```conf
DEVICESCAN -a -o on -S on -s (S/../../1/18|L/../01-07/6/10) -n standby
```

- Adjust device if needed

This configuration:
- `DEVICESCAN` - monitor all drives
- `-a` - enable all SMART checks
- `-o on` - enable automatic offline testing
- `-S on` - enable attribute autosave
- `-s (...)` - schedule tests:
    - `S/../../1/18` - short tests weekly on Mondays at 18:00
    - `L/../01-07/6/10` - long tests monthly on first Saturdays of the month at 10:00
- `-n standby` - skip if disk is idle (good for laptops)

Enable SMART service:
```bash
systemctl enable --now smartd.service
```

### 12.6 Checking Maintenance Status

- Checkups on system maintenance will be explored further in the [Operational Discipline](08-operational-discipline.md) document

To list information on all systemd timers:
```bash
systemctl list-timers
```

`btrfsmaintenance` logs:
```bash
journalctl -u btrfs-scrub
journalctl -u btrfs-balance
journalctl -u fstrim
```

Btrfs scrub status on `/` (data integrity issues):
```bash
btrfs scrub status /
```

Quick SMART health:
```bash
smartctl -H /dev/sdX
```

Detailed SMART health:
```bash
smartctl -a /dev/sdX
```

SMART logs:
```bash
journalctl -u smartd
```

## 13. Root Milestone Snapshots

For extra control over the development of the Arch system, the `@root_milestone_snapshots` subvolume created earlier in this document may be used.

At this stage in the system installation, the base system is installed, but no non-essential packages, internal recovery models, or graphical stacks have been installed.

By creating a milestone snapshot of `@` now, the base of this installation may be recorded.

### 13.1 Create Internal Root Milestone Snapshot

Create a read-only `@` snapshot named `03-base-install`:
```bash
btrfs subvolume snapshot -r / /.milestone-snapshots/03-base-install
btrfs subvolume snapshot -r /home /.milestone-snapshots/03-base-install
```

### 13.2 Root Milestone Rollback

Internally-sourced rollback is explored in the [Internal Recovery Model](04-internal-recovery-model.md#5.2-root-milestone-rollback) document.


## 14. Transparent Boot Summary

On boot:
1. UEFI firmware loads `GRUB` from the EFI System Partition
2. `GRUB` loads kernel and initramfs from `/boot`
3. The initramfs `encrypt` hook prompts for the LUKS passphrase
4. The encrypted container is unlocked
5. Btrfs subvolumes mount
6. System continues normal initialization


## 15. Security Model Notes

- EFI System Partition is unencrypted
- Disk encryption protects against offline disk access and device theft
- Secure Boot is optional
- Physical ESP tampering is outside the scope of this architecture

Passphrase-only unlocking is intentionally chosen over embedded keyfiles to preserve physical security.


## 16. Next Steps

At this stage, the system provides:
- Base installation
    - Encrypted root file system
    - Structured Btrfs subvolume layout
    - Deterministic boot process
    - System maintenance and hardware monitoring

The next layer of the architecture is the [Internal Recovery Model](04-internal-recovery-model.md), which formalizes internal snapshot management and rollback strategies.
