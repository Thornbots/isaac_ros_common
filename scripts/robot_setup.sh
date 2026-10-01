#!/bin/bash
# robot_setup.sh: the one command after the JetPack 7.2.1 USB installer, run
# on the robot Orin from the cloned workspace:
#   sudo ~/workspaces/isaac_ros-dev/src/isaac_ros_common/scripts/robot_setup.sh
# Passwordless sudo and timezone, jetson_setup.sh (host setup), jetson_trim.sh
# (headless), isaac-ros-startup's boot service, tailscale login, then
# MAXN_SUPER and one reboot. Safe to re-run. After it: log in again,
# `isaac-ros activate --build-local` once, and the service starts at boot.
# see JAZZY_FLASH.md for design rationale
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive   # robot-firstboot runs this with no terminal
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
U="${SUDO_USER:?run with sudo from the robot user, not a root shell}"
HERE="$(dirname "$(readlink -f "$0")")"
WS_SRC="$(readlink -f "$HERE/../..")"
log() { printf '\n==== %s\n' "$*"; }

log "passwordless sudo for $U, timezone America/New_York"
echo "$U ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-$U-nopasswd"
chmod 440 "/etc/sudoers.d/90-$U-nopasswd"
visudo -cf "/etc/sudoers.d/90-$U-nopasswd" >/dev/null
timedatectl set-timezone America/New_York
echo America/New_York > /etc/timezone

log "jetson_setup.sh"
NO_REBOOT=1 bash "$HERE/jetson_setup.sh" "$@"

log "jetson_trim.sh"
bash "$HERE/jetson_trim.sh"

log "boot service (isaac-ros-startup)"
if [ -f "$WS_SRC/isaac-ros-startup/install.sh" ]; then
    bash "$WS_SRC/isaac-ros-startup/install.sh" --ws "$(readlink -f "$WS_SRC/..")"
else
    echo "warning: no $WS_SRC/isaac-ros-startup; run git submodule update --init" >&2
fi

log "tailscale"
if tailscale status >/dev/null 2>&1; then
    tailscale set --ssh
    echo "tailscale IP $(tailscale ip -4): put it in fastdds_cable.xml and fastdds_udp_only.xml if new"
elif [ -t 0 ]; then
    # Prints a login URL to approve; the node joins tag:jetsons.
    tailscale up --ssh --hostname "ts-$(hostname | sed 's/^ts-//')" --advertise-tags=tag:jetsons
else
    echo "tailscale not logged in and no terminal: later run" \
        "sudo tailscale up --ssh --hostname ts-$(hostname | sed 's/^ts-//') --advertise-tags=tag:jetsons"
fi

log "MAXN_SUPER and reboot"
ID=$(sed -n 's/^< POWER_MODEL ID=\([0-9]*\) NAME=MAXN_SUPER >/\1/p' /etc/nvpmodel.conf)
[ -n "$ID" ] && nvpmodel -m "$ID" --force   # reboots if the mode changes
systemctl reboot
