// Teste de mesa do MP4 da gravação da tela R5 (fase 3), no Mac, com a libavformat do Homebrew:
// o mesmo `midia.c` do app (`mp4_abre_camera` / `mp4_video_dur` / `mp4_som`), alimentado por um
// H.264 sintético (Annex-B, sem B, com AUD) e um AAC ADTS, com **fps variável** e um **buraco**,
// para conferir com `ffprobe` (tools/sonda-r5/fase3-ffprobe.py) que o arquivo leva os tempos que o
// gravador passa — e que o fragmentado de um processo morto se remonta.
//
//   mp4-camera-mesa entrada.h264 entrada.aac saida.mp4 [--morrer-em N]
//   mp4-camera-mesa --remontar morto.mp4 remontado.mp4     (o `mp4_remonta` da volta ao app)
//
// --morrer-em N: sai com _exit(0) depois de N quadros de vídeo, sem trailer (o processo morto).
// O padrão dos intervalos (em 1/90000 s) se repete: 3000 3000 3600 2700 3000 ... e, a cada 90
// quadros, um buraco de 12000 (133 ms). A duração de cada quadro é a distância até o próximo, como no
// GravadorDaCamera; o último leva a do anterior.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../../apps/android/app/src/main/cpp/dv/midia.h"

static uint8_t *ler(const char *c, long *n) {
    FILE *f = fopen(c, "rb");
    if (!f) { perror(c); exit(1); }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)*n);
    if (fread(b, 1, (size_t)*n, f) != (size_t)*n) { perror("fread"); exit(1); }
    fclose(f);
    return b;
}

// O próximo código de início (00 00 01) a partir de i; devolve a posição do primeiro byte do NAL.
static long proximo_nal(const uint8_t *b, long n, long i, long *inicio_do_codigo) {
    for (; i + 3 <= n; i++) {
        if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
            *inicio_do_codigo = (i > 0 && b[i - 1] == 0) ? i - 1 : i;
            return i + 3;
        }
    }
    return -1;
}

typedef struct { uint8_t *d; int n; int chave; } Quadro;

int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "--remontar")) {
        int e = open(argv[2], O_RDONLY), o = open(argv[3], O_RDWR | O_CREAT | O_TRUNC, 0644);
        char erro[160] = "";
        int parcial = 0;
        int64_t r = mp4_remonta(e, o, &parcial, erro, sizeof erro);
        fprintf(stderr, "mesa: remontado: %lld pacotes%s%s\n", (long long)r, parcial ? " (parcial)" : "", r < 0 ? erro : "");
        return r < 0;
    }
    if (argc < 4) { fprintf(stderr, "uso: mp4-camera-mesa entrada.h264 entrada.aac saida.mp4 [--morrer-em N]\n"); return 2; }
    int morrer = argc >= 6 && !strcmp(argv[4], "--morrer-em") ? atoi(argv[5]) : -1;
    long nh, na;
    uint8_t *h = ler(argv[1], &nh), *a = ler(argv[2], &na);

    // Os NALs; SPS e PPS vão para o extradata, AUD separa os quadros.
    uint8_t spspps[512]; int nsp = 0;
    Quadro *q = calloc(20000, sizeof(Quadro)); int nq = 0;
    uint8_t *atual = malloc(4 << 20); int natual = 0, chave = 0, tem = 0;
    long cod, i = proximo_nal(h, nh, 0, &cod);
    while (i >= 0) {
        long cod2, j = proximo_nal(h, nh, i, &cod2);
        long fim = j >= 0 ? cod2 : nh;
        int tipo = h[i] & 0x1f;
        if (tipo == 9) {  // AUD: fecha o quadro anterior
            if (tem) { q[nq].d = malloc((size_t)natual); memcpy(q[nq].d, atual, (size_t)natual); q[nq].n = natual; q[nq].chave = chave; nq++; }
            natual = 0; chave = 0; tem = 0;
        } else if (tipo == 7 || tipo == 8) {
            if (nq == 0 && nsp + (fim - i) + 4 < (long)sizeof spspps) {
                memcpy(spspps + nsp, "\0\0\0\1", 4); nsp += 4;
                memcpy(spspps + nsp, h + i, (size_t)(fim - i)); nsp += (int)(fim - i);
            }
        } else {
            memcpy(atual + natual, "\0\0\0\1", 4); natual += 4;
            memcpy(atual + natual, h + i, (size_t)(fim - i)); natual += (int)(fim - i);
            if (tipo == 5) chave = 1;
            tem = 1;
        }
        i = j;
    }
    if (tem) { q[nq].d = atual; q[nq].n = natual; q[nq].chave = chave; nq++; }

    // O AAC: ADTS → o pacote cru e o AudioSpecificConfig.
    int taxas[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000};
    uint8_t asc[2]; int taxa = 0, canais = 0;
    long p = 0; int nquad_som = 0;
    long *pos = malloc(100000 * sizeof(long)); int *tam = malloc(100000 * sizeof(int));
    while (p + 7 <= na && (a[p] == 0xff && (a[p + 1] & 0xf0) == 0xf0)) {
        int prot = !(a[p + 1] & 1);
        int perfil = ((a[p + 2] >> 6) & 3) + 1, isr = (a[p + 2] >> 2) & 0xf;
        int ch = ((a[p + 2] & 1) << 2) | (a[p + 3] >> 6);
        int len = ((a[p + 3] & 3) << 11) | (a[p + 4] << 3) | (a[p + 5] >> 5);
        int cab = prot ? 9 : 7;
        if (!taxa) {
            taxa = taxas[isr]; canais = ch;
            asc[0] = (uint8_t)((perfil << 3) | (isr >> 1));
            asc[1] = (uint8_t)(((isr & 1) << 7) | (ch << 3));
        }
        pos[nquad_som] = p + cab; tam[nquad_som] = len - cab; nquad_som++;
        p += len;
    }
    fprintf(stderr, "mesa: %d quadros de vídeo (sps+pps %d B), %d pacotes AAC a %d Hz x %d\n", nq, nsp, nquad_som, taxa, canais);

    int fd = open(argv[3], O_RDWR | O_CREAT | O_TRUNC, 0644);
    char erro[160] = "";
    // BT.709 (1), faixa limitada (2), SDR (3): o que o GravadorDaCamera pede.
    Mp4 *m = mp4_abre_camera(fd, 1280, 720, spspps, nsp, taxa, canais, 96000, asc, 2, 1, 2, 3, erro, sizeof erro);
    if (!m) { fprintf(stderr, "mp4_abre_camera: %s\n", erro); return 1; }

    // Os tempos do vídeo: o padrão variável, com um buraco a cada 90 quadros.
    const int padrao[] = {3000, 3000, 3600, 2700, 3000};
    int64_t *pts = malloc((size_t)nq * sizeof(int64_t));
    int64_t t = 0;
    for (int k = 0; k < nq; k++) {
        pts[k] = t;
        t += (k % 90 == 89) ? 12000 : padrao[k % 5];
    }
    int64_t ultima = 0;
    int s = 0;
    for (int k = 0; k < nq; k++) {
        int64_t dur = k + 1 < nq ? pts[k + 1] - pts[k] : ultima;
        ultima = dur;
        // O som até o fim deste quadro, antes dele (intercalado pelo tempo).
        while (s < nquad_som && (int64_t)s * 1024 * 90000 / taxa < pts[k] + dur) {
            int r = mp4_som(m, a + pos[s], tam[s], (int64_t)s * 1024, 1024);
            if (r < 0) { fprintf(stderr, "mp4_som: %d\n", r); return 1; }
            s++;
        }
        int r = mp4_video_dur(m, q[k].d, q[k].n, pts[k], dur, q[k].chave);
        if (r < 0) { fprintf(stderr, "mp4_video_dur: %d\n", r); return 1; }
        if (morrer >= 0 && k + 1 >= morrer) {
            fprintf(stderr, "mesa: morrendo depois de %d quadros, sem trailer\n", k + 1);
            _exit(0);
        }
    }
    int r = mp4_fecha(m);
    close(fd);
    fprintf(stderr, "mesa: fechado (%d); vídeo até %.3f s, som até %.3f s\n", r,
            (double)t / 90000.0, (double)s * 1024 / taxa);
    return r < 0;
}
