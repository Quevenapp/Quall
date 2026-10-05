// Banco de prova de `src/perda.c`, sem OBS nenhum.
//
// Compilar o plugin inteiro exige os cabeçalhos do `libobs`, que esta máquina só tem depois de um
// clone pela rede — e na noite em que este arquivo nasceu havia outra frente medindo perda de
// pacote na mesma Wi-Fi, então baixar dezenas de MB teria contaminado a medição dela. Uma casca
// que não pode ser compilada não pode ser afirmada; o que **pode** ser afirmado é a parte que não
// depende do OBS, e é o que este banco exercita.
//
//     cc -Wall -Wextra -Werror -o /tmp/prova-perda \
//        plugins/obs/bancada/prova-perda.c plugins/obs/src/perda.c && /tmp/prova-perda
//
// Ele cobre os casos que a leitura errada de 29/08 tornou obrigatórios:
//
//  1. teto muito acima da perda exata — o caso medido (486 contra 50);
//  2. `packets_too_late > 0`, que é o contador novo admitindo que ele próprio superestima;
//  3. chave ausente, que precisa sair como `?` e **nunca** como zero;
//  4. `packets_seen == 0`, em que nem "não perdeu nada" pode ser afirmado.

#include "../src/perda.h"

#include <stdio.h>
#include <string.h>

static int falhas;

static struct numero_do_nucleo tem(int64_t v)
{
	struct numero_do_nucleo n = {v, true};
	return n;
}

static struct numero_do_nucleo ausente(void)
{
	struct numero_do_nucleo n = {0, false};
	return n;
}

static void confere(const char *caso, const struct contadores_de_perda *c, const char *esperado)
{
	char saida[256];
	formatar_perda(c, saida, sizeof saida);
	if (strcmp(saida, esperado) != 0) {
		printf("FALHOU %s\n  esperado: %s\n  obtido  : %s\n", caso, esperado, saida);
		falhas++;
	} else {
		printf("ok %s\n  %s\n", caso, saida);
	}
}

int main(void)
{
	// A corrida de 29/08 que derrubou a leitura antiga: 486 no teto, cinquenta perdidos.
	struct contadores_de_perda medida = {
		.exata = tem(50),
		.teto = tem(486),
		.tarde = tem(0),
		.vistos = tem(27729),
	};
	confere("o teto exagera dez vezes", &medida,
		"perda exata 50 (0.180%) · teto 486 (1.722%) · tarde demais 0 · vistos 27729");

	// O contador novo admitindo que ele próprio superestima. Sem esta linha, `packets_too_late`
	// seria mais um número mudo no meio de um JSON.
	struct contadores_de_perda janela_curta = {
		.exata = tem(120),
		.teto = tem(400),
		.tarde = tem(7),
		.vistos = tem(10000),
	};
	confere("janela curta se declara", &janela_curta,
		"perda exata 120 (1.186%) · teto 400 (3.846%) · tarde demais 7 · vistos 10000"
		" — JANELA CURTA: a perda exata está superestimada em até 7");

	// Uma `.so` velha, sem o contador novo: a chave não vem. `?` diz "não sei"; `0` diria "medi
	// e não perdi nada", que é a mentira mais cara que este relatório poderia contar.
	struct contadores_de_perda sem_a_chave_nova = {
		.exata = ausente(),
		.teto = tem(486),
		.tarde = ausente(),
		.vistos = tem(27729),
	};
	confere("chave ausente vira ? e não zero", &sem_a_chave_nova,
		"perda exata ? · teto 486 (1.722%) · tarde demais ? · vistos 27729");

	// A dívida 25: o primeiro pacote visto fixa a linha de base, e sem nenhum pacote visto o
	// contador não afirma coisa nenhuma.
	struct contadores_de_perda nada_chegou = {
		.exata = tem(0),
		.teto = tem(0),
		.tarde = tem(0),
		.vistos = tem(0),
	};
	confere("nada chegou, nada se afirma", &nada_chegou,
		"perda: nenhum pacote chegou ainda (packets_seen=0) — nada a afirmar");

	printf("\n%s\n", falhas ? "VERMELHO" : "verde: 4/4");
	return falhas ? 1 : 0;
}
