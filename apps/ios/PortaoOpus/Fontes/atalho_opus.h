// Atalhos não-variádicos para `opus_encoder_ctl`.
//
// **Existe por uma limitação do Swift, não por gosto**: `opus_encoder_ctl` é variádica
// (`int opus_encoder_ctl(OpusEncoder *st, int request, ...)`) e o Swift recusa importar função
// variádica em C — "Variadic function is unavailable". Sem estas três linhas de C não há como
// configurar o encoder a partir de Swift, e um encoder sem `OPUS_SET_BITRATE` não é o encoder do
// preset: seria medir outra coisa.
//
// O `crates/quall-opus/src/sys.rs` resolve o mesmo problema do lado Rust declarando os externs à
// mão — mesma limitação, mesma solução, linguagem diferente.
#ifndef ATALHO_OPUS_H
#define ATALHO_OPUS_H

int quall_opus_set_bitrate(void *st, int valor);
int quall_opus_set_inband_fec(void *st, int valor);
int quall_opus_set_packet_loss(void *st, int valor);
/// `OPUS_GET_LOOKAHEAD` — os 6,5 ms que `docs/audio.md` fixa em teste.
int quall_opus_get_lookahead(void *st, int *saida);

#endif
