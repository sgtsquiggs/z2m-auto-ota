#!/usr/bin/env bash
# Install or upgrade z2m-auto-ota on this machine. Safe to run repeatedly:
# it never overwrites an existing /etc/z2m-auto-ota.conf.
#
# Usage: sudo ./install.sh [--no-enable]
#   --no-enable  install the files but do not enable the nightly timer

set -euo pipefail

cd "$(dirname "$0")"

enable=true
case ${1:-} in
    "") ;;
    --no-enable) enable=false ;;
    *) echo "usage: sudo $0 [--no-enable]" >&2; exit 2 ;;
esac

if [[ $EUID -ne 0 ]]; then
    echo "install.sh must run as root: sudo $0" >&2
    exit 1
fi
if ! command -v systemctl >/dev/null; then
    echo "systemd is required" >&2
    exit 1
fi

missing=()
command -v mosquitto_sub >/dev/null || missing+=(mosquitto-clients)
command -v jq >/dev/null || missing+=(jq)
if ((${#missing[@]})); then
    if command -v apt-get >/dev/null; then
        echo "Installing ${missing[*]}"
        apt-get update
        apt-get install -y "${missing[@]}"
    else
        echo "Please install these packages first: ${missing[*]}" >&2
        exit 1
    fi
fi

install -m 0755 bin/z2m-auto-ota /usr/local/bin/z2m-auto-ota
install -m 0644 systemd/z2m-auto-ota.service /etc/systemd/system/z2m-auto-ota.service
install -m 0644 systemd/z2m-auto-ota.timer /etc/systemd/system/z2m-auto-ota.timer

if [[ -e /etc/z2m-auto-ota.conf ]]; then
    echo "Keeping existing /etc/z2m-auto-ota.conf"
else
    install -m 0600 z2m-auto-ota.conf.example /etc/z2m-auto-ota.conf
    echo "Created /etc/z2m-auto-ota.conf from the example; review it"
fi

systemctl daemon-reload
if [[ $enable == true ]]; then
    systemctl enable --now z2m-auto-ota.timer
    systemctl list-timers z2m-auto-ota.timer --no-pager
fi

echo
echo "Installed $(/usr/local/bin/z2m-auto-ota --version)."
echo "Try a dry run:   sudo z2m-auto-ota --dry-run"
if [[ $enable != true ]]; then
    echo "Enable nightly:  sudo systemctl enable --now z2m-auto-ota.timer"
fi
echo "Run it now:      sudo systemctl start --no-block z2m-auto-ota"
echo "Follow the logs: journalctl -u z2m-auto-ota -f"
