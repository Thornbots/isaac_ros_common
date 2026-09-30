#!/bin/bash
# jetson_setup.sh: host setup for an Orin Nano on JetPack 7.2.1 (L4T R39.2.1),
# run once after the USB installer and oem-config. Covers JAZZY_FLASH.md
# section 6, isaac-ros-cli included, plus the robot-specific host settings.
# Run as the robot user:
#   sudo ./jetson_setup.sh
# It replaces and restarts Docker, so it refuses to run while a build or
# container is up (--force overrides). Reboot afterwards.
# Safe to re-run.
# see JAZZY_FLASH.md for design rationale
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
U="${SUDO_USER:?run with sudo from the robot user, not a root shell}"
H=$(getent passwd "$U" | cut -d: -f6)
if [ "${1:-}" != --force ] && { pgrep -f 'docker.*(build|bake)' >/dev/null ||
        docker ps -q 2>/dev/null | grep -q .; }; then
    echo "a docker build or container is running; this restarts Docker." >&2
    echo "stop it first, or pass --force" >&2; exit 1
fi
grep -q '^# R39' /etc/nv_tegra_release || echo "warning: written for L4T R39" >&2
log() { printf '\n== %s\n' "$*"; }

# First, before apt touches the toolkit: its postinst enables
# nvidia-cdi-refresh, which in nvml mode opens the GPU at boot. On 2026-09-27
# that left nvgpu dead for the whole boot (ACR bootstrap failed). CSV mode
# never opens the GPU.
log "CDI refresh in CSV mode"
mkdir -p /etc/nvidia-container-toolkit
echo NVIDIA_CTK_CDI_GENERATE_MODE=csv > /etc/nvidia-container-toolkit/nvidia-cdi-refresh.env

log "apt packages"
# A debs/ dir beside this script (the installer stick) seeds apt's cache;
# apt checks each .deb against its index, so stale files are just ignored.
DEBS="$(dirname "$(readlink -f "$0")")/debs"
[ -d "$DEBS" ] && cp -n "$DEBS"/*.deb /var/cache/apt/archives/ 2>/dev/null || true
apt-get update -q
apt-get install -y -q nvidia-jetpack nvidia-container pva-allow-2 \
    git-lfs jq curl python3-pip
nvidia-ctk cdi generate --mode=csv --output=/var/run/cdi/nvidia.yaml

# nvidia-container ships nv-install-docker.service, which swaps Ubuntu's
# docker.io for Docker CE on a 30 s retry after apt exits, stopping Docker
# whenever it lands. Run it here instead. Its own `systemctl start docker`
# fails after the swap (docker.socket is stale), so start Docker ourselves.
log "Docker CE (NVIDIA's nv-install-docker, run in order)"
if [ -f /etc/systemd/nv-install-docker.sh ]; then
    systemctl disable nv-install-docker.service
    while pgrep -f nv-install-docker.sh >/dev/null; do sleep 5; done
    systemctl stop nv-install-docker.service || true
    bash /etc/systemd/nv-install-docker.sh || true
    bash /etc/systemd/nv-install-docker-cleanup.sh
fi
systemctl daemon-reload
systemctl reset-failed docker.service docker.socket 2>/dev/null || true
systemctl enable --now containerd docker.socket docker

log "docker: nvidia as default runtime"
nvidia-ctk runtime configure --runtime=docker --set-as-default

log "isaac-ros-cli (release-4, noble-jetpack on Jetson)"
K=/usr/share/keyrings/nvidia-isaac-ros.gpg
[ -s "$K" ] || curl -fsSL https://isaac.download.nvidia.com/isaac-ros/repos.key | gpg --dearmor -o "$K"
echo "deb [signed-by=$K] https://isaac.download.nvidia.com/isaac-ros/release-4 noble-jetpack main" \
    > /etc/apt/sources.list.d/nvidia-isaac-ros.list
apt-get update -q
apt-get install -y -q isaac-ros-cli
isaac-ros init docker

log "groups: docker, dialout (ttyTHS1 serial bridge)"
usermod -aG docker,dialout "$U"
systemctl disable --now nvgetty.service 2>/dev/null || true  # absent on R39

log "USB autosuspend off (cameras drop out)"
X=/boot/extlinux/extlinux.conf
if ! grep -q 'usbcore.autosuspend=-1' "$X"; then
    cp "$X" "$X.bak.$(date +%F)"
    sed -i '/^[[:space:]]*APPEND /s/$/ usbcore.autosuspend=-1/' "$X"
fi
echo -1 > /sys/module/usbcore/parameters/autosuspend

log "clocks locked at boot (MAXN_SUPER is set last: it reboots)"
cat > /etc/systemd/system/jetson_clocks.service <<'EOF'
[Unit]
Description=Lock Jetson clocks at maximum frequency
After=nvpmodel.service multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/jetson_clocks --fan
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable jetson_clocks.service

log "jtop"
command -v jtop >/dev/null || pip3 install -q --break-system-packages -U jetson-stats

log "RealSense udev rules (image builds librealsense v2.56.3, RSUSB)"
curl -fsSL -o /etc/udev/rules.d/99-realsense-libusb.rules \
    https://raw.githubusercontent.com/realsenseai/librealsense/v2.56.3/config/99-realsense-libusb.rules

log "RPLIDAR udev rule: /dev/rplidar, mode 0666 (sllidar_ros2's host rule)"
RULE="$(dirname "$(readlink -f "$0")")/../../sllidar_ros2/scripts/rplidar.rules"
if [ -f "$RULE" ]; then
    install -m 644 "$RULE" /etc/udev/rules.d/rplidar.rules
else
    echo "warning: $RULE not found; clone the workspace and re-run" >&2
fi
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty --subsystem-match=usb --action=add

log "user: git-lfs, shell env"
sudo -u "$U" git lfs install --skip-repo
B="$H/.bashrc"
grep -q 'ISAAC_ROS_WS=' "$B" || echo 'export ISAAC_ROS_WS="${ISAAC_ROS_WS:-${HOME}/workspaces/isaac_ros-dev/}"' >> "$B"
grep -q 'ROS_DOMAIN_ID=' "$B" || echo 'export ROS_DOMAIN_ID=1' >> "$B"

log "tailscale"
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
tailscale status >/dev/null 2>&1 || echo "run: sudo tailscale up --ssh --hostname ts-$(hostname | sed 's/^ts-//')"

log "restarting docker"
systemctl restart docker

docker info 2>/dev/null | grep -E 'Default Runtime' || true

# nvpmodel drops the change unless you let it reboot (answering the prompt
# NO left 25W on 2026-09-30), so --force: it reboots now if the mode differs.
ID=$(sed -n 's/^< POWER_MODEL ID=\([0-9]*\) NAME=MAXN_SUPER >/\1/p' /etc/nvpmodel.conf)
log "done; power mode MAXN_SUPER (reboots if it isn't already)"
[ -n "$ID" ] && nvpmodel -m "$ID" --force
echo "reboot to apply groups, kernel args and the GPU fix"
