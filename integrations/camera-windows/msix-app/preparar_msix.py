#!/usr/bin/env python3
"""Prepare an UNSIGNED MSIX candidate of the Quall Microsoft Store edition.

Only reads inputs, creates a NEW output folder, and optionally invokes the explicit
Windows SDK MakeAppx tool. Never builds/loads binaries, signs, installs, registers
COM, modifies ACLs/certificates/security, launches an app or contacts a service.
This edition excludes the built-in virtual camera. Static guards and MakeAppx
do NOT establish runtime or Store certification.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path
from verificar_pe import PE

BASE_COMMIT = '3172b188c29a010cd161c56bbeeb2cbcefbb220a'
IDENTITY = 'Quven.Quall'
PUBLISHER = 'CN=4EAB9D59-8495-46DE-A09A-46666F12757F'
PFN = 'Quven.Quall_4bed071cmhnq6'
NS = {
    'f': 'http://schemas.microsoft.com/appx/manifest/foundation/windows10',
    'uap': 'http://schemas.microsoft.com/appx/manifest/uap/windows10',
    'uap10': 'http://schemas.microsoft.com/appx/manifest/uap/windows10/10',
    'rescap': 'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities',
    'com4': 'http://schemas.microsoft.com/appx/manifest/com/windows10/4',
    'desktop7': 'http://schemas.microsoft.com/appx/manifest/desktop/windows10/7',
}
for prefix, uri in NS.items():
    ET.register_namespace('' if prefix == 'f' else prefix, uri)
ASSETS = {'Square44x44Logo.png': 44, 'Square150x150Logo.png': 150, 'StoreLogo.png': 50}
DEV_ASSET_HASHES = {
    'fec146e74d769122bd07db043b89307b64bb25986321af7d62ff4d9d1a68df1e',
    'ce6623c19ddcccffc6b2bcc4513c92111f112e466f7b8f581e1cefdfc57da689',
    '1020504497247812bbf2eb8bc35b2e391144473d8ba3c5782122b351fee2afd4',
}
LEGAL = ('LICENSE', 'LICENSE-SCOPE.md', 'NOTICE.txt', 'THIRD_PARTY_NOTICES.txt')
BINARIES = ('quall-app.exe',)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def plain_file(path):
    p = Path(path)
    require(p.is_file() and not p.is_symlink(), f'Regular input file required: {p}')
    require(p.stat().st_size > 0, f'Empty input: {p}')
    return p


def version_parts(value, package=False):
    require(bool(re.fullmatch(r'[0-9]+(?:\.[0-9]+){3}', value)), 'Explicit four-part numeric version required')
    parts = tuple(int(p) for p in value.split('.'))
    require(all(0 <= p <= 65535 for p in parts), 'Version field exceeds 65535')
    if package:
        require(parts[0] > 0 and parts[3] == 0, 'Store package proposal requires major > 0 and fourth part 0')
    else:
        require(parts[:2] == (10, 0) and parts[2] >= 22000, 'Windows 11 build 22000+ required')
    return parts


def exact_node(node, attributes, children=None):
    require(node is not None, 'Expected manifest element absent')
    require(set(node.attrib) == set(attributes), 'Unexpected manifest attributes: ' + node.tag)
    if children is not None:
        require([child.tag for child in node] == children, 'Unexpected manifest children: ' + node.tag)


def validate_manifest(path, experimental=False):
    require(not experimental, 'COM camera experiment is excluded from the Store edition')
    text = plain_file(path).read_text(encoding='utf-8-sig')
    require(not any(x in text.lower() for x in ('placeholder', '__package', 'quall-camera-sonda.exe', 'requireadministrator')),
            'Placeholder, probe or elevation manifest is forbidden')
    tree = ET.ElementTree(ET.fromstring(text))
    root = tree.getroot()
    require(root.tag == '{' + NS['f'] + '}Package', 'Wrong package namespace')
    package_children = ['Identity', 'Properties', 'Dependencies', 'Resources', 'Applications']
    package_children.append('Capabilities')
    exact_node(root, ['IgnorableNamespaces'], ['{'+NS['f']+'}'+name for name in package_children])
    require(root.get('IgnorableNamespaces') == 'uap uap10 rescap',
            'Namespace contract differs from the reviewed template')
    identity = root.find('f:Identity', NS)
    require(identity is not None, 'Identity absent')
    exact_node(identity, ['Name', 'Publisher', 'Version', 'ProcessorArchitecture'], [])
    require(identity.get('Name') == IDENTITY and identity.get('Publisher') == PUBLISHER,
            'Existing Store identity must remain exact')
    require(identity.get('ProcessorArchitecture') == 'x64', 'Only x64 prototype is supported')
    version_parts(identity.get('Version', ''), package=True)
    properties = root.find('f:Properties', NS)
    exact_node(properties, [], ['{'+NS['f']+'}'+name for name in ['DisplayName', 'PublisherDisplayName', 'Logo']])
    for child in properties:
        exact_node(child, [], [])
    require(root.findtext('f:Properties/f:DisplayName', namespaces=NS) == 'Quall Studio', 'Wrong product display name')
    require(root.findtext('f:Properties/f:PublisherDisplayName', namespaces=NS) == 'Quéven', 'Wrong publisher display name')
    require(root.findtext('f:Properties/f:Logo', namespaces=NS) == r'Assets\StoreLogo.png', 'Wrong StoreLogo reference')
    families = root.findall('f:Dependencies/f:TargetDeviceFamily', NS)
    exact_node(root.find('f:Dependencies', NS), [], ['{'+NS['f']+'}TargetDeviceFamily', '{'+NS['f']+'}PackageDependency'])
    crt = root.find('f:Dependencies/f:PackageDependency', NS)
    exact_node(crt, ['Name', 'MinVersion', 'Publisher'], [])
    require(crt.get('Name') == 'Microsoft.VCLibs.140.00.UWPDesktop'
            and crt.get('MinVersion') == '14.0.33728.0'
            and crt.get('Publisher') == 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US',
            'Reviewed native Desktop CRT framework required')
    require(len(families) == 1 and families[0].get('Name') == 'Windows.Desktop'
            and families[0].get('MinVersion') == '10.0.22000.0', 'Wrong desktop minimum')
    exact_node(families[0], ['Name', 'MinVersion', 'MaxVersionTested'], [])
    version_parts(families[0].get('MaxVersionTested', ''))
    languages = {r.get('Language') for r in root.findall('f:Resources/f:Resource', NS)}
    resources = root.find('f:Resources', NS)
    exact_node(resources, [], ['{'+NS['f']+'}Resource'] * 2)
    for resource in resources:
        exact_node(resource, ['Language'], [])
    require(languages == {'pt-BR', 'en-US'}, 'Only existing pt-BR/en-US app languages are declared')
    apps = root.findall('f:Applications/f:Application', NS)
    exact_node(root.find('f:Applications', NS), [], ['{'+NS['f']+'}Application'])
    require(len(apps) == 1, 'Exactly one product application required')
    app = apps[0]
    exact_node(app, ['Id', 'Executable', '{'+NS['uap10']+'}RuntimeBehavior', '{'+NS['uap10']+'}TrustLevel'],
               ['{'+NS['uap']+'}VisualElements'])
    require(app.get('Id') == 'QuallStudio' and app.get('Executable') == 'quall-app.exe', 'Real product EXE required')
    require(app.get('{' + NS['uap10'] + '}RuntimeBehavior') == 'packagedClassicApp'
            and app.get('{' + NS['uap10'] + '}TrustLevel') == 'mediumIL', 'Wrong desktop activation model')
    require(app.get('EntryPoint') is None, 'Do not mix redundant activation declarations')
    visual = app.find('uap:VisualElements', NS)
    require(visual is not None and visual.get('DisplayName') == 'Quall Studio', 'Product visual elements absent')
    exact_node(visual, ['DisplayName', 'Description', 'BackgroundColor', 'Square150x150Logo', 'Square44x44Logo'], [])
    require(visual.get('BackgroundColor') == 'transparent', 'Unexpected visual background')
    for key, name in [('Square44x44Logo', 'Square44x44Logo.png'), ('Square150x150Logo', 'Square150x150Logo.png')]:
        require(visual.get(key) == 'Assets\\' + name, 'Wrong visual asset reference')
    capabilities = root.find('f:Capabilities', NS)
    require(capabilities is not None, 'Capabilities absent')
    exact_node(capabilities, [])
    for capability in capabilities:
        exact_node(capability, ['Name'], [])
    expected = [('{'+NS['rescap']+'}Capability', 'runFullTrust'),
                ('{'+NS['f']+'}DeviceCapability', 'webcam'),
                ('{'+NS['f']+'}DeviceCapability', 'microphone')]
    require([(c.tag, c.get('Name')) for c in capabilities] == expected,
            'Only runFullTrust, webcam and microphone are justified here; retain schema order')
    require(not root.findall('.//f:Extensions', NS), 'Store edition does not register COM or other extensions')
    require(not root.findall('.//f:CustomCapability', NS), 'Custom compatibility capabilities are not granted')
    return tree


def validate_asset(path, size):
    data = plain_file(path).read_bytes()
    require(len(data) >= 33 and data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', 'PNG asset required')
    require(struct.unpack_from('>II', data, 16) == (size, size), f'Asset must be {size}x{size}')
    require(hashlib.sha256(data).hexdigest() not in DEV_ASSET_HASHES, 'Development placeholder asset is forbidden')
    offset, chunks, compressed = 8, [], bytearray()
    while offset < len(data):
        require(offset + 12 <= len(data), 'Truncated PNG chunk')
        length = struct.unpack_from('>I', data, offset)[0]
        require(offset + 12 + length <= len(data), 'PNG chunk exceeds file bounds')
        kind = data[offset+4:offset+8]
        value = data[offset+8:offset+8+length]
        crc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        require(zlib.crc32(kind + value) & 0xffffffff == crc, 'PNG chunk CRC mismatch')
        chunks.append(kind)
        if kind == b'IDAT':
            compressed.extend(value)
        offset += length + 12
        if kind == b'IEND':
            require(length == 0 and offset == len(data), 'Invalid PNG terminator/trailing bytes')
            break
    require(chunks and chunks[0] == b'IHDR' and chunks.count(b'IHDR') == 1
            and chunks[-1] == b'IEND' and compressed, 'Complete PNG header/data/terminator required')
    # SDK remains responsible for its supported image formats and visual QA.
    require(data[24:29] in (b'\x08\x06\x00\x00\x00', b'\x08\x02\x00\x00\x00'),
            'Prototype accepts only noninterlaced 8-bit RGB/RGBA PNG assets')
    channels = 4 if data[25] == 6 else 3
    decoder = zlib.decompressobj()
    maximum = size * (1 + channels * size)
    pixels = decoder.decompress(bytes(compressed), maximum + 1)
    require(len(pixels) == maximum and decoder.eof and not decoder.unused_data,
            'PNG decoded scanline length/stream invalid')
    require(all(pixels[y * (1 + channels * size)] <= 4 for y in range(size)), 'Unknown PNG scanline filter')


def validate_binaries(payload, expected_icon):
    files = {p.name for p in Path(payload).iterdir()}
    require(files == set(BINARIES), 'Store binary input must contain only quall-app.exe; camera DLL/extra payload forbidden')
    app_path = plain_file(Path(payload) / BINARIES[0])
    # Exact product resource checks also reject a probe renamed to quall-app.exe.
    app = PE(app_path)
    require(app.machine == 0x8664 and app.is64 and not app.characteristics & 0x2000 and app.subsystem == 2,
            'Real x64 PE32+ GUI app required')
    require(b'quall-distribuicao: release-sem-monitor-v2' in app.data, 'Current app-only release marker absent')
    validate_store_camera_boundary(app)
    resources = app.resources()
    require({3, 14, 16, 24}.issubset({r['path'][0] for r in resources}), 'App icon/version/manifest resources absent')
    require('quall-app.exe'.encode('utf-16le') in app.data and 'Quall Studio'.encode('utf-16le') in app.data,
            'Real product version resource absent')
    checker = subprocess.run([sys.executable, '-X', 'utf8', str(Path(__file__).with_name('verificar_pe.py')),
                              '--app', '--expected-icon', str(plain_file(expected_icon)), str(app_path)],
                             capture_output=True, text=True, encoding='utf-8', timeout=60)
    require(checker.returncode == 0, 'App PE/resource guard failed: ' + checker.stdout + checker.stderr)
    app_report = json.loads(checker.stdout)
    return {'app': app_report, 'edition': 'store-without-virtual-camera',
            'virtual_camera_payload_present': False, 'runtime_dependencies_proven': False}


def validate_store_camera_boundary(app):
    require(b'quall-distribuicao: store-sem-camera-virtual-v3' in app.data,
            'Store edition build marker absent; desktop binary is not the Store edition')
    for imported in app.imports() + app.imports(True):
        require(imported['dll'].casefold() != 'quall_camera_fonte.dll', 'Virtual camera DLL import forbidden')
        require('MFCreateVirtualCamera' not in imported['symbols'], 'Virtual camera activation import forbidden')


def validate_provenance(path, payload):
    origin = json.loads(plain_file(path).read_text(encoding='utf-8-sig'))
    require(origin.get('public_base_commit') == BASE_COMMIT, 'Expected public source base commit required')
    require(isinstance(origin.get('candidate_source_changes'), list), 'Explicit source change inventory required, even if empty')
    require(isinstance(origin.get('private_brand_overlays'), list), 'Explicit private brand inventory required, even if empty')
    hashes = origin.get('binary_sha256')
    require(isinstance(hashes, dict) and set(hashes) == set(BINARIES), 'Only the actual Store app binary hash is required')
    for name in BINARIES:
        require(hashes.get(name) == digest(Path(payload) / name), 'Binary differs from recorded build provenance: ' + name)
    require(origin.get('native_build_completed') is True, 'Native build has not been recorded complete')
    require(origin.get('edition') == 'store-without-virtual-camera', 'Store edition provenance required')
    require(origin.get('cargo_features') == ['net', 'loja'], 'Explicit net,loja build required')
    require(origin.get('security_protocol_version') == 3, 'Secure protocol v3 build required')
    return origin


def reserved_output(path):
    return any(part.casefold() in {'.git', 'quall-win', 'quall', 'desktop', 'área de trabalho'}
               or part.casefold().startswith('quall-snapshot-publico') for part in path.parts)


def is_reparse_or_link(path):
    if path.is_symlink():
        return True
    info = path.lstat()
    # FILE_ATTRIBUTE_REPARSE_POINT includes Windows junctions, not only symbolic links.
    return bool(getattr(info, 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400))


def new_output(path, inputs):
    output = Path(path)
    require(output.is_absolute(), 'Output must be an explicit absolute NEW path')
    require(not output.exists() and not output.is_symlink(), 'Output exists; refusing overwrite or cleanup')
    require(output.parent.is_dir(), 'Output parent must already exist')
    require(not reserved_output(output),
            'Do not write into reserved repositories, Desktop or existing product trees')
    resolved = output.resolve()
    require(not reserved_output(resolved), 'Resolved output leads into a reserved tree')
    require(not any(is_reparse_or_link(p) for p in output.parents), 'Output parent links/junctions/reparse points are not accepted')
    for value in inputs:
        input_path = Path(value).resolve()
        require(resolved != input_path and input_path not in resolved.parents, 'Output cannot be inside an input tree')
    return output


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifesto', type=Path, required=True)
    p.add_argument('--payload', type=Path, required=True, help='Only the current Store edition quall-app.exe; nothing here is executed')
    p.add_argument('--assets', type=Path, required=True, help='Reviewed PNGs; bundled development placeholders are rejected')
    p.add_argument('--icone-esperado', type=Path, required=True)
    p.add_argument('--fonte', type=Path, required=True, help='Exact identified source root supplying all four legal notices')
    p.add_argument('--origem-artefatos', type=Path, required=True)
    p.add_argument('--versao', required=True, help='Explicit proposed package version, e.g. 1.0.0.0; not release approval')
    p.add_argument('--max-version-tested', required=True, help='Explicit Windows version supported by actual test evidence')
    p.add_argument('--saida', type=Path, required=True)
    p.add_argument('--makeappx', type=Path, help='Optional explicit existing Windows SDK makeappx.exe; no install/download')
    a = p.parse_args()
    try:
        version_parts(a.versao, package=True)
        version_parts(a.max_version_tested)
        tree = validate_manifest(a.manifesto)
        output = new_output(a.saida, [a.payload, a.assets, a.fonte])
        for name, size in ASSETS.items():
            validate_asset(a.assets / name, size)
        for name in LEGAL:
            plain_file(a.fonte / name)
        binary_report = validate_binaries(a.payload, a.icone_esperado)
        origin = validate_provenance(a.origem_artefatos, a.payload)
        if a.makeappx:
            require(os.name == 'nt', 'MakeAppx packaging requires Windows; no emulation or remote execution')
            require(plain_file(a.makeappx).name.lower() == 'makeappx.exe', 'Explicit Windows SDK makeappx.exe required')
        tree.getroot().find('f:Identity', NS).set('Version', a.versao)
        tree.getroot().find('f:Dependencies/f:TargetDeviceFamily', NS).set('MaxVersionTested', a.max_version_tested)
        # All validations precede the first output write. Preserve partial outputs if SDK fails.
        output.mkdir(exist_ok=False)
        stage = output / 'payload'
        stage.mkdir(exist_ok=False)
        (stage / 'Assets').mkdir(exist_ok=False)
        tree.write(stage / 'AppxManifest.xml', encoding='utf-8', xml_declaration=True)
        for name in BINARIES:
            shutil.copyfile(a.payload / name, stage / name)
        for name in LEGAL:
            shutil.copyfile(a.fonte / name, stage / name)
        for name in ASSETS:
            shutil.copyfile(a.assets / name, stage / 'Assets' / name)
        # Keep build diagnostics outside the package payload. No installer/removal scripts are bundled.
        (output / 'origem-artefatos.json').write_text(json.dumps(origin, ensure_ascii=False, indent=2), encoding='utf-8')
        (output / 'PE-verificacao.json').write_text(json.dumps(binary_report, ensure_ascii=False, indent=2), encoding='utf-8')
        report = {'product': IDENTITY, 'package_family_name_expected': PFN,
                  'variant': 'store-without-virtual-camera',
                  'security_protocol_version': 3, 'virtual_camera_payload_present': False,
                  'unsigned': True, 'install_or_register_performed': False,
                  'static_contract_passed': True, 'sdk_schema_validation_completed': False,
                  'runtime_app_verified': False, 'store_submission_ready': False,
                  'payload_sha256': {str(f.relative_to(stage)): digest(f) for f in sorted(stage.rglob('*')) if f.is_file()}}
        report_path = output / 'EMPACOTAMENTO.json'
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        if a.makeappx:
            package = output / 'QuallStudio-Store-candidato-x64.msix'
            sdk = subprocess.run([str(a.makeappx), 'pack', '/d', str(stage), '/p', str(package), '/h', 'SHA256', '/no'],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
            (output / 'makeappx-output.txt').write_bytes(sdk.stdout)
            report['makeappx_exit_code'] = sdk.returncode
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
            require(sdk.returncode == 0 and package.is_file(), 'MakeAppx failed; preserve its output and do not install/submit')
            report['sdk_schema_validation_completed'] = True
            report['package_sha256'] = digest(package)
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, struct.error, ET.ParseError, subprocess.TimeoutExpired) as error:
        print('Preparation refused/failed: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
