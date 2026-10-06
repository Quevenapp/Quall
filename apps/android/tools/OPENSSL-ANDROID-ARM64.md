# OpenSSL 4.0.3: Android ARM64 capability prerequisite

The Android ARM64 build uses the locked `openssl-src 400.0.2+4.0.3` source and
official Rust builder. One local source patch requires base SVE support before
selecting SVE2. An Android emulator advertised `HWCAP2_SVE2` without `HWCAP_SVE`;
the unmodified OpenSSL constructor selected its SVE `cntb` probe and received
SIGILL. This diagnosis does not establish a page-alignment error. This is a local
portability patch, not a claim of an upstream fix or independent security audit.

`prepara-openssl-arm64.py` locates the package with locked, offline Cargo metadata,
checks the registry archive SHA256 against `Cargo.lock`, and compares every source
file against that authenticated archive. If Cargo supplied a checksum file, it is
also checked. Where that file is absent, the archive provides the complete file
manifest. Missing, extra, changed and linked files fail before copying.

The helper uses a fresh output directory, records all pristine hashes, copies the
source, and applies `openssl-arm64-sve-base.patch` without fuzz. A second full check
allows exactly that one reviewed file delta. The local checksum file describes the
patched copy; the separate pristine manifest retains authenticated upstream hashes.
The registry cache is never edited. The helper pins its `cc`, `find-msvc-tools` and
`shlex` inputs to their workspace lock identities and checks its generated lock.

The copied `openssl-src` builder receives its existing default feature set. Its
Configure options, assembly, providers, CPU detection and RNG remain enabled as in
the original builder. The external static prefix is consumed only for
`aarch64-linux-android`, through `AARCH64_LINUX_ANDROID_OPENSSL_DIR` and the explicit
`OPENSSL_NO_VENDOR=1` build marker. `datachannel-sys` calls `openssl-src` directly,
so its Android ARM64 branch must select that prefix; the marker alone is insufficient.
Direct ARM64 Cargo builds without the required prefix fail with an actionable error.
ARMv7 and the other platform branches keep their existing recipes.

The preparation helper defaults to verification only. `--prepare` copies and
patches sources and creates the helper lock without compiling. `--build` additionally
runs the official builder with one Make/Cargo job. It requires a new output path;
it will not overwrite or silently reuse an earlier prefix. `compila-nucleo.sh`
invokes the build for ARM64 and performs the existing symbol/SONAME/alignment gates.
Use a fresh `CARGO_TARGET_DIR` when reproducing the complete build.

After reviewing the patch, run the input-integrity tests:

```sh
python3 apps/android/tools/test-prepara-openssl-arm64.py
```

Before assembling a replacement APK/AAB, use the CLI fixtures on the owned test
emulator. The first links the guarded static prefix and checks actual OpenSSL
initialization, selected SVE capabilities and `RAND_bytes`; its random bytes are
cleansed and never printed. The second loads the actual packaged libc++/core pair,
checks protocol version and PIN generation, and wipes the PIN without printing it.
It performs no Activity launch, pairing, media, socket or user-data operation.

Example compilation after the prefix is built (paths below are caller-selected):

```sh
clang_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android28-clang"
"$clang_android" -fPIE -pie -I "$openssl_prefix/include" \
  apps/android/tools/tests/openssl-startup.c "$openssl_prefix/lib/libcrypto.a" \
  -ldl -pthread -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 \
  -Wl,-z,relro,-z,now -o "$fixture_output/openssl-startup"
"$clang_android" -fPIE -pie apps/android/tools/tests/core-dlopen.c -ldl \
  -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 \
  -Wl,-z,relro,-z,now -o "$fixture_output/core-dlopen"
```

The test operator must confirm the owned emulator serial, page size, CPU flags,
executable hashes and library hashes before pushing files into a unique temporary
directory. Run without capability masks, provider/RNG overrides or replacement
signal handlers. Capture exit status and public JSON metadata; remove only the
owned temporary directory afterwards. The unmodified core is an expected SIGILL
negative control on the affected emulator. A repaired core must load successfully.
These probes isolate native startup; they do not replace the app UI, paired-session,
codec or APK-specific 16 KiB compatibility checks.

Sources: [OpenSSL 4.0.3 armcap.c](https://github.com/openssl/openssl/blob/openssl-4.0.3/crypto/armcap.c),
[OpenSSL ARM64 probes](https://github.com/openssl/openssl/blob/openssl-4.0.3/crypto/arm64cpuid.pl),
[Linux ARM64 hardware capabilities](https://docs.kernel.org/arch/arm64/elf_hwcaps.html),
[Android CPU features](https://developer.android.com/ndk/guides/cpu-features).
OpenSSL retains its Apache-2.0 license; the `openssl-src` builder retains its
MIT/Apache-2.0 license notices. The local recipe, patch and fixtures are covered by
the repository's MPL-2.0 license; they grant no additional rights to upstream code.
