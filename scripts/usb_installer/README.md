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
that exact partition entry with `efibootmgr --full-dev-path`. An existing
abbreviated `HD()/File()` entry is preserved but never selected. The hook
checks the full path again after writing BootOrder.
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
Hardware acceptance must confirm the actual on-disk launcher build, rootfs GPT
`PARTLABEL` (`APP` or its slot variants), and successful extlinux loading with
the full entry. A capsule upgrade alone does not identify the on-disk launcher.

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
```
