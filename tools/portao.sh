#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Compilação sequencial do snapshot. Não instala apps, extensões ou drivers.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/.." && pwd)"
DIARIOS="$RAIZ/target/portao"
JOBS="${QUALL_JOBS:-2}"
export CARGO_BUILD_JOBS="$JOBS" CMAKE_BUILD_PARALLEL_LEVEL="$JOBS"
OFFLINE=(--offline)
SUPERFICIES=(nucleo fronteira macos camera-macos ios-quall ios-portao-appex android-so android-apk windows obs)
ESCOLHIDAS=()
SEM_WINDOWS=0
SEM_OBS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lista) printf '%s\n' "${SUPERFICIES[@]}"; exit 0 ;;
    --so) shift; while [ $# -gt 0 ] && [[ "$1" != --* ]]; do ESCOLHIDAS+=("$1"); shift; done ;;
    --sem-windows) SEM_WINDOWS=1; shift ;;
    --sem-obs) SEM_OBS=1; shift ;;
    --com-rede) OFFLINE=(); shift ;;
    --parar-no-primeiro) shift ;; # O snapshot já interrompe na primeira falha.
    -h|--help) printf '%s\n' 'Uso: tools/portao.sh [--so superfície ...] [--sem-windows] [--sem-obs] [--com-rede]' 'Padrão: offline, jobs=2, sem instalação. Windows exige execução local de tools/portao.ps1 no Windows.'; exit 0 ;;
    *) echo "Argumento desconhecido: $1" >&2; exit 2 ;;
  esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'QUALL_JOBS deve ser inteiro positivo.' >&2; exit 2; }
[ ${#ESCOLHIDAS[@]} -gt 0 ] || ESCOLHIDAS=("${SUPERFICIES[@]}")
export CARGO_NET_OFFLINE=false QUALL_OFFLINE=0
[ ${#OFFLINE[@]} -eq 0 ] || export CARGO_NET_OFFLINE=true QUALL_OFFLINE=1
mkdir -p "$DIARIOS"
garantir_xcconfig() {
  [ -f "$RAIZ/Signing.local.xcconfig" ] || cp "$RAIZ/Signing.local.xcconfig.example" "$RAIZ/Signing.local.xcconfig"
}
nucleo_apple() {
  local alvo="$1"
  env MACOSX_DEPLOYMENT_TARGET=13.0 IPHONEOS_DEPLOYMENT_TARGET=15.0 CARGO_PROFILE_RELEASE_LTO=false \
    cargo build --locked "${OFFLINE[@]}" -j "$JOBS" -p quall-ffi --release --target "$alvo"
}
correr() {
  local superficie="$1"
  case "$superficie" in
    nucleo) cargo test --locked "${OFFLINE[@]}" -j "$JOBS" --workspace ;;
    fronteira)
      python3 "$AQUI/confere-fronteira.py" --calibrar
      python3 "$AQUI/confere-fronteira.py"
      for exemplo in "$RAIZ"/crates/quall-ffi/examples/*.c; do
        cc -c -o /dev/null "$exemplo" -I"$RAIZ/crates/quall-ffi/include" -Wall -Wextra -Werror
      done ;;
    macos)
      env MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_PROFILE_RELEASE_LTO=false \
        cargo build --locked "${OFFLINE[@]}" -j "$JOBS" -p quall-ffi --release
      (cd "$RAIZ/apps/macos" && swift build --jobs "$JOBS" && swift test --jobs "$JOBS") ;;
    camera-macos)
      garantir_xcconfig
      nucleo_apple aarch64-apple-darwin
      (cd "$RAIZ/integrations/camera-macos" && xcodegen generate && xcodebuild \
        -project QuallCamera.xcodeproj -scheme QuallCamera -configuration Release -jobs "$JOBS" \
        -derivedDataPath "$DIARIOS/dd-camera-macos" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build) ;;
    ios-quall|ios-portao-appex)
      garantir_xcconfig
      nucleo_apple aarch64-apple-ios
      local pasta=Quall projeto=Quall esquema=Quall
      if [ "$superficie" = ios-portao-appex ]; then pasta=PortaoAppex; projeto=PortaoAppex; esquema=PortaoAppex; fi
      (cd "$RAIZ/apps/ios/$pasta" && xcodegen generate && xcodebuild \
        -project "$projeto.xcodeproj" -scheme "$esquema" -configuration Debug -jobs "$JOBS" \
        -destination 'generic/platform=iOS' -derivedDataPath "$DIARIOS/dd-$superficie" \
        IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build) ;;
    android-so)
      "$RAIZ/apps/android/tools/compila-nucleo.sh"
      "$RAIZ/apps/android/tools/compila-ffmpeg-dv.sh" ;;
    android-apk)
      local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
      if [ ! -f "$RAIZ/apps/android/local.properties" ]; then
        [ -d "$sdk" ] || { echo 'Configure ANDROID_HOME ou local.properties (local e ignorado).' >&2; return 2; }
        printf 'sdk.dir=%s\n' "$sdk" > "$RAIZ/apps/android/local.properties"
      fi
      local gradle_init="$DIARIOS/gradle-jobs.gradle"
      cat > "$gradle_init" <<EOF_GRADLE
// Limita compile/link no mesmo pool Ninja; uma ABI de cada vez no Gradle.
gradle.beforeProject { p ->
  p.plugins.withId('com.android.application') {
    p.extensions.getByName('android').defaultConfig.externalNativeBuild.cmake.arguments.addAll([
      '-DCMAKE_JOB_POOLS=quall_native=$JOBS',
      '-DCMAKE_JOB_POOL_COMPILE=quall_native',
      '-DCMAKE_JOB_POOL_LINK=quall_native'
    ])
  }
}
EOF_GRADLE
      (cd "$RAIZ/apps/android" && gradle "${OFFLINE[@]}" --no-daemon --max-workers=1 \
        --init-script "$gradle_init" --console=plain :app:assembleDebug :app:testDebugUnitTest) ;;
    windows)
      echo 'Windows: execute tools/portao.ps1 localmente no Windows com MSVC/SDK/WiX.' >&2
      echo 'Este script não opera outra máquina nem substitui validação Windows nativa.' >&2
      return 2 ;;
    obs) (cd "$RAIZ/plugins/obs" && ./construir.sh --sem-instalar) ;;
    *) echo "Superfície desconhecida: $superficie" >&2; return 2 ;;
  esac
}
cd "$RAIZ"
for superficie in "${ESCOLHIDAS[@]}"; do
  [ "$SEM_WINDOWS" = 0 ] || [ "$superficie" != windows ] || continue
  [ "$SEM_OBS" = 0 ] || [ "$superficie" != obs ] || continue
  diario="$DIARIOS/$superficie.log"
  printf '%s\n' "== $superficie (jobs=$JOBS; diário local: $diario)"
  if correr "$superficie" > "$diario" 2>&1; then
    echo 'OK'
  else
    status=$?
    tail -40 "$diario" >&2
    exit "$status"
  fi
done
