#!/bin/bash
# robot-firstboot.sh: robot-firstboot.service, until setup is done. Stage 1
# (first boot): tailscale, clone the workspace, robot_setup.sh (reboots).
# Stage 2 (next boot): build the image once, start thornbots.service, and
# disable this unit. Log: journalctl -u robot-firstboot; state in
# /var/lib/robot-firstboot. Re-runs a failed stage on the next boot.
set -euxo pipefail
S=/var/lib/robot-firstboot
# shellcheck source=/dev/null
source "$S/robot.env"
H=$(getent passwd "$ROBOT_USER" | cut -d: -f6)
WS="$H/workspaces/isaac_ros-dev"
as_user() { sudo -u "$ROBOT_USER" -H "$@"; }

for _ in $(seq 60); do curl -fsI https://github.com >/dev/null 2>&1 && break; sleep 5; done

if [ ! -e "$S/stage1-done" ]; then
    command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
    if [ -n "${TS_AUTHKEY:-}" ] && ! tailscale status >/dev/null 2>&1; then
        # An OAuth client secret needs the flags an auth key carries itself.
        key="$TS_AUTHKEY"; [[ "$key" == tskey-client-* ]] && key+="?ephemeral=false&preauthorized=true"
        tailscale up --ssh --hostname "$ROBOT_HOSTNAME" --advertise-tags=tag:jetsons --authkey "$key"
    fi
    command -v git >/dev/null || apt-get install -y -q git
    if [ ! -d "$WS/src/.git" ]; then
        as_user mkdir -p "$WS"
        as_user git clone -q --recurse-submodules "$WS_REPO" "$WS/src"
        as_user git -C "$WS/src" submodule foreach -q \
            'git checkout -q $(git config -f $toplevel/.gitmodules submodule.$name.branch)'
    fi
    as_user "$WS/src/isaac_ros_common/scripts/setup_workspace.sh"
    touch "$S/stage1-done"
    # robot_setup.sh ends in a reboot; stage 2 runs on the next boot.
    SUDO_USER="$ROBOT_USER" bash "$WS/src/isaac_ros_common/scripts/robot_setup.sh"
    exit 0
fi

if [ ! -e "$S/image-done" ]; then
    as_user env ISAAC_ROS_WS="$WS" isaac-ros activate --build-local --build-only
    docker images --format '{{.Tag}}' nvcr.io/nvidia/isaac/ros | grep -q realsense-thornbots
    touch "$S/image-done"
fi
systemctl disable robot-firstboot.service
systemctl start thornbots.service
