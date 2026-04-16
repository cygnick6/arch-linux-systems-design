# Graphical Stack - Xorg + i3

This document defines how to create a minimal, window-manager-based graphical environment built on Xorg and i3.

The goal is to provide a functional, daily-use laptop environment while preserving:
- *Transparency*
- *Determinism*
- *Low system complexity*

This document intentionally does not cover:
- Dotfile customization
- Advanced theming
- Workflow optimization
- Shell configuration

This is not a complete list of packages to install a ready-to-use graphical environment - user research and design choices must be made.

- Consider looking online for window-manager-based Arch installations, dotfiles, etc.


## 1. Graphical Environment Structure

The graphical environment is composed of distinct functional layers.


### 1.1 Display Server

Provides:
- Input handling (keyboard, mouse, touchpad)
- Output management (screen rendering)
- Windowing primitives

Requirement:
- An Xorg server implementation

User must choose:
- GPU driver appropriate for hardware
- Basic Xorg utilities for session startup


### 1.2 Window Manager

Responsible for:
- Window placement
- Workspaces
- Input bindings
- Layout behavior

Requirement:
- A tiling window manager

This architecture assumes:
- i3-style tiling workflow
- Keyboard-driven interaction model


### 1.3 Session Initialization

Defines how the graphical session starts.

Requirement:
- A mechanism to launch the window manager from a TTY

Typical approach:
- Use a user-controlled startup file (e.g. .xinitrc)

This ensures:
- No display manager dependency
- Fully transparent session startup


### 1.4 Terminal Emulator

Primary interface for:
- System interaction
- Shell access
- Development workflows

Requirement:
- A graphical terminal emulator compatible with Xorg


### 1.5 Status / Bar

Provides:
- Workspace indicators
- System status (battery, network, audio, etc.)
- Time/date

Requirement:
- A status bar compatible with the window manager


### 1.6 Application Launcher

Provides:
- Fast keyboard-driven program launching

Requirement:
- A launcher that integrates with Xorg


### 1.7 Compositor (Optional but Recommended)

Provides:
- Window transparency
- VSync / tearing control
- Basic visual effects

Requirement:
- A compositor compatible with Xorg


### 1.8 Notification System

Provides:
- System and application notifications

Requirement:
- A notification daemon implementing the freedesktop notification spec


### 1.9 Power and Hardware Control

Provides:
- Brightness control
- Battery monitoring
- Power management behavior

User must choose tools for:
- Backlight control
- Power optimization
- AC/battery behavior tuning


### 1.10 Audio Stack

Provides:
- Sound playback and control

Requirement:
- A modern Linux audio system

User must include:
- Audio server
- Session manager
- Utilities for volume/device control


### 1.11 Network Management (User Session Layer)

Provides:
- Wi-Fi selection
- Network status integration

Requirement:
- A user-facing interface to the system network stack


### 1.12 File and Clipboard Utilities

Provides:
- Clipboard interaction
- Basic file handling

User must choose:
- Clipboard tools compatible with Xorg
- Optional lightweight file manager


### 1.13 Screenshot / Screen Utilities

Provides:
- Screen capture
- Basic graphical tooling


### 1.14 Theming (Optional)

Provides:
- GTK theming
- Icon sets
- Cursor themes

This layer is purely cosmetic and should not introduce heavy dependencies.


## 2. Installation Flow

If you anticipate wanting to start over from this stage, consider utillizing the `@milestone_snapshots` subvolumes to do so.

### 2.1 Install packages

Install choice packages to satisfy the [structure](##-1.-graphical-environment-structure) described above.

### 2.2 Create .xinitrc

In order to start a session, `~/.xinitrc` must exist and contain at least the following line:
```ini
exec i3
```

### 2.3 Start User Environment

When in the TTY interface, logged in as the personal user, execute this to start the environment:
```bash
startx
```

### 2.4 Dotfiles

A default config for `i3` may be created. Check its contents to get familiar with the layout, customizable aspects, and general flow of using `i3`.

Other configurations and dotfiles will come into play as different programs are installed and used. These configuration files and dotfiles form the core of user customizability.


## 3. Internal Milestone Snapshots

For extra control over the development of the Arch system, the `@root_milestone_snapshots` and `@home_milestone_snapshots` subvolumes created in the [BIOS](02-bios-base-installation.md#6.-btrfs-file-system--subvolume-layout) or [UEFI Base Installation](03-uefi-base-installation.md#6.-btrfs-file-system--subvolume-layout) may be used.

At this stage in the system installation, the base installation, internal recovery layer, and graphical stack, are all installed. Beyond this point, it may be useful to have access to this system state.

`Snapper` will not be used to manage root milestone snapshots to avoid `Snapper`’s automated cleanup.

### 3.1 Create Internal Milestone Snapshots

Create read-only `@` and `@home` snapshots named `05-graphical-stack`:
```bash
btrfs subvolume snapshot -r / /.milestone-snapshots/05-graphical-stack
btrfs subvolume snapshot -r /home /home/.milestone-snapshots/05-graphical-stack
```

- This is the first milestone where a `@home` milestone snapshot is also recommended. The graphical stack developed here stores configs and dotfiles in the users home directory

### 3.2 Milestone Rollback

Internally-sourced rollback is explored in the [Internal Recovery Model](04-internal-recovery-model.md#5.2-root-milestone-rollback) document.

- The internally-sourced rollback will need to operate on `@` and `@home` together for a successful system rollback, as `@home` now has configs and dotfiles


## 4. Graphical Stack Summary

This stack uses a manual session model:
- System boots into TTY
- User logs in
- Graphical session is started manually

All user configuration resides in:
- Home directory
- User-managed dotfiles

A completed Xorg + i3 stack provides:
- Fast, keyboard-driven workflow
- Minimal resource usage
- Fully inspectable system behavior
- High reliability due to low complexity

These belong to user preference and are outside the scope of system architecture.


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
