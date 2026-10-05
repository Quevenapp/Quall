// O adapt2 da fita DV (`qualldv.c`, `desentrelacar`), generalizado para o DVD (`docs/dvd-para-mp4.md`
// §2.5 e a revisão, 10): qualquer largura e altura pares, croma 4:2:0 entrelaçado, e a ordem dos
// campos pelo `top_field_first` de cada quadro (na fita ela é fixa: campo de baixo primeiro).
//
// C puro, sem FFmpeg nem JNI: o teste de mesa roda no Mac (`apps/android/tools/testa-dvd.sh`).
//
// A regra (a mesma da fita): o campo **mais novo** (o segundo no tempo) fica como está; nas linhas
// do outro, bob com ELA onde há movimento temporal > 10 contra o quadro anterior, ou pente médio
// em x±3 > 3; weave no resto; a decisão dilatada na vertical (a linha y vai a bob se y-2, y ou y+2
// foi). Sem quadro anterior, tudo bob.
//
// **O croma 4:2:0 entrelaçado** (a revisão, 10): a linha de croma `cy` é do campo `cy & 1` e casa
// com as lumas `4k+f` e `4k+2+f` (`k = cy >> 1`, `f = cy & 1`); horizontalmente, o croma `x` cobre
// as lumas `2x` e `2x+1`. Uma linha de croma do campo interpolado vai a bob se alguma das quatro
// lumas foi; o bob do croma é a média das linhas `cy-1` e `cy+1`, que são do outro campo (o que
// fica) e estão, na imagem, logo acima e logo abaixo dela.
#pragma once
#include <stdint.h>

typedef struct Desentrelacador Desentrelacador;

// Luma w x h (pares, h múltiplo de 4), croma (w/2) x (h/2). NULL sem memória ou tamanho inválido.
Desentrelacador *des_novo(int w, int h);
void des_libera(Desentrelacador *d);

// Desentrelaça o quadro `in` (três planos 4:2:0 com os strides `is`) nos planos internos.
// `tff`: 1 se o campo de cima vem primeiro no tempo (então o de baixo, o mais novo, fica).
void des_quadro(Desentrelacador *d, const uint8_t *const in[3], const int is[3], int tff);

// O quadro progressivo passa como está (e vira o anterior do próximo entrelaçado).
void des_progressivo(Desentrelacador *d, const uint8_t *const in[3], const int is[3]);

// Os planos do último quadro (luma w x h com stride w; croma w/2 x h/2 com stride w/2).
const uint8_t *des_plano(const Desentrelacador *d, int p);

// Quantos pontos de luma foram a bob no último `des_quadro` (bancada e teste).
long des_pontos_bob(const Desentrelacador *d);

// A regra do croma, exposta para o teste: a luma `qual` (0 ou 1) da linha de croma `cy` num quadro
// de altura `h` (a segunda cai para a primeira quando passa da borda).
int des_luma_do_croma(int cy, int qual, int h);
