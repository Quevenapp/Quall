#!/bin/zsh
# Regressão Foundation pura: não constrói/abre app, extensão, mídia ou rede.
set -euo pipefail

DIRETORIO_PROVA="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -gt 1 ]]; then
  print -u2 -- "uso: $0 [diretório-novo-de-resultados]"
  exit 2
fi
if [[ $# -eq 0 ]]; then
  DIRETORIO_RESULTADO=$(mktemp -d "${TMPDIR:-/tmp}/quall-camera-registro.XXXXXX")
else
  DIRETORIO_RESULTADO="$1"
  if [[ -e "$DIRETORIO_RESULTADO" ]]; then
    print -u2 -- "Use um diretório novo; a prova não sobrescreve resultados."
    exit 2
  fi
  mkdir -p "$DIRETORIO_RESULTADO"
fi
DIRETORIO_RESULTADO="$(cd "$DIRETORIO_RESULTADO" && pwd)"
mkdir -p "$DIRETORIO_RESULTADO/cache"

# Copiar as fontes fixa a prova e permite Swift top-level em main.swift, sem incluí-la no Xcode.
cp "$DIRETORIO_PROVA/prova-registro-seguro.swift" "$DIRETORIO_RESULTADO/main.swift"
cp "$DIRETORIO_PROVA/../Fontes/App/RegistroSeguro.swift" "$DIRETORIO_RESULTADO/RegistroSeguro.swift"
xcrun swiftc -module-cache-path "$DIRETORIO_RESULTADO/cache" \
  "$DIRETORIO_RESULTADO/RegistroSeguro.swift" "$DIRETORIO_RESULTADO/main.swift" \
  -o "$DIRETORIO_RESULTADO/prova-registro"
"$DIRETORIO_RESULTADO/prova-registro" | tee "$DIRETORIO_RESULTADO/resultado.log"
shasum -a 256 "$DIRETORIO_RESULTADO/RegistroSeguro.swift" "$DIRETORIO_RESULTADO/main.swift" \
  "$DIRETORIO_RESULTADO/prova-registro" "$DIRETORIO_RESULTADO/resultado.log" \
  > "$DIRETORIO_RESULTADO/SHA256SUMS"
print -- "Evidências: $DIRETORIO_RESULTADO"
