#!/bin/bash
# Como `sessao-espera.sh`, mas com a carga sintética também no monitor da **segunda** sessão, assim que
# ela aparecer — para comparar dois receptores lado a lado com o mesmo conteúdo.
#
#   sessao-dupla.sh ROTULO ESPERA CARGA [UDID]
#
# Mesmo ambiente de `sessao-espera.sh`. O registro do segundo receptor, se for Android, vem pelo
# `adb logcat -s QuallReceptor`, a cargo de quem chama.
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
  sleep 2; FIM=$(( $(date +%s) + CARGA ))
  "$SAIDA/janela-em-movimento" "$CARGA" 30 "$ID" $MODO > "$SAIDA/manual-$ROT-$T-janela.txt" 2>&1 & J1=$!
  ID2=""
  while [ "$(date +%s)" -lt $FIM ]; do
    ID2=$(grep -oE "\[#2\] monitor virtual: id=[0-9]+" "$L" 2>/dev/null | head -1 | cut -d= -f2); [ -n "$ID2" ] && break; sleep 1
  done
  J2=""
  if [ -n "$ID2" ]; then
    sleep 2; RESTA=$(( FIM - $(date +%s) ))
    if [ $RESTA -gt 5 ]; then
      echo "   $(date +%H:%M:%S) segunda sessão (monitor $ID2) — carga por $RESTA s"
      "$SAIDA/janela-em-movimento" "$RESTA" 30 "$ID2" $MODO > "$SAIDA/manual-$ROT-$T-janela2.txt" 2>&1 & J2=$!
    fi
  fi
  wait $J1; [ -n "$J2" ] && wait $J2
  sleep 3
else echo "!! ninguém conectou em $ESPERA s"; fi
P=$(pgrep -f "Quall.app/Contents/MacOS/quall-ap[p]"); [ -n "$P" ] && kill -TERM $P
for _ in $(seq 1 20); do pgrep -f "Quall.app/Contents/MacOS/quall-ap[p]" >/dev/null || break; sleep 0.5; done
[ -n "$OUV" ] && kill $OUV 2>/dev/null; wait 2>/dev/null
echo "REGISTRO $L"
