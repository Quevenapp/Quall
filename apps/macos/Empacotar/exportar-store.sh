#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Exporta o bundle universal já conferido para PKG Mac App Store; nenhum upload.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:?uso: exportar-store.sh app-local perfil-mac-app-store pasta-saida}"
PERFIL="${2:?perfil Mac App Store Connect}"
SAIDA="${3:?pasta de saída absoluta}"
APP_IDENTIDADE="${QUALL_STORE_APP_IDENTIDADE:?identidade Apple Distribution ou Mac App Distribution}"
PKG_IDENTIDADE="${QUALL_STORE_INSTALLER_IDENTIDADE:?identidade Mac Installer Distribution}"
case "$APP" in /*.app) ;; *) echo 'O app deve ter caminho absoluto.' >&2; exit 64 ;; esac
case "$SAIDA" in /*) ;; *) echo 'A pasta de saída deve ter caminho absoluto.' >&2; exit 64 ;; esac
[ -f "$PERFIL" ] || { echo 'Perfil inexistente.' >&2; exit 1; }
"$AQUI/conferir-store.sh" "$APP" universal
PROVA="$(mktemp -d /tmp/quall-store-export.XXXXXX)"
trap 'rm -rf "$PROVA"' EXIT
security cms -D -i "$PERFIL" > "$PROVA/perfil.plist"
security find-identity -v -p basic > "$PROVA/identidades.txt"
python3 - "$PROVA/perfil.plist" "$PROVA/identidades.txt" "$AQUI/Quall.entitlements" \
    "$APP_IDENTIDADE" "$PKG_IDENTIDADE" "$PROVA/entitlements.plist" <<'PY'
import datetime, hashlib, pathlib, plistlib, re, sys
profile = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
identities = re.findall(r'([A-Fa-f0-9]{40}) "([^"]+)"', pathlib.Path(sys.argv[2]).read_text())
def identity(query, prefixes):
    matches = [(h, name) for h, name in identities if h.lower() == query.lower() or name == query]
    if len(matches) != 1 or not matches[0][1].startswith(prefixes):
        raise SystemExit('Identidade de distribuição ausente, ambígua ou de outro canal.')
    return matches[0]
app_cert, app_name = identity(sys.argv[4], ('Apple Distribution:', '3rd Party Mac Developer Application:'))
identity(sys.argv[5], ('3rd Party Mac Developer Installer:', 'Mac Installer Distribution:'))
certificates = {hashlib.sha1(c).hexdigest() for c in profile.get('DeveloperCertificates', [])}
if app_cert.lower() not in certificates:
    raise SystemExit('Certificado de assinatura não corresponde ao perfil.')
if profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices'):
    raise SystemExit('Perfil de desenvolvimento/Ad Hoc/Developer ID não serve para Store.')
if 'OSX' not in profile.get('Platform', []):
    raise SystemExit('Perfil não é macOS.')
if profile.get('ExpirationDate', datetime.datetime.min) <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    raise SystemExit('Perfil expirado.')
if profile.get('TeamIdentifier') != ['A6AXA7CBU3']:
    raise SystemExit('Perfil pertence a outro time.')
p_ent = profile.get('Entitlements', {})
key = 'com.apple.application-identifier'
identifier = p_ent.get(key, p_ent.get('application-identifier'))
if identifier != 'A6AXA7CBU3.br.com.queven.quall' or p_ent.get('get-task-allow') or p_ent.get('com.apple.security.get-task-allow'):
    raise SystemExit('Identificador ou entitlement de depuração incorreto.')
ent = plistlib.loads(pathlib.Path(sys.argv[3]).read_bytes())
ent[key] = identifier
ent['com.apple.developer.team-identifier'] = 'A6AXA7CBU3'
pathlib.Path(sys.argv[6]).write_bytes(plistlib.dumps(ent))
print('Perfil de distribuição, certificado, time e identificador conferidos.')
PY
mkdir -p "$SAIDA"
DESTINO="$SAIDA/Quall Studio.app"
PKG="$SAIDA/Quall Studio.pkg"
[ ! -e "$DESTINO" ] && [ ! -e "$PKG" ] || { echo 'Saída já existe; escolha outra pasta para preservar o pacote.' >&2; exit 1; }
cp -R "$APP" "$DESTINO"
cp "$PERFIL" "$DESTINO/Contents/embedded.provisionprofile"
codesign --force --sign "$APP_IDENTIDADE" --options runtime --timestamp \
    --entitlements "$PROVA/entitlements.plist" "$DESTINO"
codesign --verify --deep --strict "$DESTINO"
"$AQUI/conferir-store.sh" "$DESTINO" universal
productbuild --component "$DESTINO" /Applications --sign "$PKG_IDENTIDADE" "$PKG"
pkgutil --check-signature "$PKG"
shasum -a 256 "$PKG" > "$PKG.sha256"
echo "PKG exportado e assinatura conferida: $PKG"
echo 'Nenhum upload, envio à revisão ou publicação foi realizado.'
