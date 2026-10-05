#!/bin/bash
# Confere se um `.app` (ou `.dmg`) do Quall está pronto para ir para a mão de um estranho.
#
# Por que este script existe, e por que ele é o mais importante dos três: sem ele, "está pronto
# para distribuir" é opinião. O jeito de descobrir que faltava o carimbo de tempo, ou que o
# binário linkou um `.dylib` com caminho desta máquina, ou que o hardened runtime não estava
# ligado, é a notarização recusar — três minutos de upload depois, com uma mensagem que nomeia
# um problema por vez. Este script faz **todas** as conferências localmente, em segundos, e
# separa dois tipos de resultado que não podem ser confundidos:
#
#   FALHA  — está errado. Conserte antes de qualquer outra coisa.
#   FALTA  — está certo até onde dá sem a credencial do dono. Não é defeito.
#
# O código de saída distingue os dois: 0 = tudo passou, 1 = há FALHA, 2 = só FALTA.
# Um "2" é o resultado esperado de um pacote assinado ad-hoc, e é o resultado esperado de
# **qualquer** pacote que esta bancada consiga produzir sem o certificado Developer ID.
#
# Uso:
#   apps/macos/Empacotar/conferir-distribuicao.sh apps/macos/Empacotar/dist/Quall.app
#   apps/macos/Empacotar/conferir-distribuicao.sh apps/macos/Empacotar/dist/Quall-0.1.0.dmg

set -uo pipefail

ALVO="${1:-}"
[ -n "$ALVO" ] || { echo "uso: $0 <caminho do .app ou .dmg>"; exit 64; }
[ -e "$ALVO" ] || { echo "não existe: $ALVO"; exit 64; }

FALHAS=0
FALTAS=0

ok()    { printf '  \033[32mOK   \033[0m %s\n' "$1"; }
falha() { printf '  \033[31mFALHA\033[0m %s\n' "$1"; FALHAS=$((FALHAS+1)); }
falta() { printf '  \033[33mFALTA\033[0m %s\n' "$1"; FALTAS=$((FALTAS+1)); }
nota()  { printf '        %s\n' "$1"; }

echo "== conferindo: $ALVO"
echo

# ---------------------------------------------------------------------------------------------
# Um `.dmg` é conferido por fora (assinatura, notarização, ticket grampeado) e por dentro: monta,
# confere o `.app`, desmonta. Sem isso a conferência passaria num `.dmg` bem assinado contendo um
# app quebrado — que é exatamente o que o estranho baixa.
# ---------------------------------------------------------------------------------------------
MONTAGEM=""
APP="$ALVO"
case "$ALVO" in
    *.dmg)
        echo "-- imagem de disco"
        MONTAGEM="$(mktemp -d /tmp/quall-confere.XXXXXX)"
        if hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MONTAGEM" "$ALVO"; then
            ok "a imagem monta"
        else
            falha "hdiutil attach recusou a imagem"
            exit 1
        fi
        APP="$(find "$MONTAGEM" -maxdepth 1 -name '*.app' -print -quit)"
        if [ -n "$APP" ]; then ok "contém $(basename "$APP")"; else falha "não há .app dentro"; fi
        # `-quarantine` só existe em download; aqui a checagem que vale é o Gatekeeper sobre o
        # próprio `.dmg`, feita mais abaixo junto com a do app.
        echo
        ;;
esac

limpar() { [ -n "$MONTAGEM" ] && hdiutil detach -quiet "$MONTAGEM" 2>/dev/null; }
trap limpar EXIT

BIN=""
if [ -n "$APP" ] && [ -d "$APP" ]; then
    EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)"
    BIN="$APP/Contents/MacOS/$EXEC"
fi

# ---------------------------------------------------------------------------------------------
# 1. Estrutura do bundle
# ---------------------------------------------------------------------------------------------
echo "-- estrutura"
if [ -f "$APP/Contents/Info.plist" ]; then ok "Info.plist presente"
else falha "Info.plist ausente"; fi

if plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1; then ok "Info.plist é plist válido"
else falha "Info.plist inválido"; fi

if [ -x "$BIN" ]; then ok "executável: Contents/MacOS/$EXEC"
else falha "CFBundleExecutable aponta para algo que não existe ou não é executável"; fi

# O auxiliar da tela estendida. Sem ele o app abre e funciona — só a linha "Tela estendida" some
# do seletor, sem erro nenhum. É o tipo de falta que só aparece quando alguém procura a função.
AUX="$APP/Contents/MacOS/quall-monitor-virtual"
if [ -x "$AUX" ]; then
    ok "auxiliar da tela estendida: Contents/MacOS/quall-monitor-virtual ($(lipo -archs "$AUX" 2>/dev/null))"
else
    falha "auxiliar da tela estendida ausente (Contents/MacOS/quall-monitor-virtual)"
fi

for CHAVE in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
    V="$(/usr/libexec/PlistBuddy -c "Print :$CHAVE" "$APP/Contents/Info.plist" 2>/dev/null)"
    if [ -n "$V" ]; then ok "$CHAVE = $V"; else falha "$CHAVE ausente"; fi
done

# O ícone. Não é requisito de notarização, mas é a primeira coisa que o estranho vê — e um app
# sem ícone aparece com a folha branca genérica do sistema, que lê como software abandonado.
if /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    ok "CFBundleIconFile declarado"
else
    falta "sem ícone (CFBundleIconFile) — o app aparece com a folha branca do sistema"
    nota "não bloqueia a notarização; bloqueia a primeira impressão."
fi
echo

# ---------------------------------------------------------------------------------------------
# 2. Arquitetura e piso de sistema
# ---------------------------------------------------------------------------------------------
echo "-- binário"
if [ -x "$BIN" ]; then
    ARQS="$(lipo -archs "$BIN" 2>/dev/null)"
    case "$ARQS" in
        *arm64*x86_64*|*x86_64*arm64*) ok "universal: $ARQS" ;;
        *) falha "não é universal ($ARQS) — não abre em metade dos Macs" ;;
    esac

    # O piso declarado no binário e o piso declarado no Info.plist têm de ser o mesmo número. Se
    # o do binário for MAIOR, o app aparece instalável num Mac onde ele não roda: o Finder deixa
    # abrir e o dyld recusa, com uma mensagem que não explica nada.
    LSMIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null)"
    MINOS="$(vtool -show-build-version "$BIN" 2>/dev/null | grep -o 'minos [0-9.]*' | head -1 | awk '{print $2}')"
    if [ -n "$MINOS" ]; then
        if [ "${MINOS%%.0}" = "${LSMIN%%.0}" ] || [ "$MINOS" = "$LSMIN" ]; then
            ok "piso de sistema coerente: binário minos $MINOS = LSMinimumSystemVersion $LSMIN"
        else
            falha "binário exige macOS $MINOS mas o Info.plist promete $LSMIN"
        fi
    else
        falta "vtool não leu o minos do binário"
    fi

    # **O núcleo está nas DUAS fatias?** Um `lipo -archs` que responde "x86_64 arm64" só prova
    # que existem duas fatias, não que as duas servem. Uma build universal que linkasse um `.a`
    # de uma arquitetura só produziria — no melhor caso — erro de link; no pior, e é o caso que
    # importa, um binário gordo onde uma das fatias veio de uma build anterior e está velha.
    # Contar os símbolos do núcleo em cada fatia é o mesmo portão que
    # `apps/android/tools/compila-nucleo.sh` aplica às `.so`, e custa o mesmo: nada.
    N_ARM="$(nm -arch arm64  -U "$BIN" 2>/dev/null | grep -c ' T _quall_')"
    N_X86="$(nm -arch x86_64 -U "$BIN" 2>/dev/null | grep -c ' T _quall_')"
    if [ "${N_ARM:-0}" -gt 0 ] && [ "$N_ARM" = "$N_X86" ]; then
        ok "o núcleo está nas duas fatias: $N_ARM símbolos quall_* em arm64 e em x86_64"
    else
        falha "as fatias não carregam o mesmo núcleo (arm64: ${N_ARM:-0}, x86_64: ${N_X86:-0})"
    fi

    # Dependência com caminho desta máquina. A armadilha já paga em `Package.swift`
    # (`crate-type` do `quall-ffi` põe `.a` e `.dylib` na mesma pasta, e o `ld` prefere o
    # dinâmico), e o sintoma dela na mão do estranho é o app não abrir, sem diálogo nenhum.
    LOCAIS="$(otool -L "$BIN" 2>/dev/null | tail -n +2 | grep -cE '^\s+(/Users/|/Volumes/|@executable_path/\.\./\.\./)' || true)"
    if [ "${LOCAIS:-0}" -eq 0 ]; then
        ok "nenhuma dependência com caminho local ($(otool -L "$BIN" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ') bibliotecas)"
    else
        falha "$LOCAIS dependência(s) com caminho desta máquina — o app não abre em outro Mac"
        otool -L "$BIN" | tail -n +2 | grep -E '^\s+(/Users/|/Volumes/)' | sed 's/^/          /'
    fi
fi
echo

# ---------------------------------------------------------------------------------------------
# 3. Assinatura — o núcleo da conferência
# ---------------------------------------------------------------------------------------------
echo "-- assinatura"
INFO="$(codesign -dvvv "$APP" 2>&1)"

if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    ok "codesign --verify --deep --strict passa"
else
    falha "codesign --verify --deep --strict recusa"
    codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/          /'
fi

# Hardened runtime. A flag `runtime` no campo `CodeDirectory ... flags=`. Sem ela a notarização
# recusa — e recusa *depois* do upload, que é o jeito caro de descobrir.
if echo "$INFO" | grep -q 'flags=.*runtime'; then
    ok "hardened runtime ligado"
else
    falha "hardened runtime DESLIGADO — a notarização recusa"
    nota "assine com --options runtime."
fi

# Identidade. Três estados, e só um deles serve para distribuir.
AUT="$(echo "$INFO" | grep '^Authority=' | head -1 | cut -d= -f2-)"
if echo "$INFO" | grep -q '^Signature=adhoc'; then
    falta "assinatura AD-HOC — não vale fora desta máquina"
    nota "é o estado esperado de um pacote montado sem a credencial do dono."
elif echo "$AUT" | grep -q '^Developer ID Application:'; then
    ok "assinado por: $AUT"
elif [ -n "$AUT" ]; then
    falha "assinado por '$AUT', que NÃO é 'Developer ID Application:'"
    nota "Apple Development e Apple Distribution não servem para distribuição direta;"
    nota "a primeira só vale nas máquinas do time, a segunda só pela App Store."
else
    falha "sem assinatura nenhuma"
fi

# Carimbo de tempo seguro. Sem ele a assinatura expira junto com o certificado — um app assinado
# sem carimbo para de abrir no dia em que o certificado vence, mesmo já instalado.
if echo "$INFO" | grep -q '^Timestamp='; then
    ok "carimbo de tempo seguro: $(echo "$INFO" | grep '^Timestamp=' | cut -d= -f2-)"
else
    falta "sem carimbo de tempo seguro (--timestamp)"
    nota "exige identidade real: não há o que carimbar numa assinatura ad-hoc."
fi

TEAM="$(echo "$INFO" | grep '^TeamIdentifier=' | cut -d= -f2-)"
if [ -n "$TEAM" ] && [ "$TEAM" != "not set" ]; then
    ok "TeamIdentifier = $TEAM"
else
    falta "TeamIdentifier não definido (consequência da assinatura ad-hoc)"
fi
echo

# ---------------------------------------------------------------------------------------------
# 4. Entitlements
# ---------------------------------------------------------------------------------------------
echo "-- entitlements"
ENT="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
if echo "$ENT" | grep -q 'com.apple.security.device.camera'; then
    ok "com.apple.security.device.camera presente"
else
    falha "falta com.apple.security.device.camera"
    nota "sob hardened runtime o TCC recusa a câmera ANTES de existir diálogo, e sem erro legível."
    nota "Medido em 2026-08-24; ver docs/regras-de-frente.md."
fi
# O microfone junto da câmera (R5 fase 4): o mesmo defeito mudo, do lado do som.
if echo "$ENT" | grep -q 'com.apple.security.device.audio-input'; then
    ok "com.apple.security.device.audio-input presente"
else
    falha "falta com.apple.security.device.audio-input (o botão do microfone da câmera)"
fi

# `get-task-allow` é o entitlement de depuração. Ele deixa qualquer processo anexar um depurador
# ao app — e a notarização recusa um binário que o traga.
if echo "$ENT" | grep -q 'get-task-allow'; then
    falha "com.apple.security.get-task-allow presente — a notarização recusa"
    nota "ele entra sozinho em builds de depuração do Xcode; não pode ir para distribuição."
else
    ok "sem get-task-allow (entitlement de depuração)"
fi
echo

# ---------------------------------------------------------------------------------------------
# 5. Gatekeeper e notarização
#
# `spctl` responde a pergunta que interessa de verdade: **o Mac de um estranho vai abrir isto?**
# Ele é o único teste desta lista que não olha o pacote, e sim o que o sistema decide sobre ele.
# ---------------------------------------------------------------------------------------------
echo "-- Gatekeeper"
SPCTL="$(spctl -a -vvv -t exec "$APP" 2>&1)"
if echo "$SPCTL" | grep -q 'accepted'; then
    ok "spctl aceita"
    echo "$SPCTL" | grep -E 'source=|origin=' | sed 's/^/          /'
else
    falta "spctl recusa: $(echo "$SPCTL" | tail -1 | sed 's/^ *//')"
    nota "É o que o estranho vê como 'não foi possível verificar o desenvolvedor'."
    nota "Só some com Developer ID + notarização. Ver notarizar.sh."
fi

if xcrun stapler validate "$ALVO" >/dev/null 2>&1; then
    ok "bilhete de notarização grampeado (stapler validate)"
else
    falta "sem bilhete de notarização grampeado"
    nota "sem o bilhete o Mac do estranho precisa consultar a Apple na primeira abertura —"
    nota "e recusa o app se ele estiver sem internet."
fi
echo

# ---------------------------------------------------------------------------------------------
echo "== resumo"
echo "   FALHA: $FALHAS   FALTA: $FALTAS"
if [ "$FALHAS" -gt 0 ]; then
    echo "   Há defeito. Conserte antes de pensar em credencial."
    exit 1
elif [ "$FALTAS" -gt 0 ]; then
    echo "   Nenhum defeito. O que falta exige a credencial do dono — ver notarizar.sh."
    exit 2
else
    echo "   Pronto para distribuir."
    exit 0
fi
