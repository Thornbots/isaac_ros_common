#!/bin/bash
# reinstall_from_usb.sh: on a running robot with the installer stick in,
# boot the stick once and reinstall, erasing the NVMe. No keyboard needed:
#   sudo ./reinstall_from_usb.sh --yes
# Adds a UEFI entry for the stick's EFI partition, keeps BootOrder as it was
# (NVMe first, so the board can't loop into the installer), sets BootNext to
# the stick and reboots. A board with no bootable NVMe boots the stick itself.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ "${1:-}" = --yes ] || { echo "this erases the NVMe on reboot; pass --yes" >&2; exit 1; }

efi=""
for p in $(lsblk -lnpo NAME,TRAN,FSTYPE | awk '$3=="vfat"{print $1}'); do
    disk="/dev/$(lsblk -no PKNAME "$p")"
    [ "$(lsblk -dno TRAN "$disk")" = usb ] || continue
    m=$(mktemp -d); mount -o ro "$p" "$m"
    [ -f "$m/efi/boot/bootaa64.efi" ] || [ -f "$m/EFI/BOOT/BOOTAA64.EFI" ] && efi=$p
    umount "$m"; rmdir "$m"
    [ -n "$efi" ] && break
done
[ -n "$efi" ] || { echo "no installer stick found (USB disk with an EFI partition)" >&2; exit 1; }
disk="/dev/$(lsblk -no PKNAME "$efi")"; part=$(cat "/sys/class/block/${efi#/dev/}/partition")
echo "installer: $efi ($(lsblk -dno MODEL,SIZE "$disk"))"

order=$(efibootmgr | sed -n 's/^BootOrder: //p')
efibootmgr -b 00FE -B >/dev/null 2>&1 || true
efibootmgr -b 00FE -c -d "$disk" -p "$part" -l '\efi\boot\bootaa64.efi' -L "Robot installer (USB)" >/dev/null
efibootmgr -o "$order" >/dev/null
efibootmgr -n 00FE >/dev/null
efibootmgr | grep -E '^Boot(Next|Order)'
echo "rebooting into the installer; the robot comes back up on its own when done"
systemctl reboot
