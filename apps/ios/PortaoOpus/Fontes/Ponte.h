// Ponte para a libopus vendorizada em `crates/quall-opus/vendor/opus`.
//
// **Inclui o cabeçalho de upstream direto, sem intermediário nosso.** Não há FFI de áudio no
// `quall.h` — nenhum `quall_track_send_audio`, nenhum `quall_opus_*` —, então não existe caminho
// pelo núcleo para chegar ao encoder a partir de Swift hoje. Este alvo é de **medição**, não de
// produto: ele linka a mesma `libopus.a` que o `cargo` produz para `aarch64-apple-ios` a partir do
// mesmo `build.rs`, e chama o encoder direto. Ver `apps/ios/PortaoOpus/README.md`.
#import <opus.h>
#import "atalho_opus.h"
