#!/bin/bash
# Amostra a CPU do Mac a cada 2 s enquanto o quall-app vive: o total da máquina (soma do `ps`, de
# 100 % por núcleo — o M4 tem 10), o app, o WindowServer e quantos auxiliares de monitor há. Só
# contador. O total existe porque em 11/09 outro projeto (um `node`) pôs a máquina em 99 % no meio de
# uma medida, e só o app e o WindowServer não o mostravam.
#   cpu.sh ARQUIVO
OUT=$1; : > "$OUT"
for _ in $(seq 1 30); do P=$(pgrep -f "Quall.app/Contents/MacOS/quall-ap[p]" | head -1); [ -n "$P" ] && break; sleep 1; done
[ -n "$P" ] || exit 0
W=$(pgrep -x WindowServer | head -1)
while kill -0 "$P" 2>/dev/null; do
  echo "$(date +%H:%M:%S) total=$(ps -A -o %cpu= | awk '{s+=$1} END{print int(s)}') app=$(ps -o %cpu= -p "$P" | tr -d ' ') ws=$(ps -o %cpu= -p "$W" | tr -d ' ') aux=$(pgrep -f 'MacOS/quall-monitor-virtua[l]' | wc -l | tr -d ' ')" >> "$OUT"
  sleep 2
done
