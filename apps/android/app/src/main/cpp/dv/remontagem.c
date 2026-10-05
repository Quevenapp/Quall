// A remontagem dos payloads UVC (ver remontagem.h).
//
// **DV** (a GS500, provada): o de sempre, sem mudança de regra — o quadro fecha na troca de FID ou
// no EOF, e só vale com exatamente 120 000 bytes e o começo DIF; com ERR ou pacote com erro, só na
// gravação (`aceitar_ruim`).
//
// **MJPEG** (a placa de captura, medida na P0, §8.1): o quadro tem tamanho variável até o
// `dwMaxVideoFrameSize`, e vale só inteiro — sem ERR nem pacote com erro, começando com SOI
// (FF D8) e acabando num EOI (FF D9), com zeros depois tolerados. O fim é achado andando pelos
// segmentos do JPEG (`jpeg_fim`), e não só olhando os dois últimos bytes, porque 0,7 % dos quadros
// UVC da placa trazem **dois JPEG inteiros colados** (EOI e SOI no meio, o FID sem trocar): os dois
// são entregues, o primeiro com o carimbo um quadro antes. Se a caminhada não fecha mas as bordas
// fecham (SOI no começo, EOI no fim), o quadro vai inteiro, como a P0 julgou (`so_pela_borda`
// conta: um JPEG que a caminhada não entende é achado a olhar, e não defeito da placa).

#include "remontagem.h"

#include <stdlib.h>
#include <string.h>

int remonta_inicia(Remontagem *r, int formato, size_t cap_quadro, EntregaFn entregar, void *ctx) {
    memset(r, 0, sizeof *r);
    r->formato = formato;
    r->cap = formato == FORMATO_MJPEG ? cap_quadro : CAP_ACUM_DV;
    r->acum = malloc(r->cap);
    r->ultimo_fid = -1;
    r->entregar = entregar;
    r->ctx = ctx;
    return r->acum ? 0 : -1;
}

void remonta_libera(Remontagem *r) {
    free(r->acum);
    r->acum = NULL;
}

static int inicio_dif(const uint8_t *p) {
    if (p[0] != 0x1F || p[1] != 0x07 || p[2] != 0x00) return 0;
    if (p[80] != 0x3F || p[81] != 0x07 || p[82] != 0x00) return 0;
    return (p[3] & 0x80) ? 2 : 1;
}

size_t jpeg_fim(const uint8_t *q, size_t n) {
    if (n < 4 || q[0] != 0xFF || q[1] != 0xD8) return 0;
    size_t i = 2;
    for (;;) {
        // um marcador: FF (com FFs de preenchimento) e o código
        if (i >= n || q[i] != 0xFF) return 0;
        while (i < n && q[i] == 0xFF) i++;
        if (i >= n) return 0;
        uint8_t m = q[i++];
        if (m == 0xD9) return i;                           // EOI
        if (m == 0xD8 || m == 0x00) return 0;              // SOI dentro do JPEG, ou FF00 fora do dado: torto
        if (m == 0x01 || (m >= 0xD0 && m <= 0xD7)) continue;  // TEM e RSTn não têm comprimento
        if (i + 2 > n) return 0;
        size_t len = ((size_t)q[i] << 8) | q[i + 1];
        if (len < 2 || i + len > n) return 0;
        i += len;
        if (m != 0xDA) continue;
        // SOS: o dado entrópico corre até um FF que não seja FF00 (byte recheado) nem RSTn.
        for (;;) {
            const uint8_t *ff = memchr(q + i, 0xFF, n - i);
            if (!ff) return 0;
            i = (size_t)(ff - q);
            if (i + 1 >= n) return 0;
            uint8_t c = q[i + 1];
            if (c == 0x00 || (c >= 0xD0 && c <= 0xD7)) { i += 2; continue; }
            if (c == 0xFF) { i++; continue; }  // preenchimento antes do marcador
            break;                              // um marcador: volta ao laço de fora
        }
    }
}

// As bordas, como a P0 (`julga_jpeg` do espião): SOI no começo e EOI no fim, zeros depois.
static int bordas_ok(const uint8_t *q, size_t n) {
    if (n < 4 || q[0] != 0xFF || q[1] != 0xD8) return 0;
    while (n > 2 && q[n - 1] == 0) n--;
    return q[n - 2] == 0xFF && q[n - 1] == 0xD9;
}

static void fecha_dv(Remontagem *r, int64_t ts) {
    if (r->n == QUADRO_DV && (!r->ruim || r->aceitar_ruim) && inicio_dif(r->acum) == 1) {
        if (r->ruim) atomic_fetch_add(&r->ruins_entregues, 1);
        atomic_fetch_add(&r->integros, 1);
        r->entregar(r->ctx, r->acum, QUADRO_DV, ts, r->ruim);
    } else {
        atomic_fetch_add(&r->tortos, 1);
    }
}

static void fecha_mjpeg(Remontagem *r, int64_t ts) {
    const uint8_t *q = r->acum;
    size_t n = r->n;
    if (r->ruim) {
        atomic_fetch_add(&r->tortos, 1);
        atomic_fetch_add(&r->descartados_ruins, 1);
        return;
    }
    if (r->grande) {
        atomic_fetch_add(&r->tortos, 1);
        atomic_fetch_add(&r->grande_demais, 1);
        return;
    }
    if (n < 2 || q[0] != 0xFF || q[1] != 0xD8) {
        atomic_fetch_add(&r->tortos, 1);
        atomic_fetch_add(&r->sem_soi, 1);
        return;
    }
    size_t ini[MAX_JPEG_POR_QUADRO], tam[MAX_JPEG_POR_QUADRO];
    // sobra: 1 = depois do último JPEG inteiro há bytes que não são zero nem começam um JPEG (lixo
    // depois do EOI); 2 = começa um JPEG que não termina (cortado)
    int k = 0, sobra = 0;
    size_t pos = 0;
    for (;;) {
        if (k == MAX_JPEG_POR_QUADRO || n - pos < 2 || q[pos] != 0xFF || q[pos + 1] != 0xD8) {
            sobra = 1;
            break;
        }
        size_t f = jpeg_fim(q + pos, n - pos);
        if (!f) { sobra = 2; break; }
        ini[k] = pos;
        tam[k] = f;
        k++;
        pos += f;
        while (pos < n && q[pos] == 0) pos++;
        if (pos == n) break;
    }
    if (k == 0) {
        if (bordas_ok(q, n)) {
            // A caminhada não entendeu este JPEG, mas as bordas fecham: vai inteiro (o decodificador
            // julga), como a P0 aceitava.
            atomic_fetch_add(&r->so_pela_borda, 1);
            atomic_fetch_add(&r->integros, 1);
            size_t m = n;
            while (m > 2 && q[m - 1] == 0) m--;
            r->entregar(r->ctx, q, m, ts, 0);
        } else {
            atomic_fetch_add(&r->tortos, 1);
            atomic_fetch_add(&r->sem_eoi, 1);
        }
        return;
    }
    if (k >= 2) atomic_fetch_add(&r->dois_em_um, 1);
    for (int j = 0; j < k; j++) {
        atomic_fetch_add(&r->integros, 1);
        r->entregar(r->ctx, q + ini[j], tam[j], ts - (int64_t)(k - 1 - j) * PASSO_JPEG_NS, 0);
    }
    if (sobra == 2) {
        // Os JPEG inteiros foram; um JPEG colado e cortado depois deles é torto (sem EOI).
        atomic_fetch_add(&r->tortos, 1);
        atomic_fetch_add(&r->sem_eoi, 1);
    } else if (sobra == 1) {
        // Lixo não-zero depois do EOI: o quadro foi inteiro, e isto não é torto (a revisão do
        // código da P1, 5); conta à parte.
        atomic_fetch_add(&r->lixo_depois_do_eoi, 1);
    }
}

// Não comprimido (NV12): vale só com o tamanho exato e sem erro. Curto conta em `sem_eoi`.
static void fecha_cru(Remontagem *r, int64_t ts) {
    if (r->ruim) {
        atomic_fetch_add(&r->tortos, 1);
        atomic_fetch_add(&r->descartados_ruins, 1);
    } else if (r->grande || r->n > r->cru_tam) {
        atomic_fetch_add(&r->tortos, 1);
        atomic_fetch_add(&r->grande_demais, 1);
    } else if (r->n != r->cru_tam) {
        atomic_fetch_add(&r->tortos, 1);
        atomic_fetch_add(&r->sem_eoi, 1);
    } else {
        atomic_fetch_add(&r->integros, 1);
        r->entregar(r->ctx, r->acum, r->n, ts, 0);
    }
}

static void fecha_quadro(Remontagem *r, int64_t ts) {
    if (r->n == 0) return;
    if (r->cru_tam) fecha_cru(r, ts);
    else if (r->formato == FORMATO_MJPEG) fecha_mjpeg(r, ts);
    else fecha_dv(r, ts);
    r->n = 0;
    r->ruim = 0;
    r->grande = 0;
}

void remonta_payload(Remontagem *r, const uint8_t *p, size_t len, int64_t ts) {
    if (len == 0) return;  // o pacote vazio de sempre (microquadro sem dado)
    if (len < 2 || p[0] < 2 || p[0] > len) {
        // Cabeçalho UVC inválido num pacote com bytes: no MJPEG o quadro em curso perdeu um pedaço
        // e fica ruim (a revisão do código da P1, 3). Na DV, ignorado como sempre (não se mexe no
        // que a GS500 provou; um pedaço perdido já derruba o quadro pelos 120 000 bytes).
        atomic_fetch_add(&r->cabecalho_invalido, 1);
        if (r->formato == FORMATO_MJPEG && r->n) r->ruim = 1;
        return;
    }
    size_t hl = p[0];
    int fid = p[1] & 1, eof = (p[1] >> 1) & 1, err = (p[1] >> 6) & 1;
    if (r->ultimo_fid >= 0 && fid != r->ultimo_fid) fecha_quadro(r, ts);
    r->ultimo_fid = fid;
    if (err) { r->ruim = 1; atomic_fetch_add(&r->err_bit, 1); }
    size_t n = len - hl;
    if (n) {
        if (r->n + n <= r->cap) memcpy(r->acum + r->n, p + hl, n);
        else if (r->formato == FORMATO_MJPEG) r->grande = 1;
        else r->ruim = 1;  // a DV de sempre: o quadro já não terá 120 000 bytes
        r->n += n;
        if (r->n > r->cap) r->n = r->cap;
    }
    if (eof) fecha_quadro(r, ts);
}
