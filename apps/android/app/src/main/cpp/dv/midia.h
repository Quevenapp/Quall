// O som da fita e o MP4 da gravação: C puro sobre a libavformat (LGPL), sem JNI, para o mesmo
// código rodar no teste de mesa do Mac (`tools/espiao-dv-s24/bancada-dv/midia-mesa.c`).
#pragma once
#include <stdint.h>

// ---- som: o demuxer `dv` da libavformat, alimentado quadro a quadro --------------------------
typedef struct SomDv SomDv;

SomDv *som_novo(void);
void som_libera(SomDv *s);

// Extrai o PCM do quadro DV (120 000 bytes) no primeiro par de canais: s16 intercalado, estéreo.
// Devolve o número de amostras por canal (0 se o quadro não traz som; <0 em erro) e escreve a taxa
// em *taxa. A taxa sai do número de amostras do quadro (29,97 fps: 48 kHz dá 1580–1620, 44,1 kHz
// 1452–1489, 32 kHz 1053–1080), e não do stream do demuxer, que fica com a primeira taxa quando a
// fita troca no meio. `saida` precisa de 2000 amostras estéreo (8000 bytes).
int som_do_quadro(SomDv *s, const uint8_t *quadro, int16_t *saida, int *taxa);

// ---- som da gravação: sempre 48 kHz, ancorado no índice do quadro ---------------------------
typedef struct SomGravacao SomGravacao;

SomGravacao *somg_novo(void);
void somg_libera(SomGravacao *g);

// O som do quadro n da gravação, em 48 kHz estéreo s16 intercalado (`saida`: 8000 amostras
// estéreo). `pcm` com `n_pcm` amostras a `taxa` (0 amostras: quadro sem som). A reamostragem para
// 48 kHz é contínua entre quadros (sinc janelado); a âncora mantém o total de amostras escritas a
// menos de meio quadro de n × 1601,6: acrescenta silêncio (quadro sem som, som atrasado) ou corta
// (som adiantado). Devolve as amostras escritas e soma em *corrigidas as de silêncio/corte.
int somg_quadro(SomGravacao *g, int64_t n, const int16_t *pcm, int n_pcm, int taxa,
                int16_t *saida, int64_t *corrigidas);

// ---- MP4: o muxer `mp4` com movflags=hybrid_fragmented, escrevendo num fd ------------------
typedef struct Mp4 Mp4;

// `sps_pps` em Annex-B (o csd-0 + csd-1 do MediaCodec); `asc` é o AudioSpecificConfig do AAC
// (csd-0 do encoder de som). Tempos: vídeo em 1/30000 s (quadro n = n*1001), som em 1/taxa.
// `atraso_som` fica só registrado: o muxer mp4 do FFmpeg não escreve lista de edição a partir do
// `initial_padding`; o atraso do AAC é tirado do PTS do som pelo GravadorMp4.
Mp4 *mp4_abre(int fd, int largura, int altura, const uint8_t *sps_pps, int n_sps_pps,
              int taxa, int canais, int bitrate_som, const uint8_t *asc, int n_asc,
              int atraso_som, char *erro, int n_erro);
int mp4_video(Mp4 *m, const uint8_t *dados, int n, int64_t pts, int chave);

// **A câmera da tela R5** (`docs/teleprompter-com-camera.md` §5.2, G3): o mesmo muxer fragmentado,
// com o tempo que a câmera deu, e não o da fita. O vídeo chega em **1/90000 s**, cada amostra com a
// **sua duração** (fps variável: a câmera cai em pouca luz); o som em 1/taxa, como na fita. A cor é
// a que o codificador declarou, pelas constantes do `MediaFormat` (`padrao`: COLOR_STANDARD_*,
// `faixa`: COLOR_RANGE_*, `transferencia`: COLOR_TRANSFER_*; 0 = não declarada). Nenhuma taxa de
// quadros é declarada no stream.
Mp4 *mp4_abre_camera(int fd, int largura, int altura, const uint8_t *sps_pps, int n_sps_pps,
                     int taxa, int canais, int bitrate_som, const uint8_t *asc, int n_asc,
                     int padrao, int faixa, int transferencia, char *erro, int n_erro);
// Um quadro da câmera: `pts` e `duracao` em 1/90000 s (a duração > 0). Na fita, `mp4_video`.
int mp4_video_dur(Mp4 *m, const uint8_t *dados, int n, int64_t pts, int64_t duracao, int chave);
int mp4_som(Mp4 *m, const uint8_t *dados, int n, int64_t pts, int duracao);

// **O DVD** (`docs/dvd-para-mp4.md` §2.6, a D1c): o MP4 da câmera (vídeo em 1/90000 com a duração de
// cada quadro, a cor declarada) com **várias faixas de som** — `n_som` AAC de `taxa` Hz e `canais`
// canais, cada uma com o seu ASC (`ascs[k]`, `n_ascs[k]` bytes) e o idioma (`idiomas[k]`, ISO 639-2
// de três letras, ou NULL). A primeira é a padrão; as outras, alternativas (o tocador escolhe).
#define MP4_MAX_SOM 8
Mp4 *mp4_abre_faixas(int fd, int largura, int altura, const uint8_t *sps_pps, int n_sps_pps, int n_som,
                     const uint8_t *const *ascs, const int *n_ascs, const char *const *idiomas, int taxa,
                     int canais, int bitrate_som, int padrao, int faixa, int transferencia, char *erro,
                     int n_erro);
// O som da faixa `faixa` (0 a n_som-1), em 1/taxa.
int mp4_som_faixa(Mp4 *m, int faixa, const uint8_t *dados, int n, int64_t pts, int duracao);
// Escreve o trailer (o `moov`: o arquivo vira MP4 comum) e libera. Devolve 0 ou o erro do FFmpeg.
int mp4_fecha(Mp4 *m);

// Remonta um MP4 (o fragmentado que sobrou de uma gravação interrompida) em MP4 comum, de fd para
// fd, sem recodificar. Devolve os pacotes copiados, ou <0.
// *parcial vira 1 se a leitura parou num erro (arquivo cortado ou corrompido) e não no fim.
int64_t mp4_remonta(int fd_entrada, int fd_saida, int *parcial, char *erro, int n_erro);
