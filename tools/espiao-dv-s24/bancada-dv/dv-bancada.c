// Bancada da fase A do DV no S24: decodifica quadros DV-SD 525/60 (720x480, 4:1:1) com o
// libavcodec mínimo, lê o aspecto do VAUX, desentrelaça, converte para I420 no tamanho exibido,
// mede o custo de cada etapa e escreve PNGs de alguns quadros.
//
//   dv-bancada -i amostra.dv [-o dir] [-q 10,60,110] [-p passes] [-c cpu] [-t threads]
//              [-d adapt|adapt2|bob|weave] [-P limiar_pente] [-R raio] [-J janela] [-l limiar] [-y quadro_para_yuv411] [-Y desentrelacado.yuv] [-F final-i420.yuv]
//
// Desenho: quall-scratch/dv-s24/desenho-fase-a.md.

#define _GNU_SOURCE
#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#define QUADRO 120000
#define LARG 720
#define ALT 480
#define CLARG 180  // croma 4:1:1

static double agora_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

// ---------------------------------------------------------------- PNG (zlib em blocos "stored")
static uint32_t crc_tab[256];
static void crc_init(void) {
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_tab[n] = c;
    }
}
static uint32_t crc(uint32_t c, const uint8_t *b, size_t n) {
    c = ~c;
    while (n--) c = crc_tab[(c ^ *b++) & 0xFF] ^ (c >> 8);
    return ~c;
}
static void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void pedaco(FILE *f, const char *tipo, const uint8_t *d, uint32_t n) {
    uint8_t h[8];
    be32(h, n);
    memcpy(h + 4, tipo, 4);
    fwrite(h, 1, 8, f);
    if (n) fwrite(d, 1, n, f);
    uint32_t c = crc(0, (const uint8_t *)tipo, 4);
    c = crc(c, d, n);
    be32(h, c);
    fwrite(h, 1, 4, f);
}
static int png_rgb(const char *caminho, const uint8_t *rgb, int w, int h) {
    size_t cru = (size_t)h * (1 + 3 * (size_t)w);
    uint8_t *linhas = malloc(cru);
    for (int y = 0; y < h; y++) {
        linhas[y * (1 + 3 * (size_t)w)] = 0;
        memcpy(linhas + y * (1 + 3 * (size_t)w) + 1, rgb + (size_t)y * 3 * w, 3 * (size_t)w);
    }
    size_t nblocos = (cru + 65534) / 65535;
    size_t zn = 2 + cru + nblocos * 5 + 4;
    uint8_t *z = malloc(zn), *p = z;
    *p++ = 0x78; *p++ = 0x01;
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < cru; i++) { a = (a + linhas[i]) % 65521; b = (b + a) % 65521; }
    for (size_t off = 0; off < cru; off += 65535) {
        size_t k = cru - off < 65535 ? cru - off : 65535;
        *p++ = off + k == cru ? 1 : 0;
        *p++ = k & 0xFF; *p++ = k >> 8; *p++ = ~k & 0xFF; *p++ = (~k >> 8) & 0xFF;
        memcpy(p, linhas + off, k);
        p += k;
    }
    be32(p, (b << 16) | a);
    FILE *f = fopen(caminho, "wb");
    if (!f) { free(linhas); free(z); return -1; }
    static const uint8_t assin[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    fwrite(assin, 1, 8, f);
    uint8_t ihdr[13];
    be32(ihdr, w); be32(ihdr + 4, h);
    ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    pedaco(f, "IHDR", ihdr, 13);
    pedaco(f, "IDAT", z, (uint32_t)zn);
    pedaco(f, "IEND", NULL, 0);
    fclose(f);
    free(linhas);
    free(z);
    return 0;
}

// BT.601 de faixa limitada (o DV é 16-235) para RGB. `cx`/`cy`: divisores do croma.
static uint8_t sat(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }
static void yuv_para_rgb(uint8_t *rgb, int w, int h, const uint8_t *Y, int ys, const uint8_t *U,
                         const uint8_t *V, int cs, int cx, int cy) {
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int c = 298 * (Y[y * ys + x] - 16);
            int u = U[(y / cy) * cs + x / cx] - 128, v = V[(y / cy) * cs + x / cx] - 128;
            uint8_t *o = rgb + ((size_t)y * w + x) * 3;
            o[0] = sat((c + 409 * v + 128) >> 8);
            o[1] = sat((c - 100 * u - 208 * v + 128) >> 8);
            o[2] = sat((c + 516 * u + 128) >> 8);
        }
    }
}

// ---------------------------------------------------------------- VAUX
// Como o dvdec.c do FFmpeg: o pacote VSC (0x61) no bloco VAUX 3 da sequência 0 (80*5 + 48 + 5),
// DISP = PC2 & 7; 16:9 se DISP == 2, ou DISP == 7 com APT == 0. Devolve -1 sem o pacote.
typedef struct { int achou, disp, apt, entrelacado, campo_de_cima_primeiro; } Vaux;
static Vaux ler_vaux(const uint8_t *q) {
    Vaux v = {0};
    const uint8_t *p = q + 80 * 5 + 48 + 5;
    v.apt = q[4] & 7;
    if (p[0] != 0x61) {
        // Recuo: procura o 0x61 em qualquer pacote VAUX da sequência 0.
        p = NULL;
        for (int b = 3; b <= 5 && !p; b++)
            for (int k = 0; k < 15; k++) {
                const uint8_t *c = q + b * 80 + 3 + 5 * k;
                if (c[0] == 0x61) { p = c; break; }
            }
        if (!p) return v;
    }
    v.achou = 1;
    v.disp = p[2] & 7;
    v.entrelacado = (p[3] & 0x10) != 0;
    v.campo_de_cima_primeiro = !(p[3] & 0x40);
    return v;
}
static int eh_16_9(Vaux v) { return v.disp == 2 || (v.apt == 0 && v.disp == 7); }

// ---------------------------------------------------------------- desentrelaçar
// Campo de baixo primeiro: as linhas pares (campo de cima) são o campo mais novo e ficam; as
// ímpares (o campo velho) são reconstruídas. `ant` é o quadro cru anterior (ou NULL).
enum { BOB, WEAVE, ADAPT, ADAPT2 };
typedef struct { uint64_t pix_bob, pix_total; } ContaDes;
static int g_limiar_pente = 3;   // ADAPT2: pente (fora do intervalo vertical) acima disto -> bob
static int g_raio = 0;           // ADAPT2: dilatação da decisão (x±raio, e as linhas ímpares vizinhas)
static int g_janela = 3;         // ADAPT2: >0 = pente acumulado em x±janela (média), contra -P

static int ela(const uint8_t *a, const uint8_t *b, int x, int w) {
    int melhor = abs(a[x] - b[x]), r = (a[x] + b[x] + 1) >> 1;
    if (x > 0 && x < w - 1) {
        int d1 = abs(a[x - 1] - b[x + 1]), d2 = abs(a[x + 1] - b[x - 1]);
        if (d1 < melhor) { melhor = d1; r = (a[x - 1] + b[x + 1] + 1) >> 1; }
        if (d2 < melhor) { r = (a[x + 1] + b[x - 1] + 1) >> 1; }
    }
    return r;
}

// Quanto o pixel do campo velho sai do intervalo das duas linhas do campo novo (0 se dentro).
static int pente(int v, int a, int b) {
    int lo = a < b ? a : b, hi = a < b ? b : a;
    return v > hi ? v - hi : v < lo ? lo - v : 0;
}

// Planos de saída: Y 720x480, U/V 180x480 (ainda 4:1:1, agora progressivo).
// ADAPT: bob onde o movimento temporal (campo velho contra o anterior, e as duas linhas vizinhas
// do campo novo contra as anteriores) passa do limiar, pixel a pixel.
// ADAPT2 (o conserto): bob também onde há pente (o pixel do campo velho fora do intervalo vertical
// do campo novo por mais de g_limiar_pente), e a decisão é dilatada (x±g_raio, nas linhas ímpares
// y-2..y+2): some o weave isolado dentro de área em movimento (os "pontinhos" e "fiapos").
static void desentrelacar(int modo, int limiar, uint8_t *const in[3], const int is[3],
                          uint8_t *const ant[3], uint8_t *out[3], uint8_t *mascara, ContaDes *cd) {
    int adapt = (modo == ADAPT || modo == ADAPT2) && ant;
    // 1) decisão crua por pixel das linhas ímpares
    for (int y = 1; y < ALT; y += 2) {
        const uint8_t *l = in[0] + y * is[0];
        const uint8_t *a = in[0] + (y - 1) * is[0];
        const uint8_t *b = y + 1 < ALT ? in[0] + (y + 1) * is[0] : a;
        uint8_t *m = mascara + y * LARG;
        if (modo == WEAVE) { memset(m, 0, LARG); continue; }
        if (!adapt) { memset(m, 1, LARG); continue; }
        const uint8_t *pa = ant[0] + (y - 1) * LARG;
        const uint8_t *pl = ant[0] + y * LARG;
        const uint8_t *pb = y + 1 < ALT ? ant[0] + (y + 1) * LARG : pa;
        // pente com sinal consistente: o pixel velho acima (ou abaixo) das duas vizinhas novas
        int acum[LARG + 1];  // soma prefixada do pente: a média na janela sai em O(1)
        if (modo == ADAPT2 && g_janela > 0) {
            acum[0] = 0;
            for (int x = 0; x < LARG; x++) acum[x + 1] = acum[x] + pente(l[x], a[x], b[x]);
        }
        for (int x = 0; x < LARG; x++) {
            int mov = abs(l[x] - pl[x]);
            int t = abs(a[x] - pa[x]); if (t > mov) mov = t;
            t = abs(b[x] - pb[x]); if (t > mov) mov = t;
            int d = mov > limiar;
            if (modo == ADAPT2 && !d) {
                if (g_janela > 0) {
                    int x0 = x - g_janela < 0 ? 0 : x - g_janela;
                    int x1 = x + g_janela + 1 > LARG ? LARG : x + g_janela + 1;
                    d = acum[x1] - acum[x0] > g_limiar_pente * (x1 - x0);
                } else {
                    d = pente(l[x], a[x], b[x]) > g_limiar_pente;
                }
            }
            m[x] = (uint8_t)d;
        }
    }
    // 2) dilatação (ADAPT2): a linha par da máscara serve de rascunho (não é usada para decidir)
    if (modo == ADAPT2 && adapt) {
        for (int y = 1; y < ALT; y += 2) {
            uint8_t *r = mascara + (y - 1) * LARG;  // rascunho: dilatação horizontal da linha y
            const uint8_t *m = mascara + y * LARG;
            for (int x = 0; x < LARG; x++) {
                int v = 0;
                for (int k = -g_raio; k <= g_raio && !v; k++) {
                    int xx = x + k;
                    if (xx >= 0 && xx < LARG) v = m[xx];
                }
                r[x] = (uint8_t)v;
            }
        }
        // vertical: linha ímpar y fica bob se a dilatação horizontal de y-2, y ou y+2 for bob
        for (int y = 1; y < ALT; y += 2) {
            uint8_t *m = mascara + y * LARG;
            const uint8_t *r0 = mascara + (y - 1) * LARG;
            const uint8_t *rm = y >= 3 ? mascara + (y - 3) * LARG : r0;
            const uint8_t *rp = y + 2 < ALT ? mascara + (y + 1) * LARG : r0;
            for (int x = 0; x < LARG; x++) m[x] = (uint8_t)(r0[x] | rm[x] | rp[x]);
        }
    }
    // 3) saída do luma
    for (int y = 0; y < ALT; y++) {
        const uint8_t *l = in[0] + y * is[0];
        uint8_t *o = out[0] + y * LARG;
        if ((y & 1) == 0 || modo == WEAVE) { memcpy(o, l, LARG); continue; }
        const uint8_t *a = in[0] + (y - 1) * is[0];
        const uint8_t *b = y + 1 < ALT ? in[0] + (y + 1) * is[0] : a;
        const uint8_t *m = mascara + y * LARG;
        for (int x = 0; x < LARG; x++) {
            o[x] = m[x] ? (uint8_t)ela(a, b, x, LARG) : l[x];
            cd->pix_bob += m[x];
        }
        cd->pix_total += LARG;
    }
    // Croma (4:1:1: um pixel de croma cobre 4 de luma); segue a máscara do luma (bob se algum
    // dos 4 foi bob).
    for (int p = 1; p < 3; p++) {
        for (int y = 0; y < ALT; y++) {
            const uint8_t *l = in[p] + y * is[p];
            uint8_t *o = out[p] + y * CLARG;
            if ((y & 1) == 0 || modo == WEAVE) { memcpy(o, l, CLARG); continue; }
            const uint8_t *a = in[p] + (y - 1) * is[p];
            const uint8_t *b = y + 1 < ALT ? in[p] + (y + 1) * is[p] : a;
            const uint8_t *m = mascara + y * LARG;
            for (int x = 0; x < CLARG; x++) {
                int usar_bob = m[4 * x] | m[4 * x + 1] | m[4 * x + 2] | m[4 * x + 3];
                o[x] = usar_bob ? (uint8_t)((a[x] + b[x] + 1) >> 1) : l[x];
            }
        }
    }
}

// ---------------------------------------------------------------- 4:1:1 progressivo -> I420 WxH
// Luma: escala horizontal linear 720 -> W. Croma: 180 -> W/2 na horizontal (linear) e média de
// duas linhas na vertical (480 -> 240). Sem escala vertical: o DV já tem 480 linhas.
typedef struct { int *x0; int *f; int n; } Escala;  // f em 1/256
static Escala escala_nova(int de, int para) {
    Escala e = {malloc(sizeof(int) * para), malloc(sizeof(int) * para), para};
    for (int i = 0; i < para; i++) {
        // centro a centro
        double s = (i + 0.5) * de / (double)para - 0.5;
        if (s < 0) s = 0;
        int x0 = (int)s;
        if (x0 >= de - 1) { x0 = de - 2; s = de - 1; }
        e.x0[i] = x0;
        e.f[i] = (int)((s - x0) * 256 + 0.5);
    }
    return e;
}
// Croma do 4:1:1 é co-situado à esquerda (amostra k em x_luma = 4k), e o do I420 de saída também
// (amostra i em x_luma_saida = 2i). A amostra i da saída fica em x_luma_fonte = (2i + 0.5) * 720/W
// - 0.5, e em coordenada de croma da fonte, esse valor / 4.
static Escala escala_croma(int W) {
    int para = W / 2;
    Escala e = {malloc(sizeof(int) * para), malloc(sizeof(int) * para), para};
    for (int i = 0; i < para; i++) {
        double s = ((2 * i + 0.5) * LARG / (double)W - 0.5) / 4.0;
        if (s < 0) s = 0;
        int x0 = (int)s;
        if (x0 >= CLARG - 1) { x0 = CLARG - 2; s = CLARG - 1; }
        e.x0[i] = x0;
        e.f[i] = (int)((s - x0) * 256 + 0.5);
    }
    return e;
}

static void para_i420(uint8_t *const in[3], int W, Escala *ey, Escala *ec, uint8_t *out[3]) {
    for (int y = 0; y < ALT; y++) {
        const uint8_t *l = in[0] + y * LARG;
        uint8_t *o = out[0] + y * W;
        for (int i = 0; i < W; i++) {
            int x0 = ey->x0[i], f = ey->f[i];
            o[i] = (uint8_t)((l[x0] * (256 - f) + l[x0 + 1] * f + 128) >> 8);
        }
    }
    int CW = W / 2;
    for (int p = 1; p < 3; p++) {
        for (int y = 0; y < ALT / 2; y++) {
            const uint8_t *l0 = in[p] + (2 * y) * CLARG, *l1 = in[p] + (2 * y + 1) * CLARG;
            uint8_t *o = out[p] + y * CW;
            for (int i = 0; i < CW; i++) {
                int x0 = ec->x0[i], f = ec->f[i];
                int v0 = l0[x0] * (256 - f) + l0[x0 + 1] * f;
                int v1 = l1[x0] * (256 - f) + l1[x0 + 1] * f;
                o[i] = (uint8_t)((v0 + v1 + 256) >> 9);
            }
        }
    }
}

// ---------------------------------------------------------------- estatística
static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static void resumo(const char *nome, double *v, int n) {
    qsort(v, n, sizeof(double), cmp_d);
    double s = 0;
    for (int i = 0; i < n; i++) s += v[i];
    printf("  %-22s n=%d media=%.3f p50=%.3f p95=%.3f p99=%.3f max=%.3f ms\n", nome, n, s / n,
           v[n / 2], v[(int)(n * 0.95)], v[(int)(n * 0.99)], v[n - 1]);
}

int main(int argc, char **argv) {
    const char *entrada = NULL, *dir = ".", *quadros_png = "10,60,110";
    const char *saida_des = NULL;  // -Y: grava o desentrelaçado (yuv411p) de todos os quadros
    const char *saida_final = NULL;  // -F: grava o I420 final (no tamanho exibido) de todos os quadros
    int ritmo = 0;  // -r: um quadro a cada 1001/30000 s, como a câmera
    int passes = 10, cpu = -1, threads = 1, modo = ADAPT2, limiar = 10, quadro_yuv = -1;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "-i") && v) { entrada = v; i++; }
        else if (!strcmp(a, "-o") && v) { dir = v; i++; }
        else if (!strcmp(a, "-q") && v) { quadros_png = v; i++; }
        else if (!strcmp(a, "-p") && v) { passes = atoi(v); i++; }
        else if (!strcmp(a, "-c") && v) { cpu = atoi(v); i++; }
        else if (!strcmp(a, "-t") && v) { threads = atoi(v); i++; }
        else if (!strcmp(a, "-l") && v) { limiar = atoi(v); i++; }
        else if (!strcmp(a, "-y") && v) { quadro_yuv = atoi(v); i++; }
        else if (!strcmp(a, "-Y") && v) { saida_des = v; i++; }
        else if (!strcmp(a, "-F") && v) { saida_final = v; i++; }
        else if (!strcmp(a, "-r")) { ritmo = 1; }
        else if (!strcmp(a, "-P") && v) { g_limiar_pente = atoi(v); i++; }
        else if (!strcmp(a, "-R") && v) { g_raio = atoi(v); i++; }
        else if (!strcmp(a, "-J") && v) { g_janela = atoi(v); i++; }
        else if (!strcmp(a, "-d") && v) {
            modo = !strcmp(v, "bob") ? BOB : !strcmp(v, "weave") ? WEAVE : !strcmp(v, "adapt") ? ADAPT : ADAPT2; i++;
        } else { fprintf(stderr, "opção desconhecida: %s\n", a); return 2; }
    }
    if (!entrada) { fprintf(stderr, "uso: dv-bancada -i amostra.dv ...\n"); return 2; }
    crc_init();
    mkdir(dir, 0755);

#ifdef __linux__
    if (cpu >= 0) {
        cpu_set_t s;
        CPU_ZERO(&s);
        CPU_SET(cpu, &s);
        printf("afinidade cpu %d: %s\n", cpu, sched_setaffinity(0, sizeof(s), &s) ? strerror(errno) : "ok");
        cpu_set_t g;
        CPU_ZERO(&g);
        sched_getaffinity(0, sizeof(g), &g);
        printf("afinidade conferida: %d cpu(s), cpu %d %s\n", CPU_COUNT(&g), cpu, CPU_ISSET(cpu, &g) ? "dentro" : "FORA");
    }
#endif

    FILE *f = fopen(entrada, "rb");
    if (!f) { perror(entrada); return 1; }
    fseek(f, 0, SEEK_END);
    long tam = ftell(f);
    fseek(f, 0, SEEK_SET);
    int nq = (int)(tam / QUADRO);
    uint8_t *dados = malloc((size_t)nq * QUADRO + AV_INPUT_BUFFER_PADDING_SIZE);
    if (fread(dados, 1, (size_t)nq * QUADRO, f) != (size_t)nq * QUADRO) { perror("fread"); return 1; }
    fclose(f);
    printf("%s: %d quadros\n", entrada, nq);

    const AVCodec *cod = avcodec_find_decoder(AV_CODEC_ID_DVVIDEO);
    AVCodecContext *ctx = avcodec_alloc_context3(cod);
    ctx->thread_count = threads;
    ctx->thread_type = FF_THREAD_SLICE;
    if (avcodec_open2(ctx, cod, NULL) < 0) { fprintf(stderr, "avcodec_open2 falhou\n"); return 1; }
    printf("licença: %s\n", avcodec_license());
    printf("libavcodec %s, threads=%d, desentrelaçar=%s limiar=%d\n", av_version_info(), threads,
           modo == BOB ? "bob" : modo == WEAVE ? "weave" : modo == ADAPT2 ? "adapt2" : "adapt", limiar);

    AVFrame *fr = av_frame_alloc();
    AVPacket *pk = av_packet_alloc();
    uint8_t *pkbuf = av_malloc(QUADRO + AV_INPUT_BUFFER_PADDING_SIZE);
    memset(pkbuf + QUADRO, 0, AV_INPUT_BUFFER_PADDING_SIZE);

    // Buffers: anterior cru (Y 720, UV 180), desentrelaçado, máscara, I420 maior (854).
    uint8_t *ant[3] = {malloc(LARG * ALT), malloc(CLARG * ALT), malloc(CLARG * ALT)};
    uint8_t *des[3] = {malloc(LARG * ALT), malloc(CLARG * ALT), malloc(CLARG * ALT)};
    uint8_t *mascara = calloc(LARG, ALT);
    uint8_t *i420[3] = {malloc(854 * ALT), malloc(427 * 240), malloc(427 * 240)};
    int tem_ant = 0;
    FILE *fdes = saida_des ? fopen(saida_des, "wb") : NULL;
    FILE *ffin = saida_final ? fopen(saida_final, "wb") : NULL;
    Escala ey169 = escala_nova(LARG, 854), ec169 = escala_croma(854);
    Escala ey43 = escala_nova(LARG, 640), ec43 = escala_croma(640);

    int total = nq * passes;
    double *t_dec = malloc(sizeof(double) * total), *t_des = malloc(sizeof(double) * total),
           *t_conv = malloc(sizeof(double) * total), *t_tot = malloc(sizeof(double) * total);
    int n169 = 0, n43 = 0, nsem = 0, sar_desacordo = 0, ent = 0, tff = 0, flag_ent = 0, flag_tff = 0;
    ContaDes cd = {0};
    int k = 0;
    for (int pas = 0; pas < passes; pas++) {
        for (int q = 0; q < nq; q++, k++) {
            if (ritmo) {
                static double prox = 0;
                double t = agora_ms();
                if (prox == 0) prox = t;
                prox += 1001.0 / 30.0;
                if (prox > t) {
                    struct timespec ts = {0, (long)((prox - t) * 1e6)};
                    nanosleep(&ts, NULL);
                }
            }
            const uint8_t *src = dados + (size_t)q * QUADRO;
            Vaux vx = ler_vaux(src);
            int w169 = vx.achou ? eh_16_9(vx) : 0;
            if (pas == 0) {
                if (!vx.achou) nsem++; else if (w169) n169++; else n43++;
                ent += vx.entrelacado; tff += vx.campo_de_cima_primeiro;
            }
            double t0 = agora_ms();
            memcpy(pkbuf, src, QUADRO);
            pk->data = pkbuf;
            pk->size = QUADRO;
            if (avcodec_send_packet(ctx, pk) < 0 || avcodec_receive_frame(ctx, fr) < 0) {
                fprintf(stderr, "quadro %d: erro de decodificação\n", q);
                return 1;
            }
            double t1 = agora_ms();
            if (pas == 0) {
                AVRational sar = fr->sample_aspect_ratio;
                int sar169 = sar.num == 32 && sar.den == 27;
                if (sar169 != w169) sar_desacordo++;
                flag_ent += (fr->flags & AV_FRAME_FLAG_INTERLACED) != 0;
                flag_tff += (fr->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) != 0;
                if (q == 0)
                    printf("quadro 0: formato %s %dx%d linesize %d/%d/%d SAR %d:%d\n",
                           fr->format == AV_PIX_FMT_YUV411P ? "yuv411p" : "OUTRO", fr->width,
                           fr->height, fr->linesize[0], fr->linesize[1], fr->linesize[2],
                           sar.num, sar.den);
            }
            desentrelacar(modo, limiar, fr->data, fr->linesize, tem_ant ? ant : NULL, des, mascara, &cd);
            double t2 = agora_ms();
            int W = w169 ? 854 : 640;
            para_i420(des, W, w169 ? &ey169 : &ey43, w169 ? &ec169 : &ec43, i420);
            double t3 = agora_ms();
            // o cru deste quadro vira o anterior do próximo (fora da medida do desentrelaçador,
            // mas dentro do total)
            for (int y = 0; y < ALT; y++) memcpy(ant[0] + y * LARG, fr->data[0] + y * fr->linesize[0], LARG);
            for (int p = 1; p < 3; p++)
                for (int y = 0; y < ALT; y++) memcpy(ant[p] + y * CLARG, fr->data[p] + y * fr->linesize[p], CLARG);
            tem_ant = 1;
            double t4 = agora_ms();
            t_dec[k] = t1 - t0; t_des[k] = t2 - t1; t_conv[k] = t3 - t2; t_tot[k] = t4 - t0;

            if (pas == 0 && ffin) {
                fwrite(i420[0], 1, (size_t)W * ALT, ffin);
                fwrite(i420[1], 1, (size_t)(W / 2) * 240, ffin);
                fwrite(i420[2], 1, (size_t)(W / 2) * 240, ffin);
            }
            if (pas == 0 && fdes) {
                fwrite(des[0], 1, LARG * ALT, fdes);
                fwrite(des[1], 1, CLARG * ALT, fdes);
                fwrite(des[2], 1, CLARG * ALT, fdes);
            }
            if (pas == 0) {
                char lista[256];
                snprintf(lista, sizeof(lista), ",%s,", quadros_png);
                char alvo[16];
                snprintf(alvo, sizeof(alvo), ",%d,", q);
                if (strstr(lista, alvo)) {
                    char c[512];
                    uint8_t *rgb = malloc(854 * ALT * 3);
                    yuv_para_rgb(rgb, LARG, ALT, fr->data[0], fr->linesize[0], fr->data[1], fr->data[2], fr->linesize[1], 4, 1);
                    snprintf(c, sizeof(c), "%s/q%03d-1-cru-720x480.png", dir, q);
                    png_rgb(c, rgb, LARG, ALT);
                    yuv_para_rgb(rgb, LARG, ALT, des[0], LARG, des[1], des[2], CLARG, 4, 1);
                    snprintf(c, sizeof(c), "%s/q%03d-2-desentrelacado-720x480.png", dir, q);
                    png_rgb(c, rgb, LARG, ALT);
                    yuv_para_rgb(rgb, W, ALT, i420[0], W, i420[1], i420[2], W / 2, 2, 2);
                    snprintf(c, sizeof(c), "%s/q%03d-3-final-%dx480.png", dir, q, W);
                    png_rgb(c, rgb, W, ALT);
                    free(rgb);
                    printf("PNG do quadro %d (%s, DISP %d, APT %d)\n", q, w169 ? "16:9" : "4:3", vx.disp, vx.apt);
                }
                if (q == quadro_yuv) {
                    char c[512];
                    snprintf(c, sizeof(c), "%s/q%03d.yuv411p", dir, q);
                    FILE *y = fopen(c, "wb");
                    for (int p = 0; p < 3; p++) {
                        int w = p ? CLARG : LARG;
                        for (int l = 0; l < ALT; l++) fwrite(fr->data[p] + l * fr->linesize[p], 1, w, y);
                    }
                    fclose(y);
                    printf("yuv411p cru do quadro %d em %s\n", q, c);
                }
            }
        }
    }
    if (fdes) fclose(fdes);
    if (ffin) fclose(ffin);
    printf("VAUX (1ª passada, %d quadros): 16:9=%d 4:3=%d sem_pacote=%d; SAR do FFmpeg em desacordo=%d; "
           "VAUX entrelaçado=%d campo_de_cima_primeiro=%d; AVFrame INTERLACED=%d TOP_FIELD_FIRST=%d\n",
           nq, n169, n43, nsem, sar_desacordo, ent, tff, flag_ent, flag_tff);
    printf("desentrelaçador: %.1f%% dos pixels das linhas reconstruídas por interpolação\n",
           cd.pix_total ? 100.0 * cd.pix_bob / cd.pix_total : 0);
    printf("custo por quadro (%d quadros, %d passadas, %s):\n", total, passes, ritmo ? "no ritmo de 29,97" : "a toda velocidade");
#ifdef __linux__
    for (int c = 0; c < 8; c++) {
        char cam[128], buf[32] = "";
        snprintf(cam, sizeof(cam), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", c);
        FILE *ff = fopen(cam, "r");
        if (ff) { if (fgets(buf, sizeof(buf), ff)) buf[strcspn(buf, "\n")] = 0; fclose(ff); }
        printf("%scpu%d=%s", c ? " " : "  frequência no fim (kHz): ", c, buf);
    }
    printf("\n");
#endif
    resumo("decodificar", t_dec, total);
    resumo("desentrelacar", t_des, total);
    resumo("411->I420+escala", t_conv, total);
    resumo("total (c/ copia)", t_tot, total);
    return 0;
}
