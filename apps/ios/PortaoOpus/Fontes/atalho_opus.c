#include "atalho_opus.h"
#include <opus.h>

int quall_opus_set_bitrate(void *st, int valor) {
    return opus_encoder_ctl((OpusEncoder *)st, OPUS_SET_BITRATE(valor));
}

int quall_opus_set_inband_fec(void *st, int valor) {
    return opus_encoder_ctl((OpusEncoder *)st, OPUS_SET_INBAND_FEC(valor));
}

int quall_opus_set_packet_loss(void *st, int valor) {
    return opus_encoder_ctl((OpusEncoder *)st, OPUS_SET_PACKET_LOSS_PERC(valor));
}

int quall_opus_get_lookahead(void *st, int *saida) {
    opus_int32 v = 0;
    int r = opus_encoder_ctl((OpusEncoder *)st, OPUS_GET_LOOKAHEAD(&v));
    if (saida) *saida = (int)v;
    return r;
}
