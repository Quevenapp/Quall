#!/usr/bin/env bash
# Confere um APK do Quall antes de ele ir para a mão de alguém.
#
# Irmão do `apps/macos/Empacotar/conferir-distribuicao.sh`, com a mesma divisão de resultados:
#
#   FALHA — está errado. Conserte antes de qualquer outra coisa.
#   FALTA — está certo até onde dá sem a credencial do dono. Não é defeito.
#
# Saída 0 = tudo passou, 1 = há FALHA, 2 = só FALTA.
#
# O portão que mais importa é o de símbolos, e ele existe por um caso real deste repositório: uma
# `.so` do M0 — que exportava dois símbolos e nem tinha track de mídia — é um ELF perfeitamente
# válido. Um APK montado com ela **instala, carrega e passa pelo `System.loadLibrary`**, e só morre
# com `UnsatisfiedLinkError` na primeira chamada de verdade, dentro do serviço de espelhamento,
# longe do build. `compila-nucleo.sh` já guarda contra isso em `jniLibs/`; aqui a conferência é
# feita **no APK**, que é o artefato que viaja.
#
# Uso: apps/android/tools/conferir-release.sh caminho/do/app.apk

set -uo pipefail

APK="${1:-}"
[ -n "$APK" ] || { echo "uso: $0 <caminho do .apk>"; exit 64; }
[ -f "$APK" ] || { echo "não existe: $APK"; exit 64; }

: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FALHAS=0
FALTAS=0
ok()    { printf '  \033[32mOK   \033[0m %s\n' "$1"; }
falha() { printf '  \033[31mFALHA\033[0m %s\n' "$1"; FALHAS=$((FALHAS+1)); }
falta() { printf '  \033[33mFALTA\033[0m %s\n' "$1"; FALTAS=$((FALTAS+1)); }
nota()  { printf '        %s\n' "$1"; }

# As ferramentas moram na build-tools mais nova instalada.
BT="$(ls -d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -1)"
AAPT2="$BT/aapt2"
APKSIGNER="$BT/apksigner"
NDK="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.2.12479018}"
NM="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-nm"
[ -x "$NM" ] || NM="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm"

echo "== conferindo: $APK"
echo

# ---------------------------------------------------------------------------------------------
echo "-- manifesto"
BADGING="$("$AAPT2" dump badging "$APK" 2>/dev/null)"
if [ -n "$BADGING" ]; then
    echo "$BADGING" | grep -E "^package:|^sdkVersion|^targetSdkVersion|^native-code" | sed 's/^/          /'
    ok "aapt2 leu o pacote"
else
    falha "aapt2 não leu o APK ($AAPT2)"
fi

# **Um release depurável é um vazamento.** `android:debuggable` deixa qualquer um anexar um
# depurador, ler a memória do processo e — o que importa aqui — usar `run-as` para entrar no
# diretório privado do app. É exatamente o poder de que a bancada depende, e exatamente o que não
# pode viajar num APK distribuído.
if echo "$BADGING" | grep -q "application-debuggable"; then
    falha "o APK é DEPURÁVEL — não pode ser distribuído"
    nota "qualquer pessoa com o aparelho na mão usa run-as e lê o diretório privado do app."
else
    ok "não é depurável"
fi

# ---------------------------------------------------------------------------------------------
echo
echo "-- bibliotecas nativas"
LISTA="$(unzip -l "$APK" 2>/dev/null | awk '{print $4}' | grep '^lib/' || true)"
for ABI in armeabi-v7a arm64-v8a; do
    FALTOU=""
    for SO in libquall.so libqualljni.so libc++_shared.so; do
        echo "$LISTA" | grep -q "^lib/$ABI/$SO$" || FALTOU="$FALTOU $SO"
    done
    if [ -z "$FALTOU" ]; then
        ok "$ABI: libquall.so, libqualljni.so, libc++_shared.so"
    else
        falha "$ABI: falta(m)$FALTOU"
        nota "uma ABI incompleta quebra só nos aparelhos daquela ABI, e só em execução."
    fi
done

# O portão de símbolos, agora sobre o APK.
TMP="$(mktemp -d /tmp/quall-apk.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
# A lista de símbolos NÃO é escrita aqui: ela é lida de `compila-nucleo.sh`, que já a mantém e já
# a documenta ("todo símbolo que o shim JNI chama"). Duas listas do mesmo contrato divergem, e a
# que diverge em silêncio é sempre a de quem só confere. É a mesma lição do desinstalador da
# câmera do Windows, aplicada aqui: não escreva a lista, obtenha-a.
SIMBOLOS="$(sed -n '/^SIMBOLOS=(/,/^)/p' "$AQUI/compila-nucleo.sh" \
            | sed 's/#.*//' | tr ' ' '\n' | grep '^quall_' || true)"
if [ -z "$SIMBOLOS" ]; then
    falta "não consegui ler a lista de símbolos de compila-nucleo.sh"
fi
if [ -x "$NM" ] && [ -n "$SIMBOLOS" ]; then
    for ABI in armeabi-v7a arm64-v8a; do
        if unzip -o -q "$APK" "lib/$ABI/libquall.so" -d "$TMP" 2>/dev/null; then
            DEF="$("$NM" -D --defined-only "$TMP/lib/$ABI/libquall.so" 2>/dev/null | awk '{print $NF}')"
            FALTOU=""
            for S in $SIMBOLOS; do
                echo "$DEF" | grep -qx "$S" || FALTOU="$FALTOU $S"
            done
            TOTAL="$(echo "$DEF" | grep -c '^quall_' || true)"
            if [ -z "$FALTOU" ]; then
                ok "$ABI: núcleo de verdade ($TOTAL símbolos quall_*)"
            else
                falha "$ABI: a libquall.so do APK não exporta:$FALTOU"
                nota "é o sintoma de uma .so velha reaproveitada. Rode compila-nucleo.sh."
            fi
        fi
    done
else
    falta "llvm-nm do NDK não encontrado ($NM) — portão de símbolos não rodou"
fi

# ---------------------------------------------------------------------------------------------
echo
echo "-- assinatura"
if [ -x "$APKSIGNER" ]; then
    SAIDA="$("$APKSIGNER" verify -v --print-certs "$APK" 2>&1)"
    if echo "$SAIDA" | grep -q "Verifies"; then
        ok "apksigner verifica"
        echo "$SAIDA" | grep -E "^Verified using|Signer #1 certificate DN|Signer #1 certificate SHA-256" | sed 's/^/          /'
        # v2/v3 são os esquemas que assinam o arquivo inteiro. v1 (JAR) assina entrada por entrada
        # e foi por onde passaram Janus e Master Key; com minSdk 30 ele não é necessário.
        echo "$SAIDA" | grep -q "v2 scheme.*true\|APK Signature Scheme v2" && ok "esquema v2 presente"
    else
        falta "APK não assinado"
        nota "o Android recusa instalar um release sem assinatura."
        nota "Ver 'Assinar' na saída de empacotar-release.sh: a chave é do dono e é criada uma vez."
    fi
else
    falta "apksigner não encontrado em $BT"
fi

# ---------------------------------------------------------------------------------------------
echo
echo "== resumo"
echo "   FALHA: $FALHAS   FALTA: $FALTAS"
if [ "$FALHAS" -gt 0 ]; then
    echo "   Há defeito. Conserte antes de pensar em credencial."
    exit 1
elif [ "$FALTAS" -gt 0 ]; then
    echo "   Nenhum defeito. O que falta exige a chave do dono."
    exit 2
fi
echo "   Pronto para distribuir."
exit 0
