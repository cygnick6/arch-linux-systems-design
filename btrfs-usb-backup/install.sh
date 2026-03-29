#!/usr/bin/env bash

set -euo pipefail

_PREFIX="/usr"
_LIB_DIR="$_PREFIX/lib/usb-backup"
_BIN_DIR="$_PREFIX/bin"

echo "--> Installing btrfs-usb-backup system"

if [[ "$EUID" -ne 0 ]]; then

    echo "Run as root"
    exit 1

fi

# directories
install -dm755 "$_LIB_DIR"
install -dm755 /etc/usb-backup
install -dm755 /var/log/usb-backup
install -dm700 /var/lib/usb-backup

# systemd
install -m644 backup/systemd/*.service /etc/systemd/system/
install -m644 backup/systemd/*.timer /etc/systemd/system/

# udev
install -m644 backup/udev/*.rules /usr/lib/udev/rules.d/

# logrotate
install -m644 backup/logrotate/usb-backup /etc/logrotate.d/

# config
if [[ ! -f /etc/usb-backup.conf ]]; then

    install -m600 backup/config/usb-backup.conf /etc/usb-backup.conf
    echo "--> Created /etc/usb-backup.conf (edit required for target UUID)"

fi

# lib
install -m644 backup/lib/usb-backup-lib.sh "$_LIB_DIR/"

# system scripts
install -m755 backup/scripts-system/*.sh "$_LIB_DIR/"

# user commands
install -m755 backup/scripts-manual/*.sh "$_BIN_DIR/"

# reload
systemctl daemon-reexec
systemctl daemon-reload
udevadm control --reload

echo "--> Installation complete"
echo ""
echo "--> MANUAL CONFIG REQUIRED"
echo "--> Add UUID of target Btrfs USB device to /etc/usb-backup.conf before use"
echo "--> Add UUID of target Btrfs USB device to /usr/lib/udev/rules.d/99-usb-backup.rules before use"
echo "--> Then enable timer:"
echo "    systemctl enable --now usb-backup-reminder.timer"
echo ""
echo "--> btrfs-usb-backup configuration:"
echo "      /etc/usb-backup.conf (backup scripting config)"
echo "      /etc/systemd/system/usb-backup-reminder.timer (backup schedule)"
echo "      /etc/logrotate.d/usb-backup (logrotate config)"
