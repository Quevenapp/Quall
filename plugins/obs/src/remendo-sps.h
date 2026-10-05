// O remendo da `bitstream_restriction` no SPS Baseline, antes do decodificador da Microsoft.
//
// Sem a restrição, a norma (H.264, E.2.1) manda o decodificador inferir `max_dec_frame_buffering`
// pelo teto do nível, e o *Microsoft H264 Video Decoder MFT* segura ~5 quadros antes de entregar.
// Neste plugin o `MF_LOW_LATENCY` é aceito e o `CODECAPI_AVLowLatencyMode` é recusado (README): é o
// mesmo MFT e a mesma configuração do receptor do Windows, onde a S7 do som mediu em 21/09 (a T2,
// `docs/som-no-receptor.md` §20.15 e §20.19) 161 ms de fila→tela com o SPS do VideoToolbox sem VUI,
// e 4,2 ms com o SPS reescrito. O emissor do Mac remenda o próprio SPS (`RemendoDeSPS.swift`); este
// remendo faz o plugin não depender disso.
//
// **Porte de `apps/windows/src/sps.rs` (`declarar_restricao_de_bitstream`)**, com o mesmo resultado
// byte a byte (conferido em `bancada/prova-remendo-sps.c` contra o mesmo SPS literal que o teste do
// Rust confere com o `tools/ler-sps.py`). Só Baseline (perfil 66): Baseline não tem fatia B, e
// `max_num_reorder_frames = 0` é o que ele é. Main e High não são tocados. O VUI que existe é copiado
// até o flag da restrição; sem VUI, ele é escrito sem `video_signal_type`. O SPS novo é relido e
// conferido, e se não conferir nada muda. Só o prefixo não-VCL do quadro é varrido.
//
// Puro: não depende do OBS nem do Windows, e compila e testa no Mac.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Se o quadro Annex-B traz um SPS Baseline sem `bitstream_restriction`, escreve em `*saida` (com
/// `malloc`; quem chama libera com `free`) o quadro com o SPS reescrito, e devolve `true`. Senão
/// devolve `false` e não aloca nada.
bool remendo_sps_restricao(const uint8_t *annexb, size_t n, uint8_t **saida, size_t *n_saida);
