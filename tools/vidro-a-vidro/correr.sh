#!/usr/bin/env bash
# Corrida de latência vidro a vidro — laço fechado de janela, um relógio só.
#
# Roda inteiro neste MacBook, sem câmera e sem a mão de ninguém. Captura APENAS as janelas que
# os próprios processos criam (dupla tranca: windowNumber próprio + owningApplication == getpid).
# Nada da tela do usuário entra em lugar nenhum, e nenhum quadro é gravado em disco.
#
#   uso: tools/vidro-a-vidro/correr.sh [SEGUNDOS] [DIR_DE_SAIDA]
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEGUNDOS="${1:-20}"
SAIDA="${2:-$AQUI/corridas/$(date +%Y%m%d-%H%M%S)}"

HZ_DESENHO="${HZ_DESENHO:-60}"
FPS_CAPTURA="${FPS_CAPTURA:-60}"
HZ_APRESENTACAO="${HZ_APRESENTACAO:-0}"

mkdir -p "$SAIDA"
# `sun_path` tem 104 bytes: o soquete NÃO pode morar dentro do worktree.
SOQUETE="/tmp/qv-$$.sock"

echo "== construindo =="
swift build -c release --package-path "$AQUI" >/dev/null

echo "== condição da máquina, ANTES =="
uptime | tee "$SAIDA/uptime-antes.txt"
sysctl -n hw.model machdep.cpu.brand_string hw.ncpu | tr '\n' ' ' | tee "$SAIDA/maquina.txt"; echo

echo "== corrida de ${SEGUNDOS}s -> $SAIDA =="
"$AQUI/.build/release/vidro-emissor" \
    --segundos "$SEGUNDOS" --hz-desenho "$HZ_DESENHO" --fps-captura "$FPS_CAPTURA" \
    --saida "$SAIDA" --soquete "$SOQUETE" >"$SAIDA/emissor.stdout" 2>"$SAIDA/emissor.stderr" &
PID_E=$!

# Espero o soquete existir antes de conectar; sem isso o receptor corre contra o bind.
for _ in $(seq 1 100); do [ -S "$SOQUETE" ] && break; sleep 0.1; done
if [ ! -S "$SOQUETE" ]; then
    echo "o emissor não criou o soquete; abortando" >&2
    kill "$PID_E" 2>/dev/null || true
    cat "$SAIDA/emissor.stderr" >&2
    exit 1
fi

"$AQUI/.build/release/vidro-receptor" \
    --saida "$SAIDA" --soquete "$SOQUETE" --hz-apresentacao "$HZ_APRESENTACAO" \
    >"$SAIDA/receptor.stdout" 2>"$SAIDA/receptor.stderr" &
PID_R=$!

set +e
wait "$PID_E"; SAIU_E=$?
wait "$PID_R"; SAIU_R=$?
set -e

echo "== condição da máquina, DEPOIS =="
uptime | tee "$SAIDA/uptime-depois.txt"

echo "emissor saiu com $SAIU_E · receptor saiu com $SAIU_R"
cat "$SAIDA/emissor.stdout" "$SAIDA/receptor.stdout" 2>/dev/null || true
[ -s "$SAIDA/emissor.stderr" ] && { echo "-- emissor stderr --"; cat "$SAIDA/emissor.stderr"; }
[ -s "$SAIDA/receptor.stderr" ] && { echo "-- receptor stderr --"; cat "$SAIDA/receptor.stderr"; }

rm -f "$SOQUETE"
python3 "$AQUI/juntar.py" "$SAIDA" --json "$SAIDA/resumo.json"
