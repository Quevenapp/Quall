#!/bin/bash
# **O empacotador de desenvolvimento e de bancada** (o `empacotar.sh` de antes da preparação pública):
# monta `apps/macos/.build/Quall.app`, sem sandbox, que é o que os roteiros de `Bancada/` abrem. O
# `empacotar.sh` de agora monta o pacote da loja (`empacotar-store.sh`), e a bancada ficou abrindo
# um `.build/Quall.app` velho sem perceber (07/10).
# Monta e assina `Quall.app` a partir do binário que o SwiftPM produz.
#
# Por que existe um script em vez de `swift build` e pronto: o SwiftPM produz um executável solto,
# e um executável solto **não é o produto** neste caso específico. O TCC do macOS atribui cada
# pedido de permissão ao *processo responsável*; um binário aberto por `exec` de um shell herda o
# responsável de quem abriu o shell — o Terminal, ou o agente de bancada — e o diálogo sai com o
# nome errado. Dentro de um `.app` aberto pelo LaunchServices, o app é o próprio responsável e a
# linha em Ajustes do Sistema > Privacidade e Segurança sai com o nome dele.
#
# Uso:
#   apps/macos/Empacotar/empacotar.sh              # assina com a primeira identidade Apple Development
#   QUALL_IDENTIDADE="Apple Development: Fulano (XXXX)" apps/macos/Empacotar/empacotar.sh
#   QUALL_IDENTIDADE=- apps/macos/Empacotar/empacotar.sh   # ad-hoc; ver o aviso sobre TCC abaixo
#
# Depois:
#   open -n -W -a apps/macos/.build/Quall.app --args ...   # `-n` é obrigatório, ver README

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS="$(cd "$AQUI/.." && pwd)"
RAIZ="$(cd "$MACOS/../.." && pwd)"
APP="$MACOS/.build/Quall.app"

echo "==> raiz do repositório: $RAIZ"

# 1. O `.a` do núcleo. LTO desligado pela dívida 17: com `lto = "thin"` o `nm` da Apple não
#    consegue ler os símbolos de um `.a` que vai ser linkado por fora do cargo.
#    `MACOSX_DEPLOYMENT_TARGET` alinhado com o `LSMinimumSystemVersion` do Info.plist — sem isso
#    o linker avisa que os objetos do OpenSSL foram construídos para uma versão mais nova do que
#    a que está sendo linkada, e o `.app` só rodaria na versão do macOS que o construiu.
#
#    **Sempre, e não só quando o `.a` some.** A guarda `if [ ! -f ... ]` que estava aqui é o mesmo
#    defeito que `8759b0f` tirou do `construir.sh` e do `construir.ps1` do plugin do OBS em
#    07/09/2026: o `.a` de 02/09 sobrevivia a toda mudança no núcleo, e um `empacotar.sh` sozinho
#    embutia um núcleo velho no `.app` sem dizer nada. A medida seguinte então mede o núcleo
#    errado e diz que o conserto não funcionou. O cargo já não refaz o que não mudou — o custo de
#    perguntar é inferior a um segundo, e o custo de não perguntar é uma corrida inteira.
echo "==> compilando o núcleo (libquall.a)"
(cd "$RAIZ" && MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_PROFILE_RELEASE_LTO=false \
    cargo build --release -p quall-ffi)

# 2. Os binários Swift: o app e o auxiliar da tela estendida.
#
#    O auxiliar (`quall-monitor-virtual`) é o processo que **é** o monitor da tela estendida — um
#    por sessão; ver `Sources/quall-monitor-virtual/main.swift`. Sem ele dentro do `.app` a linha
#    "Tela estendida" simplesmente não aparece no seletor, sem erro nenhum. Por isso ele é
#    conferido aqui, e não descoberto na bancada.
echo "==> swift build -c release --product quall-app --product quall-monitor-virtual"
(cd "$MACOS" && swift build -c release --product quall-app)
# O auxiliar saiu do pacote na preparação pública (a tela estendida do Mac está em `Futuro/`): só
# entra quando o produto existe.
if grep -q '"quall-monitor-virtual"' "$MACOS/Package.swift"; then
    (cd "$MACOS" && swift build -c release --product quall-monitor-virtual)
fi

BINARIO="$MACOS/.build/release/quall-app"
[ -x "$BINARIO" ] || { echo "ERRO: $BINARIO não saiu do build"; exit 1; }
AUXILIAR="$MACOS/.build/release/quall-monitor-virtual"
[ -x "$AUXILIAR" ] || AUXILIAR=""

# 3. A estrutura do bundle.
echo "==> montando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARIO" "$APP/Contents/MacOS/quall-app"
[ -n "$AUXILIAR" ] && cp "$AUXILIAR" "$APP/Contents/MacOS/quall-monitor-virtual"
cp "$AQUI/Info.plist" "$APP/Contents/Info.plist"
# O ícone (`Quall.icns`, gerado por `tools/icones/gerar.py`; o `Info.plist` o nomeia em `CFBundleIconFile`).
cp "$AQUI/Quall.icns" "$APP/Contents/Resources/Quall.icns"
# A tradução (`docs/traducao.md`, "macOS"): o pacote de recursos do `QuallIdiomaKit`, com a tabela
# inglesa, sai do SwiftPM ao lado do binário e entra em `Contents/Resources`, onde o app o procura
# (`Traducoes.pacote`). Sem ele o app abre só em português, sem erro nenhum — por isso é conferido
# aqui, e não descoberto na bancada. E as frases dos diálogos de permissão nas duas línguas
# (`pt.lproj`/`en.lproj`, `InfoPlist.strings`), que o macOS escolhe pelo idioma do app.
RECURSOS="$(dirname "$BINARIO")/QuallCapture_QuallIdiomaKit.bundle"
[ -d "$RECURSOS" ] || { echo "ERRO: $RECURSOS não saiu do build (a tradução)"; exit 1; }
cp -R "$RECURSOS" "$APP/Contents/Resources/"
cp -R "$AQUI/pt.lproj" "$AQUI/en.lproj" "$APP/Contents/Resources/"
TABELA="$(find "$APP/Contents/Resources/QuallCapture_QuallIdiomaKit.bundle" -path '*en.lproj/Localizable.strings' | head -1)"
[ -n "$TABELA" ] || { echo "ERRO: a tabela inglesa não está dentro do .app"; exit 1; }
echo "==> tradução: $(plutil -convert json -o - "$TABELA" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') frases em inglês"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 4. Assinatura.
#
#    **Identidade estável importa mais do que parece.** O TCC guarda a concessão contra a
#    identidade do código: com uma identidade de desenvolvedor de verdade e o mesmo bundle id, as
#    permissões de Tela e Câmera sobrevivem a recompilações. Assinado ad-hoc (`-`), o `cdhash`
#    muda a cada build, o macOS trata cada build como um app diferente, e a pessoa reconcede a
#    permissão a cada vez — ou pior, o painel enche de linhas "Quall" idênticas.
IDENTIDADE="${QUALL_IDENTIDADE:-}"
if [ -z "$IDENTIDADE" ]; then
    IDENTIDADE="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Apple Development' | head -1 | sed 's/.*"\(.*\)".*/\1/')"
fi
if [ -z "$IDENTIDADE" ]; then
    IDENTIDADE="-"
    echo "==> AVISO: nenhuma identidade Apple Development encontrada; assinando ad-hoc."
    echo "    As permissões de Tela e Câmera vão ser pedidas de novo a cada recompilação."
fi

echo "==> assinando com: $IDENTIDADE"
# O auxiliar **antes** do bundle: código aninhado precisa estar assinado quando o bundle é
# assinado, senão `codesign --verify` recusa o `.app` inteiro. Sem entitlements — ele não captura,
# não abre câmera e não fala na rede; só cria o monitor.
[ -z "$AUXILIAR" ] || codesign --force --sign "$IDENTIDADE" \
    --options runtime \
    --timestamp=none \
    "$APP/Contents/MacOS/quall-monitor-virtual"
codesign --force --sign "$IDENTIDADE" \
    --options runtime \
    --entitlements "$AQUI/Quall-dev.entitlements" \
    --timestamp=none \
    "$APP"

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# 5. A cópia num lugar **estável**.
#
#    `.build/` fica dentro de um worktree, e worktree é descartado quando a frente é integrada.
#    Em 2026-08-27 isso custou caro de um jeito específico: o usuário foi procurar o `Quall.app`
#    para conceder Gravação de Tela e o caminho não existia mais. Pior, o TCC guarda a concessão
#    contra a identidade do código **e** o caminho conta para o que o painel mostra: um app que
#    muda de lugar a cada rodada enche a lista de linhas "Quall" que a pessoa não sabe distinguir.
#
#    `~/Applications` é o lugar padrão do usuário, é gravável sem `sudo`, e sobrevive a `git
#    worktree remove`. `QUALL_DESTINO=` (vazio) pula a cópia.
DESTINO="${QUALL_DESTINO-$HOME/Applications/Quall.app}"
if [ -n "$DESTINO" ]; then
    mkdir -p "$(dirname "$DESTINO")"
    rm -rf "$DESTINO"
    cp -R "$APP" "$DESTINO"
    echo "==> instalado em: $DESTINO"
fi

echo
echo "==> pronto: $APP"
if [ -n "$DESTINO" ]; then
    echo "    abra com:  open -n \"$DESTINO\""
    echo "    (use ESTE caminho para conceder Gravação de Tela — ele sobrevive ao worktree)"
else
    echo "    abra com:  open -n \"$APP\""
fi
