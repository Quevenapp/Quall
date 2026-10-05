// Banco de prova de `src/janela-do-enlace.c`, sem OBS, sem rede e sem aparelho.
//
// Mesma razão de `prova-perda.c`: a aritmética que decide o que o emissor vai ler não pode ficar
// à espera de uma corrida na Wi-Fi para ser afirmada. A peça não inclui nada do `libobs`, então
// ela compila e roda sozinha:
//
//     cc -Wall -Wextra -Werror -o /tmp/prova-janela-do-enlace \
//        plugins/obs/bancada/prova-janela-do-enlace.c plugins/obs/src/janela-do-enlace.c \
//        && /tmp/prova-janela-do-enlace
//
// Os casos são os que o contrato do relato torna obrigatórios:
//
//  1. a **primeira** chamada só ancora — senão a primeira janela mediria o arranque da sessão;
//  2. a janela que **ainda não fechou** não relata;
//  3. a **derivada** entre duas janelas, e não o acumulado da sessão;
//  4. o **denominador é `vistos + perdidos`** — o que o emissor mandou —, e a prova mostra o
//     número que sairia com o denominador errado, porque é ele que já inverteu uma conclusão
//     desta bancada;
//  5. a **saturação** quando o contador do núcleo regride (track recriada), e a janela seguinte
//     voltando a medir certo em cima da âncora nova;
//  6. `periodo_ms == 0`, que não é janela nenhuma.

#include "../src/janela-do-enlace.h"

#include <stdio.h>
#include <string.h>

static int falhas;

#define MS(x) ((uint64_t)(x) * 1000000ull)

static void confere_calado(const char *caso, bool fechou)
{
	if (fechou) {
		printf("FALHOU %s\n  esperado: nenhuma amostra\n  obtido  : uma amostra\n", caso);
		falhas++;
	} else {
		printf("ok %s\n  nenhuma amostra, como deve ser\n", caso);
	}
}

static void confere_linha(const char *caso, bool fechou, const struct amostra_do_enlace *a,
			  const char *esperado)
{
	if (!fechou) {
		printf("FALHOU %s\n  esperado: %s\n  obtido  : nenhuma amostra\n", caso, esperado);
		falhas++;
		return;
	}
	char saida[256];
	formatar_janela_do_enlace(a, saida, sizeof saida);
	if (strcmp(saida, esperado) != 0) {
		printf("FALHOU %s\n  esperado: %s\n  obtido  : %s\n", caso, esperado, saida);
		falhas++;
	} else {
		printf("ok %s\n  %s\n", caso, saida);
	}
}

int main(void)
{
	struct janela_do_enlace j;
	struct amostra_do_enlace a;
	bool fechou;

	janela_do_enlace_zerar(&j);

	// A sessão já rodava quando a primeira janela abriu: 10.000 pacotes vistos e 100 perdidos
	// são history, não dano desta janela. Relatar isto seria mandar ao controlador do emissor uma
	// perda de 1 % que aconteceu antes de ele estar escutando.
	fechou = janela_do_enlace_fechar(&j, MS(0), 500, 10000, 100, 5, 2, &a);
	confere_calado("a primeira chamada só ancora", fechou);

	// 200 ms depois, com pacote entrando, ainda não há janela: o laço acorda a cada ~20 ms e
	// relatar a cada volta encheria a sinalização de amostras que o controlador descartaria.
	fechou = janela_do_enlace_fechar(&j, MS(200), 500, 10400, 110, 5, 2, &a);
	confere_calado("a janela que ainda não fechou não relata", fechou);

	// A janela fecha em 502 ms — a duração **real**, e não os 500 nominais.
	//
	// vistos 10000 -> 10970 (970 chegaram), perdidos 100 -> 130 (30 sumiram).
	// pacotes = 970 + 30 = 1000, que é o que o emissor mandou; 30/1000 = 3,00 %.
	//
	// Com o denominador errado — dividir pelo que **chegou** — daria 30/970 = 3,09 %. O viés não
	// é constante: ele cresce com a perda, e foi assim que o braço que parecia o melhor da matriz
	// era o pior.
	fechou = janela_do_enlace_fechar(&j, MS(502), 500, 10970, 130, 7, 3, &a);
	confere_linha("a derivada, com o denominador do emissor", fechou, &a,
		      "janela_do_enlace ms=502 pacotes=1000 perdidos=30 (3.00%) suspeitos=2"
		      " idrs_quebrados=1");
	if (fechou) {
		double errado = a.perdidos * 100.0 / (double)(a.pacotes - a.perdidos);
		printf("  (o denominador errado, o que chegou, diria %.2f%%)\n", errado);
		if (a.pacotes != 1000 || a.perdidos != 30) {
			printf("FALHOU o denominador não é vistos+perdidos\n");
			falhas++;
		}
	}

	// A track foi recriada e os contadores do núcleo voltaram para perto de zero. Sem saturação,
	// `perdidos` daria 0 - 130 em `uint64_t` = 18.446.744.073.709.551.486 — e o controlador do
	// outro lado leria uma perda de 100 % onde não houve perda nenhuma.
	fechou = janela_do_enlace_fechar(&j, MS(1004), 500, 200, 0, 0, 0, &a);
	confere_linha("contador que regride satura em zero, não em perda negativa", fechou, &a,
		      "janela_do_enlace ms=502 pacotes=0 perdidos=0 (0.00%) suspeitos=0"
		      " idrs_quebrados=0");

	// E a janela seguinte volta a medir certo, porque a âncora foi refeita nos valores novos:
	// vistos 200 -> 1200 (1000), perdidos 0 -> 10 (10). pacotes = 1010; 10/1010 = 0,99 %.
	fechou = janela_do_enlace_fechar(&j, MS(1506), 500, 1200, 10, 1, 0, &a);
	confere_linha("depois da regressão, a janela seguinte mede em cima da âncora nova", fechou,
		      &a,
		      "janela_do_enlace ms=502 pacotes=1010 perdidos=10 (0.99%) suspeitos=1"
		      " idrs_quebrados=0");

	// Período zero não é janela: sem isto, uma casca que passasse 0 por engano relataria a cada
	// volta do laço.
	fechou = janela_do_enlace_fechar(&j, MS(3000), 0, 9999, 999, 9, 9, &a);
	confere_calado("período zero não é janela", fechou);

	printf("\n%s\n", falhas ? "VERMELHO" : "verde: 6/6");
	return falhas ? 1 : 0;
}
