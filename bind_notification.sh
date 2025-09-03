#!/usr/bin/env bash
# Bind desktop notifications to a chosen DISPLAY (default :1) on Qubes 4.2 dom0.
# ~/bin/alerts-on.sh
set -euo pipefail

D="${1:-:1}"                      # target display, e.g. :1
export DISPLAY="$D"

# 1) Ensure we have a session D-Bus (needed for org.freedesktop.Notifications)
if ! gdbus call --session --dest org.freedesktop.DBus --object-path / \
  --method org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  eval $(dbus-launch --sh-syntax)    # sets DBUS_SESSION_BUS_ADDRESS, etc.
fi

# 2) Stop any existing notifier (usually tied to :0)
pkill -x xfce4-notifyd 2>/dev/null || true
pkill -x dunst 2>/dev/null || true

# 3) Pick a notifier (prefer XFCE's, fallback to dunst)
start_notifier() {
  # Fedora/Qubes path for xfce4-notifyd
  if [ -x /usr/libexec/xfce4/notifyd/xfce4-notifyd ]; then
    nohup /usr/libexec/xfce4/notifyd/xfce4-notifyd >/dev/null 2>&1 &
    return 0
  fi
  # Generic path
  if command -v xfce4-notifyd >/dev/null 2>&1; then
    nohup xfce4-notifyd >/devnull 2>&1 &
    return 0
  fi
  # Fallback: dunst (if installed)
  if command -v dunst >/dev/null 2>&1; then
    nohup dunst >/dev/null 2>&1 &
    return 0
  fi
  echo "No notification daemon found (xfce4-notifyd/dunst)." >&2
  exit 1
}

start_notifier

# 4) Quick self-test toast (optional: comment out if you don’t want it)
sleep 0.3
if command -v notify-send >/dev/null 2>&1; then
  notify-send "VNC Alerts Active" "Notifications bound to $DISPLAY"
fi
