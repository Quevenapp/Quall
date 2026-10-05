#!/bin/zsh
# Só compila o emissor sintético; não abre rede nem inicia a transmissão.
set -euo pipefail
quall_audio_aqui=${0:A:h}
quall_audio_raiz=${quall_audio_aqui:h:h:h:h}
quall_audio_lib=${QUALL_LIBQUALL:-$quall_audio_raiz/target/release/libquall.a}
quall_audio_saida=${QUALL_SAIDA:-$(mktemp -d /tmp/quall-emissor-audio.XXXXXX)}
[[ -f "$quall_audio_lib" ]] || { print -u2 "Falta libquall.a para macOS: $quall_audio_lib"; exit 1; }
mkdir -p "$quall_audio_saida"
swiftc -O -module-cache-path "$quall_audio_saida/module-cache" \
  -import-objc-header "$quall_audio_aqui/../Comum/Ponte.h" \
  -I "$quall_audio_raiz/crates/quall-ffi/include" \
  "$quall_audio_aqui/../Receber/TomSintetico.swift" \
  "$quall_audio_raiz/apps/macos/Sources/QuallCaptureKit/PresetDeAudio.swift" \
  "$quall_audio_raiz/apps/macos/Sources/QuallCaptureKit/CodificadorDeAudio.swift" \
  "$quall_audio_aqui/EmissorDeAudioSintetico.swift" \
  "$quall_audio_lib" -lc++ -o "$quall_audio_saida/emissor-audio-sintetico"
print "Compilado: $quall_audio_saida/emissor-audio-sintetico"
