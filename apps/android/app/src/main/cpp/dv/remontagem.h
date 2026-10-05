// A remontagem dos payloads UVC em quadros, para a DV e para o MJPEG (a placa de captura USB,
// `docs/placa-de-captura-usb.md` §3.4). Separada do `qualldv.c` para ser testada no Mac sem FFmpeg
// nem JNI (`apps/android/tools/testa-remontagem.sh`).
//
// Uma thread só escreve (a de USB); os contadores são atômicos porque o `contadores` do JNI os lê
// de outra.
#pragma once

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#define QUADRO_DV 120000
#define CAP_ACUM_DV (256 * 1024)
// Um quadro UVC com mais JPEG inteiros que isto é partido só até aqui (medido: no máximo dois).
#define MAX_JPEG_POR_QUADRO 4
// O carimbo do JPEG que chegou colado no seguinte: um quadro (30/s) antes do outro.
#define PASSO_JPEG_NS 33333333LL

enum { FORMATO_DV = 0, FORMATO_MJPEG = 1 };

// Um quadro pronto: `q` vale só durante a chamada. `ruim` = veio com ERR ou pacote com erro (só a
// DV na gravação entrega assim).
typedef void (*EntregaFn)(void *ctx, const uint8_t *q, size_t n, int64_t ts, int ruim);

typedef struct {
    int formato;
    uint8_t *acum;
    size_t cap;      // DV: CAP_ACUM_DV (o acumulador de sempre); MJPEG: o dwMaxVideoFrameSize
    size_t n;
    int ultimo_fid, ruim, grande;
    // **Quadro não comprimido** (as placas HDMI em NV12, §14): > 0 é o tamanho exato do quadro; ele
    // fecha na troca de FID ou no EOF e só vale inteiro (`n == cru_tam`, sem ERR). O formato
    // continua FORMATO_MJPEG (o ramo "placa" de todo o resto); só o fecho muda.
    size_t cru_tam;
    // DV na gravação: o quadro com erro de USB também vai (o dvvideo mascara os blocos). Escrito
    // pela thread de USB antes de cada lote; o MJPEG nunca entrega quadro ruim (o JPEG partido
    // desmancha a imagem inteira).
    int aceitar_ruim;
    EntregaFn entregar;
    void *ctx;
    // contadores (acumulados). `integros` conta quadros entregues (no MJPEG, JPEGs: um quadro
    // UVC com dois JPEG conta dois); `tortos` os quadros UVC recusados, e o motivo vai ao lado.
    atomic_ullong integros, tortos, ruins_entregues, err_bit;
    atomic_ullong sem_soi, sem_eoi, grande_demais, descartados_ruins, dois_em_um, so_pela_borda;
    // não são tortos: lixo não-zero depois do EOI de um JPEG entregue; pacotes com cabeçalho UVC
    // inválido (no MJPEG marcam o quadro em curso como ruim)
    atomic_ullong lixo_depois_do_eoi, cabecalho_invalido;
} Remontagem;

// 0 ok, -1 sem memória. `cap_quadro` só vale no MJPEG.
int remonta_inicia(Remontagem *r, int formato, size_t cap_quadro, EntregaFn entregar, void *ctx);
void remonta_libera(Remontagem *r);

// Um payload UVC inteiro (um pacote isócrono), com o cabeçalho; `ts` é o carimbo do pacote.
void remonta_payload(Remontagem *r, const uint8_t *p, size_t len, int64_t ts);

// Um pacote isócrono com erro: o quadro em curso fica marcado como ruim.
static inline void remonta_pacote_ruim(Remontagem *r) { r->ruim = 1; }

// ------------------------------------------------------------------------------------ URBs
// Aqui, e não no qualldv.c, para o teste de mesa (sem FFmpeg) conferir as duas combinações.
#define MAX_URBS 256
#define MAX_PACOTES 32
#define BYTES_POR_URB 32768
#define MICROQUADROS_DE_FOLGA 512  // ~64 ms em alta velocidade
// MJPEG (a placa): no máximo 3 pacotes por URB. Medido no A07 (MediaTek MT6789, kernel
// 6.12.38-android16, 28/09 à noite): com 4 ou mais pacotes por URB o conteúdo dos pacotes chega
// perdido (os cabeçalhos UVC certos, o dado zerado ou deslocado: 100 % dos JPEG "sem SOI" com 8 x
// 3000, 4 x 3000 e 4 x 960); com 1, 2 ou 3, 100 % íntegros a 30 JPEG/s (3 x 3000, 2 x 3000, 1 x
// 3000, 2 x 960). Não era a fita nem o hub. O S24 roda os 64 x 8 da P0, mas a regra vale para os dois.
#define MAX_PACOTES_MJPEG 3
// **E no máximo 384 pacotes em trânsito na placa** (o A07 de novo, 28/09 à noite, medido com o
// espião): 128 x 3 = 384 e 128 x 2 = 256 chegam 100 % íntegros; 171 x 3 = 513, 128 x 4 = 512 e
// 64 x 8 = 512 chegam 0 %. O controlador perde o conteúdo acima de algo entre 384 e 512 pacotes na
// fila isócrona, e não só com URBs longas. 128 x 3 = 48 ms de folga.
#define PACOTES_EM_TRANSITO_MJPEG 384
// **O som da placa pelo usbfs** (docs/placa-de-captura-usb.md §13.10): 8 URBs de 4 pacotes de 1 ms no
// endpoint de som, no mesmo fd (4 ms = 192 amostras: cinco URBs dão um quadro de 20 ms exato; com
// URBs de 8 ms a entrega alternava 16 e 24 ms, §13.11). Os 32 pacotes saem da conta dos 384 (o limite do A07 é da fila
// isócrona do controlador; não se mediu se é por endpoint): o vídeo fica com 352 (117 x 3, 44 ms).
#define SOM_URBS 8
#define SOM_PACOTES 4

// Pacotes por URB e URBs, pelo formato:
// - DV: a maior potência de 2 com a URB em até 32 KB (e no máximo 32); URBs: as que somem 512
//   pacotes (~64 ms). psize 492 -> 16 x 32 (a GS500 de sempre, provada no S24; no A07 nunca medida).
// - MJPEG: até 3 pacotes (o A07, acima) dentro dos 32 KB, e as URBs que somem os mesmos ~64 ms, até
//   256, e no máximo 384 pacotes em trânsito. psize 3000 -> 128 x 3 (48 ms, 1,1 MB); o custo é
//   ~2700 SUBMITURB/s, que o resumo do diário conta (`envios_por_s`).
//
// **A DV também** (30/09, medido no A07 com a GS500): com 16 x 32 = 512 em trânsito, 30 quadros/s chegavam
// e **todos** tortos (sem o bit de erro da filmadora); a mesma regra da placa, 3 pacotes por URB e no
// máximo 384 em trânsito, vale para ela (a DV não tem som por fora: os 384 inteiros).
static inline void dimensiona_urbs(int formato, int psize, int *urbs, int *pacotes) {
    int cabem = psize > 0 ? BYTES_POR_URB / psize : 1;
    if (cabem < 1) cabem = 1;
    int p = cabem < MAX_PACOTES_MJPEG ? cabem : MAX_PACOTES_MJPEG;
    int u = (MICROQUADROS_DE_FOLGA + p - 1) / p;
    int teto = formato == FORMATO_MJPEG ? PACOTES_EM_TRANSITO_MJPEG - SOM_URBS * SOM_PACOTES : PACOTES_EM_TRANSITO_MJPEG;
    if (u * p > teto) u = teto / p;
    if (u > MAX_URBS) u = MAX_URBS;
    *urbs = u;
    *pacotes = p;
}

// O fim do JPEG que começa em q[0] (o índice logo depois do EOI), andando pelos segmentos e pelo
// dado entrópico; 0 se não começa com SOI ou não chega a um EOI dentro de n.
size_t jpeg_fim(const uint8_t *q, size_t n);
