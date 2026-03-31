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
- BusyBox rather than systemd used for initramfs
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


## 4. Format & Mount the EFI System Partition

```bash
mkfs.fat -F32 /dev/sdX1
mount --mkdir /dev/sdX1 /mnt/boot
```


## 5. Encrypt the Root Partition

Format, define the passphrase, and open the encrypted container:
```bash
cryptsetup luksFormat /dev/sdX2
cryptsetup open /dev/sdX2 cryptroot
```

This creates `/dev/mapper/cryptroot`. All subsequent file system operations target this mapped device.


## 6. Btrfs File System & Subvolume Layout

Format the file system in the encrypted container as Btrfs:
```bash
mkfs.btrfs /dev/mapper/cryptroot
```

Mount the file system and create subvolumes in a flat layout:
```bash
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs su cr /mnt/@home

btrfs su cr /mnt/@root_snapshots
btrfs su cr /mnt/@home_snapshots

btrfs su cr /mnt/@root_backup_snapshots
btrfs su cr /mnt/@home_backup_snapshots

btrfs su cr /mnt/@root_milestone_snapshots
btrfs su cr /mnt/@home_milestone_snapshots

btrfs su cr /mnt/@var_cache
btrfs su cr /mnt/@var_lib
btrfs su cr /mnt/@var_log
btrfs su cr /mnt/@var_spool
btrfs su cr /mnt/@var_tmp
```

Unmount the file system and mount the subvolumes using mount options:
```bash
umount /mnt

mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mount --mkdir -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home

mount --mkdir -o noatime,compress=zstd,subvol=@root_snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount --mkdir -o noatime,compress=zstd,subvol=@home_snapshots /dev/mapper/cryptroot /mnt/home/.snapshots

mount --mkdir -o noatime,compress=zstd,subvol=@root_backup_snapshots /dev/mapper/cryptroot /mnt/.root-backup-snapshots
mount --mkdir -o noatime,compress=zstd,subvol=@home_backup_snapshots /dev/mapper/cryptroot /mnt/.home-backup-snapshots

mount --mkdir -o noatime,compress=zstd,subvol=@root_milestone_snapshots /dev/mapper/cryptroot /mnt/.root-milestone-snapshots
mount --mkdir -o noatime,compress=zstd,subvol=@home_milestone_snapshots /dev/mapper/cryptroot /mnt/.home-milestone-snapshots

mount --mkdir -o noatime,compress=no,subvol=@var_cache /dev/mapper/cryptroot /mnt/var/cache
mount --mkdir -o noatime,compress=no,subvol=@var_lib /dev/mapper/cryptroot /mnt/var/lib
mount --mkdir -o noatime,compress=no,subvol=@var_log /dev/mapper/cryptroot /mnt/var/log
mount --mkdir -o noatime,compress=no,subvol=@var_spool /dev/mapper/cryptroot /mnt/var/spool
mount --mkdir -o noatime,compress=no,subvol=@var_tmp /dev/mapper/cryptroot /mnt/var/tmp
```

Disable Copy-on-Write (CoW) for log files:
```bash
chattr +C /mnt/var/log
```


## 7. Base System Installation

Install essential packages:
```bash
pacstrap -K /mnt base linux linux-firmware cryptsetup btrfs-progs grub
```

- Note that the external USB backup system included in this architecture makes use of `sudo` for notification support (it’s one line in `usb-backup-lib.sh` - edit it yourself if you like)

Consider also installing:
- CPU microcode (`intel-ucode` or `amd-ucode`)
- networking software
- a firewall
- `reflector`, a tool for Arch mirror server selection
- `sudo`, a privilege escalation utility
- `xdg-user-dirs` for user XDG home directory management
- a console text editor
- a font, e.g. you may be setting `terminus-font` for vconsole readability
- `tlp` for *laptop* power management tools
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

To manually retreive the UUID of the encrypted root partition (not the PARTUUID):
```bash
blkid /dev/sdX2
```

Optionally append the correct UUID, commented, to the `/etc/default/grub` file in one line:
```bash
blkid -s UUID -o value /dev/sdX2 | sed 's/^/# /' >> /etc/default/grub
```

Edit `/etc/default/grub` and add the cryptdevice paramater (use copy and paste if you appended):
```
GRUB_CMDLINE_LINUX="cryptdevice=UUID=<recorded-UUID>:cryptroot root=/dev/mapper/cryptroot"
```

Install `GRUB` (UEFI target):
```bash
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=GRUB
```

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

Enable linger for a user to allow the use of their `systemd user` services, if a display manager will not be used to start user sessions:
```bash
loginctl enable-linger UserName
```

`xdg-user-dirs` may be installed for XDG home directory management.

Log in as the non-root user to configure XDG home directories for them.

Create and configure the default selection of XDG home directories: TODO: can i modify the dirs before updating?
```bash
xdg-user-dirs-update
```

Edit `~/.config/user-dirs.dirs` to personalize the XDG home directory selections. Run `xdg-user-dirs-update` to flush any changes.

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


## 12. Transparent Boot Summary

On boot:
1. UEFI firmware loads `GRUB` from the EFI System Partition
2. `GRUB` loads kernel and initramfs from `/boot`
3. The initramfs `encrypt` hook prompts for the LUKS passphrase
4. The encrypted container is unlocked
5. Btrfs subvolumes mount
6. System continues normal initialization


## 13. Security Model Notes

- EFI System Partition is unencrypted
- Disk encryption protects against offline disk access and device theft
- Secure Boot is optional
- Physical ESP tampering is outside the scope of this architecture

Passphrase-only unlocking is intentionally chosen over embedded keyfiles to preserve physical security.


## 14. Next Steps

At this stage, the system provides:
- Encrypted root file system
- Structured Btrfs subvolume layout
- Deterministic boot process

The next layer of the architecture is the [Internal Recovery Model](04-internal-recovery-model.md), which formalizes internal snapshot management and rollback strategies.
