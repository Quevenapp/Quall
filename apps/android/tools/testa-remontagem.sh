#!/usr/bin/env bash
# Teste de mesa da remontagem UVC da câmera DV e da placa de captura (`app/src/main/cpp/dv/
# remontagem.c`), no Mac, sem USB nem FFmpeg do Android: compila `teste-remontagem/teste.c` com o
# `cc` do sistema, com ASan e UBSan, e roda. Com o `ffmpeg` do Mac no PATH, gera dois JPEG de
# verdade (4:2:2 e 4:2:0, 640x480) para a caminhada do `jpeg_fim` atravessar; sem ele, só os
# sintéticos (e diz).
set -euo pipefail

aqui="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cc -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
  -o "$tmp/teste" "$aqui/teste-remontagem/teste.c" "$aqui/../app/src/main/cpp/dv/remontagem.c"

jpegs=()
if command -v ffmpeg >/dev/null 2>&1; then
  for pf in yuvj422p yuvj420p; do
    ffmpeg -v error -f lavfi -i testsrc2=size=640x480:rate=1 -frames:v 1 -pix_fmt "$pf" -q:v 3 \
      "$tmp/$pf.jpg"
    jpegs+=("$tmp/$pf.jpg")
  done
else
  echo "(sem ffmpeg no PATH: só os JPEG sintéticos)"
fi

"$tmp/teste" ${jpegs[@]+"${jpegs[@]}"}
