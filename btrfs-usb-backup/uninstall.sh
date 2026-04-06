#!/usr/bin/env bash

set -euo pipefail

_PREFIX="/usr"
_LIB_DIR="$_PREFIX/lib/usb-backup"
_BIN_DIR="$_PREFIX/bin"

echo "--> Uninstalling btrfs-usb-backup system"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root"
    exit 1
fi

echo "--> Stopping and disabling systemd units"

systemctl stop usb-backup.service 2>/dev/null || true
systemctl stop usb-backup-reminder.service 2>/dev/null || true
systemctl stop usb-backup-reminder.timer 2>/dev/null || true

systemctl disable usb-backup-reminder.timer 2>/dev/null || true

echo "--> Removing systemd unit files"

rm -f /etc/systemd/system/usb-backup.service
rm -f /etc/systemd/system/usb-backup-reminder.service
rm -f /etc/systemd/system/usb-backup-reminder.timer

echo "--> Removing logrotate config"

rm -f /etc/logrotate.d/usb-backup

echo "--> Removing library and scripts"

rm -rf "$_LIB_DIR"

rm -f "$_BIN_DIR"/usb-backup-*.sh
rm -f "$_BIN_DIR"/usb-scrub-now.sh

echo ""
read -rp "--> Remove udev rule? [y/N]: " REMOVE_UDEV

if [[ "$REMOVE_UDEV" =~ ^[Yy]$ ]]; then

    echo "--> Removing udev rule"
    rm -f /usr/lib/udev/rules.d/99-usb-backup.rules

else

    echo "--> Preserving udev rule"

fi

echo ""
read -rp "--> Remove configuration and state data? [y/N]: " REMOVE_DATA

if [[ "$REMOVE_DATA" =~ ^[Yy]$ ]]; then

    echo "--> Removing /etc/usb-backup.conf"
    rm -f /etc/usb-backup.conf

    echo "--> Removing /var/lib/usb-backup"
    rm -rf /var/lib/usb-backup

    echo "--> Removing /var/log/usb-backup"
    rm -rf /var/log/usb-backup

else

    echo "--> Preserving configuration and state data"

fi

echo "--> Reloading systemd and udev"

systemctl daemon-reexec
systemctl daemon-reload
udevadm control --reload

echo ""
echo "--> Uninstallation complete"
