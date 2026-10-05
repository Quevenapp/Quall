// Banco de prova de `src/fluidez.c`, sem OBS, sem rede e sem aparelho.
//
// Mesma razão de `prova-janela-do-enlace.c`: a aritmética que decide o que a bancada vai comparar
// entre dois enlaces não pode ficar à espera de uma corrida na Wi-Fi para ser afirmada. A peça não
// inclui nada do `libobs`, então ela compila e roda sozinha:
//
//     cc -Wall -Wextra -Werror -o /tmp/prova-fluidez \
//        plugins/obs/bancada/prova-fluidez.c plugins/obs/src/fluidez.c \
//        && /tmp/prova-fluidez
//
// **O que esta prova NÃO prova**, e é a metade que importa: ela não diz que a marca está no lugar
// certo dentro do `receptor.c`, nem que publicar para o OBS tem alguma relação medida com o que
// aparece no vidro. Ela prova a aritmética, com instantes inventados na mesa. Ver o cabeçalho de
// `src/fluidez.h`, seção "Publicar para o OBS não é pôr na tela".
//
// Os casos são os que o contrato torna obrigatórios:
//
//  1. a **primeira** chamada só ancora — senão a subida do ICE entraria na distribuição da imagem;
//  2. a **derivada**, com o `ms` real de dois instantes;
//  3. o **buraco no meio de uma sessão regular** (29 intervalos de 33 ms e um de 226) aparecendo
//     no `max` e nos `trancos` — a corrida de 01/09/2026 em miniatura, e a razão de a média não
//     bastar;
//  4. o corte de `trancos` **estrito**, no microssegundo;
//  5. a **porta** que segura três quadros virando um intervalo de quatro tempos;
//  6. a sessão vazia, que não afirma nada e **não divide por zero**;
//  7. o **teto**, com o descarte dito na linha — e com um buraco que o `max` não enxerga, que é
//     precisamente por que ele tem de ser dito.

#include "../src/fluidez.h"

#include <stdio.h>
#include <string.h>

static int falhas;

#define MS(x) ((uint64_t)(x) * 1000000ull)
#define US(x) ((uint64_t)(x) * 1000ull)

static void confere_linha(const char *caso, struct fluidez *f, const char *esperado)
{
	char saida[192];
	formatar_fluidez(f, saida, sizeof saida);
	if (strcmp(saida, esperado) != 0) {
		printf("FALHOU %s\n  esperado: %s\n  obtido  : %s\n", caso, esperado, saida);
		falhas++;
	} else {
		printf("ok %s\n  %s\n", caso, saida);
	}
}

static void confere_trancos(const char *caso, uint64_t obtido, uint64_t esperado)
{
	if (obtido != esperado) {
		printf("FALHOU %s\n  esperado: trancos=%llu\n  obtido  : trancos=%llu\n", caso,
		       (unsigned long long)esperado, (unsigned long long)obtido);
		falhas++;
	} else {
		printf("ok %s\n  trancos=%llu\n", caso, (unsigned long long)obtido);
	}
}

int main(void)
{
	struct fluidez f;

	// 1. A primeira chamada só ancora. Não existe intervalo antes do primeiro quadro, e contar o
	//    tempo desde a abertura da sessão poria a subida do ICE e a espera pelo primeiro IDR
	//    dentro da distribuição da imagem: uma sessão que levou 4 s para montar imagem sairia com
	//    `max=4000` e um tranco que nunca foi tranco.
	fluidez_zerar(&f);
	fluidez_publicou(&f, MS(4000));
	confere_linha("a primeira publicação só ancora", &f,
		      "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0");

	// 2. Dois quadros, um intervalo — e ele é o decorrido real entre os dois instantes, não o
	//    tempo de quadro nominal.
	fluidez_zerar(&f);
	fluidez_publicou(&f, MS(1000));
	fluidez_publicou(&f, MS(1033));
	confere_linha("dois quadros dão um intervalo, com o ms real", &f,
		      "fluidez_ms=[n=1 p50=33 p95=33 max=33] trancos=0");

	// 3. **O que a média escondia.** Vinte e nove intervalos de 33 ms e um de 226 ms: a média dá
	//    ~39 ms e parece saudável; o `max` mostra o buraco e `trancos` o conta. É a corrida de
	//    01/09/2026 em miniatura — a média de fila→tela dizia 6,4 ms e estava certa.
	fluidez_zerar(&f);
	uint64_t agora = 0;
	fluidez_publicou(&f, MS(agora));
	uint64_t soma = 0;
	for (int i = 0; i < 30; i++) {
		uint64_t passo = (i == 15) ? 226 : 33;
		agora += passo;
		soma += passo;
		fluidez_publicou(&f, MS(agora));
	}
	confere_linha("um buraco no meio de uma sessão regular aparece no max e nos trancos", &f,
		      "fluidez_ms=[n=30 p50=33 p95=33 max=226] trancos=1");
	printf("  (a média dos mesmos 30 intervalos é %.1f ms — foi ela que não respondia nada)\n",
	       (double)soma / 30.0);

	// 4. O corte é **estrito**, e no microssegundo: exatamente no limiar não conta, um
	//    microssegundo acima conta. Fica fixado para que a comparação entre duas corridas não
	//    dependa de arredondamento.
	fluidez_zerar(&f);
	fluidez_publicou(&f, 0);
	fluidez_publicou(&f, MS(FLUIDEZ_TRANCO_MS));
	confere_trancos("exatamente no limiar não é tranco", fluidez_trancos(&f), 0);
	fluidez_publicou(&f, MS(FLUIDEZ_TRANCO_MS) + MS(FLUIDEZ_TRANCO_MS) + US(1));
	confere_trancos("um microssegundo acima do limiar é", fluidez_trancos(&f), 1);
	confere_linha("os dois lados do corte na mesma linha", &f,
		      "fluidez_ms=[n=2 p50=100 p95=100 max=100] trancos=1");
	printf("  (a linha é em ms inteiros e mostra max=100; o corte é em microssegundos e conta"
	       " 1 tranco — a resolução do relato não é a da decisão)\n");

	// 5. **A porta aparece aqui, e é o ponto.** Segurar um quadro condenado não o conserta: a
	//    cena para no último quadro bom. Este caso é a forma que isso tem na distribuição — a
	//    cada cinco quadros, três ficam retidos e não chamam `obs_source_output_video`, e o
	//    intervalo seguinte vira 4 x 33 = 132 ms. Medir chegadas esconderia exatamente isto.
	fluidez_zerar(&f);
	agora = 0;
	fluidez_publicou(&f, MS(agora));
	for (int i = 0; i < 10; i++) {
		agora += (i % 5 == 0) ? 33 * 4 : 33;
		fluidez_publicou(&f, MS(agora));
	}
	confere_linha("a porta que segura três quadros vira um intervalo de quatro tempos", &f,
		      "fluidez_ms=[n=10 p50=33 p95=132 max=132] trancos=2");

	// 6. Uma sessão sem quadro nenhum não afirma nada — e não divide por zero.
	fluidez_zerar(&f);
	confere_linha("sem quadro nenhum a linha existe e não mente", &f,
		      "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0");
	confere_trancos("e não há tranco a contar", fluidez_trancos(&f), 0);

	// 7. **O teto, e o que ele custa.** Depois de FLUIDEZ_MAXIMO_DE_AMOSTRAS intervalos, a
	//    distribuição para de crescer. Os cinco buracos de 500 ms que chegam depois **não**
	//    aparecem no `max` nem nos `trancos` — só no `(+5 além do teto)`. É por isso que o
	//    descarte é dito na linha em vez de o `n` fingir que é a sessão inteira.
	fluidez_zerar(&f);
	agora = 0;
	fluidez_publicou(&f, MS(agora));
	for (int i = 0; i < FLUIDEZ_MAXIMO_DE_AMOSTRAS; i++) {
		agora += 33;
		fluidez_publicou(&f, MS(agora));
	}
	for (int i = 0; i < 5; i++) {
		agora += 500;
		fluidez_publicou(&f, MS(agora));
	}
	confere_linha("o teto descarta, e o descarte é dito em vez de o n fingir a sessão inteira",
		      &f,
		      "fluidez_ms=[n=10000 p50=33 p95=33 max=33] trancos=0"
		      " (+5 além do teto)");
	printf("  (os cinco intervalos de 500 ms que vieram depois do teto NÃO estão no max nem"
	       " nos trancos — só no +5)\n");

	printf("\n%s\n", falhas ? "VERMELHO" : "verde: 10/10");
	return falhas ? 1 : 0;
}
