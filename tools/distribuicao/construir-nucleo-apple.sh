#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# A std oficial é reconstruída sem backtrace. A simbolização padrão examinaria
# arquivos do sistema, fora dos dados próprios autorizados por C617.1.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALVO="${1:?uso: construir-nucleo-apple.sh target}"
case "$ALVO" in
    aarch64-apple-ios|aarch64-apple-ios-sim) export IPHONEOS_DEPLOYMENT_TARGET=15.0 ;;
    aarch64-apple-darwin|x86_64-apple-darwin) export MACOSX_DEPLOYMENT_TARGET=13.0 ;;
    *) echo "ERRO: alvo Apple não suportado: $ALVO" >&2; exit 64 ;;
esac
FERRAMENTAS="${QUALL_RUST_APPLE_TOOLCHAIN:-}"
if [ -z "$FERRAMENTAS" ]; then
    CARGO_FIXO="$(rustup which --toolchain 1.98.0 cargo)"
    FERRAMENTAS="$(cd "$(dirname "$CARGO_FIXO")/.." && pwd)"
fi
case "$FERRAMENTAS" in /*) ;; *) echo "ERRO: toolchain deve ser absoluto" >&2; exit 64 ;; esac
[ "$("$FERRAMENTAS/bin/rustc" --version)" = "rustc 1.98.0 (88d9e12ae 2026-08-18)" ] || {
    echo "ERRO: a release exige compilador oficial Rust 1.98.0 / 88d9e12ae." >&2; exit 1;
}
STD="$FERRAMENTAS/lib/rustlib/src/rust/library"
[ -f "$STD/std/Cargo.toml" ] || {
    echo "ERRO: instale rust-src oficial 1.98.0 nesta mesma toolchain isolada." >&2; exit 1;
}
[ "$(shasum -a 256 "$STD/Cargo.lock" | awk '{print $1}')" = d1c5dbdf53bfebd7de60f26a171819db3b28ebfd75f3fa99c3286893a5a7b7a6 ] || {
    echo "ERRO: Cargo.lock da std diverge da fonte oficial inventariada." >&2; exit 1;
}
cd "$RAIZ"
# build-std é experimental. RUSTC_BOOTSTRAP é limitado a este processo e seus
# filhos, com compilador/fonte fixos; não muda toolchain/configuração global.
# Lista de features vazia desativa backtrace e panic-unwind. O hook do produto
# continua ativo e o perfil Release mantém panic=abort.
RUSTC_BOOTSTRAP=1 RUSTC="$FERRAMENTAS/bin/rustc" RUSTDOC="$FERRAMENTAS/bin/rustdoc" \
    DYLD_LIBRARY_PATH="$FERRAMENTAS/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    CARGO_PROFILE_RELEASE_LTO=false CMAKE_BUILD_PARALLEL_LEVEL="${QUALL_JOBS:-2}" \
    "$FERRAMENTAS/bin/cargo" -Zbuild-std=std,panic_abort -Zbuild-std-features= \
    build --locked --offline --release --target "$ALVO" -p quall-ffi -j "${QUALL_JOBS:-2}"
echo "Núcleo Apple: $ALVO; Rust 1.98.0; std sem backtrace; panic=abort"
