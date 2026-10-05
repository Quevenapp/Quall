// A referência em C do adapt2 sobre quadros yuv411p 720x480 crus: o `desentrelacar` do
// `dv-bancada.c` (frente do S24, `tools/espiao-dv-s24/bancada-dv/`), incluído SEM mudança, no modo
// ADAPT2 com -J 3 -P 3 -R 0 e limiar 10 — o mesmo que o dv-bancada roda com -Y e que foi medido.
// O caminho do .c vem de -DDV_BANCADA_C="..." (ver compara.sh).
//
//   ref-planar <entrada.yuv411p> <saida.yuv411p>
#define main main_da_bancada
#include DV_BANCADA_C
#undef main

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    FILE *fe = fopen(argv[1], "rb"), *fs = fopen(argv[2], "wb");
    if (!fe || !fs) return 1;
    const int T = LARG * ALT + 2 * CLARG * ALT;
    uint8_t *q = malloc(T), *a = malloc(T), *o = malloc(T), *m = malloc(LARG * ALT);
    int tem = 0;
    ContaDes cd = {0, 0};
    g_limiar_pente = 3;
    g_raio = 0;
    g_janela = 3;
    while (fread(q, 1, T, fe) == (size_t)T) {
        uint8_t *const in[3] = {q, q + LARG * ALT, q + LARG * ALT + CLARG * ALT};
        const int is[3] = {LARG, CLARG, CLARG};
        uint8_t *const an[3] = {a, a + LARG * ALT, a + LARG * ALT + CLARG * ALT};
        uint8_t *out[3] = {o, o + LARG * ALT, o + LARG * ALT + CLARG * ALT};
        desentrelacar(ADAPT2, 10, in, is, tem ? an : NULL, out, m, &cd);
        fwrite(o, 1, T, fs);
        memcpy(a, q, T);
        tem = 1;
    }
    fclose(fs);
    fclose(fe);
    return 0;
}
