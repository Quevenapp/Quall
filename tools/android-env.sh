#!/usr/bin/env bash
# Aponta o cargo para os linkers do NDK. Use com `source tools/android-env.sh`.
#
# Não usamos `cargo-ndk`: a versão 4.1.2 entra em pânico neste workspace
# (`unknown package` em cli/mod.rs:523, por conflito entre o `-p` de plataforma dele e o `-p` de
# pacote do cargo). Apontar o linker direto é uma peça a menos e falha de forma legível.

: "${ANDROID_NDK_HOME:=$HOME/Library/Android/sdk/ndk/27.2.12479018}"
: "${CARGO_BUILD_JOBS:=2}"
: "${CARGO_NET_OFFLINE:=true}"
export CARGO_BUILD_JOBS CARGO_NET_OFFLINE
: "${ANDROID_API:=30}"   # piso da bancada: Galaxy A10s, Android 11

case "$(uname -s)" in
  Darwin) _host=darwin-x86_64 ;;
  Linux)  _host=linux-x86_64 ;;
  *) echo "host não suportado: $(uname -s)" >&2; return 1 2>/dev/null || exit 1 ;;
esac

_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$_host/bin"
if [ ! -d "$_bin" ]; then
  echo "NDK não encontrado em $ANDROID_NDK_HOME" >&2
  return 1 2>/dev/null || exit 1
fi

export ANDROID_NDK_HOME
export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="$_bin/armv7a-linux-androideabi$ANDROID_API-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$_bin/aarch64-linux-android$ANDROID_API-clang"

# A partir do M1 o núcleo arrasta libdatachannel e o OpenSSL dela — duas dependências C/C++ com
# build por cmake e por Makefile. Só o linker não basta:
#
# - `openssl-src` pergunta ao crate `cc` qual é o compilador e, para `armv7-linux-androideabi`,
#   o palpite dele é `arm-linux-androideabi-clang` — binário que o NDK r19+ **não tem mais**.
#   Sem `CC_<alvo>` explícito, o build morre com "command not found" no meio do libcrypto.
# - O CMake, com `CMAKE_SYSTEM_NAME=Android`, procura o NDK em `ANDROID_NDK_ROOT` ou
#   `ANDROID_NDK` (nunca em `ANDROID_NDK_HOME`) e aborta com "Neither the NDK or a standalone
#   toolchain was found" se não achar.
# - `llvm-ar`/`llvm-ranlib` do NDK precisam ser os do alvo; o `ar` do host não lê os objetos ARM.
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export ANDROID_NDK="$ANDROID_NDK_HOME"

export CC_armv7_linux_androideabi="$_bin/armv7a-linux-androideabi$ANDROID_API-clang"
export CXX_armv7_linux_androideabi="$_bin/armv7a-linux-androideabi$ANDROID_API-clang++"
export AR_armv7_linux_androideabi="$_bin/llvm-ar"
export RANLIB_armv7_linux_androideabi="$_bin/llvm-ranlib"

export CC_aarch64_linux_android="$_bin/aarch64-linux-android$ANDROID_API-clang"
export CXX_aarch64_linux_android="$_bin/aarch64-linux-android$ANDROID_API-clang++"
export AR_aarch64_linux_android="$_bin/llvm-ar"
export RANLIB_aarch64_linux_android="$_bin/llvm-ranlib"

export PATH="$_bin:$PATH"

echo "NDK $ANDROID_NDK_HOME (API $ANDROID_API) — alvos: armv7-linux-androideabi, aarch64-linux-android"
