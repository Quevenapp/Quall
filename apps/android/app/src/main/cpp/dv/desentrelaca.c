// O adapt2 generalizado (ver desentrelaca.h). Os limiares e a dilatação são os da fita
// (`qualldv.c`, medidos na fase A da DV).
#include "desentrelaca.h"

#include <stdlib.h>
#include <string.h>

#define LIMIAR_MOV 10
#define LIMIAR_PENTE 3
#define JANELA 3

struct Desentrelacador {
    int w, h, cw, ch;
    uint8_t *ant[3];   // o cru do quadro anterior
    uint8_t *out[3];   // o quadro progressivo
    uint8_t *decisao;  // w x h: a decisão de cada linha interpolada, antes da dilatação
    uint8_t *mascara;  // w x h: depois da dilatação
    int *acum;         // w + 1
    int tem_ant;
    long pontos_bob;
};

Desentrelacador *des_novo(int w, int h) {
    if (w < 16 || h < 16 || (w & 1) || (h & 3) || w > 4096 || h > 4096) return NULL;
    Desentrelacador *d = calloc(1, sizeof(Desentrelacador));
    if (!d) return NULL;
    d->w = w; d->h = h; d->cw = w / 2; d->ch = h / 2;
    for (int p = 0; p < 3; p++) {
        size_t n = p ? (size_t)d->cw * d->ch : (size_t)w * h;
        d->ant[p] = malloc(n);
        d->out[p] = malloc(n);
    }
    d->decisao = calloc((size_t)w, (size_t)h);
    d->mascara = calloc((size_t)w, (size_t)h);
    d->acum = malloc(sizeof(int) * (size_t)(w + 1));
    for (int p = 0; p < 3; p++) if (!d->ant[p] || !d->out[p]) { des_libera(d); return NULL; }
    if (!d->decisao || !d->mascara || !d->acum) { des_libera(d); return NULL; }
    return d;
}

void des_libera(Desentrelacador *d) {
    if (!d) return;
    for (int p = 0; p < 3; p++) { free(d->ant[p]); free(d->out[p]); }
    free(d->decisao); free(d->mascara); free(d->acum);
    free(d);
}

const uint8_t *des_plano(const Desentrelacador *d, int p) { return d->out[p]; }
long des_pontos_bob(const Desentrelacador *d) { return d->pontos_bob; }

int des_luma_do_croma(int cy, int qual, int h) {
    int f = cy & 1, k = cy >> 1;
    int y1 = 4 * k + f;
    if (y1 >= h) y1 = h - 2 + f;  // não acontece com h múltiplo de 4
    if (!qual) return y1;
    int y2 = y1 + 2;
    return y2 < h ? y2 : y1;
}

static int pente(int v, int a, int b) {
    int lo = a < b ? a : b, hi = a < b ? b : a;
    return v > hi ? v - hi : v < lo ? lo - v : 0;
}

// Edge-based line average (a ELA da fita): das três direções, a de menor diferença.
static int ela(const uint8_t *a, const uint8_t *b, int x, int w) {
    int melhor = abs(a[x] - b[x]), r = (a[x] + b[x] + 1) >> 1;
    if (x > 0 && x < w - 1) {
        int d1 = abs(a[x - 1] - b[x + 1]), d2 = abs(a[x + 1] - b[x - 1]);
        if (d1 < melhor) { melhor = d1; r = (a[x - 1] + b[x + 1] + 1) >> 1; }
        if (d2 < melhor) r = (a[x + 1] + b[x - 1] + 1) >> 1;
    }
    return r;
}

// As vizinhas de y no outro campo (y-1 e y+1), com a borda caindo na que existe.
static void vizinhas(int y, int h, int *a, int *b) {
    *a = y - 1 >= 0 ? y - 1 : y + 1;
    *b = y + 1 < h ? y + 1 : y - 1;
}

static void guarda_anterior(Desentrelacador *d, const uint8_t *const in[3], const int is[3]) {
    for (int y = 0; y < d->h; y++) memcpy(d->ant[0] + (size_t)y * d->w, in[0] + (size_t)y * is[0], (size_t)d->w);
    for (int p = 1; p < 3; p++)
        for (int y = 0; y < d->ch; y++)
            memcpy(d->ant[p] + (size_t)y * d->cw, in[p] + (size_t)y * is[p], (size_t)d->cw);
    d->tem_ant = 1;
}

void des_progressivo(Desentrelacador *d, const uint8_t *const in[3], const int is[3]) {
    for (int y = 0; y < d->h; y++) memcpy(d->out[0] + (size_t)y * d->w, in[0] + (size_t)y * is[0], (size_t)d->w);
    for (int p = 1; p < 3; p++)
        for (int y = 0; y < d->ch; y++)
            memcpy(d->out[p] + (size_t)y * d->cw, in[p] + (size_t)y * is[p], (size_t)d->cw);
    d->pontos_bob = 0;
    guarda_anterior(d, in, is);
}

void des_quadro(Desentrelacador *d, const uint8_t *const in[3], const int is[3], int tff) {
    const int w = d->w, h = d->h;
    // O campo que fica é o mais novo: com o de cima primeiro, o de baixo (ímpares); senão as pares.
    const int pi = tff ? 0 : 1;  // a paridade das linhas interpoladas
    const uint8_t *const *ant = d->tem_ant ? (const uint8_t *const *)d->ant : NULL;

    // 1. A decisão, linha interpolada a linha interpolada.
    for (int y = pi; y < h; y += 2) {
        uint8_t *m = d->decisao + (size_t)y * w;
        if (!ant) { memset(m, 1, (size_t)w); continue; }
        int ya, yb;
        vizinhas(y, h, &ya, &yb);
        const uint8_t *l = in[0] + (size_t)y * is[0];
        const uint8_t *a = in[0] + (size_t)ya * is[0];
        const uint8_t *b = in[0] + (size_t)yb * is[0];
        const uint8_t *pl = ant[0] + (size_t)y * w, *pa = ant[0] + (size_t)ya * w, *pb = ant[0] + (size_t)yb * w;
        int *acum = d->acum;
        acum[0] = 0;
        for (int x = 0; x < w; x++) acum[x + 1] = acum[x] + pente(l[x], a[x], b[x]);
        for (int x = 0; x < w; x++) {
            int mov = abs(l[x] - pl[x]);
            int t = abs(a[x] - pa[x]); if (t > mov) mov = t;
            t = abs(b[x] - pb[x]); if (t > mov) mov = t;
            int bob = mov > LIMIAR_MOV;
            if (!bob) {
                int x0 = x - JANELA < 0 ? 0 : x - JANELA;
                int x1 = x + JANELA + 1 > w ? w : x + JANELA + 1;
                bob = acum[x1] - acum[x0] > LIMIAR_PENTE * (x1 - x0);
            }
            m[x] = (uint8_t)bob;
        }
    }
    // 2. A dilatação vertical (y-2, y, y+2), da decisão para a máscara.
    long bobs = 0;
    for (int y = pi; y < h; y += 2) {
        const uint8_t *r0 = d->decisao + (size_t)y * w;
        const uint8_t *rm = y - 2 >= 0 ? r0 - 2 * (size_t)w : r0;
        const uint8_t *rp = y + 2 < h ? r0 + 2 * (size_t)w : r0;
        uint8_t *m = d->mascara + (size_t)y * w;
        for (int x = 0; x < w; x++) { m[x] = (uint8_t)(r0[x] | rm[x] | rp[x]); bobs += m[x]; }
    }
    d->pontos_bob = bobs;
    // 3. A luma.
    for (int y = 0; y < h; y++) {
        const uint8_t *l = in[0] + (size_t)y * is[0];
        uint8_t *o = d->out[0] + (size_t)y * w;
        if ((y & 1) != pi) { memcpy(o, l, (size_t)w); continue; }
        int ya, yb;
        vizinhas(y, h, &ya, &yb);
        const uint8_t *a = in[0] + (size_t)ya * is[0];
        const uint8_t *b = in[0] + (size_t)yb * is[0];
        const uint8_t *m = d->mascara + (size_t)y * w;
        for (int x = 0; x < w; x++) o[x] = m[x] ? (uint8_t)ela(a, b, x, w) : l[x];
    }
    // 4. O croma: a linha cy é do campo cy & 1 (a regra do cabeçalho).
    for (int p = 1; p < 3; p++) {
        for (int cy = 0; cy < d->ch; cy++) {
            const uint8_t *l = in[p] + (size_t)cy * is[p];
            uint8_t *o = d->out[p] + (size_t)cy * d->cw;
            if ((cy & 1) != pi) { memcpy(o, l, (size_t)d->cw); continue; }
            int ca, cb;
            vizinhas(cy, d->ch, &ca, &cb);
            const uint8_t *a = in[p] + (size_t)ca * is[p];
            const uint8_t *b = in[p] + (size_t)cb * is[p];
            const uint8_t *m1 = d->mascara + (size_t)des_luma_do_croma(cy, 0, h) * w;
            const uint8_t *m2 = d->mascara + (size_t)des_luma_do_croma(cy, 1, h) * w;
            for (int x = 0; x < d->cw; x++) {
                int bob = m1[2 * x] | m1[2 * x + 1] | m2[2 * x] | m2[2 * x + 1];
                o[x] = bob ? (uint8_t)((a[x] + b[x] + 1) >> 1) : l[x];
            }
        }
    }
    guarda_anterior(d, in, is);
}
