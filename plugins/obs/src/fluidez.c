#include "fluidez.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/// Ver o cabeçalho: relógio que anda para trás vira zero, não um intervalo gigante.
static uint64_t delta(uint64_t agora, uint64_t antes)
{
	return agora > antes ? agora - antes : 0;
}

static int comparar(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return (x > y) - (x < y);
}

static double em_ms(uint64_t us)
{
	return (double)us / 1000.0;
}

/// O corte é **estrito**: exatamente no limiar não conta. Uma função só, usada pelo contador
/// público e pela linha, para que os dois nunca possam divergir.
static uint64_t contar_trancos(const uint64_t *v, size_t n)
{
	uint64_t t = 0;
	for (size_t i = 0; i < n; i++)
		if (v[i] > FLUIDEZ_TRANCO_MS * 1000ull)
			t++;
	return t;
}

void fluidez_zerar(struct fluidez *f)
{
	if (!f)
		return;
	// Campo a campo, e não `struct fluidez vazia = {0}` como em `janela_do_enlace_zerar`: aquilo
	// põe 80 KB de temporária na pilha de quem chama. O `memset` do vetor é higiene — com `n = 0`
	// nada lá dentro é lido —, e roda uma vez por sessão, fora de qualquer caminho quente.
	f->anterior_ns = 0;
	f->ancorada = false;
	f->n = 0;
	f->descartadas = 0;
	memset(f->intervalos_us, 0, sizeof f->intervalos_us);
}

void fluidez_publicou(struct fluidez *f, uint64_t agora_ns)
{
	if (!f)
		return;
	if (f->ancorada) {
		uint64_t us = delta(agora_ns, f->anterior_ns) / 1000ull;
		if (f->n < FLUIDEZ_MAXIMO_DE_AMOSTRAS)
			f->intervalos_us[f->n++] = us;
		else
			f->descartadas++;
	}
	f->anterior_ns = agora_ns;
	f->ancorada = true;
}

uint64_t fluidez_trancos(const struct fluidez *f)
{
	return f ? contar_trancos(f->intervalos_us, f->n) : 0;
}

void formatar_fluidez(struct fluidez *f, char *saida, size_t cap)
{
	if (!saida || cap == 0)
		return;
	if (!f) {
		snprintf(saida, cap, "fluidez_ms (sem medida)");
		return;
	}

	// `descartadas` é lido antes de tudo e sai na linha mesmo quando não há amostra: o teto
	// nunca pode ficar implícito. Ver o cabeçalho.
	char sufixo[48] = "";
	if (f->descartadas > 0)
		snprintf(sufixo, sizeof sufixo, " (+%" PRIu64 " além do teto)", f->descartadas);

	// Uma leitura só de `n`, e o resto da função trabalha em cima dela: a thread que publica
	// escreve em `[n, ...)` e esta aqui mexe em `[0, n)`. Ver o cabeçalho.
	size_t n = f->n;
	if (n == 0) {
		snprintf(saida, cap, "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0%s", sufixo);
		return;
	}

	qsort(f->intervalos_us, n, sizeof f->intervalos_us[0], comparar);

	// Truncando, não arredondando, e a fórmula é a de `apps/windows/src/fluidez.rs` letra por
	// letra: dois relatos da mesma distribuição em cascas diferentes têm de dar o mesmo número,
	// senão a comparação entre elas mede a fórmula em vez do enlace.
	size_t i50 = (size_t)(0.50 * (double)(n - 1));
	size_t i95 = (size_t)(0.95 * (double)(n - 1));
	if (i50 >= n)
		i50 = n - 1;
	if (i95 >= n)
		i95 = n - 1;

	// `trancos` conta as amostras **guardadas**, e o `max` também: o que passou do teto está no
	// sufixo e em lugar nenhum mais.
	uint64_t trancos = contar_trancos(f->intervalos_us, n);

	snprintf(saida, cap,
		 "fluidez_ms=[n=%zu p50=%.0f p95=%.0f max=%.0f] trancos=%" PRIu64 "%s", n,
		 em_ms(f->intervalos_us[i50]), em_ms(f->intervalos_us[i95]),
		 em_ms(f->intervalos_us[n - 1]), trancos, sufixo);
}
