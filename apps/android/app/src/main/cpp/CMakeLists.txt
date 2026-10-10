# Fachada JNI do Quall no Android.
#
# `libqualljni.so` é a única peça C deste app: ela traduz JNI ⇄ a superfície C de
# `crates/quall-ffi` (`include/quall.h`). O núcleo em si entra pronto, como `libquall.so`
# pré-compilada em `src/main/jniLibs/<abi>/` — ver `tools/compila-nucleo.sh`.
#
# Por que o shim mora aqui e não em `crates/quall-ffi`: ver a seção "Onde mora o shim JNI" no
# README desta pasta. Resumo: `jni.h` só existe no NDK, e a mesma crate é compilada para iOS,
# macOS, Windows e o plugin de OBS.

cmake_minimum_required(VERSION 3.22.1)
project(qualljni C)

# O header é lido direto do repositório, não copiado: cópia envelhece em silêncio, e este header
# é gerado por cbindgen a cada build de `quall-ffi`. Se as duas coisas divergirem, o certo é o
# build quebrar.
set(QUALL_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../crates/quall-ffi/include")
if(NOT EXISTS "${QUALL_INCLUDE}/quall.h")
    message(FATAL_ERROR
        "quall.h não encontrado em ${QUALL_INCLUDE}. "
        "Rode `cargo build -p quall-ffi` na raiz do repositório (o build.rs gera o header).")
endif()

set(QUALL_SO "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libquall.so")
if(NOT EXISTS "${QUALL_SO}")
    message(FATAL_ERROR
        "libquall.so não encontrada para a ABI ${ANDROID_ABI} em ${QUALL_SO}. "
        "Rode `apps/android/tools/compila-nucleo.sh` — sem a ABI armeabi-v7a o app quebra só no "
        "Galaxy A10s, e só em tempo de execução.")
endif()

add_library(quall SHARED IMPORTED)
set_target_properties(quall PROPERTIES IMPORTED_LOCATION "${QUALL_SO}")

add_library(qualljni SHARED quall_jni.c)
target_include_directories(qualljni PRIVATE "${QUALL_INCLUDE}")
# `log` é o liblog do NDK: o caminho do quadro não loga, mas erro de fronteira precisa aparecer
# em algum lugar quando o retorno é engolido lá em cima.
target_link_libraries(qualljni quall log)

# Android 15+ exige páginas de 16 KB em arm64. Não morde o A10s (armv7) — morde o A07 e o tablet,
# os aparelhos que parecem os seguros. Ver `docs/divida-do-nucleo.md`, item 6.
target_link_options(qualljni PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")

# --- Câmera DV por USB (só arm64) ---------------------------------------------------------------
#
# `libqualldv.so` lê a filmadora (ou a placa de captura, MJPEG) pelo usbfs e decodifica o DV ou o
# MJPEG com o FFmpeg mínimo (`libavcodec.so`/`libavutil.so`, LGPL 2.1+, ligado dinamicamente e
# substituível), produzido por `apps/android/tools/compila-ffmpeg-dv.sh` em `src/main/jniLibsDv/`.
# A remontagem UVC (`dv/remontagem.c`) tem teste de mesa no Mac (`tools/testa-remontagem.sh`,
# chamado pelo portão). É uma `.so` à parte, e o
# `libqualljni` não depende dela: no A10s (armv7) ela não existe, e sem o FFmpeg construído o app
# compila do mesmo jeito, com a DV indisponível (o Kotlin carrega sob demanda, `QuallDv`).
set(DV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibsDv")
if(ANDROID_ABI STREQUAL "arm64-v8a" AND EXISTS "${DV_DIR}/lib/arm64-v8a/libavformat.so")
    add_library(avcodec SHARED IMPORTED)
    set_target_properties(avcodec PROPERTIES IMPORTED_LOCATION "${DV_DIR}/lib/arm64-v8a/libavcodec.so")
    add_library(avutil SHARED IMPORTED)
    set_target_properties(avutil PROPERTIES IMPORTED_LOCATION "${DV_DIR}/lib/arm64-v8a/libavutil.so")
    add_library(avformat SHARED IMPORTED)
    set_target_properties(avformat PROPERTIES IMPORTED_LOCATION "${DV_DIR}/lib/arm64-v8a/libavformat.so")
    # O DVD para MP4 (`docs/dvd-para-mp4.md`, a D1b): o pipeline em C puro (`dvd.c`, com teste de
    # mesa no Mac, `tools/testa-dvd.sh`), o adapt2 generalizado e a ponte JNI.
    add_library(qualldv SHARED dv/qualldv.c dv/remontagem.c dv/midia.c
        dv/dvd.c dv/dvd_jni.c dv/desentrelaca.c)
    target_include_directories(qualldv PRIVATE "${DV_DIR}/include")
    target_compile_options(qualldv PRIVATE -O2)
    target_link_libraries(qualldv avformat avcodec avutil log)
    target_link_options(qualldv PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")
else()
    message(STATUS "câmera DV fora deste build (ABI ${ANDROID_ABI}; FFmpeg em ${DV_DIR}: "
        "rode apps/android/tools/compila-ffmpeg-dv.sh)")
endif()
