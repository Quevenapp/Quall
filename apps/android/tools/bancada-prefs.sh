#!/usr/bin/env bash
#
# Escreve as preferências de bancada do app (ver `core/Bancada.kt`) num aparelho, por `run-as`.
#
#     apps/android/tools/bancada-prefs.sh <serial> <porta> <prefixo> <idr_na_perda> \
#         [intervalo_ms] [supressao_por_causa] [piso_curto_ms]
#
# `run-as` só funciona com APK de depuração — que é o único que esta bancada instala. O app é
# parado antes de escrever: `SharedPreferences` é lido uma vez e guardado em memória pelo
# processo, e trocar de braço com o app vivo mediria o braço anterior.
set -euo pipefail

SERIAL="${1:?serial do adb}"
PORTA="${2:?porta de sinalização}"
PREFIXO="${3:-aa-}"
IDR_NA_PERDA="${4:-true}"
INTERVALO="${5:-500}"
POR_CAUSA="${6:-true}"
PISO_CURTO="${7:-100}"
PKG=com.quall.android

adb -s "$SERIAL" shell am force-stop "$PKG"

XML="<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <int name=\"porta\" value=\"$PORTA\" />
    <int name=\"intervalo_minimo_idr_ms\" value=\"$INTERVALO\" />
    <int name=\"piso_primeiro_pedido_ms\" value=\"$PISO_CURTO\" />
    <boolean name=\"supressao_por_causa\" value=\"$POR_CAUSA\" />
    <boolean name=\"pedir_idr_na_perda\" value=\"$IDR_NA_PERDA\" />
    <string name=\"prefixo_nome\">$PREFIXO</string>
</map>"

# `cat >` de dentro do `run-as`: o shell do adb não tem permissão de escrever em /data/data.
adb -s "$SERIAL" shell "run-as $PKG sh -c 'mkdir -p /data/data/$PKG/shared_prefs && cat > /data/data/$PKG/shared_prefs/quall-bancada.xml'" <<XMLEOF
$XML
XMLEOF

echo "== $SERIAL =="
adb -s "$SERIAL" shell "run-as $PKG cat /data/data/$PKG/shared_prefs/quall-bancada.xml"
