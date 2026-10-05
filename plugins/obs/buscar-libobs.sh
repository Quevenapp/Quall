#!/bin/zsh
# Busca os cabeçalhos do libobs numa **tag fixa**, com checkout esparso só de `libobs/`.
#
# Por que não o `obs-plugintemplate` inteiro: ele baixa um pacote pré-compilado de `libobs` das
# releases do GitHub e o casa com um OBS que a máquina talvez nem tenha. Aqui a bancada tem um OBS
# instalado e concreto — 32.2.2 —, e a única coisa que falta dele são os cabeçalhos: o
# `OBS.app/Contents/Frameworks/libobs.framework` traz a biblioteca e nenhum `.h`.
#
# A tag precisa casar com o OBS instalado. O `LIBOBS_API_VER` que o módulo devolve é conferido pelo
# OBS no carregamento: major/minor mais novos que o host são recusados; patch é ignorado.
# O `construir.sh` usa a tag instalada antes de compilar; a compatibilidade exige prova de carga.
set -euo pipefail
cd "$(dirname "$0")"

TAG="${QUALL_OBS_TAG:-32.2.2}"
DESTINO=".libobs"

if [[ -f "$DESTINO/.tag" && "$(cat "$DESTINO/.tag")" == "$TAG" ]]; then
  echo "== cabeçalhos do libobs $TAG já estão em $DESTINO"
  exit 0
fi

if [[ "${QUALL_OFFLINE:-0}" == "1" ]]; then
  echo "Cabeçalhos libobs $TAG ausentes no cache; permita rede explicitamente para obtê-los." >&2
  exit 1
fi

rm -rf "$DESTINO"
mkdir -p "$DESTINO"
cd "$DESTINO"

# `--filter=blob:none --sparse` traz só a árvore; os blobs de `libobs/` vêm no `sparse-checkout`.
# Um clone cheio do obs-studio passa de 400 MB e nós queremos sete diretórios de cabeçalho.
git clone --depth 1 --branch "$TAG" --filter=blob:none --sparse \
  https://github.com/obsproject/obs-studio obs-studio >/dev/null 2>&1
git -C obs-studio sparse-checkout set libobs >/dev/null

# **simde**, e ele não é opcional. `libobs/util/sse-intrin.h` inclui `<simde/x86/sse2.h>` no arm64,
# e esse cabeçalho chega a qualquer arquivo que inclua `obs.h` — por `vec4.h`. No build do próprio
# OBS ele vem do pacote `obs-deps` pré-compilado; aqui, do repositório dele, só os cabeçalhos.
SIMDE_TAG="${QUALL_SIMDE_TAG:-v0.8.2}"
git clone --depth 1 --branch "$SIMDE_TAG" --filter=blob:none --sparse \
  https://github.com/simd-everywhere/simde simde >/dev/null 2>&1
git -C simde sparse-checkout set simde >/dev/null

echo "$TAG" > .tag
echo "== cabeçalhos do libobs $TAG e simde $SIMDE_TAG em $(pwd)"
