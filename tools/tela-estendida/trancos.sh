#!/bin/bash
# Classifica as linhas `tranco:` do receptor iOS (intervalo acima de 100 ms entre entregas à tela)
# pela origem, com a mesma régua de docs/tela-estendida.md, "De onde vêm os trancos":
#   emissor — o carimbo já veio com o buraco de 250 ms ou mais (tela parada, captura parada);
#   IDR     — o quadro atrasado é um IDR;
#   rede    — carimbo normal e chegada de 180 ms ou mais;
#   o Mac pulou captura — carimbo de 67–230 ms;
#   outro   — carimbo de 33 ms e chegada abaixo de 180 ms (tremor somado).
# Os trancos do começo e do fim da corrida (tela parada antes e depois da carga) caem em "emissor".
#   trancos.sh <registro-rx>…
for R in "$@"; do
  echo "== $(basename "$R")"
  grep -oE "tranco: .*" "$R" | awk '{for(i=2;i<=NF;i++){split($i,a,"="); gsub("ms|KB","",a[2]); v[a[1]]=a[2]}
    if (v["carimbo"]+0 >= 250) c="emissor (carimbo >= 250 ms)"; else if (v["idr"]=="sim") c="IDR";
    else if (v["chegada"]+0 >= 180) c="rede (chegada >= 180 ms, carimbo normal)";
    else if (v["carimbo"]+0 >= 60) c="Mac pulou captura (carimbo 67-230 ms)"; else c="outro (carimbo 33, chegada < 180 ms)";
    n[c]++; t[c]+=v["tela"]} END {for (c in n) printf "   %-42s %3d  (tela média %.0f ms)\n", c, n[c], t[c]/n[c]}' | sort
done
