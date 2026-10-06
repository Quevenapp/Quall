#!/usr/bin/env bash
#
# Compila o núcleo (`crates/quall-ffi`, cdylib) para as duas ABIs da bancada e o instala em
# `app/src/main/jniLibs/`, junto com o `libc++_shared.so` do NDK.
#
# Este script é o **dono** de `app/src/main/jniLibs/`. Ele apaga a pasta antes de copiar, de
# propósito:
#
#   Uma `.so` de Android já existia em `target/` desde o M0, quando `quall-ffi` exportava dois
#   símbolos (`quall_protocol_version` e `quall_service_type`) e o núcleo ainda não tinha track de
#   mídia. Ela é um ELF perfeitamente válido: um APK montado com ela **instala, carrega e passa
#   pelo `System.loadLibrary`** — e só morre com `UnsatisfiedLinkError` na primeira chamada de
#   verdade, dentro do serviço de espelhamento, longe do build. Reaproveitar `target/` sem
#   conferir é exatamente esse erro esperando acontecer.
#
# Por isso, além de apagar, há um **portão de símbolos**: para cada ABI, todo símbolo que
# `app/src/main/cpp/quall_jni.c` chama precisa aparecer em `llvm-nm -D --defined-only`. Se faltar
# um, o script falha aqui, e não no aparelho.
#
# Uso, da raiz do repositório ou de qualquer lugar:
#
#     apps/android/tools/compila-nucleo.sh
#
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_APP="$(cd "$AQUI/.." && pwd)"
RAIZ="$(cd "$ANDROID_APP/../.." && pwd)"
JNILIBS="$ANDROID_APP/app/src/main/jniLibs"

# rustup é keg-only no Homebrew da bancada; um shell não interativo não o tem no PATH.
if ! command -v cargo >/dev/null 2>&1 && [ -x /opt/homebrew/opt/rustup/bin/cargo ]; then
  export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi

cd "$RAIZ"
# shellcheck disable=SC1091
source tools/android-env.sh

_host="$(uname -s)"
case "$_host" in
  Darwin) NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin" ;;
  Linux)  NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin" ;;
  *) echo "host não suportado: $_host" >&2; exit 1 ;;
esac
NM="$NDK_BIN/llvm-nm"
READELF="$NDK_BIN/llvm-readelf"
SYSROOT_LIB="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$(basename "$(dirname "$NDK_BIN")")/sysroot/usr/lib"

# Todo símbolo que o shim JNI chama. A lista é curta de propósito: se ela crescer, é porque a
# fachada cresceu, e vale reler se ainda cabe em `apps/android`.
SIMBOLOS=(
  quall_last_error quall_last_status quall_known_peers_has_secure
  quall_advertiser_start quall_advertiser_stop quall_advertiser_label
  quall_browser_start quall_browser_collect quall_browser_devices_json quall_browser_stop
  quall_canceller_new quall_canceller_free quall_session_cancel
  quall_host_cancelable quall_connect_cancelable quall_connect_with_screen
  quall_session_signaling_port quall_session_peer_json
  quall_session_pairing_is_new
  quall_session_known_peers_json quall_session_track_count quall_session_track
  quall_session_next_track quall_session_next_event
  quall_session_close quall_session_path_json
  quall_track_send_frame quall_track_take_idr_request quall_track_stats_json
  quall_track_on_frame quall_track_request_idr quall_track_kind
  quall_track_label quall_track_free quall_track_frames_dropped quall_track_set_reorder_depth
  quall_protocol_version quall_service_type quall_generate_pin quall_install_panic_hook
  # Áudio. `quall_audio_decoder_*` e `quall_track_audio_codec` entraram nesta rodada; os outros
  # já existiam no header e nunca tinham sido chamados de lugar nenhum no Android.
  quall_track_send_audio quall_track_on_audio quall_track_audio_codec
  quall_audio_preset_json
  quall_audio_encoder_new quall_audio_encoder_encode quall_audio_encoder_free
  quall_audio_decoder_new quall_audio_decoder_decode quall_audio_decoder_free
  # A taxa que escuta. `quall_session_report_link` é do receptor, `..._take_link_report` é do
  # emissor, e `quall_rate_*` é a política — que mora no núcleo para poder ser testada.
  quall_session_report_link quall_session_take_link_report
  quall_rate_new quall_rate_sample quall_rate_current_bps quall_rate_at_floor
  quall_rate_counters quall_rate_free quall_teto_ajustar_para
  # O teleprompter (F6a, `docs/contrato-teleprompter.md`): o papel no aperto de mão, as mensagens
  # da sessão e a réplica do estado. O shim JNI os chama desde a F6b (as telas do prompter e do
  # controle); a lista garante que a `.so` os exporta.
  quall_advertiser_start_with_role quall_host_with_role quall_connect_with_role
  quall_message_max_bytes quall_session_messages quall_messages_send quall_messages_next
  quall_messages_stats_json quall_messages_free
  quall_teleprompter_max_text_bytes quall_teleprompter_new quall_teleprompter_free
  quall_teleprompter_set_text quall_teleprompter_set_scrolling quall_teleprompter_set_speed
  quall_teleprompter_set_font_size quall_teleprompter_set_margin quall_teleprompter_set_reading_line
  quall_teleprompter_set_mirror quall_teleprompter_set_position quall_teleprompter_jump
  quall_teleprompter_jump_by quall_teleprompter_pump quall_teleprompter_peer_lost
  quall_teleprompter_state_json quall_teleprompter_text quall_teleprompter_saved_json
  # A porta 7979, o link e a pergunta do texto (`docs/contrato-teleprompter.md` §11, 14/09). O
  # shim JNI ainda não os chama — as telas são de outra frente —; a lista garante que a `.so` os
  # exporta quando chamar.
  quall_teleprompter_default_port quall_teleprompter_pick_port quall_parse_endpoint_json
  quall_teleprompter_resolve_text quall_teleprompter_question_text
  quall_teleprompter_text_copy quall_teleprompter_forget_text_copy
  quall_teleprompter_enable_text_question
  # "Segurar para rolar" (§12, o pedido do usuário de 14/09).
  quall_teleprompter_enable_hold quall_teleprompter_hold quall_teleprompter_release
  # A gravação (§13, o R5: o controle começa, para e vê a gravação).
  quall_teleprompter_enable_recording quall_teleprompter_set_recording
  quall_teleprompter_refuse_recording quall_teleprompter_request_record quall_teleprompter_request_stop
  # O controle remoto da câmera (`docs/controle-remoto-da-camera.md`, 02/10). O shim JNI ainda
  # não os chama — as telas são das frentes de plataforma —; a lista garante que a `.so` os exporta.
  quall_camera_host_new quall_camera_host_free quall_camera_host_set_allowed
  quall_camera_host_set_camera quall_camera_host_set_capabilities quall_camera_host_set_settings
  quall_camera_host_update_settings quall_camera_host_set_read quall_camera_host_reject
  quall_camera_host_next_request quall_camera_host_pump quall_camera_host_forget
  quall_camera_host_state_json
  quall_camera_remote_new quall_camera_remote_free quall_camera_remote_request
  quall_camera_remote_restore quall_camera_remote_touch quall_camera_remote_pump
  quall_camera_remote_state_json
)

# Dois flags de link que o `Cargo.toml` do workspace não tem como dar (ele é de `crates/`, e vale
# para todas as plataformas):
#
# - `-soname`: sem ele o `rustc` produz uma `.so` sem `DT_SONAME`, e o `DT_NEEDED` de quem linkar
#   contra ela vira o **caminho absoluto** que o linker recebeu — que no aparelho não existe.
#   Conferido nesta bancada: a `.so` do M0 não tinha SONAME nenhum.
# - `max-page-size=16384`: o Android 15+ exige alinhamento de página de 16 KB em arm64. Não morde
#   o A10s, que é armv7 — morde o A07 e o tablet (`docs/divida-do-nucleo.md`, item 6). O ideal é
#   isso sair de `tools/android-env.sh`, que é de outra frente; até lá, sai daqui.
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-soname,libquall.so -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"

echo "==> apagando $JNILIBS"
rm -rf "$JNILIBS"

confere() {
  local abi="$1" alvo="$2" triplo="$3"
  local so="${CARGO_TARGET_DIR:-$RAIZ/target}/$alvo/release/libquall.so"

  echo "==> $abi ($alvo)"
  cargo build --locked -j "$CARGO_BUILD_JOBS" -p quall-ffi --release --target "$alvo"

  if [ ! -f "$so" ]; then
    echo "FALHOU: $so não existe depois do build" >&2
    exit 1
  fi

  local libcpp="$SYSROOT_LIB/$triplo/libc++_shared.so"
  if [ ! -f "$libcpp" ]; then
    echo "FALHOU: libc++_shared.so não encontrada em $libcpp" >&2
    exit 1
  fi

  mkdir -p "$JNILIBS/$abi"
  local destino="$JNILIBS/$abi/libquall.so"
  cp "$so" "$destino"
  cp "$libcpp" "$JNILIBS/$abi/libc++_shared.so"

  # `--strip-unneeded` tira a tabela de símbolos estática e mantém `.dynsym`, que é o que o
  # `dlopen` usa. Vale ~2/3 do tamanho, e num APK que carrega duas ABIs isso não é detalhe.
  # A conferência abaixo roda **depois** do strip, sobre o arquivo que vai no APK — conferir o
  # binário intermediário provaria a coisa errada.
  "$NDK_BIN/llvm-strip" --strip-unneeded "$destino"

  local faltando=()
  local definidos
  definidos="$("$NM" -D --defined-only "$destino" | awk '{print $NF}')"
  for s in "${SIMBOLOS[@]}"; do
    if ! grep -qx -- "$s" <<<"$definidos"; then
      faltando+=("$s")
    fi
  done
  if [ ${#faltando[@]} -gt 0 ]; then
    echo "FALHOU: $abi não exporta ${#faltando[@]} símbolo(s): ${faltando[*]}" >&2
    echo "        (é o sintoma de uma .so antiga, de antes da feature \`media\`)" >&2
    exit 1
  fi

  if ! "$READELF" -d "$destino" | grep -q "SONAME.*libquall.so"; then
    echo "FALHOU: $abi saiu sem DT_SONAME=libquall.so" >&2
    exit 1
  fi

  if [ "$abi" = "arm64-v8a" ]; then
    # Todo segmento LOAD precisa de alinhamento >= 0x4000 (16 KiB) para o Android 15+.
    local desalinhados
    desalinhados="$("$READELF" -l "$destino" | awk '$1=="LOAD"{print $NF}' | grep -vc '0x4000\|0x10000' || true)"
    if [ "$desalinhados" != "0" ]; then
      echo "FALHOU: $abi tem $desalinhados segmento(s) LOAD sem alinhamento de 16 KiB" >&2
      exit 1
    fi
  fi

  local bytes
  bytes="$(wc -c <"$destino")"
  echo "    ok — $((bytes / 1024)) KiB, ${#SIMBOLOS[@]} símbolos conferidos depois do strip"
}

# `armeabi-v7a` primeiro, de propósito: é o A10s, é o que quebra, e é o que ninguém lembra de
# testar. Se o build vai falhar, que falhe no aparelho difícil antes de gastar tempo no fácil.
confere armeabi-v7a armv7-linux-androideabi arm-linux-androideabi
confere arm64-v8a    aarch64-linux-android  aarch64-linux-android

echo
echo "jniLibs prontos:"
ls -la "$JNILIBS"/*/
