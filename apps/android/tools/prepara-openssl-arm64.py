#!/usr/bin/env python3
"""Reproduce the locked openssl-src builder, with one Android ARM64 capability guard.

The default operation verifies inputs only. --prepare copies verified sources into
an explicitly selected fresh build directory. --build additionally runs the
official builder. No registry source is modified. No CPU/RNG mask is applied.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile

VERSION = '400.0.2+4.0.3'
CHECKSUM = 'd2093956673b8dbda85c87fa4fb78e70698ce6c5978a2837d1613f661d3bef76'
ARMCAP_SHA = 'b4b3291b98addb988a843eedc4d7a8d7a7333640bf148d4a0ee83b17b5cd6cf1'
OLD = '    if (getauxval(OSSL_HWCAP2) & OSSL_HWCAP2_SVE2)\n        OPENSSL_armcap_P |= ARMV9_SVE2;'
NEW = '    /* SVE2 uses base SVE instructions; do not trust inconsistent HWCAP2 alone. */\n    if ((OPENSSL_armcap_P & ARMV8_SVE)\n        && (getauxval(OSSL_HWCAP2) & OSSL_HWCAP2_SVE2))\n        OPENSSL_armcap_P |= ARMV9_SVE2;'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def command(args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env, text=True)

def locked_package(lock, name, version=None):
    found = []
    for block in lock.split('[[package]]')[1:]:
        fields = dict(re.findall(r'^(name|version|source|checksum) = "([^"]+)"$', block, re.M))
        if fields.get('name') == name and (version is None or fields.get('version') == version):
            found.append(fields)
    if len(found) != 1:
        raise RuntimeError('Ambiguous or missing locked input: ' + name)
    return found[0]

def verify_source(source, archive, checksum):
    if digest(archive.read_bytes()) != checksum:
        raise RuntimeError('Registry archive checksum differs from Cargo.lock')
    files = {}
    with tarfile.open(archive, 'r:gz') as package:
        prefix = 'openssl-src-' + VERSION
        for member in package.getmembers():
            parts = PurePosixPath(member.name).parts
            if not parts or parts[0] != prefix or '..' in parts or member.issym() or member.islnk():
                raise RuntimeError('Unsafe or unexpected crate member')
            if member.isdir():
                continue
            if not member.isfile() or len(parts) < 2:
                raise RuntimeError('Unsupported crate member')
            relative = '/'.join(parts[1:])
            if relative in files:
                raise RuntimeError('Duplicate crate member')
            files[relative] = digest(package.extractfile(member).read())
    actual = {str(p.relative_to(source)) for p in source.rglob('*') if p.is_file()}
    extra = actual - set(files) - {'.cargo-ok', '.cargo-checksum.json'}
    if extra or set(files) - actual or any(p.is_symlink() for p in source.rglob('*')):
        raise RuntimeError('Registry source has extra, missing or linked files')
    for relative, expected in files.items():
        if digest((source / relative).read_bytes()) != expected:
            raise RuntimeError('Registry source differs from authenticated archive: ' + relative)
    checksum_file = source / '.cargo-checksum.json'
    if checksum_file.exists():
        cargo_checksums = json.loads(checksum_file.read_text())
        if cargo_checksums.get('package') != checksum or cargo_checksums.get('files') != files:
            raise RuntimeError('Cargo checksum file differs from authenticated archive')
    return files

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--build', action='store_true')
    args = parser.parse_args()
    repository = args.repository.resolve()
    output = args.output.resolve()
    source_lock = (repository / 'Cargo.lock').read_text()
    locked = locked_package(source_lock, 'openssl-src', VERSION)
    if locked.get('checksum') != CHECKSUM or locked.get('source') != 'registry+https://github.com/rust-lang/crates.io-index':
        raise RuntimeError('Unexpected openssl-src lock identity')
    metadata = json.loads(command(['cargo', 'metadata', '--locked', '--offline', '--format-version=1'], cwd=repository))
    packages = [p for p in metadata['packages'] if p['name'] == 'openssl-src' and p['version'] == VERSION]
    if len(packages) != 1:
        raise RuntimeError('Unexpected openssl-src metadata')
    package = packages[0]
    node = next(n for n in metadata['resolve']['nodes'] if n['id'] == package['id'])
    if node['features'] != ['default']:
        raise RuntimeError('Builder recipe requires the exact locked openssl-src default feature set')
    source = Path(package['manifest_path']).parent
    # Cargo registry src/<index>/<crate> and cache/<index>/<crate>.crate are siblings.
    archive = source.parent.parent.parent / 'cache' / source.parent.name / ('openssl-src-' + VERSION + '.crate')
    files = verify_source(source, archive, CHECKSUM)
    armcap = (source / 'openssl/crypto/armcap.c').read_text()
    if digest(armcap.encode()) != ARMCAP_SHA or armcap.count(OLD) != 1:
        raise RuntimeError('Guard source preimage changed')
    patch = Path(__file__).with_name('openssl-arm64-sve-base.patch')
    if not patch.is_file():
        raise RuntimeError('Published guard patch missing')
    receipt = {'schema': 1, 'target': 'aarch64-linux-android', 'opensslVersion': '4.0.3',
               'opensslSrcVersion': VERSION, 'archiveSha256': CHECKSUM,
               'filesVerified': len(files), 'allFilesVerifiedBeforeCopy': True,
               'cargoChecksumFilePresent': (source / '.cargo-checksum.json').exists(),
               'registrySourceModified': False, 'sourceLockSha256': digest(source_lock.encode()),
               'guardPatchSha256': digest(patch.read_bytes()), 'beforeArmcapSha256': ARMCAP_SHA,
               'cpuMaskOrRngOverride': False, 'officialBuilderFeatures': ['default'], 'built': False}
    if not (args.prepare or args.build):
        print(json.dumps(receipt, indent=2))
        return
    if output.exists():
        raise RuntimeError('Refusing to overwrite build directory; choose a fresh output')
    output.mkdir(parents=True)
    copied = output / 'openssl-src'
    copied.mkdir()
    for relative, expected in files.items():
        destination = copied / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, destination)
        if digest(destination.read_bytes()) != expected:
            raise RuntimeError('Copied file digest differs: ' + relative)
    (output / 'pristine-source-checksums.json').write_text(json.dumps({'package': CHECKSUM, 'files': files}, sort_keys=True, indent=2) + '\n')
    subprocess.run(['patch', '--batch', '--forward', '--fuzz=0', '-p1', '-i', str(patch.resolve())], cwd=copied, check=True)
    patched = (copied / 'openssl/crypto/armcap.c').read_text()
    if patched != armcap.replace(OLD, NEW):
        raise RuntimeError('Applied patch has an unexpected delta')
    patched_files = dict(files)
    patched_files['openssl/crypto/armcap.c'] = digest(patched.encode())
    for relative, expected in patched_files.items():
        if digest((copied / relative).read_bytes()) != expected:
            raise RuntimeError('Unexpected change outside the reviewed guard')
    # This checksum file documents the local overlay; the original package archive
    # and all pristine hashes remain separately authenticated in the receipt.
    (copied / '.cargo-checksum.json').write_text(json.dumps({'package': CHECKSUM, 'files': patched_files}, sort_keys=True) + '\n')
    helper = output / 'builder'
    (helper / 'src').mkdir(parents=True)
    inputs = [locked_package(source_lock, 'cc'), locked_package(source_lock, 'find-msvc-tools'), locked_package(source_lock, 'shlex', '2.0.1')]
    manifest = '[package]\nname="quall-openssl-android-builder"\nversion="0.1.0"\nedition="2021"\n[workspace]\n[dependencies]\nopenssl-src={path="../openssl-src"}\n'
    manifest += ''.join(p['name'] + '="=' + p['version'] + '"\n' for p in inputs)
    (helper / 'Cargo.toml').write_text(manifest)
    (helper / 'src/main.rs').write_text('''fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert_eq!(args.len(), 3, "expected build directory and host triple");
    assert_eq!(openssl_src::version(), "400.0.2+4.0.3");
    let artifacts = openssl_src::Build::new().out_dir(&args[1])
        .target("aarch64-linux-android").host(&args[2]).build();
    println!("QUALL_OPENSSL_PREFIX={}", artifacts.lib_dir().parent().unwrap().display());
}
''')
    command(['cargo', 'generate-lockfile', '--offline'], cwd=helper)
    helper_lock = (helper / 'Cargo.lock').read_text()
    for expected in inputs:
        if locked_package(helper_lock, expected['name'], expected['version']) != expected:
            raise RuntimeError('Helper builder input differs from workspace lock')
    receipt.update({'afterArmcapSha256': patched_files['openssl/crypto/armcap.c'],
                    'helperLockSha256': digest(helper_lock.encode()),
                    'builderDependencyInputs': inputs, 'prefix': 'openssl-build/install'})
    if args.build:
        env = os.environ.copy()
        for name in ['OPENSSL_armcap', 'OPENSSL_ia32cap', 'OPENSSL_CONF', 'OPENSSL_MODULES', 'RANDFILE']:
            if name in env:
                raise RuntimeError('Refusing OpenSSL runtime capability/provider/RNG overrides: ' + name)
        # The Rust helper runs on the host. ELF linker flags belong only to the
        # Android core; preserve the cross-compiler CC/CFLAGS used by OpenSSL.
        env.pop('RUSTFLAGS', None)
        env.pop('CARGO_ENCODED_RUSTFLAGS', None)
        env['CARGO_TARGET_DIR'] = str(output / 'host-target')
        env['CARGO_MAKEFLAGS'] = '-j1'
        env['MAKEFLAGS'] = '-j1'
        host = re.search(r'^host: (.+)$', command(['rustc', '-vV']), re.M).group(1)
        subprocess.run(['cargo', 'run', '--locked', '--offline', '-j1', '--target', host, '--manifest-path', str(helper / 'Cargo.toml'), '--', str(output / 'openssl-build'), host], env=env, check=True)
        prefix = output / 'openssl-build/install'
        for relative in ['lib/libcrypto.a', 'lib/libssl.a', 'include/openssl/opensslv.h']:
            if not (prefix / relative).is_file():
                raise RuntimeError('Static prefix artifact missing: ' + relative)
        receipt['built'] = True
        receipt['staticArtifacts'] = {relative: digest((prefix / relative).read_bytes()) for relative in ['lib/libcrypto.a', 'lib/libssl.a']}
    (output / 'source-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))

if __name__ == '__main__':
    main()
