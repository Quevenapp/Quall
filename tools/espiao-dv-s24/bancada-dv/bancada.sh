#!/usr/bin/env bash
# Fase A do DV no S24: compila o dv-bancada (arm64) contra o FFmpeg mínimo, leva ao aparelho,
# roda e traz os PNGs.
#
#   bancada.sh compilar
#   bancada.sh rodar <serial> <amostra.dv> [args do dv-bancada...]   # PNGs em $saida
#
# Roda como o usuário do shell em /data/local/tmp/dv-bancada; não toca em app nenhum.
set -euo pipefail

aqui="$(cd "$(dirname "$0")" && pwd)"
base="${QUALL_DV_SCRATCH:-${TMPDIR:-/tmp}/quall-dv-bancada}"
alvo="${QUALL_ALVO_DV:-$base/alvo}"
ff="$alvo/ffmpeg-arm64"
ndk="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/27.2.12479018}/toolchains/llvm/prebuilt/darwin-x86_64/bin"
bin="$alvo/dv-bancada"
remoto=/data/local/tmp/dv-bancada
saida="${SAIDA:-$base/fase-a/png}"

cmd="${1:-}"; shift || true
case "$cmd" in
  compilar)
    [ -f "$ff/lib/libavcodec.so" ] || bash "$aqui/compila-ffmpeg.sh"
    "$ndk/aarch64-linux-android30-clang" -O2 -Wall -Wextra -o "$bin" "$aqui/dv-bancada.c" \
      -I"$ff/include" -L"$ff/lib" -lavcodec -lavutil -Wl,-z,max-page-size=16384
    ls -la "$bin"
    ;;
  rodar)
    s="${1:?serial}"; amostra="${2:?amostra.dv}"; shift 2
    adb -s "$s" shell mkdir -p "$remoto/png"
    adb -s "$s" push -q "$bin" "$ff/lib/libavcodec.so" "$ff/lib/libavutil.so" "$remoto/"
    adb -s "$s" push -q "$amostra" "$remoto/amostra.dv"
    adb -s "$s" shell "rm -f $remoto/png/*; cd $remoto && chmod 755 dv-bancada && LD_LIBRARY_PATH=$remoto ./dv-bancada -i amostra.dv -o png $*"
    mkdir -p "$saida"
    adb -s "$s" pull -q "$remoto/png/." "$saida/"
    ls "$saida"
    ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
