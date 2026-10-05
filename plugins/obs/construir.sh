#!/bin/zsh
# Compila o plugin e o instala em ~/Library/Application Support/obs-studio/plugins.
#
# Não usa o `obs-plugintemplate` porque ele baixa um `libobs` pré-compilado das releases do GitHub
# e não olha para o OBS que a máquina tem. Aqui o alvo é concreto: o OBS instalado nesta bancada.
set -euo pipefail
SEM_INSTALAR=false
if [[ "${1:-}" == "--sem-instalar" ]]; then
  SEM_INSTALAR=true
  shift
fi
if (( $# )); then
  echo "uso: construir.sh [--sem-instalar]" >&2
  exit 2
fi
cd "$(dirname "$0")"

RAIZ="$(cd ../.. && pwd)"
ALVO="${QUALL_ALVO_RUST:-aarch64-apple-darwin}"
OBS_APP="${QUALL_OBS_APP:-/Applications/OBS.app}"
if [[ ! -s "$RAIZ/THIRD_PARTY_NOTICES.txt" ]]; then
  echo "THIRD_PARTY_NOTICES.txt ausente ou vazio na raiz; empacotamento interrompido." >&2
  exit 1
fi
for documento in LICENSE LICENSE-SCOPE.md; do
  if [[ ! -s "$documento" ]]; then
    echo "$documento ausente ou vazio no plugin; empacotamento interrompido." >&2
    exit 1
  fi
done
if [[ ! -s "$RAIZ/LICENSE" ]]; then
  echo "LICENSE MPL-2.0 ausente ou vazio na raiz; empacotamento interrompido." >&2
  exit 1
fi

# --- a versão do OBS instalado manda na tag dos cabeçalhos -----------------------------------------
# O OBS rejeita major/minor de API mais novos que o host, ignorando patch. Usamos a tag
# instalada para limitar diferenças, e ainda precisamos conferir carga, recursos e fluxo.
VERSAO_OBS=$(defaults read "$OBS_APP/Contents/Info.plist" CFBundleShortVersionString)
export QUALL_OBS_TAG="${QUALL_OBS_TAG:-$VERSAO_OBS}"
echo "== OBS instalado: $VERSAO_OBS (cabeçalhos na tag $QUALL_OBS_TAG)"

./buscar-libobs.sh

# **Sempre, e não só quando o `.a` falta.** O `if [[ ! -f ]]` que estava aqui custou uma medida em
# 07/09: o `.a` da árvore era de 02/09, o script o deu por bom, e o plugin saiu com um núcleo cinco
# dias velho — sem o conserto que ele deveria estar carregando. Um build que não refaz o que mudou
# não é rápido, é errado, e o `cargo` já é incremental: quando nada mudou isto custa décimos.
echo "== compilando o núcleo (LTO desligado: dívida 17)"
( cd "$RAIZ" && MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_PROFILE_RELEASE_LTO=false \
    cargo build -p quall-ffi --release --locked --jobs 2 --target "$ALVO" )

echo "== cmake"
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DQUALL_ALVO_RUST="$ALVO" \
  -DQUALL_OBS_APP="$OBS_APP" >/dev/null
cmake --build build --parallel 2

# Não instalar nem assinar um bundle que perdeu licenças/avisos depois da compilação.
cmp "$RAIZ/THIRD_PARTY_NOTICES.txt" \
    build/quall-obs.plugin/Contents/Resources/THIRD_PARTY_NOTICES.txt
for documento in LICENSE LICENSE-SCOPE.md; do
  cmp "$documento" "build/quall-obs.plugin/Contents/Resources/$documento"
done
cmp "$RAIZ/LICENSE" build/quall-obs.plugin/Contents/Resources/LICENSE-MPL-2.0.txt

if $SEM_INSTALAR; then
  echo "== compilado sem instalar: build/quall-obs.plugin"
  nm -gU build/quall-obs.plugin/Contents/MacOS/quall-obs
  exit 0
fi

DESTINO="$HOME/Library/Application Support/obs-studio/plugins"
mkdir -p "$DESTINO"
rm -rf "$DESTINO/quall-obs.plugin"
cp -R build/quall-obs.plugin "$DESTINO/"

# Assinatura ad-hoc. O OBS não exige assinatura de plugin, mas um bundle **sem** assinatura nenhuma
# pode ser barrado pelo Gatekeeper depois de atravessar quarentena — e a build local não atravessa.
codesign --force --sign - --timestamp=none "$DESTINO/quall-obs.plugin" >/dev/null 2>&1 || true

echo "== instalado em $DESTINO/quall-obs.plugin"
echo "== símbolos exportados (só os do OBS devem aparecer):"
nm -gU "$DESTINO/quall-obs.plugin/Contents/MacOS/quall-obs" | sed 's/^/   /'
