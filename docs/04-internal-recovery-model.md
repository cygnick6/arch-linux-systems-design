# Internal Recovery Model

This document describes part of the core of this architecture’s design: the architecture for an *internal* snapshot layer.

## 1. Recovery Overview

The recovery model consists of three layers:
1. Internal snapshot layer - internal snapshot creation and rollback for protection from software failure
2. External backup layer - external backup strategies for protection from hardware failure or loss
3. Automated replication layer - remove part of the human element for a deterministic model

The architecture shown below addresses this system’s **automated** and **internal** snapshot layer architecture:
1. *Internal snapshot layer*
2. ~~*External backup layer*~~
3. *Automated replication layer*

The [External Recovery Model](07-external-recovery-model.md) will be be developed after a graphical stack is installed (for notification support).


## 2. Internal Recovery Design Principles

- Btrfs snapshot-based
- Root and home have different recovery domains
- `/boot` is not internally snapshotted or backed up - it is reconstructed from the restored `@` snapshot when needed
- `/boot` is treated as ever-derivable from the current or newly restored `@` subvolume
- Offline, internally-sourced rollback is available even if the system is unbootable
- Internal snapshot management automation is deterministic and inspectable

Internal snapshots *are not* external backups:
- Internal snapshots are for *software failure*
- External backups are for *hardware failure*

Internal snapshots will be created either:
- Using `Snapper` - managed by `Snapper`
- Manually using `btrfs subvolume snapshot` - not managed by `Snapper`


## 3. Internal Snapshot Layer

### 3.1 Install Packages

- `Snapper` is a tool used to create, manage, and cleanup snapshots
- `snap-pac` creates `@` snapshots pre/post pacman operations
- `grub-btrfs` enables `GRUB` to choose a `@` snapshot to temporarily boot into for inspection

Install the packages:
```bash
pacman -S snapper snap-pac grub-btrfs
```

### 3.2 Configure Snapper & Tools

Create `Snapper` configs for both `@` and `@home`. Each will detect the subvolumes created and mounted to `/.snapshots` and `/home/.snapshots` in the [BIOS](02-bios-base-installation.md#6.-btrfs-file-system--subvolume-layout) or [UEFI Base Installation](03-uefi-base-installation.md#6.-btrfs-file-system--subvolume-layout):
```bash
snapper -c root create-config /
snapper -c home create-config /home
```

The generated, default configurations can each be found at `/etc/snapper/configs/`. Consider altering the timeline and quantity values to fit your use case (e.g. `@home` snapshots may be generated less often, and fewer snapshots kept on hand).

Enable the timers for timeline-based `Snapper` operations:
```bash
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer
```

Symlink the root milestone snapshots into `/.snapshots` to give `grub-btrfs` access to them:
```bash
ln -s /.root-milestone-snapshots /.snapshots/milestones
```

- This symlink does not give `Snapper` access to the root milestone snapshots
- As such, `Snapper` will not manage the root milestone snapshots, as is intended

Enable `grub-btrfs`’s service and remake `GRUB`’s config:
```bash
systemctl enable --now grub-btrfsd.service
grub-mkconfig -o /boot/grub/grub.cfg
```

### 3.3 Manual Creation and Inspection

To list the existing `Snapper` snapshots:
```bash
snapper -c root list
snapper -c home list
```

Each `Snapper` snapshot has the structure (for `@` and `@home` respectively):
```
/.snapshots/<Number>/snapshot
/home/.snapshots/<Number>/snapshot
```

To manually create a `Snapper` snapshot:
```bash
snapper -c root create --description "custom description"
snapper -c home create --description "custom description"
```

### 3.4 Manual Online Rollback

Online rollbacks may be performed for `@home` or any subvolume non-essential to the system, but:
> Never perform an online *root* rollback

Instead, see [below](###4.2-Offline-Rollback) on how to perform an *offline* root rollback.

`Snapper` may be used to rollback a subvolume to a selected snapshot of that subvolume, in this way:
- A read-write snapshot is created from the selected read-only snapshot
- A read-only snapshot is created from the current target subvolume
- The read-write snapshot is placed and named in such a way as to replace the target subvolume

To rollback a `@home` `Snapper` snapshot:
```bash
snapper -c home rollback <snapshot-number>
reboot
```

- Reboot after any substantial, system-aware rollback (`@home` may contain configurations for window managers, etc.)

### 3.5 Internal Snapper Snapshot Layer Recap

The only two subvolumes whose snapshots are managed by Snapper are `@` and `@home`.

Snapshots are created in these contexts:
- Automatic timeline (Snapper config)
- Pre/post pacman usage (`snap-pac` package)
- Manual snapshot creation using Snapper

Snapshots are deleted in these contexts:
- Automatic timeline-based cleanup (Snapper config)
- Automatic quantity-based cleanup (Snapper config)
- Manual snapshot deletion


## 4. Internal Rollback Strategies

Internal snapshots may be used if the system is either functional or non-functional:
- Functional system -> online rollback
- Non-functional system -> offline rollback

The `@` subvolume may be rollbacked to recover from a software issue:
- Bad pacman update
- User deleting core system files

The `@home` subvolume may be rollbacked as well:
- Easily reverse an irreversible personal file deletion, etc.

### 4.1 Online Rollback

Utilize the commands found in [Manual Usage](###3.3-Manual-Usage) to perform an online rollback.

> Never perform online root rollbacks

### 4.2 Offline Root Rollback

In the event that the `@` subvolume needs to be restored, an offline rollback must be performed. A live environment must be used to gain access to the snapshots and root rollback functionality.

1. Boot into the live environment.

2. Unencrypt the main system’s file system, replacing `#` with the root partition:
```bash
cryptsetup open /dev/sdX# cryptroot
```

3. Create a mount point and mount the system’s top-level subvolume:
```bash
mkdir /mnt/btrfs
mount /dev/mapper/cryptroot /mnt/btrfs
```

4. Inspect and choose an existing `Snapper` `@` snapshot to use for the rollback:

To list available `Snapper` `@` snapshots:
```bash
ls /mnt/btrfs/@root_snapshots
```

Each `Snapper` `@` snapshot has the structure:
```
/.snapshots/<Number>/snapshot

```

To help with choosing a `@` to rollback to, consider inspecting its contents:
```bash
ls /mnt/btrfs/.snapshots/<Snapshot-Number-to-Inspect>/snapshot
```

- Also consider utilizing `grub-btrfs` to temporarily boot into a `@` snapshot and inspect in that way

5. Preserve the current `@` subvolume:

Optionally rename the current `@` subvolume `@broken` or similar for safety or for future inspection (it will be overwritten otherwise):
```bash
mv /mnt/btrfs/@ /mnt/btrfs/@_broken
```

6. Replace the current `@` subvolume:

Once a `Snapper` `@` snapshot is selected, rollback the current `@` to the target snapshot:
```bash
btrfs subvolume snapshot \
    /mnt/btrfs/@root_snapshots/<Target-Snapshot-Number>/snapshot \
    /mnt/btrfs/@
```

7. Ensure the newly restored snapshot is read-write:
```bash
btrfs property set -ts /mnt/btrfs/@ ro false
```

8. Unmount the top-level subvolume:
```bash
umount /mnt/btrfs
```

9. Mount the restored root and any required subvolumes:
```bash
mount -o subvol=@ /dev/mapper/cryptroot /mnt
mount --mkdir -o subvol=@home /dev/mapper/cryptroot /mnt/home
```

10. Mount the boot partition, replacing `#` with either the BIOS boot (or EFI system partition:
```bash
mount --mkdir /dev/sdX# /mnt/boot
```

- If `/boot` is not mounted, the possibly necessary `/boot` rebuild may silently fail and the restored system may not boot

11. Chroot into the restored system:
```bash
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
mount --bind /run /mnt/run
arch-chroot /mnt
```

12. Rebuild `/boot` from the restored `@` snapshot:

Choose one of the two following paths.

For BIOS base installations:
```bash
mkinitcpio -P
grub-install --target=i386-pc /dev/sdX
grub-mkconfig -o /boot/grub/grub.cfg
```

For UEFI base installations:
```bash
mkinitcpio -P
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
```

13. Exit, unmount, reboot
```bash
exit
umount -R /mnt
reboot
```

This completes an offline root rollback:
- `/boot` was recreated from the contents of the new `@` to deterministically remove mismatches in kernel, initramfs, CPU microcode, etc.
- `@home` and every other subvolume other than `@` was not restored


## 5. Root Milestone Snapshots (Not Snapper)

For extra control over the development of the Arch system, the `@root_milestone_snapshots` subvolume created in the [BIOS](02-bios-base-installation.md#6.-btrfs-file-system--subvolume-layout) or [UEFI Base Installation](03-uefi-base-installation.md#6.-btrfs-file-system--subvolume-layout) may be used.

At this stage in the system installation, the base system is installed along with `Snapper`, but neither non-essential packages nor any graphical stacks have been installed.

By creating a milestone snapshot of `@` now, an extra degree of freedom is afforded when trying out graphical stacks and configuring the user environment.

`Snapper` will not be used to manage root milestone snapshots to avoid `Snapper`’s automated cleanup.

### 5.1 Create Internal Root Milestone Snapshot

Create a read-only `@` snapshot named `01-base-install`:
```bash
btrfs subvolume snapshot -r / /.root-milestone-snapshots/01-base-install
```

### 5.2 Root Milestone Rollback

The `/` file system (not including any subvolume or contained file system other than `@`) may be restored to the `01-base-install` snapshot.

To do so, perform an [Offline Root Rollback](###4.2-Offline-Rollback), sourcing the snapshot to rollback to from `@root_milestone_snapshots` rather than the `Snapper` managed `@root_snapshots`.

Explicitly, follow the entire [Offline Root Rollback](###4.2-Offline-Rollback) section, but replace key steps **4.**, **5.**, and **6.** with:

4. Inspect and choose an existing `@` snapshot to use for the rollback:

Inspect available `@` milestone snapshots:
```bash
ls /mnt/btrfs/@root_milestone_snapshots
```

Inspect a specific `@` milestone snapshot (`01-base-install` or other):
```bash
ls /mnt/btrfs/@root_milestone_snapshots/01-base-install
```

- `grub-btrfs` was configured to also allow temporary boots into root milestone snapshots for inspection

5. Optionally preserve the current `@` subvolume (same as in original [Offline Root Rollback](###4.2-Offline-Rollback) section).

6. Replace the current `@` subvolume:

Rollback the current `@` to the target snapshot (`01-base-install` or other):
```bash
btrfs subvolume snapshot \
    /mnt/btrfs/.root-milestone-snapshots/01-base-install \
    /mnt/btrfs/@
```

Follow the rest of the [Offline Root Rollback](###4.2-Offline-Rollback) section to complete the rollback.


## 6. Internal Recovery Model Summary

This architecture established a Btrfs snapshot layer to maintain internal recoverability.

1. `Snapper` was installed and configured to:
- Automatically create and manage `Snapper` snapshots of `@` and `@home`

2. `snap-pac` was installed to:
- Automatically create `Snapper` snapshots on pacman operations

3. `grub-btrfs` was installed and configured to:
- Allow temporary booting and inspection of `Snapper` `@` snapshots via the `GRUB` menu
- Allow temporary booting and inspection of root milestone snapshots via the `GRUB` menu

4. Online and offline internal rollbacks were explored for recoverability

5. Milestone snapshots were explored for controlled `@` restoration


## 7. Next Steps

At this stage, the system provides:
- Base installation
    - Encrypted root file system
    - Structured Btrfs subvolume layout
    - Deterministic boot process
    - System maintenance and hardware monitoring
- Internal recovery strategy
    - Automated internal snapshot creation and management
    - Strategies for internally-sourced recovery
    - Milestone snapshot(s) created for `@`
    
The next layer of this architecture is the window-manager-based graphical stack. See this architecture’s [Philosophy](01-philosophy.md) for help with choosing between:
- The *tried and true* [xorg + i3 graphical stack](05-graphical-stack-xorg-i3.md)
- The *modern and future-facing* [wayland + sway graphical stack](06-graphical-stack-wayland-sway.md)
