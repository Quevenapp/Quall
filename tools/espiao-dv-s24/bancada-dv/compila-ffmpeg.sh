#!/usr/bin/env bash
# FFmpeg mínimo para o DV no Android arm64: só o decodificador `dvvideo`, `libavcodec.so` +
# `libavutil.so`, LGPL (sem --enable-gpl nem nonfree), ligado dinamicamente.
#
# O fonte é o tarball oficial, fixado em 9.0.1 (a mesma versão do `ffmpeg` do Mac que gera as
# referências). sha256 do ffmpeg-9.0.1.tar.xz:
#   cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
# Saídas em quall-scratch (QUALL_ALVO_DV), nunca no disco do sistema.
set -euo pipefail

versao=9.0.1
soma=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
base="${QUALL_DV_SCRATCH:-${TMPDIR:-/tmp}/quall-dv-bancada}"
alvo="${QUALL_ALVO_DV:-$base/alvo}"
fonte="$base/ffmpeg"
prefixo="$alvo/ffmpeg-arm64"
ndk="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/27.2.12479018}/toolchains/llvm/prebuilt/darwin-x86_64/bin"

mkdir -p "$fonte"
tar_xz="$fonte/ffmpeg-$versao.tar.xz"
[ -f "$tar_xz" ] || curl -sfL -o "$tar_xz" "https://ffmpeg.org/releases/ffmpeg-$versao.tar.xz"
echo "$soma  $tar_xz" | shasum -a 256 -c -
[ -d "$fonte/ffmpeg-$versao" ] || tar -C "$fonte" -xf "$tar_xz"

obra="$alvo/ffmpeg-obra"
mkdir -p "$obra"
cd "$obra"
"$fonte/ffmpeg-$versao/configure" \
  --prefix="$prefixo" \
  --target-os=android --arch=aarch64 --enable-cross-compile \
  --cc="$ndk/aarch64-linux-android30-clang" \
  --cxx="$ndk/aarch64-linux-android30-clang++" \
  --ar="$ndk/llvm-ar" --nm="$ndk/llvm-nm" --ranlib="$ndk/llvm-ranlib" --strip="$ndk/llvm-strip" \
  --disable-everything --disable-autodetect --enable-decoder=dvvideo \
  --disable-programs --disable-avformat --disable-swscale --disable-swresample \
  --disable-avfilter --disable-avdevice --disable-network --disable-doc \
  --enable-shared --disable-static --enable-pic --enable-neon --disable-debug \
  --extra-ldflags="-Wl,-z,max-page-size=16384" \
  | awk '/^License:|^Enabled decoders|^dvvideo|^External/ {print} /^Enabled decoders/ {getline; print}'
make -j"${QUALL_BUILD_JOBS:-2}" >/dev/null
make install >/dev/null
"$ndk/llvm-strip" --strip-unneeded "$prefixo"/lib/libavcodec.so "$prefixo"/lib/libavutil.so
ls -la "$prefixo"/lib/*.so
