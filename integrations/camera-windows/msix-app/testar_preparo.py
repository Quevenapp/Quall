#!/usr/bin/env python3
"""Focused negative guards; fixtures are data only, never distributable binaries/assets."""
import json
import struct
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path
import preparar_msix as prep

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / 'fixtures'


class Guards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=HERE)
        self.path = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def changed_manifest(self, edit, variant=False):
        original = HERE / ('AppxManifest.com-usuario-experimental.xml' if variant else 'AppxManifest.xml')
        tree = ET.parse(original)
        edit(tree.getroot())
        path = self.path / 'manifest.xml'
        tree.write(path, encoding='utf-8', xml_declaration=True)
        return path

    def test_base_contract_and_old_com_experiment_refused(self):
        prep.validate_manifest(HERE / 'AppxManifest.xml')
        with self.assertRaisesRegex(ValueError, 'excluded'):
            prep.validate_manifest(HERE / 'AppxManifest.com-usuario-experimental.xml', True)

    def test_missing_or_wrong_crt_rejected(self):
        def remove(root):
            d = root.find('f:Dependencies', prep.NS)
            d.remove(d.find('f:PackageDependency', prep.NS))
        with self.assertRaises(ValueError):
            prep.validate_manifest(self.changed_manifest(remove))
        path = self.changed_manifest(lambda root: root.find('f:Dependencies/f:PackageDependency', prep.NS).set('Name', 'Microsoft.VCLibs.140.00'))
        with self.assertRaises(ValueError):
            prep.validate_manifest(path)

    def test_existing_probe_manifest_rejected(self):
        with self.assertRaises(ValueError):
            prep.validate_manifest(FIXTURES / 'probe-AppxManifest.xml')

    def test_probe_executable_rejected(self):
        path = self.changed_manifest(lambda root: root.find('f:Applications/f:Application', prep.NS).set('Executable', 'quall-camera-sonda.exe'))
        with self.assertRaises(ValueError):
            prep.validate_manifest(path)

    def test_changed_store_identity_rejected(self):
        path = self.changed_manifest(lambda root: root.find('f:Identity', prep.NS).set('Name', 'Queven.QuallStudio'))
        with self.assertRaises(ValueError):
            prep.validate_manifest(path)

    def test_redundant_activation_rejected(self):
        path = self.changed_manifest(lambda root: root.find('f:Applications/f:Application', prep.NS).set('EntryPoint', 'Windows.FullTrustApplication'))
        with self.assertRaises(ValueError):
            prep.validate_manifest(path)

    def test_app_container_rejected(self):
        path = self.changed_manifest(lambda root: root.find('f:Applications/f:Application', prep.NS).set('{'+prep.NS['uap10']+'}TrustLevel', 'appContainer'))
        with self.assertRaises(ValueError):
            prep.validate_manifest(path)

    def test_missing_webcam_rejected(self):
        def remove(root):
            node = root.find('f:Capabilities', prep.NS)
            node.remove(node.find('f:DeviceCapability[@Name="webcam"]', prep.NS))
        with self.assertRaises(ValueError):
            prep.validate_manifest(self.changed_manifest(remove))

    def test_ungranted_machine_scope_rejected(self):
        path = self.changed_manifest(lambda root: root.find('f:Extensions/com4:Extension', prep.NS).set('{'+prep.NS['desktop7']+'}Scope', 'machine'), True)
        with self.assertRaises(ValueError):
            prep.validate_manifest(path)

    def test_com_requires_explicit_variant(self):
        with self.assertRaises(ValueError):
            prep.validate_manifest(HERE / 'AppxManifest.com-usuario-experimental.xml')

    def test_ungranted_custom_capability_rejected(self):
        def custom(root):
            ET.SubElement(root.find('f:Capabilities', prep.NS), '{'+prep.NS['f']+'}CustomCapability', {'Name': 'Microsoft.classicAppCompatElevated_8wekyb3d8bbwe'})
        with self.assertRaises(ValueError):
            prep.validate_manifest(self.changed_manifest(custom))

    def test_additional_com_server_rejected(self):
        def extra(root):
            node = root.find('f:Extensions/com4:Extension/com4:ComServer', prep.NS)
            ET.SubElement(node, '{'+prep.NS['com4']+'}ExeServer', {'Executable': 'other.exe'})
        with self.assertRaises(ValueError):
            prep.validate_manifest(self.changed_manifest(extra, True))

    def test_additional_class_children_rejected(self):
        def extra(root):
            node = root.find('f:Extensions/com4:Extension/com4:ComServer/com4:InProcessServer/com4:Class', prep.NS)
            ET.SubElement(node, '{'+prep.NS['com4']+'}DefaultIcon', {'ResourceIndex': '0'})
        with self.assertRaises(ValueError):
            prep.validate_manifest(self.changed_manifest(extra, True))

    def test_unreviewed_application_arguments_rejected(self):
        path = self.changed_manifest(lambda root: root.find('f:Applications/f:Application', prep.NS).set('{'+prep.NS['uap10']+'}Parameters', '--unknown'))
        with self.assertRaises(ValueError):
            prep.validate_manifest(path)

    def test_invalid_version_and_minimum_rejected(self):
        for value in ('0.1.0.0', '1.0.0.1', '__PACKAGE_VERSION__', '1.65536.0.0'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                prep.version_parts(value, True)
        with self.assertRaises(ValueError):
            prep.version_parts('10.0.19041.0')

    def test_development_assets_rejected(self):
        for name, size in prep.ASSETS.items():
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'Development placeholder'):
                prep.validate_asset(FIXTURES / 'development-assets' / name, size)

    def test_png_fixture_chunk_validation_not_asset_delivery(self):
        size = 44
        def chunk(kind, body):
            return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
        data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>II', size, size) + b'\x08\x06\0\0\0')
        data += chunk(b'IDAT', zlib.compress((b'\0' + b'\1\2\3\xff' * size) * size)) + chunk(b'IEND', b'')
        path = self.path / 'fixture-only.png'
        path.write_bytes(data)
        prep.validate_asset(path, size)
        path.write_bytes(data[:-8])
        with self.assertRaises(ValueError):
            prep.validate_asset(path, size)

    def test_existing_output_preserved(self):
        sentinel = self.path / 'sentinel.txt'
        sentinel.write_text('KEEP', encoding='utf-8')
        with self.assertRaises(ValueError):
            prep.new_output(self.path, [])
        self.assertEqual(sentinel.read_text(encoding='utf-8'), 'KEEP')

    def test_output_not_inside_input(self):
        with self.assertRaises(ValueError):
            prep.new_output(self.path / 'new-child', [self.path])

    def test_output_canonical_reserved_tree_rejected(self):
        reserved = self.path / 'quall'
        reserved.mkdir()
        link = self.path / 'innocent-parent'
        link.symlink_to(reserved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Resolved output'):
            prep.new_output(link / 'new-output', [])

    def test_output_parent_reparse_guard_rejected(self):
        # Control of the Windows guard boundary; not a native Windows junction test.
        with patch.object(prep, 'is_reparse_or_link', return_value=True), self.assertRaisesRegex(ValueError, 'reparse'):
            prep.new_output(self.path / 'new-output', [])

    def test_unbuilt_or_mismatched_provenance_rejected(self):
        payload = self.path / 'input'
        payload.mkdir()
        for name in prep.BINARIES:
            (payload / name).write_bytes(b'NOT A BINARY; HASH GUARD FIXTURE')
        origin = {'public_base_commit': prep.BASE_COMMIT, 'candidate_source_changes': [], 'private_brand_overlays': [],
                  'binary_sha256': {name: prep.digest(payload / name) for name in prep.BINARIES},
                  'native_build_completed': False, 'edition': 'store-without-virtual-camera',
                  'cargo_features': ['net', 'loja'], 'security_protocol_version': 3}
        path = self.path / 'origin.json'
        path.write_text(json.dumps(origin), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'Native build'):
            prep.validate_provenance(path, payload)
        origin['native_build_completed'] = True
        origin['binary_sha256']['quall-app.exe'] = '0' * 64
        path.write_text(json.dumps(origin), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'differs'):
            prep.validate_provenance(path, payload)

    def test_text_renamed_as_real_exe_rejected(self):
        for name in prep.BINARIES:
            (self.path / name).write_text('quall-app.exe Quall Studio quall-distribuicao: release-sem-monitor-v2')
        with self.assertRaises(ValueError):
            prep.validate_binaries(self.path, self.path / 'missing.ico')

    def test_camera_dll_in_payload_refused_before_loading_anything(self):
        (self.path / 'quall-app.exe').write_bytes(b'fixture')
        (self.path / 'quall_camera_fonte.dll').write_bytes(b'fixture')
        with self.assertRaisesRegex(ValueError, 'camera DLL'):
            prep.validate_binaries(self.path, self.path / 'missing.ico')

    def test_desktop_marker_and_camera_imports_refused(self):
        class FixturePE:
            data = b'quall-distribuicao: release-sem-monitor-v2'
            direct = []
            delayed = []
            def imports(self, delayed=False):
                return self.delayed if delayed else self.direct
        pe = FixturePE()
        with self.assertRaisesRegex(ValueError, 'Store edition'):
            prep.validate_store_camera_boundary(pe)
        pe.data += b'quall-distribuicao: store-sem-camera-virtual-v3'
        prep.validate_store_camera_boundary(pe)
        pe.direct = [{'dll': 'mfsensorgroup.dll', 'symbols': ['MFCreateVirtualCamera']}]
        with self.assertRaisesRegex(ValueError, 'activation'):
            prep.validate_store_camera_boundary(pe)
        pe.direct = []
        pe.delayed = [{'dll': 'Quall_Camera_Fonte.DLL', 'symbols': []}]
        with self.assertRaisesRegex(ValueError, 'DLL import'):
            prep.validate_store_camera_boundary(pe)


if __name__ == '__main__':
    unittest.main(verbosity=2)
