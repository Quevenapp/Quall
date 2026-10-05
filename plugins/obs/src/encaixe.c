// Ver `encaixe.h`.

#include "encaixe.h"

#include <stdlib.h>
#include <string.h>

static uint32_t par_mais_proximo(double x)
{
	double metade = x / 2.0;
	uint32_t n = (uint32_t)(metade + 0.5);
	if (n < 1)
		n = 1;
	return n * 2;
}

bool encaixe_publicar_em(uint32_t *pub_l, uint32_t *pub_a, uint32_t img_l, uint32_t img_a)
{
	if (!*pub_l || !*pub_a) {
		*pub_l = img_l;
		*pub_a = img_a;
		return false;
	}
	return img_l != *pub_l || img_a != *pub_a;
}

void encaixe_retangulo(uint32_t saida_l, uint32_t saida_a, uint32_t img_l, uint32_t img_a, uint32_t *x,
		       uint32_t *y, uint32_t *l, uint32_t *a)
{
	double sl = (double)saida_l, sa = (double)saida_a;
	double el = (double)(img_l ? img_l : 1), ea = (double)(img_a ? img_a : 1);
	double escala = sl / el < sa / ea ? sl / el : sa / ea;
	uint32_t ll = par_mais_proximo(el * escala);
	uint32_t aa = par_mais_proximo(ea * escala);
	if (ll > saida_l)
		ll = saida_l & ~1u;
	if (aa > saida_a)
		aa = saida_a & ~1u;
	*l = ll;
	*a = aa;
	*x = ((saida_l - ll) / 2) & ~1u;
	*y = ((saida_a - aa) / 2) & ~1u;
}

void encaixe_liberar(struct encaixe *e)
{
	free(e->col_y), free(e->lin_y), free(e->col_c), free(e->lin_c);
	free(e->peso_col_y), free(e->peso_lin_y), free(e->peso_col_c), free(e->peso_lin_c);
	memset(e, 0, sizeof(*e));
}

/// A tabela de um eixo: para cada uma das `n` posições de destino, a origem (a amostra da esquerda
/// ou de cima) e o peso da seguinte, em 1/256, pelo centro do pixel. A borda repete a última amostra.
static void eixo(uint32_t n, uint32_t origem, uint32_t *pos, uint16_t *peso)
{
	for (uint32_t i = 0; i < n; i++) {
		// centro do destino, em coordenadas da origem, em 1/256: ((i + 0,5) · origem / n − 0,5).
		int64_t c = (((int64_t)i * 2 + 1) * origem * 256) / ((int64_t)n * 2) - 128;
		if (c < 0)
			c = 0;
		uint32_t p = (uint32_t)(c >> 8);
		uint32_t w = (uint32_t)(c & 255);
		if (p >= origem - 1) {
			p = origem - 1;
			w = 0;
		}
		pos[i] = p;
		peso[i] = (uint16_t)w;
	}
}

bool encaixe_preparar(struct encaixe *e, uint32_t dst_l, uint32_t dst_a, uint32_t src_l, uint32_t src_a)
{
	if (e->col_y && e->dst_l == dst_l && e->dst_a == dst_a && e->src_l == src_l && e->src_a == src_a)
		return true;
	encaixe_liberar(e);
	e->dst_l = dst_l, e->dst_a = dst_a, e->src_l = src_l, e->src_a = src_a;
	encaixe_retangulo(dst_l, dst_a, src_l, src_a, &e->x0, &e->y0, &e->l, &e->a);
	e->direto = e->l == src_l && e->a == src_a;
	uint32_t cl = e->l / 2, ca = e->a / 2;
	e->col_y = malloc(sizeof(uint32_t) * (e->l + 1));
	e->lin_y = malloc(sizeof(uint32_t) * (e->a + 1));
	e->col_c = malloc(sizeof(uint32_t) * (cl + 1));
	e->lin_c = malloc(sizeof(uint32_t) * (ca + 1));
	e->peso_col_y = malloc(sizeof(uint16_t) * (e->l + 1));
	e->peso_lin_y = malloc(sizeof(uint16_t) * (e->a + 1));
	e->peso_col_c = malloc(sizeof(uint16_t) * (cl + 1));
	e->peso_lin_c = malloc(sizeof(uint16_t) * (ca + 1));
	if (!e->col_y || !e->lin_y || !e->col_c || !e->lin_c || !e->peso_col_y || !e->peso_lin_y ||
	    !e->peso_col_c || !e->peso_lin_c || !src_l || !src_a) {
		encaixe_liberar(e);
		return false;
	}
	eixo(e->l, src_l, e->col_y, e->peso_col_y);
	eixo(e->a, src_a, e->lin_y, e->peso_lin_y);
	eixo(cl, src_l / 2 ? src_l / 2 : 1, e->col_c, e->peso_col_c);
	eixo(ca, src_a / 2 ? src_a / 2 : 1, e->lin_c, e->peso_lin_c);
	return true;
}

/// Pinta de `valor` (ou do par U/V, no croma) as faixas em volta do retângulo, e só elas.
static void faixas(uint8_t *plano, uint32_t passo, uint32_t larg_bytes, uint32_t alt, uint32_t x0_bytes,
		   uint32_t y0, uint32_t l_bytes, uint32_t a, const uint8_t *padrao, uint32_t tam_padrao)
{
	for (uint32_t j = 0; j < alt; j++) {
		uint8_t *linha = plano + (size_t)j * passo;
		if (j < y0 || j >= y0 + a) {
			for (uint32_t i = 0; i < larg_bytes; i += tam_padrao)
				memcpy(linha + i, padrao, tam_padrao);
		} else {
			for (uint32_t i = 0; i < x0_bytes; i += tam_padrao)
				memcpy(linha + i, padrao, tam_padrao);
			for (uint32_t i = x0_bytes + l_bytes; i < larg_bytes; i += tam_padrao)
				memcpy(linha + i, padrao, tam_padrao);
		}
	}
}

void encaixe_nv12(const struct encaixe *e, uint8_t *dst_y, uint32_t dst_passo_y, uint8_t *dst_uv,
		  uint32_t dst_passo_uv, const uint8_t *src_y, uint32_t src_passo_y, const uint8_t *src_uv,
		  uint32_t src_passo_uv)
{
	static const uint8_t preto_y = 16, preto_uv[2] = {128, 128};
	faixas(dst_y, dst_passo_y, e->dst_l, e->dst_a, e->x0, e->y0, e->l, e->a, &preto_y, 1);
	faixas(dst_uv, dst_passo_uv, e->dst_l & ~1u, e->dst_a / 2, e->x0, e->y0 / 2, e->l, e->a / 2, preto_uv, 2);

	if (e->direto) {
		// A escala 1: o caso do controle descendo (640×480 dentro de 854×480). Cópia de linha.
		for (uint32_t j = 0; j < e->a; j++)
			memcpy(dst_y + (size_t)(e->y0 + j) * dst_passo_y + e->x0, src_y + (size_t)j * src_passo_y, e->l);
		for (uint32_t j = 0; j < e->a / 2; j++)
			memcpy(dst_uv + (size_t)(e->y0 / 2 + j) * dst_passo_uv + e->x0, src_uv + (size_t)j * src_passo_uv,
			       e->l);
		return;
	}

	// Bilinear, com as tabelas: nenhuma divisão no laço.
	for (uint32_t j = 0; j < e->a; j++) {
		const uint8_t *l0 = src_y + (size_t)e->lin_y[j] * src_passo_y;
		const uint8_t *l1 = e->lin_y[j] + 1 < e->src_a ? l0 + src_passo_y : l0;
		uint32_t wy = e->peso_lin_y[j];
		uint8_t *d = dst_y + (size_t)(e->y0 + j) * dst_passo_y + e->x0;
		for (uint32_t i = 0; i < e->l; i++) {
			uint32_t p = e->col_y[i], wx = e->peso_col_y[i];
			uint32_t q = p + 1 < e->src_l ? p + 1 : p;
			uint32_t cima = l0[p] * (256 - wx) + l0[q] * wx;
			uint32_t baixo = l1[p] * (256 - wx) + l1[q] * wx;
			d[i] = (uint8_t)((cima * (256 - wy) + baixo * wy + 32768) >> 16);
		}
	}
	uint32_t scl = e->src_l / 2, sca = e->src_a / 2;
	for (uint32_t j = 0; j < e->a / 2; j++) {
		const uint8_t *l0 = src_uv + (size_t)e->lin_c[j] * src_passo_uv;
		const uint8_t *l1 = e->lin_c[j] + 1 < sca ? l0 + src_passo_uv : l0;
		uint32_t wy = e->peso_lin_c[j];
		uint8_t *d = dst_uv + (size_t)(e->y0 / 2 + j) * dst_passo_uv + e->x0;
		for (uint32_t i = 0; i < e->l / 2; i++) {
			uint32_t p = e->col_c[i], wx = e->peso_col_c[i];
			uint32_t q = p + 1 < scl ? p + 1 : p;
			for (uint32_t k = 0; k < 2; k++) {
				uint32_t cima = l0[p * 2 + k] * (256 - wx) + l0[q * 2 + k] * wx;
				uint32_t baixo = l1[p * 2 + k] * (256 - wx) + l1[q * 2 + k] * wx;
				d[i * 2 + k] = (uint8_t)((cima * (256 - wy) + baixo * wy + 32768) >> 16);
			}
		}
	}
}
