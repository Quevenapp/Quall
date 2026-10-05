#!/usr/bin/env bash

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$AQUI/.." && pwd)"
RAIZ="$(cd "$PROJ/../../.." && pwd)"
SAIDA="$PROJ/dist"

ALCANCE=""
VERSAO="0.1.0"
BUILD="1"
SEM_ASSINAR=0

while [ $# -gt 0 ]; do
    case "$1" in
        --exportar) ALCANCE="$2"; shift 2 ;;
        --versao)   VERSAO="$2"; shift 2 ;;
        --build)    BUILD="$2"; shift 2 ;;
        --sem-assinar) SEM_ASSINAR=1; shift ;;
        *) echo "opção desconhecida: $1"; exit 64 ;;
    esac
done

ARQUIVO="$SAIDA/Quall-$VERSAO.xcarchive"
DD="$PROJ/DDrel"

if [ ! -f "$RAIZ/Signing.local.xcconfig" ]; then
    cat <<FIM
ERRO: falta $RAIZ/Signing.local.xcconfig

Ele é local e o Git o ignora (junto com *.p12 e *.mobileprovision) de propósito: é o arquivo que
amarra a build à conta do dono. Copie o modelo:

    cp "$RAIZ/Signing.local.xcconfig.example" "$RAIZ/Signing.local.xcconfig"

O modelo deixa o time em branco. Informe uma identidade e os perfis da sua conta
somente no arquivo local para produzir um pacote assinado.
FIM
    exit 1
fi

A="$RAIZ/target/aarch64-apple-ios/release/libquall.a"
    echo "==> compilando o núcleo para aarch64-apple-ios"
    ( cd "$RAIZ" && IPHONEOS_DEPLOYMENT_TARGET=15.0 CARGO_PROFILE_RELEASE_LTO=false \
        cargo build --locked --offline -j "${QUALL_JOBS:-2}" --release --target aarch64-apple-ios -p quall-ffi )
[ -f "$A" ] || { echo "ERRO: $A não saiu do build"; exit 1; }

echo "==> xcodegen generate"
( cd "$PROJ" && xcodegen generate )

mkdir -p "$SAIDA"

if [ "$SEM_ASSINAR" = "1" ]; then
    echo "==> xcodebuild build -configuration Release, SEM ASSINAR"
    ( cd "$PROJ" && xcodebuild -project Quall.xcodeproj -scheme Quall \
        -configuration Release -jobs "${QUALL_JOBS:-2}" \
        -destination "generic/platform=iOS" \
        -derivedDataPath "$DD" \
        IPHONEOS_DEPLOYMENT_TARGET=15.0 \
        MARKETING_VERSION="$VERSAO" \
        CURRENT_PROJECT_VERSION="$BUILD" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        build )
    APP="$DD/Build/Products/Release-iphoneos/Quall.app"
else
    rm -rf "$ARQUIVO"
    echo "==> xcodebuild archive -configuration Release  (versão $VERSAO, build $BUILD)"
    ( cd "$PROJ" && xcodebuild -project Quall.xcodeproj -scheme Quall \
        -configuration Release -jobs "${QUALL_JOBS:-2}" \
        -destination "generic/platform=iOS" \
        -archivePath "$ARQUIVO" \
        -allowProvisioningUpdates \
        IPHONEOS_DEPLOYMENT_TARGET=15.0 \
        MARKETING_VERSION="$VERSAO" \
        CURRENT_PROJECT_VERSION="$BUILD" \
        archive )
    APP="$ARQUIVO/Products/Applications/Quall.app"
fi

echo
echo "==> portões"
FALHOU=0
for B in "$APP/Quall" "$APP/PlugIns/Difusao.appex/Difusao"; do
    [ -f "$B" ] || { echo "  FALHA  não achei $B"; FALHOU=1; continue; }
    NOME="$(basename "$B")"

    MIN="$(vtool -show-build-version "$B" 2>/dev/null | grep -o 'minos [0-9.]*' | head -1)"
    if [ "$MIN" = "minos 15.0" ]; then echo "  ok     $NOME: $MIN"
    else echo "  FALHA  $NOME não declara minos 15.0 ($MIN) — fora do piso suportado"; FALHOU=1; fi

    LOCAIS="$(otool -L "$B" | tail -n +2 | grep -cE '^\s+(/Users/|/Volumes/)' || true)"
    if [ "${LOCAIS:-0}" -eq 0 ]; then echo "  ok     $NOME: nenhuma dependência com caminho local"
    else echo "  FALHA  $NOME tem $LOCAIS dependência(s) com caminho desta máquina"; FALHOU=1; fi

    N="$(nm -U "$B" 2>/dev/null | grep -c ' T _quall_' || true)"
    echo "  ok     $NOME: $N símbolos quall_* linkados"
done

FAM_APP="$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily' "$APP/Info.plist" 2>/dev/null | tr -d ' \n')"
FAM_EXT="$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily' "$APP/PlugIns/Difusao.appex/Info.plist" 2>/dev/null | tr -d ' \n')"
if [ "$FAM_APP" = "$FAM_EXT" ]; then
    echo "  ok     UIDeviceFamily igual no app e na appex: $FAM_APP"
else
    echo "  FALHA  UIDeviceFamily difere — app $FAM_APP, appex $FAM_EXT"
    echo "         Família menor na extensão é recusada na instalação, sem dizer por quê."
    FALHOU=1
fi

[ "$FALHOU" = "0" ] || { echo; echo "PARADO: um portão falhou. Não exporte."; exit 1; }

echo
if [ "$SEM_ASSINAR" = "1" ]; then
    cat <<FIM
==> Compilado em Release e conferido, SEM assinatura: $APP

Isto responde "o Release compila e os portões passam?" — e mais nada. Não há \`.xcarchive\`, não há
\`.ipa\`, e nenhum aparelho pode receber isto: o iOS não instala binário sem assinatura.

Para seguir, rode sem --sem-assinar. Aí o xcodebuild assina com a identidade do time, e daí em
diante é a conta do dono.
FIM
    exit 0
fi
echo "==> arquivo: $ARQUIVO"

if [ -z "$ALCANCE" ]; then
    cat <<FIM

==> Arquivado, não exportado.

Escolha o alcance e rode de novo:

  --exportar aparelhos-registrados   aparelho cadastrado no time (perfil de desenvolvimento)
  --exportar teste-interno           Ad Hoc: aparelho cadastrado, sem cabo, teto de 100/ano
  --exportar loja                    TestFlight/App Store — o único que alcança um estranho

A exportação chama o \`xcodebuild -exportArchive\`, que assina com a identidade do time e pode
pedir a senha do chaveiro. Ela usa a conta do dono; ninguém mais a roda.
FIM
    exit 0
fi

OPCOES="$AQUI/OpcoesDeExportacao-$ALCANCE.plist"
[ -f "$OPCOES" ] || { echo "ERRO: não há OpcoesDeExportacao-$ALCANCE.plist em $AQUI"; exit 64; }

echo "==> xcodebuild -exportArchive ($ALCANCE)"
rm -rf "$SAIDA/$ALCANCE"
xcodebuild -exportArchive \
    -archivePath "$ARQUIVO" \
    -exportPath "$SAIDA/$ALCANCE" \
    -exportOptionsPlist "$OPCOES" \
    -allowProvisioningUpdates

IPA="$(find "$SAIDA/$ALCANCE" -name '*.ipa' -print -quit)"
echo
echo "==> $IPA  ($(du -h "$IPA" | cut -f1))"

if [ "$ALCANCE" = "loja" ]; then
    cat <<FIM

==> Subir para o App Store Connect — o passo que exige a conta do dono

Não é feito por este roteiro, e não deve ser feito por ninguém que não seja o dono da conta:
subir um build o associa à conta configurada e pode disponibilizá-lo no TestFlight.

  1. chave de API (uma vez): https://appstoreconnect.apple.com/access/integrations/api
     Baixe o .p8 (só é oferecido uma vez) e anote Key ID e Issuer ID.

  2. subir:

     xcrun altool --upload-app -f "$IPA" -t ios \\
         --apiKey <KEYID> --apiIssuer <ISSUER-UUID>

  3. no App Store Connect, distribuir para o TestFlight.

PARADO AQUI. Nada foi enviado.
FIM
else
    cat <<FIM

==> Instalar num aparelho CADASTRADO:

  ios-deploy --id <UDID> --bundle <o .app de dentro do .ipa> --no-wifi   # iOS 15/16
  xcrun devicectl device install app --device <UDID> "$IPA"              # iOS 17+

Se der 0xe8008015 ou 0xe8008012, o aparelho **não está cadastrado** — e nenhuma das duas mensagens
diz isso. Cadastrar consome um slot do time e é ação na conta do dono:
\`-allowProvisioningDeviceRegistration\` (não \`-allowProvisioningUpdates\`, que só atualiza perfil).

E: o iOS recusa lançar app em aparelho bloqueado, para \`devicectl\` e \`ios-deploy\` igualmente.
Não há caminho sem tela acesa e desbloqueada.
FIM
fi
