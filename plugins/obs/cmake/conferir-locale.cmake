# Confere os textos do plugin antes de compilar. Roda como `cmake -P`, então vale no Mac e no
# Windows sem Python, e o portão o cobre de graça: o `CMakeLists.txt` o chama a cada build em que
# uma `.ini` ou um `.c` mudou, e um erro aqui reprova o build.
#
#   cmake -DRAIZ=plugins/obs -P plugins/obs/cmake/conferir-locale.cmake
#
# 1. **Paridade**: `pt-BR.ini` e `en-US.ini` com as mesmas chaves, nenhuma vazia.
# 2. **Conversões iguais**, chave a chave (`%s`, `%llu`, `%.1f`…, sem largura nem precisão). As
#    frases de estado são formato de `printf` vindo de arquivo (`texto.c`): uma conversão trocada
#    derrubaria o OBS. `texto_formato` tem a segunda trava em tempo de execução.
# 3. **Chave usada existe**: toda `"Quall.…"` citada em `src/*.c` está nas duas `.ini`.
# 4. **Sem texto literal na interface**: rótulo de propriedade e frase de estado (`dizer`) só por
#    chave. É uma varredura por forma, não um analisador de C — cobre os pontos onde o plugin põe
#    texto na tela hoje (`obs_properties_add_*`, `obs_property_list_add_string`,
#    `obs_property_set_description`, `dizer`).
cmake_minimum_required(VERSION 3.16)
if(NOT RAIZ)
  get_filename_component(RAIZ "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
endif()

set(problemas "")

function(ler_ini caminho prefixo)
  file(STRINGS "${caminho}" linhas ENCODING UTF-8)
  set(chaves "")
  set(prob "")
  foreach(l IN LISTS linhas)
    if(l MATCHES "^[ \t]*$" OR l MATCHES "^[ \t]*[#;]")
      continue()
    endif()
    if(NOT l MATCHES "^([A-Za-z0-9_.]+)=\"(.*)\"$")
      string(APPEND prob "\n  ${caminho}: linha fora do formato chave=\"texto\": ${l}")
      continue()
    endif()
    set(k "${CMAKE_MATCH_1}")
    set(v "${CMAKE_MATCH_2}")
    if(k IN_LIST chaves)
      string(APPEND prob "\n  ${caminho}: chave repetida ${k}")
    endif()
    list(APPEND chaves "${k}")
    if(v STREQUAL "")
      string(APPEND prob "\n  ${caminho}: ${k} vazia")
    endif()
    # As conversões, sem `%%`, sem largura e sem precisão.
    string(REPLACE "%%" "" sem "${v}")
    string(REGEX MATCHALL "%[-+ #0-9.*]*[hlLqjzt]*[A-Za-z]" convs "${sem}")
    set(assin "")
    foreach(c IN LISTS convs)
      string(REGEX REPLACE "^%[-+ #0-9.*]*" "" c "${c}")
      string(APPEND assin "${c}|")
    endforeach()
    set(${prefixo}_${k} "${assin}" PARENT_SCOPE)
  endforeach()
  set(${prefixo}_CHAVES "${chaves}" PARENT_SCOPE)
  set(problemas "${problemas}${prob}" PARENT_SCOPE)
endfunction()

ler_ini("${RAIZ}/data/locale/pt-BR.ini" PT)
ler_ini("${RAIZ}/data/locale/en-US.ini" EN)

foreach(k IN LISTS PT_CHAVES)
  if(NOT k IN_LIST EN_CHAVES)
    string(APPEND problemas "\n  en-US.ini: falta ${k}")
  elseif(NOT "${PT_${k}}" STREQUAL "${EN_${k}}")
    string(APPEND problemas "\n  ${k}: conversões diferentes (pt-BR '${PT_${k}}', en-US '${EN_${k}}')")
  endif()
endforeach()
foreach(k IN LISTS EN_CHAVES)
  if(NOT k IN_LIST PT_CHAVES)
    string(APPEND problemas "\n  pt-BR.ini: falta ${k}")
  endif()
endforeach()

file(GLOB fontes "${RAIZ}/src/*.c")
set(usadas "")
foreach(f IN LISTS fontes)
  file(READ "${f}" texto ENCODING UTF-8)
  get_filename_component(nome "${f}" NAME)
  string(REGEX MATCHALL "\"Quall\\.[A-Za-z0-9_.]+\"" citadas "${texto}")
  foreach(c IN LISTS citadas)
    string(REPLACE "\"" "" c "${c}")
    if(NOT c IN_LIST PT_CHAVES)
      string(APPEND problemas "\n  ${nome}: ${c} não está nas .ini")
    endif()
    list(APPEND usadas "${c}")
  endforeach()
  # Rótulo literal: `obs_properties_add_xxx(props, "id", "Texto"` ou `…_add_string(lista, "Texto"`.
  string(REGEX MATCHALL "obs_properties_add_[a-z0-9]+\\([^,()]+,[^,()]+,[ \t\r\n]*\"[^\"]*\"" lits "${texto}")
  string(REGEX MATCHALL "obs_property_list_add_string\\([^,()]+,[ \t\r\n]*\"[^\"]*\"" lits2 "${texto}")
  string(REGEX MATCHALL "obs_property_set_(long_)?description\\([^,()]+,[ \t\r\n]*\"[^\"]*\"" lits3 "${texto}")
  # Frase de estado literal: `dizer(r, "…")` cujo primeiro texto não é uma chave.
  string(REGEX MATCHALL "dizer\\([^,;()]+,[ \t\r\n]*\"[^Q\"][^\"]*\"" lits4 "${texto}")
  foreach(l IN LISTS lits lits2 lits3 lits4)
    string(APPEND problemas "\n  ${nome}: texto literal na interface: ${l}")
  endforeach()
endforeach()
foreach(k IN LISTS PT_CHAVES)
  if(NOT k IN_LIST usadas)
    string(APPEND problemas "\n  ${k} está nas .ini e nenhum .c a usa")
  endif()
endforeach()

list(LENGTH PT_CHAVES n)
if(problemas)
  message(FATAL_ERROR "textos do plugin (data/locale):${problemas}")
endif()
message(STATUS "textos do plugin: ${n} chaves, pt-BR e en-US com as mesmas chaves e as mesmas conversões")
