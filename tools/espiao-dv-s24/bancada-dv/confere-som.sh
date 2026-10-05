#!/usr/bin/env bash
# Confere o som da fita tirado por `midia.c` contra o ffmpeg do Mac, bit a bit, em cada .dv dado.
#   confere-som.sh A.dv [B.dv ...]
set -euo pipefail
aqui="$(cd "$(dirname "$0")" && pwd)"
alvo="${QUALL_ALVO_DV:-${TMPDIR:-/tmp}/quall-dv-bancada/alvo}"
bin="$alvo/midia-mesa"
mkdir -p "$alvo"
cc -O2 -Wall -I/opt/homebrew/include "$aqui/midia-mesa.c" "$aqui/../../../apps/android/app/src/main/cpp/dv/midia.c" \
  -L/opt/homebrew/lib -lavformat -lavcodec -lavutil -o "$bin"
tmp=$(mktemp -d)
falhas=0
for dv in "$@"; do
  "$bin" "$dv" "$tmp/nosso.s16le" "$tmp/g48.s16le"
  ffmpeg -hide_banner -loglevel error -f dv -i "$dv" -map 0:a:0 -f s16le -y "$tmp/ref.s16le"
  if cmp -s "$tmp/nosso.s16le" "$tmp/ref.s16le"; then
    echo "$(basename "$dv"): bit a bit igual ao ffmpeg ($(stat -f%z "$tmp/ref.s16le") bytes)"
  else
    echo "$(basename "$dv"): DIFERENTE (nosso $(stat -f%z "$tmp/nosso.s16le"), ffmpeg $(stat -f%z "$tmp/ref.s16le"))"
    falhas=$((falhas + 1))
  fi
done
rm -rf "$tmp"
exit $falhas
