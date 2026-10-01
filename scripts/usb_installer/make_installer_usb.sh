#!/bin/bash
# make_installer_usb.sh: a keyboard-free JetPack 7.2.1 installer for one robot.
#   ./make_installer_usb.sh --robot hero --iso <jetsoninstaller-r39.2.1-...iso> \
#       --out hero.iso [--dev /dev/sdX]
# Rebuilds NVIDIA's ISO with GRUB going straight to "Install on NVMe" plus
# nooemconfig oem-iso-cfg set-hd-boot-1st, and an /oemdata the installer runs
# in the new system (oem-iso-cfg.sh). Env: ROBOT_PASSWORD (default: the
# first line of ~/.config/thornbots/robot-password, shared by all robots),
# TS_AUTHKEY (default ~/.config/thornbots/tailscale-authkey: an auth key or
# an OAuth client secret for tag:jetsons; without one, join by hand),
# SSH_PUBKEY (default ~/.ssh/id_ed25519.pub), WIFI_SSID (default RHIT-OPEN),
# XORRISO (default xorriso). --dev writes and verifies the stick.
# see README.md for design rationale
set -euo pipefail
ROBOT="" ISO="" OUT="" DEV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --robot) ROBOT="$2"; shift 2 ;;
        --iso) ISO="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --dev) DEV="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done
[ -n "$ROBOT" ] && [ -f "$ISO" ] && [ -n "$OUT" ] || { sed -n 2,4p "$0" >&2; exit 1; }
TSFILE="$HOME/.config/thornbots/tailscale-authkey"
[ -n "${TS_AUTHKEY:-}" ] || { [ -f "$TSFILE" ] && TS_AUTHKEY=$(head -n1 "$TSFILE"); }
[ -n "${TS_AUTHKEY:-}" ] || echo "warning: no tailscale key; the robot won't join the tailnet on its own" >&2
PWFILE="$HOME/.config/thornbots/robot-password"
[ -n "${ROBOT_PASSWORD:-}" ] || { [ -f "$PWFILE" ] && ROBOT_PASSWORD=$(head -n1 "$PWFILE"); }
: "${ROBOT_PASSWORD:?set ROBOT_PASSWORD or write it to ~/.config/thornbots/robot-password}"
XORRISO="${XORRISO:-xorriso}"
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
HERE="$(dirname "$(readlink -f "$0")")"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# ── GRUB: default into the NVMe entry, no menu wait, our flags on it
"$XORRISO" -osirrox on -indev "$ISO" -extract /boot/grub/grub.cfg "$W/grub.cfg" 2>/dev/null
chmod u+w "$W/grub.cfg"
grep -q 'menuentry "Install on NVMe"' "$W/grub.cfg" || { echo "no NVMe entry in $ISO" >&2; exit 1; }
sed -i -e 's/^set default=0$/set default="0>0"/' -e 's/^set timeout=-1$/set timeout=1/' \
    -e '/force-bootdisk=nvme0n1/s|autoinstall |autoinstall nooemconfig oem-iso-cfg set-hd-boot-1st |' \
    "$W/grub.cfg"
grep -q 'nooemconfig oem-iso-cfg' "$W/grub.cfg" && grep -q 'default="0>0"' "$W/grub.cfg"

# ── /oemdata: the in-target script, first-boot stage, and this robot's settings
mkdir -p "$W/oemdata"
cp "$HERE/oem-iso-cfg.sh" "$HERE/robot-firstboot.sh" "$HERE/robot-firstboot.service" "$W/oemdata/"
{
    echo "ROBOT=$ROBOT"
    echo "ROBOT_USER=nano-$ROBOT"
    echo "ROBOT_HOSTNAME=ts-nano-$ROBOT"
    printf 'PASSWORD_HASH=%q\n' "$(openssl passwd -6 "$ROBOT_PASSWORD")"
    printf 'SSH_PUBKEY=%q\n' "$(cat "$SSH_PUBKEY")"
    printf 'TS_AUTHKEY=%q\n' "${TS_AUTHKEY:-}"
    printf 'WIFI_SSID=%q\n' "${WIFI_SSID:-RHIT-OPEN}"
    echo "WS_REPO=https://github.com/Thornbots/thornbots_workspace.git"
} > "$W/oemdata/robot.env"

rm -f "$OUT"
"$XORRISO" -indev "$ISO" -outdev "$OUT" \
    -map "$W/grub.cfg" /boot/grub/grub.cfg -map "$W/oemdata" /oemdata \
    -boot_image any replay 2>&1 | grep -E "^xorriso : (UPDATE|FAILURE|SORRY)|Writing to" | tail -3
echo "wrote $OUT ($(du -h "$OUT" | cut -f1)) for ts-nano-$ROBOT"

if [ -n "$DEV" ]; then
    [ "$(lsblk -dno TRAN "$DEV")" = usb ] || { echo "$DEV is not a USB disk; refusing" >&2; exit 1; }
    lsblk -dpo NAME,SIZE,MODEL,TRAN "$DEV"
    read -r -p "Erase $DEV and write the installer? [y/N] " a; [ "$a" = y ] || exit 1
    for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do udisksctl unmount -b "$p" 2>/dev/null || true; done
    sudo dd if="$OUT" of="$DEV" bs=4M conv=fsync oflag=direct status=progress
    sudo cmp -n "$(stat -c%s "$OUT")" "$OUT" "$DEV" && echo "stick OK"
fi
