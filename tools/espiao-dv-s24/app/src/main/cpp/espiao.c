// Espião DV: lê o endpoint de vídeo de uma câmera UVC pelo usbfs (fd do UsbDeviceConnection) e
// conta quadros DV por segundo. Sem libusb: as URBs vão direto por ioctl.
//
// Desenho e revisão adversarial: quall-scratch/dv-s24/desenho.md (§6). O que se conta:
// - no FLUXO CRU (independe de FID/EOF, é o veredito principal): começos de quadro DV (bloco de
//   cabeçalho DIF da sequência 0 seguido do subcódigo da sequência 0) e a distância em bytes entre
//   começos seguidos; `dif_120000` é a distância exata de um quadro DV 525/60;
// - por pacote isócrono (ou payload bulk): erro de pacote, vazio, só cabeçalho, cabeçalho
//   inválido, bit ERR;
// - quadros montados como o `uvcvideo` monta (FID que troca ou EOF fecham o quadro), como
//   diagnóstico de como o aparelho marca os quadros: "dv_completos" é o quadro montado de exatamente
//   120 000 bytes, começo DIF no byte 0, sem ERR nem pacote com erro dentro dele.
//
// Uma thread só (a que chama rodar) colhe, reenvia, descarta e conta; parar() só liga a bandeira.
//
// **MJPEG** (a placa de captura, `docs/placa-de-captura-usb.md` P0): o mesmo quadro por FID/EOF é
// julgado como JPEG — SOI (FF D8) no começo, EOI (FF D9) no fim (zeros depois tolerados), quantos
// SOI dentro (dois campos num quadro?), e os tamanhos. `gravar` guarda os N primeiros JPEG bons, um
// arquivo cada. As URBs são configuráveis (número e pacotes por URB), com `mmap` opcional do fd do
// usbfs, e o reenvio recusado é **contado e tentado de novo** em vez de a URB sair de circulação.

#include <jni.h>
#include <android/log.h>
#include <errno.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <linux/usbdevice_fs.h>

#define ETIQUETA "EspiaoDV"
#define LOG(...) __android_log_print(ANDROID_LOG_INFO, ETIQUETA, __VA_ARGS__)

#define MAX_URBS 256
static int N_URBS = 12;
static int N_PACOTES = 64;    // pacotes isócronos por URB (o usbfs aceita até 128); 12x64 = 96 ms
#define QUADRO_DV_525 120000  // 10 sequências DIF x 150 blocos x 80 bytes
#define QUADRO_DV_625 144000
#define CAP_QUADRO (1024 * 1024)
#define ASSINATURA 83         // bytes necessários para testar um começo DIF

static atomic_int g_parar;

// Gravação opcional dos quadros DV completos (fluxo DV cru, lido por `ffmpeg -f dv`).
static FILE *g_arq;
static int g_gravar, g_gravados;
static char g_pasta[512];
int g_compacto;               // bancada: os pacotes isócronos juntos no buffer (ver o laço)     // MJPEG: um arquivo por quadro nesta pasta

typedef struct {
    uint64_t inicios_dif, dif_120000, inicios_dif50, dv_completos, quadros, tortos, dv50, bytes,
        pacotes, vazios, so_cabecalho, cab_invalido, err_bit, erros_pacote, fid_trocas, eof,
        estouros, pos_eof_mesmo_fid, jpeg_ok, jpeg_sem_soi, jpeg_sem_eoi, jpeg_varios_soi,
        jpeg_bytes, reenvio_err;
} Contas;

typedef struct {
    size_t v[8];
    uint64_t n[8];
    uint64_t outros;
} Histo;

typedef struct {
    Contas seg, tot, tot_sem_primeiro;
    int primeiro_impresso;
    // quadro em montagem (por FID/EOF)
    uint8_t *quadro;
    size_t acum;       // bytes do quadro (pode passar do CAP; aí só conta)
    int quadro_ruim;   // ERR ou pacote com erro dentro do quadro
    int ultimo_fid;    // -1 no começo
    int apos_eof;      // o último payload trouxe EOF e o FID ainda não trocou
    // payload corrente (flags do cabeçalho)
    int p_fid, p_eof;
    // fluxo cru: janela com o rabo ainda não testado, e a posição absoluta dela
    uint8_t janela[ASSINATURA + 65536];
    size_t janela_n;
    uint64_t pos_janela0;
    int64_t ultimo_inicio;  // posição absoluta do último começo DIF (-1: nenhum)
    Histo tortos, distancias, erros;
    size_t jpeg_min, jpeg_max;
} Estado;

static void histo(Histo *h, size_t v) {
    for (int i = 0; i < 8; i++) if (h->n[i] && h->v[i] == v) { h->n[i]++; return; }
    for (int i = 0; i < 8; i++) if (!h->n[i]) { h->v[i] = v; h->n[i] = 1; return; }
    h->outros++;
}

static void histo_txt(const Histo *h, char *s, size_t cap, int com_sinal) {
    size_t off = 0;
    s[0] = 0;
    for (int i = 0; i < 8 && off < cap; i++) {
        if (!h->n[i]) continue;
        if (com_sinal)
            off += snprintf(s + off, cap - off, "%s%dx%llu", off ? "," : "", (int)h->v[i],
                            (unsigned long long)h->n[i]);
        else
            off += snprintf(s + off, cap - off, "%s%zux%llu", off ? "," : "", h->v[i],
                            (unsigned long long)h->n[i]);
    }
    if (h->outros && off < cap)
        snprintf(s + off, cap - off, "%soutros x%llu", off ? "," : "", (unsigned long long)h->outros);
}

#define SOMA(campo, qtd) do { e->seg.campo += (qtd); e->tot.campo += (qtd); \
    if (e->primeiro_impresso) e->tot_sem_primeiro.campo += (qtd); } while (0)

// 1 = começo de quadro 525/60, 2 = 625/50, 0 = não é começo.
static int inicio_dif(const uint8_t *p) {
    if (p[0] != 0x1F || p[1] != 0x07 || p[2] != 0x00) return 0;
    if (p[80] != 0x3F || p[81] != 0x07 || p[82] != 0x00) return 0;
    return (p[3] & 0x80) ? 2 : 1;
}

// Fluxo cru: todo byte de dado de payload passa por aqui, na ordem em que chegou.
static void varre_fluxo(Estado *e, const uint8_t *d, size_t n) {
    while (n > 0) {
        size_t cabe = sizeof(e->janela) - e->janela_n;
        size_t k = n < cabe ? n : cabe;
        memcpy(e->janela + e->janela_n, d, k);
        e->janela_n += k;
        d += k;
        n -= k;
        if (e->janela_n < ASSINATURA) continue;
        size_t lim = e->janela_n - ASSINATURA + 1;  // posições com a assinatura inteira à frente
        for (size_t p = 0; p < lim; p++) {
            if (e->janela[p] != 0x1F) continue;
            int t = inicio_dif(e->janela + p);
            if (!t) continue;
            uint64_t abs = e->pos_janela0 + p;
            if (t == 1) SOMA(inicios_dif, 1); else SOMA(inicios_dif50, 1);
            if (e->ultimo_inicio >= 0) {
                uint64_t dist = abs - (uint64_t)e->ultimo_inicio;
                if (t == 1 && dist == QUADRO_DV_525) SOMA(dif_120000, 1);
                else histo(&e->distancias, (size_t)dist);
            }
            e->ultimo_inicio = (int64_t)abs;
        }
        memmove(e->janela, e->janela + lim, e->janela_n - lim);
        e->janela_n -= lim;
        e->pos_janela0 += lim;
    }
}

// MJPEG: 1 = JPEG inteiro, 0 = não começa com SOI, -1 = começa mas não termina com EOI.
static int julga_jpeg(Estado *e, size_t *tam, int *n_soi) {
    const uint8_t *q = e->quadro;
    size_t n = e->acum;
    *n_soi = 0;
    if (n < 4 || q[0] != 0xFF || q[1] != 0xD8) return 0;
    for (size_t i = 0; i + 1 < n; i++) if (q[i] == 0xFF && q[i + 1] == 0xD8) (*n_soi)++;
    while (n > 2 && q[n - 1] == 0) n--;  // preenchimento depois do EOI
    *tam = n;
    return (q[n - 2] == 0xFF && q[n - 1] == 0xD9) ? 1 : -1;
}

static void fecha_quadro(Estado *e) {
    if (e->acum == 0) return;
    SOMA(quadros, 1);
    if (e->tot.quadros == 40 && g_pasta[0] && e->acum <= CAP_QUADRO) {  // um quadro cru, para olhar
        char c[600]; snprintf(c, sizeof(c), "%s/cru-40.bin", g_pasta);
        FILE *f = fopen(c, "wb"); if (f) { fwrite(e->quadro, 1, e->acum, f); fclose(f); LOG("quadro cru 40 em %s", c); }
    }
    if (e->tot.quadros >= 30 && e->tot.quadros < 34 && e->acum >= 32) {  // os bytes do começo e do fim
        const uint8_t *q = e->quadro; size_t n = e->acum < CAP_QUADRO ? e->acum : CAP_QUADRO;
        LOG("quadro %llu (%zu bytes): começo %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x fim %02x %02x %02x %02x",
            (unsigned long long)e->tot.quadros, e->acum, q[0],q[1],q[2],q[3],q[4],q[5],q[6],q[7],q[8],q[9],q[10],q[11],q[12],q[13],q[14],q[15],
            q[n-4],q[n-3],q[n-2],q[n-1]);
    }
    if (e->acum <= CAP_QUADRO && e->acum >= 2 && e->quadro[0] == 0xFF && e->quadro[1] == 0xD8) {
        size_t tam = 0;
        int n_soi = 0, j = julga_jpeg(e, &tam, &n_soi);
        if (n_soi > 1) SOMA(jpeg_varios_soi, 1);
        if (j == 1 && !e->quadro_ruim) {
            SOMA(jpeg_ok, 1);
            SOMA(jpeg_bytes, tam);
            if (!e->jpeg_min || tam < e->jpeg_min) e->jpeg_min = tam;
            if (tam > e->jpeg_max) e->jpeg_max = tam;
            if (g_pasta[0] && e->primeiro_impresso && g_gravados < g_gravar) {
                char c[600];
                snprintf(c, sizeof(c), "%s/quadro-%03d.jpg", g_pasta, g_gravados);
                FILE *f = fopen(c, "wb");
                if (f) { fwrite(e->quadro, 1, tam, f); fclose(f); g_gravados++; }
            }
        } else {
            if (j == -1) SOMA(jpeg_sem_eoi, 1);
            SOMA(tortos, 1);
            histo(&e->tortos, e->acum);
        }
        e->acum = 0;
        e->quadro_ruim = 0;
        return;
    }
    if (e->acum >= 2 && e->quadro[0] != 0x1F) SOMA(jpeg_sem_soi, 1);
    int t = (e->acum <= CAP_QUADRO && e->acum >= ASSINATURA) ? inicio_dif(e->quadro) : 0;
    if (!e->quadro_ruim && t == 1 && e->acum == QUADRO_DV_525) {
        SOMA(dv_completos, 1);
        // Grava depois do primeiro segundo (o arranque tem ERR).
        if (g_arq && e->primeiro_impresso && g_gravados < g_gravar) {
            if (fwrite(e->quadro, 1, QUADRO_DV_525, g_arq) == QUADRO_DV_525) g_gravados++;
            if (g_gravados == g_gravar) { fclose(g_arq); g_arq = NULL; LOG("gravados %d quadros", g_gravados); }
        }
    } else if (!e->quadro_ruim && t == 2 && e->acum == QUADRO_DV_625) {
        SOMA(dv50, 1);
    } else {
        SOMA(tortos, 1);
        histo(&e->tortos, e->acum);
    }
    if (e->acum > CAP_QUADRO) SOMA(estouros, 1);
    e->acum = 0;
    e->quadro_ruim = 0;
}

// Começo de payload: valida e lê o cabeçalho; FID trocado fecha o quadro anterior (como o
// uvcvideo). Devolve o tamanho do cabeçalho, ou -1 se o payload deve ser ignorado.
static int cabecalho(Estado *e, const uint8_t *d, size_t len) {
    if (len == 0) { SOMA(vazios, 1); return -1; }
    if (len < 2 || d[0] < 2 || d[0] > len) { SOMA(cab_invalido, 1); return -1; }
    int fid = d[1] & 0x01, err = (d[1] >> 6) & 1;
    e->p_fid = fid;
    e->p_eof = (d[1] >> 1) & 1;
    if (err) SOMA(err_bit, 1);
    if (e->ultimo_fid >= 0 && fid != e->ultimo_fid) {
        SOMA(fid_trocas, 1);
        fecha_quadro(e);
        e->apos_eof = 0;
    } else if (e->apos_eof && len > d[0]) {
        SOMA(pos_eof_mesmo_fid, 1);  // o kernel descartaria (fora de sincronia); aqui só conta
        e->apos_eof = 0;
    }
    e->ultimo_fid = fid;
    if (err) e->quadro_ruim = 1;
    if (len == d[0]) SOMA(so_cabecalho, 1);
    return d[0];
}

static void dados(Estado *e, const uint8_t *p, size_t n) {
    if (n == 0) return;
    if (e->acum + n <= CAP_QUADRO) memcpy(e->quadro + e->acum, p, n);
    e->acum += n;
    SOMA(bytes, n);
    varre_fluxo(e, p, n);
}

// Fim de payload: EOF fecha o quadro (lido também no pacote só de cabeçalho).
static void fim_payload(Estado *e) {
    if (e->p_eof) {
        SOMA(eof, 1);
        fecha_quadro(e);
        e->apos_eof = 1;
    }
}

static double agora(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

#define U(x) (unsigned long long)(x)

static void imprime_segundo(Estado *e, int seg) {
    Contas *c = &e->seg;
    LOG("seg=%d inicios_dif=%llu dif_120000=%llu inicios_dif50=%llu dv_completos=%llu quadros=%llu "
        "tortos=%llu dv50=%llu bytes=%llu pacotes=%llu vazios=%llu so_cabecalho=%llu "
        "cab_invalido=%llu err_bit=%llu erros_pacote=%llu fid_trocas=%llu eof=%llu estouros=%llu "
        "pos_eof_mesmo_fid=%llu jpeg_ok=%llu jpeg_sem_soi=%llu jpeg_sem_eoi=%llu jpeg_varios_soi=%llu "
        "jpeg_bytes=%llu reenvio_err=%llu",
        seg, U(c->inicios_dif), U(c->dif_120000), U(c->inicios_dif50), U(c->dv_completos),
        U(c->quadros), U(c->tortos), U(c->dv50), U(c->bytes), U(c->pacotes), U(c->vazios),
        U(c->so_cabecalho), U(c->cab_invalido), U(c->err_bit), U(c->erros_pacote),
        U(c->fid_trocas), U(c->eof), U(c->estouros), U(c->pos_eof_mesmo_fid), U(c->jpeg_ok),
        U(c->jpeg_sem_soi), U(c->jpeg_sem_eoi), U(c->jpeg_varios_soi), U(c->jpeg_bytes),
        U(c->reenvio_err));
    memset(c, 0, sizeof(*c));
    e->primeiro_impresso = 1;
}

static struct usbdevfs_urb *urbs[MAX_URBS];
static int no_ar[MAX_URBS];
static int pendente[MAX_URBS];   // o reenvio foi recusado: tentar de novo na próxima volta
static int mapeado[MAX_URBS];    // o buffer veio do mmap do fd (desfazer com munmap)

static int indice_urb(const struct usbdevfs_urb *u) {
    for (int i = 0; i < N_URBS; i++) if (urbs[i] == u) return i;
    return -1;
}

static int envia(int fd, int i, int bulk, int psize, int tam_bulk) {
    struct usbdevfs_urb *u = urbs[i];
    if (bulk) {
        u->buffer_length = tam_bulk;
    } else {
        u->number_of_packets = N_PACOTES;
        u->buffer_length = psize * N_PACOTES;
        for (int k = 0; k < N_PACOTES; k++) {
            u->iso_frame_desc[k].length = psize;
            u->iso_frame_desc[k].actual_length = 0;
            u->iso_frame_desc[k].status = 0;
        }
    }
    u->status = 0;
    u->actual_length = 0;
    if (ioctl(fd, USBDEVFS_SUBMITURB, u) < 0) return -errno;
    no_ar[i] = 1;
    return 0;
}

// USBDEVFS_RESET: reinicia o aparelho pela porta (o leitor de DVD travado no protocolo). 0 ou -errno.
JNIEXPORT jint JNICALL
Java_com_quall_bancada_espiaodv_Nativo_resetar(JNIEnv *env, jclass cls, jint fd) {
    (void)env; (void)cls;
    return ioctl(fd, USBDEVFS_RESET, 0) < 0 ? -errno : 0;
}

JNIEXPORT void JNICALL
Java_com_quall_bancada_espiaodv_Nativo_compacto(JNIEnv *env, jclass cls, jboolean sim) {
    (void)env; (void)cls;
    g_compacto = sim ? 1 : 0;
}

JNIEXPORT void JNICALL
Java_com_quall_bancada_espiaodv_Nativo_parar(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    atomic_store(&g_parar, 1);
}

// USBDEVFS_GET_SPEED: 1 baixa, 2 total (12 Mbit/s), 3 alta (480 Mbit/s), 5 super. -errno se falhar.
JNIEXPORT jint JNICALL
Java_com_quall_bancada_espiaodv_Nativo_velocidade(JNIEnv *env, jclass cls, jint fd) {
    (void)env; (void)cls;
    int r = ioctl(fd, USBDEVFS_GET_SPEED);
    return r < 0 ? -errno : r;
}

// Roda até `segundos` cheios, ou até parar(), ou 10 s sem dado no começo, ou 5 s sem dado depois
// de ter tido dado. `max_payload` (bulk) é o dwMaxPayloadTransferSize negociado. Devolve o VEREDITO.
JNIEXPORT jstring JNICALL
Java_com_quall_bancada_espiaodv_Nativo_rodar(JNIEnv *env, jclass cls, jint fd, jint endpoint,
                                            jboolean bulk, jint psize, jint tam_bulk,
                                            jint segundos, jint gravar, jstring caminho,
                                            jint n_urbs, jint n_pacotes, jboolean usar_mmap,
                                            jstring pasta_jpeg) {
    (void)cls;
    char veredito[2600];
    N_URBS = n_urbs < 1 ? 1 : n_urbs > MAX_URBS ? MAX_URBS : n_urbs;
    N_PACOTES = n_pacotes < 1 ? 1 : n_pacotes > 128 ? 128 : n_pacotes;
    g_gravar = gravar;
    g_gravados = 0;
    g_arq = NULL;
    g_pasta[0] = 0;
    if (gravar > 0 && pasta_jpeg) {
        const char *c = (*env)->GetStringUTFChars(env, pasta_jpeg, NULL);
        snprintf(g_pasta, sizeof(g_pasta), "%s", c);
        (*env)->ReleaseStringUTFChars(env, pasta_jpeg, c);
    }
    if (gravar > 0 && caminho) {
        const char *c = (*env)->GetStringUTFChars(env, caminho, NULL);
        g_arq = fopen(c, "wb");
        LOG("gravar %d quadros em %s: %s", gravar, c, g_arq ? "aberto" : strerror(errno));
        (*env)->ReleaseStringUTFChars(env, caminho, c);
    }
    Estado *e = calloc(1, sizeof(Estado));
    if (!e) return (*env)->NewStringUTF(env, "VEREDITO falha: sem memória");
    e->quadro = malloc(CAP_QUADRO);
    e->ultimo_fid = -1;
    e->ultimo_inicio = -1;
    int tam_buf = bulk ? tam_bulk : psize * N_PACOTES;
    LOG("transferência %s: endpoint 0x%02x, %s %d, %d URBs de %d pacotes (%d bytes por URB), mmap=%d",
        bulk ? "bulk" : "isócrona", endpoint, bulk ? "URB/payload máximo" : "psize",
        bulk ? tam_bulk : psize, N_URBS, bulk ? 1 : N_PACOTES, tam_buf, usar_mmap ? 1 : 0);

    memset(urbs, 0, sizeof(urbs));
    memset(no_ar, 0, sizeof(no_ar));
    memset(pendente, 0, sizeof(pendente));
    memset(mapeado, 0, sizeof(mapeado));
    int mmaps_ok = 0, mmaps_falhos = 0;
    for (int i = 0; i < N_URBS; i++) {
        size_t sz = sizeof(struct usbdevfs_urb) +
                    (bulk ? 0 : N_PACOTES * sizeof(struct usbdevfs_iso_packet_desc));
        urbs[i] = calloc(1, sz);
        urbs[i]->type = bulk ? USBDEVFS_URB_TYPE_BULK : USBDEVFS_URB_TYPE_ISO;
        urbs[i]->endpoint = (unsigned char)endpoint;
        urbs[i]->flags = bulk ? 0 : USBDEVFS_URB_ISO_ASAP;
        void *b = NULL;
        if (usar_mmap) {
            b = mmap(NULL, (size_t)tam_buf, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (b == MAP_FAILED) {
                if (!mmaps_falhos) LOG("mmap do usbfs falhou: %s (%d); malloc", strerror(errno), errno);
                mmaps_falhos++;
                b = NULL;
            } else {
                mapeado[i] = 1;
                mmaps_ok++;
            }
        }
        urbs[i]->buffer = b ? b : malloc(tam_buf);
    }
    if (usar_mmap) LOG("mmap: %d buffers mapeados, %d por malloc", mmaps_ok, mmaps_falhos);

    int enviados = 0, erro_envio = 0, falhas_iniciais = 0;
    for (int i = 0; i < N_URBS; i++) {
        int r = envia(fd, i, bulk, psize, tam_bulk);
        if (r < 0) {
            if (!falhas_iniciais) LOG("SUBMITURB %d falhou: %s (%d)", i, strerror(-r), -r);
            falhas_iniciais++;
            erro_envio = -r;
            pendente[i] = 1;
            continue;
        }
        enviados++;
    }
    LOG("%d URBs no ar, %d recusadas no envio inicial", enviados, falhas_iniciais);

    // Payload bulk em andamento (só o começo tem cabeçalho).
    int bulk_em_payload = 0;
    size_t bulk_tam = 0;

    double t0 = agora(), prox = t0 + 1.0, ultimo_dado = 0;
    int seg = 0, desconectado = 0;
    const char *motivo = "tempo cumprido";

    // Mesmo com nenhuma aceita de primeira: as pendentes tentam de novo (10 s sem dado encerram).
    while (!atomic_load(&g_parar)) {
        struct pollfd pf = {.fd = fd, .events = POLLOUT | POLLWRNORM};
        int pr = poll(&pf, 1, 100);
        if (pr < 0 && errno != EINTR) { LOG("poll: %s", strerror(errno)); motivo = "poll falhou"; break; }
        for (;;) {
            struct usbdevfs_urb *u = NULL;
            if (ioctl(fd, USBDEVFS_REAPURBNDELAY, &u) < 0) {
                if (errno == EAGAIN) break;
                if (errno == ENODEV) { desconectado = 1; break; }
                LOG("REAPURB: %s (%d)", strerror(errno), errno);
                break;
            }
            int i = indice_urb(u);
            if (i < 0) continue;
            no_ar[i] = 0;
            if (u->status == -ENODEV || u->status == -ESHUTDOWN) { desconectado = 1; break; }
            if (bulk) {
                SOMA(pacotes, 1);
                if (u->status != 0) {
                    SOMA(erros_pacote, 1);
                    histo(&e->erros, (size_t)u->status);
                    e->quadro_ruim = 1;
                    bulk_em_payload = 0;
                } else {
                    const uint8_t *d = (const uint8_t *)u->buffer;
                    size_t len = (size_t)u->actual_length;
                    if (!bulk_em_payload) {
                        int hl = cabecalho(e, d, len);
                        if (hl >= 0) {
                            dados(e, d + hl, len - (size_t)hl);
                            if (len > (size_t)hl) ultimo_dado = agora();
                            bulk_em_payload = 1;
                            bulk_tam = len;
                        }
                    } else {
                        dados(e, d, len);
                        if (len) ultimo_dado = agora();
                        bulk_tam += len;
                    }
                    // Como o kernel: o payload acaba na URB curta ou ao chegar ao máximo.
                    if (bulk_em_payload && (len < (size_t)tam_bulk || bulk_tam >= (size_t)tam_bulk)) {
                        fim_payload(e);
                        bulk_em_payload = 0;
                    }
                }
            } else {
                if (u->status != 0) histo(&e->erros, (size_t)(1000 - u->status));  // URB inteira: 1000+|status|
                size_t off_compacto = 0;
                for (int k = 0; k < u->number_of_packets; k++) {
                    struct usbdevfs_iso_packet_desc *pk = &u->iso_frame_desc[k];
                    SOMA(pacotes, 1);
                    if (pk->status != 0) {
                        SOMA(erros_pacote, 1);
                        histo(&e->erros, (size_t)pk->status);
                        e->quadro_ruim = 1;
                        continue;
                    }
                    // No usbfs, o pacote k fica em k x (comprimento pedido), não na soma dos reais.
                    // `compacto` (bancada, o A07): a soma dos reais, para ver se o kernel junta.
                    const uint8_t *d = (const uint8_t *)u->buffer +
                        (g_compacto ? off_compacto : (size_t)k * (size_t)psize);
                    off_compacto += pk->actual_length;
                    size_t len = pk->actual_length;
                    int hl = cabecalho(e, d, len);
                    if (hl < 0) continue;
                    dados(e, d + hl, len - (size_t)hl);
                    if (len > (size_t)hl) ultimo_dado = agora();
                    fim_payload(e);
                }
            }
            if (!atomic_load(&g_parar)) {
                int r = envia(fd, i, bulk, psize, tam_bulk);
                if (r < 0) {
                    if (r == -ENODEV) { desconectado = 1; break; }
                    if (!e->tot.reenvio_err) LOG("reenvio da URB %d falhou: %s (%d)", i, strerror(-r), -r);
                    SOMA(reenvio_err, 1);
                    pendente[i] = 1;
                }
            }
        }
        // As recusadas tentam de novo a cada volta (a revisão da placa, 2).
        for (int i = 0; i < N_URBS && !desconectado && !atomic_load(&g_parar); i++) {
            if (!pendente[i]) continue;
            int r = envia(fd, i, bulk, psize, tam_bulk);
            if (r == 0) pendente[i] = 0;
            else if (r == -ENODEV) desconectado = 1;
            else SOMA(reenvio_err, 1);
        }
        if (desconectado) { motivo = "câmera desconectada"; break; }
        int restam = 0;
        for (int i = 0; i < N_URBS; i++) restam += no_ar[i];
        if (!restam && ultimo_dado > 0 && agora() - ultimo_dado > 2) { motivo = "todas as URBs caíram (reenvio recusado)"; break; }
        double t = agora();
        while (t >= prox) {
            seg++;
            imprime_segundo(e, seg);
            prox += 1.0;
        }
        if (seg >= segundos) break;
        if (ultimo_dado == 0 && t - t0 > 10) { motivo = "nenhum dado em 10 s"; break; }
        if (ultimo_dado > 0 && t - ultimo_dado > 5) { motivo = "sem dado há 5 s"; break; }
    }
    if (atomic_load(&g_parar) && strcmp(motivo, "tempo cumprido") == 0) motivo = "parado";

    // Recolhe: esta mesma thread descarta as URBs no ar e espera voltarem (no máximo ~2 s).
    for (int i = 0; i < N_URBS; i++)
        if (no_ar[i]) ioctl(fd, USBDEVFS_DISCARDURB, urbs[i]);
    double limite = agora() + 2.0;
    int restam = 0;
    for (;;) {
        restam = 0;
        for (int i = 0; i < N_URBS; i++) restam += no_ar[i];
        if (!restam || agora() > limite) break;
        struct pollfd pf = {.fd = fd, .events = POLLOUT | POLLWRNORM};
        poll(&pf, 1, 100);
        struct usbdevfs_urb *u = NULL;
        while (ioctl(fd, USBDEVFS_REAPURBNDELAY, &u) == 0) {
            int i = indice_urb(u);
            if (i >= 0) no_ar[i] = 0;
        }
        if (errno == ENODEV) break;
    }
    if (restam) LOG("%d URBs não voltaram; os buffers delas ficam vazados de propósito", restam);

    // Veredito: taxas sem o primeiro segundo (arranque).
    Contas *s = &e->tot_sem_primeiro, *T = &e->tot;
    int seg_cheios = seg > 1 ? seg - 1 : 0;
    double q = seg_cheios ? 1.0 / seg_cheios : 0;
    char h_tortos[300], h_dist[300], h_err[200];
    histo_txt(&e->tortos, h_tortos, sizeof(h_tortos), 0);
    histo_txt(&e->distancias, h_dist, sizeof(h_dist), 0);
    histo_txt(&e->erros, h_err, sizeof(h_err), 1);
    snprintf(veredito, sizeof(veredito),
             "VEREDITO %.2f inicios_dif/s, %.2f dif_120000/s, %.2f dv_completos/s em %d s cheios; "
             "motivo=%s; totais: inicios_dif=%llu dif_120000=%llu inicios_dif50=%llu "
             "dv_completos=%llu quadros=%llu tortos=%llu dv50=%llu bytes=%llu pacotes=%llu "
             "vazios=%llu so_cabecalho=%llu cab_invalido=%llu err_bit=%llu erros_pacote=%llu "
             "fid_trocas=%llu eof=%llu estouros=%llu pos_eof_mesmo_fid=%llu envio_err=%d "
             "falhas_iniciais=%d reenvio_err=%llu; JPEG: %.2f jpeg_ok/s, jpeg_ok=%llu sem_soi=%llu "
             "sem_eoi=%llu varios_soi=%llu tam_min=%zu tam_med=%llu tam_max=%zu gravados=%d; "
             "distancias_nao_120000=[%s]; tamanhos_tortos=[%s]; codigos_erro=[%s]",
             s->inicios_dif * q, s->dif_120000 * q, s->dv_completos * q, seg_cheios, motivo,
             U(T->inicios_dif), U(T->dif_120000), U(T->inicios_dif50), U(T->dv_completos),
             U(T->quadros), U(T->tortos), U(T->dv50), U(T->bytes), U(T->pacotes), U(T->vazios),
             U(T->so_cabecalho), U(T->cab_invalido), U(T->err_bit), U(T->erros_pacote),
             U(T->fid_trocas), U(T->eof), U(T->estouros), U(T->pos_eof_mesmo_fid), erro_envio,
             falhas_iniciais, U(T->reenvio_err), s->jpeg_ok * q, U(T->jpeg_ok), U(T->jpeg_sem_soi),
             U(T->jpeg_sem_eoi), U(T->jpeg_varios_soi), e->jpeg_min,
             U(T->jpeg_ok ? T->jpeg_bytes / T->jpeg_ok : 0), e->jpeg_max, g_gravados,
             h_dist, h_tortos, h_err);

    if (g_arq) { fclose(g_arq); g_arq = NULL; LOG("gravados %d quadros (de %d pedidos)", g_gravados, g_gravar); }
    if (!restam) {
        for (int i = 0; i < N_URBS; i++) {
            if (mapeado[i]) munmap(urbs[i]->buffer, (size_t)tam_buf); else free(urbs[i]->buffer);
            free(urbs[i]);
        }
    }
    free(e->quadro);
    free(e);
    return (*env)->NewStringUTF(env, veredito);
}

// ---- o som da placa (UAC), cru ------------------------------------------------------------------
// Lê o endpoint isócrono de som por `segundos` e grava o PCM como veio (s16le) em `caminho`. Para
// medir o ruído e o nível em volumes diferentes (docs/placa-de-captura-usb.md §13.9): o caminho do
// Android não deixa mexer no volume. Devolve o resumo.
JNIEXPORT jstring JNICALL
Java_com_quall_bancada_espiaodv_Nativo_som(JNIEnv *env, jclass cls, jint fd, jint endpoint,
                                           jint psize, jint segundos, jstring jcaminho) {
    (void)cls;
    enum { NU = 8, NP = 16 };
    char res[256];
    const char *caminho = (*env)->GetStringUTFChars(env, jcaminho, NULL);
    FILE *f = fopen(caminho, "wb");
    (*env)->ReleaseStringUTFChars(env, jcaminho, caminho);
    if (!f) { snprintf(res, sizeof res, "som: o arquivo não abriu (errno %d)", errno); return (*env)->NewStringUTF(env, res); }
    struct usbdevfs_urb *u[NU];
    uint8_t *b[NU];
    size_t tam = sizeof(struct usbdevfs_urb) + NP * sizeof(struct usbdevfs_iso_packet_desc);
    long long bytes = 0, pacotes = 0, erros = 0, vazios = 0;
    int enviadas = 0, erro_envio = 0;
    for (int i = 0; i < NU; i++) {
        u[i] = calloc(1, tam);
        b[i] = malloc((size_t)NP * psize);
        u[i]->type = USBDEVFS_URB_TYPE_ISO;
        u[i]->endpoint = (unsigned char)endpoint;
        u[i]->flags = USBDEVFS_URB_ISO_ASAP;
        u[i]->buffer = b[i];
        u[i]->buffer_length = NP * psize;
        u[i]->number_of_packets = NP;
        for (int k = 0; k < NP; k++) u[i]->iso_frame_desc[k].length = (unsigned)psize;
        if (ioctl(fd, USBDEVFS_SUBMITURB, u[i]) < 0) erro_envio = errno; else enviadas++;
    }
    double fim = agora() + segundos;
    while (enviadas > 0 && agora() < fim) {
        struct pollfd p = { .fd = fd, .events = POLLOUT };
        if (poll(&p, 1, 200) <= 0) continue;
        struct usbdevfs_urb *r = NULL;
        while (ioctl(fd, USBDEVFS_REAPURBNDELAY, &r) == 0 && r) {
            uint8_t *d = r->buffer;
            for (int k = 0; k < r->number_of_packets; k++) {
                struct usbdevfs_iso_packet_desc *q = &r->iso_frame_desc[k];
                pacotes++;
                if (q->status) erros++;
                else if (q->actual_length == 0) vazios++;
                else { fwrite(d, 1, q->actual_length, f); bytes += q->actual_length; }
                d += q->length;
            }
            if (ioctl(fd, USBDEVFS_SUBMITURB, r) < 0) { erro_envio = errno; enviadas--; }
        }
    }
    for (int i = 0; i < NU; i++) ioctl(fd, USBDEVFS_DISCARDURB, u[i]);
    struct timespec t = { 0, 100000000 };
    nanosleep(&t, NULL);
    { struct usbdevfs_urb *r = NULL; while (ioctl(fd, USBDEVFS_REAPURBNDELAY, &r) == 0 && r) {} }
    for (int i = 0; i < NU; i++) { free(b[i]); free(u[i]); }
    fclose(f);
    snprintf(res, sizeof res, "som: %lld bytes em %lld pacotes (%lld com erro, %lld vazios), erro_de_envio=%d",
             bytes, pacotes, erros, vazios, erro_envio);
    return (*env)->NewStringUTF(env, res);
}
