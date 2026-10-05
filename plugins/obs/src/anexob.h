// Annex-B (o que o contrato das tracks entrega) → AVCC (o que o VideoToolbox come).
//
// O núcleo entrega um quadro completo em Annex-B, com SPS/PPS junto quando é IDR. O
// `CMVideoFormatDescription` do VideoToolbox quer os conjuntos de parâmetros **fora** da amostra e
// os NALs de vídeo prefixados por comprimento. Esta unidade faz a separação e a reescrita.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct buf {
	uint8_t *p;
	size_t n;
	size_t cap;
};

void buf_soltar(struct buf *b);

struct anexob_resultado {
	bool tem_vcl;         // há NAL de vídeo (tipos 1..5)
	bool tem_idr;         // há NAL tipo 5
	bool parametros_novos;// SPS ou PPS diferente do que já estava guardado
	int nals;
};

/// Varre `e[0..n)`. Guarda o último SPS e o último PPS em `sps`/`pps` (buffers próprios, crescem
/// sozinhos) e escreve os NALs de vídeo em `avcc` com prefixo de 4 bytes big-endian.
/// Devolve `false` se não houver NAL nenhum.
bool anexob_converter(const uint8_t *e, size_t n, struct buf *avcc, struct buf *sps, struct buf *pps,
		      struct anexob_resultado *res);
