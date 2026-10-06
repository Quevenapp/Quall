#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Prefer Xcode's availability implementation over Rust std's weak fallback.
# This does not implement or call a private OS API; it links the compiler's runtime.
set -euo pipefail
RUNTIME="$(xcrun clang --print-runtime-dir)"
case "${PLATFORM_NAME:?Xcode platform}" in
    iphoneos) LIB=ios ;;
    iphonesimulator) LIB=iossim ;;
    macosx) LIB=osx ;;
    *) echo "Unsupported Xcode platform" >&2; exit 64 ;;
esac
mkdir -p "$DERIVED_FILE_DIR"
OBJECTS=()
for ARCH in ${ARCHS:?Xcode architectures}; do
    ARCHIVE="$DERIVED_FILE_DIR/quall-compiler-rt-$ARCH.a"
    OBJ="$DERIVED_FILE_DIR/quall-availability-$ARCH.o"
    lipo "$RUNTIME/libclang_rt.$LIB.a" -thin "$ARCH" -output "$ARCHIVE"
    ar -p "$ARCHIVE" os_version_check.c.o > "$OBJ"
    [ -s "$OBJ" ] || { echo "Xcode availability object absent" >&2; exit 1; }
    OBJECTS+=("$OBJ")
done
lipo -create "${OBJECTS[@]}" -output "$DERIVED_FILE_DIR/QuallAvailability.o"
