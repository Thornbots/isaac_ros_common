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

# efibootmgr -v may print a full device path or an abbreviated HD() path.
target_entries() {
    awk -v uuid="$uuid" '
        /^Boot[[:xdigit:]]{4}/ {
            line=tolower($0)
            if (index(line, ",gpt," tolower(uuid) ",") &&
                index(line, "file(\\efi\\boot\\bootaa64.efi)"))
                print toupper(substr($0, 5, 4))
        }' <<<"$1"
}
entries=$(efibootmgr -v)
target=$(target_entries "$entries" | head -n1)
if [ -z "$target" ]; then
    efibootmgr -c -d "/dev/$disk" -p "$part" -l '\EFI\BOOT\BOOTAA64.efi' -L "Robot NVMe"
    entries=$(efibootmgr -v)
    target=$(target_entries "$entries" | head -n1)
fi
[ -n "$target" ] || fail "no boot entry matches the installed ESP and L4T launcher"
[ "$target" != 00FE ] || fail "target uses the reserved installer boot number"

# Do not delete an unrelated entry if someone reused our reserved number.
if grep -qi '^Boot00FE' <<<"$entries"; then
    grep -qi '^Boot00FE[* ]*Robot installer (USB)[[:space:]]' <<<"$entries" ||
        fail "Boot00FE is not the temporary robot installer entry"
    efibootmgr -b 00FE -B
fi
if grep -qi '^BootNext: 00FE$' <<<"$entries"; then
    efibootmgr -N
fi
entries=$(efibootmgr -v)
order=$(sed -n 's/^BootOrder: //p' <<<"$entries")
new_order=$target
IFS=, read -r -a previous <<<"$order"
for entry in "${previous[@]}"; do
    [ "${entry^^}" = "$target" ] || new_order+=",$entry"
done
efibootmgr -b "$target" -a
efibootmgr -o "$new_order"
entries=$(efibootmgr -v)
order=$(sed -n 's/^BootOrder: //p' <<<"$entries")
[ "${order%%,*}" = "$target" ] || fail "BootOrder update failed"
! grep -qi '^Boot00FE' <<<"$entries" || fail "temporary installer entry remains"
