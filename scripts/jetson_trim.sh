#!/bin/bash
# jetson_trim.sh: make a robot Orin headless, like NVIDIA's minimal rootfs
# flavor, after jetson_setup.sh. Boots to multi-user.target, shortens the UEFI
# (5 s) and L4TLauncher (3 s) menu waits, boots the kernel `quiet`, disables
# timers and services a robot doesn't use, purges the desktop
# (jetson_headless_purge.txt) and snapd, and stops dpkg installing docs.
# Keeps ssh, tailscale, docker, NetworkManager, Wi-Fi firmware and USB device
# mode (l4tbr0).
#   sudo ./jetson_trim.sh [--dry-run]   # reboot afterwards; --dry-run lists the purge only
# Undo the desktop: sudo systemctl set-default graphical.target
# see JAZZY_FLASH.md for design rationale
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
log() { printf '\n== %s\n' "$*"; }
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1

if [ "$DRY" = 0 ]; then

log "boot to multi-user.target"
systemctl set-default multi-user.target

log "boot menu waits: UEFI 1 s (ESC still enters setup), L4TLauncher 0.1 s"
efibootmgr -t 1 >/dev/null
sed -i 's/^TIMEOUT .*/TIMEOUT 1/' /boot/extlinux/extlinux.conf

# The kernel writes its log to the 115200-baud serial console as it boots;
# quiet cut kernel start to /init from 4.7 s to 2.3 s on the sentry.
log "kernel cmdline: quiet"
if ! grep -qE '^[[:space:]]*APPEND .* quiet( |$)' /boot/extlinux/extlinux.conf; then
    sed -i '/^[[:space:]]*APPEND /s/$/ quiet/' /boot/extlinux/extlinux.conf
fi

log "timers: no background apt, firmware, motd or crash-report runs"
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer man-db.timer \
    motd-news.timer fwupd-refresh.timer ua-timer.timer apport-autoreport.timer \
    update-notifier-download.timer update-notifier-motd.timer 2>/dev/null || true
systemctl disable --now unattended-upgrades.service 2>/dev/null || true

log "services a headless robot doesn't use"
# nvargus: CSI cameras (ours is USB). nvweston: display compositor.
# nvmf*/nvmefc: NVMe over fabrics. ubiquity, nv-oobe: first-boot installers.
for u in ModemManager bluetooth avahi-daemon.socket avahi-daemon cups cups-browsed \
    openvpn sssd kerneloops auditd gnome-remote-desktop power-profiles-daemon \
    switcheroo-control udisks2 accounts-daemon nvargus-daemon nvweston \
    nvmefc-boot-connections nvmf-autoconnect secureboot-db ubiquity nv-oobe \
    ua-reboot-cmds ubuntu-advantage grub-common grub-initrd-fallback \
    cloud-init-local cloud-init cloud-config cloud-final cloud-init-hotplugd.socket; do
    systemctl disable --now "$u" 2>/dev/null || true
done

fi

log "desktop packages (NVIDIA's desktop-minus-minimal list) and snapd"
# Purged: listed packages that nothing kept depends on. KEEP overrides the
# list: Wi-Fi, the l4tbr0 USB link, jetson_setup.sh's tools, and vim and fdisk
# for fixing a robot by hand. PROTECT aborts if anything critical would go.
KEEP='linux-firmware|wireless-regdb|dnsmasq|dnsmasq-base|git|jq|linux-base|x11-common|vim|fdisk'
PROTECT='nvidia-.*|docker.*|containerd.*|tailscale|openssh-server|network-manager|isc-dhcp-server|dnsmasq.*|linux-firmware|linux-base|wpasupplicant|efibootmgr|git|jq|curl|zstd|cuda.*|libnv.*|tensorrt.*'
deps() {  # installed packages the given ones need, recursively
    apt-cache depends --recurse --installed --no-recommends --no-suggests --no-conflicts \
        --no-breaks --no-replaces --no-enhances "$@" 2>/dev/null |
        awk '{print $NF}' | sed 's/:arm64$//; s/^<//; s/>$//' | sort -u  # incl. virtual providers
}
inst=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' | awk '$1=="ii" {sub(/:arm64$/, "", $2); print $2}' | sort -u)
list=$( (grep -v '^#' "$(dirname "$(readlink -f "$0")")/jetson_headless_purge.txt"; echo snapd) |
        grep -vxE "$KEEP" | sort -u)
pkgs=$(comm -12 <(echo "$inst") <(echo "$list"))
pkgs=$(comm -23 <(echo "$pkgs") <(deps $(comm -23 <(echo "$inst") <(echo "$pkgs"))))
# The BSP metapackage goes with its GUI tools; its parts stay, marked manual
# below so autoremove can't take them. Any other cascade is refused.
CASCADE_OK='nvidia-l4t-bsp|nvidia-l4t-nvpmodel-gui-tools|nvidia-l4t-jetsonpower-gui-tools|gir1.2-appindicator3-0.1'
# shellcheck disable=SC2086
gone=$(apt-get -s purge $pkgs | awk '/^Purg/ {print $2}' | sort -u)
extra=$(comm -23 <(echo "$gone") <(echo "$pkgs") | grep -vxE "$CASCADE_OK" || true)
[ -z "$extra" ] || { echo "refusing: the purge cascades to $(echo $extra)" >&2; exit 1; }
if bad=$(grep -vxE "$CASCADE_OK" <<< "$gone" | grep -xE "$PROTECT"); then
    echo "refusing: the purge would remove $(echo $bad)" >&2; exit 1
fi
echo "purging $(wc -l <<< "$gone") packages"
[ "$DRY" = 1 ] && { echo $gone; exit 0; }
for s in $(snap list 2>/dev/null | awk 'NR>1 && $1 !~ /^(core|bare|snapd)/ {print $1}'); do
    snap remove --purge "$s" || true
done
# Kept packages manual, so autoremove leaves them (linux-base is auto here).
apt-mark manual $(echo "$inst" | grep -xE "nvidia-.*|${KEEP}") >/dev/null
# shellcheck disable=SC2086
apt-get purge -y -q $pkgs
if bad=$(apt-get -s autoremove --purge | awk '/^Purg/ {print $2}' | grep -xE "$PROTECT"); then
    echo "skipping autoremove: it would remove $(echo $bad)" >&2
else
    apt-get autoremove -y -q --purge
fi
rm -rf /snap /var/snap /var/lib/snapd

log "dpkg: no man pages, docs or translations from now on (Ubuntu minimal's rules)"
cat > /etc/dpkg/dpkg.cfg.d/excludes <<'EOF'
path-exclude=/usr/share/man/*
path-exclude=/usr/share/locale/*/LC_MESSAGES/*.mo
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/info/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/groff/*
EOF
find /usr/share/doc -mindepth 1 ! -name copyright ! -type d -delete 2>/dev/null || true
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/lintian/* /usr/share/groff/*
find /usr/share/locale -name '*.mo' -delete

log "done; reboot, then: systemd-analyze && systemd-analyze critical-chain"
