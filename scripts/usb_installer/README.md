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
and matches its GPT partition UUID plus `EFI/BOOT/BOOTAA64.efi` in the
firmware entries. If missing, it creates the entry for that exact partition.
It removes the reserved USB entry, clears a remaining USB BootNext, activates
the target and puts it first while preserving other entries' relative order.
An unrelated `Boot00FE` causes an error rather than deletion.

The ISO initramfs mounts `efivarfs` read-write; curtin normally exposes `/sys`
in the target. The hook checks the target mount, mounts/remounts `efivarfs`
when needed, and fails the installer on unavailable EFI variables, ambiguous
disk layout or missing L4T launcher. It must finish before reboot; a first-boot
service cannot fix a loop that prevents the target from booting. Other disk
layouts, encrypted roots and other installer versions need explicit review.

Host regression tests use fake firmware and block-device commands; they do
not validate firmware persistence or a physical installation:

```sh
python3 -m unittest discover -s tests -p test_usb_installer.py -v
```
