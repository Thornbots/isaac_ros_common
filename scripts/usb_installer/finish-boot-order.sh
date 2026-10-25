#!/bin/bash
# Runs in the installed target after NVIDIA's set-hd-boot-1st late commands.
# Match the mounted target ESP, never the first HD() entry (which can be USB).
set -euo pipefail
fail() { echo "finish-boot-order: $*" >&2; exit 1; }

vars=/sys/firmware/efi/efivars
[ -d "$vars" ] || fail "UEFI runtime variables are unavailable"
if ! mountpoint -q "$vars"; then
    mount -t efivarfs -o rw,nosuid,nodev,noexec efivarfs "$vars"
fi
[ "$(findmnt -nro FSTYPE --target "$vars")" = efivarfs ] || fail "not an efivarfs mount"
if [[ ,$(findmnt -nro OPTIONS --target "$vars"), == *,ro,* ]]; then
    mount -o remount,rw "$vars"
fi

mountpoint -q /boot/efi || fail "target ESP is not mounted at /boot/efi"
esp=$(readlink -f "$(findmnt -nro SOURCE --target /boot/efi)")
root=$(readlink -f "$(findmnt -nro SOURCE --target /)")
disk=$(lsblk -dnro PKNAME "$esp")
[[ $disk =~ ^nvme[0-9]+n[0-9]+$ ]] || fail "target ESP is not on NVMe: $esp"
[ "$(lsblk -dnro PKNAME "$root")" = "$disk" ] || fail "root and ESP are on different disks"
part=$(cat "/sys/class/block/${esp##*/}/partition")
uuid=$(blkid -s PARTUUID -o value "$esp")
[ -n "$part" ] && [ -n "$uuid" ] || fail "target ESP has no partition number/UUID"
[ -f /boot/efi/EFI/BOOT/BOOTAA64.efi ] || fail "target L4T launcher is missing"

helper=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/nvme_boot_entry.py
# Reuse only a binary-verified target before trying either creation method.
target=$(python3 "$helper" --disk "$disk" --esp "${esp##*/}" --lookup) ||
    fail "target firmware NVMe prefix could not be validated"
if [ -z "$target" ]; then
    if ! efibootmgr -C --full-dev-path -d "/dev/$disk" -p "$part" -l '\EFI\BOOT\BOOTAA64.efi' -L "Robot NVMe"; then
        echo "finish-boot-order: full-dev-path unavailable; validating firmware NVMe prefix" >&2
    fi
fi
# Binary validation also covers entries returned successfully by efibootmgr.
target=$(python3 "$helper" --disk "$disk" --esp "${esp##*/}") ||
    fail "no full PCI/NVMe boot entry could be validated"
[[ $target =~ ^[[:xdigit:]]{4}$ ]] || fail "invalid target boot number"
entries=$(efibootmgr -v)
[ "$target" != 00FE ] || fail "target uses the reserved installer boot number"

# Do not delete an unrelated entry if someone reused our reserved number.
if grep -qi '^Boot00FE' <<<"$entries"; then
    grep -qi '^Boot00FE[* ]*Robot installer (USB)[[:space:]]' <<<"$entries" ||
        fail "Boot00FE is not the temporary robot installer entry"
fi
entries=$(efibootmgr -v)
order=$(sed -n 's/^BootOrder: //p' <<<"$entries")
new_order=$target
IFS=, read -r -a previous <<<"$order"
for entry in "${previous[@]}"; do
    [ "${entry^^}" = "$target" ] || [ "${entry^^}" = 00FE ] || new_order+=",$entry"
done
efibootmgr -b "$target" -a
python3 "$helper" --disk "$disk" --esp "${esp##*/}" --verify "$target" >/dev/null ||
    fail "target failed activation readback"
efibootmgr -o "$new_order"
entries=$(efibootmgr -v)
order=$(sed -n 's/^BootOrder: //p' <<<"$entries")
[ "${order^^}" = "${new_order^^}" ] || fail "BootOrder update failed"
python3 "$helper" --disk "$disk" --esp "${esp##*/}" --verify "$target" >/dev/null ||
    fail "target failed final binary verification"
if grep -qi '^BootNext: 00FE$' <<<"$entries"; then
    efibootmgr -N
fi
if grep -qi '^Boot00FE' <<<"$entries"; then
    efibootmgr -b 00FE -B
fi
entries=$(efibootmgr -v)
order=$(sed -n 's/^BootOrder: //p' <<<"$entries")
[ "${order^^}" = "${new_order^^}" ] || fail "BootOrder changed during USB cleanup"
! grep -qi '^BootNext: 00FE$' <<<"$entries" || fail "temporary USB BootNext remains"
! grep -qi '^Boot00FE' <<<"$entries" || fail "temporary installer entry remains"
python3 "$helper" --disk "$disk" --esp "${esp##*/}" --verify "$target" >/dev/null ||
    fail "target failed final binary verification"
