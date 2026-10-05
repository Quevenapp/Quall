// O som da fita e o MP4 da gravação (ver midia.h). LGPL: só chama a libavformat dinâmica.
#include "midia.h"

#include <errno.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// ---- som ------------------------------------------------------------------------------------
// As três funções `avpriv_dv_*` são a interface do demuxer DV para quem já tem os quadros na mão
// (o próprio FFmpeg as usa no demuxer AVI e no de DV). Não estão nos cabeçalhos públicos, mas a
// `libavformat.so` as exporta (`av*` no libavformat.v). O contrato, lido em libavformat/dv.c
// (9.0.1): `produce_packet` extrai o som do quadro para os buffers internos (e o pacote de vídeo
// aponta para o quadro); `get_packet` devolve um ponteiro para o buffer interno, válido até o
// próximo `produce_packet`. Por ser ABI privada, a `libavformat.so` que substituir esta tem de ser
// da mesma série (9.0.x); a tela de licenças diz isso.
typedef struct DVDemuxContext DVDemuxContext;
DVDemuxContext *avpriv_dv_init_demux(AVFormatContext *s);
int avpriv_dv_get_packet(DVDemuxContext *c, AVPacket *pkt);
int avpriv_dv_produce_packet(DVDemuxContext *c, AVPacket *pkt, uint8_t *buf, int buf_size,
                             int64_t pos);

struct SomDv {
    AVFormatContext *fmt;
    DVDemuxContext *dmx;
    AVPacket *pk;
    uint8_t *buf;  // cópia do quadro (o demuxer pede ponteiro não-const)
};

SomDv *som_novo(void) {
    SomDv *s = calloc(1, sizeof(SomDv));
    if (!s) return NULL;
    s->fmt = avformat_alloc_context();
    s->dmx = s->fmt ? avpriv_dv_init_demux(s->fmt) : NULL;
    s->pk = av_packet_alloc();
    s->buf = malloc(144000);
    if (!s->dmx || !s->pk || !s->buf) { som_libera(s); return NULL; }
    return s;
}

void som_libera(SomDv *s) {
    if (!s) return;
    av_free(s->dmx);  // alocado por av_mallocz no demuxer; os streams são do fmt
    if (s->fmt) avformat_free_context(s->fmt);
    av_packet_free(&s->pk);
    free(s->buf);
    free(s);
}

// A taxa pelo número de amostras do quadro a 29,97 (as faixas não se tocam).
static int taxa_pelas_amostras(int n) {
    if (n >= 1500) return 48000;
    if (n >= 1400) return 44100;
    if (n >= 1000) return 32000;
    return 0;
}

int som_do_quadro(SomDv *s, const uint8_t *quadro, int16_t *saida, int *taxa) {
    memcpy(s->buf, quadro, 120000);
    av_packet_unref(s->pk);
    int r = avpriv_dv_produce_packet(s->dmx, s->pk, s->buf, 120000, -1);
    // o pacote de vídeo aponta para s->buf; não é nosso
    s->pk->data = NULL; s->pk->size = 0; s->pk->buf = NULL;
    if (r < 0) return r;
    // o primeiro par de canais (stream 1 do fmt: o 0 é o vídeo)
    int amostras = 0;
    for (;;) {
        AVPacket p = {0};
        int n = avpriv_dv_get_packet(s->dmx, &p);
        if (n < 0) break;
        if (amostras == 0 && s->fmt->nb_streams > 1 && p.stream_index == s->fmt->streams[1]->index) {
            int m = n / 4;
            if (m > 2000) m = 2000;
            int t = taxa_pelas_amostras(m);
            if (t) {
                memcpy(saida, p.data, (size_t)m * 4);
                amostras = m;
                *taxa = t;
            }
        }
        av_packet_free_side_data(&p);
    }
    return amostras;
}

// ---- som da gravação: 48 kHz, ancorado no quadro -------------------------------------------
#define META 8                // meia largura do núcleo sinc (16 amostras)
#define CAP_ENTRADA 16384     // amostras estéreo guardadas na reamostragem

struct SomGravacao {
    float *entrada;           // estéreo intercalado, na taxa da fita
    int n_entrada;
    double pos;               // posição da próxima amostra de saída, em amostras de entrada
    int taxa;                 // a taxa da fita em curso (0: nenhuma ainda)
    int64_t escritas;         // amostras de 48 kHz já entregues
};

SomGravacao *somg_novo(void) {
    SomGravacao *g = calloc(1, sizeof(SomGravacao));
    if (g) g->entrada = calloc(CAP_ENTRADA * 2, sizeof(float));
    if (g && !g->entrada) { free(g); g = NULL; }
    return g;
}

void somg_libera(SomGravacao *g) {
    if (!g) return;
    free(g->entrada);
    free(g);
}

// Núcleo: sinc com janela de Blackman, meia largura META. Ampliando (32/44,1 → 48 kHz), o corte é o
// Nyquist da entrada.
static double nucleo(double d) {
    if (fabs(d) >= META) return 0;
    double s = d == 0 ? 1.0 : sin(M_PI * d) / (M_PI * d);
    double x = (d + META) / (2.0 * META);
    double w = 0.42 - 0.5 * cos(2 * M_PI * x) + 0.08 * cos(4 * M_PI * x);
    return s * w;
}

static inline int16_t sat16(double v) {
    return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)lrint(v);
}

// Reamostra o que houver na entrada para 48 kHz; devolve as amostras escritas em `out`.
static int reamostra(SomGravacao *g, int16_t *out, int cap) {
    double passo = (double)g->taxa / 48000.0;
    int n = 0;
    while (n < cap && (int)floor(g->pos) + META < g->n_entrada) {
        int i0 = (int)floor(g->pos);
        double f = g->pos - i0;
        double l = 0, r = 0;
        for (int k = -META + 1; k <= META; k++) {
            int i = i0 + k;
            if (i < 0) continue;
            double w = nucleo(k - f);
            l += w * g->entrada[2 * i];
            r += w * g->entrada[2 * i + 1];
        }
        out[2 * n] = sat16(l);
        out[2 * n + 1] = sat16(r);
        n++;
        g->pos += passo;
    }
    // descarta o que não será mais lido (guarda META amostras para trás)
    int descartar = (int)floor(g->pos) - META;
    if (descartar > 0) {
        memmove(g->entrada, g->entrada + 2 * descartar, (size_t)(g->n_entrada - descartar) * 2 * sizeof(float));
        g->n_entrada -= descartar;
        g->pos -= descartar;
    }
    return n;
}

int somg_quadro(SomGravacao *g, int64_t n, const int16_t *pcm, int n_pcm, int taxa, int16_t *saida,
                int64_t *corrigidas) {
    int16_t tmp[8000];
    int prod = 0;
    if (n_pcm > 0 && taxa > 0) {
        if (taxa != g->taxa) {
            // A fita trocou de taxa (ou é a primeira): a reamostragem recomeça. A âncora abaixo
            // absorve o degrau.
            g->taxa = taxa;
            g->n_entrada = 0;
            g->pos = 0;
        }
        if (taxa == 48000) {
            memcpy(tmp, pcm, (size_t)n_pcm * 4);
            prod = n_pcm;
        } else {
            if (g->n_entrada + n_pcm > CAP_ENTRADA) g->n_entrada = 0;  // não acontece em regime
            for (int i = 0; i < 2 * n_pcm; i++) g->entrada[2 * g->n_entrada + i] = pcm[i];
            g->n_entrada += n_pcm;
            prod = reamostra(g, tmp, 4000);
        }
    }
    // A âncora: ao fim deste quadro o total deve estar em (n+1) x 1601,6 amostras de 48 kHz.
    int64_t alvo = ((n + 1) * 16016 + 5) / 10;
    int64_t excesso = g->escritas + prod - alvo;
    int saiu = 0, ini = 0;
    if (excesso < -800) {
        int64_t sil = -excesso;
        if (sil > 4000) sil = 4000;
        memset(saida, 0, (size_t)sil * 4);
        saiu = (int)sil;
        *corrigidas += sil;
    } else if (excesso > 800) {
        ini = (int)(excesso < prod ? excesso : prod);
        *corrigidas += ini;
    }
    int copiar = prod - ini;
    if (saiu + copiar > 8000) copiar = 8000 - saiu;
    memcpy(saida + 2 * saiu, tmp + 2 * ini, (size_t)copiar * 4);
    saiu += copiar;
    g->escritas += saiu;
    return saiu;
}

// ---- MP4 ------------------------------------------------------------------------------------
struct Mp4 {
    AVFormatContext *oc;
    AVIOContext *io;
    int fd;
    AVStream *sv, *sa;  // `sa`: a primeira faixa de som (a fita e a câmera só têm uma)
    AVStream *sas[MP4_MAX_SOM];
    int n_sa;
    int taxa;
    AVRational tb_video;  // a unidade dos tempos de vídeo que chegam (1/30000 na fita, 1/90000 na câmera)
};

static int escreve(void *op, const uint8_t *buf, int n) {
    int fd = *(int *)op;
    int feito = 0;
    while (feito < n) {
        ssize_t r = write(fd, buf + feito, (size_t)(n - feito));
        if (r < 0) {
            if (errno == EINTR) continue;
            return AVERROR(errno);
        }
        feito += (int)r;
    }
    return n;
}

static int le(void *op, uint8_t *buf, int n) {
    int fd = *(int *)op;
    for (;;) {
        ssize_t r = read(fd, buf, (size_t)n);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) return AVERROR(errno);
        return r == 0 ? AVERROR_EOF : (int)r;
    }
}

static int64_t busca(void *op, int64_t pos, int de_onde) {
    int fd = *(int *)op;
    if (de_onde == AVSEEK_SIZE) {
        struct stat st;
        return fstat(fd, &st) == 0 ? st.st_size : AVERROR(errno);
    }
    off_t r = lseek(fd, (off_t)pos, de_onde & ~AVSEEK_FORCE);
    return r < 0 ? AVERROR(errno) : r;
}

static void cor_do_dv(AVCodecParameters *p) {
    // O DV é BT.601 525 de faixa limitada, e a gravação guarda os valores como vieram (sem
    // converter matriz): o `colr` (nclx) e a VUI dizem isso.
    p->color_range = AVCOL_RANGE_MPEG;
    p->color_primaries = AVCOL_PRI_SMPTE170M;
    p->color_trc = AVCOL_TRC_SMPTE170M;
    p->color_space = AVCOL_SPC_SMPTE170M;
}

// A cor da câmera, pelas constantes do `MediaFormat` que o codificador declarou (0: não declarada).
// Só os valores que o Android usa para vídeo de câmera; o resto fica "não especificado".
static void cor_da_camera(AVCodecParameters *p, int padrao, int faixa, int transferencia) {
    p->color_range = faixa == 1 ? AVCOL_RANGE_JPEG : faixa == 2 ? AVCOL_RANGE_MPEG : AVCOL_RANGE_UNSPECIFIED;
    switch (padrao) {
    case 1:  // COLOR_STANDARD_BT709
        p->color_primaries = AVCOL_PRI_BT709; p->color_space = AVCOL_SPC_BT709; break;
    case 2:  // COLOR_STANDARD_BT601_PAL
        p->color_primaries = AVCOL_PRI_BT470BG; p->color_space = AVCOL_SPC_BT470BG; break;
    case 4:  // COLOR_STANDARD_BT601_NTSC
        p->color_primaries = AVCOL_PRI_SMPTE170M; p->color_space = AVCOL_SPC_SMPTE170M; break;
    case 6:  // COLOR_STANDARD_BT2020
        p->color_primaries = AVCOL_PRI_BT2020; p->color_space = AVCOL_SPC_BT2020_NCL; break;
    default:
        p->color_primaries = AVCOL_PRI_UNSPECIFIED; p->color_space = AVCOL_SPC_UNSPECIFIED; break;
    }
    switch (transferencia) {
    case 3:  // COLOR_TRANSFER_SDR_VIDEO
        p->color_trc = padrao == 1 ? AVCOL_TRC_BT709 : padrao == 6 ? AVCOL_TRC_BT2020_10 : AVCOL_TRC_SMPTE170M; break;
    case 6: p->color_trc = AVCOL_TRC_SMPTE2084; break;       // COLOR_TRANSFER_ST2084
    case 7: p->color_trc = AVCOL_TRC_ARIB_STD_B67; break;    // COLOR_TRANSFER_HLG
    default: p->color_trc = AVCOL_TRC_UNSPECIFIED; break;
    }
}

// O corpo comum da fita e da câmera: o que muda é a unidade do vídeo, a taxa de quadros declarada
// (a fita é 29,97 fixa; a câmera é variável, e não declara) e a cor.
// `n_som` faixas de som (0 a MP4_MAX_SOM), cada uma com o seu ASC e o idioma (ISO 639-2, ou NULL);
// a primeira é a padrão (a única ligada no `tkhd`; as outras ficam como alternativas).
// Os parâmetros do codificador (csd em Annex B) são de HEVC? O primeiro NAL depois do código de
// início: no HEVC o tipo está em (byte >> 1) & 0x3F, e o VPS é 32; no H.264 o SPS é (byte & 0x1F) == 7.
static int parametros_sao_hevc(const uint8_t *p, int n) {
    for (int i = 0; i + 3 < n; i++) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
            uint8_t b = p[i + 3];
            return ((b >> 1) & 0x3F) == 32 && (b & 0x1F) != 7;
        }
    }
    return 0;
}

static Mp4 *abre(int fd, int largura, int altura, const uint8_t *sps_pps, int n_sps_pps, int taxa,
                 int canais, int bitrate_som, int n_som, const uint8_t *const *ascs, const int *n_ascs,
                 const char *const *idiomas, int atraso_som,
                 int camera, int padrao, int faixa, int transferencia, char *erro, int n_erro) {
    Mp4 *m = calloc(1, sizeof(Mp4));
    int r;
    if (!m) return NULL;
    m->fd = fd;
    m->taxa = taxa;
    m->tb_video = camera ? (AVRational){1, 90000} : (AVRational){1, 30000};
    if ((r = avformat_alloc_output_context2(&m->oc, NULL, "mp4", NULL)) < 0) goto falha;
    const int tam_io = 1 << 16;
    uint8_t *bufio = av_malloc(tam_io);
    m->io = avio_alloc_context(bufio, tam_io, 1, &m->fd, NULL, escreve, busca);
    if (!m->io) { r = AVERROR(ENOMEM); goto falha; }
    m->oc->pb = m->io;

    m->sv = avformat_new_stream(m->oc, NULL);
    m->sv->time_base = m->tb_video;
    if (!camera) m->sv->avg_frame_rate = (AVRational){30000, 1001};
    AVCodecParameters *pv = m->sv->codecpar;
    pv->codec_type = AVMEDIA_TYPE_VIDEO;
    // H.264 ou HEVC, pelo primeiro NAL dos parâmetros (Annex B): o HEVC começa pelo VPS (tipo 32).
    pv->codec_id = parametros_sao_hevc(sps_pps, n_sps_pps) ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264;
    if (pv->codec_id == AV_CODEC_ID_HEVC) pv->codec_tag = MKTAG('h', 'v', 'c', '1');  // o que a Apple toca
    pv->width = largura;
    pv->height = altura;
    if (camera) cor_da_camera(pv, padrao, faixa, transferencia);
    else cor_do_dv(pv);
    pv->extradata = av_mallocz((size_t)n_sps_pps + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(pv->extradata, sps_pps, (size_t)n_sps_pps);
    pv->extradata_size = n_sps_pps;

    if (n_som > MP4_MAX_SOM) n_som = MP4_MAX_SOM;
    for (int k = 0; taxa > 0 && k < n_som; k++) {
        if (n_ascs[k] <= 0) continue;
        AVStream *sa = avformat_new_stream(m->oc, NULL);
        if (!sa) { r = AVERROR(ENOMEM); goto falha; }
        sa->time_base = (AVRational){1, taxa};
        AVCodecParameters *pa = sa->codecpar;
        pa->codec_type = AVMEDIA_TYPE_AUDIO;
        pa->codec_id = AV_CODEC_ID_AAC;
        pa->sample_rate = taxa;
        av_channel_layout_default(&pa->ch_layout, canais);
        pa->bit_rate = bitrate_som;
        pa->frame_size = 1024;
        pa->initial_padding = atraso_som;  // só informativo (ver midia.h)
        pa->extradata = av_mallocz((size_t)n_ascs[k] + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(pa->extradata, ascs[k], (size_t)n_ascs[k]);
        pa->extradata_size = n_ascs[k];
        if (idiomas && idiomas[k] && idiomas[k][0]) av_dict_set(&sa->metadata, "language", idiomas[k], 0);
        sa->disposition = m->n_sa == 0 ? AV_DISPOSITION_DEFAULT : 0;
        m->sas[m->n_sa++] = sa;
    }
    m->sa = m->n_sa ? m->sas[0] : NULL;

    // Fragmentado enquanto grava (legível se o processo morrer), convertido em MP4 comum no fim.
    // Um fragmento por IDR (o encoder põe um por segundo).
    AVDictionary *op = NULL;
    av_dict_set(&op, "movflags", "hybrid_fragmented+frag_keyframe", 0);
    r = avformat_write_header(m->oc, &op);
    av_dict_free(&op);
    if (r < 0) goto falha;
    return m;

falha:
    if (erro) av_strerror(r, erro, (size_t)n_erro);
    if (m->oc) {
        m->oc->pb = NULL;
        avformat_free_context(m->oc);
    }
    if (m->io) { av_freep(&m->io->buffer); avio_context_free(&m->io); }
    free(m);
    return NULL;
}

Mp4 *mp4_abre(int fd, int largura, int altura, const uint8_t *sps_pps, int n_sps_pps, int taxa,
              int canais, int bitrate_som, const uint8_t *asc, int n_asc, int atraso_som, char *erro,
              int n_erro) {
    const uint8_t *ascs[1] = {asc};
    int n_ascs[1] = {n_asc};
    return abre(fd, largura, altura, sps_pps, n_sps_pps, taxa, canais, bitrate_som, n_asc > 0, ascs, n_ascs,
                NULL, atraso_som, 0, 0, 0, 0, erro, n_erro);
}

Mp4 *mp4_abre_camera(int fd, int largura, int altura, const uint8_t *sps_pps, int n_sps_pps,
                     int taxa, int canais, int bitrate_som, const uint8_t *asc, int n_asc,
                     int padrao, int faixa, int transferencia, char *erro, int n_erro) {
    const uint8_t *ascs[1] = {asc};
    int n_ascs[1] = {n_asc};
    return abre(fd, largura, altura, sps_pps, n_sps_pps, taxa, canais, bitrate_som, n_asc > 0, ascs, n_ascs,
                NULL, 0, 1, padrao, faixa, transferencia, erro, n_erro);
}

Mp4 *mp4_abre_faixas(int fd, int largura, int altura, const uint8_t *sps_pps, int n_sps_pps, int n_som,
                     const uint8_t *const *ascs, const int *n_ascs, const char *const *idiomas, int taxa,
                     int canais, int bitrate_som, int padrao, int faixa, int transferencia, char *erro,
                     int n_erro) {
    return abre(fd, largura, altura, sps_pps, n_sps_pps, taxa, canais, bitrate_som, n_som, ascs, n_ascs,
                idiomas, 0, 1, padrao, faixa, transferencia, erro, n_erro);
}

static int escreve_pacote(Mp4 *m, AVStream *st, AVRational tb, const uint8_t *dados, int n,
                          int64_t pts, int duracao, int chave) {
    AVPacket *p = av_packet_alloc();
    if (!p) return AVERROR(ENOMEM);
    int r = av_new_packet(p, n);
    if (r < 0) { av_packet_free(&p); return r; }
    memcpy(p->data, dados, (size_t)n);
    p->stream_index = st->index;
    p->pts = p->dts = pts;
    p->duration = duracao;
    if (chave) p->flags |= AV_PKT_FLAG_KEY;
    // Os tempos chegam nas unidades escolhidas; o muxer pode ter trocado o time_base do stream.
    av_packet_rescale_ts(p, tb, st->time_base);
    r = av_interleaved_write_frame(m->oc, p);
    av_packet_free(&p);
    return r;
}

int mp4_video(Mp4 *m, const uint8_t *dados, int n, int64_t pts, int chave) {
    return escreve_pacote(m, m->sv, (AVRational){1, 30000}, dados, n, pts, 1001, chave);
}

int mp4_video_dur(Mp4 *m, const uint8_t *dados, int n, int64_t pts, int64_t duracao, int chave) {
    if (duracao <= 0 || duracao > INT32_MAX) return AVERROR(EINVAL);
    return escreve_pacote(m, m->sv, m->tb_video, dados, n, pts, (int)duracao, chave);
}

int mp4_som(Mp4 *m, const uint8_t *dados, int n, int64_t pts, int duracao) {
    if (!m->sa) return 0;
    return escreve_pacote(m, m->sa, (AVRational){1, m->taxa}, dados, n, pts, duracao, 1);
}

int mp4_som_faixa(Mp4 *m, int faixa, const uint8_t *dados, int n, int64_t pts, int duracao) {
    if (faixa < 0 || faixa >= m->n_sa) return AVERROR(EINVAL);
    return escreve_pacote(m, m->sas[faixa], (AVRational){1, m->taxa}, dados, n, pts, duracao, 1);
}

int mp4_fecha(Mp4 *m) {
    if (!m) return 0;
    int r = av_write_trailer(m->oc);
    avio_flush(m->io);
    m->oc->pb = NULL;
    avformat_free_context(m->oc);
    av_freep(&m->io->buffer);
    avio_context_free(&m->io);
    free(m);
    return r;
}

// ---- remontar ------------------------------------------------------------------------------
int64_t mp4_remonta(int fd_entrada, int fd_saida, int *parcial, char *erro, int n_erro) {
    AVFormatContext *ic = NULL, *oc = NULL;
    AVIOContext *ii = NULL, *oi = NULL;
    AVPacket *p = NULL;
    int fe = fd_entrada, fs = fd_saida;
    int64_t pacotes = 0;
    int r;
    ii = avio_alloc_context(av_malloc(1 << 16), 1 << 16, 0, &fe, le, NULL, busca);
    ic = avformat_alloc_context();
    if (!ii || !ic) { r = AVERROR(ENOMEM); goto fim; }
    ic->pb = ii;
    if ((r = avformat_open_input(&ic, NULL, av_find_input_format("mov"), NULL)) < 0) goto fim;
    if ((r = avformat_find_stream_info(ic, NULL)) < 0) goto fim;
    if ((r = avformat_alloc_output_context2(&oc, NULL, "mp4", NULL)) < 0) goto fim;
    oi = avio_alloc_context(av_malloc(1 << 16), 1 << 16, 1, &fs, NULL, escreve, busca);
    if (!oi) { r = AVERROR(ENOMEM); goto fim; }
    oc->pb = oi;
    for (unsigned i = 0; i < ic->nb_streams; i++) {
        AVStream *o = avformat_new_stream(oc, NULL);
        if (!o || (r = avcodec_parameters_copy(o->codecpar, ic->streams[i]->codecpar)) < 0) {
            r = o ? r : AVERROR(ENOMEM);
            goto fim;
        }
        o->codecpar->codec_tag = 0;
        o->time_base = ic->streams[i]->time_base;
        // O idioma e a faixa padrão de cada fluxo (o DVD tem várias faixas de som; a revisão do
        // código, 13): a remontagem não pode perdê-los.
        av_dict_copy(&o->metadata, ic->streams[i]->metadata, 0);
        o->disposition = ic->streams[i]->disposition;
    }
    if ((r = avformat_write_header(oc, NULL)) < 0) goto fim;
    p = av_packet_alloc();
    int lido;
    *parcial = 0;
    while ((lido = av_read_frame(ic, p)) >= 0) {
        if (p->flags & AV_PKT_FLAG_CORRUPT) { av_packet_unref(p); continue; }  // o último, cortado
        AVStream *is = ic->streams[p->stream_index], *os = oc->streams[p->stream_index];
        av_packet_rescale_ts(p, is->time_base, os->time_base);
        p->pos = -1;
        if (av_interleaved_write_frame(oc, p) >= 0) pacotes++;
        av_packet_unref(p);
    }
    if (lido != AVERROR_EOF) *parcial = 1;
    r = av_write_trailer(oc);
    avio_flush(oi);
fim:
    if (r < 0 && erro) av_strerror(r, erro, (size_t)n_erro);
    av_packet_free(&p);
    if (ic) { avformat_close_input(&ic); }
    if (ii) { av_freep(&ii->buffer); avio_context_free(&ii); }
    if (oc) { oc->pb = NULL; avformat_free_context(oc); }
    if (oi) { av_freep(&oi->buffer); avio_context_free(&oi); }
    return r < 0 ? r : pacotes;
}
