#!/bin/bash
# Vários receptores de sonda no próprio Mac contra a tela estendida do Quall do Mac: cada sonda diz
# a tela de um aparelho (`--tela`), e o Mac tem de abrir uma espera por vez, criar um monitor por
# receptor no formato dele e transmitir os N fluxos juntos. Mede captura + codificação de N fluxos
# no M4 e o monitor por aparelho.
#
# Só contador. A carga de cada monitor é nossa (`janela-em-movimento`), nada da vida do usuário.
#
#   N=3 SEG=40 HZ=30 TELAS="1200x1920 1125x2436 720x1520" ./laco-varios.sh
#
# `ESCALA=1x|2x` (2x por padrão) vai como `--tela-estendida`: a corrida não herda a escala escolhida na
# tela inicial do app. `HZ` fixa o monitor e o fps juntos (`--tela-estendida-hz`); sem ele, o padrão do
# app — 30 fps de um monitor de 60 Hz. `CARGA_MODO` vai para a carga (`ca`, `camadas`, `leve`; vazio é
# o `draw`). `MOVENDO=K`: só os K primeiros monitores recebem a carga, os outros ficam parados — o uso
# comum de monitor é janela parada (usuário, 11/09).
set -uo pipefail
AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
SAIDA=${SAIDA:-$RAIZ/target/tela-estendida}
mkdir -p "$SAIDA"
[ -x "$SAIDA/janela-em-movimento" ] && [ "$SAIDA/janela-em-movimento" -nt "$AQUI/janela-em-movimento.swift" ] \
  || xcrun swiftc -O "$AQUI/janela-em-movimento.swift" -o "$SAIDA/janela-em-movimento" || exit 1
PROBE=$RAIZ/target/release/quall-probe
N=${N:-3}; SEG=${SEG:-40}; HZ=${HZ:-}; PIN=314159
read -r -a TELAS <<< "${TELAS:-1200x1920 1125x2436 720x1520}"
IP=$(ipconfig getifaddr en12)
[ -n "$IP" ] || { echo "!! en12 sem endereço"; exit 1; }
T=$(date +%H%M%S)
L="$SAIDA/laco-varios-$T.log"

open -n ~/Applications/Quall.app --args --registro="$L" --fonte=tela-estendida --espelhar-ja --pin=$PIN \
  --sair-apos=$((SEG + 20 + N * 10)) --rede=en12 ${HZ:+--tela-estendida-hz=$HZ} --tela-estendida=${ESCALA:-2x} ${EXTRA_APP:-}

prefixo() { [ "$1" = 1 ] && echo "" || echo "\[#$1\] "; }
for i in $(seq 1 "$N"); do
  P=$(prefixo "$i")
  PORTA=""
  for _ in $(seq 1 150); do
    PORTA=$(grep -E "^[0-9:.]+  ${P}espelhar:" "$L" 2>/dev/null | head -1 | grep -oE "porta=[0-9]+" | cut -d= -f2)
    [ -n "$PORTA" ] && break; sleep 0.2
  done
  [ -n "$PORTA" ] || { echo "!! a espera $i não abriu"; break; }
  TELA=${TELAS[$(( (i - 1) % ${#TELAS[@]} ))]}
  echo "   receptor $i: $IP:$PORTA, tela $TELA"
  "$PROBE" receber-video --ip "$IP:$PORTA" --pin $PIN --id "sonda-tela-$i" --nome "Sonda $i" \
    --tela "$TELA" --saida /dev/null --segundos "$SEG" > "$SAIDA/laco-varios-$T-sonda-$i.txt" 2>&1 &
  ID=""
  for _ in $(seq 1 100); do
    ID=$(grep -E "^[0-9:.]+  ${P}monitor virtual: id=" "$L" 2>/dev/null | head -1 | grep -oE "id=[0-9]+" | head -1 | cut -d= -f2)
    [ -n "$ID" ] && break; sleep 0.2
  done
  if [ -n "$ID" ] && [ "$i" -gt "${MOVENDO:-$N}" ]; then
    echo "   receptor $i: monitor parado (MOVENDO=$MOVENDO)"
  elif [ -n "$ID" ]; then
    sleep 2; "$SAIDA/janela-em-movimento" $((SEG - 8)) "${HZ:-60}" "$ID" ${CARGA_MODO:-} > "$SAIDA/laco-varios-$T-janela-$i.txt" 2>&1 &
  else
    echo "!! o monitor do receptor $i não apareceu no registro"
  fi
  sleep 2
done
wait
for _ in $(seq 1 60); do grep -q "saindo" "$L" 2>/dev/null && break; sleep 1; done

echo "== $N receptores, ${HZ:+monitor e fps a $HZ, }telas ${TELAS[*]}"
for i in $(seq 1 "$N"); do
  P=$(prefixo "$i")
  echo "-- receptor $i"
  grep -E "^[0-9:.]+  ${P}(tracks:|monitor virtual: id|captura:|fim da captura)" "$L" \
    | sed -E 's/^[0-9:.]+  //; s/ — criado em.*(nasceu [^|]*)\|/ … \1|/; s/pin=[0-9]+/pin=***/' | cut -c1-200
  grep -E "^[0-9:.]+  ${P}casca:" "$L" | tail -1 | grep -oE "capturados=[0-9]+|enviados=[0-9]+|latencia_media_ms=[0-9.]+|idrs=[0-9]+" | paste -sd' ' -
  grep -E "quadros gravados|IDR  |perd|fps" "$SAIDA/laco-varios-$T-sonda-$i.txt" | head -4 | sed 's/^/   sonda: /'
done
grep -E "!!|reaberta|desisto" "$L" | sed -E 's/pin=[0-9]+/pin=***/' | head -8
echo "   (registro: $L)"
