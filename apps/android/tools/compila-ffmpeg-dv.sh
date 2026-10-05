#!/usr/bin/env bash
# FFmpeg mínimo da câmera DV (filmadora por USB), arm64, LGPL 2.1+ (sem --enable-gpl nem nonfree),
# ligado dinamicamente: os decodificadores `dvvideo` (a filmadora DV) e `mjpeg` (a placa de captura
# USB, `docs/placa-de-captura-usb.md` §3.5) (`libavcodec.so` + `libavutil.so`), e a
# `libavformat.so` só com o demuxer `dv` (o som da fita), o muxer `mp4` (a gravação, com
# `hybrid_fragmented`) e o demuxer `mov` (fechar uma gravação interrompida, remontando o MP4).
#
# **O DVD para MP4** (`docs/dvd-para-mp4.md` §2.4, a D1a): o demuxer `mpegps` (o VOB), os parsers
# `mpegvideo`, `ac3` e `mpegaudio`, e os decodificadores `mpeg2video`, `ac3`, `mp2` e `pcm_dvd`. E
# o demuxer `mpegvideo`, que não estava no desenho: o `mpegps` cria o fluxo de vídeo (0x1E0) com
# `request_probe`, e quem diz "é MPEG-2" é a sonda do demuxer `mpegvideo` (`libavformat/demux.c`,
# `fmt_id_type`); sem ele, o fluxo fica sem codec e sem parser. O DTS, o MLP e as legendas não
# entram (o desenho, §2.1 e §2.3).
#
# Saída: `app/src/main/jniLibsDv/lib/arm64-v8a/lib{avcodec,avutil,avformat}.so` e os cabeçalhos em
# `app/src/main/jniLibsDv/include/` (a pasta é ignorada pelo Git, como `jniLibs/`). Sem ela o app
# compila do mesmo jeito, e a DV aparece como indisponível (ver `cpp/CMakeLists.txt`).
#
# A licença da dependência: a `.so` vai separada e substituível. A tela
# "Licenças de terceiros" diz a versão e oferece o fonte, e este script e a linha do `configure`
# são o que se entrega a quem quiser recompilar. Não aplique remendo no fonte: a oferta diz "sem
# modificação".
#
# O tarball é o oficial, fixado pela soma abaixo. Ele é baixado uma vez para o cache
# (QUALL_FFMPEG_CACHE); com o cache quente, o script roda sem rede. Não refaz nada se a versão já
# estiver construída.
set -euo pipefail

versao=9.0.1
soma=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635

aqui="$(cd "$(dirname "$0")" && pwd)"
app="$aqui/../app/src/main/jniLibsDv"
ndk_home="${ANDROID_NDK_HOME:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/ndk/27.2.12479018}"
raiz="$(cd "$aqui/../../.." && pwd)"
cache="${QUALL_FFMPEG_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/quall/ffmpeg}"
obra="${QUALL_FFMPEG_OBRA:-${TMPDIR:-/tmp}/quall-ffmpeg-android-$UID}"
jobs="${QUALL_BUILD_JOBS:-2}"
case "$jobs" in ''|*[!0-9]*|0) echo "QUALL_BUILD_JOBS deve ser inteiro positivo" >&2; exit 2;; esac
# Antes de apagar a obra, rejeita caminhos que contenham ou estejam dentro de fontes, cache,
# SDK/NDK ou da pasta pessoal. Caminhos são resolvidos para detectar aliases/symlinks.
python3 - "$obra" "$raiz" "$cache" "$ndk_home" "$HOME" <<'PY_GUARD'
import sys
from pathlib import Path
work = Path(sys.argv[1]).expanduser().resolve()
protected = [Path(v).expanduser().resolve() for v in sys.argv[2:] if v]
shared_temp_roots = {Path(v).expanduser().resolve() for v in ("/tmp", __import__("os").environ.get("TMPDIR", "/tmp"))}
if work in shared_temp_roots or work == Path(work.anchor) or any(work == p or work in p.parents for p in protected):
    raise SystemExit("QUALL_FFMPEG_OBRA não pode conter fontes/cache/SDK/pasta pessoal")
if any(p in work.parents for p in protected[:3]):
    raise SystemExit("QUALL_FFMPEG_OBRA deve ficar fora das fontes/cache/SDK")
PY_GUARD
case "$(uname -s)" in
  Darwin) host=darwin-x86_64 ;;
  Linux) host=linux-x86_64 ;;
  *) echo "host não suportado" >&2; exit 1 ;;
esac
ndk="$ndk_home/toolchains/llvm/prebuilt/$host/bin"
carimbo="$app/.versao"
# O carimbo leva a soma deste script: mudar a linha do `configure` reconstrói.
esperado="ffmpeg-$versao dvvideo+mjpeg+dvd arm64 lgpl ndk-$(basename "$ndk_home") script-$(shasum -a 256 "$0" | cut -c1-12)"

if [ -f "$carimbo" ] && [ "$(cat "$carimbo")" = "$esperado" ] \
   && [ -f "$app/lib/arm64-v8a/libavcodec.so" ] && [ -f "$app/lib/arm64-v8a/libavutil.so" ] \
   && [ -f "$app/lib/arm64-v8a/libavformat.so" ]; then
  echo "FFmpeg da DV já construído ($esperado)"
  exit 0
fi

mkdir -p "$cache"
tar_xz="$cache/ffmpeg-$versao.tar.xz"
if [ ! -f "$tar_xz" ]; then
  if [ "${QUALL_OFFLINE:-0}" = 1 ]; then
    echo "Tarball ausente no cache; forneça QUALL_FFMPEG_CACHE ou permita download com QUALL_OFFLINE=0" >&2
    exit 1
  fi
  curl -sfL -o "$tar_xz.parcial" "https://ffmpeg.org/releases/ffmpeg-$versao.tar.xz"
  mv "$tar_xz.parcial" "$tar_xz"
fi
echo "$soma  $tar_xz" | shasum -a 256 -c -

if [ -e "$obra" ] && [ ! -f "$obra/.quall-ffmpeg-work" ]; then
  echo "Obra existente sem marcador Quall; escolha outra QUALL_FFMPEG_OBRA" >&2
  exit 1
fi
rm -rf "$obra"
mkdir -p "$obra/fonte" "$obra/build"
printf '%s\n' 'Quall FFmpeg temporary build directory' > "$obra/.quall-ffmpeg-work"
tar -C "$obra/fonte" -xf "$tar_xz"
fonte="$obra/fonte/ffmpeg-$versao"
prefixo="$obra/prefixo"
cd "$obra/build"
"$fonte/configure" \
  --prefix="$prefixo" \
  --target-os=android --arch=aarch64 --enable-cross-compile \
  --cc="$ndk/aarch64-linux-android30-clang" \
  --cxx="$ndk/aarch64-linux-android30-clang++" \
  --ar="$ndk/llvm-ar" --nm="$ndk/llvm-nm" --ranlib="$ndk/llvm-ranlib" --strip="$ndk/llvm-strip" \
  --disable-everything --disable-autodetect --enable-decoder=dvvideo --enable-decoder=mjpeg \
  --enable-avformat --enable-demuxer=dv --enable-demuxer=mov --enable-muxer=mp4 \
  --enable-demuxer=mpegps --enable-demuxer=mpegvideo \
  --enable-parser=mpegvideo --enable-parser=ac3 --enable-parser=mpegaudio \
  --enable-decoder=mpeg2video --enable-decoder=ac3 --enable-decoder=mp2 --enable-decoder=pcm_dvd \
  --disable-programs --disable-swscale --disable-swresample \
  --disable-avfilter --disable-avdevice --disable-network --disable-doc \
  --enable-shared --disable-static --enable-pic --enable-neon --disable-debug \
  --extra-ldflags="-Wl,-z,max-page-size=16384" >/dev/null
grep -q '^#define CONFIG_GPL 0' config.h || { echo "configure saiu com GPL" >&2; exit 1; }
grep -q '^#define CONFIG_NONFREE 0' config.h || { echo "configure saiu com nonfree" >&2; exit 1; }
make -j"$jobs" >/dev/null
make install >/dev/null
# O que o DVD precisa saiu mesmo (um `--enable-*` com nome errado passa calado pelo configure; os
# componentes ficam em `config_components.h`, e não no `config.h`).
for c in MPEGPS_DEMUXER MPEGVIDEO_DEMUXER MPEGVIDEO_PARSER AC3_PARSER MPEGAUDIO_PARSER \
         MPEG2VIDEO_DECODER AC3_DECODER MP2_DECODER PCM_DVD_DECODER; do
  grep -q "^#define CONFIG_$c 1" config_components.h || { echo "configure saiu sem $c" >&2; exit 1; }
done

rm -rf "$app"
mkdir -p "$app/lib/arm64-v8a" "$app/include"
cp "$prefixo/lib/libavcodec.so" "$prefixo/lib/libavutil.so" "$prefixo/lib/libavformat.so" "$app/lib/arm64-v8a/"
"$ndk/llvm-strip" --strip-unneeded "$app/lib/arm64-v8a/libavcodec.so" "$app/lib/arm64-v8a/libavutil.so" \
  "$app/lib/arm64-v8a/libavformat.so"
cp -R "$prefixo/include/libavcodec" "$prefixo/include/libavutil" "$prefixo/include/libavformat" "$app/include/"
# O texto da LGPL que a tela "Licenças de terceiros" mostra é versionado em
# `app/src/main/assets/licencas/LGPL-2.1.txt`; confere que é o do tarball.
cmp -s "$fonte/COPYING.LGPLv2.1" "$aqui/../app/src/main/assets/licencas/LGPL-2.1.txt" \
  || { echo "assets/licencas/LGPL-2.1.txt difere do COPYING.LGPLv2.1 do tarball" >&2; exit 1; }
# O SONAME tem de ser o nome do arquivo (o Android não segue links versionados dentro do APK).
for so in libavcodec.so libavutil.so libavformat.so; do
  "$ndk/llvm-readelf" -d "$app/lib/arm64-v8a/$so" | grep -q "SONAME.*\[$so\]" \
    || { echo "SONAME de $so não é $so" >&2; exit 1; }
done
echo "$esperado" > "$carimbo"
ls -la "$app/lib/arm64-v8a"
