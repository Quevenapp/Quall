#!/bin/bash
# Uma corrida com aparelho de verdade, conectado **à mão**: o Mac abre a tela estendida esperando com o
# PIN de bancada por até ESPERA segundos; quando o primeiro receptor conecta, a carga sintética roda
# CARGA segundos no monitor dele, e o Mac sai sozinho. Se o UDID de um iPhone no USB for dado, o
# registro dele (`idevicesyslog -m quall-rx`) vai junto. Amostra a CPU do Mac a cada 2 s.
#
#   sessao-espera.sh ROTULO ESPERA CARGA [UDID]
#
# Ambiente: CARGA_MODO (padrão `ca`; vazio usa o `draw` antigo, que salta no monitor virtual de 30 Hz —
# ver "A carga pelo Core Animation" em docs/tela-estendida.md; `camadas` é o app movendo camadas a cada
# quadro, como uma rolagem), EXTRA_APP (argumentos a mais para o app, ex. `--espacamento-mbps=0`), HZ
# (fixa o monitor e o fps juntos, `--tela-estendida-hz`; sem ele, o padrão do app: 30 fps de um monitor
# de 60 Hz), REDE (padrão en12), PIN (padrão 314159).
#
# ESPERA ≤ 280: a espera do Mac desiste em 5 min. O fim é abrupto — o roteiro encerra o app, e o iPhone
# mostra "o emissor encerrou"; os ~4 s de imagem parada no fim são a carga acabando antes.
set -uo pipefail
AQUI=$(cd "$(dirname "$0")" && pwd); RAIZ=$(cd "$AQUI/../.." && pwd); SAIDA=$RAIZ/target/tela-estendida
ROT=$1; ESPERA=$2; CARGA=$3; UDID=${4:-}; PIN=${PIN:-314159}; REDE=${REDE:-en12}; MODO=${CARGA_MODO-ca}
T=$(date +%H%M%S); L=$SAIDA/manual-$ROT-$T.log
mkdir -p "$SAIDA"
[ -x "$SAIDA/janela-em-movimento" ] && [ "$SAIDA/janela-em-movimento" -nt "$AQUI/janela-em-movimento.swift" ] \
  || xcrun swiftc -O "$AQUI/janela-em-movimento.swift" -o "$SAIDA/janela-em-movimento" || exit 1
if pgrep -f "MacOS/quall-monitor-virtua[l]|[Q]uall.app/Contents/MacOS" >/dev/null; then echo "!! Quall no ar"; exit 9; fi
OUV=""
if [ -n "$UDID" ] && idevice_id -l | grep -q "$UDID"; then
  idevicesyslog -u "$UDID" -m quall-rx > "$SAIDA/manual-$ROT-$T-rx-${UDID:0:8}.log" 2>&1 & OUV=$!
fi
open -n ~/Applications/Quall.app --args --registro="$L" --fonte=tela-estendida --espelhar-ja --pin="$PIN" \
  --sair-apos=$((ESPERA + CARGA + 30)) --rede="$REDE" ${HZ:+--tela-estendida-hz=$HZ} --tela-estendida=2x ${EXTRA_APP:-}
"$AQUI/cpu.sh" "$SAIDA/manual-$ROT-$T-cpu.txt" &
LIMITE=$(( $(date +%s) + ESPERA )); ID=""
while [ "$(date +%s)" -lt $LIMITE ]; do
  ID=$(grep -oE "monitor virtual: id=[0-9]+" "$L" 2>/dev/null | head -1 | cut -d= -f2); [ -n "$ID" ] && break; sleep 1
done
if [ -n "$ID" ]; then
  echo "   $(date +%H:%M:%S) conectou (monitor $ID) — carga ${MODO:-draw} por $CARGA s"
  sleep 2; "$SAIDA/janela-em-movimento" "$CARGA" 30 "$ID" $MODO > "$SAIDA/manual-$ROT-$T-janela.txt" 2>&1
  sleep 3
else echo "!! ninguém conectou em $ESPERA s"; fi
P=$(pgrep -f "Quall.app/Contents/MacOS/quall-ap[p]"); [ -n "$P" ] && kill -TERM $P
for _ in $(seq 1 20); do pgrep -f "Quall.app/Contents/MacOS/quall-ap[p]" >/dev/null || break; sleep 0.5; done
[ -n "$OUV" ] && kill $OUV 2>/dev/null; wait 2>/dev/null
echo "REGISTRO $L"
