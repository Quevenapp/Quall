#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Banco de prova explícito: compila um arquivo C e carrega apenas o módulo indicado
# pelo libobs do OBS instalado. Não executa construir.sh, nem instala plugins.
set -euo pipefail
if (( $# != 2 )); then
  echo "uso: prova-compatibilidade.sh <quall-obs.plugin> <pasta nova sob /tmp>" >&2
  exit 2
fi
AQUI="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$1" && pwd)"
SAIDA="$2"
case "$SAIDA" in
  /tmp/*|/private/tmp/*) ;;
  *) echo "A saída precisa ser uma pasta nova de bancada sob /tmp." >&2; exit 2 ;;
esac
if [[ -e "$SAIDA" ]]; then
  echo "A pasta de saída já existe; use uma pasta nova para isolar a configuração." >&2
  exit 2
fi
mkdir -p "$SAIDA"
SAIDA="$(cd "$SAIDA" && pwd)"
OBS_APP="${QUALL_OBS_APP:-/Applications/OBS.app}"
LIBOBS="$OBS_APP/Contents/Frameworks/libobs.framework/Versions/A/libobs"
CABECALHOS="$AQUI/../.libobs/obs-studio/libobs"
if [[ ! -f "$PLUGIN/Contents/MacOS/quall-obs" || ! -f "$LIBOBS" ]]; then
  echo "Plugin ou libobs ausente." >&2
  exit 2
fi
mkdir "$SAIDA/gerado" "$SAIDA/config"
shasum -a 256 "$LIBOBS" "$OBS_APP/Contents/MacOS/OBS" \
  "$PLUGIN/Contents/MacOS/quall-obs" "$PLUGIN/Contents/Resources/THIRD_PARTY_NOTICES.txt" \
  > "$SAIDA/hashes.txt"
nm -gU "$PLUGIN/Contents/MacOS/quall-obs" > "$SAIDA/exports.txt"
otool -L "$PLUGIN/Contents/MacOS/quall-obs" > "$SAIDA/dependencias.txt"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OBS_APP/Contents/Info.plist" \
  > "$SAIDA/obs-versao.txt"
printf '#pragma once\n#define OBS_RELEASE_CANDIDATE 0\n#define OBS_BETA 0\n' > "$SAIDA/gerado/obsconfig.h"
cc -std=c17 -Wall -Wextra -I"$CABECALHOS" -I"$AQUI/../.libobs/simde" \
  -I"$SAIDA/gerado" "$AQUI/prova-compatibilidade.c" "$LIBOBS" \
  -Wl,-rpath,"$OBS_APP/Contents/Frameworks" -o "$SAIDA/prova-compatibilidade"
STATUS=0
"$SAIDA/prova-compatibilidade" "$PLUGIN/Contents/MacOS/quall-obs" \
  "$PLUGIN/Contents/Resources" "$SAIDA/config" > "$SAIDA/resultado.log" 2>&1 || STATUS=$?
cat "$SAIDA/resultado.log"
exit "$STATUS"
