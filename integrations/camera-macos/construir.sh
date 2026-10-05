#!/bin/zsh
# Constrói, instala em /Applications e pede a ativação da extensão.
#
# O app **precisa** estar em /Applications: com SIP ligado — que é o estado desta bancada — o
# `systemextensionsctl developer on` recusa ("cannot be used if System Integrity Protection is
# enabled"), e sem modo de desenvolvedor o `sysextd` só aceita extensão vinda de um app instalado.
set -euo pipefail
cd "$(dirname "$0")"

RAIZ="$(cd ../.. && pwd)"
ALVO="${QUALL_ALVO_RUST:-aarch64-apple-darwin}"
AVISOS="$RAIZ/THIRD_PARTY_NOTICES.txt"
if [[ ! -s "$AVISOS" ]]; then
  echo "THIRD_PARTY_NOTICES.txt ausente ou vazio na raiz; empacotamento interrompido." >&2
  exit 1
fi

if [[ ! -f "$RAIZ/target/$ALVO/release/libquall.a" ]]; then
  echo "== compilando o núcleo (LTO desligado: ver dívida 17)"
  # `lto = "thin"` emite bitcode que o `nm` da Apple não lê. O `ld` linka, mas qualquer guarda
  # que conte símbolos dá alarme falso — e no M3 isso custou uma rodada inteira de diagnóstico.
  CARGO_PROFILE_RELEASE_LTO=false cargo build -p quall-ffi --release --target "$ALVO"
fi

echo "== gerando o projeto"
xcodegen generate

echo "== compilando"
# **A versão muda quando a extensão muda, e só então.** São duas armadilhas opostas, e o meio
# termo é a única saída:
#
# 1. Reinstalar a **mesma** versão não reencena nada: o bundle novo vai para /Applications e o
#    sistema continua com o antigo, sem erro e sem aviso. O sintoma é o cdhash instalado não bater
#    com o `stagedCdhashes` do `db.plist`. Custou uma rodada.
# 2. Trocar a versão de uma extensão **já aprovada e rodando** derruba a câmera do sistema inteiro
#    quando a ativação é pedida uma vez só: o registro novo entra como `activated enabled`, o
#    antigo fica `terminated waiting to uninstall on reboot`, e **nenhum processo de extensão é
#    lançado**. A câmera some do `system_profiler`, do AVFoundation e do DAL, sem erro nenhum.
#    Medido em 2026-08-24; o conserto é o pedido de ativação em dobro, logo abaixo.
#
# Um carimbo de tempo resolve a primeira e dispara a segunda a cada build — inclusive quando só o
# app mudou, que é a maioria das builds. A impressão digital das fontes da extensão resolve as
# duas: muda quando as fontes ou os avisos empacotados da extensão mudam.
FONTES_DA_EXTENSAO=$(cat Fontes/Extensao/*.swift Fontes/Comum/*.swift \
                         Fontes/Extensao/Info.plist Fontes/Extensao/*.entitlements \
                         "$AVISOS" | shasum -a 256)
VERSAO_DE_BUILD="${QUALL_VERSAO_DE_BUILD:-$((16#${FONTES_DA_EXTENSAO:0:7}))}"
INSTALADA=$(systemextensionsctl list com.apple.system_extension.cmio 2>/dev/null \
            | grep "quall.camera.extensao" | grep "activated enabled" | sed -E 's|.*/([0-9]+)\).*|\1|')
if [[ -n "$INSTALADA" && "$INSTALADA" != "$VERSAO_DE_BUILD" ]]; then
  cat <<FIM

  AVISO: a extensão vai ser SUBSTITUÍDA ($INSTALADA -> $VERSAO_DE_BUILD).
  Se você só mexeu no app, confira o que mudou em Fontes/Extensao, Fontes/Comum ou nos avisos
  empacotados. A substituição é segura — o pedido de ativação em dobro deste script relança
  o processo da extensão —, mas o passo "a câmera está publicada?" no fim confere.
FIM
fi
xcodebuild -project QuallCamera.xcodeproj -scheme QuallCamera -configuration Release \
  -derivedDataPath DD -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$VERSAO_DE_BUILD" "$@" build | tail -3

echo "== instalando em /Applications"
rm -rf /Applications/QuallCamera.app
cp -R DD/Build/Products/Release/QuallCamera.app /Applications/

echo "== pedindo ativação"
# **Duas vezes, de propósito.** Numa substituição de versão, o primeiro pedido deixa o registro
# novo em `activated_enabled` **sem** `additionalLaunchdPlistEntries` no `db.plist` — ou seja, o
# `com.apple.cmio.registerassistantservice` não chegou a registrar o serviço da extensão. O
# segundo pedido completa o registro. Medido em 2026-08-24, conferindo o `db.plist` entre os dois.
for _ in 1 2; do
  /Applications/QuallCamera.app/Contents/MacOS/QuallCamera ativar &
  PID=$!
  sleep 6
  kill $PID 2>/dev/null || true
done

echo "== estado"
systemextensionsctl list com.apple.system_extension.cmio
echo "== o registro do CoreMediaIO chegou ao db.plist?"
if plutil -p /Library/SystemExtensions/db.plist 2>/dev/null \
   | grep -c additionalLaunchdPlistEntries | grep -qv '^0$'; then
  plutil -p /Library/SystemExtensions/db.plist 2>/dev/null \
    | grep -cE 'additionalLaunchdPlistEntries' | sed 's/^/  registros com serviço de assistente: /'
fi
echo "== a câmera está publicada?"
if system_profiler SPCameraDataType 2>/dev/null | grep -q "Quall:"; then
  echo "  sim: a Quall aparece no system_profiler"
else
  echo "  NÃO. Se a extensão acabou de ser substituída, isto é esperado: reinicie o Mac."
fi
