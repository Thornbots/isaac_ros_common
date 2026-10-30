#!/usr/bin/env python3
"""Validate/create one full NVMe EFI load option; never change boot policy."""

import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import uuid


GLOBAL = '8be4df61-93ca-11d2-aa0d-00e098032b8c'
END = b'\x7f\xff\x04\x00'
LOADER = '\\EFI\\BOOT\\BOOTAA64.efi'
VARIABLE_ATTRS = 7  # Nonvolatile, boot-service and runtime access, separate from load attrs.


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def utf16z(data):
    require(len(data) >= 2 and len(data) % 2 == 0 and data[-2:] == b'\0\0',
            'unterminated UTF-16 string')
    text = data[:-2].decode('utf-16-le', errors='strict')
    require('\0' not in text, 'embedded UTF-16 terminator')
    return text


def parse_variable(raw):
    require(12 <= len(raw) <= 65536, 'invalid variable size')
    attrs, load_attrs, path_len = struct.unpack_from('<IIH', raw)
    require(attrs == VARIABLE_ATTRS, 'unsupported EFI variable attributes')
    require(load_attrs & ~0xB == 0, 'unsupported load-option attributes/category')
    offset = 10
    while offset + 2 <= len(raw) and raw[offset:offset + 2] != b'\0\0':
        offset += 2
    description = utf16z(raw[10:offset + 2])
    offset += 2
    require(bool(description), 'empty load-option description')
    require(path_len >= 4 and offset + path_len <= len(raw), 'invalid device-path length')
    path = raw[offset:offset + path_len]
    nodes = []
    cursor = 0
    while cursor < len(path):
        require(len(nodes) < 256, 'too many device-path nodes')
        require(cursor + 4 <= len(path), 'truncated device-path header')
        kind, subtype, size = struct.unpack_from('<BBH', path, cursor)
        require(size >= 4 and cursor + size <= len(path), 'invalid device-path node length')
        node = path[cursor:cursor + size]
        if kind == 0x7F:
            require(node == END and cursor + size == len(path), 'invalid/multiple path end')
        nodes.append((kind, subtype, node))
        cursor += size
    require(nodes[-1][2] == END, 'missing path end')
    return load_attrs, description, nodes, raw[offset + path_len:]


def nvme_prefix(nodes):
    # Limit inherited nodes to the hardware/ACPI forms used by firmware, through NVMe.
    allowed = {(1, 1): 6, (1, 3): 24, (1, 4): None, (2, 1): 12}
    prefix = []
    for kind, subtype, node in nodes:
        if (kind, subtype) == (3, 0x17):
            require(len(node) == 16, 'invalid NVMe node')
            require(any(n[:2] == (1, 1) for n in nodes[:len(prefix)]), 'missing PCI prefix')
            require(prefix and nodes[0][:2] in ((1, 3), (1, 4), (2, 1)),
                    'missing hardware/ACPI root')
            return b''.join(prefix) + node, struct.unpack_from('<I', node, 4)[0], node[8:]
        require((kind, subtype) in allowed, 'unsupported firmware prefix node')
        expected = allowed[(kind, subtype)]
        require(len(node) == expected if expected else len(node) >= 20,
                'invalid firmware prefix node size')
        prefix.append(node)
    raise ValueError('missing NVMe node')


def namespace_identity(disk, sysfs):
    nsid = int((sysfs / disk / 'nsid').read_text().strip())
    data = json.loads(command('nvme', 'id-ns', '/dev/' + disk, '-o', 'json'))
    require(isinstance(data, dict), 'namespace JSON is not an object')
    eui = data.get('eui64', '')
    require(isinstance(eui, str) and re.fullmatch('[0-9a-fA-F]{16}', eui),
            'missing/invalid namespace EUI64')
    eui = bytes.fromhex(eui)
    require(0 < nsid < 0xFFFFFFFF and any(eui), 'zero/invalid NVMe identity')
    return nsid, eui


def target_suffix(disk, esp, sysfs):
    require(re.fullmatch(r'nvme\d+n\d+', disk) is not None, 'invalid NVMe disk name')
    require(re.fullmatch(re.escape(disk) + r'p\d+', esp) is not None,
            'ESP does not belong to target disk')
    require(command('blkid', '-s', 'PTTYPE', '-o', 'value', '/dev/' + disk) == 'gpt',
            'target disk is not GPT')
    guid = uuid.UUID(command('blkid', '-s', 'PARTUUID', '-o', 'value', '/dev/' + esp))
    require(guid.int != 0, 'zero GPT partition UUID')
    part = int((sysfs / esp / 'partition').read_text())
    start = int((sysfs / esp / 'start').read_text()) * 512
    size = int((sysfs / esp / 'size').read_text()) * 512
    sector = int((sysfs / disk / 'queue/logical_block_size').read_text())
    capacity = int((sysfs / disk / 'size').read_text()) * 512
    require(sector >= 512 and sector & (sector - 1) == 0, 'invalid logical sector size')
    require(0 < part <= 0xFFFFFFFF and start > 0 and size > 0
            and start % sector == size % sector == 0 and start + size <= capacity,
            'invalid GPT partition geometry')
    hd = struct.pack('<BBHIQQ16sBB', 4, 1, 42, part, start // sector, size // sector,
                     guid.bytes_le, 2, 2)
    filename = (LOADER + '\0').encode('utf-16-le')
    return hd + struct.pack('<BBH', 4, 4, len(filename) + 4) + filename + END


def select_path(variables, identity, suffix):
    prefixes = set()
    whole_prefixes = set()
    reusable = []
    for number, raw in variables.items():
        try:
            attrs, _, nodes, optional = parse_variable(raw)
            prefix, nsid, eui = nvme_prefix(nodes)
        except (ValueError, UnicodeError, struct.error):
            continue  # Unrelated/malformed options are never copied or overwritten.
        if (nsid, eui) != identity:
            continue
        path = b''.join(n[2] for n in nodes)
        if path == prefix + END:
            prefixes.add(prefix)
            whole_prefixes.add(prefix)
        elif path == prefix + suffix and not optional and attrs == 1 and number != '00FE':
            reusable.append((number, prefix))
            prefixes.add(prefix)
        else:
            # A different route to the same namespace is still ambiguous.
            prefixes.add(prefix)
    require(len(prefixes) == 1, 'missing or ambiguous firmware NVMe prefix')
    prefix = next(iter(prefixes))
    require(prefix in whole_prefixes, 'no validated whole-NVMe firmware entry')
    require(len(reusable) <= 1, 'ambiguous existing full target entries')
    return prefix + suffix, reusable[0][0] if reusable else None


def load_option(path):
    raw = struct.pack('<IIH', VARIABLE_ATTRS, 1, len(path))
    raw += ('Robot NVMe\0').encode('utf-16-le') + path
    parse_variable(raw)
    return raw


def read_variables(directory):
    result = {}
    for entry in directory.iterdir():
        match = re.fullmatch(r'Boot([0-9A-Fa-f]{4})-' + GLOBAL, entry.name)
        if match:
            number = match[1].upper()
            require(number not in result, 'duplicate boot variable number')
            require(len(result) < 4096, 'too many boot variables')
            with entry.open('rb') as stream:
                result[number] = stream.read(65537)
            require(len(result[number]) <= 65536, 'oversized boot variable')
    return result


def write_entry(directory, number, raw):
    require(re.fullmatch('[0-9A-F]{4}', number) is not None and number != '00FE',
            'invalid/reserved boot number')
    parse_variable(raw)
    destination = directory / f'Boot{number}-{GLOBAL}'
    # O_EXCL reserves an unused name; never truncate an existing firmware variable.
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        # efivar --write reopens by name and cannot enforce exclusive creation.
        # Keep the original descriptor so no unrelated variable can be overwritten.
        require(os.write(fd, raw) == len(raw), 'short efivarfs write')
    finally:
        os.close(fd)
    require(destination.read_bytes() == raw, 'EFI variable readback mismatch')
    parse_variable(destination.read_bytes())


def ensure_entry(directory, sysfs, disk, esp, verify=None, lookup=False):
    identity = namespace_identity(disk, sysfs)
    disks = sorted(p.name for p in sysfs.iterdir() if re.fullmatch(r'nvme\d+n\d+', p.name))
    require(disk in disks, 'target namespace is absent')
    for other in disks:
        if other != disk:
            require(namespace_identity(other, sysfs)[1] != identity[1],
                    'ambiguous NVMe identity across disks')
    suffix = target_suffix(disk, esp, sysfs)
    variables = read_variables(directory)
    path, existing = select_path(variables, identity, suffix)
    if verify:
        require(existing == verify.upper(), 'target entry failed binary verification')
        return existing
    if existing or lookup:
        return existing
    number = next((f'{n:04X}' for n in range(0x10000)
                   if f'{n:04X}' not in variables and n != 0xFE), None)
    require(number is not None, 'no unused Boot number')
    raw = load_option(path)
    write_entry(directory, number, raw)
    require(select_path(read_variables(directory), identity, suffix)[1] == number,
            'created boot entry is not uniquely readable')
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--disk', required=True, help='NVMe block name, e.g. nvme0n1')
    parser.add_argument('--esp', required=True, help='ESP block name, e.g. nvme0n1p10')
    parser.add_argument('--lookup', action='store_true', help='find a verified entry; never write')
    parser.add_argument('--verify', help='only verify this Boot number; never write')
    args = parser.parse_args()
    try:
        print(ensure_entry(Path('/sys/firmware/efi/efivars'), Path('/sys/class/block'),
                           args.disk, args.esp, args.verify, args.lookup) or '')
    except (OSError, ValueError, struct.error, subprocess.SubprocessError) as error:
        print(f'nvme-boot-entry: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
