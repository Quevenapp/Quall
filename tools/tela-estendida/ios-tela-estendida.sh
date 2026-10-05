#!/bin/bash
# Tela estendida do Mac -> iPhone (iOS 15/16), sem toque: o app é lançado por `idevicedebug` com
# `--endereco`/`--pin`, e o veredito sai só dos contadores do receptor (`1Hz`/`FIM`) e do emissor.
# Nada de foto, nada gravado: o conteúdo do monitor é a carga sintética nossa (`janela-em-movimento`).
#
#   ./ios-tela-estendida.sh <UDID> <rotulo>        SEG=40 HZ=30 TAM=1920x1200   (sem HZ, o padrão do app: 30 fps de um monitor de 60 Hz)
set -uo pipefail
AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
SAIDA=${SAIDA:-$RAIZ/target/tela-estendida}
mkdir -p "$SAIDA"
[ -x "$SAIDA/janela-em-movimento" ] && [ "$SAIDA/janela-em-movimento" -nt "$AQUI/janela-em-movimento.swift" ] \
  || xcrun swiftc -O "$AQUI/janela-em-movimento.swift" -o "$SAIDA/janela-em-movimento" || exit 1
UDID=$1; ROTULO=$2
SEG=${SEG:-40}; HZ=${HZ:-}; TAM=${TAM:-}; PIN=314159
T=$(date +%H%M%S)
L="$SAIDA/ios-$ROTULO-$T-mac.log"; R="$SAIDA/ios-$ROTULO-$T-rx.log"
EXTRA=(); [ -n "$TAM" ] && EXTRA=(--tela-estendida-tamanho="$TAM")

idevicesyslog -u "$UDID" -m "quall-rx" > "$R" 2>&1 &
OUV=$!
sleep 1
open -n ~/Applications/Quall.app --args --registro="$L" --fonte=tela-estendida --espelhar-ja \
  --pin=$PIN --sair-apos=$((SEG + 30)) --rede=en12 ${HZ:+--tela-estendida-hz=$HZ} --tela-estendida=2x ${EXTRA[@]+"${EXTRA[@]}"}
END=""; for _ in $(seq 1 100); do END=$(grep -oE "endereco=[0-9.]+:[0-9]+" "$L" 2>/dev/null | head -1 | cut -d= -f2); [ -n "$END" ] && break; sleep 0.2; done
[ -n "$END" ] || { echo "!! o emissor não disse o endereço"; kill $OUV; exit 1; }
echo "   emissor em $END"
idevicedebug -u "$UDID" --detach run br.com.queven.quall -- --endereco "$END" --pin $PIN --segundos $SEG --esperar 1 2>&1 | tail -1
for _ in $(seq 1 150); do grep -q "captura:" "$L" 2>/dev/null && break; sleep 0.2; done
if grep -q "captura:" "$L"; then
  sleep 3; "$SAIDA/janela-em-movimento" $((SEG - 12)) "${HZ:-60}" > /dev/null 2>&1 &
fi
for _ in $(seq 1 $((SEG + 40))); do grep -q " FIM " "$R" 2>/dev/null && break; sleep 1; done
sleep 2; kill $OUV 2>/dev/null; wait 2>/dev/null

echo "== $ROTULO — tela estendida ${TAM:-1920x1200}${HZ:+, monitor e fps a $HZ}"
grep -oE "aparelho: .*|tela: [0-9]+x[0-9]+ pt.*|APP aberto .*ip=[^ ]+|não conectou: .*|permissão de Rede Local: .*" "$R" | sed -E 's/id=ios-[0-9a-f]+/id=…/' | sort -u | head -6
grep -E " FIM " "$R" | tail -1 | grep -oE "t=[0-9.]+s|recebidos=[0-9]+|decodificados=[0-9]+|enfileirados=[0-9]+|nao_couberam=[0-9]+|falhas_sessao=[0-9]+|primeira_imagem=[^ ]+|fps=[0-9.]+|p50=[0-9.]+ms|p95=[0-9.]+ms|dim=[0-9x]+|rupturas=[0-9]+|suspeitos=[0-9]+|pior_rajada=[0-9]+|sem_referencia_ms=[^ ]+( [^ ]+)?|trancos=[0-9]+|camada=[0-9x]+|pegada=[^ ]+|perda=\[[^]]*\]" | paste -sd' ' -
grep -c " 1Hz " "$R" | sed 's/^/   linhas 1Hz: /'
grep -oE "monitor virtual: [^|]{0,120}|teto: [^|]{0,140}" "$L" | head -2 | sed -E 's/pin=[0-9]+/pin=***/'
grep -E "fim da captura" "$L" | grep -oE "capturados=[0-9]+|idrs=[0-9]+" | paste -sd' ' -
grep -E "!!" "$L" | sed -E 's/pin=[0-9]+/pin=***/' | head -3
echo "   (registros: $R  $L)"
