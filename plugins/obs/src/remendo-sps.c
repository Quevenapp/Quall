// O remendo da `bitstream_restriction` no SPS Baseline. Ver `remendo-sps.h`.
#include "remendo-sps.h"

#include <stdlib.h>
#include <string.h>

// O SPS é pequeno (o do VideoToolbox tem 10 bytes; o do NVENC, 22); um maior que isto não é remendado.
#define SPS_MAXIMO 256

// -------------------------------------------------------------------------------------------------
// Bits
// -------------------------------------------------------------------------------------------------

struct leitor {
	const uint8_t *d;
	size_t n;   // bytes
	size_t pos; // bits
	bool ok;
};

static uint32_t ler(struct leitor *b, int bits)
{
	uint32_t v = 0;
	for (int i = 0; i < bits; i++) {
		if (b->pos / 8 >= b->n) {
			b->ok = false;
			return 0;
		}
		v = (v << 1) | ((b->d[b->pos / 8] >> (7 - (b->pos % 8))) & 1);
		b->pos++;
	}
	return v;
}

static uint32_t ler_ue(struct leitor *b)
{
	int zeros = 0;
	while (b->ok && ler(b, 1) == 0) {
		if (++zeros > 31) {
			b->ok = false;
			return 0;
		}
	}
	if (!b->ok)
		return 0;
	if (zeros == 0)
		return 0;
	return ((1u << zeros) - 1) + ler(b, zeros);
}

static void ler_se(struct leitor *b)
{
	(void)ler_ue(b);
}

struct escritor {
	uint8_t d[SPS_MAXIMO + 32];
	size_t bits;
	bool ok;
};

static void escrever_bit(struct escritor *e, int bit)
{
	if (e->bits / 8 >= sizeof(e->d)) {
		e->ok = false;
		return;
	}
	if (e->bits % 8 == 0)
		e->d[e->bits / 8] = 0;
	if (bit)
		e->d[e->bits / 8] |= (uint8_t)(0x80 >> (e->bits % 8));
	e->bits++;
}

static void escrever(struct escritor *e, uint32_t v, int bits)
{
	for (int k = bits - 1; k >= 0; k--)
		escrever_bit(e, (int)((v >> k) & 1));
}

static void escrever_ue(struct escritor *e, uint32_t v)
{
	uint64_t x = (uint64_t)v + 1;
	int n = 0;
	for (uint64_t t = x; t; t >>= 1)
		n++;
	for (int i = 0; i < n - 1; i++)
		escrever_bit(e, 0);
	for (int k = n - 1; k >= 0; k--)
		escrever_bit(e, (int)((x >> k) & 1));
}

// -------------------------------------------------------------------------------------------------
// O SPS Baseline, com as posições que o remendo precisa
// -------------------------------------------------------------------------------------------------

struct sps {
	uint8_t perfil, restricoes, nivel;
	uint32_t largura_mbs, altura_mapa, frame_mbs_only, recorte[4];
	uint32_t max_num_ref_frames;
	bool tem_vui, tem_sinal, faixa_cheia, tem_cor;
	uint8_t cor[3];
	bool tem_restricao;
	uint32_t reorder, dpb;
	size_t bit_do_vui, bit_da_restricao; // posições no RBSP
	bool achou_bit_da_restricao;
};

static size_t desescapar(const uint8_t *in, size_t n, uint8_t *out, size_t cap)
{
	size_t k = 0;
	int zeros = 0;
	for (size_t i = 0; i < n && k < cap; i++) {
		if (zeros >= 2 && in[i] == 3) {
			zeros = 0;
			continue;
		}
		zeros = in[i] == 0 ? zeros + 1 : 0;
		out[k++] = in[i];
	}
	return k;
}

static size_t escapar(const uint8_t *in, size_t n, uint8_t *out, size_t cap)
{
	size_t k = 0;
	int zeros = 0;
	for (size_t i = 0; i < n; i++) {
		if (zeros >= 2 && in[i] <= 3) {
			if (k >= cap)
				return 0;
			out[k++] = 3;
			zeros = 0;
		}
		if (k >= cap)
			return 0;
		out[k++] = in[i];
		zeros = in[i] == 0 ? zeros + 1 : 0;
	}
	return k;
}

static void pular_hrd(struct leitor *b)
{
	uint32_t cpb = ler_ue(b) + 1;
	ler(b, 4);
	ler(b, 4);
	for (uint32_t i = 0; i < cpb && b->ok; i++) {
		ler_ue(b);
		ler_ue(b);
		ler(b, 1);
	}
	ler(b, 5);
	ler(b, 5);
	ler(b, 5);
	ler(b, 5);
}

/// Lê um SPS **Baseline** (RBSP, sem o byte de cabeçalho). `false` se não for Baseline ou não se ler.
static bool analisar(const uint8_t *rbsp, size_t n, struct sps *s)
{
	memset(s, 0, sizeof(*s));
	struct leitor b = {rbsp, n, 0, true};
	s->perfil = (uint8_t)ler(&b, 8);
	s->restricoes = (uint8_t)ler(&b, 8);
	s->nivel = (uint8_t)ler(&b, 8);
	if (!b.ok || s->perfil != 66)
		return false;
	ler_ue(&b); // seq_parameter_set_id
	ler_ue(&b); // log2_max_frame_num_minus4
	uint32_t poc = ler_ue(&b);
	if (poc == 0) {
		ler_ue(&b);
	} else if (poc == 1) {
		ler(&b, 1);
		ler_se(&b);
		ler_se(&b);
		uint32_t ciclo = ler_ue(&b);
		for (uint32_t i = 0; i < ciclo && b.ok; i++)
			ler_se(&b);
	}
	s->max_num_ref_frames = ler_ue(&b);
	ler(&b, 1); // gaps_in_frame_num_value_allowed_flag
	s->largura_mbs = ler_ue(&b);
	s->altura_mapa = ler_ue(&b);
	s->frame_mbs_only = ler(&b, 1);
	if (!s->frame_mbs_only)
		ler(&b, 1);
	ler(&b, 1); // direct_8x8_inference_flag
	if (ler(&b, 1)) {
		for (int i = 0; i < 4; i++)
			s->recorte[i] = ler_ue(&b);
	}
	s->bit_do_vui = b.pos;
	s->tem_vui = ler(&b, 1) == 1;
	if (!b.ok)
		return false;
	if (!s->tem_vui)
		return true;
	if (ler(&b, 1) && ler(&b, 8) == 255) { // aspect_ratio_info_present_flag, idc
		ler(&b, 16);
		ler(&b, 16);
	}
	if (ler(&b, 1)) // overscan_info_present_flag
		ler(&b, 1);
	if (ler(&b, 1)) { // video_signal_type_present_flag
		s->tem_sinal = true;
		ler(&b, 3);
		s->faixa_cheia = ler(&b, 1) == 1;
		if (ler(&b, 1)) {
			s->tem_cor = true;
			for (int i = 0; i < 3; i++)
				s->cor[i] = (uint8_t)ler(&b, 8);
		}
	}
	if (ler(&b, 1)) { // chroma_loc_info_present_flag
		ler_ue(&b);
		ler_ue(&b);
	}
	if (ler(&b, 1)) { // timing_info_present_flag
		ler(&b, 32);
		ler(&b, 32);
		ler(&b, 1);
	}
	bool nal_hrd = ler(&b, 1) == 1;
	if (nal_hrd)
		pular_hrd(&b);
	bool vcl_hrd = ler(&b, 1) == 1;
	if (vcl_hrd)
		pular_hrd(&b);
	if (nal_hrd || vcl_hrd)
		ler(&b, 1); // low_delay_hrd_flag
	ler(&b, 1);         // pic_struct_present_flag
	s->bit_da_restricao = b.pos;
	s->achou_bit_da_restricao = b.ok;
	if (ler(&b, 1)) {
		s->tem_restricao = true;
		ler(&b, 1);
		ler_ue(&b);
		ler_ue(&b);
		ler_ue(&b);
		ler_ue(&b);
		s->reorder = ler_ue(&b);
		s->dpb = ler_ue(&b);
	}
	return b.ok;
}

/// Reescreve uma NAL de SPS (com o cabeçalho). Devolve o tamanho novo em `out`, ou 0 se não mexeu.
static size_t reescrever(const uint8_t *nal, size_t n, uint8_t *out, size_t cap)
{
	if (n < 4 || n > SPS_MAXIMO || (nal[0] & 0x1f) != 7 || nal[1] != 66)
		return 0;
	uint8_t rbsp[SPS_MAXIMO];
	size_t nr = desescapar(nal + 1, n - 1, rbsp, sizeof(rbsp));
	struct sps a;
	if (!analisar(rbsp, nr, &a) || a.tem_restricao)
		return 0;
	if (a.tem_vui && !a.achou_bit_da_restricao)
		return 0;

	struct escritor e;
	memset(&e, 0, sizeof(e));
	e.ok = true;
	size_t ate = a.tem_vui ? a.bit_da_restricao : a.bit_do_vui;
	for (size_t p = 0; p < ate; p++)
		escrever_bit(&e, (rbsp[p / 8] >> (7 - (p % 8))) & 1);
	if (!a.tem_vui) {
		escrever(&e, 1, 1); // vui_parameters_present_flag
		escrever(&e, 0, 1); // aspect_ratio_info_present_flag
		escrever(&e, 0, 1); // overscan_info_present_flag
		escrever(&e, 0, 1); // video_signal_type_present_flag: o receptor não sabe, e não inventa
		escrever(&e, 0, 1); // chroma_loc_info_present_flag
		escrever(&e, 0, 1); // timing_info_present_flag
		escrever(&e, 0, 1); // nal_hrd_parameters_present_flag
		escrever(&e, 0, 1); // vcl_hrd_parameters_present_flag
		escrever(&e, 0, 1); // pic_struct_present_flag
	}
	escrever(&e, 1, 1);                    // bitstream_restriction_flag
	escrever(&e, 1, 1);                    // motion_vectors_over_pic_boundaries_flag
	escrever_ue(&e, 0);                    // max_bytes_per_pic_denom
	escrever_ue(&e, 0);                    // max_bits_per_mb_denom
	escrever_ue(&e, 16);                   // log2_max_mv_length_horizontal
	escrever_ue(&e, 16);                   // log2_max_mv_length_vertical
	escrever_ue(&e, 0);                    // max_num_reorder_frames  <-- o conserto
	escrever_ue(&e, a.max_num_ref_frames); // max_dec_frame_buffering
	escrever_bit(&e, 1);                   // rbsp_stop_one_bit
	while (e.bits % 8)
		escrever_bit(&e, 0);
	if (!e.ok || cap < 2)
		return 0;

	out[0] = nal[0];
	size_t ne = escapar(e.d, e.bits / 8, out + 1, cap - 1);
	if (!ne)
		return 0;

	// A releitura: um SPS errado não degrada a imagem, apaga.
	uint8_t rbsp2[SPS_MAXIMO + 32];
	size_t nr2 = desescapar(out + 1, ne, rbsp2, sizeof(rbsp2));
	struct sps d;
	if (!analisar(rbsp2, nr2, &d))
		return 0;
	bool confere = d.perfil == a.perfil && d.restricoes == a.restricoes && d.nivel == a.nivel &&
		       d.largura_mbs == a.largura_mbs && d.altura_mapa == a.altura_mapa &&
		       d.frame_mbs_only == a.frame_mbs_only &&
		       memcmp(d.recorte, a.recorte, sizeof(a.recorte)) == 0 &&
		       d.tem_sinal == a.tem_sinal && d.faixa_cheia == a.faixa_cheia &&
		       d.tem_cor == a.tem_cor && memcmp(d.cor, a.cor, sizeof(a.cor)) == 0 &&
		       d.tem_restricao && d.reorder == 0 && d.dpb == a.max_num_ref_frames;
	return confere ? ne + 1 : 0;
}

bool remendo_sps_restricao(const uint8_t *q, size_t n, uint8_t **saida, size_t *n_saida)
{
	*saida = NULL;
	*n_saida = 0;
	// Acha o primeiro SPS no prefixo não-VCL: (onde começa o corpo, onde acaba).
	size_t i = 0, sps_ini = 0, sps_fim = 0;
	bool aberto_e_sps = false, achou = false;
	while (i + 2 < n) {
		size_t tam;
		if (q[i] == 0 && q[i + 1] == 0 && q[i + 2] == 1)
			tam = 3;
		else if (i + 3 < n && q[i] == 0 && q[i + 1] == 0 && q[i + 2] == 0 && q[i + 3] == 1)
			tam = 4;
		else {
			i++;
			continue;
		}
		if (aberto_e_sps) {
			sps_fim = i;
			achou = true;
			break;
		}
		size_t corpo = i + tam;
		if (corpo >= n)
			break;
		uint8_t tipo = q[corpo] & 0x1f;
		if (tipo < 6 || tipo > 9)
			break; // a primeira fatia encerra a busca
		if (tipo == 7) {
			aberto_e_sps = true;
			sps_ini = corpo;
		}
		i = corpo;
	}
	if (aberto_e_sps && !achou) {
		sps_fim = n;
		achou = true;
	}
	if (!achou)
		return false;

	uint8_t novo[SPS_MAXIMO + 64];
	size_t nn = reescrever(q + sps_ini, sps_fim - sps_ini, novo, sizeof(novo));
	if (!nn)
		return false;
	size_t total = n - (sps_fim - sps_ini) + nn;
	uint8_t *o = malloc(total);
	if (!o)
		return false;
	memcpy(o, q, sps_ini);
	memcpy(o + sps_ini, novo, nn);
	memcpy(o + sps_ini + nn, q + sps_fim, n - sps_fim);
	*saida = o;
	*n_saida = total;
	return true;
}
