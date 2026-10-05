#!/bin/bash
# Pacote local da mesma primeira release: arquitetura do host, sandbox e nenhum monitor virtual.
# Não copia para ~/Applications. QUALL_APP_DESTINO pode apontar para um .app de bancada isolado.
# Uma identidade Apple Development existente pode ser passada por QUALL_IDENTIDADE.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS="$(cd "$AQUI/.." && pwd)"
export QUALL_ARQUITETURAS=host
export QUALL_APP_DESTINO="${QUALL_APP_DESTINO:-$MACOS/.build/Quall Studio.app}"
exec "$AQUI/empacotar-store.sh" "$@"
