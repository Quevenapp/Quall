#!/usr/bin/env bash
#
# CPU e memória do processo do Quall num aparelho, com a sessão de pé.
#
#     apps/android/tools/aa-consumo.sh <serial>
#
# `top -b -d 1 -n 2` e a **segunda** amostra: a primeira é acumulada desde o boot do processo e
# não diz nada sobre o que está acontecendo agora. `dumpsys meminfo` dá PSS e RSS totais, que é o
# par que importa num aparelho de 1,79 GB — RES sozinho conta páginas compartilhadas duas vezes.
set -euo pipefail

SERIAL="${1:?serial do adb}"
PKG=com.quall.android

PID="$(adb -s "$SERIAL" shell pidof "$PKG" | tr -d '\r')"
if [ -z "$PID" ]; then
  echo "o processo do $PKG não está de pé em $SERIAL" >&2
  exit 1
fi

echo "== $SERIAL · pid $PID =="
adb -s "$SERIAL" shell "top -b -d 1 -n 2 -p $PID" | tail -2
adb -s "$SERIAL" shell "dumpsys meminfo $PID" | grep -E "TOTAL PSS|TOTAL RSS|^ *TOTAL" | head -3
adb -s "$SERIAL" shell "cat /proc/meminfo" | grep -E "MemTotal|MemFree|MemAvailable"
echo "-- descarte de UDP pelo kernel (rx), enquanto recebe --"
adb -s "$SERIAL" shell "cat /proc/net/snmp" | awk '/^Udp:/{print}' | tail -2
adb -s "$SERIAL" shell "cat /proc/net/dev" | awk '/wlan0/{print "wlan0 rx_errs="$4" rx_drop="$5" tx_errs="$12" tx_drop="$13}'
