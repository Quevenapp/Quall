// Teste de mesa da remontagem (cpp/dv/remontagem.c), no Mac, sem USB nem FFmpeg: payloads UVC
// sintéticos, e os casos que a P0 da placa de captura mediu (docs/placa-de-captura-usb.md §8.1).
// Roda por `apps/android/tools/testa-remontagem.sh` (e pelo portão, na superfície android-so).
// Argumentos opcionais: arquivos JPEG de verdade (o script gera um com o ffmpeg do Mac), que
// `jpeg_fim` tem de atravessar até o fim.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../app/src/main/cpp/dv/remontagem.h"

static int falhas = 0;
#define CONFERE(c, ...) do { if (!(c)) { falhas++; printf("FALHOU %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// ------------------------------------------------------------------ o que foi entregue
#define MAX_ENT 16
static struct { size_t n; int64_t ts; int ruim; uint8_t *q; } ent[MAX_ENT];
static int n_ent;

static void entrega(void *ctx, const uint8_t *q, size_t n, int64_t ts, int ruim) {
    (void)ctx;
    if (n_ent >= MAX_ENT) return;
    ent[n_ent].n = n;
    ent[n_ent].ts = ts;
    ent[n_ent].ruim = ruim;
    ent[n_ent].q = malloc(n);
    memcpy(ent[n_ent].q, q, n);
    n_ent++;
}

static void zera_entregas(void) {
    for (int i = 0; i < n_ent; i++) free(ent[i].q);
    n_ent = 0;
}

// ------------------------------------------------------------------ o envio em pacotes
static int fid_global = 0;

// Manda `n` bytes como um quadro UVC em pacotes de até `carga` bytes de dado (cabeçalho de 12);
// `err_no` = índice do pacote com o bit ERR (-1 nenhum); `eof` = o último pacote leva EOF (senão o
// quadro fecha na troca de FID do próximo); `ruim_no` = pacote que "chega com erro" (-1 nenhum).
static void manda_quadro(Remontagem *r, const uint8_t *q, size_t n, size_t carga, int err_no, int eof,
                         int ruim_no, int64_t ts) {
    uint8_t pk[4096];
    size_t off = 0;
    int k = 0;
    while (off < n) {
        size_t m = n - off < carga ? n - off : carga;
        int ultimo = off + m == n;
        pk[0] = 12;
        pk[1] = (uint8_t)(0x80 | fid_global | (eof && ultimo ? 2 : 0) | (k == err_no ? 0x40 : 0));
        memset(pk + 2, 0, 10);
        memcpy(pk + 12, q + off, m);
        if (k == ruim_no) remonta_pacote_ruim(r);
        else remonta_payload(r, pk, 12 + m, ts);
        off += m;
        k++;
    }
    fid_global ^= 1;
}

// Um pacote só de cabeçalho com o FID novo: fecha o quadro anterior por troca de FID.
static void troca_fid(Remontagem *r, int64_t ts) {
    uint8_t pk[12] = {12, (uint8_t)(0x80 | fid_global)};
    remonta_payload(r, pk, 12, ts);
}

// ------------------------------------------------------------------ JPEGs sintéticos
// Monta um JPEG estruturalmente válido de `alvo` bytes (aprox.): SOI, APP0, DQT, SOF0, DHT, SOS,
// dado entrópico com FF00 e RST, EOI. `exif`: um APP1 com uma miniatura (FF D8 ... FF D9) dentro.
static size_t jpeg_sintetico(uint8_t *o, size_t alvo, int exif, uint8_t semente) {
    size_t i = 0;
    o[i++] = 0xFF; o[i++] = 0xD8;
    // APP0 JFIF
    static const uint8_t app0[] = {0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0};
    memcpy(o + i, app0, sizeof app0); i += sizeof app0;
    if (exif) {
        // APP1 com uma miniatura inteira dentro (FF D8 ... FF D9): a caminhada pula pelo comprimento
        uint8_t mini[] = {0xFF, 0xD8, 0xFF, 0xD9, 0xFF, 0xD9, 0xFF, 0xD8, 0x12, 0x34};
        size_t L = 2 + 6 + sizeof mini;
        o[i++] = 0xFF; o[i++] = 0xE1; o[i++] = (uint8_t)(L >> 8); o[i++] = (uint8_t)L;
        memcpy(o + i, "Exif\0\0", 6); i += 6;
        memcpy(o + i, mini, sizeof mini); i += sizeof mini;
    }
    // DQT (65 bytes de tabela), com um FF D9 dentro (dado de segmento não é marcador)
    o[i++] = 0xFF; o[i++] = 0xDB; o[i++] = 0; o[i++] = 67; o[i++] = 0;
    for (int k = 0; k < 64; k++) o[i++] = (uint8_t)(k == 10 ? 0xFF : k == 11 ? 0xD9 : k + 1);
    // SOF0 640x480, 3 componentes 4:2:2
    static const uint8_t sof[] = {0xFF, 0xC0, 0, 17, 8, 0x01, 0xE0, 0x02, 0x80, 3, 1, 0x21, 0, 2, 0x11, 1, 3, 0x11, 1};
    memcpy(o + i, sof, sizeof sof); i += sizeof sof;
    // DHT mínimo (um código)
    static const uint8_t dht[] = {0xFF, 0xC4, 0, 20, 0x00, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    memcpy(o + i, dht, sizeof dht); i += sizeof dht;
    // SOS
    static const uint8_t sos[] = {0xFF, 0xDA, 0, 12, 3, 1, 0, 2, 0x11, 3, 0x11, 0, 63, 0};
    memcpy(o + i, sos, sizeof sos); i += sizeof sos;
    // dado entrópico: bytes pseudoaleatórios, FF sempre recheado (FF 00), um RST a cada 4 KB
    uint32_t x = 2463534242u ^ semente;
    int rst = 0;
    while (i + 4 < alvo) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        uint8_t b = (uint8_t)x;
        if (i % 4096 == 0) { o[i++] = 0xFF; o[i++] = (uint8_t)(0xD0 + (rst++ & 7)); continue; }
        o[i++] = b;
        if (b == 0xFF) o[i++] = 0x00;
    }
    o[i++] = 0xFF; o[i++] = 0xD9;
    return i;
}

static Remontagem novo(int formato, size_t cap) {
    Remontagem r;
    if (remonta_inicia(&r, formato, cap, entrega, NULL) < 0) { printf("sem memória\n"); exit(2); }
    return r;
}

#define U(x) ((unsigned long long)atomic_load(&(x)))

// ------------------------------------------------------------------ os casos
static void caso_urbs(void) {
    int u, p;
    // A DV com a regra da placa desde 30/09 (o A07 perdia o conteúdo com 16 x 32): 128 x 3 = 384.
    dimensiona_urbs(FORMATO_DV, 492, &u, &p);
    CONFERE(u == 128 && p == 3, "DV psize 492: %d URBs de %d (esperado 128 de 3)", u, p);
    // A placa: no máximo 3 pacotes por URB e 384 em trânsito (o A07, §11.0), menos os 32 do som
    // (§13.10): 117 x 3.
    dimensiona_urbs(FORMATO_MJPEG, 3000, &u, &p);
    CONFERE(u == 117 && p == 3, "placa psize 3000: %d URBs de %d (esperado 117 de 3)", u, p);
    CONFERE(u * p + SOM_URBS * SOM_PACOTES <= PACOTES_EM_TRANSITO_MJPEG, "vídeo + som acima de 384 em trânsito");
    CONFERE(3000 * p <= BYTES_POR_URB, "URB da placa acima de 32 KB");
    CONFERE((long)u * p * 3000 <= 1600000L, "a placa passa de 1,6 MB de URBs: %ld", (long)u * p * 3000);
    dimensiona_urbs(FORMATO_MJPEG, 960, &u, &p);
    CONFERE(u == 117 && p == 3, "MJPEG psize 960: %d x %d (esperado 117 de 3)", u, p);
    dimensiona_urbs(FORMATO_MJPEG, 20000, &u, &p);
    CONFERE(u == 256 && p == 1, "MJPEG psize 20000: %d x %d (esperado 256 de 1: 256 em trânsito)", u, p);
    dimensiona_urbs(FORMATO_DV, 1024, &u, &p);
    CONFERE(u == 128 && p == 3, "DV psize 1024: %d x %d", u, p);
    dimensiona_urbs(FORMATO_DV, 40000, &u, &p);
    CONFERE(p == 1 && u == MAX_URBS, "DV psize 40000: %d x %d", u, p);
}

static void quadro_dv(uint8_t *q) {
    memset(q, 0x55, QUADRO_DV);
    q[0] = 0x1F; q[1] = 0x07; q[2] = 0x00; q[3] = 0x3F;
    q[80] = 0x3F; q[81] = 0x07; q[82] = 0x00;
}

static void caso_dv(void) {
    static uint8_t q[QUADRO_DV];
    quadro_dv(q);
    Remontagem r = novo(FORMATO_DV, 0);
    manda_quadro(&r, q, QUADRO_DV, 480, -1, 1, -1, 1000);
    CONFERE(n_ent == 1 && ent[0].n == QUADRO_DV && !memcmp(ent[0].q, q, QUADRO_DV), "DV íntegro: %d entregas", n_ent);
    zera_entregas();
    // com ERR, fora da gravação: cai; na gravação: vai, contado como ruim
    manda_quadro(&r, q, QUADRO_DV, 480, 3, 1, -1, 2000);
    CONFERE(n_ent == 0 && U(r.tortos) == 1, "DV com ERR fora da gravação: %d entregas, %llu tortos", n_ent, U(r.tortos));
    r.aceitar_ruim = 1;
    manda_quadro(&r, q, QUADRO_DV, 480, 3, 1, -1, 3000);
    CONFERE(n_ent == 1 && ent[0].ruim && U(r.ruins_entregues) == 1, "DV com ERR na gravação: %d entregas", n_ent);
    zera_entregas();
    r.aceitar_ruim = 0;
    // sem EOF: fecha na troca de FID
    manda_quadro(&r, q, QUADRO_DV, 480, -1, 0, -1, 4000);
    CONFERE(n_ent == 0, "DV sem EOF fechou antes da troca de FID");
    troca_fid(&r, 5000);
    CONFERE(n_ent == 1 && ent[0].ts == 5000, "DV sem EOF: %d entregas", n_ent);
    zera_entregas();
    // tamanho errado: torto
    manda_quadro(&r, q, QUADRO_DV - 480, 480, -1, 1, -1, 6000);
    CONFERE(n_ent == 0, "DV curto entregue");
    CONFERE(U(r.integros) == 3, "DV: %llu íntegros (esperado 3)", U(r.integros));
    // um cabeçalho inválido no meio de um quadro DV é ignorado como sempre (a regra da GS500)
    {
        uint8_t torto[5] = {40, 0x80, 1, 2, 3};
        manda_quadro(&r, q, QUADRO_DV / 2, 480, -1, 0, -1, 7000);
        remonta_payload(&r, torto, sizeof torto, 7000);
        fid_global ^= 1;  // o mesmo FID: continua o quadro
        manda_quadro(&r, q + QUADRO_DV / 2, QUADRO_DV / 2, 480, -1, 1, -1, 7000);
        CONFERE(n_ent == 1 && !ent[0].ruim, "DV com cabeçalho inválido no meio: %d entregas", n_ent);
        zera_entregas();
    }
    remonta_libera(&r);
}

static void caso_mjpeg(void) {
    const size_t cap = 614400;  // o dwMaxVideoFrameSize da placa
    static uint8_t j1[300000], j2[300000], q[700000];
    size_t n1 = jpeg_sintetico(j1, 54000, 0, 1);  // a média medida (54 KB)
    size_t n2 = jpeg_sintetico(j2, 53000, 1, 2);

    CONFERE(jpeg_fim(j1, n1) == n1, "jpeg_fim do sintético: %zu de %zu", jpeg_fim(j1, n1), n1);
    CONFERE(jpeg_fim(j2, n2) == n2, "jpeg_fim do sintético com EXIF: %zu de %zu", jpeg_fim(j2, n2), n2);

    Remontagem r = novo(FORMATO_MJPEG, cap);
    // 1. um JPEG inteiro, em pacotes de 2988 (3000 - 12)
    manda_quadro(&r, j1, n1, 2988, -1, 1, -1, 1000000000);
    CONFERE(n_ent == 1 && ent[0].n == n1 && !memcmp(ent[0].q, j1, n1), "MJPEG inteiro: %d entregas", n_ent);
    zera_entregas();

    // 2. zeros depois do EOI: vai, sem os zeros
    memcpy(q, j1, n1);
    memset(q + n1, 0, 700);
    manda_quadro(&r, q, n1 + 700, 2988, -1, 1, -1, 1033333333);
    CONFERE(n_ent == 1 && ent[0].n == n1, "MJPEG com zeros depois do EOI: %d entregas, %zu bytes", n_ent, n_ent ? ent[0].n : 0);
    zera_entregas();

    // 3. o bit ERR: cai
    manda_quadro(&r, j1, n1, 2988, 5, 1, -1, 1066666666);
    CONFERE(n_ent == 0 && U(r.descartados_ruins) == 1, "MJPEG com ERR entregue");
    // 4. um pacote com erro: cai
    manda_quadro(&r, j1, n1, 2988, -1, 1, 7, 1099999999);
    CONFERE(n_ent == 0 && U(r.descartados_ruins) == 2, "MJPEG com pacote ruim entregue");

    // 5. dois JPEG colados no mesmo quadro UVC (medido: 0,7 %): os dois, na ordem, o primeiro um
    //    quadro antes
    memcpy(q, j1, n1);
    memcpy(q + n1, j2, n2);
    manda_quadro(&r, q, n1 + n2, 2988, -1, 1, -1, 2000000000);
    CONFERE(n_ent == 2, "dois JPEG colados: %d entregas (esperado 2)", n_ent);
    if (n_ent == 2) {
        CONFERE(ent[0].n == n1 && !memcmp(ent[0].q, j1, n1), "o primeiro JPEG veio errado (%zu)", ent[0].n);
        CONFERE(ent[1].n == n2 && !memcmp(ent[1].q, j2, n2), "o segundo JPEG veio errado (%zu)", ent[1].n);
        CONFERE(ent[1].ts == 2000000000 && ent[0].ts == 2000000000 - PASSO_JPEG_NS, "carimbos %lld %lld",
                (long long)ent[0].ts, (long long)ent[1].ts);
    }
    CONFERE(U(r.dois_em_um) == 1, "dois_em_um=%llu", U(r.dois_em_um));
    zera_entregas();

    // 6. o EXIF com miniatura (FF D8 ... FF D9 dentro do APP1) não parte o JPEG
    manda_quadro(&r, j2, n2, 2988, -1, 1, -1, 2033333333);
    CONFERE(n_ent == 1 && ent[0].n == n2, "JPEG com miniatura EXIF: %d entregas", n_ent);
    zera_entregas();

    // 7. maior que os 120 000 da DV (a P0 mediu até 113 KB; 200 KB aqui)
    static uint8_t grande[300000];
    size_t ng = jpeg_sintetico(grande, 200000, 0, 3);
    manda_quadro(&r, grande, ng, 2988, -1, 1, -1, 3000000000LL);
    CONFERE(n_ent == 1 && ent[0].n == ng && ng > 120000, "JPEG de %zu bytes: %d entregas", ng, n_ent);
    zera_entregas();

    // 8. maior que o dwMaxVideoFrameSize: cai como grande demais
    Remontagem pequena = novo(FORMATO_MJPEG, 100000);
    manda_quadro(&pequena, grande, ng, 2988, -1, 1, -1, 1);
    CONFERE(n_ent == 0 && U(pequena.grande_demais) == 1, "acima do cap entregue");
    // e o seguinte, normal, passa (o estado foi zerado)
    manda_quadro(&pequena, j1, n1, 2988, -1, 1, -1, 2);
    CONFERE(n_ent == 1 && ent[0].n == n1, "o quadro depois do grande demais não passou");
    zera_entregas();
    remonta_libera(&pequena);

    // 9. sem SOI (o começo perdido): cai
    manda_quadro(&r, j1 + 100, n1 - 100, 2988, -1, 1, -1, 4000000000LL);
    CONFERE(n_ent == 0 && U(r.sem_soi) == 1, "sem SOI entregue");
    // 10. sem EOI (o fim cortado): cai
    manda_quadro(&r, j1, n1 - 5000, 2988, -1, 1, -1, 4100000000LL);
    CONFERE(n_ent == 0 && U(r.sem_eoi) == 1, "sem EOI entregue");
    // 11. dois colados com o segundo cortado: o primeiro vai, o resto conta como sem EOI
    memcpy(q, j1, n1);
    memcpy(q + n1, j2, n2 - 3000);
    manda_quadro(&r, q, n1 + n2 - 3000, 2988, -1, 1, -1, 4200000000LL);
    CONFERE(n_ent == 1 && ent[0].n == n1 && U(r.sem_eoi) == 2, "colado com o segundo cortado: %d entregas", n_ent);
    zera_entregas();
    // 11b. lixo não-zero depois do EOI: o JPEG vai, e o lixo conta à parte (não é torto)
    unsigned long long tortos_antes = U(r.tortos);
    memcpy(q, j1, n1);
    memset(q + n1, 0x5A, 300);
    manda_quadro(&r, q, n1 + 300, 2988, -1, 1, -1, 4250000000LL);
    CONFERE(n_ent == 1 && ent[0].n == n1 && U(r.lixo_depois_do_eoi) == 1 && U(r.tortos) == tortos_antes,
            "lixo depois do EOI: %d entregas, lixo=%llu", n_ent, U(r.lixo_depois_do_eoi));
    zera_entregas();
    // 11c. um pacote com cabeçalho UVC inválido no meio do quadro: o quadro cai como ruim
    {
        uint8_t pk[3000];
        pk[0] = 12; pk[1] = (uint8_t)(0x80 | fid_global);
        memset(pk + 2, 0, 10);
        memcpy(pk + 12, j1, 2000);
        remonta_payload(&r, pk, 12 + 2000, 4260000000LL);
        uint8_t torto[5] = {40, 0x80, 1, 2, 3};  // bHeaderLength 40 > 5
        remonta_payload(&r, torto, sizeof torto, 4260000000LL);
        remonta_payload(&r, torto, 0, 4260000000LL);  // len 0: nada
        pk[1] |= 2;  // EOF
        memcpy(pk + 12, j1 + 2000, 800);
        remonta_payload(&r, pk, 12 + 800, 4260000000LL);
        fid_global ^= 1;
        CONFERE(n_ent == 0 && U(r.cabecalho_invalido) == 1, "cabeçalho inválido: %d entregas, %llu inválidos",
                n_ent, U(r.cabecalho_invalido));
    }
    // 12. lixo que não é JPEG estruturado, mas com SOI no começo e EOI no fim: vai inteiro pela borda
    uint8_t esquisito[64];
    memset(esquisito, 0x33, sizeof esquisito);
    esquisito[0] = 0xFF; esquisito[1] = 0xD8; esquisito[62] = 0xFF; esquisito[63] = 0xD9;
    manda_quadro(&r, esquisito, sizeof esquisito, 2988, -1, 1, -1, 4300000000LL);
    CONFERE(n_ent == 1 && ent[0].n == sizeof esquisito && U(r.so_pela_borda) == 1, "pela borda: %d entregas", n_ent);
    zera_entregas();
    // 13. sem EOF: fecha na troca de FID
    manda_quadro(&r, j1, n1, 2988, -1, 0, -1, 4400000000LL);
    CONFERE(n_ent == 0, "MJPEG sem EOF fechou antes da troca");
    troca_fid(&r, 4433333333LL);
    CONFERE(n_ent == 1 && ent[0].n == n1, "MJPEG sem EOF: %d entregas", n_ent);
    zera_entregas();
    // um MJPEG com ERR nunca vai, nem com aceitar_ruim (a gravação é só da DV)
    r.aceitar_ruim = 1;
    manda_quadro(&r, j1, n1, 2988, 2, 1, -1, 4500000000LL);
    CONFERE(n_ent == 0, "MJPEG com ERR entregue com aceitar_ruim");
    printf("MJPEG: integros=%llu tortos=%llu sem_soi=%llu sem_eoi=%llu grande=%llu ruins=%llu dois_em_um=%llu borda=%llu "
           "lixo=%llu cab_invalido=%llu\n",
           U(r.integros), U(r.tortos), U(r.sem_soi), U(r.sem_eoi), U(r.grande_demais), U(r.descartados_ruins),
           U(r.dois_em_um), U(r.so_pela_borda), U(r.lixo_depois_do_eoi), U(r.cabecalho_invalido));
    remonta_libera(&r);
}

// JPEGs de verdade (do ffmpeg do Mac): a caminhada chega ao EOI no fim do arquivo.
static void caso_arquivo(const char *caminho) {
    FILE *f = fopen(caminho, "rb");
    if (!f) { CONFERE(0, "não abri %s", caminho); return; }
    static uint8_t b[4 << 20];
    size_t n = fread(b, 1, sizeof b, f);
    fclose(f);
    size_t m = n;
    while (m > 2 && b[m - 1] == 0) m--;
    size_t fim = jpeg_fim(b, n);
    CONFERE(fim == m, "%s: jpeg_fim %zu de %zu", caminho, fim, m);
    // e colado nele mesmo, pela remontagem: dois
    static uint8_t dois[8 << 20];
    memcpy(dois, b, m);
    memcpy(dois + m, b, m);
    Remontagem r = novo(FORMATO_MJPEG, 8 << 20);
    manda_quadro(&r, dois, 2 * m, 2988, -1, 1, -1, 1);
    CONFERE(n_ent == 2 && ent[0].n == m && ent[1].n == m, "%s colado: %d entregas", caminho, n_ent);
    zera_entregas();
    remonta_libera(&r);
    printf("arquivo %s: %zu bytes, fim em %zu\n", caminho, n, fim);
}

int main(int argc, char **argv) {
    caso_urbs();
    caso_dv();
    caso_mjpeg();
    for (int i = 1; i < argc; i++) caso_arquivo(argv[i]);
    if (falhas) { printf("remontagem: %d falha(s)\n", falhas); return 1; }
    printf("remontagem: ok\n");
    return 0;
}
