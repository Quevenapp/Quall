#!/usr/bin/env bash
# Teste de mesa do DVD para MP4 (`app/src/main/cpp/dv/dvd.c` e `desentrelaca.c`, a D1b de
# `docs/dvd-para-mp4.md`), no Mac, com ASan e UBSan: compila `teste-dvd/teste.c` com o `cc` do
# sistema e roda.
#
# Com o FFmpeg do Homebrew (a mesma série do app, 9.0; `pkg-config libavformat`) e o `ffmpeg` no
# PATH, gera dois VOB de teste (NTSC 16:9 entrelaçado com AC-3 5.1 e MP2 mono; PAL 4:3 progressivo
# com LPCM 96 kHz) e passa o caminho inteiro por eles. Sem os dois, só o croma do adapt2 (e diz).
set -euo pipefail

aqui="$(cd "$(dirname "$0")" && pwd)"
cpp="$aqui/../app/src/main/cpp/dv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}:/opt/homebrew/lib/pkgconfig"

if command -v ffmpeg >/dev/null 2>&1 && pkg-config --exists libavformat libavcodec libavutil 2>/dev/null; then
  cc -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    $(pkg-config --cflags libavformat libavcodec libavutil) \
    -o "$tmp/teste" "$aqui/teste-dvd/teste.c" "$cpp/dvd.c" "$cpp/desentrelaca.c" \
    $(pkg-config --libs libavformat libavcodec libavutil) -lpthread
  ffmpeg -v error -y -f lavfi -i testsrc2=size=720x480:rate=30000/1001 \
    -f lavfi -i "sine=f=440:r=48000,pan=5.1|c0=c0|c1=c0|c2=c0|c3=0*c0|c4=c0|c5=c0" \
    -f lavfi -i sine=f=1000:r=48000 -t 6 -map 0 -map 1 -map 2 -target ntsc-dvd -aspect 16:9 \
    -flags +ilme+ildct -vf setfield=tff -c:a:1 mp2 -b:a:1 192k "$tmp/a.vob"
  ffmpeg -v error -y -f lavfi -i testsrc2=size=720x576:rate=25 -f lavfi -i sine=f=440:r=96000 -t 4 \
    -af "pan=stereo|c0=c0|c1=c0" -target pal-dvd -aspect 4:3 -c:a pcm_dvd -ar 96000 -ac 2 "$tmp/b.vob"
  # h) um minuto de 352x240 com LPCM 48 kHz: as células do defeito do A07 (teste.c, h)
  ffmpeg -v error -y -f lavfi -i testsrc2=size=352x240:rate=30000/1001 -f lavfi -i sine=f=440:r=48000 -t 60 \
    -af "pan=stereo|c0=c0|c1=c0" -target ntsc-dvd -s 352x240 -aspect 4:3 -c:a pcm_dvd -ar 48000 -ac 2 "$tmp/h.vob"
  "$tmp/teste" "$tmp/a.vob" "$tmp/b.vob" "$tmp/h.vob"
else
  # `dvd.c` precisa dos cabeçalhos e das bibliotecas do FFmpeg: sem eles, só o desentrelaçador.
  echo "(sem o FFmpeg do Homebrew: só o croma do adapt2; a conferência do setor e o caminho ficam de fora)"
  cc -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DSO_DESENTRELACA -o "$tmp/teste" "$aqui/teste-dvd/teste.c" "$cpp/desentrelaca.c"
  "$tmp/teste"
fi
