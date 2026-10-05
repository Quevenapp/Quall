#pragma once
// **O primeiro tamanho da fonte fica, e os seguintes entram encaixados** (decisão do Pessoa Exemplo de
// 21/09/2026, depois do controle da troca de tamanho).
//
// Quando o emissor troca o tamanho da imagem no meio da sessão (a câmera do Windows em 16:9 ↔ 4:3),
// o plugin publicava cada quadro no tamanho dele, e a fonte mudava de tamanho na cena. No controle
// de 21/09 o Pessoa Exemplo viu isso acontecer. Um item de cena com `OBS_BOUNDS_NONE` guarda escala, não
// tamanho, e o enquadramento de quem transmite pula a cada troca; o §8.56 da bancada já tinha
// recusado trocar a geometria no ar por esse motivo.
//
// A decisão: a fonte publica sempre o **primeiro** tamanho que ela publicou. Vale **por fonte**, e
// não por sessão de rede: uma reconexão com outro tamanho continua encaixada no tamanho que a fonte
// já publicava (decisão do coordenador na revisão do `23eb480`, M3). O tamanho só volta a valer de
// novo quando a pessoa muda com quem a fonte fala (endereço ou PIN) ou a fonte é recriada. Uma
// imagem de outro tamanho entra no maior retângulo com o aspecto dela, centrado, com faixas pretas
// de faixa limitada (Y=16, UV=128).
//
// **A imagem é escalada por bilinear, com tabelas** (a revisão do `23eb480`, M1 e M2): a primeira
// versão fazia uma divisão de 64 bits por pixel e reduzia por vizinho mais próximo, que jogava fora
// um quarto das colunas e das linhas na subida do controle. Agora as posições e os pesos de cada
// coluna e de cada linha são calculados uma vez por troca de tamanho (`encaixe_preparar`), a escala
// 1 é cópia direta de linha (o caso do controle descendo: 640×480 dentro de 854×480), e o preto é
// pintado só nas faixas.
//
// Sem `libobs`: aritmética e cópia de bytes, testadas e medidas em `bancada/prova-encaixe.c`. O
// `video_scaler` do libobs (swscale) também serviria; ficou este porque a prova e a medida rodam
// sem o OBS, e o custo medido cabe folgado no quadro (ver a prova).

#include <stdbool.h>
#include <stdint.h>

/// **O tamanho que a fonte publica.** `*pub_l` e `*pub_a` nascem 0 e guardam o primeiro tamanho
/// que chegar. Devolve `true` quando a imagem `img_l`×`img_a` não é desse tamanho e precisa entrar
/// encaixada.
bool encaixe_publicar_em(uint32_t *pub_l, uint32_t *pub_a, uint32_t img_l, uint32_t img_a);

/// O maior retângulo com o aspecto de `img_l`×`img_a` dentro de `saida_l`×`saida_a`, centrado, com
/// posição e tamanho pares (o NV12 pede). A mesma conta de `regras_da_camera::encaixe` no emissor
/// do Windows.
void encaixe_retangulo(uint32_t saida_l, uint32_t saida_a, uint32_t img_l, uint32_t img_a, uint32_t *x,
		       uint32_t *y, uint32_t *l, uint32_t *a);

/// As tabelas de uma troca: de `src_l`×`src_a` para o retângulo dentro de `dst_l`×`dst_a`.
struct encaixe {
	uint32_t dst_l, dst_a, src_l, src_a;
	uint32_t x0, y0, l, a;
	bool direto; // a escala é 1: cópia de linha
	// Por coluna e por linha de destino: a origem e o peso da vizinha (0..256), luma e croma.
	uint32_t *col_y, *lin_y, *col_c, *lin_c;
	uint16_t *peso_col_y, *peso_lin_y, *peso_col_c, *peso_lin_c;
};

/// Monta (ou mantém, se o par de tamanhos é o mesmo) as tabelas de `e`. `false` se faltou memória.
bool encaixe_preparar(struct encaixe *e, uint32_t dst_l, uint32_t dst_a, uint32_t src_l, uint32_t src_a);
/// Solta as tabelas.
void encaixe_liberar(struct encaixe *e);

/// Põe `src` (NV12, o tamanho de `e`) encaixado em `dst` (NV12, o tamanho de `e`), com as faixas
/// pretas. Os passos são em bytes. `e` tem de estar preparado para os dois tamanhos.
void encaixe_nv12(const struct encaixe *e, uint8_t *dst_y, uint32_t dst_passo_y, uint8_t *dst_uv,
		  uint32_t dst_passo_uv, const uint8_t *src_y, uint32_t src_passo_y, const uint8_t *src_uv,
		  uint32_t src_passo_uv);
