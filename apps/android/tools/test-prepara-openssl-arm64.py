#!/usr/bin/env python3
"""Negative input-integrity tests for the actual preparation verifier, without builds."""
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

FILE = Path(__file__).with_name('prepara-openssl-arm64.py')
SPEC = importlib.util.spec_from_file_location('recipe', FILE)
recipe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(recipe)

class SourceIntegrity(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.source = self.directory / 'source'
        self.source.mkdir()
        self.archive = self.directory / 'source.crate'
        self.content = b'known immutable input\n'
        (self.source / 'input.c').write_bytes(self.content)
        with tarfile.open(self.archive, 'w:gz') as archive:
            info = tarfile.TarInfo('openssl-src-' + recipe.VERSION + '/input.c')
            info.size = len(self.content)
            archive.addfile(info, io.BytesIO(self.content))
        self.checksum = recipe.digest(self.archive.read_bytes())

    def tearDown(self):
        self.temporary.cleanup()

    def verify(self):
        return recipe.verify_source(self.source, self.archive, self.checksum)

    def test_valid_archive_and_every_source_file(self):
        self.assertEqual(self.verify(), {'input.c': recipe.digest(self.content)})

    def test_registry_file_tampering_rejected(self):
        (self.source / 'input.c').write_bytes(b'changed\n')
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            self.verify()

    def test_archive_tampering_rejected_against_locked_checksum(self):
        self.archive.write_bytes(self.archive.read_bytes() + b'changed')
        with self.assertRaisesRegex(RuntimeError, 'checksum'):
            self.verify()

    def test_extra_source_file_rejected(self):
        (self.source / 'extra.c').write_bytes(b'extra')
        with self.assertRaisesRegex(RuntimeError, 'extra'):
            self.verify()

    def test_missing_source_file_rejected(self):
        (self.source / 'input.c').unlink()
        with self.assertRaisesRegex(RuntimeError, 'missing'):
            self.verify()

    def test_symlink_rejected(self):
        (self.source / 'linked.c').symlink_to(self.source / 'input.c')
        with self.assertRaisesRegex(RuntimeError, 'linked'):
            self.verify()

if __name__ == '__main__':
    unittest.main()
