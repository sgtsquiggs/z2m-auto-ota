#!/usr/bin/env bash
# Remove z2m-auto-ota. Keeps /etc/z2m-auto-ota.conf unless --purge is given.
#
# Usage: sudo ./uninstall.sh [--purge]

set -euo pipefail

purge=false
case ${1:-} in
    "") ;;
    --purge) purge=true ;;
    *) echo "usage: sudo $0 [--purge]" >&2; exit 2 ;;
esac

if [[ $EUID -ne 0 ]]; then
    echo "uninstall.sh must run as root: sudo $0" >&2
    exit 1
fi

systemctl disable --now z2m-auto-ota.timer 2>/dev/null || true
# Stopping the service mid-update does not stop the update itself;
# Zigbee2MQTT finishes it on its own.
systemctl stop z2m-auto-ota.service 2>/dev/null || true
rm -f /etc/systemd/system/z2m-auto-ota.service /etc/systemd/system/z2m-auto-ota.timer
rm -f /usr/local/bin/z2m-auto-ota
systemctl daemon-reload

if [[ $purge == true ]]; then
    rm -f /etc/z2m-auto-ota.conf
    echo "Removed z2m-auto-ota and its config."
else
    echo "Removed z2m-auto-ota. Kept /etc/z2m-auto-ota.conf (use --purge to remove it)."
fi
