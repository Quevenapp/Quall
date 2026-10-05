#!/bin/bash
# Resumo de uma corrida de `sessao-espera.sh`/`sessao-dupla.sh`, só por contador:
#   - o receptor iOS (a linha 1Hz final, as pausas por origem, as etapas, a perda calada), se houver;
#   - o Mac: captura por segundo, ociosos do ScreenCaptureKit (`sck=[1:…]`), CPU da máquina. "De
#     carga" é o segundo com 5 capturas ou mais: o monitor parado dá ~1 por segundo. O corte era 20,
#     e escondia justo os segundos em que o monitor anda na metade do ritmo (~15, sem o Sidecar);

#   - a segunda sessão, se houver (taxa, IDR, pedidos), e as duas lado a lado em blocos de 10 s.
#
#   resumo.sh target/tela-estendida/manual-<rotulo>-<hora>      (sem o .log)
set -uo pipefail
AQUI=$(cd "$(dirname "$0")" && pwd)
B=${1%.log}; L=$B.log; R=$(ls "$B"-rx-*.log 2>/dev/null | head -1); T=$(mktemp -d)
echo "== $(basename "$B")"
grep -oE "folga de exibi[^—]*" "${R:-/dev/null}" 2>/dev/null | head -1 | sed 's/^/iPhone: /'
if [ -n "$R" ]; then
  grep -E " 1Hz " "$R" | tail -1 | grep -oE 't=[0-9.]+s|idrs=[0-9]+|pedidos_idr=[0-9]+|rupturas=[0-9]+|sem_referencia_ms=\[[^]]*\]|fluidez_ms=\[[^]]*\]|trancos=[0-9]+|"packets_lost_for_real":[0-9]+|"packets_seen":[0-9]+' | paste -sd' ' - | sed 's/^/iPhone: /'
  grep -oE "pausas: .*" "$R" | tail -1 | sed 's/^/iPhone: /'
  grep -oE "etapas_ms: .*" "$R" | tail -1 | sed 's/^/iPhone: /'
  "$AQUI/perda-calada.sh" "$R" | sed -E 's/^[^ ]+ +/iPhone: /'
fi
grep -E "casca:" "$L" | grep -v "\[#" | sed -E 's/^([0-9:]+)\.[0-9]+.* capturados=([0-9]+) .*/\1 \2 &/' \
  | awk '{c=$2; ocio=0; if (match($0, /sck=\[[^]]*\]/)) {n2=split(substr($0, RSTART+5, RLENGTH-6), kv, " "); for (i=1;i<=n2;i++) {split(kv[i], p, ":"); if (p[1]=="1") ocio=p[2]}}
         if (NR>1) {d=c-pc; o=ocio-pocio; if (d>=5) {n++; sc+=d; so+=o}} pc=c; pocio=ocio}
         END {if (n) printf "Mac: %d s de carga, %.1f capturas/s, %.2f ociosos/s\n", n, sc/n, so/n}'
[ -f "$B-cpu.txt" ] && awk '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]=="total") {v=a[2]+0; s+=v; n++; if (v>m) m=v; if (v>300) alto++}}} END {if (n) printf "CPU do Mac: média %.0f%%, máx. %.0f%%, %d de %d amostras acima de 300%% (de 1000%%)\n", s/n, m, alto, n}' "$B-cpu.txt"
grep -E "\[#2\] casca:" "$L" | sed -E 's/^([0-9]+):([0-9]+):([0-9]+)\.[0-9]+.* capturados=([0-9]+) enviados=([0-9]+).* idrs=([0-9]+) idrs_forcados=([0-9]+) bytes=([0-9]+).*/\1 \2 \3 \5 \6 \7 \8/' > "$T/tab"
if [ -s "$T/tab" ]; then
  awk 'NR==1{s0=$1*3600+$2*60+$3; e0=$4; b0=$7; i0=$5; f0=$6} {s=$1*3600+$2*60+$3; e=$4; b=$7; i=$5; f=$6} END {d=s-s0; if (d>0) printf "segunda sessão: %d s, %.1f quadros/s, %.1f Mbps, %d IDR (%d pedidos)\n", d, (e-e0)/d, (b-b0)*8/d/1e6, i-i0, f-f0}' "$T/tab"
  if [ -n "$R" ]; then
    echo "-- blocos de 10 s: segunda sessão × perda do iPhone"
    awk '{s=$1*3600+$2*60+$3; if (NR>1) {b=int(s/10)*10; kb[b]+=($7-pb)/1024; idr[b]+=$5-pi; forc[b]+=$6-pf} pb=$7; pi=$5; pf=$6} END {for (b in kb) printf "%d %d %d %d\n", b, kb[b]/10, idr[b], forc[b]}' "$T/tab" | sort > "$T/bt"
    grep -E "janela_do_enlace" "$R" | sed -E 's/^[A-Za-z]+ [0-9]+ ([0-9]+):([0-9]+):([0-9]+)\.[0-9]+.* perdidos=([0-9]+) .*suspeitos=([0-9]+).*/\1 \2 \3 \4 \5/' | awk '{s=$1*3600+$2*60+$3; b=int(s/10)*10; p[b]+=$4; su[b]+=$5} END {for (b in p) printf "%d %d %d\n", b, p[b], su[b]}' | sort > "$T/bi"
    join "$T/bt" "$T/bi" | awk '{h=int($1/3600); m=int(($1%3600)/60); s=$1%60; printf "%02d:%02d:%02d  segunda %5d KB/s idr=%2d (pedidos %2d) | iPhone perdidos=%4d suspeitos=%3d\n", h,m,s,$2,$3,$4,$5,$6}'
  fi
fi
rm -rf "$T"
