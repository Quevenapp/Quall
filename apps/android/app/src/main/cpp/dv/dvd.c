// O DVD para MP4 (ver dvd.h). LGPL: só chama a libavformat/libavcodec dinâmicas.
#include "dvd.h"

#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "desentrelaca.h"

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "QuallDvd", __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, "QuallDvd", __VA_ARGS__)
#else
#define LOGI(...) (fprintf(stderr, "QuallDvd: " __VA_ARGS__), fputc('\n', stderr))
#define LOGW(...) (fprintf(stderr, "QuallDvd (aviso): " __VA_ARGS__), fputc('\n', stderr))
#endif

// A fila (§2.2): 8 MB à frente do demuxer, e 1 MB já lido guardado para as voltas curtas que o
// `mpegps` dá no AVIO (`avio_seek` para trás no começo de um PES, `ffio_ensure_seekback`).
#define FILA (8 << 20)
#define HIST (1 << 20)
#define CAP_ANEL (FILA + HIST)  // múltiplo de 2048: um setor nunca dá a volta no anel
#define MAX_CELULAS 4096
#define MAX_QUADROS 32
#define TAXA 48000
#define MASCARA33 ((1LL << 33) - 1)
// A âncora do som: um desvio de até 40 ms entre o PTS e a contagem de amostras é tolerado (o
// arredondamento dos PTS); além disso vira silêncio (buraco) ou corte (sobreposição).
#define TOLERANCIA (TAXA / 25)
// A faixa que ficou mais de 1 s atrás do vídeo (não apareceu, ou sumiu) recebe silêncio até lá: os
// AAC de todas as faixas andam juntos, e o MP4 abre (ele espera o formato de todas).
#define ATRASO_MAXIMO TAXA
// O salto (a revisão do código, 5): um vídeo que pula mais de 10 s para a frente é descontinuidade
// (um PTS ruim, uma célula com acumulado errado): a linha do tempo é rebaseada, em vez de encher o
// arquivo de silêncio e de um quadro parado. O som que pula mais que isso segue contínuo.
#define MAX_SALTO_90K (10LL * 90000)
#define MAX_SALTO_AMOSTRAS (10LL * TAXA)
// O maior FIFO de uma faixa (30 s): o Kotlin esvazia a cada passo; mais que isso é defeito.
#define MAX_FIFO (30 * TAXA)
// A costura das células (o defeito do A07, 28/09): o primeiro quadro com PTS de cada célula é
// colado no fim da anterior quando a diferença é de até 5 s — o acumulado do IFO (o C_PBTM em BCD)
// diverge do conteúdo (medido: ~0,1 %, o timecode de 30 quadros contra os 29,97), e a célula do
// DVD-Video é contínua por construção. Além de 5 s, vale o acumulado (e o salto de 10 s acima).
#define MAX_COSTURA_90K (5LL * 90000)
// O som nunca é cortado em massa: atrasado mais que 1 s, ele é rebaseado (segue contínuo).
#define MAX_CORTE (TAXA)
// O som de uma célula espera o vídeo dela ser costurado (até 3 s), para usar a mesma base.
#define MAX_PENDENTE (3 * TAXA)
// Uma faixa sem dado há mais de 2 s de vídeo é ausente, e recebe silêncio (as AAC andam juntas).
#define AUSENTE_90K (2LL * 90000)
// As correções guardadas para a mediana do diário.
#define MAX_CORRECOES 65536
// O meia-banda do LPCM a 96 kHz (a revisão, 12): 2 x 31 + 1 coeficientes, Blackman.
#define HB_M 31

typedef struct {
    int64_t pos, acum;
    int64_t s_ptm;
    int tem_s;  // 0: ainda não; 1: sabido (NAV ou o primeiro PTS); -1: o primeiro setor não era NAV
    int nav;    // o s_ptm veio do NAV
    // a costura e o diário (só a thread da conversão escreve)
    int colada;          // o primeiro quadro com PTS dela já passou
    int64_t base;        // o ajuste da célula (saída − mapeado), o do som dela
    int64_t costura;     // quanto a costura mexeu (90 kHz; + o acumulado era curto)
    int64_t v_pts0, a_pts0;   // o primeiro PTS cru de vídeo e de som (-1: nenhum)
    int64_t to0, to_fim;      // o primeiro quadro e o fim do último na saída
    int64_t quadros, corrigidos, soma_correcoes, silencio, cortadas, rebaseados;
} Celula;

typedef struct {
    int id;             // o substream (0x80+n, 0xA0+n, 0x1C0+n)
    int st;             // o índice do fluxo no demuxer, ou -1
    AVCodecContext *ctx;
    int avisou_canais, avisou_taxa, falhas;
    // o meia-banda (96 kHz), estéreo intercalado
    float *hb;
    int hb_n, hb_cap, hb_c;
    // a saída: s16 estéreo intercalado
    int16_t *fifo;
    int f_ini, f_n, f_cap;
    int64_t escritas;   // amostras de 48 kHz já postas na saída (som e silêncio)
    int64_t silencio, cortadas, saltos, rebaseados;
    int avisou_corte;
    // o som que espera a costura da célula dele: pedaços s16 estéreo com o carimbo mapeado
    struct Pedaco { int64_t pts; int cel; int n; int16_t *a; } *pend;
    int n_pend, cap_pend;
    int64_t amostras_pend;
    int64_t ultimo_dado_90k;  // o vídeo de saída quando a faixa teve som pela última vez (-1: nunca)
    // rascunho da conversão
    float *tmp;
    int tmp_cap;
    // **Um canal só no disco** (29/09: o DVD-R do gravador de mesa do Pessoa Exemplo tem o esquerdo a −92 dB e o direito a
    // −31 dB — um cabo de áudio só na gravação): a energia de cada lado, e o espelho (0 nenhum, 1 esquerdo→direito,
    // 2 direito→esquerdo) quando um lado fica mudo 2 s com o outro vivo; desfeito se o mudo voltar a ter som.
    double e_l, e_r, cond_s;
    int espelho;
} Faixa;

typedef struct {
    int n;
    int *x0;
    int *w;  // 4 por saída, em 1/1024
} Taps;

struct Dvd {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    uint8_t *anel;
    int64_t inicio, leitura, fim;
    int fim_entrada, erro_entrada;
    Celula *cel;
    int n_cel;
    int ultima_cel;  // cache da busca

    AVFormatContext *fmt;
    AVIOContext *io;
    AVPacket *pk;
    int n_fluxos_vistos;
    int vst;  // o fluxo de vídeo, ou -1
    AVCodecContext *vctx;
    AVFrame *fila[MAX_QUADROS];
    int q_ini, q_n;
    AVFrame *livre;  // um AVFrame para receber
    int demux_acabou, terminou;
    int preparado;

    int auto_faixas, congeladas;
    int n_faixas;
    Faixa f[DVD_MAX_FAIXAS];

    Desentrelacador *des;
    int des_w, des_h;
    int tem_atual, at_w, at_h;
    int64_t ultimo_pts, ultima_dur;
    int64_t ajuste;       // saída − mapeado do vídeo agora (90 kHz): a costura, as correções, os saltos
    int64_t ajuste_base;  // o da célula em curso sem as correções de um quadro só
    int cel_video;        // a célula do último quadro entregue (-1: nenhum)
    int32_t *correcoes;
    int n_correcoes;
    int64_t maior_correcao;
    int tem_ultimo;
    DvdInfo info;

    // a escala do atual para o destino (em cache para a última geometria)
    int esc_W, esc_H, esc_w, esc_h;
    Taps ty_x, ty_y, tc_x, tc_y;
    int16_t *esc_tmp;
    size_t esc_tmp_cap;

    // contadores (ver dvd_contadores)
    int64_t c_setores, c_fora_do_formato, c_zerados, c_navs, c_navs_invalidos, c_quadros_decod,
        c_quadros_entregues, c_entrelacados, c_progressivos, c_pulldown, c_carimbos_corrigidos,
        c_quadros_antes_do_zero, c_falhas_video, c_pacotes_sem_faixa, c_voltas_no_anel,
        c_bob_pontos, c_descontinuidades;
};

static float g_hb[2 * HB_M + 1];
static pthread_once_t g_hb_uma = PTHREAD_ONCE_INIT;

static void hb_inicia(void) {
    double soma = 0;
    for (int k = -HB_M; k <= HB_M; k++) {
        double x = k / 2.0;
        double s = k == 0 ? 1.0 : sin(M_PI * x) / (M_PI * x);
        double t = (double)(k + HB_M) / (2 * HB_M);
        double w = 0.42 - 0.5 * cos(2 * M_PI * t) + 0.08 * cos(4 * M_PI * t);
        g_hb[k + HB_M] = (float)(0.5 * s * w);
        soma += g_hb[k + HB_M];
    }
    for (int k = 0; k < 2 * HB_M + 1; k++) g_hb[k] = (float)(g_hb[k] / soma);  // ganho 1 no DC
}

// ---------------------------------------------------------------------------------- o setor
static inline uint32_t rb32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static inline int rb16(const uint8_t *p) { return p[0] << 8 | p[1]; }

// Os fluxos sem o cabeçalho estendido do PES (sem o campo de cifragem): o program stream map, o
// padding, o private stream 2 (o NAV), ECM/EMM, o diretório, o DSM-CC e o H.222.1 tipo E.
static int sem_cabecalho_estendido(int id) {
    return id == 0xBC || id == 0xBE || id == 0xBF || id == 0xF0 || id == 0xF1 || id == 0xF2 ||
           id == 0xF8 || id == 0xFF;
}

int dvd_confere_setor(uint8_t *s, int *nav, uint32_t *s_ptm) {
    *nav = 0;
    int zero = 1;
    for (int i = 0; i < DVD_SETOR; i++) if (s[i]) { zero = 0; break; }
    if (zero) return 3;
    int off;
    if (rb32(s) != 0x1BA) {
        // Não começa com o pack: o setor inteiro sai zerado (o demuxer acharia um PES no meio dele
        // sem que o campo de cifragem tivesse sido conferido).
        memset(s, 0, DVD_SETOR);
        return 2;
    }
    if ((s[4] & 0xC0) == 0x40) off = 14 + (s[13] & 7);   // MPEG-2
    else if ((s[4] & 0xF0) == 0x20) off = 12;            // MPEG-1
    else { memset(s, 0, DVD_SETOR); return 2; }
    int fora = 0;
    while (off + 6 <= DVD_SETOR) {
        if (s[off] != 0 || s[off + 1] != 0 || s[off + 2] != 1 || s[off + 3] < 0xBB) {
            // A cadeia de PES quebrou antes do fim do setor: o resto sai zerado.
            memset(s + off, 0, (size_t)(DVD_SETOR - off));
            fora = 1;
            break;
        }
        int id = s[off + 3], len = rb16(s + off + 4);
        const uint8_t *p = s + off + 6;
        // Suspeitos (a revisão do código, 6): o PES sem tamanho (não existe no DVD, e esconderia o
        // resto do setor), e o cabeçalho encostado no fim, sem o byte do campo de cifragem. O resto
        // sai zerado.
        if (len == 0 || (off + 6 == DVD_SETOR && !sem_cabecalho_estendido(id) && id != 0xBB)) {
            memset(s + off, 0, (size_t)(DVD_SETOR - off));
            fora = 1;
            break;
        }
        if (id == 0xBF && nav && len >= 0x15 && off + 6 + 0x15 <= DVD_SETOR && p[0] == 0x00) {
            // O PCI do NAV pack (o `vobu_s_ptm` em 0x0D do dado, o `vobu_e_ptm` em 0x11); válido só
            // se o fim vem depois do começo (o NAV zerado do muxer `dvd` do FFmpeg não é).
            uint32_t s0 = rb32(p + 0x0D), e0 = rb32(p + 0x11);
            if (e0 > s0) { *nav = 1; *s_ptm = s0; }
            else *nav = -1;
        } else if (!sem_cabecalho_estendido(id) && id != 0xBB) {
            // O cabeçalho estendido do PES (MPEG-2) começa com '10'; o campo de cifragem são os
            // dois bits seguintes. Um PES no estilo MPEG-1 não tem o campo (e o CSS não existe nele).
            if (off + 6 < DVD_SETOR && (p[0] & 0xC0) == 0x80 && ((p[0] >> 4) & 3) != 0) return 1;
        }
        off += 6 + len;
    }
    // Uma sobra de menos de 6 bytes depois do último PES (não cabe um cabeçalho): zerada se não é.
    if (!fora && off < DVD_SETOR) {
        for (int i = off; i < DVD_SETOR; i++)
            if (s[i]) { memset(s + off, 0, (size_t)(DVD_SETOR - off)); fora = 1; break; }
    }
    return fora ? 2 : 0;
}

// ------------------------------------------------------------------------------------ a fila
static Celula *celula_de(Dvd *d, int64_t pos) {
    // chamada com d->mu
    int i = d->ultima_cel;
    if (i >= d->n_cel) i = d->n_cel - 1;
    while (i > 0 && d->cel[i].pos > pos) i--;
    while (i + 1 < d->n_cel && d->cel[i + 1].pos <= pos) i++;
    d->ultima_cel = i;
    return &d->cel[i];
}

Dvd *dvd_novo(const int *faixas, int n_faixas) {
    pthread_once(&g_hb_uma, hb_inicia);
    Dvd *d = calloc(1, sizeof(Dvd));
    if (!d) return NULL;
    pthread_mutex_init(&d->mu, NULL);
    pthread_cond_init(&d->cv, NULL);
    d->anel = malloc(CAP_ANEL);
    d->cel = calloc(MAX_CELULAS, sizeof(Celula));
    d->pk = av_packet_alloc();
    d->livre = av_frame_alloc();
    if (!d->anel || !d->cel || !d->pk || !d->livre) { dvd_libera(d); return NULL; }
    // A célula implícita (a D1 sem IFO): no byte 0, acumulado 0; a primeira `dvd_celula` a troca.
    d->n_cel = 1;
    d->cel[0].v_pts0 = d->cel[0].a_pts0 = -1;
    d->vst = -1;
    d->cel_video = -1;
    d->correcoes = malloc(sizeof(int32_t) * MAX_CORRECOES);
    if (!d->correcoes) { dvd_libera(d); return NULL; }
    d->auto_faixas = n_faixas < 0;
    if (n_faixas > DVD_MAX_FAIXAS) n_faixas = DVD_MAX_FAIXAS;
    for (int i = 0; i < DVD_MAX_FAIXAS; i++) d->f[i].ultimo_dado_90k = -1;
    for (int i = 0; i < n_faixas; i++) { d->f[i].id = faixas[i]; d->f[i].st = -1; }
    d->n_faixas = n_faixas < 0 ? 0 : n_faixas;
    d->congeladas = !d->auto_faixas;
    return d;
}

int dvd_celula(Dvd *d, int64_t pos, int64_t acumulado90k) {
    pthread_mutex_lock(&d->mu);
    int r = 0;
    if (pos % DVD_SETOR) r = DVD_ERRO_POSICAO;
    else if (pos == 0 && d->n_cel == 1 && d->fim == 0) {
        d->cel[0] = (Celula){.pos = 0, .acum = acumulado90k, .v_pts0 = -1, .a_pts0 = -1};
    } else if (d->n_cel >= MAX_CELULAS || pos <= d->cel[d->n_cel - 1].pos || pos < d->fim) {
        r = DVD_ERRO_CELULAS;
    } else {
        d->cel[d->n_cel++] = (Celula){.pos = pos, .acum = acumulado90k, .v_pts0 = -1, .a_pts0 = -1};
    }
    pthread_mutex_unlock(&d->mu);
    return r;
}

int dvd_empurrar(Dvd *d, const uint8_t *dados, int n, int64_t pos) {
    if (n <= 0 || n % DVD_SETOR || n > FILA / 4) return DVD_ERRO_POSICAO;
    pthread_mutex_lock(&d->mu);
    if (pos != d->fim) { pthread_mutex_unlock(&d->mu); return DVD_ERRO_POSICAO; }
    for (;;) {
        if (d->erro_entrada) { int e = d->erro_entrada; pthread_mutex_unlock(&d->mu); return e; }
        int64_t base = d->leitura - HIST > d->inicio ? d->leitura - HIST : d->inicio;
        if (d->fim + n - base <= CAP_ANEL) break;
        pthread_cond_wait(&d->cv, &d->mu);
    }
    if (d->fim + n - d->inicio > CAP_ANEL) d->inicio = d->fim + n - CAP_ANEL;
    pthread_mutex_unlock(&d->mu);

    // Fora da trava: só esta thread escreve em [fim, fim + n), e ninguém lê ali antes de `fim` andar.
    for (int k = 0; k < n; k += DVD_SETOR) {
        int64_t p = pos + k;
        uint8_t *s = d->anel + (size_t)(p % CAP_ANEL);
        memcpy(s, dados + k, DVD_SETOR);
        int nav = 0;
        uint32_t s_ptm = 0;
        int r = dvd_confere_setor(s, &nav, &s_ptm);
        if (r == 1) {
            LOGW("setor cifrado no byte %lld do título (setor %lld): a conversão para (§2.1)",
                 (long long)p, (long long)(p / DVD_SETOR));
            dvd_abortar(d, DVD_ERRO_CIFRADO);
            return DVD_ERRO_CIFRADO;
        }
        d->c_setores++;
        if (r == 2) d->c_fora_do_formato++;
        if (r == 3) d->c_zerados++;
        if (nav > 0) d->c_navs++;
        if (nav < 0) d->c_navs_invalidos++;
        pthread_mutex_lock(&d->mu);
        Celula *c = celula_de(d, p);
        if (c->pos == p && c->tem_s == 0) {
            // O primeiro setor da célula: o NAV dela, ou o PTS do primeiro pacote (tem_s = -1).
            if (nav > 0) { c->s_ptm = s_ptm; c->tem_s = 1; c->nav = 1; }
            else c->tem_s = -1;
        }
        pthread_mutex_unlock(&d->mu);
    }
    pthread_mutex_lock(&d->mu);
    d->fim += n;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    return 0;
}

void dvd_fim_da_entrada(Dvd *d) {
    pthread_mutex_lock(&d->mu);
    d->fim_entrada = 1;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
}

void dvd_abortar(Dvd *d, int erro) {
    pthread_mutex_lock(&d->mu);
    if (!d->erro_entrada) d->erro_entrada = erro ? erro : DVD_ERRO_CANCELADO;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
}

static int le_anel(void *op, uint8_t *buf, int n) {
    Dvd *d = op;
    pthread_mutex_lock(&d->mu);
    while (d->leitura >= d->fim && !d->fim_entrada && !d->erro_entrada) pthread_cond_wait(&d->cv, &d->mu);
    if (d->erro_entrada) { pthread_mutex_unlock(&d->mu); return AVERROR_EXIT; }
    if (d->leitura >= d->fim) { pthread_mutex_unlock(&d->mu); return AVERROR_EOF; }
    int64_t disp = d->fim - d->leitura;
    if (n > disp) n = (int)disp;
    int64_t de = d->leitura;
    pthread_mutex_unlock(&d->mu);
    size_t i = (size_t)(de % CAP_ANEL);
    size_t a = (size_t)n <= CAP_ANEL - i ? (size_t)n : CAP_ANEL - i;
    memcpy(buf, d->anel + i, a);
    if (a < (size_t)n) memcpy(buf + a, d->anel, (size_t)n - a);
    pthread_mutex_lock(&d->mu);
    d->leitura = de + n;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    return n;
}

static int64_t busca_anel(void *op, int64_t pos, int de_onde) {
    Dvd *d = op;
    if (de_onde & AVSEEK_SIZE) return AVERROR(ENOSYS);
    de_onde &= ~AVSEEK_FORCE;
    pthread_mutex_lock(&d->mu);
    if (de_onde == SEEK_CUR) pos += d->leitura;
    else if (de_onde != SEEK_SET) { pthread_mutex_unlock(&d->mu); return AVERROR(ENOSYS); }
    while (pos > d->fim && !d->fim_entrada && !d->erro_entrada) pthread_cond_wait(&d->cv, &d->mu);
    if (pos < d->inicio || pos > d->fim) { pthread_mutex_unlock(&d->mu); return AVERROR(EPIPE); }
    if (pos < d->leitura) d->c_voltas_no_anel++;
    d->leitura = pos;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    return pos;
}

// ------------------------------------------------------------------------------ os carimbos
// O PTS (90 kHz, 33 bits) do pacote em `pos` no tempo de saída.
// `video`: o pacote é do vídeo. Sem NAV válido no primeiro setor da célula, **só o vídeo** ancora
// (o primeiro PTS de vídeo nela é o começo; a revisão do código, 14): o som que chega antes, sem
// âncora, sai sem carimbo (segue contínuo).
static int64_t mapeia(Dvd *d, int64_t pos, int64_t pts, int video, int *cel) {
    pthread_mutex_lock(&d->mu);
    Celula *c = celula_de(d, pos < 0 ? 0 : pos);
    *cel = (int)(c - d->cel);
    if (pts == AV_NOPTS_VALUE) { pthread_mutex_unlock(&d->mu); return pts; }
    if (video && c->v_pts0 < 0) c->v_pts0 = pts & MASCARA33;
    if (!video && c->a_pts0 < 0) c->a_pts0 = pts & MASCARA33;
    if (c->tem_s <= 0) {
        if (!video) { pthread_mutex_unlock(&d->mu); return AV_NOPTS_VALUE; }
        c->s_ptm = pts & MASCARA33;
        c->tem_s = 1;
    }
    int64_t dif = (pts - c->s_ptm) & MASCARA33;
    if (dif >= (1LL << 32)) dif -= 1LL << 33;
    int64_t r = c->acum + dif;
    pthread_mutex_unlock(&d->mu);
    return r;
}

// ----------------------------------------------------------------------------------- o som
static int fifo_cabe(Faixa *f, int n) {
    if (f->f_ini + f->f_n + n <= f->f_cap) return 0;
    if (f->f_ini > 0) {
        memmove(f->fifo, f->fifo + 2 * (size_t)f->f_ini, (size_t)f->f_n * 4);
        f->f_ini = 0;
        if (f->f_n + n <= f->f_cap) return 0;
    }
    if (f->f_n + n > MAX_FIFO) {
        LOGW("faixa 0x%x: o som acumulado passaria de %d s; recusado", f->id, MAX_FIFO / TAXA);
        return DVD_ERRO_MEMORIA;
    }
    int cap = f->f_cap ? f->f_cap : 16384;
    while (cap < f->f_n + n) cap *= 2;
    int16_t *novo = realloc(f->fifo, (size_t)cap * 4);
    if (!novo) return DVD_ERRO_MEMORIA;
    f->fifo = novo;
    f->f_cap = cap;
    return 0;
}

static int fifo_silencio(Faixa *f, int64_t n) {
    while (n > 0) {
        int k = n > TAXA ? TAXA : (int)n;
        if (fifo_cabe(f, k) < 0) return DVD_ERRO_MEMORIA;
        memset(f->fifo + 2 * (size_t)(f->f_ini + f->f_n), 0, (size_t)k * 4);
        f->f_n += k;
        f->escritas += k;
        f->silencio += k;
        n -= k;
    }
    return 0;
}

static inline int16_t s16(float v) {
    float x = v * 32768.0f;
    return x >= 32767.0f ? 32767 : x <= -32768.0f ? -32768 : (int16_t)lrintf(x);
}

// Uma amostra do canal `c` do quadro, em float.
static inline float amostra(const AVFrame *fr, int c, int i) {
    int nc = fr->ch_layout.nb_channels;
    switch (fr->format) {
    case AV_SAMPLE_FMT_S16: return ((const int16_t *)fr->data[0])[i * nc + c] / 32768.0f;
    case AV_SAMPLE_FMT_S16P: return ((const int16_t *)fr->data[c])[i] / 32768.0f;
    case AV_SAMPLE_FMT_S32: return ((const int32_t *)fr->data[0])[i * nc + c] / 2147483648.0f;
    case AV_SAMPLE_FMT_S32P: return ((const int32_t *)fr->data[c])[i] / 2147483648.0f;
    case AV_SAMPLE_FMT_FLT: return ((const float *)fr->data[0])[i * nc + c];
    case AV_SAMPLE_FMT_FLTP: return ((const float *)fr->data[c])[i];
    default: return 0;
    }
}

// O quadro decodificado da faixa, em estéreo 48 kHz s16, ancorado pelo carimbo `pts` (90 kHz, no
// tempo de saída; AV_NOPTS_VALUE: continua do anterior).
static int som_do_quadro(Dvd *d, Faixa *f, const AVFrame *fr, int64_t pts, int cel) {
    (void)d;
    int nc = fr->ch_layout.nb_channels, n = fr->nb_samples, taxa = fr->sample_rate;
    if (nc < 1 || n <= 0) return 0;
    if (taxa != 48000 && taxa != 96000) {
        if (!f->avisou_taxa++) LOGW("faixa 0x%x: %d Hz (o DVD só tem 48 e 96 kHz); a faixa sai em silêncio", f->id, taxa);
        return 0;
    }
    if (nc > 2 && !f->avisou_canais++)
        LOGW("faixa 0x%x: %d canais depois do decodificador; só os dois primeiros", f->id, nc);
    // 1. Estéreo em float (mono vira os dois lados).
    int cap = n + 2 * HB_M + 2;
    if (f->tmp_cap < cap) {
        float *t = realloc(f->tmp, (size_t)cap * 2 * sizeof(float));
        if (!t) return DVD_ERRO_MEMORIA;
        f->tmp = t; f->tmp_cap = cap;
    }
    float *st = f->tmp;
    int m = 0;
    if (taxa == 48000) {
        for (int i = 0; i < n; i++) {
            float l = amostra(fr, 0, i), r = nc > 1 ? amostra(fr, 1, i) : l;
            st[2 * m] = l; st[2 * m + 1] = r; m++;
        }
    } else {
        // 96 kHz: o meia-banda e a dizimação 2:1. O buffer começa com HB_M zeros (fase zero).
        if (f->hb_cap < f->hb_n + n) {
            int c2 = f->hb_n + n + 2 * HB_M + 1024;
            float *h = realloc(f->hb, (size_t)c2 * 2 * sizeof(float));
            if (!h) return DVD_ERRO_MEMORIA;
            if (!f->hb) { memset(h, 0, (size_t)HB_M * 2 * sizeof(float)); f->hb_n = HB_M; f->hb_c = HB_M; }
            f->hb = h; f->hb_cap = c2;
        }
        for (int i = 0; i < n; i++) {
            float l = amostra(fr, 0, i), r = nc > 1 ? amostra(fr, 1, i) : l;
            f->hb[2 * f->hb_n] = l; f->hb[2 * f->hb_n + 1] = r; f->hb_n++;
        }
        while (f->hb_c + HB_M < f->hb_n) {
            const float *x = f->hb + 2 * (size_t)(f->hb_c - HB_M);
            float l = 0, r = 0;
            for (int k = 0; k < 2 * HB_M + 1; k += 1) {
                float w = g_hb[k];
                if (w == 0.0f) continue;
                l += w * x[2 * k]; r += w * x[2 * k + 1];
            }
            st[2 * m] = l; st[2 * m + 1] = r; m++;
            f->hb_c += 2;
        }
        int descarta = f->hb_c - HB_M;
        if (descarta > 0) {
            memmove(f->hb, f->hb + 2 * (size_t)descarta, (size_t)(f->hb_n - descarta) * 2 * sizeof(float));
            f->hb_n -= descarta;
            f->hb_c -= descarta;
        }
    }
    // 1b. Um canal só: a energia média de cada lado (janela de ~2 s) e o espelho.
    if (m > 0) {
        double sl = 0, sr = 0;
        for (int i = 0; i < m; i++) { sl += (double)st[2 * i] * st[2 * i]; sr += (double)st[2 * i + 1] * st[2 * i + 1]; }
        sl /= m; sr /= m;
        double al = (double)m / (48000.0 * 2.0); if (al > 1) al = 1;
        f->e_l += al * (sl - f->e_l); f->e_r += al * (sr - f->e_r);
        const double MUDO = 1e-7, VIVO = 1e-5, VOLTOU = 1e-6;   // −70, −50 e −60 dBFS
        int mudo_l = f->e_l < MUDO && f->e_r > VIVO, mudo_r = f->e_r < MUDO && f->e_l > VIVO;
        if (f->espelho == 0) {
            if (mudo_l || mudo_r) f->cond_s += m / 48000.0; else f->cond_s = 0;
            if (f->cond_s >= 2.0) {
                f->espelho = mudo_r ? 1 : 2;
                LOGI("faixa 0x%x: o canal %s está mudo e o %s tem som (%.0f × %.0f dBFS): o vivo vai aos dois lados",
                     f->id, mudo_r ? "direito" : "esquerdo", mudo_r ? "esquerdo" : "direito",
                     10 * log10(f->e_l + 1e-12), 10 * log10(f->e_r + 1e-12));
            }
        } else if ((f->espelho == 1 && f->e_r > VOLTOU) || (f->espelho == 2 && f->e_l > VOLTOU)) {
            LOGI("faixa 0x%x: o canal que estava mudo voltou a ter som; o espelho sai", f->id);
            f->espelho = 0; f->cond_s = 0;
        }
        if (f->espelho == 1) for (int i = 0; i < m; i++) st[2 * i + 1] = st[2 * i];
        else if (f->espelho == 2) for (int i = 0; i < m; i++) st[2 * i] = st[2 * i + 1];
    }
    // 2. O pedaço espera a costura da célula dele (a base do som é a do vídeo da mesma célula).
    if (m <= 0) return 0;
    if (f->n_pend == f->cap_pend) {
        int cap = f->cap_pend ? 2 * f->cap_pend : 64;
        struct Pedaco *np = realloc(f->pend, sizeof(*np) * (size_t)cap);
        if (!np) return DVD_ERRO_MEMORIA;
        f->pend = np; f->cap_pend = cap;
    }
    int16_t *a = malloc((size_t)m * 4);
    if (!a) return DVD_ERRO_MEMORIA;
    for (int i = 0; i < 2 * m; i++) a[i] = s16(st[i]);
    f->pend[f->n_pend++] = (struct Pedaco){pts, cel, m, a};
    f->amostras_pend += m;
    return 0;
}

// A base do som da célula `c`: a do vídeo dela (a costura); a célula ainda não vista pelo vídeo usa
// a de agora (só quando forçado).
static int64_t base_do_som(const Dvd *d, int c) {
    if (c < 0 || c >= d->n_cel) return d->ajuste_base;
    if (d->cel[c].colada) return d->cel[c].base;
    return d->ajuste_base;
}

// Um pedaço na saída, pelo carimbo mapeado + a base da célula. O som nunca é cortado em massa: ±40 ms
// é o arredondamento; até 10 s adiantado, silêncio; atrasado até 1 s, corte; além disso, rebaseado
// (segue contínuo, e conta).
static int posiciona(Dvd *d, Faixa *f, struct Pedaco *pd) {
    int ini = 0, m = pd->n;
    Celula *c = pd->cel >= 0 && pd->cel < d->n_cel ? &d->cel[pd->cel] : NULL;
    if (pd->pts != AV_NOPTS_VALUE) {
        int64_t esperado = (pd->pts + base_do_som(d, pd->cel)) * TAXA / 90000;
        int64_t dif = esperado - f->escritas;
        if (dif > MAX_SALTO_AMOSTRAS) {
            if (!f->saltos++) LOGW("faixa 0x%x: salto de %lld s no carimbo; o som segue contínuo", f->id, (long long)(dif / TAXA));
        } else if (dif > TOLERANCIA) {
            int r = fifo_silencio(f, dif);
            if (r < 0) return r;
            if (c) c->silencio += dif;
        } else if (dif < -MAX_CORTE) {
            if (!f->rebaseados++) LOGW("faixa 0x%x: o som chegou %.2f s atrás do lugar; rebaseado (segue contínuo), "
                                       "em vez de cortado", f->id, -dif / (double)TAXA);
            if (c) c->rebaseados++;
        } else if (dif < -TOLERANCIA) {
            ini = -dif > m ? m : (int)-dif;
            f->cortadas += ini;
            if (c) c->cortadas += ini;
            if (!f->avisou_corte && f->cortadas > TAXA) {
                f->avisou_corte = 1;
                LOGW("faixa 0x%x: mais de 1 s de som cortado no título (a costura das células está errada?)", f->id);
            }
        }
    }
    int k = m - ini;
    if (k <= 0) return 0;
    if (fifo_cabe(f, k) < 0) return DVD_ERRO_MEMORIA;
    memcpy(f->fifo + 2 * (size_t)(f->f_ini + f->f_n), pd->a + 2 * (size_t)ini, (size_t)k * 4);
    f->f_n += k;
    f->escritas += k;
    return 0;
}

// Solta o som que já pode ir: o da célula que o vídeo já costurou (ou já passou), o sem carimbo ou
// sem célula; tudo quando `forcar` (o fim) ou quando espera mais de 3 s (som sem vídeo).
static int libera_som(Dvd *d, Faixa *f, int forcar) {
    int feitos = 0, r = 0;
    while (feitos < f->n_pend) {
        struct Pedaco *pd = &f->pend[feitos];
        int pode = forcar || f->amostras_pend > MAX_PENDENTE || pd->cel < 0 || pd->cel >= d->n_cel ||
                   d->cel[pd->cel].colada || pd->cel < d->cel_video;
        if (!pode) break;
        r = posiciona(d, f, pd);
        f->amostras_pend -= pd->n;
        free(pd->a);
        feitos++;
        if (r < 0) break;
    }
    if (feitos) {
        memmove(f->pend, f->pend + feitos, sizeof(*f->pend) * (size_t)(f->n_pend - feitos));
        f->n_pend -= feitos;
    }
    return r;
}

static int abre_faixa(Dvd *d, Faixa *f, int st) {
    enum AVCodecID id;
    if (f->id >= 0x80 && f->id <= 0x87) id = AV_CODEC_ID_AC3;
    else if (f->id >= 0xA0 && f->id <= 0xA7) id = AV_CODEC_ID_PCM_DVD;
    else if (f->id >= 0x1C0 && f->id <= 0x1C7) id = AV_CODEC_ID_MP2;
    else return -1;
    const AVCodec *c = avcodec_find_decoder(id);
    if (!c) { LOGW("sem o decodificador de som %s", avcodec_get_name(id)); return -1; }
    f->ctx = avcodec_alloc_context3(c);
    if (!f->ctx) return DVD_ERRO_MEMORIA;
    AVDictionary *op = NULL;
    // O AC-3 5.1 sai estéreo pelo próprio decodificador (com os níveis de centro e surround do
    // fluxo); os outros ignoram a opção.
    if (id == AV_CODEC_ID_AC3) av_dict_set(&op, "downmix", "stereo", 0);
    f->ctx->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
    int r = avcodec_open2(f->ctx, c, &op);
    av_dict_free(&op);
    if (r < 0) { avcodec_free_context(&f->ctx); LOGW("faixa 0x%x: o decodificador não abriu (%d)", f->id, r); return -1; }
    f->st = st;
    d->fmt->streams[st]->discard = AVDISCARD_DEFAULT;
    LOGI("faixa 0x%x: %s no fluxo %d", f->id, avcodec_get_name(id), st);
    return 0;
}

static int eh_som_do_dvd(int id) {
    return (id >= 0x80 && id <= 0x87) || (id >= 0xA0 && id <= 0xA7) || (id >= 0x1C0 && id <= 0x1C7);
}

// Os fluxos que o `mpegps` criou desde a última volta: o vídeo, as faixas pedidas; o resto é
// descartado (o demuxer pula os pacotes deles).
static int novos_fluxos(Dvd *d) {
    for (unsigned i = (unsigned)d->n_fluxos_vistos; i < d->fmt->nb_streams; i++) {
        AVStream *st = d->fmt->streams[i];
        int usado = 0;
        if (st->id == 0x1E0 && d->vst < 0) {
            const AVCodec *c = avcodec_find_decoder(AV_CODEC_ID_MPEG2VIDEO);
            d->vctx = c ? avcodec_alloc_context3(c) : NULL;
            if (!d->vctx) return DVD_ERRO_VIDEO;
            d->vctx->thread_count = 2;
            d->vctx->thread_type = FF_THREAD_SLICE;
            d->vctx->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
            if (avcodec_open2(d->vctx, c, NULL) < 0) return DVD_ERRO_VIDEO;
            d->vst = (int)i;
            usado = 1;
        } else if (eh_som_do_dvd(st->id)) {
            for (int k = 0; k < d->n_faixas; k++)
                if (d->f[k].id == st->id && d->f[k].st < 0) { usado = abre_faixa(d, &d->f[k], (int)i) == 0; break; }
            if (!usado && !d->congeladas && d->n_faixas < DVD_MAX_FAIXAS) {
                Faixa *f = &d->f[d->n_faixas];
                f->id = st->id;
                if (abre_faixa(d, f, (int)i) == 0) { d->n_faixas++; usado = 1; }
                else f->id = 0;
            }
        }
        if (!usado) st->discard = AVDISCARD_ALL;
    }
    d->n_fluxos_vistos = (int)d->fmt->nb_streams;
    return 0;
}

static Faixa *faixa_do_fluxo(Dvd *d, int st) {
    for (int k = 0; k < d->n_faixas; k++) if (d->f[k].st == st) return &d->f[k];
    return NULL;
}

static int recebe_som(Dvd *d, Faixa *f) {
    for (;;) {
        int r = avcodec_receive_frame(f->ctx, d->livre);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
        if (r < 0) { f->falhas++; return 0; }
        int cel = (int)(intptr_t)d->livre->opaque - 1;
        r = som_do_quadro(d, f, d->livre, d->livre->pts, cel);
        av_frame_unref(d->livre);
        if (r < 0) return r;
        f->ultimo_dado_90k = d->tem_ultimo ? d->ultimo_pts : 0;
        if ((r = libera_som(d, f, 0)) < 0) return r;
    }
}

static int recebe_video(Dvd *d) {
    for (;;) {
        if (d->q_n >= MAX_QUADROS) return 0;  // o resto sai na próxima volta
        int r = avcodec_receive_frame(d->vctx, d->livre);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
        if (r < 0) { d->c_falhas_video++; return 0; }
        AVFrame *q = av_frame_alloc();
        if (!q) return DVD_ERRO_MEMORIA;
        av_frame_move_ref(q, d->livre);
        d->fila[(d->q_ini + d->q_n) % MAX_QUADROS] = q;
        d->q_n++;
        d->c_quadros_decod++;
    }
}

// O fim do fluxo: os decodificadores entregam o que seguram.
static int esvazia(Dvd *d) {
    if (d->vctx) { avcodec_send_packet(d->vctx, NULL); int r = recebe_video(d); if (r < 0) return r; }
    for (int k = 0; k < d->n_faixas; k++) {
        if (!d->f[k].ctx) continue;
        avcodec_send_packet(d->f[k].ctx, NULL);
        int r = recebe_som(d, &d->f[k]);
        if (r < 0) return r;
    }
    return 0;
}

// Um pacote do demuxer. 0, 1 no fim do fluxo, ou erro.
static int avanca(Dvd *d) {
    int r = av_read_frame(d->fmt, d->pk);
    if (r < 0) {
        pthread_mutex_lock(&d->mu);
        int e = d->erro_entrada;
        pthread_mutex_unlock(&d->mu);
        if (e) return e;
        if (r == AVERROR_EOF) return 1;
        char msg[128];
        av_strerror(r, msg, sizeof msg);
        LOGW("demuxer: %s", msg);
        return DVD_ERRO_DEMUX;
    }
    r = novos_fluxos(d);
    if (r < 0) { av_packet_unref(d->pk); return r; }
    AVPacket *p = d->pk;
    if (p->stream_index == d->vst) {
        int cel;
        p->pts = mapeia(d, p->pos, p->pts, 1, &cel);
        p->dts = mapeia(d, p->pos, p->dts, 1, &cel);
        p->opaque = (void *)(intptr_t)(cel + 1);  // a célula vai com o quadro (AV_CODEC_FLAG_COPY_OPAQUE)
        if (avcodec_send_packet(d->vctx, p) < 0) d->c_falhas_video++;
        av_packet_unref(p);
        return recebe_video(d);
    }
    Faixa *f = faixa_do_fluxo(d, p->stream_index);
    if (f && f->ctx) {
        int cel;
        p->pts = mapeia(d, p->pos, p->pts, 0, &cel);
        p->dts = AV_NOPTS_VALUE;
        p->opaque = (void *)(intptr_t)(cel + 1);
        if (avcodec_send_packet(f->ctx, p) < 0) f->falhas++;
        av_packet_unref(p);
        return recebe_som(d, f);
    }
    d->c_pacotes_sem_faixa++;
    av_packet_unref(p);
    return 0;
}

int dvd_preparar(Dvd *d) {
    if (d->preparado) return 0;
    const int tam = 1 << 16;
    uint8_t *buf = av_malloc(tam);
    d->io = buf ? avio_alloc_context(buf, tam, 0, d, le_anel, NULL, busca_anel) : NULL;
    if (!d->io) { av_free(buf); return DVD_ERRO_MEMORIA; }
    d->io->seekable = 0;
    d->fmt = avformat_alloc_context();
    if (!d->fmt) return DVD_ERRO_MEMORIA;
    d->fmt->pb = d->io;
    // NOFILLIN: os carimbos saem como estão no PES. Sem ela, a libavformat inventa o PTS que falta
    // (o `cur_dts` + a duração) continuando a linha do tempo da célula anterior, e na célula nova o
    // som saía segundos fora (medido no teste de mesa, c: 4,3 s de silêncio e 4,3 s cortados no MP2).
    d->fmt->flags |= AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_NOFILLIN;
    // O demuxer `mpegps` do configure se chama "mpeg" em tempo de execução.
    const AVInputFormat *ps = av_find_input_format("mpeg");
    if (!ps) { LOGW("sem o demuxer mpegps (\"mpeg\")"); return DVD_ERRO_DEMUX; }
    int r = avformat_open_input(&d->fmt, NULL, ps, NULL);
    if (r < 0) {
        d->fmt = NULL;  // o open_input libera o contexto na falha
        pthread_mutex_lock(&d->mu);
        int e = d->erro_entrada;
        pthread_mutex_unlock(&d->mu);
        return e ? e : DVD_ERRO_DEMUX;
    }
    while (d->q_n == 0) {
        r = avanca(d);
        if (r < 0) return r;
        if (r == 1) {
            d->demux_acabou = 1;
            if ((r = esvazia(d)) < 0) return r;
            break;
        }
    }
    if (d->q_n == 0 || d->vst < 0) return DVD_ERRO_VIDEO;
    d->congeladas = 1;
    const AVFrame *q = d->fila[d->q_ini];
    DvdInfo *i = &d->info;
    i->largura = q->width;
    i->altura = q->height;
    AVRational fr = d->vctx->framerate;
    if (fr.num <= 0 || fr.den <= 0) fr = q->height % 288 == 0 || q->height % 576 == 0 ? (AVRational){25, 1} : (AVRational){30000, 1001};
    i->fps_num = fr.num;
    i->fps_den = fr.den;
    AVRational sar = q->sample_aspect_ratio;
    if (sar.num <= 0 || sar.den <= 0) sar = d->vctx->sample_aspect_ratio;
    double dar = sar.num > 0 && sar.den > 0 ? (double)q->width * sar.num / ((double)q->height * sar.den) : 4.0 / 3.0;
    i->aspecto169 = dar > 1.55;
    i->entrelacado = (q->flags & AV_FRAME_FLAG_INTERLACED) != 0;
    i->n_faixas = d->n_faixas;
    for (int k = 0; k < d->n_faixas; k++) { i->faixa_id[k] = d->f[k].id; i->faixa_visto[k] = d->f[k].st >= 0; }
    LOGI("preparado: %dx%d %d/%d, DAR %.3f (%s), %s, %d faixa(s) de som%s", i->largura, i->altura, fr.num,
         fr.den, dar, i->aspecto169 ? "16:9" : "4:3", i->entrelacado ? "entrelaçado" : "progressivo",
         i->n_faixas, d->auto_faixas ? " (modo automático, sem IFO)" : "");
    d->preparado = 1;
    return 0;
}

void dvd_info(Dvd *d, DvdInfo *i) {
    *i = d->info;
    for (int k = 0; k < d->n_faixas; k++) i->faixa_visto[k] = d->f[k].st >= 0;
}

// A faixa que ficou para trás recebe silêncio até `ate` (amostras).
// Só a faixa **ausente** (sem som há mais de 2 s de vídeo, e nada esperando): a que tem som e está
// atrás não recebe silêncio — foi esse silêncio que, somado ao corte do som que chegava depois,
// emudeceu o A07 a partir dos 1021 s (sil ≈ cort ≈ o resto do título).
static int acompanha(Dvd *d, int64_t ate) {
    for (int k = 0; k < d->n_faixas; k++) {
        Faixa *f = &d->f[k];
        if (f->escritas >= ate) continue;
        if (f->n_pend > 0) continue;
        if (f->ultimo_dado_90k >= 0 && d->tem_ultimo && d->ultimo_pts - f->ultimo_dado_90k < AUSENTE_90K) continue;
        int64_t falta = ate - f->escritas;
        if (falta > MAX_SALTO_AMOSTRAS) {
            // Não acontece com o vídeo rebaseado; se acontecer, o som não vira minutos de silêncio.
            LOGW("faixa 0x%x: %lld s atrás do vídeo; só %lld s de silêncio", f->id, (long long)(falta / TAXA),
                 (long long)(MAX_SALTO_AMOSTRAS / TAXA));
            falta = MAX_SALTO_AMOSTRAS;
        }
        int r = fifo_silencio(f, falta);
        if (r < 0) return r;
    }
    return 0;
}

int dvd_passo(Dvd *d) {
    if (!d->preparado) return DVD_ERRO_DEMUX;
    if (d->q_n > 0) return DVD_QUADRO;
    if (d->terminou) return DVD_FIM;
    if (!d->demux_acabou) {
        int r = avanca(d);
        if (r < 0) return r;
        if (r == 1) {
            d->demux_acabou = 1;
            if ((r = esvazia(d)) < 0) return r;
        } else {
            return d->q_n > 0 ? DVD_QUADRO : DVD_NADA;
        }
    }
    if (d->q_n > 0) return DVD_QUADRO;
    // O fim: o som que esperava vai, e todas as faixas até o fim do último quadro.
    for (int k = 0; k < d->n_faixas; k++) { int r = libera_som(d, &d->f[k], 1); if (r < 0) return r; }
    for (int k = 0; k < d->n_faixas; k++) d->f[k].ultimo_dado_90k = -1;
    if (d->tem_ultimo) {
        int r = acompanha(d, (d->ultimo_pts + d->ultima_dur) * TAXA / 90000);
        if (r < 0) return r;
    }
    d->terminou = 1;
    return DVD_FIM;
}

int dvd_quadro(Dvd *d, int64_t *pts90k, int64_t *dur90k) {
    while (d->q_n > 0) {
        AVFrame *q = d->fila[d->q_ini];
        d->fila[d->q_ini] = NULL;
        d->q_ini = (d->q_ini + 1) % MAX_QUADROS;
        d->q_n--;
        int w = q->width, h = q->height;
        if (q->format != AV_PIX_FMT_YUV420P || w < 16 || h < 16 || (w & 1) || (h & 3) || w > 1920 || h > 1088) {
            d->c_falhas_video++;
            av_frame_free(&q);
            continue;
        }
        AVRational fr = d->vctx->framerate;
        int64_t nominal = fr.num > 0 && fr.den > 0 ? 90000LL * fr.den / fr.num : 3003;
        int64_t dur = nominal * (2 + q->repeat_pict) / 2;
        if (q->repeat_pict) d->c_pulldown++;
        int cel = (int)(intptr_t)q->opaque - 1;
        Celula *c = cel >= 0 && cel < d->n_cel ? &d->cel[cel] : NULL;
        int64_t t;
        if (q->pts == AV_NOPTS_VALUE) {
            // Sem carimbo (o DVD que só marca o I de cada VOBU): o seguinte do anterior.
            t = d->tem_ultimo ? d->ultimo_pts + d->ultima_dur : 0;
        } else {
            int64_t tm = q->pts;
            t = tm + d->ajuste;
            if (d->tem_ultimo) {
                int64_t prox = d->ultimo_pts + d->ultima_dur;
                if (c && !c->colada) {
                    // A costura: o primeiro quadro com PTS da célula vai para o fim da anterior.
                    int64_t dif = prox - t;
                    if (dif >= -MAX_COSTURA_90K && dif <= MAX_COSTURA_90K) {
                        d->ajuste += dif;
                        d->ajuste_base += dif;
                        t = prox;
                        c->costura = dif;
                    }
                }
                if (t - prox > MAX_SALTO_90K) {
                    int64_t salto = t - prox;
                    LOGW("vídeo: salto de %.1f s no carimbo; a linha do tempo é rebaseada", salto / 90000.0);
                    d->ajuste -= salto;
                    d->ajuste_base -= salto;
                    t = prox;
                    d->c_descontinuidades++;
                } else if (t <= d->ultimo_pts) {
                    // Um quadro antes do anterior (um PTS ruim): vai logo depois dele; o ajuste guarda a
                    // diferença, e o intervalo seguinte a devolve.
                    int64_t corr = prox - t;
                    d->ajuste += corr;
                    t = prox;
                    d->c_carimbos_corrigidos++;
                    if (corr > d->maior_correcao) d->maior_correcao = corr;
                    if (d->n_correcoes < MAX_CORRECOES) d->correcoes[d->n_correcoes++] = (int32_t)(corr > INT32_MAX ? INT32_MAX : corr);
                    if (c) { c->corrigidos++; c->soma_correcoes += corr; }
                } else if (d->ajuste > d->ajuste_base && t > prox + nominal / 2) {
                    int64_t volta = t - prox;
                    if (volta > d->ajuste - d->ajuste_base) volta = d->ajuste - d->ajuste_base;
                    d->ajuste -= volta;
                    t -= volta;
                }
            }
            if (c && !c->colada) { c->colada = 1; c->base = d->ajuste_base; }
            if (c) c->base = d->ajuste_base;
        }
        if (c) {
            if (!c->quadros) c->to0 = t;
            c->to_fim = t + dur;
            c->quadros++;
        }
        if (cel >= 0 && cel > d->cel_video) d->cel_video = cel;
        if (!d->tem_ultimo && t < 0) {
            // Antes do começo do título (o GOP aberto da primeira célula): cai; meio quadro vale 0.
            if (t < -nominal / 2) { d->c_quadros_antes_do_zero++; av_frame_free(&q); continue; }
            t = 0;
        }
        if (!d->des || d->des_w != w || d->des_h != h) {
            des_libera(d->des);
            d->des = des_novo(w, h);
            d->des_w = w; d->des_h = h;
            if (!d->des) { av_frame_free(&q); return DVD_ERRO_MEMORIA; }
        }
        const uint8_t *const in[3] = {q->data[0], q->data[1], q->data[2]};
        const int is[3] = {q->linesize[0], q->linesize[1], q->linesize[2]};
        if (q->flags & AV_FRAME_FLAG_INTERLACED) {
            des_quadro(d->des, in, is, (q->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) != 0);
            d->c_entrelacados++;
            d->c_bob_pontos += des_pontos_bob(d->des);
        } else {
            des_progressivo(d->des, in, is);
            d->c_progressivos++;
        }
        av_frame_free(&q);
        d->tem_atual = 1;
        d->at_w = w; d->at_h = h;
        d->ultimo_pts = t;
        d->ultima_dur = dur;
        d->tem_ultimo = 1;
        d->c_quadros_entregues++;
        *pts90k = t;
        *dur90k = dur;
        for (int k = 0; k < d->n_faixas; k++) { int r = libera_som(d, &d->f[k], 0); if (r < 0) return r; }
        int r = acompanha(d, t * TAXA / 90000 - ATRASO_MAXIMO);
        if (r < 0) return r;
        return 1;
    }
    return 0;
}

int dvd_som(Dvd *d, int faixa, int16_t *saida, int max) {
    if (faixa < 0 || faixa >= d->n_faixas || max <= 0) return 0;
    Faixa *f = &d->f[faixa];
    int n = f->f_n < max ? f->f_n : max;
    memcpy(saida, f->fifo + 2 * (size_t)f->f_ini, (size_t)n * 4);
    f->f_ini += n;
    f->f_n -= n;
    if (!f->f_n) f->f_ini = 0;
    return n;
}

// ---------------------------------------------------------------------------------- a escala
static void taps_libera(Taps *t) { free(t->x0); free(t->w); t->x0 = t->w = NULL; t->n = 0; }

// Catmull-Rom (a = -0.5) em 1/1024.
static void pesos_cr(double f, int *w) {
    double f2 = f * f, f3 = f2 * f;
    double a = -0.5 * f3 + f2 - 0.5 * f, b = 1.5 * f3 - 2.5 * f2 + 1.0;
    double c = -1.5 * f3 + 2.0 * f2 + 0.5 * f;
    w[0] = (int)lrint(a * 1024); w[1] = (int)lrint(b * 1024); w[2] = (int)lrint(c * 1024);
    w[3] = 1024 - w[0] - w[1] - w[2];
}

// A saída i vem da fonte em a*i + b (em amostras da fonte).
static int taps_novos(Taps *t, int n, double a, double b) {
    taps_libera(t);
    t->x0 = malloc(sizeof(int) * (size_t)n);
    t->w = malloc(sizeof(int) * 4 * (size_t)n);
    if (!t->x0 || !t->w) { taps_libera(t); return -1; }
    t->n = n;
    for (int i = 0; i < n; i++) {
        double s = a * i + b;
        int base = (int)floor(s);
        t->x0[i] = base;
        pesos_cr(s - base, t->w + 4 * i);
    }
    return 0;
}

static inline uint8_t sat8(int v) { return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }

// Um plano: src (sw x sh, stride ss) → dst (tx.n x ty.n, stride ds, passo dp), separável.
static void reamostra(Dvd *d, const uint8_t *src, int sw, int sh, int ss, const Taps *tx, const Taps *ty,
                      uint8_t *dst, int ds, int dp) {
    int dw = tx->n, dh = ty->n;
    int16_t *tmp = d->esc_tmp;
    for (int y = 0; y < sh; y++) {
        const uint8_t *l = src + (size_t)y * ss;
        int16_t *t = tmp + (size_t)y * dw;
        for (int i = 0; i < dw; i++) {
            int b = tx->x0[i];
            const int *w = tx->w + 4 * i;
            int acc = 0;
            for (int k = 0; k < 4; k++) {
                int x = b - 1 + k;
                x = x < 0 ? 0 : x >= sw ? sw - 1 : x;
                acc += w[k] * l[x];
            }
            t[i] = (int16_t)((acc + 64) >> 7);  // em 1/8 de código
        }
    }
    for (int j = 0; j < dh; j++) {
        uint8_t *o = dst + (size_t)j * ds;
        int b = ty->x0[j];
        const int *w = ty->w + 4 * j;
        const int16_t *ls[4];
        for (int k = 0; k < 4; k++) {
            int y = b - 1 + k;
            y = y < 0 ? 0 : y >= sh ? sh - 1 : y;
            ls[k] = tmp + (size_t)y * dw;
        }
        for (int i = 0; i < dw; i++) {
            int acc = w[0] * ls[0][i] + w[1] * ls[1][i] + w[2] * ls[2][i] + w[3] * ls[3][i];
            o[(size_t)i * dp] = sat8((acc + 4096) >> 13);
        }
    }
}

int dvd_escrever(Dvd *d, uint8_t *Y, int ys, uint8_t *U, uint8_t *V, int cs, int cps, int W, int H) {
    if (!d->tem_atual) return -1;
    if (W < 16 || H < 16 || (W & 1) || (H & 1) || ys < W || (cps != 1 && cps != 2) || cs < (W / 2) * cps) return -3;
    int w = d->at_w, h = d->at_h;
    // O 4:3 do BT.601 é a área de 704: do quadro de 720 saem 8 px de cada lado (a revisão, 11).
    int cx = w == 720 ? 8 : 0;
    if (d->esc_W != W || d->esc_H != H || d->esc_w != w || d->esc_h != h) {
        double sx = (double)(w - 2 * cx) / W, sy = (double)h / H;
        int ok = taps_novos(&d->ty_x, W, sx, 0.5 * sx - 0.5 + cx) == 0 &&
                 taps_novos(&d->ty_y, H, sy, 0.5 * sy - 0.5) == 0 &&
                 // o croma horizontal co-situado com a luma par (MPEG-2 4:2:0, e o do encoder):
                 // a saída i está na luma 2i da saída, que vem da luma (2i + 0.5) sx - 0.5 + cx da
                 // fonte, que é o croma de metade disso
                 taps_novos(&d->tc_x, W / 2, sx, (0.5 * sx - 0.5 + cx) / 2) == 0 &&
                 // o vertical, no meio das duas lumas (centro a centro, na resolução do croma)
                 taps_novos(&d->tc_y, H / 2, sy, 0.5 * sy - 0.5) == 0;
        size_t precisa = (size_t)W * (size_t)(h > H ? h : H);
        if (ok && d->esc_tmp_cap < precisa) {
            int16_t *t = realloc(d->esc_tmp, precisa * sizeof(int16_t));
            if (t) { d->esc_tmp = t; d->esc_tmp_cap = precisa; } else ok = 0;
        }
        if (!ok) { d->esc_W = 0; return DVD_ERRO_MEMORIA; }
        d->esc_W = W; d->esc_H = H; d->esc_w = w; d->esc_h = h;
    }
    reamostra(d, des_plano(d->des, 0), w, h, w, &d->ty_x, &d->ty_y, Y, ys, 1);
    reamostra(d, des_plano(d->des, 1), w / 2, h / 2, w / 2, &d->tc_x, &d->tc_y, U, cs, cps);
    reamostra(d, des_plano(d->des, 2), w / 2, h / 2, w / 2, &d->tc_x, &d->tc_y, V, cs, cps);
    return 0;
}

// ---------------------------------------------------------------------------------- o resto
static int compara32(const void *a, const void *b) {
    int32_t x = *(const int32_t *)a, y = *(const int32_t *)b;
    return x < y ? -1 : x > y;
}

static int64_t mediana_das_correcoes(Dvd *d) {
    if (d->n_correcoes == 0) return 0;
    int32_t *c = malloc(sizeof(int32_t) * (size_t)d->n_correcoes);
    if (!c) return -1;
    memcpy(c, d->correcoes, sizeof(int32_t) * (size_t)d->n_correcoes);
    qsort(c, (size_t)d->n_correcoes, sizeof(int32_t), compara32);
    int64_t m = c[d->n_correcoes / 2];
    free(c);
    return m;
}

void dvd_diario(Dvd *d) {
    // Uma linha por célula (as 300 primeiras): onde ela está, o tempo que o IFO dá (C_PBTM) e o que o
    // vídeo dela durou de fato, a base do NAV, os primeiros PTS, a costura, e o que foi corrigido.
    for (int k = 0; k < d->n_cel && k < 300; k++) {
        const Celula *c = &d->cel[k];
        int64_t setores = k + 1 < d->n_cel ? (d->cel[k + 1].pos - c->pos) / DVD_SETOR : (d->fim - c->pos) / DVD_SETOR;
        double pbtm = k + 1 < d->n_cel ? (d->cel[k + 1].acum - c->acum) / 90000.0 : -1;
        double conteudo = c->quadros ? (c->to_fim - c->to0) / 90000.0 : -1;
        LOGI("célula %d: setor %lld (+%lld), acumulado %.3f s, C_PBTM %.3f s, vídeo na saída %.3f s, "
             "s_ptm %lld (%s), 1º PTS vídeo %lld som %lld, costura %+.3f s, base %+.3f s, quadros %lld, "
             "corrigidos %lld (soma %.3f s), som: silêncio %.3f s, cortado %.3f s, rebaseados %lld",
             k, (long long)(c->pos / DVD_SETOR), (long long)setores, c->acum / 90000.0, pbtm, conteudo,
             (long long)c->s_ptm, c->nav ? "NAV" : c->tem_s > 0 ? "1º PTS" : "nenhum", (long long)c->v_pts0,
             (long long)c->a_pts0, c->costura / 90000.0, c->base / 90000.0, (long long)c->quadros,
             (long long)c->corrigidos, c->soma_correcoes / 90000.0, c->silencio / (double)TAXA,
             c->cortadas / (double)TAXA, (long long)c->rebaseados);
    }
    int64_t cort = 0;
    for (int k = 0; k < d->n_faixas; k++) cort += d->f[k].cortadas;
    LOGI("correções de carimbo de vídeo: %lld, a maior %.1f ms, a mediana %.1f ms; ajuste final %+.3f s; "
         "som cortado no título %.3f s", (long long)d->c_carimbos_corrigidos, d->maior_correcao / 90.0,
         mediana_das_correcoes(d) / 90.0, d->ajuste / 90000.0, cort / (double)TAXA);
}
// [0 setores, 1 fora_do_formato, 2 zerados, 3 navs, 4 navs_invalidos, 5 quadros_decodificados,
//  6 quadros_entregues, 7 entrelaçados, 8 progressivos, 9 pulldown (repeat_pict), 10
//  carimbos_corrigidos, 11 quadros_antes_do_zero, 12 falhas_de_vídeo, 13 pacotes_sem_faixa, 14
//  voltas_no_anel, 15 pontos_bob, 16 bytes_lidos_pelo_demuxer, e por faixa k (até 8), a partir de
//  17 + 4k: amostras_escritas, silêncio, cortadas, falhas; em 49 as descontinuidades do vídeo
//  (saltos > 10 s rebaseados; a revisão do código, 5); 50 o som cortado no título, somadas as
//  faixas (ms); 51 a maior correção de carimbo de vídeo (ms); 52 a mediana delas (ms); 53 os pedaços
//  de som rebaseados (atrasados > 1 s)]
// As faixas com um canal só espelhado (bit k = a faixa k): a tela diz isso.
int dvd_canal_copiado(Dvd *d) {
    int b = 0;
    for (int k = 0; k < DVD_MAX_FAIXAS; k++) if (d->f[k].espelho) b |= 1 << k;
    return b;
}

int dvd_contadores(Dvd *d, int64_t *v, int n) {
    int64_t t[DVD_N_CONTADORES] = {0};
    pthread_mutex_lock(&d->mu);
    int64_t lidos = d->leitura;
    pthread_mutex_unlock(&d->mu);
    int64_t base[17] = {d->c_setores, d->c_fora_do_formato, d->c_zerados, d->c_navs, d->c_navs_invalidos,
                        d->c_quadros_decod, d->c_quadros_entregues, d->c_entrelacados, d->c_progressivos,
                        d->c_pulldown, d->c_carimbos_corrigidos, d->c_quadros_antes_do_zero,
                        d->c_falhas_video, d->c_pacotes_sem_faixa, d->c_voltas_no_anel, d->c_bob_pontos, lidos};
    memcpy(t, base, sizeof base);
    for (int k = 0; k < DVD_MAX_FAIXAS; k++) {
        t[17 + 4 * k] = d->f[k].escritas;
        t[18 + 4 * k] = d->f[k].silencio;
        t[19 + 4 * k] = d->f[k].cortadas;
        t[20 + 4 * k] = d->f[k].falhas;
    }
    t[17 + 4 * DVD_MAX_FAIXAS] = d->c_descontinuidades;
    int64_t cort = 0, reb = 0;
    for (int k = 0; k < DVD_MAX_FAIXAS; k++) { cort += d->f[k].cortadas; reb += d->f[k].rebaseados; }
    t[50] = cort * 1000 / TAXA;
    t[51] = d->maior_correcao / 90;
    t[52] = mediana_das_correcoes(d) / 90;
    t[53] = reb;
    int m = n < (int)(sizeof t / sizeof t[0]) ? n : (int)(sizeof t / sizeof t[0]);
    memcpy(v, t, (size_t)m * sizeof(int64_t));
    return m;
}

void dvd_libera(Dvd *d) {
    if (!d) return;
    if (d->fmt) avformat_close_input(&d->fmt);
    if (d->io) { av_freep(&d->io->buffer); avio_context_free(&d->io); }
    if (d->vctx) avcodec_free_context(&d->vctx);
    for (int k = 0; k < DVD_MAX_FAIXAS; k++) {
        Faixa *f = &d->f[k];
        if (f->ctx) avcodec_free_context(&f->ctx);
        free(f->hb); free(f->fifo); free(f->tmp);
        for (int i = 0; i < f->n_pend; i++) free(f->pend[i].a);
        free(f->pend);
    }
    while (d->q_n > 0) { av_frame_free(&d->fila[d->q_ini]); d->q_ini = (d->q_ini + 1) % MAX_QUADROS; d->q_n--; }
    av_frame_free(&d->livre);
    av_packet_free(&d->pk);
    des_libera(d->des);
    taps_libera(&d->ty_x); taps_libera(&d->ty_y); taps_libera(&d->tc_x); taps_libera(&d->tc_y);
    free(d->esc_tmp);
    free(d->anel);
    free(d->cel);
    free(d->correcoes);
    pthread_mutex_destroy(&d->mu);
    pthread_cond_destroy(&d->cv);
    free(d);
}
