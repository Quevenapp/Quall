#!/bin/zsh
# Build de **sonda** da extensão: mede o teto de memória e se ela consegue rede.
#
# É binário diferente do de produto de propósito. A sonda de memória aloca até 1 GB para
# descobrir onde dói — se houver teto, ela mata a extensão, e uma câmera que morre no meio não
# serve para provar nada com app de terceiro.
#
# Depois de medir, rode `./construir.sh` para voltar ao binário de produto.
set -uo pipefail
cd "$(dirname "$0")"

SAIDA="${QUALL_SAIDA:-/tmp/quall-camera-sonda}"
mkdir -p "$SAIDA"
DESDE=$(date +"%Y-%m-%d %H:%M:%S")

./construir.sh \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="SONDA_MEMORIA" \
  QUALL_ENTITLEMENTS_EXTENSAO="Fontes/Extensao/Sonda.entitlements"

echo
echo "== entitlements da extensão instalada"
codesign -d --entitlements - --xml \
  /Applications/QuallCamera.app/Contents/Library/SystemExtensions/br.com.queven.quall.camera.extensao.systemextension \
  2>/dev/null | plutil -p -

echo
echo "== acordando a extensão (abrir o fluxo de entrada lança o processo)"
/Applications/QuallCamera.app/Contents/MacOS/QuallCamera alimentar --segundos 45 > "$SAIDA/alimentacao.txt" 2>&1 &
sleep 40

echo
echo "== o que a sonda mediu"
/usr/bin/log show --info --style compact --start "$DESDE" \
  --predicate 'subsystem == "br.com.queven.quall.camera"' > "$SAIDA/log.txt" 2>&1
grep -E "SONDA|EXT " "$SAIDA/log.txt" | tail -60

wait
echo "artefatos em $SAIDA"
