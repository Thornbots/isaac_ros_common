# Robot USB installer

`make_installer_usb.sh` customizes the JetPack 7.2.1 / r39.2.1 installer:
GRUB selects **Install on NVMe**, skips interactive OEM configuration, and
runs `oem-iso-cfg.sh` in the installed target. See the script header for
arguments and configuration. The output ISO contains the password hash,
SSH public key and optional Tailscale secret; protect the ISO and stick.

The OEM hook creates the robot user, validates a final
`zz-robot-nopasswd` sudoers rule, and enables `robot-firstboot.service` for
network-dependent workspace setup. Passwordless sudo is intentional for
unattended provisioning. Both hooks retain strict error handling but disable
command tracing so `robot.env` credentials stay out of installer and first-boot
journals.

## Boot handoff

`reinstall_from_usb.sh --yes` preserves BootOrder and uses BootNext with the
reserved `Boot00FE` entry labelled `Robot installer (USB)`. This only selects
the next boot: NVIDIA's `set-hd-boot-1st` late commands (command_65/66 in the
r39.2.1 installer) can subsequently promote the USB entry because it also
has an `HD()` device path.

The OEM hook runs afterward and calls `finish-boot-order.sh`. It identifies
the mounted `/boot/efi` ESP, requires it to share the installed root's NVMe,
and requires a full hardware/PCI/NVMe device path followed by that ESP's
partition number, GPT UUID and `EFI/BOOT/BOOTAA64.efi`. If missing, it creates
that exact partition entry with `efibootmgr --create-only --full-dev-path`,
leaving BootOrder untouched until readback succeeds. On the r39.2.1
DT platform this can fail with `EINVAL`; `nvme_boot_entry.py` provides a bounded
fallback using the firmware's existing whole-NVMe path. It validates the
binary EFI load option, matches sysfs NSID and nonzero `nvme id-ns -o json`
EUI64, and preserves the complete hardware prefix through the NVMe node.
EUI bytes match nvme-cli JSON directly; EDK2's displayed order is reversed.
Distinct matching prefixes, duplicate full targets or duplicate disk EUIs
cause failure. The helper requires a validated whole-device entry even when
reusing an existing full entry.

The helper builds a GPT HD node from the mounted ESP's partition number,
PARTUUID and sysfs geometry, converting 512-byte sysfs units to logical LBAs,
then appends the UTF-16 launcher File node and End Entire node. Firmware
optional data is never copied. EFI variable attributes (`7`) and load-option
attributes (`1`, active) are validated separately. It reserves an unused
`Boot####` exclusively, excludes `00FE`, and writes the attributes and load
option together through that same efivarfs descriptor. Standard `efivar --write`
is unsuitable here: it reopens by name and can overwrite a variable created by
another writer after the initial check. The raw fallback preserves
exclusive creation even when that CLI is installed.
This raw writer is limited to creating a new boot option; it never edits an
unrelated entry or BootOrder. Exact binary readback is required before policy
changes. An existing abbreviated `HD()/File()` entry is preserved but never
selected. Binary validation also applies to entries created by efibootmgr.
The hook rechecks the target after activation and BootOrder, before deleting
USB, and again after cleanup; it verifies the complete intended order.
It removes the reserved USB entry, clears a remaining USB BootNext, activates
the target and puts it first while preserving other entries' relative order.
An unrelated `Boot00FE` causes an error rather than deletion. Existing bare
whole-device entries (including the recovery entry) are preserved.

Full-path creation bypasses abbreviated-HD expansion as a compatibility
workaround for the observed post-capsule r39.2.1 failure. NVIDIA's
[boot manager supports abbreviated HD paths](https://github.com/NVIDIA/edk2/blob/5acf429321649bc191baf19de19670216a75cfb0/MdeModulePkg/Library/UefiBootManagerLib/BmBoot.c#L1002-L1013).
[L4TLauncher discovers rootfs through parent/child handles and GPT partition names](https://github.com/NVIDIA/edk2-nvidia/blob/7e9f9ec4de8d979807683a7b4605a15ec3299b89/Silicon/NVIDIA/Application/L4TLauncher/L4TLauncher.c#L353-L428),
not a required raw boot-entry prefix. Its
[partition-info error precedes opening extlinux.conf](https://github.com/NVIDIA/edk2-nvidia/blob/7e9f9ec4de8d979807683a7b4605a15ec3299b89/Silicon/NVIDIA/Application/L4TLauncher/L4TLauncher.c#L1301-L1313).
On 2026-10-25, a UEFI-shell `bcfg` full entry booted successfully through
BootManager (`BootCurrent=000A`) with firmware 39.2.1, normal slots, root
`PARTLABEL=APP`, and working SSH/sudo. The captured full and whole-device
variables in [test fixtures](../../tests/fixtures/efi/README.md) have identical
84-byte prefixes; tests reproduce the full load option exactly. The Python
writer still needs a separate-entry/BootNext/reboot hardware check;
these fixtures do not establish its firmware persistence.

The ISO initramfs mounts `efivarfs` read-write; curtin normally exposes `/sys`
in the target. The hook checks the target mount, mounts/remounts `efivarfs`
when needed, and fails the installer on unavailable EFI variables, ambiguous
disk layout or missing L4T launcher. It must finish before reboot; a first-boot
service cannot fix a loop that prevents the target from booting. Other disk
layouts, encrypted roots and other installer versions need explicit review.

Host regression tests use fake firmware and block-device commands; they do
not validate firmware persistence, curtin runtime mounts, or a physical installation:

```sh
python3 -m unittest discover -s tests -p test_usb_installer.py -v
python3 -m unittest discover -s tests -p test_nvme_boot_entry.py -v
```
