// Teste de mesa do som da fita (roda no Mac, com a libavformat do Homebrew):
// - o PCM que `som_do_quadro` (apps/android/app/src/main/cpp/dv/midia.c) tira de cada quadro,
//   gravado em s16le, para comparar bit a bit com `ffmpeg -f dv -i A.dv -map 0:a:0 -f s16le`;
// - o som da gravação (`somg_quadro`: 48 kHz, ancorado no quadro), gravado em s16le 48 kHz, com o
//   desvio da âncora no fim. Com `-s N` os quadros múltiplos de N ficam sem som (a âncora tem de
//   pôr silêncio).
//
//   midia-mesa A.dv cru.s16le gravacao48k.s16le [-s N]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../../apps/android/app/src/main/cpp/dv/midia.h"

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "uso: midia-mesa A.dv cru.s16le gravacao48k.s16le [-s N]\n"); return 2; }
    int sem_som_a_cada = argc >= 6 && !strcmp(argv[4], "-s") ? atoi(argv[5]) : 0;
    FILE *f = fopen(argv[1], "rb"), *o = fopen(argv[2], "wb"), *g48 = fopen(argv[3], "wb");
    if (!f || !o || !g48) { perror("abrir"); return 1; }
    static uint8_t q[120000];
    int16_t pcm[4000], out[16000];
    SomDv *s = som_novo();
    SomGravacao *g = somg_novo();
    long quadros = 0, amostras = 0, sem = 0, escritas = 0;
    int64_t corrigidas = 0;
    int taxa = 0, min = 1 << 30, max = 0;
    for (long n = 0; fread(q, 1, sizeof q, f) == sizeof q; n++) {
        int k = som_do_quadro(s, q, pcm, &taxa);
        if (k <= 0) sem++;
        else {
            fwrite(pcm, 4, (size_t)k, o);
            quadros++;
            amostras += k;
            if (k < min) min = k;
            if (k > max) max = k;
        }
        int usar = (sem_som_a_cada && n % sem_som_a_cada == 0) ? 0 : k;
        int w = somg_quadro(g, n, pcm, usar > 0 ? usar : 0, taxa, out, &corrigidas);
        fwrite(out, 4, (size_t)w, g48);
        escritas += w;
    }
    long total_quadros = quadros + sem;
    som_libera(s);
    somg_libera(g);
    fclose(f);
    fclose(o);
    fclose(g48);
    double alvo = total_quadros * 1601.6;
    printf("quadros com som=%ld sem som=%ld amostras=%ld taxa=%d por quadro min=%d max=%d media=%.2f\n",
           quadros, sem, amostras, taxa, min, max, quadros ? (double)amostras / quadros : 0);
    printf("gravação 48k: %ld amostras, alvo %.1f, desvio %.1f amostras (%.2f ms), corrigidas %lld\n",
           escritas, alvo, escritas - alvo, (escritas - alvo) / 48.0, (long long)corrigidas);
    return 0;
}
