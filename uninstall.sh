#!/usr/bin/env bash
#
# uninstall.sh — fully remove the Goodix 55A4 fix.
#
# Deletes the patched library and the fprintd.systemd-ext drop-in, then
# restores the stock fprintd (that always used the distro's own libfprint).
#
#   sudo bash uninstall.sh
#
set -euo pipefail

DEST=/opt/libfprint-goodix
DROPIN=/etc/systemd/system/fprintd.service.d/10-goodix55a4.conf
RUNMAX=/etc/systemd/system/fprintd.service.d/20-goodix-runtime-max.conf
SLEEPFIX=/etc/systemd/system/fprintd-sleep-fix.service
UDEVRULE=/etc/udev/rules.d/61-goodix-no-autosuspend.rules

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo:  sudo bash $0" >&2; exit 1; }

[ -d "$DEST" ] && rm -rf "$DEST" && echo "removed $DEST"
[ -f "$DROPIN" ] && rm -f "$DROPIN" && echo "removed $DROPIN"
[ -f "$RUNMAX" ] && rm -f "$RUNMAX" && echo "removed $RUNMAX"
if [ -f "$SLEEPFIX" ]; then
  systemctl disable -q fprintd-sleep-fix.service 2>/dev/null || true
  rm -f "$SLEEPFIX" && echo "removed $SLEEPFIX"
fi
if [ -f "$UDEVRULE" ]; then
  rm -f "$UDEVRULE" && echo "removed $UDEVRULE"
  udevadm control --reload 2>/dev/null || true
fi

systemctl daemon-reload
systemctl restart fprintd.service 2>/dev/null || true
echo "done — fprintd now uses your distro's stock libfprint again."