#!/bin/sh
# Compara a saida do desentrelacador Rust com uma referencia C escolhida explicitamente.
# Sem FASE_A, usa somente oito quadros sinteticos; nao abre amostras da bancada privada.
# DV_BANCADA_C=<referencia.c> [FASE_A=<pasta com .dv>] compara.sh
set -e
AQUI=$(cd "$(dirname "$0")" && pwd)
: "${DV_BANCADA_C:?informe o caminho da referencia C autorizada}"
FASE_A=${FASE_A:-}
T=$(mktemp -d "${TMPDIR:-/tmp}/quall-desentrelacador.XXXXXX")
ALVO=${CARGO_TARGET_DIR:-$T/alvo}
trap 'rm -rf "$T"' EXIT HUP INT TERM
FF=$(pkg-config --cflags --libs libavcodec libavutil)
# shellcheck disable=SC2086
clang -O2 -w -DDV_BANCADA_C="\"$DV_BANCADA_C\"" -o "$T/ref-planar" "$AQUI/ref-planar.c" $FF
(cd "$AQUI" && CARGO_TARGET_DIR="$ALVO" cargo build --release --locked --jobs 2 -q)
R="$ALVO/release/desentrelacador-arnes"
"$R" sintetico 8 "$T/sint8.yuv"
"$T/ref-planar" "$T/sint8.yuv" "$T/sint8-c.yuv"
"$R" rust "$T/sint8.yuv" "$T/sint8-rust.yuv" 2>/dev/null
cmp "$T/sint8-c.yuv" "$T/sint8-rust.yuv"
echo "sintetico: IGUAL"
echo "GOLDEN_C = $("$R" fnv "$T/sint8-c.yuv")"
[ -n "$FASE_A" ] || exit 0
for amostra in "$FASE_A"/*.dv; do
  [ -f "$amostra" ] || continue
  b=$(basename "$amostra" .dv)
  ffmpeg -hide_banner -loglevel error -i "$amostra" -f rawvideo -pix_fmt yuv411p -y "$T/$b.yuv"
  "$T/ref-planar" "$T/$b.yuv" "$T/$b-c.yuv"
  "$R" rust "$T/$b.yuv" "$T/$b-rust.yuv" 2>"$T/$b-rust.txt"
  cmp "$T/$b-c.yuv" "$T/$b-rust.yuv"
  echo "$b: IGUAL"
  rm -f "$T/$b.yuv" "$T/$b-c.yuv" "$T/$b-rust.yuv"
done
