"""Binary firmware references and failure cases for bounded NVMe boot creation."""

import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / 'scripts/usb_installer/nvme_boot_entry.py'
SPEC = importlib.util.spec_from_file_location('nvme_boot_entry', SOURCE)
boot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(boot)
FIXTURES = Path(__file__).parent / 'fixtures/efi'
WHOLE = (FIXTURES / 'Boot0001.reference').read_bytes()
FULL = (FIXTURES / 'Boot000A.reference').read_bytes()
IDENTITY = (1, bytes.fromhex('ace42e0026e1e350'))
SUFFIX = b''.join(n[2] for n in boot.parse_variable(FULL)[2][-3:])


class BinaryBootTest(unittest.TestCase):
    def test_bcfg_reference_exact_bytes_and_optional_data_boundary(self):
        attrs, desc, nodes, optional = boot.parse_variable(WHOLE)
        self.assertEqual(attrs, 1)
        self.assertTrue(desc.startswith('UEFI SHGP31'))
        self.assertEqual(len(optional), 16)
        self.assertEqual(sum(len(n[2]) for n in nodes), 88)
        path, existing = boot.select_path({'0001': WHOLE}, IDENTITY, SUFFIX)
        self.assertIsNone(existing)
        self.assertEqual(boot.load_option(path), FULL)
        self.assertEqual(len(path), 180)
        self.assertEqual(boot.nvme_prefix(nodes)[1:], IDENTITY)

    def test_existing_full_option_is_reused_and_duplicate_is_rejected(self):
        self.assertEqual(boot.select_path({'0001': WHOLE, '000A': FULL},
                                         IDENTITY, SUFFIX)[1], '000A')
        with self.assertRaisesRegex(ValueError, 'ambiguous existing'):
            boot.select_path({'0001': WHOLE, '000A': FULL, '000B': FULL}, IDENTITY, SUFFIX)

    def test_distinct_routes_to_same_namespace_are_ambiguous(self):
        other = bytearray(WHOLE)
        other[146] = 1  # Change PCI node, preserving namespace identity.
        with self.assertRaisesRegex(ValueError, 'ambiguous firmware'):
            boot.select_path({'0001': WHOLE, '0002': bytes(other)}, IDENTITY, SUFFIX)

    def test_missing_whole_prefix_and_reversed_eui_are_rejected(self):
        for variables, identity in (({'000A': FULL}, IDENTITY),
                                    ({'0001': WHOLE}, (1, IDENTITY[1][::-1])),
                                    ({'0001': WHOLE}, (2, IDENTITY[1]))):
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                boot.select_path(variables, identity, SUFFIX)

    def test_malformed_binary_boundaries_and_attributes(self):
        cases = [b'', FULL[:9], FULL[:-1]]
        for offset, data in ((0, b'\x01\0\0\0'), (4, b'\x04\0\0\0'),
                             (8, b'\xff\xff'), (10, b'\x00\xd8'),
                             (34, b'\x00\x00'), (208, b'\x7f\x01\x04\0')):
            value = bytearray(FULL)
            value[offset:offset + len(data)] = data
            cases.append(bytes(value))
        for raw in cases:
            with self.subTest(raw=raw[:12]), self.assertRaises((ValueError, UnicodeError)):
                boot.parse_variable(raw)

    def test_exclusive_write_collision_short_write_and_readback(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            destination = directory / f'Boot0002-{boot.GLOBAL}'
            for number, raw in (('00FE', FULL), ('../../', FULL), ('0002', FULL[:9])):
                with self.subTest(number=number), self.assertRaises(ValueError):
                    boot.write_entry(directory, number, raw)
            self.assertFalse(list(directory.iterdir()))
            boot.write_entry(directory, '0002', FULL)
            self.assertEqual(destination.read_bytes(), FULL)
            with self.assertRaises(FileExistsError):
                boot.write_entry(directory, '0002', FULL)
            with patch.object(boot.os, 'write', return_value=1):
                with self.assertRaisesRegex(ValueError, 'short'):
                    boot.write_entry(directory, '0003', FULL)
            with patch.object(Path, 'read_bytes', return_value=FULL[:-1]):
                with self.assertRaisesRegex(ValueError, 'readback'):
                    boot.write_entry(directory, '0004', FULL)
            with patch.object(boot.os, 'write', side_effect=OSError('firmware EIO')):
                with self.assertRaisesRegex(OSError, 'EIO'):
                    boot.write_entry(directory, '0005', FULL)


class DiscoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sysfs = self.root / 'block'
        self.variables = self.root / 'vars'
        self.variables.mkdir()
        for name, value in {'nvme0n1/nsid': '1', 'nvme0n1/queue/logical_block_size': '512',
                            'nvme0n1/size': '10000000', 'nvme0n1p10/partition': '10',
                            'nvme0n1p10/start': '862760', 'nvme0n1p10/size': '131072'}.items():
            target = self.sysfs / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(value)
        (self.variables / f'Boot0001-{boot.GLOBAL}').write_bytes(WHOLE)
        self.command = patch.object(boot, 'command', side_effect=self.fake_command)
        self.command.start()
        self.addCleanup(self.command.stop)

    def fake_command(self, *args):
        if args[0] == 'nvme':
            return json.dumps({'eui64': IDENTITY[1].hex(),
                               'nguid': 'ace42e0026e1e3502ee4ac0000000001'})
        return 'gpt' if 'PTTYPE' in args else '41f65e50-129b-4fe7-9a6d-6520379bdc4a'

    def ensure(self, verify=None):
        return boot.ensure_entry(self.variables, self.sysfs, 'nvme0n1', 'nvme0n1p10', verify)

    def test_live_geometry_matches_reference_and_creation_does_not_set_boot_policy(self):
        self.assertEqual(boot.target_suffix('nvme0n1', 'nvme0n1p10', self.sysfs), SUFFIX)
        self.assertIsNone(boot.ensure_entry(self.variables, self.sysfs, 'nvme0n1',
                                           'nvme0n1p10', lookup=True))
        self.assertEqual(len(list(self.variables.iterdir())), 1)
        self.assertEqual(self.ensure(), '0000')
        self.assertEqual(self.ensure(), '0000')
        self.assertEqual(self.ensure('0000'), '0000')
        self.assertEqual(len(list(self.variables.iterdir())), 2)
        self.assertEqual((self.variables / f'Boot0000-{boot.GLOBAL}').read_bytes(), FULL)

    def test_four_kn_geometry_is_converted_to_logical_lbas(self):
        (self.sysfs / 'nvme0n1/queue/logical_block_size').write_text('4096')
        hd = boot.target_suffix('nvme0n1', 'nvme0n1p10', self.sysfs)[:42]
        self.assertEqual(struct.unpack_from('<QQ', hd, 8), (862760 // 8, 131072 // 8))

    def test_invalid_geometry_and_namespace_json_fail_without_writes(self):
        for data in ('[]', 'null', '{}', '{"eui64":"0000000000000000"}', '{"eui64":12}', 'no json'):
            with patch.object(boot, 'command', return_value=data), self.assertRaises(ValueError):
                self.ensure()
        (self.sysfs / 'nvme0n1p10/size').write_text('0')
        with self.assertRaisesRegex(ValueError, 'geometry'):
            self.ensure()
        self.assertEqual(len(list(self.variables.iterdir())), 1)

    def test_duplicate_disk_identity_and_verify_mismatch_fail_without_writes(self):
        with self.assertRaises(ValueError):
            self.ensure('000A')
        other = self.sysfs / 'nvme1n1'
        other.mkdir()
        (other / 'nsid').write_text('1')
        with self.assertRaisesRegex(ValueError, 'across disks'):
            self.ensure()
        self.assertEqual(len(list(self.variables.iterdir())), 1)


if __name__ == '__main__':
    unittest.main()
