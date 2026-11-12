# EFI boot-variable references

Captured 2026-10-25 on the Jetson r39.2.1 DT platform, including each efivarfs
four-byte attribute header. These are boot metadata, without credentials.

- `Boot0001.reference`: firmware whole-NVMe entry; 88-byte device path and
  16 bytes of optional data outside it.
- `Boot000A.reference`: UEFI-shell `bcfg` launcher entry, proven to boot via
  BootManager (`BootCurrent=000A`). Its 180-byte path adds GPT HD and File nodes
  to the identical 84-byte hardware/NVMe prefix. Description: `Robot NVMe`.

Target: NSID 1, raw EUI64 `ace42e0026e1e350`; GPT partition 10,
start LBA 862760, size 131072 logical sectors (512 bytes), PARTUUID
`41f65e50-129b-4fe7-9a6d-6520379bdc4a`; `\EFI\BOOT\BOOTAA64.efi`.
See [boot handoff](../../../scripts/usb_installer/README.md#boot-handoff)
for the maintained implementation and hardware acceptance status.
