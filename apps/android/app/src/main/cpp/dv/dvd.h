// O DVD para MP4 (`docs/dvd-para-mp4.md` §2.4–§2.6, a D1b): do fluxo MPEG-PS do título, empurrado em
// blocos pelo leitor, ao quadro progressivo pronto para o encoder H.264 e ao PCM estéreo de 48 kHz
// de cada faixa de som, pronto para o AAC. C puro sobre a libavformat/libavcodec (LGPL), sem JNI:
// o mesmo código roda no teste de mesa do Mac (`apps/android/tools/testa-dvd.sh`, com o FFmpeg do
// Homebrew). A ponte JNI é `dvd_jni.c`.
//
// Duas threads:
// - **a do leitor** chama `dvd_celula` (antes de empurrar a célula) e `dvd_empurrar` (bloqueia com
//   a fila cheia: 8 MB), e no fim `dvd_fim_da_entrada`; ou `dvd_abortar` com o motivo;
// - **a da conversão** chama `dvd_preparar`, depois `dvd_passo` em laço, e a cada `DVD_QUADRO`
//   `dvd_quadro` + `dvd_escrever`, e `dvd_som` para cada faixa.
//
// **A proteção falha fechado** (§2.1): cada setor de 2048 bytes é conferido **antes** de entrar na
// fila — um pack de vídeo, som ou legenda com os bits `PES_scrambling_control` diferentes de 0
// para tudo com `DVD_ERRO_CIFRADO`, e o setor nunca chega ao demuxer nem ao decodificador.
//
// **Os carimbos** (§2.4, a revisão, 7): o tempo de saída de um pacote é o acumulado das células
// anteriores (o C_PBTM do IFO, que o Kotlin passa em `dvd_celula`) + (PTS − `vobu_s_ptm` do NAV
// pack do primeiro setor da célula). O pacote é ligado à célula pela posição dele no fluxo
// (`AVPacket.pos`). Sem célula nenhuma (a D1, sem IFO), uma implícita no byte 0 com o acumulado 0.
// O NAV que não é NAV (o do muxer `dvd` do FFmpeg, zerado) cai para o PTS do primeiro pacote da
// célula.
#pragma once
#include <stdint.h>

#define DVD_MAX_FAIXAS 8
#define DVD_SETOR 2048

// dvd_passo
#define DVD_NADA 0
#define DVD_QUADRO 1
#define DVD_FIM 2

// Os erros (negativos, fora da faixa dos AVERROR comuns).
#define DVD_ERRO_CIFRADO (-1001)    // um setor com os bits de cifragem do PES ≠ 0 (§2.1)
#define DVD_ERRO_CANCELADO (-1002)  // `dvd_abortar(DVD_ERRO_CANCELADO)`
#define DVD_ERRO_POSICAO (-1003)    // um bloco fora de ordem, ou fora do alinhamento de setor
#define DVD_ERRO_DEMUX (-1004)
#define DVD_ERRO_VIDEO (-1005)      // sem vídeo MPEG-2 no título
#define DVD_ERRO_MEMORIA (-1006)
#define DVD_ERRO_LEITOR (-1007)     // o leitor parou (o Kotlin diz o motivo)
#define DVD_ERRO_CELULAS (-1008)    // células demais, ou fora de ordem

typedef struct Dvd Dvd;

// `faixas`: os substreams de som na ordem do IFO — 0x80+n (AC-3), 0xA0+n (LPCM), 0x1C0+n (MPEG);
// cada um vira uma faixa, exista ou não no fluxo (a que não aparece sai em silêncio).
// `n_faixas < 0`: o modo automático da bancada (sem IFO): as faixas que aparecerem antes do
// primeiro quadro de vídeo.
Dvd *dvd_novo(const int *faixas, int n_faixas);
void dvd_libera(Dvd *d);

// ---- a thread do leitor ----------------------------------------------------------------------
// Uma célula começa no byte `pos` do fluxo (múltiplo de 2048), com `acumulado90k` de tempo antes
// dela. Em ordem crescente, e antes de empurrar o primeiro setor dela.
int dvd_celula(Dvd *d, int64_t pos, int64_t acumulado90k);
// `n` bytes (setores inteiros) na posição `pos` do fluxo (a seguinte à do bloco anterior). Bloqueia
// enquanto a fila está cheia. 0, ou um erro (DVD_ERRO_CIFRADO: o bloco não entrou, e a conversão
// para).
int dvd_empurrar(Dvd *d, const uint8_t *dados, int n, int64_t pos);
void dvd_fim_da_entrada(Dvd *d);
// Para tudo com `erro` (DVD_ERRO_CANCELADO, DVD_ERRO_LEITOR): as duas threads acordam.
void dvd_abortar(Dvd *d, int erro);

// ---- a thread da conversão -------------------------------------------------------------------
// Abre o demuxer e decodifica até o primeiro quadro de vídeo (a informação fica pronta). 0 ou erro.
int dvd_preparar(Dvd *d);

typedef struct {
    int largura, altura;          // do primeiro quadro (720/704/352 x 480/576/240/288)
    int fps_num, fps_den;         // 30000/1001 ou 25/1
    int aspecto169;               // pela SAR do fluxo: 1 = 16:9, 0 = 4:3
    int entrelacado;              // o primeiro quadro
    int n_faixas;
    int faixa_id[DVD_MAX_FAIXAS];      // o substream
    int faixa_visto[DVD_MAX_FAIXAS];   // já apareceu no fluxo
} DvdInfo;
void dvd_info(Dvd *d, DvdInfo *i);

// Demultiplexa e decodifica um pacote. DVD_QUADRO (há quadro para `dvd_quadro`), DVD_NADA, DVD_FIM,
// ou um erro.
int dvd_passo(Dvd *d);
// O próximo quadro vira o atual (desentrelaçado se é entrelaçado). 1, ou 0 sem quadro. `pts90k`:
// o carimbo de saída; `dur90k`: a duração nominal dele (com o *pulldown*: 1,5 quadro).
int dvd_quadro(Dvd *d, int64_t *pts90k, int64_t *dur90k);
// O quadro atual, cortado para 704 (o de 720) e escalado para W x H 4:2:0 (Y com stride ys; U e V
// com stride cs e passo de pixel cps, 1 planar ou 2 intercalado). 0, ou <0.
int dvd_escrever(Dvd *d, uint8_t *Y, int ys, uint8_t *U, uint8_t *V, int cs, int cps, int W, int H);
// Até `max` amostras estéreo s16 intercaladas da faixa (48 kHz). Devolve quantas.
int dvd_som(Dvd *d, int faixa, int16_t *saida, int max);

// Os contadores (ver a lista em dvd.c, `dvd_contadores`); devolve quantos escreveu.
#define DVD_N_CONTADORES (17 + 4 * DVD_MAX_FAIXAS + 5)

// O diário por célula e o resumo das correções, no logcat (o fim da conversão; o defeito do A07).
void dvd_diario(Dvd *d);
int dvd_contadores(Dvd *d, int64_t *v, int n);
// As faixas com um canal só espelhado para os dois lados (bit k = a faixa k).
int dvd_canal_copiado(Dvd *d);

// ---- para o teste de mesa ---------------------------------------------------------------------
// Confere um setor (e o corrige): 0 limpo, 1 cifrado (não mexe), 2 fora do formato (a sobra
// depois do último PES inteiro foi zerada), 3 zerado. `*s_ptm` recebe o vobu_s_ptm quando o setor é
// um NAV pack válido (e *nav = 1).
int dvd_confere_setor(uint8_t *setor, int *nav, uint32_t *s_ptm);
