// Teste de mesa da reamostragem e da âncora de `somg_quadro` (midia.c), sem DV: um seno de 1 kHz
// a 32 kHz (e depois a 48 kHz: a troca de taxa no meio da fita), quadro a quadro como a fita
// entrega (1067/1068 amostras a 32 kHz, 1601/1602 a 48 kHz), escrito em s16le 48 kHz estéreo.
//
//   reamostra-mesa saida48k.s16le
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "../../../apps/android/app/src/main/cpp/dv/midia.h"

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    FILE *o = fopen(argv[1], "wb");
    SomGravacao *g = somg_novo();
    int16_t pcm[4000], out[16000];
    int64_t corrigidas = 0, escritas = 0;
    double fase = 0;
    long quadros = 600;  // 20 s: 10 s a 32 kHz e 10 s a 48 kHz
    double acumulado = 0;
    for (long n = 0; n < quadros; n++) {
        int taxa = n < 300 ? 32000 : 48000;
        double por_quadro = taxa * 1001.0 / 30000.0;
        acumulado += por_quadro;
        int k = (int)(acumulado) - (int)(acumulado - por_quadro);
        for (int i = 0; i < k; i++) {
            int16_t v = (int16_t)lrint(16000 * sin(fase));
            pcm[2 * i] = v;
            pcm[2 * i + 1] = v;
            fase += 2 * M_PI * 1000.0 / taxa;
        }
        if (n == 300) acumulado = por_quadro;
        int w = somg_quadro(g, n, pcm, k, taxa, out, &corrigidas);
        fwrite(out, 4, (size_t)w, o);
        escritas += w;
    }
    fclose(o);
    somg_libera(g);
    printf("escritas %lld, alvo %.1f, desvio %.1f amostras, corrigidas %lld\n", (long long)escritas,
           quadros * 1601.6, escritas - quadros * 1601.6, (long long)corrigidas);
    return 0;
}
