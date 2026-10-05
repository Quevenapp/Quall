#!/bin/bash
# Por sessão: segundos em que faltou pacote (packets_missing_upper_bound subiu) e quantos deles
# NÃO subiram frames_dropped nem neste segundo nem no seguinte — a perda calada.
for R in "$@"; do
  grep -E " 1Hz " "$R" | sed -E 's/.*"frames_dropped":([0-9]+).*"packets_missing_upper_bound":([0-9]+).*/\1 \2/' | grep -E '^[0-9]+ [0-9]+$' |
  awk -v nome="$(basename "$R")" '
    { fd[NR]=$1; mi[NR]=$2 }
    END {
      ev=0; calada=0; pac=0; pcal=0
      for (i=2;i<=NR;i++) if (mi[i]>mi[i-1]) {
        ev++; d=mi[i]-mi[i-1]; pac+=d
        prox=(i<NR)?fd[i+1]:fd[i]
        if (prox==fd[i-1]) { calada++; pcal+=d }
      }
      printf "%-48s segundos_com_falta=%d calados=%d  pacotes_faltando=%d nos_calados=%d  frames_dropped=%d\n", nome, ev, calada, pac, pcal, fd[NR]
    }'
done
