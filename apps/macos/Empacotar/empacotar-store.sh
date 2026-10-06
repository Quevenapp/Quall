#!/bin/bash
# Bundle da primeira release para conferência da Mac App Store: sandbox e APIs públicas.
# Não instala, não exporta PKG, não notariza e não envia. Assinatura local ad-hoc por padrão;
# uma identidade Apple Development existente pode ser indicada para prova local de runtime.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS="$(cd "$AQUI/.." && pwd)"
RAIZ="$(cd "$MACOS/../.." && pwd)"
APP="${QUALL_APP_DESTINO:-$AQUI/dist/Quall Studio.app}"
ARQUITETURAS="${QUALL_ARQUITETURAS:-universal}"
IDENTIDADE="${QUALL_IDENTIDADE:--}"
JOBS="${QUALL_JOBS:-2}"
VERSAO="${QUALL_VERSAO:-1.0.0}"
BUILD="${QUALL_BUILD:-3}"
case "$IDENTIDADE" in
    -|"Apple Development:"*) ;;
    *) echo "ERRO: esta etapa permite só assinatura local ad-hoc ou Apple Development existente." >&2
       echo "A exportação com identidade de distribuição e provisioning profile é outra etapa." >&2; exit 1 ;;
esac
case "$ARQUITETURAS" in host|universal) ;; *) echo "ERRO: QUALL_ARQUITETURAS deve ser host ou universal" >&2; exit 1 ;; esac
[ -z "${QUALL_TELA_ESTENDIDA_FUTURA:-}" ] || { echo "ERRO: recurso futuro não entra no produto Store" >&2; exit 1; }
case "$APP" in /*.app) ;; *) echo "ERRO: QUALL_APP_DESTINO deve ser caminho absoluto de um .app" >&2; exit 1 ;; esac
bash "$RAIZ/tools/distribuicao/conferir-marca-apple.sh" mac

BINARIO="${QUALL_BINARIO:-}"
RECURSOS="${QUALL_RECURSOS:-}"
if [ -z "$BINARIO" ]; then
    # O caminho linkado por Package.swift. A opção explícita permite reaproveitar o núcleo de
    # um snapshot já compilado e conferido; não afirma que um arquivo antigo esteja atualizado.
    if [ "${QUALL_NUCLEO_PRONTO:-nao}" != "sim" ]; then
        if [ "$ARQUITETURAS" = universal ]; then
            FATIAS=()
            for ALVO in aarch64-apple-darwin x86_64-apple-darwin; do
                QUALL_JOBS="$JOBS" bash "$RAIZ/tools/distribuicao/construir-nucleo-apple.sh" "$ALVO"
                FATIAS+=("$RAIZ/target/$ALVO/release/libquall.a")
            done
            mkdir -p "$RAIZ/target/release"
            lipo -create "${FATIAS[@]}" -output "$RAIZ/target/release/libquall.a"
        else
            case "$(uname -m)" in arm64) ALVO=aarch64-apple-darwin ;; x86_64) ALVO=x86_64-apple-darwin ;; esac
            QUALL_JOBS="$JOBS" bash "$RAIZ/tools/distribuicao/construir-nucleo-apple.sh" "$ALVO"
            mkdir -p "$RAIZ/target/release"
            cp "$RAIZ/target/$ALVO/release/libquall.a" "$RAIZ/target/release/libquall.a"
        fi
    fi
    [ -s "$RAIZ/target/release/libquall.a" ] || { echo "ERRO: núcleo ausente" >&2; exit 1; }
    if [ "$ARQUITETURAS" = universal ]; then
        ARQS=(--arch arm64 --arch x86_64)
    else
        # Bash 3.2 do macOS trata array vazio como variável não definida com set -u.
        # A fatia host explícita evita esse erro e mantém a arquitetura nativa.
        ARQS=(--arch "$(uname -m)")
    fi
    if [ "$ARQUITETURAS" = universal ]; then RUNTIME_ARQS="arm64 x86_64"; else RUNTIME_ARQS="$(uname -m)"; fi
    RUNTIME_DIR="$RAIZ/target/compiler-runtime/macos"
    PLATFORM_NAME=macosx ARCHS="$RUNTIME_ARQS" DERIVED_FILE_DIR="$RUNTIME_DIR" \
        bash "$RAIZ/apps/ios/Quall/Ferramentas/preparar-runtime-xcode.sh"
    (cd "$MACOS" && xcrun swift build -c release --jobs "$JOBS" "${ARQS[@]}" \
        -Xlinker "$RUNTIME_DIR/QuallAvailability.o" --product quall-app)
    PASTA_BIN="$(cd "$MACOS" && xcrun swift build -c release "${ARQS[@]}" --show-bin-path)"
    BINARIO="$PASTA_BIN/quall-app"
fi
[ -x "$BINARIO" ] || { echo "ERRO: executável ausente: $BINARIO" >&2; exit 1; }
[ -n "$RECURSOS" ] || RECURSOS="$(dirname "$BINARIO")/QuallCapture_QuallIdiomaKit.bundle"
[ -d "$RECURSOS" ] || { echo "ERRO: recursos de tradução ausentes: $RECURSOS" >&2; exit 1; }
if [ "$ARQUITETURAS" = universal ]; then
    ARQS_DO_BIN="$(lipo -archs "$BINARIO")"
    case "$ARQS_DO_BIN" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "ERRO: binário não universal: $ARQS_DO_BIN" >&2; exit 1 ;; esac
fi

# Só o app principal: nenhum helper, driver, plug-in ou arquivo de fontes futuros é copiado.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARIO" "$APP/Contents/MacOS/quall-app"
cp "$AQUI/Info.plist" "$APP/Contents/Info.plist"
cp "$AQUI/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp -R "$RAIZ/vendor/datachannel-sys/OpenSSL_Privacy.bundle" "$APP/Contents/Resources/"
cp "$AQUI/Quall.icns" "$APP/Contents/Resources/Quall.icns"
cp -R "$RECURSOS" "$APP/Contents/Resources/"
cp -R "$AQUI/pt.lproj" "$AQUI/en.lproj" "$APP/Contents/Resources/"
AVISOS="$RAIZ/THIRD_PARTY_NOTICES.txt"
[ -s "$AVISOS" ] || { echo "ERRO: avisos ausentes ou vazios" >&2; exit 1; }
cp "$AVISOS" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cmp -s "$AVISOS" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
for ARQUIVO_LICENCA in LICENSE LICENSE-SCOPE.md NOTICE.txt; do
    [ -s "$RAIZ/$ARQUIVO_LICENCA" ] || { echo "ERRO: licença própria ausente/vazia: $ARQUIVO_LICENCA" >&2; exit 1; }
    cp "$RAIZ/$ARQUIVO_LICENCA" "$APP/Contents/Resources/$ARQUIVO_LICENCA"
    cmp -s "$RAIZ/$ARQUIVO_LICENCA" "$APP/Contents/Resources/$ARQUIVO_LICENCA"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSAO" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :QuallCanalDeDistribuicao string mac-app-store' "$APP/Contents/Info.plist"
echo "==> assinando pacote LOCAL: $IDENTIDADE"
codesign --force --sign "$IDENTIDADE" --options runtime --timestamp=none \
    --entitlements "$AQUI/Quall.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> pacote local: $APP"
echo "    A assinatura local não é uma exportação nem aprovação da Mac App Store."
"$AQUI/conferir-store.sh" "$APP" "$ARQUITETURAS"
