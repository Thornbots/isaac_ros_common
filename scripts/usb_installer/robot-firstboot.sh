#!/bin/bash
# robot-firstboot.sh: robot-firstboot.service, until setup is done. Stage 1
# (first boot): tailscale, clone the workspace, robot_setup.sh (reboots).
# Stage 2 (next boot): build the image once, start thornbots.service, and
# disable this unit. Log: journalctl -u robot-firstboot; state in
# /var/lib/robot-firstboot. Re-runs a failed stage on the next boot.
set +x
set -euo pipefail
S=/var/lib/robot-firstboot
# shellcheck source=/dev/null
source "$S/robot.env"
H=$(getent passwd "$ROBOT_USER" | cut -d: -f6)
WS="$H/workspaces/isaac_ros-dev"
as_user() { sudo -u "$ROBOT_USER" -H "$@"; }

tailscale_state() {
    local status state
    for _ in $(seq 30); do
        status=$(timeout 5 tailscale status --json 2>/dev/null || true)
        state=$(python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("BackendState", ""))
except (ValueError, AttributeError):
    pass' <<< "$status")
        case "$state" in
            Running|NeedsLogin) printf '%s\n' "$state"; return 0 ;;
            ""|NoState|Starting) sleep 2 ;;
            *) break ;;
        esac
    done
    echo "Tailscale is not ready; retry firstboot after checking network and tailscaled." >&2
    return 1
}

for _ in $(seq 60); do curl -fsI https://github.com >/dev/null 2>&1 && break; sleep 5; done

if [ ! -e "$S/stage1-done" ]; then
    command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
    if [ -n "${TS_AUTHKEY:-}" ]; then
        state=$(tailscale_state)
        if [ "$state" = NeedsLogin ]; then
            # An OAuth client secret needs the flags an auth key carries itself.
            key="$TS_AUTHKEY"; [[ "$key" == tskey-client-* ]] && key+="?ephemeral=false&preauthorized=true"
            # up can echo its authkey in a suggested command on preference errors.
            if ! timeout 120 tailscale up --ssh --hostname "$ROBOT_HOSTNAME" \
                --advertise-tags=tag:jetsons --accept-dns=false --authkey "$key" >/dev/null 2>&1; then
                echo "Tailscale authentication failed; check network and saved preferences, then retry firstboot." >&2
                exit 1
            fi
            state=$(tailscale_state)
            if [ "$state" != Running ]; then
                echo "Tailscale still needs login; retry firstboot after checking authentication." >&2
                exit 1
            fi
        fi
    fi
    command -v git >/dev/null || apt-get install -y -q git
    if [ ! -d "$WS/src/.git" ]; then
        as_user mkdir -p "$WS"
        as_user git clone -q --recurse-submodules "$WS_REPO" "$WS/src"
        as_user git -C "$WS/src" submodule foreach -q \
            'git checkout -q $(git config -f $toplevel/.gitmodules submodule.$name.branch)'
    fi
    as_user "$WS/src/isaac_ros_common/scripts/setup_workspace.sh"
    # Setup records completion before its final power-mode change can reboot.
    SUDO_USER="$ROBOT_USER" ROBOT_SETUP_COMPLETE_FILE="$S/stage1-done" \
        bash "$WS/src/isaac_ros_common/scripts/robot_setup.sh"
    exit 0
fi

if [ ! -e "$S/image-done" ]; then
    as_user env ISAAC_ROS_WS="$WS" isaac-ros activate --build-local --build-only
    docker images --format '{{.Tag}}' nvcr.io/nvidia/isaac/ros | grep -q realsense-thornbots
    touch "$S/image-done"
fi
systemctl disable robot-firstboot.service
systemctl start thornbots.service
