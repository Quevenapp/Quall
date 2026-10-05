//  Ponte entre o Swift da appex e a fronteira C do núcleo.
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

#endif /* PONTE_H */
