# datachannel-sys 0.23.0+0.23.2 — alterações Quall

Base: crate publicado datachannel-sys 0.23.0+0.23.2, libdatachannel 0.23.2, ligado ao workspace
por `[patch.crates-io]`. Licenças/avisos MPL e titulares upstream permanecem preservados.

O patch runtime original está em `quall.patch`:

1. `libdatachannel/src/pacinghandler.cpp`: corrigir a guarda de schedule baseada no valor anterior
   de `mHaveScheduled.exchange(true)` e inicializar `mLastRun` na construção.
2. `libdatachannel/src/capi.cpp` e `include/rtc/rtc.h`: expor `rtcChainPacingHandler` na API C,
   recusando taxa/intervalo não positivos.
3. `build.rs`: observar fontes/headers C++ para reconstrução Cargo.

A seleção pública acrescenta alterações do grafo de testes: `NO_TESTS=ON` nas três configurações
CMake, padrão ON no CMake e diagnóstico se a suíte omitida for solicitada. Não altera runtime
para substituir fixture por teste falso. O archive histórico não é distribuído: a árvore
selecionada é o fonte desta versão. Recursos/keys omitidos estão em `PUBLIC-SOURCE.md`.

O espaçador deve ser o último handler da corrente. Bindgen gera a ponte C de rtc.h.
Uma revisão upstream que incorpore API/correções poderá permitir remover o fork;
este documento não afirma que migração ou testes tenham ocorrido.
