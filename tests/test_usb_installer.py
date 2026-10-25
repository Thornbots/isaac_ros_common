"""Exercise the in-target boot handoff without firmware or block-device access."""

import json
import os
import shutil
import shlex
from pathlib import Path
import subprocess
import tempfile
import unittest


MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

state_path = Path(os.environ['BOOT_TEST_STATE'])
s = json.loads(state_path.read_text())
cmd = Path(sys.argv[0]).name
a = sys.argv[1:]
s['calls'].append([cmd, *a])
result = ''
code = 0
if cmd == 'mountpoint':
    code = int(a[-1].endswith('efivars') and not s['mounted'])
elif cmd == 'mount':
    s['mounted'] = True
    s['readonly'] = False
elif cmd == 'findmnt':
    if 'FSTYPE' in a:
        result = 'efivarfs'
    elif 'OPTIONS' in a:
        result = 'ro,nosuid' if s['readonly'] else 'rw,nosuid'
    else:
        result = '/dev/nvme0n1p10' if a[-1].endswith('esp') else '/dev/nvme0n1p1'
elif cmd == 'readlink':
    result = a[-1]
elif cmd == 'lsblk':
    result = s['disk']
elif cmd == 'blkid':
    result = '12345678-1234-1234-1234-123456789abc'
elif cmd == 'efibootmgr':
    if a == ['-v']:
        result = 'BootOrder: ' + ','.join(s['order']) + '\n'
        if s['next']:
            result += 'BootNext: ' + s['next'] + '\n'
        for number, path in s['entries'].items():
            result += 'Boot' + number + '* ' + path + '\n'
    elif '-c' in a:
        s['entries']['0007'] = (s['target'] if '--full-dev-path' in a
                                and not s['force_abbreviated'] else s['abbreviated'])
        s['order'].insert(0, '0007')
    elif '-B' in a:
        del s['entries'][a[1]]
        s['order'] = [n for n in s['order'] if n != a[1]]
    elif a == ['-N']:
        s['next'] = ''
    elif a[0] == '-o':
        s['order'] = a[1].split(',')
        if s['corrupt_final_path']:
            s['entries'][s['order'][0]] = s['abbreviated']
state_path.write_text(json.dumps(s))
if result:
    print(result)
sys.exit(code)
'''


class BootHandoffTest(unittest.TestCase):
    def run_hook(self, *, existing=True, mounted=True, readonly=False,
                 disk='nvme0n1', reserved='Robot installer (USB)', variables=True,
                 usb=True, bootnext='00FE', missing_loader=False,
                 existing_path=None, force_abbreviated=False, corrupt_final_path=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            esp = root / 'esp'
            loader = esp / 'EFI/BOOT/BOOTAA64.efi'
            loader.parent.mkdir(parents=True)
            if not missing_loader:
                loader.touch()
            partition = root / 'partition'
            partition.write_text('10\n')
            variables_path = root / 'efivars'
            if variables:
                variables_path.mkdir()
            abbreviated = ('Robot NVMe\tHD(10,GPT,12345678-1234-1234-1234-123456789ABC,'
                           '0x1000,0x2000)/File(\\EFI\\BOOT\\BOOTAA64.efi)')
            target = abbreviated.replace('\tHD(',
                                         '\tPciRoot(0x0)/Pci(0x1,0x0)/'
                                         'NVMe(0x1,00-11-22-33-44-55-66-77)/HD(')
            state = {
                'entries': {
                    '00FE': reserved + '\tHD(1,GPT,usb-guid,0x1,0x2)/File('
                    '\\EFI\\BOOT\\grubaa64.efi)',
                    '0001': 'UEFI NVMe\tPciRoot(0x0)/Pci(0x1,0x0)/'
                    'NVMe(0x1,00-11-22-33-44-55-66-77)',
                },
                'order': ['00FE', '0001'], 'next': bootnext, 'calls': [],
                'mounted': mounted, 'readonly': readonly, 'disk': disk,
                'target': target, 'abbreviated': abbreviated,
                'force_abbreviated': force_abbreviated,
                'corrupt_final_path': corrupt_final_path,
            }
            if existing:
                state['entries']['0003'] = (target if existing_path is None else
                                          existing_path.replace('{abbreviated}', abbreviated)
                                          .replace('{hd}', abbreviated.split('\t')[1]))
                state['order'].append('0003')
            if not usb:
                del state['entries']['00FE']
                state['order'].remove('00FE')
            state_path = root / 'state.json'
            state_path.write_text(json.dumps(state))
            mock = root / 'mock'
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for name in ('mountpoint', 'mount', 'findmnt', 'readlink', 'lsblk',
                         'blkid', 'efibootmgr'):
                (root / name).symlink_to(mock)
            source = Path(__file__).resolve().parents[1] / 'scripts/usb_installer'
            script = (source / 'finish-boot-order.sh').read_text()
            script = script.replace('/sys/firmware/efi/efivars', str(variables_path))
            script = script.replace('/boot/efi', str(esp))
            script = script.replace('/sys/class/block/${esp##*/}/partition', str(partition))
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       BOOT_TEST_STATE=str(state_path))
            result = subprocess.run(['bash', '-c', script], env=env,
                                    text=True, capture_output=True, check=False)
            return result, json.loads(state_path.read_text())

    def test_existing_target_wins_over_usb_and_other_nvme(self):
        result, state = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state['order'], ['0003', '0001'])
        self.assertNotIn('00FE', state['entries'])
        self.assertEqual(state['next'], '')
        self.assertNotIn('-c', [arg for call in state['calls'] for arg in call])

    def test_missing_entry_is_created_on_target_esp(self):
        result, state = self.run_hook(existing=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state['order'], ['0007', '0001'])
        self.assertIn(['efibootmgr', '-c', '--full-dev-path', '-d', '/dev/nvme0n1', '-p', '10',
                       '-l', '\\EFI\\BOOT\\BOOTAA64.efi', '-L', 'Robot NVMe'], state['calls'])

    def test_hardware_abbreviated_entry_is_replaced_and_never_promoted(self):
        result, state = self.run_hook(existing_path='{abbreviated}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state['order'], ['0007', '0001', '0003'])
        self.assertIn('0003', state['entries'])
        self.assertIn('--full-dev-path', [a for c in state['calls'] for a in c])

    def test_successful_write_of_abbreviated_path_is_rejected(self):
        result, state = self.run_hook(existing_path='{abbreviated}', force_abbreviated=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no full PCI/NVMe boot entry', result.stderr)
        self.assertIn('00FE', state['entries'])
        self.assertFalse(any(c[0] == 'efibootmgr' and c[1] in ('-o', '-a', '-B', '-N')
                             for c in state['calls'] if len(c) > 1))

    def test_incomplete_device_paths_are_rejected(self):
        for prefix in ('NVMe(0x1,0x0)/', 'PciRoot(0x0)/Pci(0x1,0x0)/'):
            with self.subTest(prefix=prefix):
                result, state = self.run_hook(existing_path='Robot NVMe\t' + prefix + '{hd}',
                                              force_abbreviated=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('00FE', state['entries'])

    def test_vendor_hardware_prefix_is_accepted(self):
        result, state = self.run_hook(existing_path=(
            'UEFI NVMe\tVenHw(12345678-1234-1234-1234-123456789abc)/'
            'PciRoot(0x0)/Pci(0x1,0x0)/NVMe(0x1,0x0)/{hd}'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state['order'][0], '0003')
        self.assertNotIn('-c', [a for c in state['calls'] for a in c])

    def test_full_path_to_other_partition_or_loader_is_rejected(self):
        path = 'Robot NVMe\tPciRoot(0x0)/Pci(0x1,0x0)/NVMe(0x1,0x0)/'
        for suffix in (
                'HD(1,GPT,12345678-1234-1234-1234-123456789abc,0x1,0x2)/'
                'File(\\EFI\\BOOT\\BOOTAA64.efi)',
                'HD(10,GPT,other-guid,0x1,0x2)/File(\\EFI\\BOOT\\BOOTAA64.efi)',
                'HD(10,GPT,12345678-1234-1234-1234-123456789abc,0x1,0x2)/'
                'File(\\EFI\\BOOT\\grubaa64.efi)'):
            with self.subTest(suffix=suffix):
                result, state = self.run_hook(existing_path=path + suffix,
                                              force_abbreviated=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('00FE', state['entries'])

    def test_final_verification_rechecks_device_path(self):
        result, _ = self.run_hook(corrupt_final_path=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('target lost its full PCI/NVMe device path', result.stderr)

    def test_efivarfs_is_mounted_or_remounted(self):
        for options in ({'mounted': False}, {'readonly': True}):
            with self.subTest(options=options):
                result, state = self.run_hook(**options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(any(c[0] == 'mount' for c in state['calls']))

    def test_direct_install_preserves_other_bootnext(self):
        result, state = self.run_hook(usb=False, bootnext='0001')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state['order'], ['0003', '0001'])
        self.assertEqual(state['next'], '0001')

    def test_unrelated_reserved_entry_is_preserved(self):
        result, state = self.run_hook(reserved='Another OS')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('00FE', state['entries'])
        self.assertEqual(state['order'][0], '00FE')

    def test_non_nvme_and_missing_variables_fail_before_firmware_writes(self):
        for options in ({'disk': 'sda'}, {'variables': False}, {'missing_loader': True}):
            with self.subTest(options=options):
                result, state = self.run_hook(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[0] == 'efibootmgr' for c in state['calls']))


class CredentialTracingTest(unittest.TestCase):
    def test_hooks_source_credentials_without_tracing_and_keep_strict_mode(self):
        source = Path(__file__).resolve().parents[1] / 'scripts/usb_installer'
        for name in ('oem-iso-cfg.sh', 'robot-firstboot.sh'):
            with self.subTest(hook=name), tempfile.TemporaryDirectory() as tmp:
                env_path = Path(tmp) / 'robot.env'
                secrets = ('test-password-hash-sentinel', 'test-authkey-sentinel')
                env_path.write_text(f'PASSWORD_HASH={secrets[0]}\nTS_AUTHKEY={secrets[1]}\n')
                script = (source / name).read_text()
                for line in script.splitlines():
                    if line.lstrip().startswith('set '):
                        words = shlex.split(line, comments=True)
                        self.assertFalse(any(
                            (word.startswith('-') and any(c in word for c in 'xv'))
                            or word in ('xtrace', 'verbose') for word in words[1:]), line)
                # Exercise the real startup through sourcing, before provisioning.
                startup, remainder = script.split('/robot.env"', 1)
                self.assertTrue(remainder.startswith('\n'))
                startup = startup.rsplit('source ', 1)[0]
                probe = startup + f'source "{env_path}"\n' + r'''
[[ $- != *x* && $- == *e* && $- == *u* ]]
[[ $(set -o | awk '$1 == "pipefail" {print $2}') == on ]]
: "$PASSWORD_HASH" "$TS_AUTHKEY"
'''
                result = subprocess.run(['bash', '-c', probe], text=True,
                                        capture_output=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                for secret in secrets:
                    self.assertNotIn(secret, result.stdout + result.stderr)


class InstallerPackagingTest(unittest.TestCase):
    def test_builder_includes_boot_handoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            iso = root / 'source.iso'
            iso.touch()
            key = root / 'pubkey'
            key.write_text('ssh-ed25519 test-public-key\n')
            xorriso = root / 'xorriso'
            xorriso.write_text(r'''#!/bin/bash
set -eu
if [ "$1" = -osirrox ]; then
    cat > "${@: -1}" <<'GRUB'
set default=0
set timeout=-1
menuentry "Install on NVMe" {
linux /casper/Image autoinstall force-bootdisk=nvme0n1
}
GRUB
else
    touch "$4"
    while [ "$1" != -map ] || [ "$3" != /oemdata ]; do shift; done
    test -f "$2/finish-boot-order.sh"
    grep -q 'finish-boot-order.sh' "$2/oem-iso-cfg.sh"
    echo 'xorriso : UPDATE : verified OEM boot hook'
fi
''')
            xorriso.chmod(0o755)
            builder = (Path(__file__).resolve().parents[1] /
                       'scripts/usb_installer/make_installer_usb.sh')
            env = dict(os.environ, HOME=str(root), ROBOT_PASSWORD='test-only',
                       TS_AUTHKEY='test-only', SSH_PUBKEY=str(key), XORRISO=str(xorriso))
            result = subprocess.run(['bash', str(builder), '--robot', 'test',
                                     '--iso', str(iso), '--out', str(root / 'out.iso')],
                                    env=env, text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('verified OEM boot hook', result.stdout)

    @unittest.skipUnless(shutil.which('visudo'), 'visudo is not installed')
    def test_oem_sudoers_rule_is_valid_and_passwordless(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = (Path(__file__).resolve().parents[1] /
                      'scripts/usb_installer/oem-iso-cfg.sh').read_text()
            block = source[source.index('sudoers='):source.index('H=/home/')]
            block = block.replace('/etc/sudoers.d/zz-robot-nopasswd', str(root / 'rule'))
            block = block.replace('/etc/sudoers', str(root / 'rule'))
            result = subprocess.run(['bash', '-euc', 'ROBOT_USER=nano-test\n' + block],
                                    text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / 'rule').read_text(),
                             'nano-test ALL=(ALL:ALL) NOPASSWD: ALL\n')
            self.assertEqual((root / 'rule').stat().st_mode & 0o777, 0o440)


if __name__ == '__main__':
    unittest.main()
