#!/usr/bin/env python3
"""Read-only PE inventory. Never loads or executes the inspected file.

Reference: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
An absent certificate table is unsigned. A present table is NOT a verified signature.
OS header versions do NOT prove the Windows 11 build 22000 product minimum.
"""
import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path


class PE:
    def __init__(self, path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        if self.data[:2] != b'MZ':
            raise ValueError('DOS signature MZ absent')
        self.pe = self.u32(0x3c)
        if self.block(self.pe, 4) != b'PE\0\0':
            raise ValueError('PE signature absent')
        self.machine, self.nsections = self.unpack('<HH', self.pe + 4)
        if not 1 <= self.nsections <= 96:
            raise ValueError('invalid section count')
        self.optional_size, self.characteristics = self.unpack('<HH', self.pe + 20)
        self.optional = self.pe + 24
        self.block(self.optional, self.optional_size)
        self.magic = self.u16(self.optional)
        if self.magic not in (0x10b, 0x20b):
            raise ValueError('invalid optional header magic')
        self.is64 = self.magic == 0x20b
        self.imagebase = self.unpack('<Q' if self.is64 else '<I', self.optional + (24 if self.is64 else 28))[0]
        self.headers = self.u32(self.optional + 60)
        self.subsystem = self.u16(self.optional + 68)
        count_offset, directory_offset = (108, 112) if self.is64 else (92, 96)
        count = min(self.u32(self.optional + count_offset), 16)
        if directory_offset + count * 8 > self.optional_size:
            raise ValueError('data directories exceed optional header')
        self.directories = [self.unpack('<II', self.optional + directory_offset + i * 8) for i in range(count)]
        self.sections = []
        for i in range(self.nsections):
            o = self.optional + self.optional_size + i * 40
            name = self.block(o, 8).split(b'\0')[0].decode('ascii', 'replace')
            size, rva, raw_size, raw_offset = self.unpack('<IIII', o + 8)
            self.block(raw_offset, raw_size)
            self.sections.append({'name': name, 'rva': rva, 'virtual_size': size, 'raw_size': raw_size, 'raw_offset': raw_offset})

    def block(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise ValueError(f'file range outside bounds: {offset}+{size}')
        return self.data[offset:offset + size]

    def unpack(self, fmt, offset):
        return struct.unpack(fmt, self.block(offset, struct.calcsize(fmt)))

    def u16(self, offset): return self.unpack('<H', offset)[0]
    def u32(self, offset): return self.unpack('<I', offset)[0]

    def rva(self, address, size=1):
        if address < self.headers and address + size <= self.headers:
            self.block(address, size)
            return address
        for s in self.sections:
            delta = address - s['rva']
            if 0 <= delta and delta + size <= s['raw_size']:
                offset = s['raw_offset'] + delta
                self.block(offset, size)
                return offset
        raise ValueError(f'RVA outside backed section: 0x{address:x}+{size}')

    def directory(self, index):
        return self.directories[index] if index < len(self.directories) else (0, 0)

    def string(self, address):
        offset = self.rva(address)
        end = self.data.find(b'\0', offset, min(offset + 65536, len(self.data)))
        if end < 0: raise ValueError('unterminated import string')
        return self.data[offset:end].decode('ascii', 'strict')

    def imports(self, delayed=False):
        address, size = self.directory(13 if delayed else 1)
        if not address: return []
        stride = 32 if delayed else 20
        result = []
        for i in range(min(4096, max(1, size // stride))):
            fields = self.unpack('<' + 'I' * (stride // 4), self.rva(address + i * stride, stride))
            if not any(fields): return result
            if delayed:
                attrs, name, _, iat, names, _, _, _ = fields
                names = names or iat
                if not attrs & 1:
                    name -= self.imagebase
                    names -= self.imagebase
            else:
                names, _, _, name, iat = fields
                names = names or iat
            width = 8 if self.is64 else 4
            symbols = []
            for j in range(65536):
                thunk = self.unpack('<Q' if self.is64 else '<I', self.rva(names + j * width, width))[0]
                if not thunk: break
                if thunk & (1 << (width * 8 - 1)):
                    symbols.append({'ordinal': thunk & 0xffff})
                else:
                    symbols.append(self.string(thunk + 2))
            else: raise ValueError('unterminated import thunk table')
            result.append({'dll': self.string(name), 'symbols': symbols})
        raise ValueError('unterminated import descriptor table')

    def resources(self):
        address, size = self.directory(2)
        if not address: return []
        result = []
        visited = set()
        def relative(offset, count):
            if offset < 0 or offset + count > size: raise ValueError('resource offset outside directory')
            return self.rva(address + offset, count)
        def walk(offset, path):
            if len(path) > 5 or offset in visited: raise ValueError('resource tree cycle/depth')
            visited.add(offset)
            o = relative(offset, 16)
            count = self.u16(o + 12) + self.u16(o + 14)
            if count > 4096: raise ValueError('excessive resource count')
            for i in range(count):
                name, child = self.unpack('<II', relative(offset + 16 + i * 8, 8))
                if name & 0x80000000:
                    text_offset = name & 0x7fffffff
                    chars = self.u16(relative(text_offset, 2))
                    key = self.block(relative(text_offset + 2, chars * 2), chars * 2).decode('utf-16le')
                else: key = name
                if child & 0x80000000: walk(child & 0x7fffffff, path + [key])
                else:
                    data_rva, length, codepage, _ = self.unpack('<IIII', relative(child, 16))
                    blob = self.block(self.rva(data_rva, length), length)
                    item = {'path': path + [key], 'bytes': length, 'codepage': codepage, 'sha256': hashlib.sha256(blob).hexdigest()}
                    if path and path[0] == 24:
                        item['manifest'] = blob.decode('utf-8', 'replace')
                    result.append(item)
        walk(0, [])
        return result

    def report(self):
        certificate_offset, certificate_size = self.directory(4)
        if certificate_size: self.block(certificate_offset, certificate_size)
        imports = self.imports()
        delayed = self.imports(True)
        return {'path': str(self.path), 'bytes': len(self.data), 'sha256': hashlib.sha256(self.data).hexdigest(),
                'machine': f'0x{self.machine:04x}', 'architecture': {0x8664: 'x64', 0x14c: 'x86', 0xaa64: 'arm64'}.get(self.machine, 'unknown'),
                'optional_header': 'PE32+' if self.is64 else 'PE32', 'is_dll': bool(self.characteristics & 0x2000),
                'subsystem': self.subsystem, 'subsystem_name': {2: 'Windows GUI', 3: 'Windows CUI'}.get(self.subsystem, 'other'),
                'header_os_version': self.unpack('<HH', self.optional + 40), 'header_subsystem_version': self.unpack('<HH', self.optional + 48),
                'windows_11_build_22000_enforced_by_pe_header': False,
                'certificate_table_present': bool(certificate_size), 'signature_verified': False,
                'imports': imports, 'delay_imports': delayed, 'resources': self.resources(),
                'resource_and_dependency_checks_do_not_prove_runtime': True}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('files', nargs='+', type=Path)
    p.add_argument('--app', action='store_true', help='Require each inspected file to be the Quall release app')
    p.add_argument('--expected-icon', type=Path)
    a = p.parse_args()
    output = {'files': [], 'errors': []}
    for file in a.files:
        try:
            pe = PE(file)
            report = pe.report()
            failures = []
            if pe.machine != 0x8664: failures.append('not x64')
            if a.app:
                if pe.characteristics & 0x2000: failures.append('app is a DLL')
                if pe.subsystem != 2: failures.append('app is not Windows GUI subsystem')
                if b'quall-distribuicao: release-sem-monitor-v2' not in pe.data: failures.append('release marker absent')
                for forbidden in [b'quall-distribuicao: desenvolvimento-tela-estendida-v1', b'CertAddEncodedCertificateToStore', b'CertDeleteCertificateFromStore', b'UpdateDriverForPlugAndPlayDevicesW', b'SwDeviceCreate']:
                    if forbidden in pe.data: failures.append('forbidden driver marker/API: ' + forbidden.decode())
                types = {r['path'][0] for r in report['resources']}
                for t in (3, 14, 16, 24):
                    if t not in types: failures.append(f'resource type {t} absent')
            if a.expected_icon:
                ico = a.expected_icon.read_bytes()
                if ico[:4] != b'\0\0\1\0': raise ValueError('invalid expected ICO')
                count = struct.unpack_from('<H', ico, 4)[0]
                if not 1 <= count <= 1024: raise ValueError('invalid expected ICO image count')
                wanted = []
                group = ico[:6]
                for i in range(count):
                    size, off = struct.unpack_from('<II', ico, 6 + 16 * i + 8)
                    if off + size > len(ico): raise ValueError('expected ICO truncated')
                    wanted.append(hashlib.sha256(ico[off:off + size]).hexdigest())
                    group += ico[6 + 16 * i:6 + 16 * i + 12] + struct.pack('<H', i + 1)
                actual = [r['sha256'] for r in report['resources'] if r['path'][0] == 3]
                report['expected_icon_sha256'] = hashlib.sha256(ico).hexdigest()
                report['expected_icon_images_exact'] = len(actual) == count and sorted(actual) == sorted(wanted)
                if not report['expected_icon_images_exact']: failures.append('embedded icon images differ from expected ICO')
                groups = [r for r in report['resources'] if r['path'][:2] == [14, 1]]
                report['expected_icon_group_exact'] = bool(groups) and all(r['sha256'] == hashlib.sha256(group).hexdigest() for r in groups)
                if not report['expected_icon_group_exact']: failures.append('RT_GROUP_ICON 1 absent or differs from expected ICO mapping')
                images = [r for r in report['resources'] if r['path'][0] == 3]
                if any(not isinstance(r['path'][1], int) or not 1 <= r['path'][1] <= count or r['sha256'] != wanted[r['path'][1] - 1] for r in images):
                    failures.append('icon IDs differ from expected ICO mapping')
            report['structural_failures'] = failures
            output['files'].append(report)
            output['errors'].extend(f'{file}: {f}' for f in failures)
        except (OSError, ValueError, struct.error, UnicodeError) as error:
            output['errors'].append(f'{file}: {error}')
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return bool(output['errors'])


if __name__ == '__main__': sys.exit(main())
