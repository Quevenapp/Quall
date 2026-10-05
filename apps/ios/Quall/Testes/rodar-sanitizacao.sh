#!/bin/zsh
# Regressão pura Foundation: mesmos casos em Debug e Release; não compila app nem núcleo.
set -euo pipefail
quall_log_aqui=${0:A:h}
quall_log_saida=${QUALL_SAIDA:-$(mktemp -d /tmp/quall-log-ios.XXXXXX)}
mkdir -p "$quall_log_saida"
for quall_log_config in debug release; do
  quall_log_flags=()
  [[ "$quall_log_config" == debug ]] && quall_log_flags=(-D DEBUG)
  swiftc -O "${quall_log_flags[@]}" \
    -module-cache-path "$quall_log_saida/module-cache" \
    "$quall_log_aqui/../Comum/SanitizacaoDoLog.swift" "$quall_log_aqui/TestesDaSanitizacao.swift" \
    -o "$quall_log_saida/testes-sanitizacao-$quall_log_config"
  "$quall_log_saida/testes-sanitizacao-$quall_log_config"
done
