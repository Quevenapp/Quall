// Ponte para a fronteira C do núcleo.
//
// O header **não** é copiado para cá: ele é gerado pelo cbindgen a cada build do Rust, e uma
// cópia envelheceria em silêncio numa fronteira onde divergência de assinatura vira corrupção de
// memória em vez de erro de compilação.
#import "quall.h"
