#!/bin/zsh
# Monta o .pkg do plugin do OBS para macOS: assina o `quall-obs.plugin` (Developer ID Application,
# hardened runtime), empacota para a pasta de plugins **do usuário**, assina o pacote (Developer ID
# Installer), notariza e grampeia. Ver LEIA.md, ao lado.
#
#   plugins/obs/instalador/construir-pkg.sh                      # compila (../construir.sh --sem-instalar) e empacota
#   plugins/obs/instalador/construir-pkg.sh --plugin <quall-obs.plugin>   # empacota um plugin pronto
#
# Opções: --versao X.Y.Z (padrão: CFBundleShortVersionString do plugin), --obs-minimo X.Y.Z (padrão:
# major.minor dos cabeçalhos em ../.libobs), --saida <pasta>, --reassinar, --sem-notarizar.
#
# Não instala nada. Quem instala é o Bruno, com o pacote na mão.
#
# O molde é o do obs-plugintemplate (`cmake/macos/resources/create-package.cmake.in` e
# `distribution.in`, conferidos em 14/10/2026): `pkgbuild` com a raiz em
# `Library/Application Support/obs-studio/plugins`, `productbuild` com
# `<domains enable_currentUserHome="true"/>`, `productsign`/`--sign` com o Developer ID Installer e
# `notarytool` + `stapler` no pacote. Duas coisas a mais, e por quê:
#
# 1. **`BundleIsRelocatable` desligado.** O padrão do `pkgbuild` é deixar o Installer "achar" um
#    bundle de mesmo identificador em outro lugar do disco e atualizar *aquele*. Nesta máquina há
#    cópias do `quall-obs.plugin` em `build/` e no scratch; a atualização iria para lá e o OBS
#    continuaria com o velho.
# 2. **O plugin já assinado com Developer ID e runtime não é reassinado** (salvo `--reassinar`). O
#    binário publicado no obsproject.com (1.0.0) tem soma registrada na proveniência; reassinar troca
#    a assinatura e a soma sem ganho nenhum.
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$AQUI/.." && pwd)"
ID_PACOTE="br.com.queven.quall.obs"
# Há DOIS "Developer ID Application: Veneri & Quellis Ltda (A6AXA7CBU3)" nas Chaves, e o `codesign`
# recusa um nome ambíguo. O padrão é o de 31/08/2026 que vale até 2031 e assinou o obs-v1.0.0
# (o outro vence em 01/02/2027).
ID_APLICACAO="${QUALL_ID_APLICACAO:-05A31ECC9B665A6DE5EBDA556CB2C695974AB382}"
ID_INSTALADOR="${QUALL_ID_INSTALADOR:-Developer ID Installer: Veneri & Quellis Ltda (A6AXA7CBU3)}"
TIME="A6AXA7CBU3"
PERFIL="${QUALL_PERFIL_NOTARIZACAO:-quall-notarizacao}"
# Por SSH o perfil fica num keychain próprio (ver o guia do Mac em D:\code\mac): passe-o em
# QUALL_KEYCHAIN_NOTARIZACAO. Sem a variável, o notarytool procura nas Chaves de sempre.
NOTARIZACAO_KC=()
[[ -n "${QUALL_KEYCHAIN_NOTARIZACAO:-}" ]] && NOTARIZACAO_KC=(--keychain "$QUALL_KEYCHAIN_NOTARIZACAO")

PLUGIN="" VERSAO="" OBS_MINIMO="" SAIDA="/Volumes/Dev/code/quall-scratch/obs-instalador/macos"
REASSINAR=false NOTARIZAR=true
while (( $# )); do
  case "$1" in
    --plugin) PLUGIN="$2"; shift 2 ;;
    --versao) VERSAO="$2"; shift 2 ;;
    --obs-minimo) OBS_MINIMO="$2"; shift 2 ;;
    --saida) SAIDA="$2"; shift 2 ;;
    --reassinar) REASSINAR=true; shift ;;
    --sem-notarizar) NOTARIZAR=false; shift ;;
    *) echo "opção desconhecida: $1 (ver o cabeçalho)" >&2; exit 2 ;;
  esac
done

falhar() { echo "PARADO: $*" >&2; exit 1; }

case "$SAIDA" in /tmp/*|/private/tmp/*) falhar "a saída não vai para /tmp: use o HD externo" ;; esac

# --- o plugin ----------------------------------------------------------------------------------
if [[ -z "$PLUGIN" ]]; then
  echo "== compilando (construir.sh --sem-instalar)"
  "$PLUGIN_DIR/construir.sh" --sem-instalar
  PLUGIN="$PLUGIN_DIR/build/quall-obs.plugin"
fi
PLUGIN="${PLUGIN%/}"
[[ -d "$PLUGIN" && "$(basename "$PLUGIN")" == "quall-obs.plugin" ]] || falhar "não é um quall-obs.plugin: $PLUGIN"
INFO="$PLUGIN/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$INFO")" == "$ID_PACOTE" ]] || falhar "identificador do bundle não é $ID_PACOTE"
[[ -f "$PLUGIN/Contents/MacOS/quall-obs" ]] || falhar "falta Contents/MacOS/quall-obs"
for f in LICENSE LICENSE-SCOPE.md LICENSE-MPL-2.0.txt THIRD_PARTY_NOTICES.txt locale/en-US.ini locale/pt-BR.ini; do
  [[ -s "$PLUGIN/Contents/Resources/$f" ]] || falhar "falta Contents/Resources/$f (licenças e traduções vão no pacote)"
done
[[ -n "$VERSAO" ]] || VERSAO="$(plutil -extract CFBundleShortVersionString raw "$INFO")"
MACOS_MINIMO="$(plutil -extract LSMinimumSystemVersion raw "$INFO" 2>/dev/null || echo 13.0)"
ARQS="$(lipo -archs "$PLUGIN/Contents/MacOS/quall-obs")"
ARQUITETURAS="${ARQS// /,}"
case "$ARQS" in
  arm64) SUFIXO="macos-arm64" ;;
  *arm64*x86_64*|*x86_64*arm64*) SUFIXO="macos-universal" ;;
  x86_64) SUFIXO="macos-x64" ;;
  *) falhar "arquiteturas inesperadas: $ARQS" ;;
esac

# O OBS recusa major/minor de API mais novos que ele e ignora o patch (README do plugin): o mínimo
# é o major.minor dos cabeçalhos com que o plugin foi compilado.
if [[ -z "$OBS_MINIMO" ]]; then
  CFG="$PLUGIN_DIR/.libobs/obs-studio/libobs/obs-config.h"
  [[ -f "$CFG" ]] || falhar "sem $CFG para tirar o OBS mínimo; passe --obs-minimo X.Y.0"
  MAJ=$(awk '/#define LIBOBS_API_MAJOR_VER/{print $3}' "$CFG")
  MIN=$(awk '/#define LIBOBS_API_MINOR_VER/{print $3}' "$CFG")
  OBS_MINIMO="$MAJ.$MIN.0"
fi
[[ "$OBS_MINIMO" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || falhar "OBS mínimo inválido: $OBS_MINIMO"

NOME="QuallOBS-$VERSAO-$SUFIXO.pkg"
echo "== plugin: $PLUGIN"
echo "   versão $VERSAO, $ARQS, macOS $MACOS_MINIMO+, OBS $OBS_MINIMO+  ->  $SAIDA/$NOME"

# --- estágio -----------------------------------------------------------------------------------
ESTAGIO="$SAIDA/estagio"
rm -rf "$ESTAGIO"
mkdir -p "$ESTAGIO/raiz" "$ESTAGIO/componentes" "$ESTAGIO/recursos"
ditto "$PLUGIN" "$ESTAGIO/raiz/quall-obs.plugin"
P="$ESTAGIO/raiz/quall-obs.plugin"
find "$P" -name '.DS_Store' -delete
xattr -cr "$P"

# --- assinatura do plugin ----------------------------------------------------------------------
security find-identity -v -p codesigning | grep -q "$ID_APLICACAO" \
  || falhar "identidade de assinatura ausente nas Chaves: $ID_APLICACAO"
security find-identity -v -p basic | grep -qF "$ID_INSTALADOR" \
  || falhar "identidade de instalador ausente nas Chaves: $ID_INSTALADOR"

ja_distribuivel() {
  local d; d="$(codesign -dvv "$P" 2>&1)" || return 1
  [[ "$d" == *"Authority=Developer ID Application:"*"($TIME)"* ]] || return 1
  [[ "$d" == *"(runtime)"* ]] || return 1
  [[ "$d" == *"Timestamp="* ]] || return 1
  codesign --verify --strict --deep "$P" 2>/dev/null
}
if ! $REASSINAR && ja_distribuivel; then
  echo "== o plugin já tem Developer ID ($TIME), runtime e carimbo: mantido como veio"
else
  echo "== assinando o plugin (Developer ID Application, hardened runtime, carimbo de tempo)"
  codesign --force --options runtime --timestamp --sign "$ID_APLICACAO" "$P"
fi
codesign --verify --strict --deep -v "$P"
codesign -dvv "$P" 2>&1 | grep -E '^(Authority|TeamIdentifier|Timestamp|CodeDirectory)' | sed 's/^/   /'

# --- pacote de componente ----------------------------------------------------------------------
COMP="$ESTAGIO/componente.plist"
pkgbuild --analyze --root "$ESTAGIO/raiz" "$COMP" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$COMP"
plutil -replace 0.BundleOverwriteAction -string upgrade "$COMP"
plutil -replace 0.BundleHasStrictIdentifier -bool YES "$COMP"
# Instalação por domínio do usuário: o caminho é relativo ao home de quem instala.
pkgbuild --root "$ESTAGIO/raiz" \
  --component-plist "$COMP" \
  --identifier "$ID_PACOTE" \
  --version "$VERSAO" \
  --install-location "/Library/Application Support/obs-studio/plugins" \
  "$ESTAGIO/componentes/quall-obs.pkg"

# --- distribuição ------------------------------------------------------------------------------
sed -e "s|@ID@|$ID_PACOTE|g" -e "s|@VERSAO@|$VERSAO|g" -e "s|@OBS_MINIMO@|$OBS_MINIMO|g" \
    -e "s|@MACOS_MINIMO@|$MACOS_MINIMO|g" -e "s|@ARQUITETURAS@|$ARQUITETURAS|g" \
    "$AQUI/macos/distribution.xml.in" > "$ESTAGIO/distribution.xml"
grep -q '@[A-Z_]*@' "$ESTAGIO/distribution.xml" && falhar "sobrou marcador na distribuição"
xmllint --noout "$ESTAGIO/distribution.xml"
cp -R "$AQUI/macos/en.lproj" "$AQUI/macos/pt.lproj" "$ESTAGIO/recursos/"
for l in en pt; do plutil -lint "$ESTAGIO/recursos/$l.lproj/Localizable.strings" >/dev/null; done

mkdir -p "$SAIDA"
PKG="$SAIDA/$NOME"
rm -f "$PKG"
productbuild --distribution "$ESTAGIO/distribution.xml" \
  --package-path "$ESTAGIO/componentes" \
  --resources "$ESTAGIO/recursos" \
  --sign "$ID_INSTALADOR" --timestamp \
  "$PKG"

# --- notarização -------------------------------------------------------------------------------
if $NOTARIZAR; then
  if xcrun notarytool history --keychain-profile "$PERFIL" "${NOTARIZACAO_KC[@]}" >/dev/null 2>&1; then
    echo "== notarizando com o perfil '$PERFIL' (espera o resultado)"
    RESP="$(xcrun notarytool submit "$PKG" --keychain-profile "$PERFIL" "${NOTARIZACAO_KC[@]}" --wait --output-format json)"
    echo "$RESP"
    ESTADO="$(print -r -- "$RESP" | plutil -extract status raw - 2>/dev/null || true)"
    ENVIO="$(print -r -- "$RESP" | plutil -extract id raw - 2>/dev/null || true)"
    if [[ "$ESTADO" != "Accepted" ]]; then
      falhar "a notarização não aceitou ($ESTADO). Relatório: xcrun notarytool log $ENVIO --keychain-profile $PERFIL"
    fi
    xcrun stapler staple "$PKG"
    xcrun stapler validate "$PKG"
    print -r -- "$ENVIO" > "$PKG.notarizacao"
  else
    cat <<FIM
== SEM NOTARIZAÇÃO: não há o perfil '$PERFIL' do notarytool nas Chaves.
   O pacote está assinado, mas o Gatekeeper recusa pacote baixado sem bilhete. Quem tem a conta cria
   o perfil uma vez (ver apps/macos/Empacotar/notarizar.sh) e roda:
     xcrun notarytool submit "$PKG" --keychain-profile "$PERFIL" --wait
     xcrun stapler staple "$PKG"
FIM
  fi
fi

# --- conferências ------------------------------------------------------------------------------
echo "== pkgutil --check-signature"
pkgutil --check-signature "$PKG"
echo "== spctl -a -vv -t install"
spctl -a -vv -t install "$PKG" || echo "   (spctl recusou: sem notarização isto é o esperado)"
echo "== conteúdo"
EXP="$ESTAGIO/expandido"
rm -rf "$EXP"
pkgutil --expand "$PKG" "$EXP"
grep -o 'install-location="[^"]*"' "$EXP/quall-obs.pkg/PackageInfo"
grep -o 'relocatable="[^"]*"' "$EXP/quall-obs.pkg/PackageInfo"
pkgutil --payload-files "$PKG" | grep -v '/\._' | grep -E 'MacOS/quall-obs$|locale/|THIRD_PARTY' | sed 's/^/   /'
# Os `._*` do payload são o `com.apple.provenance` que o macOS 26+ pendura em todo arquivo escrito
# por processo rastreado (o shell do agente, por exemplo) e que nem `xattr -c` tira. O `pkgbuild` os
# guarda como AppleDouble e o Installer os devolve como atributo, não como arquivo; a assinatura não
# cobre atributo. Conferido em 14/10/2026: só esse atributo, nada de Finder Info nem resource fork.
if pkgutil --payload-files "$PKG" | grep '/\._' >/dev/null; then
  echo "   (com AppleDouble de atributo: ver o comentário acima)"
fi
shasum -a 256 "$PKG" "$P/Contents/MacOS/quall-obs" | sed 's/^/   /'
echo "== pronto: $PKG ($(du -h "$PKG" | cut -f1))"
