cmake_minimum_required(VERSION 3.22)
project(quall-obs VERSION 1.0.0 LANGUAGES C)

# =================================================================================================
# Fonte nativa de OBS que embute o receptor do Quall.
#
# O plugin é um `MODULE` que o OBS carrega por `dlopen`. Ele não depende de Qt: as propriedades
# saem pela API de `obs_properties_*`, que o OBS desenha sozinho. Isso mantém o plugin fora do
# problema de casar a versão do Qt com a do OBS instalado, que é onde plugin de OBS mais quebra.
# =================================================================================================

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)

# Os avisos vêm sempre da raiz auditada, inclusive quando só eles mudam entre builds.
# O GPL do plugin e o MPL dos arquivos do núcleo acompanham cada candidato novo.
set(QUALL_RAIZ "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(QUALL_AVISOS "${QUALL_RAIZ}/THIRD_PARTY_NOTICES.txt")
set(QUALL_LICENCA_PLUGIN "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")
set(QUALL_ESCOPO_PLUGIN "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE-SCOPE.md")
set(QUALL_LICENCA_NUCLEO "${QUALL_RAIZ}/LICENSE")
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/copiar-avisos.cmake")

# O mesmo piso do app da câmera virtual (`integrations/camera-macos/project.yml`). Precisa casar com
# o `MACOSX_DEPLOYMENT_TARGET` usado ao compilar `libquall.a`, senão o `ld` avisa uma vez por objeto
# da libdatachannel — 25 linhas de ruído que escondem o aviso que importa.
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0")

if(NOT APPLE AND NOT WIN32)
  message(FATAL_ERROR
    "Só macOS e Windows estão implementados. Ver plugins/obs/README.md.")
endif()

# --- libobs: cabeçalhos de uma tag fixa, biblioteca do OBS instalado ------------------------------
#
# Os dois sistemas seguem a mesma regra e pelo mesmo motivo: **os cabeçalhos vêm de uma tag que
# casa com o OBS instalado nesta máquina, e a biblioteca vem do próprio OBS instalado.** O OBS
# confere o `LIBOBS_API_VER`: **recusa major/minor mais novos** que o host e ignora patch.
# Compilar contra a tag instalada limita essa diferença; não substitui a prova de runtime.
set(QUALL_LIBOBS_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/.libobs/obs-studio/libobs"
    CACHE PATH "Cabeçalhos do libobs (ver buscar-libobs.sh / buscar-libobs.ps1)")

if(NOT EXISTS "${QUALL_LIBOBS_INCLUDE}/obs-module.h")
  message(FATAL_ERROR "Cabeçalhos do libobs ausentes. Rode plugins/obs/buscar-libobs.sh primeiro.")
endif()

if(APPLE)
  set(QUALL_OBS_APP "/Applications/OBS.app" CACHE PATH "OBS instalado nesta máquina")
  set(QUALL_LIBOBS_LIB "${QUALL_OBS_APP}/Contents/Frameworks/libobs.framework/Versions/A/libobs")
  if(NOT EXISTS "${QUALL_LIBOBS_LIB}")
    message(FATAL_ERROR "libobs não encontrada em ${QUALL_LIBOBS_LIB}. O OBS está instalado?")
  endif()
else()
  # **No Windows o OBS instalado não traz `obs.lib`** — só `obs.dll`. Um plugin de OBS precisa da
  # biblioteca de importação, e o caminho oficial para tê-la é compilar o libobs inteiro. Aqui ela
  # é **gerada a partir da própria DLL instalada** (`dumpbin /exports` → `.def` → `lib /def`), que é
  # o análogo exato do que o lado macOS faz ao linkar contra a `libobs` de dentro do `OBS.app`: o
  # alvo é o OBS desta bancada, não um pacote pré-compilado que pode ser outra versão.
  # Ver `construir.ps1`; o mesmo vale para `w32-pthreads.lib`, que o `util/threading.h` exige.
  set(QUALL_OBS_DIR "C:/Program Files/obs-studio" CACHE PATH "OBS instalado nesta máquina")
  set(QUALL_LIBS_GERADAS "${CMAKE_CURRENT_SOURCE_DIR}/.libobs/lib"
      CACHE PATH "obs.lib e w32-pthreads.lib geradas das DLLs instaladas")
  set(QUALL_LIBOBS_LIB "${QUALL_LIBS_GERADAS}/obs.lib")
  set(QUALL_PTHREAD_LIB "${QUALL_LIBS_GERADAS}/w32-pthreads.lib")
  set(QUALL_PTHREAD_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/.libobs/obs-studio/deps/w32-pthreads")
  foreach(arq "${QUALL_LIBOBS_LIB}" "${QUALL_PTHREAD_LIB}" "${QUALL_PTHREAD_INCLUDE}/pthread.h")
    if(NOT EXISTS "${arq}")
      message(FATAL_ERROR "${arq} ausente. Rode plugins/obs/construir.ps1, que gera as duas .lib.")
    endif()
  endforeach()
endif()

# `obs-config.h` inclui `obsconfig.h`, que o build do próprio OBS gera. Ele só carrega caminhos de
# instalação e chaves de plataformas que não são a nossa; para um módulo, os campos que importam
# são os dois defines de release/beta.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/gerado/obsconfig.h"
     "#pragma once\n#define OBS_RELEASE_CANDIDATE 0\n#define OBS_BETA 0\n")

# --- núcleo do Quall pela fronteira C -------------------------------------------------------------
if(APPLE)
  set(QUALL_ALVO_RUST "aarch64-apple-darwin" CACHE STRING "alvo do rustc")
  set(QUALL_LIB "${QUALL_RAIZ}/target/${QUALL_ALVO_RUST}/release/libquall.a")
else()
  # No Windows o `cargo build` sem `--target` põe em `target/release`, e o `staticlib` do
  # `quall-ffi` sai como `quall.lib`. O `cdylib` sai como `quall.dll` + `quall.dll.lib` na mesma
  # pasta: nomes diferentes, então aqui não há a armadilha de o `ld` preferir o dinâmico que o
  # lado macOS registra — mas o caminho é dado inteiro do mesmo jeito.
  set(QUALL_ALVO_RUST "" CACHE STRING "alvo do rustc (vazio = alvo nativo)")
  if(QUALL_ALVO_RUST STREQUAL "")
    set(QUALL_LIB "${QUALL_RAIZ}/target/release/quall.lib")
  else()
    set(QUALL_LIB "${QUALL_RAIZ}/target/${QUALL_ALVO_RUST}/release/quall.lib")
  endif()
endif()
set(QUALL_NUCLEO_ESTATICO "" CACHE FILEPATH
    "Núcleo estático de uma bancada/candidato; vazio mantém o caminho padrão")
if(NOT QUALL_NUCLEO_ESTATICO STREQUAL "")
  get_filename_component(QUALL_LIB "${QUALL_NUCLEO_ESTATICO}" ABSOLUTE
                         BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
endif()
if(NOT EXISTS "${QUALL_LIB}")
  message(FATAL_ERROR
    "o núcleo compilado está ausente em ${QUALL_LIB}.\n"
    "  CARGO_PROFILE_RELEASE_LTO=false cargo build -p quall-ffi --release\n"
    "  (LTO desligado: dívida 17 — o bitcode do rustc quebra o `nm` da Apple)")
endif()
if(IS_DIRECTORY "${QUALL_LIB}")
  message(FATAL_ERROR "O núcleo estático precisa ser um arquivo: ${QUALL_LIB}")
endif()
file(SIZE "${QUALL_LIB}" QUALL_TAMANHO_NUCLEO)
if(QUALL_TAMANHO_NUCLEO EQUAL 0)
  message(FATAL_ERROR "O núcleo estático está vazio: ${QUALL_LIB}")
endif()
file(REAL_PATH "${QUALL_LIB}" QUALL_LIB)
message(STATUS "Núcleo estático do plugin: ${QUALL_LIB}")

set(QUALL_FONTES
  src/plugin.c
  src/fonte.c
  src/receptor.c
  src/descoberta.c
  src/pares.c
  src/medida.c
  src/perda.c
  src/fluidez.c
  src/encaixe.c
  src/janela-do-enlace.c
  src/interface-do-cabo.c
  src/som.c
  src/tempo-do-som.c
  src/texto.c
  src/camera-remota.c
  src/camera-remota-regras.c)
if(APPLE)
  # `anexob.c` é do caminho do VideoToolbox: o `CMVideoFormatDescription` quer SPS/PPS **fora** da
  # amostra e NALs prefixados por comprimento. O MFT do Windows come Annex-B como veio da rede.
  list(APPEND QUALL_FONTES src/decodificador-vt.c src/anexob.c)
else()
  # `remendo-sps.c` (a S7 do som): a `bitstream_restriction` no SPS Baseline antes do MFT da
  # Microsoft, que sem ela segura ~5 quadros. O VideoToolbox não segura; no Mac ela não entra.
  list(APPEND QUALL_FONTES src/decodificador-mf.c src/remendo-sps.c)
endif()

add_library(quall-obs MODULE ${QUALL_FONTES})

add_custom_target(quall-obs-avisos
  COMMAND ${CMAKE_COMMAND} "-DQUALL_AVISOS=${QUALL_AVISOS}"
          "-DQUALL_LICENCA_PLUGIN=${QUALL_LICENCA_PLUGIN}"
          "-DQUALL_ESCOPO_PLUGIN=${QUALL_ESCOPO_PLUGIN}"
          "-DQUALL_LICENCA_NUCLEO=${QUALL_LICENCA_NUCLEO}"
          "-DQUALL_DESTINO_AVISOS=${CMAKE_CURRENT_BINARY_DIR}/data/THIRD_PARTY_NOTICES.txt"
          "-DQUALL_DADOS_ORIGEM=${CMAKE_CURRENT_SOURCE_DIR}/data"
          -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/copiar-avisos.cmake"
  COMMENT "Conferindo e empacotando licenças e avisos de terceiros"
  VERBATIM)
add_dependencies(quall-obs quall-obs-avisos)
if(APPLE)
  # O gerador copia este recurso antes de assinar o bundle; mudanças no arquivo refazem a cópia.
  # O nome MPL é distinto do LICENSE GPL do plugin, sem modificar o texto da raiz.
  set(QUALL_RECURSO_MPL "${CMAKE_CURRENT_BINARY_DIR}/licencas/LICENSE-MPL-2.0.txt")
  configure_file("${QUALL_LICENCA_NUCLEO}" "${QUALL_RECURSO_MPL}" COPYONLY)
  set(QUALL_DOCUMENTOS "${QUALL_AVISOS}" "${QUALL_LICENCA_PLUGIN}"
      "${QUALL_ESCOPO_PLUGIN}" "${QUALL_RECURSO_MPL}")
  set_source_files_properties(${QUALL_DOCUMENTOS} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
  target_sources(quall-obs PRIVATE ${QUALL_DOCUMENTOS})
endif()

# **Os textos conferidos a cada build** (`cmake/conferir-locale.cmake`): as duas `.ini` com as
# mesmas chaves e as mesmas conversões de `printf`, toda chave usada existente, e nenhum rótulo
# literal no `.c`. Roda no Mac e no Windows sem Python, e reprova o build — é assim que o portão o
# cobre. O carimbo só refaz a conferência quando uma `.ini` ou um `.c` muda.
file(GLOB QUALL_LOCALES "${CMAKE_CURRENT_SOURCE_DIR}/data/locale/*.ini")
add_custom_command(
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/locale-conferido.carimbo"
  COMMAND ${CMAKE_COMMAND} "-DRAIZ=${CMAKE_CURRENT_SOURCE_DIR}"
          -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/conferir-locale.cmake"
  COMMAND ${CMAKE_COMMAND} -E touch "${CMAKE_CURRENT_BINARY_DIR}/locale-conferido.carimbo"
  DEPENDS ${QUALL_LOCALES} ${QUALL_FONTES} "${CMAKE_CURRENT_SOURCE_DIR}/cmake/conferir-locale.cmake"
  COMMENT "Conferindo os textos do plugin (data/locale)")
add_custom_target(quall-obs-locale DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/locale-conferido.carimbo")
add_dependencies(quall-obs quall-obs-locale)

target_include_directories(quall-obs PRIVATE
  "${QUALL_LIBOBS_INCLUDE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/.libobs/simde"
  "${CMAKE_CURRENT_BINARY_DIR}/gerado"
  "${QUALL_RAIZ}/crates/quall-ffi/include")

if(APPLE)
  target_compile_options(quall-obs PRIVATE -Wall -Wextra -Wno-unused-parameter)
else()
  target_include_directories(quall-obs PRIVATE "${QUALL_PTHREAD_INCLUDE}")
  # `/W3` e não `/W4`: os cabeçalhos do libobs e do SDK do Windows enchem o `/W4` de ruído que não
  # é nosso. `_CRT_SECURE_NO_WARNINGS` tira o aviso de `snprintf`, que é padrão desde o C99.
  target_compile_options(quall-obs PRIVATE /W3 /wd4100)
  target_compile_definitions(quall-obs PRIVATE
    _CRT_SECURE_NO_WARNINGS
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    _WIN32_WINNT=0x0A00
    WINVER=0x0A00)
endif()

# **O arquivo inteiro, por caminho.** O `crate-type` do `quall-ffi` põe `libquall.a` *e*
# `libquall.dylib` na mesma pasta, e o `ld` prefere o dinâmico com `-lquall`: o plugin sairia com
# uma dependência de caminho local que só existe nesta máquina. Mesma armadilha registrada em
# `integrations/camera-macos/project.yml`.
if(APPLE)
target_link_libraries(quall-obs PRIVATE
  "${QUALL_LIBOBS_LIB}"
  "${QUALL_LIB}"
  c++
  "-framework VideoToolbox"
  "-framework CoreMedia"
  "-framework CoreVideo"
  "-framework CoreFoundation")
else()
# `mfplat`/`mfuuid`: o MFT de decode e os GUIDs dele. As demais são o que a libdatachannel, o
# OpenSSL e o `juice` pedem quando entram estáticos — a mesma lista que `crates/quall-rtc/build.rs`
# explica símbolo por símbolo, mais o que o Rust sempre quer (`ws2_32`, `userenv`, `ntdll`).
target_link_libraries(quall-obs PRIVATE
  "${QUALL_LIBOBS_LIB}"
  "${QUALL_PTHREAD_LIB}"
  "${QUALL_LIB}"
  mfplat mfuuid mf ole32 oleaut32
  ws2_32 iphlpapi bcrypt crypt32 secur32 advapi32 user32 userenv ntdll shell32 dbghelp)
endif()

# **Lista de símbolos exportados, e ela não é higiene: é o que evita um travamento.**
#
# O OBS 32.2.2 embarca a **própria** `libdatachannel.dylib` (compilada contra mbedTLS, para a saída
# WHIP dele) com 1.159 símbolos `rtc*` exportados. O nosso núcleo linka **outra** libdatachannel,
# estática, compilada contra OpenSSL. Sem esta lista, os símbolos da nossa cópia sairiam exportados
# do plugin e disputariam com os do OBS — e o pior caso não é o símbolo `rtc*`, é a coalescência de
# `weak definition` do C++ (typeinfo, instanciação de template, `operator new` de classe), que o
# dyld resolve por processo inteiro e não por biblioteca. Duas ABIs diferentes da mesma classe
# escolhidas em tempo de carga é falha silenciosa.
#
# Com a lista, só as nove funções que o OBS procura por `dlsym` ficam visíveis; todo o resto do
# plugin — Quall, libdatachannel, OpenSSL, libsrtp, libjuice, usrsctp — fica interno.
if(APPLE)
target_link_options(quall-obs PRIVATE
  "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/cmake/simbolos-exportados.txt"
  "-Wl,-rpath,@executable_path/../Frameworks")
else()
# **No Windows esta proteção não é necessária, e vale escrever por quê.** O OBS também embarca uma
# `datachannel.dll` (2,2 MB, ao lado do `obs64.exe`), e o nosso núcleo linka outra libdatachannel,
# estática. No Mach-O o perigo seria a coalescência de `weak definition` do C++, que o dyld resolve
# por **processo**. O PE resolve por **módulo**: cada DLL carrega a sua cópia e ninguém escolhe por
# ninguém. O que sobra é higiene — só as funções `obs_module_*` saem, e o `MODULE_EXPORT` dos
# cabeçalhos do OBS já cuida disso. `construir.ps1` imprime o `dumpbin /exports` no fim, para a
# lista ser conferida a cada build, como o `nm -gU` do lado macOS.
target_link_options(quall-obs PRIVATE /IGNORE:4217)
endif()

if(APPLE)
set_target_properties(quall-obs PROPERTIES
  BUNDLE TRUE
  BUNDLE_EXTENSION plugin
  OUTPUT_NAME quall-obs
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "quall-obs"
  MACOSX_BUNDLE_GUI_IDENTIFIER "br.com.queven.quall.obs"
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}")

add_custom_command(TARGET quall-obs POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory
          "${CMAKE_CURRENT_BINARY_DIR}/data"
          "$<TARGET_BUNDLE_CONTENT_DIR:quall-obs>/Resources")
else()
set_target_properties(quall-obs PROPERTIES OUTPUT_NAME quall-obs SUFFIX ".dll")
endif()
