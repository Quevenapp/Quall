// Banco de prova de `src/encaixe.c`, sem OBS, sem rede e sem aparelho.
//
// A peça não inclui nada do `libobs`, então compila e roda sozinha:
//
//     cc -O2 -Wall -Wextra -Werror -o /tmp/prova-encaixe \
//        plugins/obs/bancada/prova-encaixe.c plugins/obs/src/encaixe.c && /tmp/prova-encaixe
//
// Os casos são os do controle da troca de tamanho de 21/09 (854×480 ↔ 640×480), onde o Pessoa Exemplo viu
// a fonte mudar de tamanho na cena, e os da revisão do `23eb480`:
//
//  1. o tamanho publicado é o primeiro, e os seguintes pedem encaixe. **Reprova a regra de antes**,
//     que publicava cada quadro no tamanho dele. Esta prova não passa pelo `receptor.c`: ela prova
//     a regra que ele chama;
//  2. os retângulos: 640×480 dentro de 854×480 (faixas dos lados), 854×480 dentro de 640×480
//     (faixas em cima e embaixo), o mesmo tamanho (sem faixa), tudo par;
//  3. a imagem de verdade: as faixas com o preto da faixa limitada (Y=16, UV=128), e a imagem com
//     os valores dela, no lugar certo, nos dois sentidos. Na escala 1 (o controle descendo), a
//     imagem sai **byte a byte** igual à origem;
//  4. **nenhuma coluna da origem some na redução** (M2): uma linha vertical de um pixel em cada
//     uma das 854 colunas, reduzida a 640, aparece no destino. **Reprova o vizinho mais próximo** da
//     primeira versão, que perdia 214 das 854 colunas;
//  5. **o custo por quadro** (M1): o melhor de 50 voltas em cada caso da revisão. Só mede; o número
//     que importa é o do Dell (MSVC), e esta prova diz o do Mac.

#include "../src/encaixe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int falhas;

static void confere(const char *caso, long obtido, long esperado)
{
	if (obtido != esperado) {
		printf("FALHOU %s\n  esperado: %ld\n  obtido  : %ld\n", caso, esperado, obtido);
		falhas++;
	} else {
		printf("ok %s = %ld\n", caso, obtido);
	}
}

static void confere_ret(const char *caso, uint32_t sl, uint32_t sa, uint32_t il, uint32_t ia, uint32_t ex,
			uint32_t ey, uint32_t el, uint32_t ea)
{
	uint32_t x, y, l, a;
	encaixe_retangulo(sl, sa, il, ia, &x, &y, &l, &a);
	if (x != ex || y != ey || l != el || a != ea) {
		printf("FALHOU %s\n  esperado: (%u, %u, %u, %u)\n  obtido  : (%u, %u, %u, %u)\n", caso, ex, ey, el, ea, x,
		       y, l, a);
		falhas++;
	} else {
		printf("ok %s = (%u, %u, %u, %u)\n", caso, x, y, l, a);
	}
}

struct nv12 {
	uint32_t l, a, passo;
	uint8_t *y, *uv;
};

static struct nv12 novo(uint32_t l, uint32_t a, uint32_t folga)
{
	struct nv12 q = {l, a, l + folga, NULL, NULL};
	q.y = malloc((size_t)q.passo * a);
	q.uv = malloc((size_t)q.passo * (a / 2));
	return q;
}

static void soltar(struct nv12 *q)
{
	free(q->y), free(q->uv);
}

static void encaixar(struct encaixe *e, struct nv12 *dst, const struct nv12 *src)
{
	if (!encaixe_preparar(e, dst->l, dst->a, src->l, src->a)) {
		printf("FALHOU encaixe_preparar %ux%u -> %ux%u\n", src->l, src->a, dst->l, dst->a);
		falhas++;
		return;
	}
	encaixe_nv12(e, dst->y, dst->passo, dst->uv, dst->passo, src->y, src->passo, src->uv, src->passo);
}

static double agora_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}

static void medir(const char *caso, uint32_t pl, uint32_t pa, uint32_t il, uint32_t ia)
{
	struct nv12 src = novo(il, ia, 0), dst = novo(pl, pa, 0);
	for (size_t i = 0; i < (size_t)il * ia; i++)
		src.y[i] = (uint8_t)(i * 7);
	memset(src.uv, 128, (size_t)il * (ia / 2));
	struct encaixe e = {0};
	encaixe_preparar(&e, pl, pa, il, ia);
	double melhor = 1e9;
	for (int volta = 0; volta < 50; volta++) {
		double t0 = agora_ms();
		encaixe_nv12(&e, dst.y, dst.passo, dst.uv, dst.passo, src.y, src.passo, src.uv, src.passo);
		double t = agora_ms() - t0;
		if (t < melhor)
			melhor = t;
	}
	printf("custo %s: publicado %ux%u, imagem %ux%u (%s): %.3f ms por quadro\n", caso, pl, pa, il, ia,
	       e.direto ? "cópia de linha" : "bilinear", melhor);
	encaixe_liberar(&e);
	soltar(&src), soltar(&dst);
}

int main(void)
{
	// --- 1. o tamanho publicado -------------------------------------------------------------
	uint32_t pl = 0, pa = 0;
	confere("o primeiro quadro (854x480) não encaixa", encaixe_publicar_em(&pl, &pa, 854, 480), 0);
	confere("e fixa a largura publicada", pl, 854);
	confere("o 640x480 do meio encaixa", encaixe_publicar_em(&pl, &pa, 640, 480), 1);
	confere("e a largura publicada fica a primeira", pl, 854);
	confere("a volta ao 854x480 não encaixa", encaixe_publicar_em(&pl, &pa, 854, 480), 0);

	// --- 2. os retângulos ----------------------------------------------------------------------
	confere_ret("640x480 dentro de 854x480", 854, 480, 640, 480, 106, 0, 640, 480);
	confere_ret("854x480 dentro de 640x480", 640, 480, 854, 480, 0, 60, 640, 360);
	confere_ret("o mesmo tamanho", 854, 480, 854, 480, 0, 0, 854, 480);
	confere_ret("1920x1080 dentro de 1280x720", 1280, 720, 1920, 1080, 0, 0, 1280, 720);

	struct encaixe e = {0};

	// --- 3a. descendo: 640x480 (Y=200, U=90, V=170) dentro de 854x480 -------------------------
	struct nv12 src = novo(640, 480, 64), dst = novo(854, 480, 10);
	for (uint32_t j = 0; j < src.a; j++)
		for (uint32_t i = 0; i < src.l; i++)
			src.y[(size_t)j * src.passo + i] = (uint8_t)(100 + (i + j) % 100);
	for (uint32_t j = 0; j < src.a / 2; j++)
		for (uint32_t i = 0; i < src.l / 2; i++) {
			src.uv[(size_t)j * src.passo + i * 2] = 90;
			src.uv[(size_t)j * src.passo + i * 2 + 1] = 170;
		}
	encaixar(&e, &dst, &src);
	confere("descendo é cópia de linha (escala 1)", e.direto, 1);
	confere("faixa esquerda, Y", dst.y[10 * dst.passo + 0], 16);
	confere("última coluna da faixa esquerda, Y", dst.y[10 * dst.passo + 105], 16);
	confere("faixa direita, Y", dst.y[479 * dst.passo + 746], 16);
	confere("faixa esquerda, U", dst.uv[0], 128);
	confere("faixa esquerda, V", dst.uv[1], 128);
	confere("imagem, U", dst.uv[5 * dst.passo + 106], 90);
	confere("imagem, V", dst.uv[5 * dst.passo + 107], 170);
	confere("faixa direita, U", dst.uv[5 * dst.passo + 746], 128);
	int iguais = 1;
	for (uint32_t j = 0; j < 480 && iguais; j++)
		iguais = memcmp(dst.y + (size_t)j * dst.passo + 106, src.y + (size_t)j * src.passo, 640) == 0;
	confere("a imagem é a origem byte a byte (luma)", iguais, 1);
	soltar(&src), soltar(&dst);

	// --- 3b. subindo: 854x480 com uma rampa vertical dentro de 640x480 ------------------------
	struct nv12 alto = novo(854, 480, 0), baixo = novo(640, 480, 0);
	for (uint32_t j = 0; j < alto.a; j++)
		memset(alto.y + (size_t)j * alto.passo, (int)(20 + j / 3), alto.l);
	memset(alto.uv, 128, (size_t)alto.passo * (alto.a / 2));
	encaixar(&e, &baixo, &alto);
	confere("subindo é bilinear", e.direto, 0);
	confere("faixa de cima, Y", baixo.y[59 * baixo.passo + 320], 16);
	confere("primeira linha da imagem perto da primeira da origem", baixo.y[60 * baixo.passo + 320] <= 21, 1);
	confere("última linha da imagem perto da última da origem", baixo.y[419 * baixo.passo + 320] >= 20 + 479 / 3 - 1, 1);
	confere("faixa de baixo, Y", baixo.y[420 * baixo.passo + 320], 16);
	confere("a imagem vai de borda a borda", baixo.y[200 * baixo.passo + 639] != 16, 1);
	int monotona = 1;
	for (uint32_t j = 61; j < 420; j++)
		if (baixo.y[j * baixo.passo + 320] < baixo.y[(j - 1) * baixo.passo + 320])
			monotona = 0;
	confere("a rampa reduzida continua subindo linha a linha", monotona, 1);

	// --- 4. nenhuma coluna some na redução (M2) --------------------------------------------------
	int perdidas = 0;
	for (uint32_t c = 0; c < 854; c++) {
		memset(alto.y, 16, (size_t)alto.passo * alto.a);
		for (uint32_t j = 0; j < alto.a; j++)
			alto.y[(size_t)j * alto.passo + c] = 235;
		encaixar(&e, &baixo, &alto);
		int viu = 0;
		for (uint32_t i = 0; i < 640 && !viu; i++)
			viu = baixo.y[240 * baixo.passo + i] > 16 + 20;
		if (!viu)
			perdidas++;
	}
	confere("colunas da origem (854) que somem na redução a 640", perdidas, 0);
	soltar(&alto), soltar(&baixo);
	encaixe_liberar(&e);

	// --- 5. o custo por quadro (M1) -------------------------------------------------------------
	medir("controle, descendo", 854, 480, 640, 480);
	medir("controle, subindo", 640, 480, 854, 480);
	medir("câmera 4:3 numa sessão 16:9 1080p", 1920, 1080, 1440, 1080);
	medir("1080p numa sessão 720p", 1280, 720, 1920, 1080);
	medir("4K 4:3 numa sessão 4K", 3840, 2160, 2880, 2160);

	printf("\n%s: %d falha(s)\n", falhas ? "REPROVADO" : "APROVADO", falhas);
	return falhas ? 1 : 0;
}
