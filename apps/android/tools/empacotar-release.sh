#!/usr/bin/env bash
# Monta o APK (e o AAB) de **release** do Quall Android.
#
# O que a bancada instala hoje é `app-debug.apk`, e isso não é descuido: `run-as` — o único jeito
# de escrever `/data/data/com.quall.android/shared_prefs/quall-bancada.xml` e de ler o `.wav` de
# dentro do `filesDir` — **só funciona em APK de depuração**. Este roteiro acrescenta o release
# **sem tocar** no caminho de depuração: o `debug` continua igual, e passou a ser declarado
# explicitamente em `app/build.gradle.kts` para que ninguém o mude por acidente.
#
# O que muda para a bancada, e é a única coisa que muda: `debug` e `release` têm o mesmo
# `applicationId` com assinaturas diferentes, então **não convivem no mesmo aparelho**. Instalar um
# por cima do outro devolve `INSTALL_FAILED_UPDATE_INCOMPATIBLE`; desinstale antes. Dar um
# `applicationIdSuffix` ao debug resolveria a convivência e quebraria todo `run-as
# com.quall.android` dos roteiros — troca ruim.
#
# Uso:
#   apps/android/tools/empacotar-release.sh
#   apps/android/tools/empacotar-release.sh --versao 0.1.0 --codigo 7
#   apps/android/tools/empacotar-release.sh --sem-nucleo    # pula o compila-nucleo.sh
#   apps/android/tools/empacotar-release.sh --aab           # também o Android App Bundle
#
# Sem chave de assinatura configurada, ele produz o APK **não assinado** e imprime o comando exato
# que falta. Ver a seção "Assinar" no fim da saída.

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_APP="$(cd "$AQUI/.." && pwd)"
RAIZ="$(cd "$ANDROID_APP/../.." && pwd)"
DIST="$ANDROID_APP/dist"

VERSAO="0.1.0"
CODIGO="1"
FAZER_NUCLEO=1
FAZER_AAB=0
OFFLINE=""
SEM_LINT=0
PULAR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --versao) VERSAO="$2"; shift 2 ;;
        --codigo) CODIGO="$2"; shift 2 ;;
        --sem-nucleo) FAZER_NUCLEO=0; shift ;;
        --aab) FAZER_AAB=1; shift ;;
        # Numa bancada onde outra frente mede perda na Wi-Fi, um build que baixa dependência é
        # tráfego que ninguém pediu. Com o cache do Gradle quente, `--offline` prova o mesmo.
        --offline) OFFLINE="--offline"; shift ;;
        # `lintVital` roda sozinho em toda build de release e é um portão de verdade — ele acha
        # coisas que o compilador não acha. Esta opção existe por um motivo estreito: o
        # `lint-gradle` é baixado sob demanda e **não estava no cache** desta bancada, então com
        # `--offline` a build inteira falhava no último passo por falta de um `.jar`. Pular o lint
        # não é o padrão, e a saída avisa quando ele foi pulado.
        --sem-lint) SEM_LINT=1; shift ;;
        *) echo "opção desconhecida: $1"; exit 64 ;;
    esac
done

: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export ANDROID_HOME
[ -d "$ANDROID_HOME" ] || { echo "ERRO: ANDROID_HOME não existe: $ANDROID_HOME"; exit 1; }

echo "==> versão $VERSAO (código $CODIGO)"

# ---------------------------------------------------------------------------------------------
# 1. O núcleo, nas duas ABIs.
#
# `compila-nucleo.sh` é o **dono** de `app/src/main/jniLibs/`: ele apaga a pasta antes de copiar,
# e aplica o portão de símbolos. Um release montado sobre uma `.so` velha instala, carrega, passa
# pelo `System.loadLibrary` e só morre com `UnsatisfiedLinkError` na primeira chamada de verdade,
# dentro do serviço de espelhamento. Reaproveitar é exatamente esse erro esperando acontecer.
# ---------------------------------------------------------------------------------------------
if [ "$FAZER_NUCLEO" = "1" ]; then
    echo "==> núcleo (compila-nucleo.sh)"
    "$AQUI/compila-nucleo.sh"
else
    echo "==> --sem-nucleo: usando o que já está em app/src/main/jniLibs"
fi

# O FFmpeg da câmera DV (LGPL, arm64): a tela "Licenças de terceiros" diz a versão, e a release
# não pode sair sem as `.so` que ela descreve, nem com `.so` de outra construção.
echo "==> FFmpeg da câmera DV (compila-ffmpeg-dv.sh)"
"$AQUI/compila-ffmpeg-dv.sh"

for ABI in armeabi-v7a arm64-v8a; do
    SO="$ANDROID_APP/app/src/main/jniLibs/$ABI/libquall.so"
    [ -f "$SO" ] || { echo "ERRO: falta $SO — rode sem --sem-nucleo"; exit 1; }
done

# ---------------------------------------------------------------------------------------------
# 2. O APK.
# ---------------------------------------------------------------------------------------------
command -v gradle >/dev/null || {
    echo "ERRO: 'gradle' não está no PATH."
    echo "  Não há wrapper neste projeto, por decisão registrada em settings.gradle.kts:"
    echo "  a bancada tem gradle 8.10.2 fixo. Instale 8.10+ compatível com AGP 8.7."
    exit 1
}

if [ "$SEM_LINT" = "1" ]; then
    PULAR="-x lintVitalAnalyzeRelease -x lintVitalReportRelease -x lintVitalRelease"
    echo "==> AVISO: --sem-lint, o portão lintVital NÃO vai rodar nesta build"
fi

echo "==> gradle assembleRelease"
( cd "$ANDROID_APP" && gradle $OFFLINE $PULAR --console=plain \
    -PquallVersionName="$VERSAO" -PquallVersionCode="$CODIGO" \
    assembleRelease )

if [ "$FAZER_AAB" = "1" ]; then
    echo "==> gradle bundleRelease"
    ( cd "$ANDROID_APP" && gradle $OFFLINE $PULAR --console=plain \
        -PquallVersionName="$VERSAO" -PquallVersionCode="$CODIGO" \
        bundleRelease )
fi

# ---------------------------------------------------------------------------------------------
# 3. Recolher.
# ---------------------------------------------------------------------------------------------
mkdir -p "$DIST"
APK=""
for CAND in "$ANDROID_APP/app/build/outputs/apk/release/app-release.apk" \
            "$ANDROID_APP/app/build/outputs/apk/release/app-release-unsigned.apk"; do
    if [ -f "$CAND" ]; then
        APK="$DIST/quall-$VERSAO$( [ "${CAND##*/}" = "app-release-unsigned.apk" ] && echo "-NAO-ASSINADO" ).apk"
        cp "$CAND" "$APK"
        break
    fi
done
[ -n "$APK" ] || { echo "ERRO: não achei o APK de release"; exit 1; }
echo "==> $APK  ($(du -h "$APK" | cut -f1))"

AAB=""
if [ "$FAZER_AAB" = "1" ] && [ -f "$ANDROID_APP/app/build/outputs/bundle/release/app-release.aab" ]; then
    AAB="$DIST/quall-$VERSAO.aab"
    cp "$ANDROID_APP/app/build/outputs/bundle/release/app-release.aab" "$AAB"
    echo "==> $AAB  ($(du -h "$AAB" | cut -f1))"
fi

echo
"$AQUI/conferir-release.sh" "$APK" || true

# ---------------------------------------------------------------------------------------------
cat <<FIM

==> Assinar — o degrau que exige a chave do dono

A chave de release é a identidade do produto. Quem a tem publica atualizações em nome do dono, e
o Google não troca a chave de um app já publicado: perdê-la significa publicar outro app, com
outra ficha e sem os instalados. Ela é criada UMA VEZ, pelo dono, e nunca entra no Git — o
\`.gitignore\` passou a cobrir \`*.jks\`, \`*.keystore\` e \`keystore.properties\` nesta rodada.

  1. criar a chave (uma vez, guardando o arquivo e a senha em lugar seguro):

     keytool -genkeypair -v \\
         -keystore ~/chaves/quall-release.jks \\
         -alias quall \\
         -keyalg RSA -keysize 4096 -validity 10000 \\
         -dname "CN=Quall, O=Veneri & Quellis Ltda, C=BR"

     (10000 dias é o mínimo que a Play Store aceita para uma chave de upload.)

  2. apontar este build para ela, em apps/android/keystore.properties:

     storeFile=/Users/<voce>/chaves/quall-release.jks
     storePassword=...
     keyAlias=quall
     keyPassword=...

     ou, sem arquivo em disco (CI):
       QUALL_KEYSTORE  QUALL_KEYSTORE_SENHA  QUALL_KEY_ALIAS  QUALL_KEY_SENHA

  3. rodar este roteiro de novo. O APK sai assinado e \`conferir-release.sh\` passa a mostrar o
     certificado.

Para assinar um APK **já construído**, sem reconstruir:

  \$ANDROID_HOME/build-tools/<versão>/apksigner sign \\
      --ks ~/chaves/quall-release.jks --ks-key-alias quall \\
      --out "$DIST/quall-$VERSAO.apk" "$APK"

PARADO AQUI. Nenhuma chave foi criada nem usada por este roteiro.
FIM
