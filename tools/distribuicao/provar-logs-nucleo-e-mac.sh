#!/bin/zsh
# Prova focal de diagnóstico, sem app, rede, câmera, mídia, Cargo/CMake ou dados pessoais.
set -euo pipefail
quall_logs_raiz=${0:A:h:h:h}
quall_logs_saida=${QUALL_SAIDA:-$(mktemp -d /tmp/quall-logs-nucleo-mac.XXXXXX)}
mkdir -p "$quall_logs_saida"
cat > "$quall_logs_saida/regressao.rs" <<RUST
#[path="$quall_logs_raiz/crates/quall-rtc/src/registro_seguro.rs"] mod rtc;
#[path="$quall_logs_raiz/crates/quall-ffi/src/registro_seguro.rs"] mod ffi;
RUST
rustc --edition=2021 --test "$quall_logs_saida/regressao.rs" -o "$quall_logs_saida/testes-rust"
"$quall_logs_saida/testes-rust"
for quall_logs_config in debug release; do
    quall_logs_flags=()
    [[ "$quall_logs_config" == debug ]] && quall_logs_flags=(-D DEBUG)
    swiftc -O "${quall_logs_flags[@]}" -module-cache-path "$quall_logs_saida/module-cache" \
        "$quall_logs_raiz/apps/macos/Sources/QuallApp/SanitizacaoDoLog.swift" \
        "$quall_logs_raiz/apps/ios/Quall/Testes/TestesDaSanitizacao.swift" \
        -o "$quall_logs_saida/testes-mac-$quall_logs_config"
    "$quall_logs_saida/testes-mac-$quall_logs_config"
done
swiftc -O -module-cache-path "$quall_logs_saida/module-cache" \
    "$quall_logs_raiz/apps/macos/Sources/QuallApp/SanitizacaoDoLog.swift" \
    "$quall_logs_raiz/apps/macos/Sources/QuallApp/Registro.swift" \
    "$quall_logs_raiz/tools/distribuicao/TestesDoRegistroMac.swift" \
    -o "$quall_logs_saida/testes-sink-mac"
quall_logs_sink=$(mktemp -d /tmp/quall-log-sink.XXXXXX)
# Foundation no processo isolado só recebeu acesso ao /tmp nesta execução do agente.
# A prova não deve confundir essa restrição do executor com o container do produto.
"$quall_logs_saida/testes-sink-mac" "$quall_logs_sink" 2> "$quall_logs_saida/stderr-sintetico.log"
cp "$quall_logs_sink/diario-sintetico.log" "$quall_logs_saida/diario-sintetico.log"
if rg -q '901234|RETER|SEGREDO SINTÉTICO|Pessoa Sintética|2001:db8' "$quall_logs_saida/stderr-sintetico.log"; then
    print -u2 'Falha: sink stderr reteve valor sintético'
    exit 1
fi
shasum -a 256 "$quall_logs_raiz/crates/quall-rtc/src/registro_seguro.rs" \
    "$quall_logs_raiz/crates/quall-ffi/src/registro_seguro.rs" \
    "$quall_logs_raiz/apps/macos/Sources/QuallApp/SanitizacaoDoLog.swift" \
    "$quall_logs_raiz/apps/macos/Sources/QuallApp/Registro.swift" \
    > "$quall_logs_saida/SHA256SUMS"
print 'Sinks Rust/macOS conferidos com dados sintéticos'
