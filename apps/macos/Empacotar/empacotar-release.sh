#!/bin/bash
# Compatibilidade do comando anterior: primeira release escolhida pela Mac App Store.
# O pacote conferível é produzido por empacotar-store.sh; não há DMG/notarização/publicação.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$AQUI/empacotar-store.sh" "$@"
