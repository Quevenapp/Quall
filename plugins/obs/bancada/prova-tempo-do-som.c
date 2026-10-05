// Banco de prova de `src/tempo-do-som.c` (S5 do `docs/som-no-receptor.md`), sem OBS, sem rede e
// sem aparelho. Mesma forma de `prova-fluidez.c`:
//
//     cc -Wall -Wextra -Werror -o /tmp/prova-tempo-do-som \
//        plugins/obs/bancada/prova-tempo-do-som.c plugins/obs/src/tempo-do-som.c -lm \
//        && /tmp/prova-tempo-do-som
//
// O que ela prova:
//
//  1. o reamostrador com razão 1 devolve a entrada amostra por amostra, atravessando blocos de
//     tamanhos que não casam com os slots (10 ms de saída contra 20 ms de entrada);
//  2. com razão 1 + 400 ppm, em 60 s ele consome 1,0004 vez a saída, com a fração levada de um
//     bloco ao outro (o erro fica abaixo de um quadro);
//  3. um seno de 3 150 Hz a 8 kHz, reamostrado a 1 + 300 ppm, sai com distorção pequena (o tom
//     da claquete atravessa a peça);
//  4. o µ-law contra valores literais da G.711;
//  5. a histerese do tique (crítica 16, N1): com a hora do som parada no meio entre dois tiques e
//     jitter de ±2 ms, o "tique mais perto" dá quadros de 1 e 3 tiques, e a histerese nenhum; com
//     a fase andando 3 períodos (outro cristal), uma troca por travessia;
//  6. a rampa da espera (N4): sobe e desce no máximo 10 % do intervalo por quadro, depois dela a
//     espera é a do tique, um quadro atrasado sozinho não a derruba, e o teto é 200 ms;
//  7. a mediana corrente da decodificação (N10), com 10 % de soluços;
//  8. o salto do som (crítica 17): o laço da thread do som simulado, com uma parada de 0 a 300 ms —
//     nenhum bloco sai com o carimbo a menos de 2 ms de agora, todo buraco no que sai tem 80 ms ou
//     mais (a libobs o põe pelo carimbo), e sem parada tudo sai.
//
// O que ela **não** prova: que o OBS põe o som onde o carimbo diz. Isso é a gravação do próprio
// OBS, lida pela claquete (`som-no-obs.sh`).

#include "../src/tempo-do-som.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int falhas;
#define CONFERE(cond, ...)                                  \
	do {                                                \
		if (!(cond)) {                              \
			falhas++;                           \
			printf("FALHA %s:%d: ", __FILE__, __LINE__); \
			printf(__VA_ARGS__);                \
			printf("\n");                       \
		}                                           \
	} while (0)

static void prova_razao_um(void)
{
	static struct reamostrador r;
	reamostrador_zerar(&r, 2);
	float slot[960 * 2], saida[480 * 2];
	size_t escrito = 0, lido = 0;
	int iguais = 1;
	for (int s = 0; s < 20; s++) {
		for (int i = 0; i < 960; i++) {
			slot[i * 2] = (float)(escrito + (size_t)i) / 100000.0f;
			slot[i * 2 + 1] = -(float)(escrito + (size_t)i) / 100000.0f;
		}
		reamostrador_empurrar(&r, slot, 960);
		escrito += 960;
		while (reamostrador_disponivel(&r, 1.0) >= 480) {
			size_t n = reamostrador_tirar(&r, saida, 480, 1.0);
			for (size_t k = 0; k < n; k++) {
				float esperado = (float)(lido + k) / 100000.0f;
				if (saida[k * 2] != esperado || saida[k * 2 + 1] != -esperado)
					iguais = 0;
			}
			lido += n;
		}
	}
	CONFERE(iguais, "razão 1: a saída é a entrada, amostra por amostra");
	CONFERE(lido >= escrito - 960 && lido <= escrito, "razão 1: consumiu %zu de %zu", lido, escrito);
	printf("razão 1: %zu quadros, idênticos: %s\n", lido, iguais ? "sim" : "NÃO");
}

static void prova_razao_ppm(void)
{
	static struct reamostrador r;
	reamostrador_zerar(&r, 1);
	const double razao = 1.0 + 400e-6;
	float slot[160], saida[80];
	uint64_t saidos = 0;
	uint64_t empurrados = 0;
	// 60 s a 8 kHz: slots de 20 ms de entrada, blocos de 10 ms de saída, a entrada sempre à frente.
	while (saidos < 8000ull * 60) {
		while (reamostrador_disponivel(&r, razao) < 80) {
			for (int i = 0; i < 160; i++)
				slot[i] = 0.0f;
			reamostrador_empurrar(&r, slot, 160);
			empurrados += 160;
		}
		saidos += reamostrador_tirar(&r, saida, 80, razao);
	}
	double consumidos = reamostrador_posicao_global(&r);
	double esperado = (double)saidos * razao;
	CONFERE(fabs(consumidos - esperado) < 1.0, "400 ppm: consumiu %.3f, esperado %.3f", consumidos, esperado);
	double a_frente = reamostrador_a_frente(&r);
	CONFERE(fabs(((double)empurrados - consumidos) - a_frente) < 1.01,
		"o que falta à frente bate com o empurrado menos o lido: %.2f contra %.2f",
		(double)empurrados - consumidos, a_frente);
	printf("400 ppm em 60 s: %llu quadros de saída consumiram %.3f de entrada (%.1f ppm)\n",
	       (unsigned long long)saidos, consumidos, (consumidos / (double)saidos - 1.0) * 1e6);
}

/// O caminho do PCMU inteiro: 8 kHz → interpolador por 6 → cúbica a 48 kHz, a 1 + 300 ppm. A
/// saída k lê a posição global k·razão da entrada de 48 kHz, que está o atraso do filtro atrás do
/// sinal: o seno ideal ali, contra o que saiu.
static double snr_do_caminho_pcmu(double hz)
{
	static struct reamostrador r;
	static struct interpolador it;
	reamostrador_zerar(&r, 1);
	interpolador_iniciar(&it);
	const double razao = 1.0 + 300e-6;
	float slot[160], a48[960];
	static float saida[48000];
	size_t n = 0;
	uint64_t indice = 0;
	while (n < 48000) {
		for (int i = 0; i < 160; i++, indice++)
			slot[i] = 0.5f * (float)sin(2.0 * M_PI * hz * (double)indice / 8000.0);
		interpolador_processar(&it, slot, 160, a48);
		reamostrador_empurrar(&r, a48, 960);
		n += reamostrador_tirar(&r, &saida[n], 48000 - n, razao);
	}
	const double atraso = (INTERPOLADOR_FATOR * INTERPOLADOR_POR_FASE - 1) / 2.0; // em quadros de 48 kHz
	double erro2 = 0, sinal2 = 0;
	for (size_t k = 2000; k < 48000; k++) {
		double ideal = 0.5 * sin(2.0 * M_PI * hz * ((double)k * razao - atraso) / 48000.0);
		erro2 += (saida[k] - ideal) * (saida[k] - ideal);
		sinal2 += ideal * ideal;
	}
	return 10.0 * log10(sinal2 / erro2);
}

static void prova_seno(void)
{
	// O estouro da claquete (3 150 Hz) e o tom de fundo da sonda (1 kHz). A cúbica sozinha, a
	// 8 kHz, dava 8,6 dB no estouro: foi o que pôs o interpolador na frente dela.
	double snr_estouro = snr_do_caminho_pcmu(3150.0);
	double snr_tom = snr_do_caminho_pcmu(1000.0);
	CONFERE(snr_estouro > 30.0, "3150 Hz pelo caminho do PCMU: SNR %.1f dB", snr_estouro);
	CONFERE(snr_tom > 40.0, "1000 Hz pelo caminho do PCMU: SNR %.1f dB", snr_tom);
	printf("caminho do PCMU (×6 e cúbica a 1 + 300 ppm): SNR %.1f dB a 3 150 Hz, %.1f dB a 1 kHz\n",
	       snr_estouro, snr_tom);

	// E a cúbica sozinha a 48 kHz (o caminho do Opus), a 3 150 Hz.
	static struct reamostrador r;
	reamostrador_zerar(&r, 1);
	const double razao = 1.0 + 300e-6;
	float slot[960];
	static float saida[48000];
	size_t n = 0;
	uint64_t indice = 0;
	while (n < 48000) {
		for (int i = 0; i < 960; i++, indice++)
			slot[i] = 0.5f * (float)sin(2.0 * M_PI * 3150.0 * (double)indice / 48000.0);
		reamostrador_empurrar(&r, slot, 960);
		n += reamostrador_tirar(&r, &saida[n], 48000 - n, razao);
	}
	double erro2 = 0, sinal2 = 0;
	for (size_t k = 100; k < 48000; k++) {
		double ideal = 0.5 * sin(2.0 * M_PI * 3150.0 * (double)k * razao / 48000.0);
		erro2 += (saida[k] - ideal) * (saida[k] - ideal);
		sinal2 += ideal * ideal;
	}
	double snr = 10.0 * log10(sinal2 / erro2);
	CONFERE(snr > 40.0, "3150 Hz a 48 kHz: SNR %.1f dB", snr);
	printf("cúbica a 48 kHz (o caminho do Opus), 3 150 Hz a 1 + 300 ppm: SNR %.1f dB\n", snr);
}

static void prova_mulaw(void)
{
	// Valores literais da G.711: 0xFF e 0x7F são os zeros; 0x00 e 0x80 os extremos.
	CONFERE(mulaw_para_float(0xFF) == 0.0f, "0xFF é zero");
	CONFERE(mulaw_para_float(0x7F) == 0.0f, "0x7F é zero");
	CONFERE(mulaw_para_float(0x80) * 32768.0f == 32124.0f, "0x80 é +32124: %f", mulaw_para_float(0x80) * 32768.0f);
	CONFERE(mulaw_para_float(0x00) * 32768.0f == -32124.0f, "0x00 é -32124: %f", mulaw_para_float(0x00) * 32768.0f);
	CONFERE(mulaw_para_float(0xFE) * 32768.0f == 8.0f, "0xFE é +8: %f", mulaw_para_float(0xFE) * 32768.0f);
	printf("µ-law: ok\n");
}

/// Um gerador pseudoaleatório fixo, para a prova sair igual toda vez: uniforme em [-1, 1).
static double sorteio(uint64_t *estado)
{
	*estado = *estado * 6364136223846793005ull + 1442695040888963407ull;
	return (double)(*estado >> 11) / (double)(1ull << 53) * 2.0 - 1.0;
}

/// Quantos quadros de 30 fps num canvas de 60 não ficam exatos 2 tiques, com ou sem a histerese.
/// `fora_a_cada`: um quadro a cada tantos chega com a hora do som 5 ms fora da fase (0: nenhum).
static int quadros_tortos(bool histerese, double fase_inicial, double fase_final, int n, int fora_a_cada,
			  int *trocas, double *maior_erro)
{
	const int64_t p = 16666667; // o `video_frame_interval_ns` de 60 fps
	const int64_t ref = 1000000000000ll;
	struct espera_da_imagem e;
	espera_zerar(&e);
	uint64_t sorte = 42;
	int64_t anterior = 0;
	int tortos = 0;
	*trocas = 0;
	*maior_erro = 0;
	for (int i = 0; i < n; i++) {
		double fase = fase_inicial + (fase_final - fase_inicial) * (double)i / (double)n;
		int64_t alvo = ref + 2 * p * (int64_t)i + (int64_t)(fase * (double)p) + (int64_t)(2e6 * sorteio(&sorte));
		bool fora = fora_a_cada && i % fora_a_cada == fora_a_cada - 1;
		if (fora)
			alvo += 5000000;
		if (!histerese)
			espera_esquecer_o_tique(&e);
		bool trocou = false, segurou = false;
		int64_t tique = espera_tique(&e, alvo, ref, p, &trocou, &segurou);
		if (trocou)
			(*trocas)++;
		double erro = fabs((double)(tique - alvo)) / (double)p;
		if (!fora && erro > *maior_erro)
			*maior_erro = erro;
		if (i > 0 && tique - anterior != 2 * p)
			tortos++;
		anterior = tique;
	}
	return tortos;
}

static void prova_histerese(void)
{
	int trocas;
	double maior;
	int sem = quadros_tortos(false, 0.5, 0.5, 3000, 0, &trocas, &maior);
	int com = quadros_tortos(true, 0.5, 0.5, 3000, 0, &trocas, &maior);
	CONFERE(sem > 100, "sem histerese, a fase no meio tinha de dar trancos: %d", sem);
	CONFERE(com == 0, "com histerese, a fase no meio não dá tranco: %d", com);
	CONFERE(maior < ESPERA_HISTERESE, "o erro fica abaixo de 0,75 período: %.3f", maior);
	printf("histerese, fase parada no meio, ±2 ms: %d quadros tortos sem, %d com (erro máximo %.2f período)\n",
	       sem, com, maior);

	int sem_d = quadros_tortos(false, 0.0, 3.0, 6000, 0, &trocas, &maior);
	int trocas_sem = trocas;
	int com_d = quadros_tortos(true, 0.0, 3.0, 6000, 0, &trocas, &maior);
	// A fase anda 3 períodos: 3 travessias. Cada uma dá um quadro de 1 ou 3 tiques e o seguinte de
	// volta: no máximo 2 tortos por travessia, mais uma de folga.
	CONFERE(trocas >= 2 && trocas <= 4, "3 períodos de deriva: %d trocas", trocas);
	CONFERE(com_d <= 8, "3 períodos de deriva: %d quadros tortos", com_d);
	// Na travessia, o primeiro quadro que pede a troca ainda fica: 0,75 mais o jitter de ±2 ms
	// (0,12 período) e a deriva de um quadro.
	CONFERE(maior < ESPERA_HISTERESE + 0.15, "o erro fica abaixo de 0,9 período: %.3f", maior);
	printf("histerese, fase andando 3 períodos: %d quadros tortos sem (%d trocas), %d com (%d trocas)\n", sem_d,
	       trocas_sem, com_d, trocas);

	// A fase parada no meio e um quadro a cada 50 com a hora do som 5 ms fora (a `r16-opus-b`):
	// um quadro sozinho não troca o lado, e nenhum quadro fica torto.
	int fora = quadros_tortos(true, 0.5, 0.5, 3000, 50, &trocas, &maior);
	CONFERE(trocas == 0, "um quadro fora da fase a cada 50: %d trocas", trocas);
	CONFERE(fora == 0, "um quadro fora da fase a cada 50: %d quadros tortos", fora);
	printf("histerese, fase no meio e um quadro a cada 50 fora da fase por 5 ms: %d trocas, %d tortos\n", trocas,
	       fora);
}

static void prova_rampa(void)
{
	struct espera_da_imagem e;
	espera_zerar(&e);
	uint64_t sorte = 7;
	uint64_t ts = 1000000;
	const uint64_t intervalo_us = 33333;
	const double passo_max = ESPERA_RAMPA * (double)intervalo_us * 1000.0 + 1.0;
	int64_t anterior = 0;
	int convergiu_em = -1;
	bool ok_subida = true, ok_depois = true;
	// A subida: o mapa passa a valer com a espera desejada de 80 ms ± 8.
	for (int i = 0; i < 120; i++) {
		int64_t desejada = 80000000 + (int64_t)(8e6 * sorteio(&sorte));
		bool na_rampa = false;
		int64_t w = espera_do_quadro(&e, ts, true, desejada, &na_rampa);
		ts += intervalo_us;
		// Antes de alcançar a desejada, todo quadro anda no máximo um passo. Depois, o jitter anda
		// livre dentro da folga de 20 ms do teto, e isso não é rampa.
		if (convergiu_em < 0 && i > 0 && (double)(w - anterior) > passo_max)
			ok_subida = false;
		if (!na_rampa && convergiu_em < 0)
			convergiu_em = i;
		if (convergiu_em >= 0 && i > convergiu_em + 5 && (na_rampa || w != desejada))
			ok_depois = false;
		anterior = w;
	}
	CONFERE(ok_subida, "a subida anda no máximo 10 %% do intervalo por quadro");
	CONFERE(convergiu_em >= 20 && convergiu_em <= 30, "a subida de 80 ms a 30 fps leva ~24 quadros: %d",
		convergiu_em);
	CONFERE(ok_depois, "depois da rampa, a espera é a desejada, com o jitter");

	// Um quadro atrasado sozinho: espera zero, e o seguinte volta à desejada sem rampa.
	bool na_rampa = false;
	int64_t w = espera_do_quadro(&e, ts, true, -5000000, &na_rampa);
	ts += intervalo_us;
	CONFERE(w == 0 && !na_rampa, "o atrasado sai já: %lld", (long long)w);
	w = espera_do_quadro(&e, ts, true, 81000000, &na_rampa);
	ts += intervalo_us;
	CONFERE(w == 81000000 && !na_rampa, "o seguinte volta à desejada: %lld (rampa %d)", (long long)w, na_rampa);

	// A descida: o mapa vence (o som ocioso) ou a fonte foi mutada.
	anterior = w;
	int zerou_em = -1;
	bool ok_descida = true;
	for (int i = 0; i < 60; i++) {
		w = espera_do_quadro(&e, ts, false, 0, &na_rampa);
		ts += intervalo_us;
		if ((double)(anterior - w) > passo_max)
			ok_descida = false;
		if (w == 0 && zerou_em < 0)
			zerou_em = i;
		anterior = w;
	}
	CONFERE(ok_descida, "a descida anda no máximo 10 %% do intervalo por quadro");
	CONFERE(zerou_em >= 20 && zerou_em <= 30, "a descida de 81 ms leva ~24 quadros: %d", zerou_em);
	CONFERE(e.teto_ns == 0, "sem espera, o teto desce junto: %lld", (long long)e.teto_ns);

	// O teto: nem a desejada de 300 ms passa de 200.
	int64_t maior = 0;
	for (int i = 0; i < 200; i++) {
		w = espera_do_quadro(&e, ts, true, 300000000, &na_rampa);
		ts += intervalo_us;
		if (w > maior)
			maior = w;
	}
	CONFERE(maior == ESPERA_NO_MAXIMO_NS, "o teto é 200 ms: %lld", (long long)maior);
	printf("rampa: sobe em %d quadros, desce em %d, teto %.0f ms\n", convergiu_em, zerou_em, (double)maior / 1e6);
}

static void prova_decode(void)
{
	struct espera_da_imagem e;
	espera_zerar(&e);
	CONFERE(espera_decode(&e) == ESPERA_DECODE_PADRAO_NS, "antes da medida, 3 ms");
	uint64_t sorte = 3;
	for (int i = 0; i < 600; i++) {
		double u = (sorteio(&sorte) + 1.0) / 2.0;
		int64_t d = u < 0.1 ? 40000000 : 4000000 + (int64_t)(500000 * sorteio(&sorte));
		espera_medir_decode(&e, d);
	}
	double a = (double)espera_decode(&e) / 1e6;
	CONFERE(a > 3.5 && a < 5.0, "4 ms com 10 %% de soluços de 40 ms: %.2f ms", a);
	for (int i = 0; i < 300; i++)
		espera_medir_decode(&e, 8000000);
	double b = (double)espera_decode(&e) / 1e6;
	CONFERE(b > 7.8 && b < 8.2, "a decodificação passou a 8 ms: %.2f ms", b);
	printf("decodificação: %.2f ms com soluços (mediana 4), %.2f ms depois de passar a 8\n", a, b);
}

/// O laço da `thread_do_som` (`som.c`), com o relógio simulado: blocos de 10 ms, carimbo 20 ms à
/// frente, e a thread parada `parada_ns` uma vez, aos 10 s. Cada `obs_source_output_audio` custa
/// 0,1 ms. Confere as duas regras que evitam a catraca da libobs.
static void simular_parada(uint64_t parada_ns, int *publicados, int *pulados, int *saltos, int *no_passado,
			   int *buracos_curtos, uint64_t *maior_buraco)
{
	const uint64_t bloco = 10000000ull, adiantamento = 20000000ull;
	struct salto_do_som salto = {0};
	uint64_t relogio = 1000000000000ull, t0 = relogio, blocos = 0, fim = 0;
	bool parou = false;
	*publicados = *pulados = *saltos = *no_passado = *buracos_curtos = 0;
	*maior_buraco = 0;
	while (blocos < 3000) {
		if (!parou && blocos >= 1000) {
			relogio += parada_ns;
			parou = true;
		}
		uint64_t agora = relogio;
		uint64_t t_bloco = t0 + blocos * bloco;
		if (agora > t_bloco + 200000000ull) {
			t0 = agora;
			blocos = 0;
			t_bloco = t0;
		}
		while (t_bloco <= agora) {
			uint64_t carimbo = t_bloco + adiantamento;
			bool abriu = false;
			if (salto_publicar(&salto, carimbo, bloco, relogio, &abriu)) {
				if (carimbo <= relogio + SALTO_MARGEM_NS)
					(*no_passado)++;
				if (fim && carimbo != fim) {
					uint64_t buraco = carimbo - fim;
					if (buraco < 70000000ull)
						(*buracos_curtos)++;
					if (buraco > *maior_buraco)
						*maior_buraco = buraco;
				}
				fim = carimbo + bloco;
				(*publicados)++;
				relogio += 100000; // o custo da publicação
			} else {
				(*pulados)++;
			}
			if (abriu)
				(*saltos)++;
			blocos++;
			t_bloco = t0 + blocos * bloco;
		}
		// O sono até o próximo bloco, acordando 0 a 3 ms depois.
		relogio = t_bloco + (blocos * 7919 % 3000000ull);
	}
}

static void prova_salto(void)
{
	int pub, pul, sal, passado, curtos;
	uint64_t maior;
	simular_parada(0, &pub, &pul, &sal, &passado, &curtos, &maior);
	CONFERE(pul == 0 && sal == 0, "sem parada, tudo sai: %d pulados, %d saltos", pul, sal);
	int falhas_antes = falhas;
	for (uint64_t d = 5000000ull; d <= 300000000ull; d += 5000000ull) {
		simular_parada(d, &pub, &pul, &sal, &passado, &curtos, &maior);
		CONFERE(passado == 0, "parada de %llu ms: %d bloco(s) publicados sem estar no futuro",
			(unsigned long long)(d / 1000000), passado);
		CONFERE(curtos == 0, "parada de %llu ms: %d buraco(s) de menos de 70 ms", (unsigned long long)(d / 1000000),
			curtos);
		if (d == 30000000ull || d == 95000000ull || d == 120000000ull || d == 250000000ull)
			printf("salto, parada de %3llu ms: %d salto(s), %d bloco(s) pulados, maior buraco %.0f ms\n",
			       (unsigned long long)(d / 1000000), sal, pul, (double)maior / 1e6);
	}
	if (falhas == falhas_antes)
		printf("salto: de 5 a 300 ms de parada, nenhum bloco sai sem estar no futuro, e todo buraco tem 80 ms ou mais\n");
}

int main(void)
{
	prova_razao_um();
	prova_razao_ppm();
	prova_seno();
	prova_mulaw();
	prova_histerese();
	prova_rampa();
	prova_decode();
	prova_salto();
	if (falhas) {
		printf("%d falha(s)\n", falhas);
		return 1;
	}
	printf("tudo certo\n");
	return 0;
}
