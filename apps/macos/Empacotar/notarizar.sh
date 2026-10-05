#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Receita de notarização para distribuição direta no macOS.
# Sem QUALL_PERFIL_NOTARIZACAO, apenas verifica o pacote e informa o próximo passo.
# O perfil precisa existir no chaveiro; este script não cria nem recebe credenciais.
set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALVO="${1:-}"
PERFIL="${QUALL_PERFIL_NOTARIZACAO:-}"
[ -n "$ALVO" ] && [ -e "$ALVO" ] || { echo "uso: $0 <arquivo .dmg ou .app existente>" >&2; exit 64; }
"$AQUI/conferir-distribuicao.sh" "$ALVO"
PREVOO=$?
if [ "$PREVOO" -eq 1 ]; then
    echo "O pacote precisa ser corrigido antes da notarização." >&2
    exit 1
fi
if [ -z "$PERFIL" ]; then
    cat <<'FIM'
Nada foi enviado. Para download direto, o pacote deve estar assinado com uma
identidade Developer ID Application válida. Consulte a documentação da Apple:
https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
Configure um perfil de notarização no chaveiro fora do repositório e informe
somente seu nome em QUALL_PERFIL_NOTARIZACAO ao executar novamente esta receita.
FIM
    exit 2
fi
xcrun notarytool submit "$ALVO" --keychain-profile "$PERFIL" --wait || exit 1
xcrun stapler staple "$ALVO" || exit 1
xcrun stapler validate "$ALVO" || exit 1
"$AQUI/conferir-distribuicao.sh" "$ALVO"
