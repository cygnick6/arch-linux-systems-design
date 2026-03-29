# Arch Linux Systems Design

An opinionated, architecture-focused approach to building a resilient Arch Linux system using Btrfs, Snapper, window-manager-based graphical stacks, and a custom external USB backup framework.

This project contains a single, well-reasoned system design intended for long-term personal use. It emphasizes transparent and deterministic recovery, layered snapshot management, and minimal graphical environments over desktop abstractions.

This is not a beginner’s introduction to Arch.
It is a structured system architecture for users who want to understand and control their system’s behavior.

---

## Project Goals

- Define a resilient base Arch installation (BIOS or UEFI) centered on Btrfs snapshotting
- Implement an automated, layered recovery model (internal snapshot layer + external replication)
- Favor deterministic recovery over convenience
- Use window-manager-based graphical stacks (i3 or sway) instead of full desktop environments

---

## Hardware Context

The design documented here was developed and tested on both legacy BIOS and modern UEFI-based laptop hardware.

---

## Core Design Principles

- **Single coherent path** - This project does not present multiple competing installation strategies. It documents one architecture
- **Snapshot-driven system state** - System integrity is managed through structured snapshot creation and retention
- **Layered recovery architecture** - Internal snapshotting + rollback and external backups + recovery are treated as distinct layers
- **Minimal and transparent system design** – Only essential components are included. System behavior is visible and understandable rather than abstracted behind desktop layers
- **Intentional operation** – Updating and maintaining the system follows a structured operational model designed to preserve system integrity

---

## Repository Structure

The Arch system architecture described in this repository is broken up into:
- [Documentation](./docs/) (docs/)
- [External Btrfs USB Backup System](./btrfs-usb-backup/) (btrfs-usb-backup/)

### docs

Each document represents a distinct layer of the system architecture.
The core of the design is found in the **Internal and External Recovery Model Sections**, which is based on system configuration from the **Base Installation Section**.

See the [docs README](docs/README.md) for orientation.

- [01 – Philosophy](docs/01-philosophy.md)
- [02 – BIOS Base Installation](docs/02-bios-base-installation.md)
- [03 - UEFI Base Installation](docs/03-uefi-base-installation.md)
- [04 – Internal Recovery Model](docs/04-internal-recovery-model.md)
- [05 – Graphical Stack: Xorg + i3](docs/05-graphical-stack-xorg-i3.md)
- [06 – Graphical Stack: Wayland + sway](docs/06-graphical-stack-wayland-sway.md)
- [07 - External Recovery Model](docs/07-external-recovery-model.md)
- [08 – Operational Discipline](docs/08-operational-discipline.md)
- [09 – Extensions and Enhancements](docs/09-extensions-and-enhancements.md)
- [10 – Official Reference Material](docs/10-official-reference-material.md)

### btrfs-usb-backup

The [btrfs-usb-backup](./btrfs-usb-backup/) system is a transparent, inspectable external backup system that enables deterministic externally-based system recovery.

It was designed around the [BIOS](docs/02-bios-base-installation.md) and [UEFI](docs/03-uefi-base-installation.md) Base Installations, and to work in parallel with the [Internal Recovery Model](docs/04-internal-recovery-model.md).

Features:
- Btrfs snapshot-based
- Incremental, self-healing backup processes
    - Full system replication (root + /home)
    - Portable /home file-level backup
- Automated backups that require minimal user intervention
- Backup state + health inspectability and transparency
- Enables deterministic externally-sourced recovery

See the [btrfs-usb-backup README](btrfs-usb-backup/README.md) for orientation.

See the [btrfs-usb-backup INSTALL](btrfs-usb-backup/INSTALL.md) document for quick-start installation.

---

## Intended Audience

This architecture is intended for intermediate Linux users who:

- Have experience using Arch or another Linux distribution
- Want to move away from full desktop environments
- Want to understand and control their system’s recovery behavior
- Value a structured, opinionated architecture over broad option lists

---

## Status

Active development.

The repository structure is scaffolded to reflect the intended system architecture. Sections are incrementally refined and merged into `main` upon reaching stable milestones.

Treat any code or documentation solely located in the `dev` branch as untested.

See [docs](docs/README.md) and [btrfs-usb-backup](btrfs-usb-backup/README.md) READMEs for future implementations.

---

## Scope

This repository does not intend to replace the [Arch Wiki](https://wiki.archlinux.org/title/Main_page).
It documents a specific system design built using Arch.

Readers are encouraged to consult the [Arch Wiki](https://wiki.archlinux.org/title/Main_page) for detailed reference documentation.
