#include "janela-do-enlace.h"

#include <inttypes.h>
#include <stdio.h>

/// Ver o cabeçalho: contador que regride é track recriada, e não perda negativa.
static uint64_t delta(uint64_t agora, uint64_t antes)
{
	return agora > antes ? agora - antes : 0;
}

static void ancorar(struct janela_do_enlace *j, uint64_t agora_ns, uint64_t v, uint64_t p,
		    uint64_t s, uint64_t i)
{
	j->aberta_em_ns = agora_ns;
	j->vistos = v;
	j->perdidos = p;
	j->suspeitos = s;
	j->idrs_quebrados = i;
	j->ancorada = true;
}

void janela_do_enlace_zerar(struct janela_do_enlace *j)
{
	if (!j)
		return;
	struct janela_do_enlace vazia = {0};
	*j = vazia;
}

bool janela_do_enlace_fechar(struct janela_do_enlace *j, uint64_t agora_ns, uint64_t periodo_ms,
			     uint64_t vistos_acum, uint64_t perdidos_acum, uint64_t suspeitos_acum,
			     uint64_t idrs_quebrados_acum, struct amostra_do_enlace *saida)
{
	if (!j || !saida || periodo_ms == 0)
		return false;

	if (!j->ancorada) {
		ancorar(j, agora_ns, vistos_acum, perdidos_acum, suspeitos_acum, idrs_quebrados_acum);
		return false;
	}

	// Saturante também aqui: o relógio de quem chama é monotônico, mas um `agora_ns` menor que a
	// âncora viraria um `ms` gigante depois do laço, e daí uma taxa por segundo perto de zero.
	uint64_t decorrido_ms = delta(agora_ns, j->aberta_em_ns) / 1000000ull;
	if (decorrido_ms < periodo_ms)
		return false;

	uint64_t dv = delta(vistos_acum, j->vistos);
	uint64_t dp = delta(perdidos_acum, j->perdidos);

	saida->ms = decorrido_ms;
	// **O denominador do emissor**, montado aqui e não por quem lê a linha: vistos + perdidos é
	// o que o emissor pôs no ar nesta janela.
	saida->pacotes = dv + dp;
	saida->perdidos = dp;
	saida->suspeitos = delta(suspeitos_acum, j->suspeitos);
	saida->idrs_quebrados = delta(idrs_quebrados_acum, j->idrs_quebrados);

	ancorar(j, agora_ns, vistos_acum, perdidos_acum, suspeitos_acum, idrs_quebrados_acum);
	return true;
}

void formatar_janela_do_enlace(const struct amostra_do_enlace *a, char *saida, size_t cap)
{
	if (!saida || cap == 0)
		return;
	if (!a) {
		snprintf(saida, cap, "janela_do_enlace (sem amostra)");
		return;
	}
	double pct = a->pacotes == 0 ? 0.0 : (double)a->perdidos * 100.0 / (double)a->pacotes;
	snprintf(saida, cap,
		 "janela_do_enlace ms=%" PRIu64 " pacotes=%" PRIu64 " perdidos=%" PRIu64
		 " (%.2f%%) suspeitos=%" PRIu64 " idrs_quebrados=%" PRIu64,
		 a->ms, a->pacotes, a->perdidos, pct, a->suspeitos, a->idrs_quebrados);
}
