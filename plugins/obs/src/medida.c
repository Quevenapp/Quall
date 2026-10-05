#include "quall-obs.h"

#include <stdlib.h>
#include <string.h>

void medida_zerar(struct medida *m)
{
	memset(m, 0, sizeof(*m));
}

void medida_por(struct medida *m, uint64_t amostra)
{
	m->v[m->proxi] = amostra;
	m->proxi = (m->proxi + 1) % MEDIDA_CAP;
	if (m->n < MEDIDA_CAP)
		m->n++;
	m->total += amostra;
	m->contagem++;
	if (amostra > m->maximo)
		m->maximo = amostra;
}

static int comparar(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return (x > y) - (x < y);
}

uint64_t medida_percentil(const struct medida *m, double p)
{
	if (m->n == 0)
		return 0;
	uint64_t *copia = bmalloc(m->n * sizeof(uint64_t));
	memcpy(copia, m->v, m->n * sizeof(uint64_t));
	qsort(copia, m->n, sizeof(uint64_t), comparar);
	size_t i = (size_t)(p * (double)(m->n - 1) + 0.5);
	if (i >= m->n)
		i = m->n - 1;
	uint64_t r = copia[i];
	bfree(copia);
	return r;
}

uint64_t medida_media(const struct medida *m)
{
	return m->contagem ? m->total / m->contagem : 0;
}
