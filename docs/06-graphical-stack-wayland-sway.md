# Graphical Stack - Wayland + Sway

This document defines a minimal graphical environment built on Wayland using a tiling compositor.

This stack is the Wayland-native counterpart to the Xorg + i3 setup.

The goal is to provide a modern, minimal, laptop-oriented environment with improved input and rendering behavior compared to Xorg.

This stack follows the same principles as the Xorg-based environment:
- *Transparency*
- *Determinism*
- *Low system complexity*

Additionally, Wayland introduces:
- Compositor-centric design – replaces Xorg + compositor split
- Improved input handling – especially for touchpads and HiDPI
- Stronger isolation between applications
- Stack Layers

This is not a complete list of packages to install a ready-to-use graphical environment - user research and design choices must be made.

- Consider looking online for window-manager-based Arch installations, dotfiles, etc.


## 1. Graphical Environment Structure

The graphical environment is composed of distinct functional layers.

## 1.1 Wayland Compositor

Replaces:
- Xorg server
- Window manager
- Compositor

Responsible for:
- Display output
- Input handling
- Window management
- Rendering

Requirement:
- A Wayland compositor with tiling capabilities

This architecture assumes:
- i3-like behavior and configuration model


## 1.2 Session Initialization

Defines how the Wayland session is launched.

Requirement:
- Manual session startup from TTY

Typical approach:
- Launch compositor directly from shell

This avoids:
- Display managers
- Hidden session logic


## 1.3 Terminal Emulator

Requirement:
- A Wayland-compatible terminal emulator


## 1.4 Status / Bar

Provides:
- Workspace information
- System metrics

Requirement:
- A bar compatible with the compositor


## 1.5 Application Launcher

Provides:
- Keyboard-driven application launching

Requirement:
- A launcher compatible with Wayland


## 1.6 Notification System

Provides:
- Desktop notifications

Requirement:
- A notification daemon compatible with Wayland protocols


## 1.7 Idle / Lock Management

Wayland separates idle handling more explicitly.

Requirement:
- Idle daemon (detect inactivity)
- Screen locker


## 1.8 Audio Stack

Same requirements as Xorg stack:
- Audio server
- Session manager
- Control utilities


## 1.9 Network Management

Provides:
- User-facing network control

Same role as in Xorg stack.


## 1.10 Power and Hardware Control

Provides:
- Backlight control
- Power management

Same conceptual role as Xorg, but tools must be Wayland-compatible where applicable.

## 1.11 Clipboard and Data Sharing

Wayland changes clipboard behavior.

Requirement:
- Wayland-compatible clipboard utilities


## 1.12 Screenshot / Screen Capture

Wayland requires compositor-aware tools.

Requirement:
- Screenshot utilities that integrate with Wayland protocols


## 1.13 XWayland Compatibility Layer (Optional but Common)

Provides:
- Support for legacy X11 applications

Requirement:
- XWayland bridge


## 1.14 Theming (Optional)

Same as Xorg:
- GTK themes
- Icons
- Fonts
- Session Model


## 2. Installation Flow

If you anticipate wanting to start over from this stage, consider utillizing the `@milestone_snapshots` subvolumes to do so.

### 2.1 Install packages

Install choice packages to satisfy the [structure](##-1.-graphical-environment-structure) described above.

### 2.2 Start User Environment

When in the TTY interface, logged in as the personal user, execute this to start the environment:
```bash
sway
```

### 2.3 Dotfiles

A default config for `i3` may be created. Check its contents to get familiar with the layout, customizable aspects, and general flow of using `i3`.

Other configurations and dotfiles will come into play as different programs are installed and used. These configuration files and dotfiles form the core of user customizability.


## 3. Internal Milestone Snapshots

For extra control over the development of the Arch system, the `@root_milestone_snapshots` and `@home_milestone_snapshots` subvolumes created in the [BIOS](02-bios-base-installation.md#6.-btrfs-file-system--subvolume-layout) or [UEFI Base Installation](03-uefi-base-installation.md#6.-btrfs-file-system--subvolume-layout) may be used.

At this stage in the system installation, the base installation, internal recovery layer, and graphical stack, are all installed. Beyond this point, it may be useful to have access to this system state.

`Snapper` will not be used to manage root milestone snapshots to avoid `Snapper`’s automated cleanup.

### 3.1 Create Internal Milestone Snapshots

Create read-only `@` and `@home` snapshots named `06-graphical-stack`:
```bash
btrfs subvolume snapshot -r / /.milestone-snapshots/06-graphical-stack
btrfs subvolume snapshot -r /home /.milestone-snapshots/06-graphical-stack
```

- This is the first milestone where a `@home` milestone snapshot is also recommended. The graphical stack developed here stores configs and dotfiles in the users home directory

### 3.2 Milestone Rollback

Internally-sourced rollback is explored in the [Internal Recovery Model](04-internal-recovery-model.md#5.2-root-milestone-rollback) document.

- The internally-sourced rollback will need to operate on `@` and `@home` together for a successful system rollback, as `@home` now has configs and dotfiles


## 4. Graphical Stack Summary

A completed Wayland + sway stack provides:
- Smooth rendering and reduced tearing
- Better laptop input handling
- Minimal, keyboard-driven workflow
- Reduced reliance on legacy X11 components

This document does not cover:
- Advanced compositor configuration
- Wayland protocol deep dives
- Dotfile ecosystems

These are intentionally left to the user.


## 5. Next Steps

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
    - A minimal, functional user environment
    
The next layer of this architecture is the [External Recovery Model](docs/07-external-recovery-model.md).
