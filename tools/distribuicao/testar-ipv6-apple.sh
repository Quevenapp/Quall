#!/bin/zsh
# Teste leve e isolado dos helpers reais. Não compila apps, Rust ou dependências C.
set -euo pipefail
raiz=${0:A:h:h:h}
saida=${1:-${TMPDIR:-/tmp}/quall-ipv6-apple}
mkdir -p "$saida/module-cache"
python3 - "$raiz/apps/ios/Quall/App/PermissaoDeRedeLocal.swift" "$saida/PermissaoExtraida.swift" <<'PY'
from pathlib import Path
import sys
fonte = Path(sys.argv[1]).read_text()
def extrair(nome):
    inicio = fonte.index(f"    static func {nome}(")
    abre = fonte.index("{", inicio)
    nivel = 1
    fim = abre + 1
    while nivel:
        c = fonte[fim]
        nivel += (c == "{") - (c == "}")
        fim += 1
    return fonte[inicio:fim]
Path(sys.argv[2]).write_text("import Foundation\nenum PermissaoDeRedeLocal {\n" +
    extrair("host") + "\n" + extrair("enderecoEhDaRedeLocal") + "\n}\n")
PY
swiftc -Onone -D IOS_ENDERECOS -module-cache-path "$saida/module-cache" \
    "$raiz/apps/ios/Quall/Comum/Enderecos.swift" \
    "$raiz/apps/ios/Quall/Teleprompter/LinkDePareamento.swift" \
    "$saida/PermissaoExtraida.swift" "$raiz/tools/distribuicao/testes-ipv6-apple.swift" \
    -o "$saida/ios-helpers"
"$saida/ios-helpers"
swiftc -Onone -module-cache-path "$saida/module-cache" \
    "$raiz/apps/macos/Sources/QuallApp/Enderecos.swift" \
    "$raiz/tools/distribuicao/testes-ipv6-apple.swift" -o "$saida/macos-helpers"
"$saida/macos-helpers"
