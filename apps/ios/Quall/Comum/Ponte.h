//  Ponte entre o Swift do Quall e a fronteira C do núcleo.
//
//  O header vem de `crates/quall-ffi/include/quall.h`, gerado pelo cbindgen a cada build do
//  Rust. Ele **não** é copiado para cá de propósito: uma cópia envelheceria em silêncio, e a
//  fronteira C é justamente onde uma divergência de assinatura vira corrupção de memória em vez
//  de erro de compilação. O caminho entra por `HEADER_SEARCH_PATHS` no `project.yml`.
//
//  Este arquivo só existe porque um alvo Swift puro não tem outro jeito de enxergar um header C
//  que mora fora do alvo. Nada de lógica aqui.

#ifndef PONTE_H
#define PONTE_H

#include "quall.h"

//  As quatro funções da libopus que o lado que exibe usa para transformar os slots ordenados que
//  `quall_track_on_audio` entrega em PCM. O núcleo **não** expõe decodificador, por decisão
//  registrada em `docs/audio.md` §13 ("não é difícil; é só cedo"), e os símbolos da libopus já
//  viajam dentro do `libquall.a`. Ver o cabeçalho do arquivo para por que declarar não custa nada
//  à appex — e para a guarda que mede isso em vez de supor.
#include "OpusDoNucleo.h"

#endif /* PONTE_H */
