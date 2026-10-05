// Teste de mesa do DVD para MP4 (`app/src/main/cpp/dv/dvd.c` e `desentrelaca.c`), no Mac, com o
// FFmpeg do Homebrew no lugar do do app (a mesma série, 9.0). Roda por `../testa-dvd.sh`, que gera
// os VOB de teste com o `ffmpeg` do Mac. Sem arquivo nenhum na linha de comando, só as partes que
// não precisam do FFmpeg (a conferência do setor e o croma do adapt2).
//
// O que prova:
// 1. a conferência do setor (§2.1): o pack limpo passa, o PES com os bits de cifragem ≠ 0 é
//    recusado (vídeo, som em private stream 1, e o MPEG áudio), o NAV válido dá o vobu_s_ptm, o
//    zerado não; o setor sem pack e a cadeia quebrada saem zerados;
// 2. a regra do croma do adapt2 em 4:2:0 (a revisão, 10), e a ordem dos campos pelo tff;
// 3. o caminho inteiro (VOB → blocos de 64 KB → demuxer → decodificadores → desentrelaçador →
//    escala → PCM 48 kHz estéreo), com a quantidade de quadros, os carimbos, a duração do som de
//    cada faixa contra a do vídeo (±50 ms), a faixa que não existe (silêncio), duas "células" com
//    o PTS recomeçando (o acumulado do C_PBTM), e o setor cifrado no meio (a conversão para).
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../app/src/main/cpp/dv/desentrelaca.h"
#ifndef SO_DESENTRELACA
#include "../../app/src/main/cpp/dv/dvd.h"
#endif

static int falhas = 0;
#define CONFERE(c, ...) do { if (!(c)) { falhas++; fprintf(stderr, "FALHOU %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

// ------------------------------------------------------------------------- 1. o setor
#ifndef SO_DESENTRELACA
static void pack(uint8_t *s) {
    memset(s, 0, DVD_SETOR);
    s[0] = 0; s[1] = 0; s[2] = 1; s[3] = 0xBA;
    s[4] = 0x44;  // '01' MPEG-2
    s[13] = 0xF8; // sem enchimento
}

// Um PES em `off` com id, tamanho total do dado `len` e o primeiro byte do cabeçalho estendido.
static int pes(uint8_t *s, int off, int id, int len, uint8_t flags0) {
    s[off] = 0; s[off + 1] = 0; s[off + 2] = 1; s[off + 3] = (uint8_t)id;
    s[off + 4] = (uint8_t)(len >> 8); s[off + 5] = (uint8_t)len;
    s[off + 6] = flags0;
    return off + 6 + len;
}

static void testa_setor(void) {
    uint8_t s[DVD_SETOR];
    int nav; uint32_t sp;
    // limpo: vídeo, depois padding até o fim
    pack(s);
    int o = pes(s, 14, 0xE0, 1000, 0x81);
    pes(s, o, 0xBE, DVD_SETOR - o - 6, 0xFF);
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 0 && nav == 0, "pack limpo");
    // os bits de cifragem: 01, 10 e 11, no vídeo, no private stream 1 (AC-3) e no MPEG áudio
    int ids[3] = {0xE0, 0xBD, 0xC0};
    for (int k = 0; k < 3; k++)
        for (int b = 1; b <= 3; b++) {
            pack(s);
            o = pes(s, 14, ids[k], 1000, (uint8_t)(0x80 | b << 4));
            pes(s, o, 0xBE, DVD_SETOR - o - 6, 0xFF);
            CONFERE(dvd_confere_setor(s, &nav, &sp) == 1, "cifrado id 0x%x bits %d", ids[k], b);
        }
    // o cifrado atrás de um limpo, no mesmo setor
    pack(s);
    o = pes(s, 14, 0xBD, 500, 0x81);
    o = pes(s, o, 0xE0, 500, 0x90);
    pes(s, o, 0xBE, DVD_SETOR - o - 6, 0xFF);
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 1, "cifrado no segundo PES");
    // o NAV: sistema, PCI (0x3D4) com s_ptm 90000 e e_ptm 135000, DSI
    pack(s);
    s[14] = 0; s[15] = 0; s[16] = 1; s[17] = 0xBB; s[18] = 0; s[19] = 18;
    o = 14 + 6 + 18;
    CONFERE(o == 0x26, "o PCI em 0x26");
    int pci = o;
    o = pes(s, o, 0xBF, 0x3D4, 0x00);
    uint8_t *d = s + pci + 6;
    d[0x0D] = 0; d[0x0E] = 1; d[0x0F] = 0x5F; d[0x10] = 0x90;  // 90000
    d[0x11] = 0; d[0x12] = 2; d[0x13] = 0x0F; d[0x14] = 0x58;  // 135000
    pes(s, o, 0xBF, DVD_SETOR - o - 6, 0x01);
    CONFERE(pci + 6 + 0x0D == 0x39, "o vobu_s_ptm em 0x39 do setor");
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 0 && nav == 1 && sp == 90000, "NAV válido (nav %d s_ptm %u)", nav, sp);
    // o NAV zerado (o muxer dvd do FFmpeg): não vale
    memset(d + 1, 0, 0x3D3);
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 0 && nav == -1, "NAV zerado não vale");
    // sem pack: zerado inteiro
    memset(s, 0x55, DVD_SETOR);
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 2 && s[0] == 0 && s[DVD_SETOR - 1] == 0, "sem pack");
    // um PES escondido no meio do setor sem pack, cifrado: zerado, nunca chega ao demuxer
    memset(s, 0x11, DVD_SETOR);
    pes(s, 100, 0xE0, 1000, 0x90);
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 2 && s[103] == 0, "PES escondido sem pack");
    // a cadeia quebrada: o resto sai zerado
    pack(s);
    o = pes(s, 14, 0xE0, 500, 0x81);
    memset(s + o, 0x77, DVD_SETOR - o);
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 2 && s[o] == 0 && s[DVD_SETOR - 1] == 0, "cadeia quebrada");
    // o PES sem tamanho (len 0) e o cabeçalho encostado no fim: suspeitos, o resto zerado
    pack(s);
    o = pes(s, 14, 0xE0, 0, 0x81);
    memset(s + o, 0x33, DVD_SETOR - o);
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 2 && s[14] == 0 && s[DVD_SETOR - 1] == 0, "PES sem tamanho");
    pack(s);
    o = pes(s, 14, 0xE0, DVD_SETOR - 14 - 12, 0x81);
    CONFERE(o == DVD_SETOR - 6, "o cabeçalho encostado");
    s[o] = 0; s[o + 1] = 0; s[o + 2] = 1; s[o + 3] = 0xE0; s[o + 4] = 0; s[o + 5] = 9;
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 2 && s[o + 3] == 0, "cabeçalho sem o byte da cifragem");
    // a sobra de menos de 6 bytes que não é zero
    pack(s);
    o = pes(s, 14, 0xE0, DVD_SETOR - 14 - 6 - 3, 0x81);
    s[DVD_SETOR - 1] = 0x42;
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 2 && s[DVD_SETOR - 1] == 0, "a sobra");
    // zeros
    memset(s, 0, DVD_SETOR);
    CONFERE(dvd_confere_setor(s, &nav, &sp) == 3, "zerado");
}

#endif

// ------------------------------------------------------------------------ 2. o croma
static void testa_croma(void) {
    // a linha de croma cy é do campo cy & 1 e casa com as lumas 4k+f e 4k+2+f
    int esperado[8][2] = {{0, 2}, {1, 3}, {4, 6}, {5, 7}, {8, 10}, {9, 11}, {12, 14}, {13, 15}};
    for (int cy = 0; cy < 8; cy++)
        for (int q = 0; q < 2; q++)
            CONFERE(des_luma_do_croma(cy, q, 480) == esperado[cy][q], "croma %d luma %d: %d", cy, q,
                    des_luma_do_croma(cy, q, 480));
    CONFERE(des_luma_do_croma(239, 0, 480) == 477 && des_luma_do_croma(239, 1, 480) == 479, "a última");
    CONFERE(des_luma_do_croma(143, 1, 288) == 287 && des_luma_do_croma(142, 1, 288) == 286, "PAL/2");

    // O pente cheio: o campo de cima (pares) em 50, o de baixo em 200; no croma, o campo de cima
    // (cy par) em 60, o de baixo em 190. O adapt2 mantém o campo mais novo.
    const int w = 64, h = 48;
    uint8_t *y = malloc((size_t)w * h), *u = malloc((size_t)w * h / 4), *v = malloc((size_t)w * h / 4);
    for (int l = 0; l < h; l++) memset(y + l * w, l & 1 ? 200 : 50, (size_t)w);
    for (int l = 0; l < h / 2; l++) { memset(u + l * w / 2, l & 1 ? 190 : 60, (size_t)w / 2); memset(v + l * w / 2, 128, (size_t)w / 2); }
    const uint8_t *in[3] = {y, u, v};
    const int is[3] = {w, w / 2, w / 2};
    for (int tff = 0; tff <= 1; tff++) {
        Desentrelacador *d = des_novo(w, h);
        des_quadro(d, in, is, tff);  // sem anterior: tudo bob
        des_quadro(d, in, is, tff);  // parado, mas o pente cheio vai a bob
        const uint8_t *oy = des_plano(d, 0), *ou = des_plano(d, 1);
        int fica = tff ? 200 : 50, fica_c = tff ? 190 : 60;
        int ok = 1, ok_c = 1;
        for (int l = 0; l < h; l++) for (int x = 0; x < w; x++) ok &= oy[l * w + x] == fica;
        for (int l = 0; l < h / 2; l++) for (int x = 0; x < w / 2; x++) ok_c &= ou[l * w / 2 + x] == fica_c;
        CONFERE(ok, "tff=%d: a luma inteira no campo mais novo (%d)", tff, fica);
        CONFERE(ok_c, "tff=%d: o croma inteiro no campo mais novo (%d), pela regra 4:2:0", tff, fica_c);
        CONFERE(des_pontos_bob(d) == (long)w * h / 2, "tff=%d: todas as linhas interpoladas a bob (%ld)", tff, des_pontos_bob(d));
        des_libera(d);
    }
    // O parado sem pente (uma rampa vertical suave) fica em weave: nenhum bob no segundo quadro.
    for (int l = 0; l < h; l++) memset(y + l * w, 40 + l, (size_t)w);
    Desentrelacador *d = des_novo(w, h);
    des_quadro(d, in, is, 1);
    des_quadro(d, in, is, 1);
    CONFERE(des_pontos_bob(d) == 0, "parado sem pente: weave (%ld bob)", des_pontos_bob(d));
    int ok = 1;
    for (int l = 0; l < h; l++) ok &= des_plano(d, 0)[l * w + 3] == 40 + l;
    CONFERE(ok, "weave devolve o quadro como veio");
    des_libera(d);
    free(y); free(u); free(v);
}

// ------------------------------------------------------------------------ 3. o caminho
#ifndef SO_DESENTRELACA
typedef struct {
    Dvd *d;
    const uint8_t *dados;
    size_t n;
    int vezes;           // o arquivo repetido (duas células)
    int64_t acum2;       // o acumulado da segunda célula (90 kHz)
    int celulas;
    int r;
    const int64_t *acums;  // o acumulado de cada célula (o C_PBTM), ou NULL (acum2 x v)
} Leitor;

static void *le(void *op) {
    Leitor *l = op;
    int64_t pos = 0;
    for (int v = 0; v < l->vezes; v++) {
        if (l->celulas) dvd_celula(l->d, pos, l->acums ? l->acums[v] : v == 0 ? 0 : l->acum2 * v);
        for (size_t k = 0; k < l->n; k += 65536) {
            int n = (int)(l->n - k < 65536 ? l->n - k : 65536);
            int r = dvd_empurrar(l->d, l->dados + k, n, pos);
            if (r) { l->r = r; return NULL; }
            pos += n;
        }
    }
    dvd_fim_da_entrada(l->d);
    return NULL;
}

typedef struct {
    int quadros;
    int64_t primeiro, ultimo, ultima_dur;
    int64_t amostras[DVD_MAX_FAIXAS];
    double energia[DVD_MAX_FAIXAS];
    int n_faixas;
    int erro;
    int corrigidos;
    DvdInfo info;
    // a energia da faixa 0 por segundo de saída (o som mudo aparece aqui)
    double seg[4000];
    int64_t cortado_ms, rebaseados;
} Resultado;

static uint8_t *le_arquivo(const char *c, size_t *n) {
    FILE *f = fopen(c, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *n = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(*n);
    if (fread(b, 1, *n, f) != *n) { free(b); b = NULL; }
    fclose(f);
    return b;
}

static Resultado converte_celulas(const uint8_t *dados, size_t n, const int *faixas, int n_faixas, int vezes,
                                  int64_t acum2, const int64_t *acums, int W, int H) {
    static Resultado res;
    memset(&res, 0, sizeof res);
    Dvd *d = dvd_novo(faixas, n_faixas);
    Leitor l = {d, dados, n, vezes, acum2, vezes > 1, 0, acums};
    pthread_t t;
    pthread_create(&t, NULL, le, &l);
    int r = dvd_preparar(d);
    if (r < 0) { res.erro = r; dvd_abortar(d, DVD_ERRO_CANCELADO); pthread_join(t, NULL); dvd_libera(d); return res; }
    dvd_info(d, &res.info);
    res.n_faixas = res.info.n_faixas;
    uint8_t *Y = malloc((size_t)W * H), *U = malloc((size_t)W * H / 4), *V = malloc((size_t)W * H / 4);
    int16_t som[8192];
    res.primeiro = -1;
    for (;;) {
        r = dvd_passo(d);
        if (r < 0) { res.erro = r; break; }
        if (r == DVD_QUADRO) {
            int64_t p, du;
            while (dvd_quadro(d, &p, &du) == 1) {
                if (res.primeiro < 0) res.primeiro = p;
                if (res.quadros && p <= res.ultimo) res.corrigidos++;
                res.ultimo = p; res.ultima_dur = du;
                res.quadros++;
                if (W > 0) CONFERE(dvd_escrever(d, Y, W, U, V, W / 2, 1, W, H) == 0, "escrever");
            }
        }
        for (int k = 0; k < res.n_faixas; k++) {
            int m;
            while ((m = dvd_som(d, k, som, 4096)) > 0) {
                for (int i = 0; i < m; i++) {
                    double e = (double)som[2 * i] * som[2 * i] + (double)som[2 * i + 1] * som[2 * i + 1];
                    res.energia[k] += e;
                    int64_t sg = (res.amostras[k] + i) / 48000;
                    if (k == 0 && sg < 4000) res.seg[sg] += e;
                }
                res.amostras[k] += m;
            }
        }
        if (r == DVD_FIM) break;
    }
    int64_t c[64];
    int nc = dvd_contadores(d, c, 64);
    if (nc > 53) { res.cortado_ms = c[50]; res.rebaseados = c[53]; }
    dvd_diario(d);
    fprintf(stderr, "   contadores:");
    for (int i = 0; i < 17 && i < nc; i++) fprintf(stderr, " %lld", (long long)c[i]);
    for (int k = 0; k < res.n_faixas && 20 + 4 * k < nc; k++)
        fprintf(stderr, " | faixa %d: silêncio %lld cortadas %lld falhas %lld", k, (long long)c[18 + 4 * k],
                (long long)c[19 + 4 * k], (long long)c[20 + 4 * k]);
    fprintf(stderr, "\n");
    if (res.erro) dvd_abortar(d, DVD_ERRO_CANCELADO);
    pthread_join(t, NULL);
    if (l.r && !res.erro) res.erro = l.r;
    dvd_libera(d);
    free(Y); free(U); free(V);
    return res;
}

static Resultado converte(const uint8_t *dados, size_t n, const int *faixas, int n_faixas, int vezes,
                          int64_t acum2, int W, int H) {
    return converte_celulas(dados, n, faixas, n_faixas, vezes, acum2, NULL, W, H);
}

// Os segundos inteiros da faixa 0 em silêncio (RMS < 300), até o fim do vídeo menos 1 s.
static int segundos_mudos(const Resultado *r) {
    int64_t fim = (r->ultimo + r->ultima_dur) / 90000 - 1;
    int mudos = 0;
    for (int64_t k = 1; k < fim && k < 4000; k++) if (sqrt(r->seg[k] / (2.0 * 48000)) < 300) mudos++;
    return mudos;
}

// O PTS de 33 bits de um cabeçalho de PES (5 bytes).
static int64_t pts_do_pes(const uint8_t *t) {
    return ((int64_t)((t[0] >> 1) & 7) << 30) | ((int64_t)t[1] << 22) | ((int64_t)(t[2] >> 1) << 15) |
           ((int64_t)t[3] << 7) | (t[4] >> 1);
}

static void confere_som(Resultado *r, const char *nome);

// h) **O defeito do A07** (28/09): um título de várias células de um minuto, como um DVD de verdade —
// o PTS só no primeiro PES de vídeo de cada VOBU (o I; os outros quadros sem carimbo), o NAV válido
// no começo de cada célula, o som LPCM 48 kHz adiantado no fluxo — e o acumulado das células (o
// C_PBTM) em três versões: 0,1 % curto (o timecode de 30 quadros contra os 29,97, a divergência
// que emudeceu o A07 aos 1021 s), 1 s curto e 1 s longo por célula. O som não pode ficar mudo, nem
// ser cortado em massa, e acaba com o vídeo.
static void testa_celulas_de_minuto(const char *caminho) {
    size_t n;
    uint8_t *v = le_arquivo(caminho, &n);
    if (!v || n % DVD_SETOR) { CONFERE(0, "h: o VOB de um minuto não abriu"); return; }
    int tirados = 0, navs = 0;
    int64_t primeiro_pts = -1;
    int depois_do_nav = 0;
    for (size_t k = 0; k < n; k += DVD_SETOR) {
        uint8_t *s = v + k;
        if (s[0] || s[1] || s[2] != 1 || s[3] != 0xBA) continue;
        int off = 14 + (s[13] & 7);
        while (off + 9 <= DVD_SETOR && s[off] == 0 && s[off + 1] == 0 && s[off + 2] == 1) {
            int id = s[off + 3], len = (s[off + 4] << 8) | s[off + 5];
            if (id == 0xBF && s[off + 6] == 0x00) {
                navs++;
                depois_do_nav = 1;
            } else if (id == 0xE0 && (s[off + 7] & 0x80)) {
                if (primeiro_pts < 0) primeiro_pts = pts_do_pes(s + off + 9);
                if (depois_do_nav) {
                    depois_do_nav = 0;  // o primeiro PES de vídeo da VOBU fica com o carimbo
                } else if ((s[off + 7] & 0x3F) == 0) {
                    int hl = s[off + 8];
                    s[off + 7] &= 0x3F;
                    memset(s + off + 9, 0xFF, (size_t)hl);  // os carimbos viram enchimento
                    tirados++;
                }
            }
            if (id == 0xBB || len == 0) { off += 6 + len; if (len == 0) break; continue; }
            off += 6 + len;
        }
    }
    CONFERE(tirados > 100 && navs > 50 && primeiro_pts > 0, "h: %d carimbos tirados, %d NAV, 1º PTS %lld", tirados, navs,
            (long long)primeiro_pts);
    // o NAV do primeiro setor com o vobu_s_ptm de verdade (o muxer do FFmpeg o deixa zerado)
    {
        uint8_t *p = v;
        int pci = 14 + (p[13] & 7);
        if (p[pci + 3] == 0xBB) pci += 6 + ((p[pci + 4] << 8) | p[pci + 5]);
        uint8_t *q = p + pci + 6;
        uint32_t s0 = (uint32_t)primeiro_pts, e0 = s0 + 15015;
        q[0x0D] = (uint8_t)(s0 >> 24); q[0x0E] = (uint8_t)(s0 >> 16); q[0x0F] = (uint8_t)(s0 >> 8); q[0x10] = (uint8_t)s0;
        q[0x11] = (uint8_t)(e0 >> 24); q[0x12] = (uint8_t)(e0 >> 16); q[0x13] = (uint8_t)(e0 >> 8); q[0x14] = (uint8_t)e0;
    }
    int fx[1] = {0xA0};
    Resultado r1 = converte_celulas(v, n, fx, 1, 1, 0, NULL, 0, 0);
    CONFERE(r1.erro == 0 && r1.quadros > 1700, "h: uma célula: erro %d, %d quadros", r1.erro, r1.quadros);
    int64_t fim1 = r1.ultimo + r1.ultima_dur;
    const char *nomes[3] = {"h 0,1 % curto", "h 1 s curto", "h 1 s longo"};
    for (int caso = 0; caso < 3; caso++) {
        int64_t acums[4];
        for (int k = 0; k < 4; k++)
            acums[k] = caso == 0 ? k * fim1 * 1000 / 1001 : caso == 1 ? k * (fim1 - 90000) : k * (fim1 + 90000);
        Resultado r = converte_celulas(v, n, fx, 1, 4, 0, acums, 0, 0);
        CONFERE(r.erro == 0, "%s: erro %d", nomes[caso], r.erro);
        CONFERE(r.quadros >= 4 * r1.quadros - 4 && r.quadros <= 4 * r1.quadros, "%s: %d quadros (4 x %d)", nomes[caso],
                r.quadros, r1.quadros);
        CONFERE(llabs(r.ultimo + r.ultima_dur - 4 * fim1) <= 2 * 3003, "%s: acaba em %.3f s, esperado %.3f s (a costura)",
                nomes[caso], (r.ultimo + r.ultima_dur) / 90000.0, 4 * fim1 / 90000.0);
        confere_som(&r, nomes[caso]);
        int mudos = segundos_mudos(&r);
        CONFERE(mudos == 0, "%s: %d segundo(s) de som mudo", nomes[caso], mudos);
        CONFERE(r.cortado_ms < 300 && r.rebaseados == 0, "%s: %lld ms de som cortado, %lld pedaços rebaseados",
                nomes[caso], (long long)r.cortado_ms, (long long)r.rebaseados);
        fprintf(stderr, "   %s: %d quadros, %.3f s, som cortado %lld ms, mudos %d\n", nomes[caso], r.quadros,
                (r.ultimo + r.ultima_dur) / 90000.0, (long long)r.cortado_ms, mudos);
    }
    free(v);
    fprintf(stderr, "dvd: as células de um minuto conferidas (h)\n");
}

static void confere_som(Resultado *r, const char *nome) {
    int64_t fim = (r->ultimo + r->ultima_dur) * 48000 / 90000;
    for (int k = 0; k < r->n_faixas; k++) {
        int64_t dif = r->amostras[k] - fim;
        CONFERE(llabs(dif) <= 2400, "%s: faixa %d com %lld amostras, o vídeo acaba em %lld (%+lld ms)", nome, k,
                (long long)r->amostras[k], (long long)fim, (long long)(dif * 1000 / 48000));
        fprintf(stderr, "   %s: faixa %d (0x%x): %.3f s, RMS %.0f\n", nome, k, r->info.faixa_id[k],
                r->amostras[k] / 48000.0, r->amostras[k] ? sqrt(r->energia[k] / (2.0 * r->amostras[k])) : 0.0);
    }
}

#endif

int main(int argc, char **argv) {
    testa_croma();
#ifdef SO_DESENTRELACA
    (void)argc; (void)argv;
#else
    testa_setor();
    if (argc >= 3) {
        size_t na, nb;
        uint8_t *a = le_arquivo(argv[1], &na), *b = le_arquivo(argv[2], &nb);
        if (!a || !b || na % DVD_SETOR || nb % DVD_SETOR) { fprintf(stderr, "os VOB de teste não abriram\n"); return 2; }

        // a) NTSC 16:9 entrelaçado (tff), AC-3 5.1 + MP2 mono, modo automático: 6 s
        Resultado r = converte(a, na, NULL, -1, 1, 0, 854, 480);
        CONFERE(r.erro == 0, "a: erro %d", r.erro);
        CONFERE(r.info.largura == 720 && r.info.altura == 480 && r.info.aspecto169 && r.info.entrelacado,
                "a: info %dx%d 16:9=%d entrelaçado=%d", r.info.largura, r.info.altura, r.info.aspecto169, r.info.entrelacado);
        CONFERE(r.info.fps_num == 30000 && r.info.fps_den == 1001, "a: fps %d/%d", r.info.fps_num, r.info.fps_den);
        CONFERE(r.n_faixas == 2 && r.info.faixa_id[0] == 0x80 && r.info.faixa_id[1] == 0x1C0, "a: faixas %d", r.n_faixas);
        CONFERE(r.quadros >= 178 && r.quadros <= 181, "a: %d quadros (6 s a 29,97)", r.quadros);
        CONFERE(r.primeiro >= 0 && r.primeiro <= 3003, "a: o primeiro em %lld", (long long)r.primeiro);
        CONFERE(r.corrigidos == 0, "a: carimbos fora de ordem %d", r.corrigidos);
        confere_som(&r, "a");
        for (int k = 0; k < r.n_faixas; k++) CONFERE(r.energia[k] > 0, "a: faixa %d em silêncio", k);
        int quadros_a = r.quadros;
        int64_t fim_a = r.ultimo + r.ultima_dur;

        // b) as faixas pelo IFO, na ordem dele, com uma que não existe (0x81): sai em silêncio
        int fx[3] = {0x1C0, 0x81, 0x80};
        r = converte(a, na, fx, 3, 1, 0, 640, 480);
        CONFERE(r.erro == 0 && r.n_faixas == 3, "b: erro %d faixas %d", r.erro, r.n_faixas);
        CONFERE(r.info.faixa_id[0] == 0x1C0 && r.info.faixa_visto[0] && !r.info.faixa_visto[1], "b: a ordem do IFO");
        confere_som(&r, "b");
        CONFERE(r.energia[0] > 0 && r.energia[1] == 0 && r.energia[2] > 0, "b: só a 0x81 em silêncio");

        // c) duas células: o mesmo VOB duas vezes (o PTS recomeça), a segunda com o acumulado do
        // fim da primeira: a saída é contínua e dura o dobro.
        r = converte(a, na, NULL, -1, 2, fim_a, 854, 480);
        CONFERE(r.erro == 0, "c: erro %d", r.erro);
        CONFERE(r.quadros >= 2 * quadros_a - 2 && r.quadros <= 2 * quadros_a, "c: %d quadros (2 x %d)", r.quadros, quadros_a);
        CONFERE(r.corrigidos == 0, "c: carimbos fora de ordem %d", r.corrigidos);
        CONFERE(llabs(r.ultimo + r.ultima_dur - 2 * fim_a) <= 3003, "c: acaba em %lld, esperado %lld",
                (long long)(r.ultimo + r.ultima_dur), (long long)(2 * fim_a));
        confere_som(&r, "c");

        // f) o NAV de verdade: o primeiro setor com o PCI preenchido (vobu_s_ptm = o PTS do primeiro
        // quadro de vídeo, que o muxer `dvd` do FFmpeg deixa zerado). As duas células pelo NAV: a
        // saída começa em 0 e continua no acumulado.
        {
            uint8_t *y = malloc(na);
            memcpy(y, a, na);
            uint32_t pts_v = 0;
            for (size_t s = 0; s < na && !pts_v; s += DVD_SETOR) {
                uint8_t *p = y + s;
                int off = 14 + (p[13] & 7);
                if (p[off + 3] == 0xE0 && (p[off + 7] & 0x80)) {
                    const uint8_t *t = p + off + 9;
                    pts_v = (uint32_t)((((int64_t)(t[0] >> 1) & 7) << 30) | ((int64_t)t[1] << 22) |
                                       ((int64_t)(t[2] >> 1) << 15) | ((int64_t)t[3] << 7) | (t[4] >> 1));
                }
            }
            uint8_t *p = y;
            int pci = 14 + (p[13] & 7);
            if (p[pci + 3] == 0xBB) pci += 6 + ((p[pci + 4] << 8) | p[pci + 5]);
            CONFERE(pts_v > 0 && p[pci + 3] == 0xBF && p[pci + 6] == 0, "f: o NAV no setor 0 (pts %u)", pts_v);
            uint8_t *q = p + pci + 6;
            uint32_t e = pts_v + 15015;
            q[0x0D] = (uint8_t)(pts_v >> 24); q[0x0E] = (uint8_t)(pts_v >> 16); q[0x0F] = (uint8_t)(pts_v >> 8); q[0x10] = (uint8_t)pts_v;
            q[0x11] = (uint8_t)(e >> 24); q[0x12] = (uint8_t)(e >> 16); q[0x13] = (uint8_t)(e >> 8); q[0x14] = (uint8_t)e;
            r = converte(y, na, NULL, -1, 2, fim_a, 854, 480);
            CONFERE(r.erro == 0 && r.primeiro == 0, "f: erro %d, o primeiro em %lld", r.erro, (long long)r.primeiro);
            CONFERE(r.corrigidos == 0, "f: carimbos fora de ordem %d", r.corrigidos);
            CONFERE(llabs(r.ultimo + r.ultima_dur - 2 * fim_a) <= 3003, "f: acaba em %lld, esperado %lld",
                    (long long)(r.ultimo + r.ultima_dur), (long long)(2 * fim_a));
            confere_som(&r, "f");
            free(y);
        }

        // g) o acumulado errado em 60 s (um C_PBTM ruim): o salto é rebaseado, e a saída continua
        // durando o dobro, sem minuto de silêncio nem quadro parado (a revisão do código, 5)
        r = converte(a, na, NULL, -1, 2, fim_a + 60 * 90000LL, 854, 480);
        CONFERE(r.erro == 0 && r.corrigidos == 0, "g: erro %d corrigidos %d", r.erro, r.corrigidos);
        CONFERE(llabs(r.ultimo + r.ultima_dur - 2 * fim_a) <= 3003, "g: acaba em %lld, esperado %lld",
                (long long)(r.ultimo + r.ultima_dur), (long long)(2 * fim_a));
        confere_som(&r, "g");

        // d) um setor cifrado no meio: a conversão para com DVD_ERRO_CIFRADO
        uint8_t *x = malloc(na);
        memcpy(x, a, na);
        size_t alvo = 0;
        for (size_t s = na / 2 / DVD_SETOR * DVD_SETOR; s < na; s += DVD_SETOR) {
            uint8_t *p = x + s;
            int off = 14 + (p[13] & 7);
            if (p[3] == 0xBA && p[off] == 0 && p[off + 1] == 0 && p[off + 2] == 1 && p[off + 3] == 0xE0) {
                p[off + 6] |= 0x10;
                alvo = s;
                break;
            }
        }
        CONFERE(alvo > 0, "d: achei um pack de vídeo");
        r = converte(x, na, NULL, -1, 1, 0, 854, 480);
        CONFERE(r.erro == DVD_ERRO_CIFRADO, "d: erro %d (esperado %d)", r.erro, DVD_ERRO_CIFRADO);
        CONFERE(r.quadros < quadros_a, "d: parou antes do fim (%d quadros)", r.quadros);
        free(x);

        // e) PAL 4:3 progressivo, LPCM 96 kHz estéreo: 4 s
        r = converte(b, nb, NULL, -1, 1, 0, 768, 576);
        CONFERE(r.erro == 0, "e: erro %d", r.erro);
        CONFERE(r.info.largura == 720 && r.info.altura == 576 && !r.info.aspecto169 && !r.info.entrelacado,
                "e: info %dx%d 16:9=%d entrelaçado=%d", r.info.largura, r.info.altura, r.info.aspecto169, r.info.entrelacado);
        CONFERE(r.info.fps_num == 25 && r.info.fps_den == 1, "e: fps %d/%d", r.info.fps_num, r.info.fps_den);
        CONFERE(r.quadros >= 99 && r.quadros <= 101, "e: %d quadros", r.quadros);
        CONFERE(r.n_faixas == 1 && r.info.faixa_id[0] == 0xA0, "e: LPCM");
        confere_som(&r, "e");
        // o seno de amplitude 1/8 (o `sine` do lavfi) passa pelo meia-banda sem perder nível: RMS ~2900
        double rms = r.amostras[0] ? sqrt(r.energia[0] / (2.0 * r.amostras[0])) : 0;
        CONFERE(rms > 2600 && rms < 3200, "e: RMS %.0f depois do meia-banda", rms);
        free(a); free(b);
        fprintf(stderr, "dvd: o caminho inteiro conferido (a, b, c, f, g, d, e)\n");
        if (argc >= 4) testa_celulas_de_minuto(argv[3]);
    }
#endif
    if (falhas) { fprintf(stderr, "dvd: %d falha(s)\n", falhas); return 1; }
    printf("dvd: ok\n");
    return 0;
}
