#include "tempo-do-som.h"

#include <math.h>
#include <string.h>

// -------------------------------------------------------------------------------------------------
// O reamostrador
// -------------------------------------------------------------------------------------------------

void reamostrador_zerar(struct reamostrador *r, uint32_t canais)
{
	memset(r, 0, sizeof(*r));
	r->canais = canais < 1 ? 1 : (canais > REAMOSTRADOR_CANAIS_MAX ? REAMOSTRADOR_CANAIS_MAX : canais);
	// Um quadro de silêncio de história: a interpolação de Hermite lê um vizinho para trás, e a
	// primeira amostra de verdade sai exata na posição 1.
	r->quadros = 1;
	r->posicao = 1.0;
	r->consumidos = 0;
}

size_t reamostrador_empurrar(struct reamostrador *r, const float *pcm, size_t n)
{
	size_t cabe = REAMOSTRADOR_FILA - r->quadros;
	if (n > cabe)
		n = cabe;
	memcpy(&r->fila[r->quadros * r->canais], pcm, n * r->canais * sizeof(float));
	r->quadros += n;
	return n;
}

size_t reamostrador_disponivel(const struct reamostrador *r, double razao)
{
	// A saída k lê a posição `posicao + k * razao` e precisa de dois vizinhos à frente: a posição
	// tem de ficar abaixo de `quadros - 2`.
	double folga = (double)r->quadros - 2.0 - r->posicao;
	if (folga <= 0 || razao <= 0)
		return 0;
	return (size_t)ceil(folga / razao);
}

static float hermite(float p0, float p1, float p2, float p3, float t)
{
	float a = -p0 + 3.0f * p1 - 3.0f * p2 + p3;
	float b = 2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3;
	float c = -p0 + p2;
	return 0.5f * (((a * t + b) * t + c) * t) + p1;
}

size_t reamostrador_tirar(struct reamostrador *r, float *saida, size_t n, double razao)
{
	size_t d = reamostrador_disponivel(r, razao);
	if (n > d)
		n = d;
	const uint32_t c = r->canais;
	for (size_t k = 0; k < n; k++) {
		size_t i = (size_t)r->posicao;
		float t = (float)(r->posicao - (double)i);
		for (uint32_t ch = 0; ch < c; ch++) {
			float p0 = r->fila[(i - 1) * c + ch];
			float p1 = r->fila[i * c + ch];
			float p2 = r->fila[(i + 1) * c + ch];
			float p3 = r->fila[(i + 2) * c + ch];
			// Na fração zero a saída é a amostra, sem arredondamento de ponto flutuante nenhum.
			saida[k * c + ch] = t == 0.0f ? p1 : hermite(p0, p1, p2, p3, t);
		}
		r->posicao += razao;
	}
	// Tira da frente o que não será mais lido, guardando um quadro de história.
	size_t ler = (size_t)r->posicao;
	if (ler > 1) {
		size_t sai = ler - 1;
		memmove(r->fila, &r->fila[sai * c], (r->quadros - sai) * c * sizeof(float));
		r->quadros -= sai;
		r->posicao -= (double)sai;
		r->consumidos += sai;
	}
	return n;
}

double reamostrador_a_frente(const struct reamostrador *r)
{
	double a = (double)r->quadros - r->posicao;
	return a > 0 ? a : 0;
}

double reamostrador_posicao_global(const struct reamostrador *r)
{
	// A fila começa, na numeração global, em `consumidos`; o quadro 0 de todos é o de história.
	return (double)r->consumidos + r->posicao - 1.0;
}

// -------------------------------------------------------------------------------------------------
// O interpolador por 6
// -------------------------------------------------------------------------------------------------

/// A função de Bessel modificada de ordem zero, pela série.
static double bessel_i0(double x)
{
	double soma = 1.0, termo = 1.0, k = 1.0;
	while (termo > 1e-12 * soma) {
		termo *= (x / (2 * k)) * (x / (2 * k));
		soma += termo;
		k += 1;
	}
	return soma;
}

void interpolador_iniciar(struct interpolador *it)
{
	const int n = INTERPOLADOR_FATOR * INTERPOLADOR_POR_FASE;
	const double corte = 4000.0 / 48000.0, beta = 7.0, pi = 3.14159265358979323846;
	const double meio = (double)(n - 1) / 2.0;
	double h[INTERPOLADOR_FATOR * INTERPOLADOR_POR_FASE];
	double soma = 0;
	for (int m = 0; m < n; m++) {
		double x = (double)m - meio;
		double sinc = x == 0 ? 2 * corte : sin(2 * pi * corte * x) / (pi * x);
		double r = x / meio;
		double janela = bessel_i0(beta * sqrt(1 - r * r)) / bessel_i0(beta);
		h[m] = sinc * janela;
		soma += h[m];
	}
	// Ganho de DC igual ao fator: a entrada é "esticada" com zeros, e cada fase soma um sexto.
	for (int m = 0; m < n; m++)
		it->coeficientes[m] = (float)(h[m] / soma * INTERPOLADOR_FATOR);
	memset(it->historia, 0, sizeof(it->historia));
	it->cabeca = 0;
}

void interpolador_processar(struct interpolador *it, const float *entrada, size_t n, float *saida)
{
	const int f = INTERPOLADOR_FATOR, k = INTERPOLADOR_POR_FASE;
	for (size_t i = 0; i < n; i++) {
		it->cabeca = (it->cabeca + 1) % k;
		it->historia[it->cabeca] = entrada[i];
		for (int p = 0; p < f; p++) {
			float y = 0;
			int h = it->cabeca;
			for (int j = 0; j < k; j++) {
				y += it->coeficientes[p + f * j] * it->historia[h];
				h = h == 0 ? k - 1 : h - 1;
			}
			saida[i * (size_t)f + (size_t)p] = y;
		}
	}
}

float interpolador_ultima(const struct interpolador *it)
{
	return it->historia[it->cabeca];
}

// -------------------------------------------------------------------------------------------------
// µ-law
// -------------------------------------------------------------------------------------------------

float mulaw_para_float(uint8_t u)
{
	u = (uint8_t)~u;
	int sinal = u & 0x80;
	int expoente = (u >> 4) & 0x07;
	int mantissa = u & 0x0F;
	int amostra = (((mantissa << 3) + 0x84) << expoente) - 0x84;
	return (float)(sinal ? -amostra : amostra) / 32768.0f;
}

// -------------------------------------------------------------------------------------------------
// A espera da imagem
// -------------------------------------------------------------------------------------------------

void espera_zerar(struct espera_da_imagem *e)
{
	memset(e, 0, sizeof(*e));
}

int64_t espera_tique(struct espera_da_imagem *e, int64_t alvo_ns, int64_t referencia_ns, int64_t periodo_ns,
		     bool *trocou, bool *segurou)
{
	*trocou = false;
	*segurou = false;
	if (!referencia_ns || periodo_ns <= 0) {
		e->tem_erro_anterior = false;
		return alvo_ns;
	}
	const double p = (double)periodo_ns;
	// A posição da hora do som na grade dos tiques, em períodos.
	const double x = (double)(alvo_ns - referencia_ns) / p;
	double k = floor(x + 0.5);
	if (e->tem_erro_anterior) {
		// O tique que repete o erro do quadro anterior: o mesmo lado, a mesma fase.
		double k_mesmo = floor(x + (double)e->erro_anterior_ns / p + 0.5);
		if (fabs(k_mesmo - x) < ESPERA_HISTERESE) {
			k = k_mesmo;
			e->pedidos_de_troca = 0;
		} else if (++e->pedidos_de_troca < ESPERA_TROCA_QUADROS) {
			// Um quadro só fora da fase: fica do lado de antes.
			k = k_mesmo;
			*segurou = true;
		} else {
			e->pedidos_de_troca = 0;
			*trocou = true;
		}
	}
	int64_t tique = referencia_ns + (int64_t)llround(k * p);
	e->erro_anterior_ns = tique - alvo_ns;
	e->tem_erro_anterior = true;
	return tique;
}

void espera_esquecer_o_tique(struct espera_da_imagem *e)
{
	e->tem_erro_anterior = false;
	e->pedidos_de_troca = 0;
}

int64_t espera_do_quadro(struct espera_da_imagem *e, uint64_t timestamp_us, bool com_espera, int64_t desejada_ns,
			 bool *na_rampa)
{
	*na_rampa = false;
	// O passo: 10 % do intervalo entre este quadro e o anterior, pelo carimbo do emissor (o da
	// chegada treme com a rede). O primeiro quadro não anda.
	int64_t intervalo = 0;
	if (e->timestamp_anterior_us && timestamp_us > e->timestamp_anterior_us)
		intervalo = (int64_t)(timestamp_us - e->timestamp_anterior_us) * 1000;
	e->timestamp_anterior_us = timestamp_us;
	if (intervalo > ESPERA_INTERVALO_MAXIMO_NS)
		intervalo = ESPERA_INTERVALO_MAXIMO_NS;
	const int64_t passo = (int64_t)(ESPERA_RAMPA * (double)intervalo);

	if (!com_espera) {
		// A descida: da espera do quadro anterior até zero, um passo por quadro. O teto acompanha,
		// para uma volta do mapa subir daqui, e não de onde estava.
		int64_t w = e->ultima_ns - passo;
		if (w < 0)
			w = 0;
		*na_rampa = w > 0;
		e->ultima_ns = w;
		e->teto_ns = w;
		return w;
	}

	int64_t limite = e->teto_ns + passo;
	if (limite > ESPERA_NO_MAXIMO_NS)
		limite = ESPERA_NO_MAXIMO_NS;
	int64_t w = desejada_ns;
	if (w > ESPERA_NO_MAXIMO_NS)
		w = ESPERA_NO_MAXIMO_NS;
	if (w < 0)
		w = 0;
	if (w > limite) {
		w = limite;
		*na_rampa = true;
	}
	// O teto segue a espera com a folga do jitter, e anda no máximo um passo por quadro para cada
	// lado: um quadro atrasado sozinho (espera zero) não o derruba.
	int64_t alvo_do_teto = w + ESPERA_FOLGA_DA_RAMPA_NS;
	if (alvo_do_teto > ESPERA_NO_MAXIMO_NS)
		alvo_do_teto = ESPERA_NO_MAXIMO_NS;
	int64_t t = e->teto_ns;
	if (alvo_do_teto > t + passo)
		t += passo;
	else if (alvo_do_teto < t - passo)
		t -= passo;
	else
		t = alvo_do_teto;
	e->teto_ns = t < 0 ? 0 : t;
	e->ultima_ns = w;
	return w;
}

void espera_medir_decode(struct espera_da_imagem *e, int64_t decode_ns)
{
	if (decode_ns < 0)
		return;
	// Um soluço de 1 s não é a decodificação: o teto da amostra é 50 ms.
	if (decode_ns > 50000000)
		decode_ns = 50000000;
	if (!e->decode_ns) {
		e->decode_ns = decode_ns > 0 ? decode_ns : 1;
		return;
	}
	// A mediana corrente: um passo de 1/32 da estimativa (no mínimo 50 µs) para o lado da amostra,
	// sem passar dela.
	int64_t passo = e->decode_ns / 32;
	if (passo < 50000)
		passo = 50000;
	int64_t d = decode_ns - e->decode_ns;
	if (d > passo)
		d = passo;
	if (d < -passo)
		d = -passo;
	e->decode_ns += d;
	if (e->decode_ns <= 0)
		e->decode_ns = 1;
}

int64_t espera_decode(const struct espera_da_imagem *e)
{
	return e->decode_ns > 0 ? e->decode_ns : ESPERA_DECODE_PADRAO_NS;
}

// -------------------------------------------------------------------------------------------------
// O salto do som
// -------------------------------------------------------------------------------------------------

bool salto_publicar(struct salto_do_som *s, uint64_t carimbo_ns, uint64_t duracao_ns, uint64_t agora_ns,
		    bool *abriu)
{
	*abriu = false;
	const bool no_futuro = carimbo_ns > agora_ns + SALTO_MARGEM_NS;
	if (!s->em_salto && !no_futuro) {
		s->em_salto = true;
		*abriu = true;
	}
	if (s->em_salto) {
		const bool longe = !s->fim_publicado_ns || carimbo_ns >= s->fim_publicado_ns + SALTO_MINIMO_NS;
		if (!(no_futuro && longe))
			return false;
		s->em_salto = false;
	}
	s->fim_publicado_ns = carimbo_ns + duracao_ns;
	return true;
}
