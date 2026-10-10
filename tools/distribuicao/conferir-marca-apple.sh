#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# A marca de produto é uma entrada separada dos placeholders MPL do snapshot público.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
PLATAFORMA="${1:?ios ou mac}"
case "$PLATAFORMA" in
    ios)
        NOME=AppIcon-1024.png
        DESTINO="$RAIZ/apps/ios/Quall/App/Assets.xcassets/AppIcon.appiconset/$NOME"
        SHA=28a72896c050fc9d1bcbe140b6d73ba23f1ec783703c71fb5bb31338931b8a20 ;;
    mac)
        NOME=Quall.icns
        DESTINO="$RAIZ/apps/macos/Empacotar/$NOME"
        SHA=a4d25fa345376bee7369235718a4043c62cf155887acba6e5764b183ea43c24a ;;
    *) echo 'Plataforma inválida.' >&2; exit 64 ;;
esac
if [ -n "${QUALL_MARCA_APPLE_DIR:-}" ]; then
    [ -f "$QUALL_MARCA_APPLE_DIR/$NOME" ] || { echo 'Entrada de marca aprovada ausente.' >&2; exit 1; }
    cp "$QUALL_MARCA_APPLE_DIR/$NOME" "$DESTINO"
    UI_PATCH="$QUALL_MARCA_APPLE_DIR/marca-ui.patch"
    [ "$(shasum -a 256 "$UI_PATCH" | awk '{print $1}')" = 2d7d7e80cd34fdecd89da5bce31dff15f9c4e5b1765d0d78cbde26daeceec31c ] || {
        echo 'Overlay da marca nas interfaces ausente ou divergente.' >&2; exit 1;
    }
    if (cd "$RAIZ" && git apply --check "$UI_PATCH"); then
        (cd "$RAIZ" && git apply "$UI_PATCH")
    elif ! (cd "$RAIZ" && git apply --reverse --check "$UI_PATCH"); then
        echo 'A interface diverge da base do overlay aprovado; revise a integração.' >&2; exit 1;
    fi
fi
python3 - "$DESTINO" "$SHA" "$PLATAFORMA" <<'PY'
import hashlib, pathlib, struct, sys
p = pathlib.Path(sys.argv[1]); b = p.read_bytes()
if hashlib.sha256(b).hexdigest() != sys.argv[2]:
    raise SystemExit('Arte não corresponde à marca de produto aprovada. Forneça QUALL_MARCA_APPLE_DIR; não exportar o placeholder como app oficial.')
if sys.argv[3] == 'ios':
    if b[:8] != b'\x89PNG\r\n\x1a\n' or b[12:16] != b'IHDR':
        raise SystemExit('AppIcon inválido')
    width, height, depth, color = struct.unpack('>IIBB', b[16:26])
    if (width, height, depth, color) != (1024, 1024, 8, 2):
        raise SystemExit('AppIcon precisa ser RGB opaco 1024x1024')
print('Marca Apple aprovada conferida:', p.name)
PY
python3 - "$RAIZ" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 'apps/ios/Quall/App/Estilo.swift':'692f62bd92af7a59e0fdb04bfeb2f8ea2ba1547b51a5e05aa3028c150610f74e',
 'apps/macos/Sources/QuallApp/Estilo.swift':'6a87a9eda7fa2a76289b5e01d397891690d446827112cda007a5ad88c574cf33',
 'apps/macos/Sources/QuallBarraDeMenusKit/MarcaNaBarra.swift':'5c41668c40c98c1c851171919c78d6e1f2e3714f7ddaab7b60db57e93a3a1be6',
 'apps/macos/Tests/QuallBarraDeMenusKitTests/TestesDaMarcaNaBarra.swift':'dbed46c0b8b43bc7d9ab30d8b4bc310f85b25a3a53c01f2f4d7c15e058bedeb5',
}
for rel,sha in expected.items():
 if hashlib.sha256((root/rel).read_bytes()).hexdigest()!=sha:
  raise SystemExit('Marca de interface diverge do overlay aprovado: '+rel)
print('Marca nas interfaces Apple conferida')
PY
