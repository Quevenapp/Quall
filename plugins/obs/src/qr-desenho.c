#include "qr-desenho.h"

#include <stdlib.h>
#include <string.h>

// =================================================================================================
// O desenho do QR do convite (`docs/conexao.md` §10), em C e sem dependência.
//
// **Por que um codificador próprio.** O libobs não traz gerador de QR; o do obs-websocket
// (`qrcodegen`, MIT) mora dentro daquele plugin de interface e não é exportado para os outros
// módulos; e este plugin não depende de Qt nem baixa nada na compilação (`CMakeLists.txt`). O que o
// convite precisa é pouco — modo byte, correção M (§10.2), um texto de ~150 a ~300 bytes —, e o
// algoritmo é o da norma (ISO/IEC 18004): os blocos de Reed-Solomon sobre GF(256), os padrões de
// função, a máscara escolhida pela penalidade. São ~300 linhas, escritas aqui, sob a licença do
// plugin; a prova é ler de volta (`bancada/prova-qr-desenho.c`, com o leitor de QR do macOS).
// =================================================================================================

/// Correção M, versões 1 a 40: bytes de correção por bloco, e quantos blocos (a tabela da norma).
static const int8_t ECC_POR_BLOCO_M[41] = {
	-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
	26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28};
static const int8_t BLOCOS_M[41] = {
	-1, 1,  1,  1,  2,  2,  4,  4,  4,  5,  5,  5,  8,  9,  9,  10, 10, 11, 13, 14, 16,
	17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49};


struct qr {
	int versao, lado;
	uint8_t *m;      // módulos
	uint8_t *funcao; // 1 = padrão de função (a máscara não toca)
};

static void por(struct qr *q, int x, int y, bool escuro)
{
	q->m[y * q->lado + x] = escuro;
	q->funcao[y * q->lado + x] = 1;
}

static bool bit(uint32_t v, int i)
{
	return ((v >> i) & 1) != 0;
}

/// Os módulos de dados de uma versão (o lado ao quadrado, menos os padrões de função).
static int modulos_de_dados(int ver)
{
	int r = (16 * ver + 128) * ver + 64;
	if (ver >= 2) {
		int n = ver / 7 + 2;
		r -= (25 * n - 10) * n - 55;
		if (ver >= 7)
			r -= 36;
	}
	return r;
}

static int bytes_de_dados(int ver)
{
	return modulos_de_dados(ver) / 8 - ECC_POR_BLOCO_M[ver] * BLOCOS_M[ver];
}

// --- Reed-Solomon sobre GF(2^8), polinômio 0x11D --------------------------------------------------
static uint8_t gf_mul(uint8_t x, uint8_t y)
{
	int z = 0;
	for (int i = 7; i >= 0; i--) {
		z = (z << 1) ^ ((z >> 7) * 0x11D);
		z ^= ((y >> i) & 1) * x;
	}
	return (uint8_t)z;
}

static void rs_divisor(int grau, uint8_t *d)
{
	memset(d, 0, (size_t)grau);
	d[grau - 1] = 1;
	uint8_t raiz = 1;
	for (int i = 0; i < grau; i++) {
		for (int j = 0; j < grau; j++) {
			d[j] = gf_mul(d[j], raiz);
			if (j + 1 < grau)
				d[j] ^= d[j + 1];
		}
		raiz = gf_mul(raiz, 0x02);
	}
}

static void rs_resto(const uint8_t *dados, int n, const uint8_t *d, int grau, uint8_t *resto)
{
	memset(resto, 0, (size_t)grau);
	for (int i = 0; i < n; i++) {
		uint8_t fator = dados[i] ^ resto[0];
		memmove(resto, resto + 1, (size_t)grau - 1);
		resto[grau - 1] = 0;
		for (int j = 0; j < grau; j++)
			resto[j] ^= gf_mul(d[j], fator);
	}
}

// --- padrões de função ----------------------------------------------------------------------------
static void localizador(struct qr *q, int x, int y)
{
	for (int dy = -4; dy <= 4; dy++)
		for (int dx = -4; dx <= 4; dx++) {
			int xx = x + dx, yy = y + dy;
			if (xx < 0 || yy < 0 || xx >= q->lado || yy >= q->lado)
				continue;
			int dist = abs(dx) > abs(dy) ? abs(dx) : abs(dy);
			por(q, xx, yy, dist != 2 && dist != 4);
		}
}

static void alinhamento(struct qr *q, int x, int y)
{
	for (int dy = -2; dy <= 2; dy++)
		for (int dx = -2; dx <= 2; dx++) {
			int dist = abs(dx) > abs(dy) ? abs(dx) : abs(dy);
			por(q, x + dx, y + dy, dist != 1);
		}
}

static int posicoes_de_alinhamento(int ver, int *pos)
{
	if (ver == 1)
		return 0;
	int n = ver / 7 + 2;
	int passo = ver == 32 ? 26 : (ver * 4 + n * 2 + 1) / (n * 2 - 2) * 2;
	pos[0] = 6;
	for (int i = n - 1, p = ver * 4 + 10; i >= 1; i--, p -= passo)
		pos[i] = p;
	return n;
}

static void formato(struct qr *q, int mascara)
{
	// Correção M = 0b00 nos bits de formato.
	uint32_t dados = (0u << 3) | (uint32_t)mascara;
	uint32_t resto = dados;
	for (int i = 0; i < 10; i++)
		resto = (resto << 1) ^ ((resto >> 9) * 0x537);
	uint32_t bits = ((dados << 10) | resto) ^ 0x5412;
	int s = q->lado;
	for (int i = 0; i <= 5; i++)
		por(q, 8, i, bit(bits, i));
	por(q, 8, 7, bit(bits, 6));
	por(q, 8, 8, bit(bits, 7));
	por(q, 7, 8, bit(bits, 8));
	for (int i = 9; i < 15; i++)
		por(q, 14 - i, 8, bit(bits, i));
	for (int i = 0; i < 8; i++)
		por(q, s - 1 - i, 8, bit(bits, i));
	for (int i = 8; i < 15; i++)
		por(q, 8, s - 15 + i, bit(bits, i));
	por(q, 8, s - 8, true);
}

static void versao_info(struct qr *q)
{
	if (q->versao < 7)
		return;
	uint32_t resto = (uint32_t)q->versao;
	for (int i = 0; i < 12; i++)
		resto = (resto << 1) ^ ((resto >> 11) * 0x1F25);
	uint32_t bits = ((uint32_t)q->versao << 12) | resto;
	for (int i = 0; i < 18; i++) {
		int a = q->lado - 11 + i % 3, b = i / 3;
		por(q, a, b, bit(bits, i));
		por(q, b, a, bit(bits, i));
	}
}

static void padroes(struct qr *q)
{
	int s = q->lado;
	for (int i = 0; i < s; i++) {
		por(q, 6, i, i % 2 == 0);
		por(q, i, 6, i % 2 == 0);
	}
	localizador(q, 3, 3);
	localizador(q, s - 4, 3);
	localizador(q, 3, s - 4);
	int pos[7];
	int n = posicoes_de_alinhamento(q->versao, pos);
	for (int i = 0; i < n; i++)
		for (int j = 0; j < n; j++)
			if (!((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0)))
				alinhamento(q, pos[i], pos[j]);
	formato(q, 0); // reserva o lugar; o de verdade vem com a máscara escolhida
	versao_info(q);
}

// --- dados ----------------------------------------------------------------------------------------
static void palavras(struct qr *q, const uint8_t *dados, int n)
{
	int i = 0, s = q->lado;
	for (int direita = s - 1; direita >= 1; direita -= 2) {
		if (direita == 6)
			direita = 5;
		for (int v = 0; v < s; v++)
			for (int j = 0; j < 2; j++) {
				int x = direita - j;
				bool sobe = ((direita + 1) & 2) == 0;
				int y = sobe ? s - 1 - v : v;
				if (!q->funcao[y * s + x] && i < n * 8) {
					q->m[y * s + x] = bit(dados[i >> 3], 7 - (i & 7));
					i++;
				}
			}
	}
}

static void mascarar(struct qr *q, int k)
{
	int s = q->lado;
	for (int y = 0; y < s; y++)
		for (int x = 0; x < s; x++) {
			bool inv;
			switch (k) {
			case 0: inv = (x + y) % 2 == 0; break;
			case 1: inv = y % 2 == 0; break;
			case 2: inv = x % 3 == 0; break;
			case 3: inv = (x + y) % 3 == 0; break;
			case 4: inv = (x / 3 + y / 2) % 2 == 0; break;
			case 5: inv = x * y % 2 + x * y % 3 == 0; break;
			case 6: inv = (x * y % 2 + x * y % 3) % 2 == 0; break;
			default: inv = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
			}
			if (!q->funcao[y * s + x] && inv)
				q->m[y * s + x] ^= 1;
		}
}

/// A penalidade da norma: corridas, blocos 2×2, o falso localizador e o equilíbrio de escuros.
static long penalidade(const struct qr *q)
{
	int s = q->lado;
	long p = 0;
	static const uint8_t falso[2][11] = {{1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0}, {0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1}};
	for (int eixo = 0; eixo < 2; eixo++)
		for (int a = 0; a < s; a++) {
			int corrida = 1;
			for (int b = 0; b < s; b++) {
				uint8_t v = eixo ? q->m[b * s + a] : q->m[a * s + b];
				if (b > 0) {
					uint8_t ant = eixo ? q->m[(b - 1) * s + a] : q->m[a * s + b - 1];
					if (v == ant) {
						corrida++;
						if (corrida == 5)
							p += 3;
						else if (corrida > 5)
							p++;
					} else
						corrida = 1;
				}
				if (b + 11 <= s)
					for (int f = 0; f < 2; f++) {
						int k = 0;
						while (k < 11 && (eixo ? q->m[(b + k) * s + a] : q->m[a * s + b + k]) == falso[f][k])
							k++;
						if (k == 11)
							p += 40;
					}
			}
		}
	long escuros = 0;
	for (int y = 0; y < s; y++)
		for (int x = 0; x < s; x++) {
			escuros += q->m[y * s + x];
			if (x + 1 < s && y + 1 < s) {
				uint8_t c = q->m[y * s + x];
				if (c == q->m[y * s + x + 1] && c == q->m[(y + 1) * s + x] && c == q->m[(y + 1) * s + x + 1])
					p += 3;
			}
		}
	long total = (long)s * s;
	long pct = escuros * 100 / total;
	p += 10 * (labs(pct - 50) / 5);
	return p;
}

bool qr_codificar(const uint8_t *texto, size_t n, struct qr_matriz *saida)
{
	int ver = 1;
	for (; ver <= 40; ver++) {
		int bits_da_contagem = ver <= 9 ? 8 : 16;
		if (4 + bits_da_contagem + 8 * (long)n <= 8L * bytes_de_dados(ver))
			break;
	}
	if (ver > 40)
		return false;

	int capacidade = bytes_de_dados(ver);
	uint8_t *dados = calloc((size_t)capacidade, 1);
	if (!dados)
		return false;
	// O fluxo de bits: modo byte (0100), a contagem, os bytes, o terminador e o enchimento.
	int pos = 0;
#define POR_BITS(valor, quantos)                                                                  \
	for (int _i = (quantos)-1; _i >= 0; _i--, pos++)                                          \
		if (((valor) >> _i) & 1)                                                          \
			dados[pos >> 3] |= (uint8_t)(0x80 >> (pos & 7));
	POR_BITS(0x4u, 4);
	POR_BITS((uint32_t)n, ver <= 9 ? 8 : 16);
	for (size_t i = 0; i < n; i++) {
		POR_BITS((uint32_t)texto[i], 8);
	}
	int resta = capacidade * 8 - pos;
	int terminador = resta < 4 ? resta : 4;
	pos += terminador;
	pos = (pos + 7) & ~7;
	for (int k = pos / 8, alterna = 0; k < capacidade; k++, alterna ^= 1)
		dados[k] = alterna ? 0x11 : 0xEC;
#undef POR_BITS

	// Os blocos, cada um com a sua correção, intercalados.
	int blocos = BLOCOS_M[ver], ecc = ECC_POR_BLOCO_M[ver];
	int brutos = modulos_de_dados(ver) / 8;
	int curtos = blocos - brutos % blocos;
	int tam_curto = brutos / blocos;
	uint8_t divisor[30], resto[30];
	rs_divisor(ecc, divisor);
	uint8_t *final = calloc((size_t)brutos, 1);
	uint8_t *blocos_mem = calloc((size_t)blocos * (size_t)(tam_curto + 1), 1);
	if (!final || !blocos_mem) {
		free(dados);
		free(final);
		free(blocos_mem);
		return false;
	}
	for (int b = 0, k = 0; b < blocos; b++) {
		int n_dados = tam_curto - ecc + (b < curtos ? 0 : 1);
		uint8_t *bloco = blocos_mem + (size_t)b * (size_t)(tam_curto + 1);
		memcpy(bloco, dados + k, (size_t)n_dados);
		rs_resto(dados + k, n_dados, divisor, ecc, resto);
		k += n_dados;
		// O bloco curto ganha um byte vazio antes da correção, para os índices casarem na intercalação.
		memcpy(bloco + tam_curto + 1 - ecc, resto, (size_t)ecc);
	}
	for (int i = 0, k = 0; i < tam_curto + 1; i++)
		for (int b = 0; b < blocos; b++)
			if (i != tam_curto - ecc || b >= curtos)
				final[k++] = blocos_mem[(size_t)b * (size_t)(tam_curto + 1) + (size_t)i];
	free(blocos_mem);
	free(dados);

	struct qr q = {.versao = ver, .lado = ver * 4 + 17};
	q.m = calloc((size_t)q.lado * (size_t)q.lado, 1);
	q.funcao = calloc((size_t)q.lado * (size_t)q.lado, 1);
	if (!q.m || !q.funcao) {
		free(final);
		free(q.m);
		free(q.funcao);
		return false;
	}
	padroes(&q);
	palavras(&q, final, brutos);
	free(final);

	int melhor = 0;
	long menor = -1;
	for (int k = 0; k < 8; k++) {
		mascarar(&q, k);
		formato(&q, k);
		long p = penalidade(&q);
		if (menor < 0 || p < menor) {
			menor = p;
			melhor = k;
		}
		mascarar(&q, k); // desfaz (a máscara é um ou-exclusivo)
	}
	mascarar(&q, melhor);
	formato(&q, melhor);

	saida->lado = q.lado;
	memcpy(saida->escuro, q.m, (size_t)q.lado * (size_t)q.lado);
	free(q.m);
	free(q.funcao);
	return true;
}
