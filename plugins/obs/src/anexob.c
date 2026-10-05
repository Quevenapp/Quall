#include "anexob.h"

#include <obs-module.h>
#include <string.h>

void buf_soltar(struct buf *b)
{
	bfree(b->p);
	b->p = NULL;
	b->n = b->cap = 0;
}

static void buf_reservar(struct buf *b, size_t precisa)
{
	if (b->cap >= precisa)
		return;
	size_t nova = b->cap ? b->cap : 4096;
	while (nova < precisa)
		nova *= 2;
	b->p = brealloc(b->p, nova);
	b->cap = nova;
}

static void buf_acrescentar(struct buf *b, const uint8_t *d, size_t n)
{
	buf_reservar(b, b->n + n);
	memcpy(b->p + b->n, d, n);
	b->n += n;
}

/// Guarda `d` em `b` e diz se mudou.
static bool buf_trocar(struct buf *b, const uint8_t *d, size_t n)
{
	if (b->n == n && memcmp(b->p, d, n) == 0)
		return false;
	buf_reservar(b, n);
	memcpy(b->p, d, n);
	b->n = n;
	return true;
}

static bool eh_inicio(const uint8_t *e, size_t n, size_t i, size_t *tam)
{
	if (i + 3 <= n && e[i] == 0 && e[i + 1] == 0 && e[i + 2] == 1) {
		*tam = 3;
		return true;
	}
	if (i + 4 <= n && e[i] == 0 && e[i + 1] == 0 && e[i + 2] == 0 && e[i + 3] == 1) {
		*tam = 4;
		return true;
	}
	return false;
}

bool anexob_converter(const uint8_t *e, size_t n, struct buf *avcc, struct buf *sps, struct buf *pps,
		      struct anexob_resultado *res)
{
	memset(res, 0, sizeof(*res));
	avcc->n = 0;

	size_t i = 0, tam = 0;
	// posicionar no primeiro start code
	while (i < n && !eh_inicio(e, n, i, &tam))
		i++;
	if (i >= n)
		return false;

	while (i < n) {
		i += tam;
		size_t inicio = i;
		size_t j = i;
		size_t tam_prox = 0;
		while (j < n && !eh_inicio(e, n, j, &tam_prox))
			j++;
		size_t fim = j;
		// Bytes zero antes do próximo start code pertencem ao alinhamento, não ao NAL.
		while (fim > inicio && e[fim - 1] == 0)
			fim--;

		if (fim > inicio) {
			const uint8_t *p = e + inicio;
			size_t c = fim - inicio;
			int tipo = p[0] & 0x1f;
			res->nals++;
			switch (tipo) {
			case 7: // SPS
				if (buf_trocar(sps, p, c))
					res->parametros_novos = true;
				break;
			case 8: // PPS
				if (buf_trocar(pps, p, c))
					res->parametros_novos = true;
				break;
			case 9:  // delimitador de unidade de acesso
			case 12: // enchimento
				break;
			default:
				if (tipo >= 1 && tipo <= 5) {
					res->tem_vcl = true;
					if (tipo == 5)
						res->tem_idr = true;
				}
				if (tipo >= 1 && tipo <= 6) {
					uint8_t pref[4] = {(uint8_t)(c >> 24), (uint8_t)(c >> 16),
							   (uint8_t)(c >> 8), (uint8_t)c};
					buf_acrescentar(avcc, pref, 4);
					buf_acrescentar(avcc, p, c);
				}
				break;
			}
		}

		if (j >= n)
			break;
		i = j;
		tam = tam_prox;
	}

	return res->nals > 0;
}
