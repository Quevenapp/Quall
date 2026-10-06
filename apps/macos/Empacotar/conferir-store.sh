#!/bin/bash
# Prova estrutural local do pacote Mac Store. Não submete nem valida assinatura de distribuição.
set -uo pipefail
APP="${1:-}"
ARQUITETURAS="${2:-universal}"
[ -d "$APP/Contents" ] || { echo "uso: $0 <app> [universal|host]" >&2; exit 64; }
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../../.." && pwd)"
FALHAS=0
TMP_PROVA="$(mktemp -d /tmp/quall-store-check.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_PROVA"' EXIT
ok() { echo "OK: $1"; }
falha() { echo "FALHA: $1"; FALHAS=$((FALHAS+1)); }
INFO="$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/quall-app"
if plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null 2>&1; then ok 'manifesto de privacidade válido'; else falha 'manifesto ausente/inválido'; fi
for SDK_RECURSO in PrivacyInfo.xcprivacy Info.plist; do
    if cmp -s "$RAIZ/vendor/datachannel-sys/OpenSSL_Privacy.bundle/$SDK_RECURSO" \
        "$APP/Contents/Resources/OpenSSL_Privacy.bundle/$SDK_RECURSO"; then
        ok "recurso OpenSSL próprio conferido: $SDK_RECURSO"
    else falha "recurso OpenSSL próprio ausente/divergente: $SDK_RECURSO"; fi
done
if plutil -lint "$INFO" >/dev/null 2>&1; then ok 'Info.plist válido'; else falha 'Info.plist inválido'; fi
for CHAVE in CFBundleIdentifier CFBundleVersion CFBundleShortVersionString LSMinimumSystemVersion; do
    [ -n "$(/usr/libexec/PlistBuddy -c "Print :$CHAVE" "$INFO" 2>/dev/null)" ] || falha "metadado ausente: $CHAVE"
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO" 2>/dev/null)" = 'Quall Studio' ] \
    || falha 'CFBundleDisplayName difere de Quall Studio'
[ -x "$BIN" ] || falha 'executável principal ausente'
if [ "$(find "$APP/Contents/MacOS" -type f | wc -l | tr -d ' ')" = 1 ]; then
    ok 'só um executável, sem helper'
else falha 'Contents/MacOS contém arquivos além do executável principal'; fi
# Provas independentes: biblioteca privada poderia entrar linkada mesmo sem helper.
PROIBIDOS='CGVirtualDisplay|CMonitorVirtual|QuallMonitorVirtual|MonitorVirtualAuxiliar|quall-monitor-virtual|--tela-estendida|--gop-tela-estendida'
if [ -x "$BIN" ]; then
    if ! nm -a "$BIN" > "$TMP_PROVA/simbolos" 2> "$TMP_PROVA/nm.erro"; then falha 'nm não conseguiu ler o executável'
    elif LC_ALL=C grep -E "$PROIBIDOS" "$TMP_PROVA/simbolos" >/dev/null; then falha 'símbolos de monitor virtual no executável'
    else ok 'símbolos de monitor virtual ausentes'; fi
    if ! strings -a "$BIN" > "$TMP_PROVA/strings" 2> "$TMP_PROVA/strings.erro"; then falha 'strings não conseguiu ler o executável'
    elif LC_ALL=C grep -E "$PROIBIDOS" "$TMP_PROVA/strings" >/dev/null; then falha 'strings de API privada/helper/argumentos futuros no executável'
    else ok 'strings de API privada/helper/argumentos futuros ausentes'; fi
    if ! otool -L "$BIN" > "$TMP_PROVA/dependencias" 2> "$TMP_PROVA/otool.erro"; then falha 'otool não conseguiu ler o executável'
    elif ! python3 - "$TMP_PROVA/dependencias" <<'PYDEP'
import pathlib,sys
paths=[line.split()[0] for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line[:1].isspace()]
invalid=[p for p in paths if not p.startswith(("/System/Library/", "/usr/lib/"))]
if invalid:print("Dependências não resolvidas como bibliotecas do sistema:",", ".join(invalid))
sys.exit(bool(invalid) or not paths)
PYDEP
    then falha 'dependência fora do sistema ou @rpath não resolvido (não distribuir)'
    else ok 'só dependências dinâmicas do sistema'; fi
    ARQS="$(lipo -archs "$BIN" 2>/dev/null)"
    [ -n "$ARQS" ] || falha 'lipo não conseguiu ler arquiteturas'
    LSMIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO" 2>/dev/null)"
    for ARQ in $ARQS; do
        if ! vtool -arch "$ARQ" -show-build-version "$BIN" > "$TMP_PROVA/minos-$ARQ" 2>/dev/null; then
            falha "vtool não leu o piso $ARQ"
        elif python3 - "$TMP_PROVA/minos-$ARQ" "$LSMIN" <<'PYMIN'
import pathlib,re,sys
src=pathlib.Path(sys.argv[1]).read_text();versions=re.findall(r"\bminos ([0-9.]+)",src)
def normal(x):
    v=[int(p) for p in x.split('.')]
    while v and v[-1]==0:v.pop()
    return v
sys.exit(not versions or any(normal(v)!=normal(sys.argv[2]) for v in versions) or 'platform MACOS' not in src)
PYMIN
        then ok "piso $ARQ coerente com Info.plist: $LSMIN"
        else falha "piso do binário $ARQ difere de Info.plist"; fi
    done
    case "$ARQUITETURAS:$ARQS" in
        universal:*arm64*x86_64*|universal:*x86_64*arm64*) ok "universal: $ARQS" ;;
        host:*) ok "conferência só da arquitetura local: $ARQS" ;;
        *) falha "arquiteturas insuficientes: $ARQS" ;;
    esac
fi
# Fontes preservados no checkout e strings exclusivas do futuro não entram nos recursos.
if find "$APP/Contents" -type f | LC_ALL=C grep -E 'monitor-virtual|CMonitorVirtual|/Futuro/|\.(swift|m|h)$' >/dev/null; then
    falha 'helper/fontes futuros dentro do pacote'
else ok 'nenhum helper/fonte futuro no pacote'; fi
AVISOS="$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
if [ -s "$AVISOS" ] && cmp -s "$RAIZ/THIRD_PARTY_NOTICES.txt" "$AVISOS"; then
    ok "avisos iguais à raiz: $(shasum -a 256 "$AVISOS" | awk '{print $1}')"
else falha 'avisos ausentes/vazios/diferentes da raiz'; fi
TABELA="$APP/Contents/Resources/QuallCapture_QuallIdiomaKit.bundle/en.lproj/Localizable.strings"
if [ -f "$TABELA" ]; then
    if plutil -convert json -o - "$TABELA" | python3 -c '
import json,pathlib,sys
t=json.load(sys.stdin)
exclusivas=set(pathlib.Path(sys.argv[1]).read_text().splitlines())
presentes=sorted(exclusivas.intersection(t))
privadas=[k for k in t if "CGVirtualDisplay" in k]
if presentes or privadas:print("Chaves futuras no recurso:", presentes or privadas)
sys.exit(bool(presentes or privadas))
' "$AQUI/../Futuro/mapa-traducoes-tela-estendida.txt"; then
        ok 'tabela EN sem chaves exclusivas do monitor virtual'
    else falha 'tabela EN ainda contém chaves do monitor virtual'; fi
else falha 'tabela EN ausente'; fi
for IDIOMA in pt en; do
    [ -f "$APP/Contents/Resources/$IDIOMA.lproj/InfoPlist.strings" ] || falha "permissões sem $IDIOMA"
done
[ -f "$APP/Contents/Resources/Quall.icns" ] || falha 'ícone ausente'
if codesign --verify --deep --strict "$APP" 2>/dev/null; then ok 'assinatura local íntegra'; else falha 'assinatura local inválida'; fi
ENT="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
if printf '%s' "$ENT" | python3 -c '
import plistlib,sys
try:t=plistlib.loads(sys.stdin.buffer.read())
except Exception:sys.exit(1)
required={"com.apple.security.app-sandbox","com.apple.security.network.client","com.apple.security.network.server","com.apple.security.device.camera","com.apple.security.device.audio-input","com.apple.security.assets.movies.read-write"}
for k in required:
    if t.get(k) is not True:print("Falta entitlement:",k);sys.exit(1)
if any("temporary-exception" in k or "disable-library-validation" in k or "get-task-allow" in k for k in t):sys.exit(1)
'; then ok 'sandbox, rede, câmera, microfone e Movies; sem exceções/depuração'
else falha 'entitlements diferem dos necessários à primeira release'; fi
if [ "$FALHAS" -ne 0 ]; then echo "Conferência local: $FALHAS falha(s)."; exit 1; fi
echo 'Conferência estrutural local passou. Runtime sandbox ainda deve ser testado.'
echo 'Exportação/perfil/assinatura Mac App Store, testes Intel e App Review não são provados aqui.'
