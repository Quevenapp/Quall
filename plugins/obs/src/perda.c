#include "perda.h"

#include <inttypes.h>
#include <stdio.h>

// `50 (0,180%)`, ou só `50` quando não há janela observada, ou `?` quando a chave não veio.
static void texto_com_taxa(char *b, size_t cap, struct numero_do_nucleo v,
			   struct numero_do_nucleo vistos)
{
	if (!v.tem) {
		snprintf(b, cap, "?");
		return;
	}
	if (!vistos.tem || vistos.v <= 0) {
		snprintf(b, cap, "%" PRId64, v.v);
		return;
	}
	// O denominador é a **janela observada mais o que faltou nela**: nada que tenha caído antes
	// do primeiro pacote visto pode entrar em conta nenhuma, e é por isso que `packets_seen`
	// existe. Ver a dívida 25.
	double den = (double)v.v + (double)vistos.v;
	snprintf(b, cap, "%" PRId64 " (%.3f%%)", v.v, den > 0 ? 100.0 * (double)v.v / den : 0.0);
}

static void texto_simples(char *b, size_t cap, struct numero_do_nucleo v)
{
	if (v.tem)
		snprintf(b, cap, "%" PRId64, v.v);
	else
		snprintf(b, cap, "?");
}

void formatar_perda(const struct contadores_de_perda *c, char *saida, size_t cap)
{
	if (!saida || cap == 0)
		return;

	if (c->vistos.tem && c->vistos.v == 0) {
		snprintf(saida, cap,
			 "perda: nenhum pacote chegou ainda (packets_seen=0) — nada a afirmar");
		return;
	}

	char c_exata[64], c_teto[64], c_tarde[32], c_vistos[32];
	texto_com_taxa(c_exata, sizeof c_exata, c->exata, c->vistos);
	texto_com_taxa(c_teto, sizeof c_teto, c->teto, c->vistos);
	texto_simples(c_tarde, sizeof c_tarde, c->tarde);
	texto_simples(c_vistos, sizeof c_vistos, c->vistos);

	int n = snprintf(saida, cap, "perda exata %s · teto %s · tarde demais %s · vistos %s",
			 c_exata, c_teto, c_tarde, c_vistos);

	// A janela de reordenação tem 128 posições. Um pacote que chega depois de a posição dele já
	// ter saído dela é uma posição cobrada como perda que não era: quando isto passa de zero, a
	// perda exata está superestimada nesse tanto, e a leitura precisa dizer isso em voz alta.
	if (c->tarde.tem && c->tarde.v > 0 && n > 0 && (size_t)n < cap)
		snprintf(saida + n, cap - (size_t)n,
			 " — JANELA CURTA: a perda exata está superestimada em até %" PRId64,
			 c->tarde.v);
}
