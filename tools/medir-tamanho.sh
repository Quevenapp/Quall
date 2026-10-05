#!/usr/bin/env bash
#
# Mede o custo de tamanho de binário da libopus vendorizada, por plataforma.
#
# # Por que este script existe, e por que ele mede o `quall-probe`
#
# Tamanho de binário não é métrica decorativa neste projeto: **foi ela que escolheu
# `libdatachannel` em vez de libwebrtc**, e é ela que a Broadcast Upload Extension do iOS cobra a
# 50 MiB no iPhone 7 e no iPhone X.
#
# O que se mede é o **binário ligado e removido**, e não o `libquall.a`. O arquivo estático tem
# ~46 MB e não diz nada: ele é um caixote de membros, e o ligador descarta o que ninguém
# referencia. O `crates/quall-core/src/transport.rs` já fixou esse protocolo, e a tabela de lá é
# a linha de base contra a qual estes números se comparam.
#
# O `quall-probe` é o corpo de prova porque ele é um executável autocontido que **usa** o codec:
# um número que saísse de um binário que não chama o encoder mediria zero e mentiria.
#
# Uso:
#   tools/medir-tamanho.sh            # todos os alvos disponíveis
#   tools/medir-tamanho.sh host       # só o host
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"

SO="${1:-todos}"
TRABALHO="$(mktemp -d)"
trap 'rm -rf "$TRABALHO"' EXIT

# Remove símbolos do binário do jeito de cada plataforma. O `strip` do host não lê objeto ARM do
# Android, e usar o errado devolve o binário intacto **sem erro** — um número inflado que parece
# medição.
remover_simbolos() {
  local alvo="$1" arquivo="$2"
  case "$alvo" in
    *android*)
      local ndk_bin
      ndk_bin="$(dirname "$(command -v llvm-strip 2>/dev/null || echo /nao-existe/x)")"
      if [ -x "$ndk_bin/llvm-strip" ]; then
        "$ndk_bin/llvm-strip" --strip-unneeded "$arquivo" 2>/dev/null
      else
        echo "    (aviso: llvm-strip do NDK não encontrado; número SEM remoção)" >&2
      fi
      ;;
    *) xcrun strip -x "$arquivo" 2>/dev/null ;;
  esac
}

bytes() { wc -c <"$1" | tr -d ' '; }

# Constrói o `quall-probe` para um alvo com e sem a feature `opus` e imprime a linha da tabela.
medir() {
  local rotulo="$1" alvo="$2"; shift 2
  # O bash 3.2 do macOS estoura em `"${vazio[@]}"` sob `set -u`; a forma `+` contorna.
  local flags_alvo=()
  local dir="target"
  if [ "$alvo" != "host" ]; then
    flags_alvo=(--target "$alvo")
    dir="target/$alvo"
  fi

  local sem com
  # `--no-default-features` tira a feature `opus` do `quall-probe`; nada mais depende dela.
  if ! cargo build --release -p quall-probe --no-default-features \
        ${flags_alvo[@]+"${flags_alvo[@]}"} >"$TRABALHO/log" 2>&1; then
    echo "| $rotulo | — | — | — | falhou sem opus (ver $TRABALHO/log) |"
    cp "$TRABALHO/log" "/tmp/quall-tamanho-$rotulo-sem.log"
    return
  fi
  cp "$dir/release/quall-probe" "$TRABALHO/sem"
  remover_simbolos "$alvo" "$TRABALHO/sem"
  sem="$(bytes "$TRABALHO/sem")"

  if ! cargo build --release -p quall-probe ${flags_alvo[@]+"${flags_alvo[@]}"} \
        >"$TRABALHO/log" 2>&1; then
    echo "| $rotulo | $sem | — | — | falhou com opus |"
    cp "$TRABALHO/log" "/tmp/quall-tamanho-$rotulo-com.log"
    return
  fi
  cp "$dir/release/quall-probe" "$TRABALHO/com"
  remover_simbolos "$alvo" "$TRABALHO/com"
  com="$(bytes "$TRABALHO/com")"

  local delta=$((com - sem))
  local pct
  pct="$(awk -v d="$delta" -v s="$sem" 'BEGIN{printf "%.2f", 100*d/s}')"
  local kib
  kib="$(awk -v d="$delta" 'BEGIN{printf "%.0f", d/1024}')"
  echo "| $rotulo | $(printf "%'d" "$sem") | $(printf "%'d" "$com") | **+${kib} KiB** | +${pct}% |"
}

echo
echo "libopus vendorizada — custo no binário ligado e removido (\`quall-probe\`, release)"
echo
echo "| alvo | sem opus (B) | com opus (B) | custo | % |"
echo "|---|---|---|---|---|"

if [ "$SO" = "todos" ] || [ "$SO" = "host" ]; then
  medir "aarch64-apple-darwin (host)" host
fi

if [ "$SO" = "todos" ] || [ "$SO" = "ios" ]; then
  IPHONEOS_DEPLOYMENT_TARGET=15.0 CARGO_PROFILE_RELEASE_LTO=false \
    medir "aarch64-apple-ios (LTO desligado)" aarch64-apple-ios
fi

if [ "$SO" = "todos" ] || [ "$SO" = "android" ]; then
  # shellcheck disable=SC1091
  source tools/android-env.sh >/dev/null 2>&1 || {
    echo "| android | — | — | — | tools/android-env.sh falhou |"; exit 0; }
  medir "aarch64-linux-android" aarch64-linux-android
  medir "armv7-linux-androideabi" armv7-linux-androideabi
fi

echo
echo "Windows: não medido nesta rodada — o Dell G3 está com outra frente."
