// Vídeo por USB, só arm64: a câmera DV (filmadora UVC em modo DV, ex. Panasonic GS500 em "Video
// Edit") e, desde a P1 da placa de captura (`docs/placa-de-captura-usb.md`), o MJPEG (a EasyCap
// Arkmicro 18ec:5555, 640x480 a 30). O formato é decidido pelo Kotlin (`UsbDv.abrir`) e vem no
// `abrir`; o resto do caminho (a fila, a thread, o encoder) é o mesmo.
//
// Esta `.so` (`libqualldv.so`) é separada do `libqualljni.so` de propósito: ela depende do FFmpeg
// (`libavcodec.so`/`libavutil.so`, LGPL, só arm64) e um `dlopen` falho não pode derrubar o núcleo.
// O Kotlin (`capture/dv/QuallDv.kt`) a carrega sob demanda.
//
// URBs: no máximo 32 KB cada (a regra da P0, §3.3 e §8: o usbfs faz um kmalloc contíguo da URB a
// cada envio, e 64 pacotes de 3000 deram ENOMEM), e tantas URBs quanto mantenham ~64 ms de folga
// (512 microquadros). A DV (psize 492) continua 16 de 32, em potência de 2; a placa (MJPEG) vai com
// **no máximo 3 pacotes por URB** (medido no A07: com 4 ou mais o dado dos pacotes chega perdido,
// `docs/placa-de-captura-usb.md` §11), 171 de 3 em psize 3000. Um reenvio recusado é contado e
// tentado de novo na volta seguinte, em vez de a URB sair de circulação.
//
// Três partes, todas medidas na bancada antes (tools/espiao-dv-s24, quall-scratch/dv-s24/):
// 1. **USB**: uma thread colhe URBs isócronas pelo usbfs (fd do UsbDeviceConnection), monta os
//    payloads UVC por FID/EOF (`remontagem.c`) e põe na fila os quadros íntegros (DV: 120 000
//    bytes, começo DIF; MJPEG: SOI...EOI, até o dwMaxVideoFrameSize, dois JPEG colados partidos em
//    dois; os dois sem ERR nem pacote com erro), carimbados com CLOCK_MONOTONIC no reap que fechou
//    o quadro. Cada posição da fila guarda o tamanho do seu quadro. A fila tem 2 posições; se o
//    consumidor atrasa, o mais velho cai (e é contado).
// 2. **Decodificação**: o `dvvideo` do FFmpeg (bit a bit igual ao do ffmpeg do Mac, fase A), ou o
//    `mjpeg` (4:2:2, 4:2:0 ou 4:4:4; **sem compressão de faixa**: a placa embala faixa limitada num
//    JPEG que se diz cheio, medido na P0, §8.1 — os valores vão ao encoder como estão).
// 3. **Imagem**: na DV, desentrelaçamento `adapt2` (campo de baixo primeiro, medido pela sequência;
//    movimento temporal + pente médio em x±3 > 3 → bob com ELA; senão weave); no MJPEG nada (a
//    placa já entrega progressivo, §3.6). Depois, a conversão para 4:2:0 no tamanho exibido (DV:
//    854x480 em 16:9, 640x480 em 4:3, pelo DISP do VAUX; MJPEG: o aspecto do próprio quadro, 4:3
//    na placa), encaixada com faixas pretas quando o aspecto do quadro não é o da abertura.
//
// Uma thread de USB (interna) e uma consumidora (a `quall-dv` do Kotlin, que chama esperar e
// converter). `fechar` só é chamado depois que a consumidora saiu.

#include <jni.h>
#include <android/log.h>
#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/pixdesc.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <linux/usbdevice_fs.h>
#include <math.h>
#include <unistd.h>

#include "midia.h"
#include "remontagem.h"

#define TAG "QuallDv"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

#define QUADRO QUADRO_DV
#define LARG 720
#define ALT 480
#define CLARG 180
#define N_BUF 17  // até 16 na fila (gravação) + 1 com a consumidora; o espelhamento usa 2
// MJPEG: 8 na fila da gravação (a P4 adiantada: ~260 ms de folga para o encoder a 30/s) + 1 com a
// consumidora, cada uma do tamanho do dwMaxVideoFrameSize (9 x 614400 = 5,5 MB); o espelhamento usa 2
#define N_BUF_MJPEG 9
// Bulk (as placas HDMI): URBs no ar, cada uma do tamanho de um payload (16 KiB nas três medidas).
#define URBS_BULK 32

enum { LIVRE, NA_FILA, COM_CONSUMIDORA };

typedef struct {
    int *x0, *f, n;
} Escala;

typedef struct {
    // USB
    int fd, endpoint, psize;
    // As placas HDMI (§14): `bulk` = o endpoint de vídeo é bulk (uma URB de `tam_bulk` bytes por
    // payload UVC, sem pacotes isócronos); `cru` = o quadro é NV12 não comprimido (sem decodificar).
    int bulk, tam_bulk, cru;
    pthread_t thread;
    int thread_viva;
    atomic_int parar;
    int n_urbs, n_pacotes;
    struct usbdevfs_urb *urbs[MAX_URBS];
    int no_ar[MAX_URBS];
    int pendente[MAX_URBS];  // o reenvio foi recusado: tenta de novo, com recuo
    int ja_pendente[MAX_URBS];  // esta URB já ficou pendente alguma vez (o contador é de URBs distintas)
    int64_t tentou_em[MAX_URBS];  // a última tentativa recusada desta URB (CLOCK_MONOTONIC, ns)
    // o formato (FORMATO_DV ou FORMATO_MJPEG) e a geometria dos planos de `des`: luma lw x lh,
    // croma cw x ch; `centrado` = croma no centro (JPEG), senão co-situado à esquerda (DV 4:1:1)
    int formato, lw, lh, cw, ch, centrado;
    int an, ad;  // o aspecto do MJPEG (o do quadro); a DV usa o disp169
    // bancada: quadros de um arquivo .dv em vez do USB
    uint8_t *arquivo;
    size_t n_arquivo;
    // montagem
    Remontagem rm;
    // fila
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int n_buf;
    size_t cap_quadro;
    uint8_t *buf[N_BUF];
    size_t tam[N_BUF];
    int estado[N_BUF];
    int64_t ts[N_BUF];
    uint64_t seq[N_BUF];
    uint64_t seq_prox;
    int64_t ultimo_ts;
    int morta;  // desconectada (ENODEV) ou todas as URBs caídas
    // Gravação: fila FIFO funda (16), entrega em ordem, e o quadro com erro de USB também vai (o
    // dvvideo mascara os blocos ruins; na digitalização um quadro imperfeito vale mais que um
    // buraco). Espelhamento: fila de 2, entrega o mais novo, derruba o quadro com erro.
    atomic_int gravacao;
    int atual;  // índice com a consumidora, ou -1
    // decodificação
    AVCodecContext *ctx;
    AVFrame *fr;
    AVPacket *pk;
    uint8_t *pkbuf;
    uint8_t *ant[3], *des[3], *mascara;
    int tem_ant;
    int disp169;  // do último quadro decodificado: 1 = 16:9, 0 = 4:3, -1 = nenhum ainda
    int decodificado;
    SomDv *som;
    SomGravacao *somg;
    int pular_luma;
    int hq_w, hq_h, *hq_x0, *hq_wx, *hq_y0, *hq_wy;
    int16_t *hq_tmp;
    // escalas em cache (para o último retângulo)
    int esc_w, esc_h;
    Escala ey_x, ey_y, ec_x, ec_y;
    // contadores
    atomic_ullong c_caidos_fila, c_erros_pacote, c_entregues, c_decod_falhas, c_trocas_aspecto,
        c_us_decod, c_us_des, c_us_conv, c_reenvio_recusado, c_tentativas_recusadas, c_envios;
    int avisou_decod;  // a primeira falha de decodificação vai ao logcat, com o motivo
    // O som da placa pelo usbfs (§13.10): as URBs são da thread do USB (ligadas por ela quando
    // `som_pedido` sobe); o anel (s16 mono, 1 s) é da thread do USB (escreve) e da leitora do
    // Kotlin (lê), sob `som_mu`. `som_w`/`som_r` contam amostras desde a abertura.
    atomic_int som_pedido;
    int som_ligado, som_ep, som_psize;
    int som_passo;  // amostras s16 da placa por amostra de saída (canais x fator de taxa): a média delas
    struct usbdevfs_urb *som_urbs[SOM_URBS];
    int som_no_ar[SOM_URBS], som_pendente[SOM_URBS];
    int64_t som_tentou_em[SOM_URBS];
    pthread_mutex_t som_mu;
    pthread_cond_t som_cv;
    int16_t *som_anel;
    uint64_t som_w, som_r;
    int64_t som_ts_w;  // quando a amostra `som_w` chegou (CLOCK_MONOTONIC, ns)
    int som_fim;       // a leitora não espera mais (fechando, ou a placa caiu)
    atomic_ullong c_som_pacotes, c_som_erros, c_som_caidas;
    // O intervalo entre as chegadas das URBs de som (a cadência, §13.11): <4, 4–12, 12–20, 20–40, ≥40 ms.
    int64_t som_ultima_ns;
    unsigned long long som_intervalos[5];
} Dv;

#define SOM_BASE 100000  // o `usercontext` das URBs de som
#define SOM_ANEL 48000   // amostras
#define SOM_TAXA 48000

static int64_t agora_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// ------------------------------------------------------------------------------------ USB
// O `EntregaFn` da remontagem: copia o quadro (n bytes) para uma posição da fila.
static void entrega_quadro(void *ctx, const uint8_t *q, size_t n, int64_t ts, int ruim) {
    (void)ruim;
    Dv *d = ctx;
    if (n > d->cap_quadro) return;  // não acontece: a remontagem não passa do cap
    pthread_mutex_lock(&d->mu);
    int livre = -1, na_fila = 0;
    int limite = atomic_load(&d->gravacao) ? d->n_buf - 1 : 2;
    for (int i = 0; i < d->n_buf; i++) na_fila += d->estado[i] == NA_FILA;
    if (na_fila < limite)
        for (int i = 0; i < d->n_buf; i++) if (d->estado[i] == LIVRE) { livre = i; break; }
    if (livre < 0) {
        // a fila está cheia: o mais velho cai
        uint64_t menor = UINT64_MAX;
        for (int i = 0; i < d->n_buf; i++)
            if (d->estado[i] == NA_FILA && d->seq[i] < menor) { menor = d->seq[i]; livre = i; }
        atomic_fetch_add(&d->c_caidos_fila, 1);
    }
    if (livre >= 0) {
        // O carimbo nunca anda para trás: com reap atrasado, URBs do mesmo lote recebem quase o
        // mesmo t_reap, e um quadro fechado no começo de uma URB sairia antes do anterior.
        if (ts <= d->ultimo_ts) ts = d->ultimo_ts + 1000000;
        d->ultimo_ts = ts;
        memcpy(d->buf[livre], q, n);
        d->tam[livre] = n;
        d->estado[livre] = NA_FILA;
        d->ts[livre] = ts;
        d->seq[livre] = d->seq_prox++;
        pthread_cond_signal(&d->cv);
    }
    pthread_mutex_unlock(&d->mu);
}

static int envia(Dv *d, int i) {
    struct usbdevfs_urb *u = d->urbs[i];
    u->number_of_packets = d->n_pacotes;
    u->buffer_length = d->bulk ? d->tam_bulk : d->psize * d->n_pacotes;
    for (int k = 0; k < d->n_pacotes; k++) {
        u->iso_frame_desc[k].length = d->psize;
        u->iso_frame_desc[k].actual_length = 0;
        u->iso_frame_desc[k].status = 0;
    }
    u->status = 0;
    u->actual_length = 0;
    if (ioctl(d->fd, USBDEVFS_SUBMITURB, u) < 0) return -errno;
    d->no_ar[i] = 1;
    atomic_fetch_add(&d->c_envios, 1);
    return 0;
}

// O índice vai no `usercontext` (a placa tem 171 URBs a ~2700 reaps/s: a busca linear seria ~460
// mil comparações por segundo); conferido contra a tabela, e a busca fica de reserva.
static int indice_urb(Dv *d, const struct usbdevfs_urb *u) {
    intptr_t k = u ? (intptr_t)u->usercontext : -1;
    if (k >= 0 && k < d->n_urbs && d->urbs[k] == u) return (int)k;
    for (int i = 0; i < d->n_urbs; i++) if (d->urbs[i] == u) return i;
    return -1;
}

static void som_acaba(Dv *d) {
    pthread_mutex_lock(&d->som_mu);
    d->som_fim = 1;
    pthread_cond_broadcast(&d->som_cv);
    pthread_mutex_unlock(&d->som_mu);
}

static void marca_morta(Dv *d, const char *porque) {
    pthread_mutex_lock(&d->mu);
    if (!d->morta) LOGW("câmera DV: %s", porque);
    d->morta = 1;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    som_acaba(d);
}

// ---- o som da placa (§13.10), na thread do USB ---------------------------------------------------
static int envia_som(Dv *d, int i) {
    struct usbdevfs_urb *u = d->som_urbs[i];
    u->number_of_packets = SOM_PACOTES;
    u->buffer_length = d->som_psize * SOM_PACOTES;
    for (int k = 0; k < SOM_PACOTES; k++) {
        u->iso_frame_desc[k].length = d->som_psize;
        u->iso_frame_desc[k].actual_length = 0;
        u->iso_frame_desc[k].status = 0;
    }
    u->status = 0;
    u->actual_length = 0;
    if (ioctl(d->fd, USBDEVFS_SUBMITURB, u) < 0) {
        d->som_pendente[i] = 1;
        d->som_tentou_em[i] = agora_ns();
        return -errno;
    }
    d->som_no_ar[i] = 1;
    d->som_pendente[i] = 0;
    return 0;
}

static void liga_som(Dv *d) {
    d->som_ligado = 1;
    int no_ar = 0, erro = 0;
    for (int i = 0; i < SOM_URBS; i++) {
        struct usbdevfs_urb *u = calloc(1, sizeof(struct usbdevfs_urb) + SOM_PACOTES * sizeof(struct usbdevfs_iso_packet_desc));
        if (!u) break;
        u->buffer = malloc((size_t)d->som_psize * SOM_PACOTES);
        if (!u->buffer) { free(u); break; }
        u->type = USBDEVFS_URB_TYPE_ISO;
        u->endpoint = (unsigned char)d->som_ep;
        u->flags = USBDEVFS_URB_ISO_ASAP;
        u->usercontext = (void *)(intptr_t)(SOM_BASE + i);
        d->som_urbs[i] = u;
        int r = envia_som(d, i);
        if (r == 0) no_ar++; else erro = r;
    }
    LOGI("som da placa pelo USB: endpoint 0x%02x psize %d, passo %d, %d URBs de %d pacotes no ar%s%s",
         d->som_ep, d->som_psize, d->som_passo, no_ar, SOM_PACOTES, erro ? "; recusa: " : "", erro ? strerror(-erro) : "");
}

// O índice da URB de som, ou -1 se `u` não é de som.
static int indice_som(Dv *d, const struct usbdevfs_urb *u) {
    intptr_t k = u ? (intptr_t)u->usercontext - SOM_BASE : -1;
    return (k >= 0 && k < SOM_URBS && d->som_urbs[k] == u) ? (int)k : -1;
}

static void som_chegou(Dv *d, const struct usbdevfs_urb *u) {
    int64_t t = agora_ns();
    if (d->som_ultima_ns) {
        int64_t ms = (t - d->som_ultima_ns) / 1000000;
        d->som_intervalos[ms < 4 ? 0 : ms < 12 ? 1 : ms < 20 ? 2 : ms < 40 ? 3 : 4]++;
    }
    d->som_ultima_ns = t;
    pthread_mutex_lock(&d->som_mu);
    for (int k = 0; k < u->number_of_packets; k++) {
        const struct usbdevfs_iso_packet_desc *pk = &u->iso_frame_desc[k];
        atomic_fetch_add(&d->c_som_pacotes, 1);
        if (pk->status != 0) { atomic_fetch_add(&d->c_som_erros, 1); continue; }
        const uint8_t *p = (const uint8_t *)u->buffer + (size_t)k * d->som_psize;
        int passo = d->som_passo, n = (int)(pk->actual_length / (2 * (unsigned)passo));
        for (int j = 0; j < n; j++) {
            // A média das `passo` amostras: estéreo vira mono, 96 kHz vira 48 kHz.
            int soma = 0;
            for (int c = 0; c < passo; c++) {
                const uint8_t *a = p + 2 * (j * passo + c);
                soma += (int16_t)(a[0] | (a[1] << 8));
            }
            d->som_anel[d->som_w % SOM_ANEL] = (int16_t)(soma / passo);
            d->som_w++;
        }
    }
    if (d->som_w - d->som_r > SOM_ANEL) {
        atomic_fetch_add(&d->c_som_caidas, d->som_w - d->som_r - SOM_ANEL);
        d->som_r = d->som_w - SOM_ANEL;
    }
    d->som_ts_w = t;
    pthread_cond_broadcast(&d->som_cv);
    pthread_mutex_unlock(&d->som_mu);
}

// Um envio recusado (ENOMEM do kmalloc da URB, §3.3): a URB fica pendente e tenta de novo com
// recuo (RECUO_NS desde a última tentativa dela). `c_reenvio_recusado` conta URBs distintas que
// ficaram pendentes alguma vez; `c_tentativas_recusadas`, cada recusa (a revisão do código da P1,
// 4). A primeira vai ao logcat.
#define RECUO_NS 100000000LL
static void envio_recusado(Dv *d, int i, int r) {
    if (atomic_fetch_add(&d->c_tentativas_recusadas, 1) == 0)
        LOGW("envio da URB %d recusado: %s (fica pendente e tenta de novo a cada 100 ms)", i, strerror(-r));
    if (!d->ja_pendente[i]) { d->ja_pendente[i] = 1; atomic_fetch_add(&d->c_reenvio_recusado, 1); }
    d->pendente[i] = 1;
    d->tentou_em[i] = agora_ns();
}

static void *laco_usb(void *arg) {
    Dv *d = arg;
    int64_t sem_urb_desde = 0;  // desde quando nenhuma URB está no ar (só pendentes)
    while (!atomic_load(&d->parar)) {
        struct pollfd pf = {.fd = d->fd, .events = POLLOUT | POLLWRNORM};
        int pr = poll(&pf, 1, 100);
        if (pr < 0 && errno != EINTR) { marca_morta(d, "poll falhou"); break; }
        int morta = 0;
        for (;;) {
            struct usbdevfs_urb *u = NULL;
            if (ioctl(d->fd, USBDEVFS_REAPURBNDELAY, &u) < 0) {
                if (errno == EAGAIN) break;
                if (errno == ENODEV) { morta = 1; break; }
                LOGW("REAPURB: %s", strerror(errno));
                break;
            }
            int s = indice_som(d, u);
            if (s >= 0) {
                d->som_no_ar[s] = 0;
                if (u->status == -ENODEV || u->status == -ESHUTDOWN) { morta = 1; break; }
                som_chegou(d, u);
                if (!atomic_load(&d->parar) && envia_som(d, s) == -ENODEV) { morta = 1; break; }
                continue;
            }
            int i = indice_urb(d, u);
            if (i < 0) continue;
            d->no_ar[i] = 0;
            if (u->status == -ENODEV || u->status == -ESHUTDOWN) { morta = 1; break; }
            // O carimbo é do pacote, e não da URB: o reap vê a URB inteira de uma vez, e o pacote
            // k chegou (N-1-k) microquadros de 125 µs antes do último.
            int64_t t_reap = agora_ns();
            d->rm.aceitar_ruim = atomic_load(&d->gravacao);
            if (d->bulk) {
                // Bulk: a URB inteira é um payload UVC (o cabeçalho no começo; o fim pela URB curta
                // ou pelo dwMaxPayloadTransferSize, como o espião mediu nas duas placas bulk).
                if (u->status == 0) {
                    remonta_payload(&d->rm, (const uint8_t *)u->buffer, (size_t)u->actual_length, t_reap);
                } else {
                    remonta_pacote_ruim(&d->rm);
                    atomic_fetch_add(&d->c_erros_pacote, 1);
                }
            }
            for (int k = 0; k < u->number_of_packets; k++) {
                int64_t ts = t_reap - (int64_t)(u->number_of_packets - 1 - k) * 125000;
                struct usbdevfs_iso_packet_desc *pk = &u->iso_frame_desc[k];
                if (pk->status != 0) {
                    remonta_pacote_ruim(&d->rm);
                    atomic_fetch_add(&d->c_erros_pacote, 1);
                    continue;
                }
                // No usbfs, o pacote k fica em k x (comprimento pedido).
                remonta_payload(&d->rm, (const uint8_t *)u->buffer + (size_t)k * d->psize,
                                pk->actual_length, ts);
            }
            if (!atomic_load(&d->parar)) {
                int r = envia(d, i);
                if (r == -ENODEV) { morta = 1; break; }
                if (r < 0) envio_recusado(d, i, r);
            }
        }
        // As recusadas tentam de novo (a revisão da placa, 2; como o espião), cada uma no máximo
        // a cada 100 ms: sem o recuo, com URBs no ar o poll volta a cada ~1 ms e o kmalloc que
        // acabou de falhar seria pedido de novo mil vezes por segundo.
        int64_t t_pend = agora_ns();
        if (atomic_load(&d->som_pedido) && !d->som_ligado && !morta) liga_som(d);
        for (int i = 0; i < SOM_URBS && d->som_ligado && !morta && !atomic_load(&d->parar); i++) {
            if (!d->som_urbs[i] || !d->som_pendente[i] || t_pend - d->som_tentou_em[i] < RECUO_NS) continue;
            if (envia_som(d, i) == -ENODEV) morta = 1;
        }
        for (int i = 0; i < d->n_urbs && !morta && !atomic_load(&d->parar); i++) {
            if (!d->pendente[i] || t_pend - d->tentou_em[i] < RECUO_NS) continue;
            int r = envia(d, i);
            if (r == 0) d->pendente[i] = 0;
            else if (r == -ENODEV) morta = 1;
            else envio_recusado(d, i, r);
        }
        if (morta) { marca_morta(d, "desconectada (ENODEV)"); break; }
        int restam = 0, pendentes = 0;
        for (int i = 0; i < d->n_urbs; i++) { restam += d->no_ar[i]; pendentes += d->pendente[i]; }
        if (restam) {
            sem_urb_desde = 0;
        } else if (!pendentes) {
            marca_morta(d, "todas as URBs caíram");
            break;
        } else {
            // Só pendentes: o poll acima volta a cada 100 ms e elas tentam de novo; 2 s assim é
            // o kernel recusando tudo, e a câmera cai com o motivo.
            int64_t t = agora_ns();
            if (!sem_urb_desde) sem_urb_desde = t;
            else if (t - sem_urb_desde > 2000000000LL) {
                marca_morta(d, "todas as URBs caíram (reenvio recusado há 2 s)");
                break;
            }
        }
    }
    // Recolhe: descarta as URBs no ar e espera voltarem (no máximo ~2 s).
    som_acaba(d);
    for (int i = 0; i < d->n_urbs; i++)
        if (d->no_ar[i]) ioctl(d->fd, USBDEVFS_DISCARDURB, d->urbs[i]);
    for (int i = 0; i < SOM_URBS; i++)
        if (d->som_no_ar[i]) ioctl(d->fd, USBDEVFS_DISCARDURB, d->som_urbs[i]);
    int64_t limite = agora_ns() + 2000000000LL;
    for (;;) {
        int restam = 0;
        for (int i = 0; i < d->n_urbs; i++) restam += d->no_ar[i];
        for (int i = 0; i < SOM_URBS; i++) restam += d->som_no_ar[i];
        if (!restam) break;
        if (agora_ns() > limite) {
            LOGW("%d URBs não voltaram; os buffers delas ficam vazados de propósito", restam);
            break;
        }
        struct pollfd pf = {.fd = d->fd, .events = POLLOUT | POLLWRNORM};
        poll(&pf, 1, 100);
        struct usbdevfs_urb *u = NULL;
        while (ioctl(d->fd, USBDEVFS_REAPURBNDELAY, &u) == 0) {
            int s = indice_som(d, u);
            if (s >= 0) { d->som_no_ar[s] = 0; continue; }
            int i = indice_urb(d, u);
            if (i >= 0) d->no_ar[i] = 0;
        }
        if (errno == ENODEV) {
            // Aparelho sumiu: o kernel já matou as URBs; não voltam por reap.
            for (int i = 0; i < d->n_urbs; i++) d->no_ar[i] = 0;
            for (int i = 0; i < SOM_URBS; i++) d->som_no_ar[i] = 0;
            break;
        }
    }
    return NULL;
}

// Bancada: um arquivo de quadros DV (gravado pelo espião) no ritmo de 29,97, em laço, no lugar do
// USB. Prova o caminho inteiro (fila, decodificação, ImageWriter, encoder, receptor) sem filmadora
// e sem diálogo de permissão.
static void *laco_arquivo(void *arg) {
    Dv *d = arg;
    size_t n = d->n_arquivo / QUADRO, q = 0;
    int64_t prox = agora_ns();
    while (!atomic_load(&d->parar)) {
        int64_t t = agora_ns();
        if (t < prox) {
            struct timespec ts = {0, (long)(prox - t)};
            nanosleep(&ts, NULL);
            continue;
        }
        prox += 1001000000LL / 30;
        const uint8_t *quadro = d->arquivo + (q % n) * QUADRO;
        q++;
        atomic_fetch_add(&d->rm.integros, 1);
        entrega_quadro(d, quadro, QUADRO, agora_ns(), 0);
    }
    return NULL;
}

// ------------------------------------------------------------------------------ imagem
// O DISP do pacote VSC (0x61), como o dvdec.c do FFmpeg: sequência 0, bloco VAUX 3 (80*5 + 48 + 5);
// 16:9 se DISP == 2, ou DISP == 7 com APT == 0. -1 sem o pacote.
static int disp_169(const uint8_t *q) {
    const uint8_t *p = q + 80 * 5 + 48 + 5;
    if (p[0] != 0x61) return -1;
    int disp = p[2] & 7, apt = q[4] & 7;
    return disp == 2 || (apt == 0 && disp == 7);
}

static int ela(const uint8_t *a, const uint8_t *b, int x) {
    int melhor = abs(a[x] - b[x]), r = (a[x] + b[x] + 1) >> 1;
    if (x > 0 && x < LARG - 1) {
        int d1 = abs(a[x - 1] - b[x + 1]), d2 = abs(a[x + 1] - b[x - 1]);
        if (d1 < melhor) { melhor = d1; r = (a[x - 1] + b[x + 1] + 1) >> 1; }
        if (d2 < melhor) r = (a[x + 1] + b[x - 1] + 1) >> 1;
    }
    return r;
}

static int pente(int v, int a, int b) {
    int lo = a < b ? a : b, hi = a < b ? b : a;
    return v > hi ? v - hi : v < lo ? lo - v : 0;
}

#define LIMIAR_MOV 10
#define LIMIAR_PENTE 3
#define JANELA 3

// adapt2 da fase A (bancada-dv/dv-bancada.c, medido em mede-desentrelacado.py): as linhas pares
// (campo de cima, o mais novo) ficam; nas ímpares, bob com ELA onde há movimento temporal > 10 ou
// pente médio em x±3 > 3, e weave no resto. Sem quadro anterior, tudo bob.
static void desentrelacar(Dv *d, uint8_t *const in[3], const int is[3]) {
    uint8_t *const *ant = d->tem_ant ? d->ant : NULL;
    for (int y = 1; y < ALT; y += 2) {
        const uint8_t *l = in[0] + y * is[0];
        const uint8_t *a = in[0] + (y - 1) * is[0];
        const uint8_t *b = y + 1 < ALT ? in[0] + (y + 1) * is[0] : a;
        uint8_t *m = d->mascara + y * LARG;
        if (!ant) { memset(m, 1, LARG); continue; }
        const uint8_t *pa = ant[0] + (y - 1) * LARG, *pl = ant[0] + y * LARG;
        const uint8_t *pb = y + 1 < ALT ? ant[0] + (y + 1) * LARG : pa;
        int acum[LARG + 1];
        acum[0] = 0;
        for (int x = 0; x < LARG; x++) acum[x + 1] = acum[x] + pente(l[x], a[x], b[x]);
        for (int x = 0; x < LARG; x++) {
            int mov = abs(l[x] - pl[x]);
            int t = abs(a[x] - pa[x]); if (t > mov) mov = t;
            t = abs(b[x] - pb[x]); if (t > mov) mov = t;
            int bob = mov > LIMIAR_MOV;
            if (!bob) {
                int x0 = x - JANELA < 0 ? 0 : x - JANELA;
                int x1 = x + JANELA + 1 > LARG ? LARG : x + JANELA + 1;
                bob = acum[x1] - acum[x0] > LIMIAR_PENTE * (x1 - x0);
            }
            m[x] = (uint8_t)bob;
        }
    }
    // Dilatação vertical da decisão, como a referência medida (dv-bancada.c, adapt2 com R0): a
    // linha ímpar y vai a bob onde a decisão de y-2, y ou y+2 foi bob. A linha par da máscara é o
    // rascunho (cópia da decisão da ímpar seguinte), e não decide nada.
    if (ant) {
        for (int y = 1; y < ALT; y += 2) memcpy(d->mascara + (y - 1) * LARG, d->mascara + y * LARG, LARG);
        for (int y = 1; y < ALT; y += 2) {
            uint8_t *m = d->mascara + y * LARG;
            const uint8_t *r0 = d->mascara + (y - 1) * LARG;
            const uint8_t *rm = y >= 3 ? d->mascara + (y - 3) * LARG : r0;
            const uint8_t *rp = y + 2 < ALT ? d->mascara + (y + 1) * LARG : r0;
            for (int x = 0; x < LARG; x++) m[x] = (uint8_t)(r0[x] | rm[x] | rp[x]);
        }
    }
    for (int y = 0; y < ALT; y++) {
        const uint8_t *l = in[0] + y * is[0];
        uint8_t *o = d->des[0] + y * LARG;
        if ((y & 1) == 0) { memcpy(o, l, LARG); continue; }
        const uint8_t *a = in[0] + (y - 1) * is[0];
        const uint8_t *b = y + 1 < ALT ? in[0] + (y + 1) * is[0] : a;
        const uint8_t *m = d->mascara + y * LARG;
        for (int x = 0; x < LARG; x++) o[x] = m[x] ? (uint8_t)ela(a, b, x) : l[x];
    }
    for (int p = 1; p < 3; p++) {
        for (int y = 0; y < ALT; y++) {
            const uint8_t *l = in[p] + y * is[p];
            uint8_t *o = d->des[p] + y * CLARG;
            if ((y & 1) == 0) { memcpy(o, l, CLARG); continue; }
            const uint8_t *a = in[p] + (y - 1) * is[p];
            const uint8_t *b = y + 1 < ALT ? in[p] + (y + 1) * is[p] : a;
            const uint8_t *m = d->mascara + y * LARG;
            for (int x = 0; x < CLARG; x++) {
                int bob = m[4 * x] | m[4 * x + 1] | m[4 * x + 2] | m[4 * x + 3];
                o[x] = bob ? (uint8_t)((a[x] + b[x] + 1) >> 1) : l[x];
            }
        }
    }
    // o cru deste quadro é o anterior do próximo
    for (int y = 0; y < ALT; y++) memcpy(d->ant[0] + y * LARG, in[0] + y * is[0], LARG);
    for (int p = 1; p < 3; p++)
        for (int y = 0; y < ALT; y++) memcpy(d->ant[p] + y * CLARG, in[p] + y * is[p], CLARG);
    d->tem_ant = 1;
}

static void escala_libera(Escala *e) { free(e->x0); free(e->f); e->x0 = e->f = NULL; e->n = 0; }

// Amostra i da saída (centro em i + 0.5, em unidades da saída) → posição na fonte (centro):
// (i + 0.5) * de / para - 0.5. `desloc`/`div` servem ao croma: posição em luma da fonte →
// índice de croma. `cositado`: a amostra k do croma fica no luma div*k (a DV 4:1:1, à esquerda);
// senão no centro dos div lumas que cobre (o JPEG: k ↔ luma div*(k + 0.5) - 0.5). Com div 1 as
// duas contas dão o mesmo.
static void escala_nova(Escala *e, int de_amostras, int para, double borda_saida_por_amostra,
                        double deslocamento_saida, double fonte_por_saida, double div, int cositado) {
    e->x0 = malloc(sizeof(int) * para);
    e->f = malloc(sizeof(int) * para);
    e->n = para;
    for (int i = 0; i < para; i++) {
        double borda = (i * borda_saida_por_amostra + deslocamento_saida) * fonte_por_saida;
        // no croma horizontal da DV, a amostra k está em luma 4k
        double s = cositado ? (borda - 0.5) / div : borda / div - 0.5;
        if (s < 0) s = 0;
        int x0 = (int)s;
        if (x0 >= de_amostras - 1) { x0 = de_amostras - 2; s = de_amostras - 1; }
        e->x0[i] = x0;
        e->f[i] = (int)((s - x0) * 256 + 0.5);
    }
}

// Prepara as escalas para um retângulo de destino dw x dh (em luma, pares), a partir dos planos de
// `des` (lw x lh, croma cw x ch). `esc_w = 0` força refazer (a subamostragem mudou).
static void prepara_escalas(Dv *d, int dw, int dh) {
    if (d->esc_w == dw && d->esc_h == dh) return;
    escala_libera(&d->ey_x); escala_libera(&d->ey_y); escala_libera(&d->ec_x); escala_libera(&d->ec_y);
    double sx = (double)d->lw / dw, sy = (double)d->lh / dh;
    int cositado = !d->centrado;
    // luma: centro a centro
    escala_nova(&d->ey_x, d->lw, dw, 1.0, 0.5, sx, 1.0, 1);
    escala_nova(&d->ey_y, d->lh, dh, 1.0, 0.5, sy, 1.0, 1);
    // croma horizontal: a saída co-situada à esquerda (saída i em luma 2i); a fonte na DV também
    // (k em 4k), no JPEG no centro (4:2:2 e 4:2:0: k em 2k + 0.5)
    escala_nova(&d->ec_x, d->cw, dw / 2, 2.0, 0.5, sx, (double)d->lw / d->cw, cositado);
    // croma vertical: a linha j do 4:2:0 cobre as linhas de luma 2j e 2j+1 (borda em 2j+1); a fonte
    // DV (4:1:1 progressivo) e o JPEG 4:2:2 têm uma linha de croma por linha de luma, o 4:2:0 uma
    // a cada duas (no centro)
    escala_nova(&d->ec_y, d->ch, dh / 2, 2.0, 1.0, sy, (double)d->lh / d->ch, cositado);
    d->esc_w = dw;
    d->esc_h = dh;
}

static inline uint8_t bilinear(const uint8_t *p, int stride, int x0, int fx, int y0, int fy) {
    const uint8_t *l0 = p + y0 * stride, *l1 = l0 + stride;
    int a = l0[x0] * (256 - fx) + l0[x0 + 1] * fx;
    int b = l1[x0] * (256 - fx) + l1[x0 + 1] * fx;
    return (uint8_t)((a * (256 - fy) + b * fy + 32768) >> 16);
}

// Escreve o quadro progressivo (d->des: lw x lh, croma cw x ch) no destino 4:2:0 W x H com o
// retângulo (rx, ry, rw, rh) e faixas pretas fora dele. U e V podem ser planares (pixelStride 1) ou
// intercalados (2). Os valores passam como estão (faixa limitada nos dois formatos, §3.5).
static void para_destino(Dv *d, uint8_t *Y, int ys, uint8_t *U, uint8_t *V, int cs, int cps,
                         int W, int H, int rx, int ry, int rw, int rh) {
    prepara_escalas(d, rw, rh);
    for (int y = 0; y < H; y++) {
        uint8_t *o = Y + (size_t)y * ys;
        if (y < ry || y >= ry + rh) { memset(o, 16, W); continue; }
        if (rx > 0) memset(o, 16, rx);
        if (rx + rw < W) memset(o + rx + rw, 16, W - rx - rw);
        if (d->pular_luma) continue;  // o caminho HQ escreve o luma do retângulo
        int yy = y - ry, y0 = d->ey_y.x0[yy], fy = d->ey_y.f[yy];
        for (int i = 0; i < rw; i++)
            o[rx + i] = bilinear(d->des[0], d->lw, d->ey_x.x0[i], d->ey_x.f[i], y0, fy);
    }
    int CW = W / 2, CH = H / 2, crx = rx / 2, cry = ry / 2, crw = rw / 2, crh = rh / 2;
    for (int p = 0; p < 2; p++) {
        uint8_t *dst = p == 0 ? U : V;
        const uint8_t *src = d->des[p + 1];
        for (int y = 0; y < CH; y++) {
            uint8_t *o = dst + (size_t)y * cs;
            int dentro_y = y >= cry && y < cry + crh;
            int yy = y - cry;
            int y0 = dentro_y ? d->ec_y.x0[yy] : 0, fy = dentro_y ? d->ec_y.f[yy] : 0;
            for (int x = 0; x < CW; x++) {
                uint8_t v = 128;
                if (dentro_y && x >= crx && x < crx + crw) {
                    int xx = x - crx;
                    v = bilinear(src, d->cw, d->ec_x.x0[xx], d->ec_x.f[xx], y0, fy);
                }
                o[(size_t)x * cps] = v;
            }
        }
    }
}

// ------------------------------------------------------------------------------ JNI
#define FN(nome) Java_com_quall_android_capture_dv_QuallDv_##nome
JNIEXPORT void JNICALL FN(fechar)(JNIEnv *env, jclass cls, jlong h);

static Dv *novo_dv(int formato, int largura, int altura, size_t cap_quadro);

JNIEXPORT jlong JNICALL FN(abrirArquivo)(JNIEnv *env, jclass cls, jstring caminho) {
    Dv *d = novo_dv(FORMATO_DV, LARG, ALT, QUADRO);
    if (!d) return 0;
    const char *c = (*env)->GetStringUTFChars(env, caminho, NULL);
    FILE *f = fopen(c, "rb");
    if (f) {
        fseek(f, 0, SEEK_END);
        long tam = ftell(f);
        fseek(f, 0, SEEK_SET);
        size_t n = tam > 0 ? (size_t)tam / QUADRO * QUADRO : 0;
        d->arquivo = n ? malloc(n) : NULL;
        if (d->arquivo && fread(d->arquivo, 1, n, f) == n) d->n_arquivo = n;
        fclose(f);
    }
    LOGI("bancada: arquivo aberto, %zu quadros", d->n_arquivo / QUADRO);
    (*env)->ReleaseStringUTFChars(env, caminho, c);
    if (!d->n_arquivo || pthread_create(&d->thread, NULL, laco_arquivo, d) != 0) {
        FN(fechar)(env, cls, (jlong)(intptr_t)d);
        return 0;
    }
    d->thread_viva = 1;
    return (jlong)(intptr_t)d;
}

// `formato`: FORMATO_DV ou FORMATO_MJPEG; `largura` x `altura` e `quadro_max` (o
// dwMaxVideoFrameSize do commit) valem no MJPEG; a DV é sempre 720x480 de 120 000 bytes.
// `bulk` != 0: o endpoint é bulk e `payload_max` é o dwMaxPayloadTransferSize (o tamanho da URB).
// `cru` != 0: o quadro é NV12 não comprimido de largura x altura (o formato fica FORMATO_MJPEG).
JNIEXPORT jlong JNICALL FN(abrir)(JNIEnv *env, jclass cls, jint fd, jint endpoint, jint psize,
                                  jint formato, jint largura, jint altura, jlong quadro_max,
                                  jint bulk, jint payload_max, jint cru) {
    if (formato != FORMATO_DV && formato != FORMATO_MJPEG) return 0;
    if (cru && formato != FORMATO_MJPEG) return 0;
    if (formato == FORMATO_MJPEG) {
        if (largura < 16 || altura < 16 || largura > 4096 || altura > 4096 || (largura & 1) || (altura & 1)) {
            LOGW("MJPEG: tamanho %dx%d recusado", largura, altura);
            return 0;
        }
        // O dwMaxVideoFrameSize da placa é 614400 (medido); um valor absurdo vira o do quadro cru
        // 4:2:2, que um JPEG não passa.
        if (quadro_max < 16384 || quadro_max > 16 * 1024 * 1024) quadro_max = (jlong)largura * altura * 2;
        // Não comprimido, o tamanho exato: NV12 (1) 12 bits por pixel; YUY2 (2) 16.
        if (cru) quadro_max = cru == 2 ? (jlong)largura * altura * 2 : (jlong)largura * altura * 3 / 2;
    }
    Dv *d = formato == FORMATO_MJPEG ? novo_dv(FORMATO_MJPEG, largura, altura, (size_t)quadro_max)
                                     : novo_dv(FORMATO_DV, LARG, ALT, QUADRO);
    if (!d) return 0;
    d->fd = fd; d->endpoint = endpoint; d->psize = psize;
    if (cru) {
        // NV12: 4:2:0 com o croma intercalado; YUY2: 4:2:2 empacotado (Y0 U Y1 V). Os planos de `des`
        // recebem Y, U e V separados.
        d->cru = cru == 2 ? 2 : 1;
        d->rm.cru_tam = (size_t)quadro_max;
        d->cw = largura / 2; d->ch = cru == 2 ? altura : altura / 2; d->centrado = 0;
    }
    if (bulk) {
        d->bulk = 1;
        d->tam_bulk = payload_max < 512 ? 16384 : payload_max > (1 << 20) ? (1 << 20) : payload_max;
        d->n_urbs = URBS_BULK;
        d->n_pacotes = 0;
    } else {
        dimensiona_urbs(d->formato, psize, &d->n_urbs, &d->n_pacotes);
    }
    for (int i = 0; i < d->n_urbs; i++) {
        d->urbs[i] = calloc(1, sizeof(struct usbdevfs_urb) + d->n_pacotes * sizeof(struct usbdevfs_iso_packet_desc));
        if (!d->urbs[i]) goto falha_urbs;
        d->urbs[i]->type = bulk ? USBDEVFS_URB_TYPE_BULK : USBDEVFS_URB_TYPE_ISO;
        d->urbs[i]->endpoint = (unsigned char)endpoint;
        d->urbs[i]->flags = bulk ? 0 : USBDEVFS_URB_ISO_ASAP;
        d->urbs[i]->usercontext = (void *)(intptr_t)i;
        d->urbs[i]->buffer = malloc(bulk ? (size_t)d->tam_bulk : (size_t)psize * d->n_pacotes);
        if (!d->urbs[i]->buffer) goto falha_urbs;
    }
    int enviados = 0, recusadas = 0;
    for (int i = 0; i < d->n_urbs; i++) {
        int r = envia(d, i);
        if (r == -ENODEV) { LOGW("SUBMITURB %d: %s", i, strerror(-r)); goto falha_urbs; }
        if (r < 0) {
            // Pendente: a thread tenta de novo (antes, a primeira recusa parava o envio e as
            // seguintes nunca iam ao ar).
            if (!recusadas++) LOGW("SUBMITURB %d: %s (fica pendente)", i, strerror(-r));
            envio_recusado(d, i, r);
            continue;
        }
        enviados++;
    }
    if (!enviados) goto falha_urbs;
    if (pthread_create(&d->thread, NULL, laco_usb, d) != 0) goto falha_urbs;
    d->thread_viva = 1;
    LOGI("aberta: %s %dx%d quadro_max %zu, endpoint 0x%02x psize %d, %d URBs de %d pacotes "
         "(%d bytes cada%s), %d recusadas no envio; %s",
         cru == 2 ? "YUY2" : cru ? "NV12" : formato == FORMATO_MJPEG ? "MJPEG" : "DV", d->lw, d->lh, d->cap_quadro, endpoint, psize,
         enviados, d->n_pacotes, bulk ? d->tam_bulk : psize * d->n_pacotes, bulk ? ", bulk" : "", recusadas,
         avcodec_license());
    return (jlong)(intptr_t)d;

falha_urbs:
    for (int i = 0; i < d->n_urbs; i++)
        if (d->no_ar[i]) ioctl(fd, USBDEVFS_DISCARDURB, d->urbs[i]);
    // sem thread: as que foram ao ar vazam de propósito (não sabemos esperar aqui)
    for (int i = 0; i < d->n_urbs; i++) if (d->no_ar[i]) d->urbs[i] = NULL;
    FN(fechar)(env, cls, (jlong)(intptr_t)d);
    return 0;
}

static int mdc(int a, int b) { while (b) { int t = a % b; a = b; b = t; } return a; }

static Dv *novo_dv(int formato, int largura, int altura, size_t cap_quadro) {
    Dv *d = calloc(1, sizeof(Dv));
    if (!d) return NULL;
    d->fd = -1;
    d->atual = -1; d->disp169 = -1;
    d->formato = formato;
    pthread_mutex_init(&d->mu, NULL);
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);  // o prazo não anda com o relógio de parede
    pthread_cond_init(&d->cv, &ca);
    pthread_mutex_init(&d->som_mu, NULL);
    pthread_cond_init(&d->som_cv, &ca);
    pthread_condattr_destroy(&ca);
    if (remonta_inicia(&d->rm, formato, cap_quadro, entrega_quadro, d) < 0) { LOGW("sem memória"); goto falha; }
    d->cap_quadro = cap_quadro;
    if (formato == FORMATO_DV) {
        d->n_buf = N_BUF;
        d->lw = LARG; d->lh = ALT; d->cw = CLARG; d->ch = ALT; d->centrado = 0;
        for (int p = 0; p < 3; p++) {
            int w = p ? CLARG : LARG;
            d->ant[p] = malloc((size_t)w * ALT);
            d->des[p] = malloc((size_t)w * ALT);
        }
        d->mascara = calloc(LARG, ALT);
    } else {
        // MJPEG: sem desentrelaçamento nem o som/HQ da fita (a gravação da placa usa o
        // `escrever`); o croma começa como 4:2:2 (o que a placa manda) e segue o que o
        // decodificador disser. Os planos de croma têm o tamanho do
        // luma, para caber qualquer subamostragem sem realocar (a prévia segura os ponteiros).
        // Um quadro grande (1440p e 4K sem compressão: 5,5 e 12,4 MB) não cabe nove vezes à toa.
        d->n_buf = cap_quadro > 4 * 1024 * 1024 ? 5 : N_BUF_MJPEG;
        d->lw = largura; d->lh = altura; d->cw = largura / 2; d->ch = altura; d->centrado = 1;
        int g = mdc(largura, altura);
        d->an = largura / g; d->ad = altura / g;
        d->disp169 = 0;  // o `aspectoDecodificado` responde 4:3 (o aspecto de fato é an:ad)
        for (int p = 0; p < 3; p++) d->des[p] = calloc((size_t)largura, (size_t)altura);
    }
    for (int i = 0; i < d->n_buf; i++) if (!(d->buf[i] = malloc(cap_quadro))) { LOGW("sem memória"); goto falha; }
    for (int p = 0; p < 3; p++) if (!d->des[p]) { LOGW("sem memória"); goto falha; }

    const AVCodec *cod = avcodec_find_decoder(formato == FORMATO_MJPEG ? AV_CODEC_ID_MJPEG : AV_CODEC_ID_DVVIDEO);
    d->ctx = cod ? avcodec_alloc_context3(cod) : NULL;
    if (!d->ctx) { LOGW("sem o decodificador %s", formato == FORMATO_MJPEG ? "mjpeg" : "dvvideo"); goto falha; }
    d->ctx->thread_count = 1;
    if (avcodec_open2(d->ctx, cod, NULL) < 0) { LOGW("avcodec_open2 falhou"); goto falha; }
    d->fr = av_frame_alloc();
    d->pk = av_packet_alloc();
    // O pacote do decodificador com o preenchimento zerado que o FFmpeg exige depois do dado.
    d->pkbuf = av_mallocz(cap_quadro + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!d->fr || !d->pk || !d->pkbuf) { LOGW("sem memória"); goto falha; }

    return d;

falha:
    FN(fechar)(NULL, NULL, (jlong)(intptr_t)d);
    return NULL;
}

// Espera o próximo quadro. Devolve o carimbo (CLOCK_MONOTONIC, ns), -1 no prazo, -2 desconectada.
JNIEXPORT jlong JNICALL FN(esperar)(JNIEnv *env, jclass cls, jlong h, jint timeout_ms) {
    (void)env; (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    struct timespec lim;
    clock_gettime(CLOCK_MONOTONIC, &lim);
    lim.tv_sec += timeout_ms / 1000;
    lim.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (lim.tv_nsec >= 1000000000L) { lim.tv_sec++; lim.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&d->mu);
    if (d->atual >= 0) { d->estado[d->atual] = LIVRE; d->atual = -1; }
    for (;;) {
        // O mais novo: um quadro na fila atrás de outro só somaria um quadro de latência. Os mais
        // velhos caem (e contam).
        int melhor = -1;
        uint64_t maior = 0;
        int fifo = atomic_load(&d->gravacao);
        for (int i = 0; i < d->n_buf; i++)
            if (d->estado[i] == NA_FILA &&
                (melhor < 0 || (fifo ? d->seq[i] < maior : d->seq[i] > maior))) { maior = d->seq[i]; melhor = i; }
        if (melhor >= 0) {
            for (int i = 0; i < d->n_buf && !fifo; i++)
                if (i != melhor && d->estado[i] == NA_FILA) {
                    d->estado[i] = LIVRE;
                    atomic_fetch_add(&d->c_caidos_fila, 1);
                }
            d->estado[melhor] = COM_CONSUMIDORA;
            d->atual = melhor;
            jlong ts = d->ts[melhor];
            pthread_mutex_unlock(&d->mu);
            return ts;
        }
        if (d->morta) { pthread_mutex_unlock(&d->mu); return -2; }
        if (pthread_cond_timedwait(&d->cv, &d->mu, &lim) == ETIMEDOUT) {
            pthread_mutex_unlock(&d->mu);
            return -1;
        }
    }
}

// Esvazia a fila (o começo de uma sessão não usa quadro guardado de antes). Devolve quantos caíram.
JNIEXPORT jint JNICALL FN(descartar)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    int n = 0;
    pthread_mutex_lock(&d->mu);
    for (int i = 0; i < d->n_buf; i++)
        if (d->estado[i] == NA_FILA) { d->estado[i] = LIVRE; n++; }
    if (d->atual >= 0) { d->estado[d->atual] = LIVRE; d->atual = -1; }
    pthread_mutex_unlock(&d->mu);
    return n;
}

// Aspecto do quadro que está com a consumidora: 1 = 16:9, 0 = 4:3, -1 = sem pacote VSC. No MJPEG
// sempre 0: o `disp_169` leria bytes do JPEG como se fossem o VAUX (a revisão, 6), e o aspecto é o
// do quadro (ver `geometria`).
JNIEXPORT jint JNICALL FN(aspecto)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    if (d->atual < 0) return -1;
    if (d->formato != FORMATO_DV) return 0;
    return disp_169(d->buf[d->atual]);
}

static int falha_decod(Dv *d, const char *porque, int a, int b) {
    atomic_fetch_add(&d->c_decod_falhas, 1);
    if (!d->avisou_decod) {
        d->avisou_decod = 1;
        LOGW("%s: decodificação falhou (%s %d %d); as seguintes só contam", d->formato == FORMATO_MJPEG ? "MJPEG" : "DV",
             porque, a, b);
    }
    return -2;
}

// MJPEG: os planos do quadro decodificado vão para `des` como estão (sem compressão de faixa nem
// desentrelaçamento, §3.5 e §3.6), com a subamostragem que o decodificador disser.
static int copia_mjpeg(Dv *d) {
    const AVFrame *fr = d->fr;
    int cw, ch;
    switch (fr->format) {
    case AV_PIX_FMT_YUVJ422P: case AV_PIX_FMT_YUV422P: cw = (fr->width + 1) / 2; ch = fr->height; break;
    case AV_PIX_FMT_YUVJ420P: case AV_PIX_FMT_YUV420P: cw = (fr->width + 1) / 2; ch = (fr->height + 1) / 2; break;
    case AV_PIX_FMT_YUVJ444P: case AV_PIX_FMT_YUV444P: cw = fr->width; ch = fr->height; break;
    default: return falha_decod(d, "formato de pixel não aceito", fr->format, 0);
    }
    if (fr->width != d->lw || fr->height != d->lh) return falha_decod(d, "tamanho diferente do negociado", fr->width, fr->height);
    if (cw < 2 || ch < 2) return falha_decod(d, "croma pequeno demais", cw, ch);
    for (int y = 0; y < d->lh; y++) memcpy(d->des[0] + (size_t)y * d->lw, fr->data[0] + (size_t)y * fr->linesize[0], d->lw);
    for (int p = 1; p < 3; p++)
        for (int y = 0; y < ch; y++)
            memcpy(d->des[p] + (size_t)y * cw, fr->data[p] + (size_t)y * fr->linesize[p], cw);
    if (!d->decodificado || cw != d->cw || ch != d->ch) {
        LOGI("MJPEG: %dx%d %s, croma %dx%d, faixa do JPEG %s (ignorada: os valores vão como estão, §3.5)",
             fr->width, fr->height, av_get_pix_fmt_name(fr->format), cw, ch, av_color_range_name(fr->color_range));
        d->cw = cw; d->ch = ch;
        d->esc_w = d->esc_h = 0;  // as escalas do croma mudam
    }
    return 0;
}

// Decodifica o quadro que está com a consumidora nos planos internos `des`, uma vez por quadro, e
// guarda o aspecto dele: na DV, desentrelaçado (Y 720x480, U/V 180x480, 4:1:1 progressivo); no
// MJPEG, os planos do JPEG (lw x lh, croma cw x ch). Os destinos (o Image do espelhamento por
// `escrever`; a GPU da prévia e da gravação por `planos`) partem daí. 0 = ok, -1 = sem quadro,
// -2 = decodificação falhou.
JNIEXPORT jint JNICALL FN(decodificar)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    if (d->atual < 0) return -1;
    const uint8_t *q = d->buf[d->atual];
    size_t nq = d->tam[d->atual];
    int64_t t0 = agora_ns();
    if (d->cru) {
        // Sem decodificar: o luma e o croma vão para os três planos.
        size_t ny = (size_t)d->lw * d->lh, nc = (size_t)d->cw * d->ch;
        if (nq != ny + 2 * nc) return falha_decod(d, "quadro não comprimido de tamanho errado", (int)nq, (int)(ny + 2 * nc));
        uint8_t *py = d->des[0], *pu = d->des[1], *pv = d->des[2];
        if (d->cru == 2) {
            // YUY2: Y0 U Y1 V por par de pixels.
            for (size_t i = 0; i < nc; i++) {
                py[2 * i] = q[4 * i]; pu[i] = q[4 * i + 1]; py[2 * i + 1] = q[4 * i + 2]; pv[i] = q[4 * i + 3];
            }
        } else {
            // NV12: o luma como está; o croma intercalado (U, V).
            memcpy(py, q, ny);
            const uint8_t *uv = q + ny;
            for (size_t i = 0; i < nc; i++) { pu[i] = uv[2 * i]; pv[i] = uv[2 * i + 1]; }
        }
        if (!d->decodificado) LOGI("%s: %dx%d, croma %dx%d, sem decodificar", d->cru == 2 ? "YUY2" : "NV12", d->lw, d->lh, d->cw, d->ch);
        d->decodificado = 1;
        atomic_fetch_add(&d->c_us_decod, (unsigned long long)((agora_ns() - t0) / 1000));
        return 0;
    }
    memcpy(d->pkbuf, q, nq);
    // O preenchimento depois do dado tem de ser zero (o quadro anterior pode ter sido maior).
    memset(d->pkbuf + nq, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    d->pk->data = d->pkbuf;
    d->pk->size = (int)nq;
    int r = avcodec_send_packet(d->ctx, d->pk);
    if (r < 0) return falha_decod(d, "send_packet", r, (int)nq);
    r = avcodec_receive_frame(d->ctx, d->fr);
    if (r < 0) return falha_decod(d, "receive_frame", r, (int)nq);
    if (d->formato == FORMATO_MJPEG) {
        if (copia_mjpeg(d) < 0) return -2;
        d->decodificado = 1;
        atomic_fetch_add(&d->c_us_decod, (unsigned long long)((agora_ns() - t0) / 1000));
        return 0;
    }
    if (d->fr->format != AV_PIX_FMT_YUV411P || d->fr->width != LARG || d->fr->height != ALT)
        return falha_decod(d, "quadro DV fora de 720x480 4:1:1", d->fr->width, d->fr->height);
    int64_t t1 = agora_ns();
    desentrelacar(d, d->fr->data, d->fr->linesize);
    int64_t t2 = agora_ns();
    // Sem pacote VSC: o último visto; sem nenhum ainda, 16:9 (o que o Kotlin também supõe).
    int a = disp_169(q);
    if (a < 0) a = d->disp169 < 0 ? 1 : d->disp169;
    if (d->disp169 >= 0 && a != d->disp169) atomic_fetch_add(&d->c_trocas_aspecto, 1);
    d->disp169 = a;
    d->decodificado = 1;
    atomic_fetch_add(&d->c_us_decod, (unsigned long long)((t1 - t0) / 1000));
    atomic_fetch_add(&d->c_us_des, (unsigned long long)((t2 - t1) / 1000));
    return 0;
}

// Aspecto do último quadro decodificado: 1 = 16:9, 0 = 4:3 (o MJPEG responde 0; o aspecto de fato
// dele está em `geometria`).
JNIEXPORT jint JNICALL FN(aspectoDecodificado)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    return ((Dv *)(intptr_t)h)->disp169 == 0 ? 0 : 1;
}

// O aspecto a encaixar: na DV, 16:9 ou 4:3 pelo DISP; no MJPEG, o do quadro (pixel quadrado).
static void aspecto_de(const Dv *d, int *an, int *ad) {
    if (d->formato == FORMATO_MJPEG) { *an = d->an; *ad = d->ad; return; }
    *an = d->disp169 ? 16 : 4;
    *ad = d->disp169 ? 9 : 3;
}

// [luma_w, luma_h, croma_w, croma_h, aspecto_n, aspecto_d, croma_centrado, formato] dos planos de
// `des` depois do último `decodificar` (a prévia sobe as texturas por aqui).
JNIEXPORT jintArray JNICALL FN(geometria)(JNIEnv *env, jclass cls, jlong h) {
    (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    int an, ad;
    aspecto_de(d, &an, &ad);
    jint v[8] = {d->lw, d->lh, d->cw, d->ch, an, ad, d->centrado, d->formato};
    jintArray a = (*env)->NewIntArray(env, 8);
    if (a) (*env)->SetIntArrayRegion(env, a, 0, 8, v);
    return a;
}

// Os três planos de `des` como ByteBuffer direto sobre a memória do C (sem cópia), para o upload
// na GPU, do tamanho da geometria de agora (se a subamostragem do MJPEG mudar, a prévia pede de
// novo). Vivem até `fechar`; só a thread consumidora os lê, entre `decodificar`s.
JNIEXPORT jobjectArray JNICALL FN(planos)(JNIEnv *env, jclass cls, jlong h) {
    (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    jclass bb = (*env)->FindClass(env, "java/nio/ByteBuffer");
    jobjectArray a = (*env)->NewObjectArray(env, 3, bb, NULL);
    for (int p = 0; p < 3; p++) {
        jlong n = p ? (jlong)d->cw * d->ch : (jlong)d->lw * d->lh;
        jobject b = (*env)->NewDirectByteBuffer(env, d->des[p], n);
        (*env)->SetObjectArrayElement(env, a, p, b);
    }
    return a;
}

// Escreve o último quadro decodificado no destino W x H (I420 ou NV12/NV21), encaixado com
// faixas pretas quando o aspecto do quadro não é o do destino (como regras_da_camera::encaixe do
// Windows). 0 = ok, -1 = nada decodificado, -3 = destino inválido.
JNIEXPORT jint JNICALL FN(escrever)(JNIEnv *env, jclass cls, jlong h, jobject by, jint ys,
                                    jobject bu, jobject bv, jint cs, jint cps, jint W, jint H) {
    (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    if (!d->decodificado) return -1;
    uint8_t *Y = (*env)->GetDirectBufferAddress(env, by);
    uint8_t *U = (*env)->GetDirectBufferAddress(env, bu);
    uint8_t *V = (*env)->GetDirectBufferAddress(env, bv);
    jlong cy = (*env)->GetDirectBufferCapacity(env, by);
    jlong cu = (*env)->GetDirectBufferCapacity(env, bu);
    jlong cv = (*env)->GetDirectBufferCapacity(env, bv);
    if (!Y || !U || !V || W < 2 || H < 2 || (W & 1) || (H & 1) || ys < W || (cps != 1 && cps != 2) ||
        cy < (jlong)ys * (H - 1) + W || cu < (jlong)cs * (H / 2 - 1) + (jlong)(W / 2 - 1) * cps + 1 ||
        cv < (jlong)cs * (H / 2 - 1) + (jlong)(W / 2 - 1) * cps + 1)
        return -3;
    int64_t t0 = agora_ns();
    // O aspecto exato (16:9 ou 4:3; no MJPEG o do quadro), e não 854:480: 1280x720 com 854:480
    // dava 718 linhas e duas pretas embaixo.
    int an, ad;
    aspecto_de(d, &an, &ad);
    int rw, rh;
    if ((long)W * ad <= (long)H * an) { rw = W; rh = (int)((long)ad * W / an); }
    else { rh = H; rw = (int)((long)an * H / ad); }
    rw &= ~1; rh &= ~1;
    if (rw < 2) rw = 2;
    if (rh < 2) rh = 2;
    int rx = ((W - rw) / 2) & ~1, ry = ((H - rh) / 2) & ~1;
    para_destino(d, Y, ys, U, V, cs, cps, W, H, rx, ry, rw, rh);
    atomic_fetch_add(&d->c_us_conv, (unsigned long long)((agora_ns() - t0) / 1000));
    atomic_fetch_add(&d->c_entregues, 1);
    return 0;
}

// O som do quadro que está com a consumidora (o primeiro par de canais), em s16 estéreo
// intercalado no ByteBuffer direto `saida` (8000 bytes). Devolve as amostras por canal (0 sem
// som) e escreve a taxa em taxa[0].
JNIEXPORT jint JNICALL FN(som)(JNIEnv *env, jclass cls, jlong h, jobject saida, jintArray taxa) {
    (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    if (d->atual < 0) return -1;
    if (d->formato != FORMATO_DV) return 0;  // o som da placa é outra interface (a P2)
    int16_t *out = (*env)->GetDirectBufferAddress(env, saida);
    if (!out || (*env)->GetDirectBufferCapacity(env, saida) < 8000) return -3;
    if (!d->som) d->som = som_novo();
    if (!d->som) return -4;
    int t = 0;
    int n = som_do_quadro(d->som, d->buf[d->atual], out, &t);
    jint tj = t;
    (*env)->SetIntArrayRegion(env, taxa, 0, 1, &tj);
    return n;
}

// [0 íntegros, 1 tortos, 2 caídos_na_fila, 3 erros_de_pacote, 4 err_bit, 5 entregues,
//  6 falhas_de_decodificação, 7 trocas_de_aspecto, 8 µs_decodificar, 9 µs_desentrelaçar,
//  10 µs_converter, 11 ruins_entregues, 12 reenvio_recusado (URBs distintas que ficaram
//  pendentes), e os motivos dos tortos do MJPEG: 13 sem_soi, 14 sem_eoi, 15 grande_demais,
//  16 descartados_ruins (ERR ou pacote com erro), 17 dois_em_um (quadros UVC com dois JPEG,
//  partidos), 18 so_pela_borda; 19 URBs, 20 pacotes por URB (fixos); 21 tentativas_recusadas
//  (cada envio recusado), 22 lixo_depois_do_eoi (não é torto), 23 cabecalho_invalido, 24 envios
//  (SUBMITURB aceitos: o custo das URBs curtas da placa, ~2700/s)] (acumulados)
#define N_CONTADORES 25
JNIEXPORT jlongArray JNICALL FN(contadores)(JNIEnv *env, jclass cls, jlong h) {
    (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    const Remontagem *r = &d->rm;
    jlong v[N_CONTADORES] = {
        (jlong)atomic_load(&r->integros), (jlong)atomic_load(&r->tortos),
        (jlong)atomic_load(&d->c_caidos_fila), (jlong)atomic_load(&d->c_erros_pacote),
        (jlong)atomic_load(&r->err_bit), (jlong)atomic_load(&d->c_entregues),
        (jlong)atomic_load(&d->c_decod_falhas), (jlong)atomic_load(&d->c_trocas_aspecto),
        (jlong)atomic_load(&d->c_us_decod), (jlong)atomic_load(&d->c_us_des),
        (jlong)atomic_load(&d->c_us_conv), (jlong)atomic_load(&r->ruins_entregues),
        (jlong)atomic_load(&d->c_reenvio_recusado),
        (jlong)atomic_load(&r->sem_soi), (jlong)atomic_load(&r->sem_eoi),
        (jlong)atomic_load(&r->grande_demais), (jlong)atomic_load(&r->descartados_ruins),
        (jlong)atomic_load(&r->dois_em_um), (jlong)atomic_load(&r->so_pela_borda),
        d->n_urbs, d->n_pacotes,
        (jlong)atomic_load(&d->c_tentativas_recusadas), (jlong)atomic_load(&r->lixo_depois_do_eoi),
        (jlong)atomic_load(&r->cabecalho_invalido), (jlong)atomic_load(&d->c_envios),
    };
    jlongArray a = (*env)->NewLongArray(env, N_CONTADORES);
    if (a) (*env)->SetLongArrayRegion(env, a, 0, N_CONTADORES, v);
    return a;
}

// Para a thread de USB (descarta e recolhe as URBs) e libera tudo. O fd é do Kotlin, que o fecha
// depois (UsbDeviceConnection.close).
JNIEXPORT void JNICALL FN(fechar)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    if (!d) return;
    atomic_store(&d->parar, 1);
    if (d->thread_viva) pthread_join(d->thread, NULL);
    int vazou = 0;
    for (int i = 0; i < MAX_URBS; i++) {
        if (!d->urbs[i]) continue;
        if (d->no_ar[i]) { vazou = 1; continue; }  // o kernel ainda pode escrever nela
        free(d->urbs[i]->buffer);
        free(d->urbs[i]);
    }
    for (int i = 0; i < SOM_URBS; i++) {
        if (!d->som_urbs[i]) continue;
        if (d->som_no_ar[i]) { vazou = 1; continue; }
        free(d->som_urbs[i]->buffer);
        free(d->som_urbs[i]);
    }
    if (d->som_ligado)
        LOGI("som da placa pelo USB: fechado; pacotes=%llu com_erro=%llu amostras_caidas=%llu; "
             "intervalo entre URBs: <4ms=%llu 4-12=%llu 12-20=%llu 20-40=%llu >=40=%llu",
             (unsigned long long)atomic_load(&d->c_som_pacotes), (unsigned long long)atomic_load(&d->c_som_erros),
             (unsigned long long)atomic_load(&d->c_som_caidas), d->som_intervalos[0], d->som_intervalos[1],
             d->som_intervalos[2], d->som_intervalos[3], d->som_intervalos[4]);
    free(d->som_anel);
    pthread_mutex_destroy(&d->som_mu);
    pthread_cond_destroy(&d->som_cv);
    if (vazou) LOGW("URBs no ar ao fechar: vazadas de propósito");
    if (d->ctx) avcodec_free_context(&d->ctx);
    if (d->fr) av_frame_free(&d->fr);
    if (d->pk) { d->pk->data = NULL; d->pk->size = 0; av_packet_free(&d->pk); }
    av_free(d->pkbuf);
    remonta_libera(&d->rm);
    free(d->arquivo);
    for (int i = 0; i < N_BUF; i++) free(d->buf[i]);
    for (int p = 0; p < 3; p++) { free(d->ant[p]); free(d->des[p]); }
    free(d->mascara);
    som_libera(d->som);
    somg_libera(d->somg);
    free(d->hq_x0); free(d->hq_wx); free(d->hq_y0); free(d->hq_wy); free(d->hq_tmp);
    escala_libera(&d->ey_x); escala_libera(&d->ey_y); escala_libera(&d->ec_x); escala_libera(&d->ec_y);
    pthread_mutex_destroy(&d->mu);
    pthread_cond_destroy(&d->cv);
    free(d);
}

// ------------------------------------------------------------------------------ o som da placa

// Pede à thread do USB que ligue o som: o endpoint isócrono da interface de som (já reivindicada e
// na alternativa certa pelo Kotlin), 48 kHz mono s16. 0, ou -1 sem memória / fora da placa.
// `passo`: amostras s16 da placa por amostra de saída (canais x taxa/48000): 1 (48 kHz mono), 2 (48 kHz
// estéreo, ou 96 kHz mono), 4 (96 kHz estéreo).
JNIEXPORT jint JNICALL FN(ligarSom)(JNIEnv *env, jclass cls, jlong h, jint endpoint, jint psize, jint passo) {
    (void)env; (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    if (!d || d->fd < 0 || psize < 2 || psize > 1024 || passo < 1 || passo > 4 || atomic_load(&d->som_pedido)) return -1;
    d->som_passo = passo;
    d->som_anel = calloc(SOM_ANEL, sizeof(int16_t));
    if (!d->som_anel) return -1;
    d->som_ep = endpoint; d->som_psize = psize;
    atomic_store(&d->som_pedido, 1);
    return 0;
}

// Destrava a leitora do som (o Kotlin fecha a fonte: ninguém pode estar dentro de `lerSom`).
JNIEXPORT void JNICALL FN(pararSom)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    if (d) som_acaba(d);
}

// Espera até `timeout_ms` por `amostras` amostras e as copia (s16 mono) no ByteBuffer direto.
// Devolve `amostras`, 0 no prazo, -1 se o som acabou. instante[0]: a hora da primeira amostra
// entregue (µs de CLOCK_MONOTONIC, o relógio do vídeo), pela chegada do último pacote.
JNIEXPORT jint JNICALL FN(lerSom)(JNIEnv *env, jclass cls, jlong h, jobject saida, jint amostras,
                                  jint timeout_ms, jlongArray instante) {
    (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    int16_t *out = (*env)->GetDirectBufferAddress(env, saida);
    if (!d || !d->som_anel || !out || amostras <= 0 || amostras > SOM_ANEL / 2 ||
        (*env)->GetDirectBufferCapacity(env, saida) < (jlong)amostras * 2) return -1;
    struct timespec lim;
    clock_gettime(CLOCK_MONOTONIC, &lim);
    lim.tv_sec += timeout_ms / 1000;
    lim.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (lim.tv_nsec >= 1000000000L) { lim.tv_sec++; lim.tv_nsec -= 1000000000L; }
    int r = 0;
    jlong us = 0;
    pthread_mutex_lock(&d->som_mu);
    while (!d->som_fim && d->som_w - d->som_r < (uint64_t)amostras) {
        if (pthread_cond_timedwait(&d->som_cv, &d->som_mu, &lim) != 0) break;
    }
    if (d->som_w - d->som_r >= (uint64_t)amostras) {
        us = (jlong)((d->som_ts_w - (int64_t)(d->som_w - d->som_r) * 1000000000LL / SOM_TAXA) / 1000);
        for (int j = 0; j < amostras; j++) out[j] = d->som_anel[(d->som_r + (uint64_t)j) % SOM_ANEL];
        d->som_r += (uint64_t)amostras;
        r = amostras;
    } else if (d->som_fim) {
        r = -1;
    }
    pthread_mutex_unlock(&d->som_mu);
    if (r > 0) (*env)->SetLongArrayRegion(env, instante, 0, 1, &us);
    return r;
}

// ------------------------------------------------------------------------------ gravação
// Liga (1) ou desliga (0) o modo de gravação da fila (ver `gravacao` no Dv). Zera a âncora do som.
JNIEXPORT void JNICALL FN(modoGravacao)(JNIEnv *env, jclass cls, jlong h, jboolean ligado) {
    (void)env; (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    atomic_store(&d->gravacao, ligado ? 1 : 0);
    pthread_mutex_lock(&d->mu);
    somg_libera(d->somg);
    d->somg = ligado ? somg_novo() : NULL;
    pthread_mutex_unlock(&d->mu);
}

// Quantos quadros estão na fila agora (a gravação mostra a folga).
JNIEXPORT jint JNICALL FN(naFila)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    int n = 0;
    pthread_mutex_lock(&d->mu);
    for (int i = 0; i < d->n_buf; i++) n += d->estado[i] == NA_FILA;
    pthread_mutex_unlock(&d->mu);
    return n;
}

// O som do quadro atual para o quadro n da gravação: 48 kHz estéreo, ancorado (ver somg_quadro), em
// `saida` (ByteBuffer direto de 32000 bytes). Devolve as amostras; corrigidas[0] acumula.
JNIEXPORT jint JNICALL FN(somGravacao)(JNIEnv *env, jclass cls, jlong h, jlong n, jobject saida,
                                       jlongArray corrigidas) {
    (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    if (d->atual < 0 || !d->somg || d->formato != FORMATO_DV) return -1;
    int16_t *out = (*env)->GetDirectBufferAddress(env, saida);
    if (!out || (*env)->GetDirectBufferCapacity(env, saida) < 32000) return -3;
    if (!d->som) d->som = som_novo();
    int16_t pcm[4000];
    int taxa = 0, k = d->som ? som_do_quadro(d->som, d->buf[d->atual], pcm, &taxa) : 0;
    if (k < 0) k = 0;
    int64_t c = 0;
    int w = somg_quadro(d->somg, n, pcm, k, taxa, out, &c);
    if (c) {
        jlong antes = 0;
        (*env)->GetLongArrayRegion(env, corrigidas, 0, 1, &antes);
        antes += c;
        (*env)->SetLongArrayRegion(env, corrigidas, 0, 1, &antes);
    }
    return w;
}

// Catmull-Rom (a = -0.5) em ponto fixo, 1/1024.
static void pesos_cr(double f, int w[4]) {
    double f2 = f * f, f3 = f2 * f;
    double a = -0.5 * f3 + f2 - 0.5 * f, b = 1.5 * f3 - 2.5 * f2 + 1.0;
    double c = -1.5 * f3 + 2.0 * f2 + 0.5 * f;
    w[0] = (int)lrint(a * 1024); w[1] = (int)lrint(b * 1024); w[2] = (int)lrint(c * 1024);
    w[3] = 1024 - w[0] - w[1] - w[2];
}

static inline uint8_t sat8(int v) { return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }

// O luma em Catmull-Rom separável (720x480 -> rw x rh), no retângulo (rx, ry) do destino; o croma
// é o bilinear de `para_destino`. Para a gravação 1280x720: 480 -> 720 é ampliação, e o bilinear
// amolece. O super-branco (Y > 235) passa como veio.
static void para_destino_hq(Dv *d, uint8_t *Y, int ys, uint8_t *U, uint8_t *V, int cs, int cps,
                            int W, int H, int rx, int ry, int rw, int rh) {
    // croma e as faixas pelo caminho de sempre (bilinear); o luma do retângulo é o daqui
    d->pular_luma = 1;
    para_destino(d, Y, ys, U, V, cs, cps, W, H, rx, ry, rw, rh);
    d->pular_luma = 0;
    if (d->hq_w != rw || d->hq_h != rh) {
        free(d->hq_x0); free(d->hq_wx); free(d->hq_y0); free(d->hq_wy); free(d->hq_tmp);
        d->hq_x0 = malloc(sizeof(int) * rw); d->hq_wx = malloc(sizeof(int) * 4 * rw);
        d->hq_y0 = malloc(sizeof(int) * rh); d->hq_wy = malloc(sizeof(int) * 4 * rh);
        d->hq_tmp = malloc(sizeof(int16_t) * (size_t)rw * ALT);
        for (int i = 0; i < rw; i++) {
            double s = (i + 0.5) * LARG / rw - 0.5;
            int b = (int)floor(s);
            d->hq_x0[i] = b;
            pesos_cr(s - b, d->hq_wx + 4 * i);
        }
        for (int j = 0; j < rh; j++) {
            double s = (j + 0.5) * ALT / rh - 0.5;
            int b = (int)floor(s);
            d->hq_y0[j] = b;
            pesos_cr(s - b, d->hq_wy + 4 * j);
        }
        d->hq_w = rw;
        d->hq_h = rh;
    }
    // horizontal: 480 linhas x rw, em 1/1024
    for (int y = 0; y < ALT; y++) {
        const uint8_t *l = d->des[0] + y * LARG;
        int16_t *t = d->hq_tmp + (size_t)y * rw;
        for (int i = 0; i < rw; i++) {
            int b = d->hq_x0[i];
            const int *w = d->hq_wx + 4 * i;
            int acc = 0;
            for (int k = 0; k < 4; k++) {
                int x = b - 1 + k;
                x = x < 0 ? 0 : x >= LARG ? LARG - 1 : x;
                acc += w[k] * l[x];
            }
            // guarda em 1/8 de código (cabe em int16 com a sobra dos lóbulos)
            t[i] = (int16_t)((acc + 64) >> 7);
        }
    }
    // vertical
    for (int j = 0; j < rh; j++) {
        uint8_t *o = Y + (size_t)(ry + j) * ys + rx;
        int b = d->hq_y0[j];
        const int *w = d->hq_wy + 4 * j;
        const int16_t *ls[4];
        for (int k = 0; k < 4; k++) {
            int y = b - 1 + k;
            y = y < 0 ? 0 : y >= ALT ? ALT - 1 : y;
            ls[k] = d->hq_tmp + (size_t)y * rw;
        }
        for (int i = 0; i < rw; i++) {
            int acc = w[0] * ls[0][i] + w[1] * ls[1][i] + w[2] * ls[2][i] + w[3] * ls[3][i];
            o[i] = sat8((acc + 4096) >> 13);  // 1024 x 8
        }
    }
}

// Como `escrever`, com o luma em Catmull-Rom: o caminho da gravação (1280x720). Só DV (os planos
// 720x480 são fixos aqui; gravar a placa é a P4): -4 no MJPEG.
JNIEXPORT jint JNICALL FN(escreverHq)(JNIEnv *env, jclass cls, jlong h, jobject by, jint ys,
                                      jobject bu, jobject bv, jint cs, jint cps, jint W, jint H) {
    (void)cls;
    Dv *d = (Dv *)(intptr_t)h;
    if (d->formato != FORMATO_DV) return -4;
    if (!d->decodificado) return -1;
    uint8_t *Y = (*env)->GetDirectBufferAddress(env, by);
    uint8_t *U = (*env)->GetDirectBufferAddress(env, bu);
    uint8_t *V = (*env)->GetDirectBufferAddress(env, bv);
    jlong cy = (*env)->GetDirectBufferCapacity(env, by);
    jlong cu = (*env)->GetDirectBufferCapacity(env, bu);
    jlong cv = (*env)->GetDirectBufferCapacity(env, bv);
    if (!Y || !U || !V || W < 2 || H < 2 || (W & 1) || (H & 1) || ys < W || (cps != 1 && cps != 2) ||
        cy < (jlong)ys * (H - 1) + W || cu < (jlong)cs * (H / 2 - 1) + (jlong)(W / 2 - 1) * cps + 1 ||
        cv < (jlong)cs * (H / 2 - 1) + (jlong)(W / 2 - 1) * cps + 1)
        return -3;
    int64_t t0 = agora_ns();
    // O aspecto exato (16:9 ou 4:3), e não 854:480: 1280x720 com 854:480 dava 718 linhas e duas
    // pretas embaixo.
    int an = d->disp169 ? 16 : 4, ad = d->disp169 ? 9 : 3;
    int rw, rh;
    if ((long)W * ad <= (long)H * an) { rw = W; rh = (int)((long)ad * W / an); }
    else { rh = H; rw = (int)((long)an * H / ad); }
    rw &= ~1; rh &= ~1;
    if (rw < 2) rw = 2;
    if (rh < 2) rh = 2;
    int rx = ((W - rw) / 2) & ~1, ry = ((H - rh) / 2) & ~1;
    para_destino_hq(d, Y, ys, U, V, cs, cps, W, H, rx, ry, rw, rh);
    atomic_fetch_add(&d->c_us_conv, (unsigned long long)((agora_ns() - t0) / 1000));
    atomic_fetch_add(&d->c_entregues, 1);
    return 0;
}

// fsync do arquivo da gravação (a cada ~10 s: numa queda de energia, o fim do arquivo não some).
JNIEXPORT jint JNICALL FN(sincronizar)(JNIEnv *env, jclass cls, jint fd) {
    (void)env; (void)cls;
    return fsync(fd) == 0 ? 0 : -errno;
}

// Remonta o MP4 fragmentado de uma gravação interrompida em MP4 comum (fd para fd).
// Devolve os pacotes copiados (negativo: erro); com a leitura parada num erro (arquivo cortado),
// soma 1<<40 para o Kotlin saber que é parcial.
JNIEXPORT jlong JNICALL FN(mp4Remontar)(JNIEnv *env, jclass cls, jint entrada, jint saida) {
    (void)env; (void)cls;
    char erro[160] = "";
    int parcial = 0;
    int64_t r = mp4_remonta(entrada, saida, &parcial, erro, sizeof erro);
    if (r < 0) { LOGW("mp4: remontar falhou: %s", erro); return r; }
    LOGI("mp4: remontado, %lld pacotes%s", (long long)r, parcial ? " (parcial: a leitura parou num erro)" : "");
    return parcial ? r + (1LL << 40) : r;
}

// ------------------------------------------------------------------------------ MP4 (gravação)
// O muxer `mp4` da libavformat com movflags=hybrid_fragmented, sobre o fd do MediaStore (ver
// midia.c). Uma thread só (a do gravador) chama estas quatro.
JNIEXPORT jlong JNICALL FN(mp4Abrir)(JNIEnv *env, jclass cls, jint fd, jint w, jint h,
                                     jbyteArray sps_pps, jint taxa, jint canais, jint bitrate,
                                     jbyteArray asc, jint atraso) {
    (void)cls;
    jsize ns = sps_pps ? (*env)->GetArrayLength(env, sps_pps) : 0;
    jsize na = asc ? (*env)->GetArrayLength(env, asc) : 0;
    jbyte *ps = ns ? (*env)->GetByteArrayElements(env, sps_pps, NULL) : NULL;
    jbyte *pa = na ? (*env)->GetByteArrayElements(env, asc, NULL) : NULL;
    char erro[160] = "";
    Mp4 *m = mp4_abre(fd, w, h, (const uint8_t *)ps, ns, taxa, canais, bitrate,
                      (const uint8_t *)pa, na, atraso, erro, sizeof erro);
    if (ps) (*env)->ReleaseByteArrayElements(env, sps_pps, ps, JNI_ABORT);
    if (pa) (*env)->ReleaseByteArrayElements(env, asc, pa, JNI_ABORT);
    if (!m) LOGW("mp4: não abriu: %s", erro);
    else LOGI("mp4: aberto %dx%d, som %d Hz x %d, hybrid_fragmented", w, h, taxa, canais);
    return (jlong)(intptr_t)m;
}

// A câmera da tela R5 (midia.h, `mp4_abre_camera`): o vídeo em 1/90000 s com a duração de cada
// quadro, e a cor que o codificador declarou.
JNIEXPORT jlong JNICALL FN(mp4AbrirCamera)(JNIEnv *env, jclass cls, jint fd, jint w, jint h,
                                           jbyteArray sps_pps, jint taxa, jint canais, jint bitrate,
                                           jbyteArray asc, jint padrao, jint faixa, jint transferencia) {
    (void)cls;
    jsize ns = sps_pps ? (*env)->GetArrayLength(env, sps_pps) : 0;
    jsize na = asc ? (*env)->GetArrayLength(env, asc) : 0;
    jbyte *ps = ns ? (*env)->GetByteArrayElements(env, sps_pps, NULL) : NULL;
    jbyte *pa = na ? (*env)->GetByteArrayElements(env, asc, NULL) : NULL;
    char erro[160] = "";
    Mp4 *m = mp4_abre_camera(fd, w, h, (const uint8_t *)ps, ns, taxa, canais, bitrate,
                             (const uint8_t *)pa, na, padrao, faixa, transferencia, erro, sizeof erro);
    if (ps) (*env)->ReleaseByteArrayElements(env, sps_pps, ps, JNI_ABORT);
    if (pa) (*env)->ReleaseByteArrayElements(env, asc, pa, JNI_ABORT);
    if (!m) LOGW("mp4 (câmera): não abriu: %s", erro);
    else LOGI("mp4 (câmera): aberto %dx%d, vídeo em 1/90000 com duração por quadro, som %d Hz x %d, "
              "cor %d/%d/%d, hybrid_fragmented", w, h, taxa, canais, padrao, faixa, transferencia);
    return (jlong)(intptr_t)m;
}

JNIEXPORT jint JNICALL FN(mp4VideoComDuracao)(JNIEnv *env, jclass cls, jlong m, jobject buf, jint off,
                                              jint n, jlong pts, jlong duracao, jboolean chave) {
    (void)cls;
    uint8_t *p = (*env)->GetDirectBufferAddress(env, buf);
    if (!p || off < 0 || n <= 0 || (*env)->GetDirectBufferCapacity(env, buf) < (jlong)off + n) return -22;
    return mp4_video_dur((Mp4 *)(intptr_t)m, p + off, n, pts, duracao, chave);
}

JNIEXPORT jint JNICALL FN(mp4Video)(JNIEnv *env, jclass cls, jlong m, jobject buf, jint off,
                                    jint n, jlong pts, jboolean chave) {
    (void)cls;
    uint8_t *p = (*env)->GetDirectBufferAddress(env, buf);
    if (!p || off < 0 || n <= 0 || (*env)->GetDirectBufferCapacity(env, buf) < (jlong)off + n) return -22;
    return mp4_video((Mp4 *)(intptr_t)m, p + off, n, pts, chave);
}

JNIEXPORT jint JNICALL FN(mp4Som)(JNIEnv *env, jclass cls, jlong m, jobject buf, jint off, jint n,
                                  jlong pts, jint duracao) {
    (void)cls;
    uint8_t *p = (*env)->GetDirectBufferAddress(env, buf);
    if (!p || off < 0 || n <= 0 || (*env)->GetDirectBufferCapacity(env, buf) < (jlong)off + n) return -22;
    return mp4_som((Mp4 *)(intptr_t)m, p + off, n, pts, duracao);
}

JNIEXPORT jint JNICALL FN(mp4Fechar)(JNIEnv *env, jclass cls, jlong m) {
    (void)env; (void)cls;
    int r = mp4_fecha((Mp4 *)(intptr_t)m);
    if (r < 0) LOGW("mp4: trailer falhou: %d", r);
    return r;
}
