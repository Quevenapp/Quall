// A ponte JNI do DVD para MP4 (`dvd.h`) para `com.quall.android.dvd.QuallDvd`. Mora na
// `libqualldv.so` (o FFmpeg é o mesmo da DV), e o Kotlin só chama depois de `QuallDv.disponivel`.
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

#include "dvd.h"
#include "midia.h"

#include <android/log.h>

#define FN(nome) Java_com_quall_android_dvd_QuallDvd_##nome

JNIEXPORT jlong JNICALL FN(abrir)(JNIEnv *env, jclass cls, jintArray faixas) {
    (void)cls;
    if (!faixas) return (jlong)(intptr_t)dvd_novo(NULL, -1);
    jsize n = (*env)->GetArrayLength(env, faixas);
    int ids[DVD_MAX_FAIXAS] = {0};
    if (n > DVD_MAX_FAIXAS) n = DVD_MAX_FAIXAS;
    jint tmp[DVD_MAX_FAIXAS];
    (*env)->GetIntArrayRegion(env, faixas, 0, n, tmp);
    for (int i = 0; i < n; i++) ids[i] = tmp[i];
    return (jlong)(intptr_t)dvd_novo(ids, n);
}

JNIEXPORT jint JNICALL FN(celula)(JNIEnv *env, jclass cls, jlong h, jlong pos, jlong acumulado) {
    (void)env; (void)cls;
    return dvd_celula((Dvd *)(intptr_t)h, pos, acumulado);
}

// `buf` é um ByteBuffer direto; `n` bytes a partir do começo.
JNIEXPORT jint JNICALL FN(empurrar)(JNIEnv *env, jclass cls, jlong h, jobject buf, jint n, jlong pos) {
    (void)cls;
    const uint8_t *p = (*env)->GetDirectBufferAddress(env, buf);
    if (!p || n <= 0 || (*env)->GetDirectBufferCapacity(env, buf) < n) return DVD_ERRO_POSICAO;
    return dvd_empurrar((Dvd *)(intptr_t)h, p, n, pos);
}

JNIEXPORT void JNICALL FN(fimDaEntrada)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    dvd_fim_da_entrada((Dvd *)(intptr_t)h);
}

JNIEXPORT void JNICALL FN(abortar)(JNIEnv *env, jclass cls, jlong h, jint erro) {
    (void)env; (void)cls;
    dvd_abortar((Dvd *)(intptr_t)h, erro);
}

JNIEXPORT jint JNICALL FN(preparar)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    return dvd_preparar((Dvd *)(intptr_t)h);
}

// [largura, altura, fps_num, fps_den, aspecto169, entrelaçado, n_faixas, id_0..id_7, visto_0..visto_7]
JNIEXPORT jintArray JNICALL FN(info)(JNIEnv *env, jclass cls, jlong h) {
    (void)cls;
    DvdInfo i;
    dvd_info((Dvd *)(intptr_t)h, &i);
    jint v[7 + 2 * DVD_MAX_FAIXAS] = {i.largura, i.altura, i.fps_num, i.fps_den, i.aspecto169, i.entrelacado, i.n_faixas};
    for (int k = 0; k < DVD_MAX_FAIXAS; k++) { v[7 + k] = i.faixa_id[k]; v[7 + DVD_MAX_FAIXAS + k] = i.faixa_visto[k]; }
    jintArray a = (*env)->NewIntArray(env, 7 + 2 * DVD_MAX_FAIXAS);
    if (a) (*env)->SetIntArrayRegion(env, a, 0, 7 + 2 * DVD_MAX_FAIXAS, v);
    return a;
}

JNIEXPORT jint JNICALL FN(passo)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    return dvd_passo((Dvd *)(intptr_t)h);
}

// 1 com quadro: tempos[0] = pts, tempos[1] = duração nominal (90 kHz).
JNIEXPORT jint JNICALL FN(quadro)(JNIEnv *env, jclass cls, jlong h, jlongArray tempos) {
    (void)cls;
    int64_t p = 0, d = 0;
    int r = dvd_quadro((Dvd *)(intptr_t)h, &p, &d);
    if (r == 1) {
        jlong v[2] = {p, d};
        (*env)->SetLongArrayRegion(env, tempos, 0, 2, v);
    }
    return r;
}

JNIEXPORT jint JNICALL FN(escrever)(JNIEnv *env, jclass cls, jlong h, jobject by, jint ys, jobject bu,
                                    jobject bv, jint cs, jint cps, jint W, jint H) {
    (void)cls;
    uint8_t *Y = (*env)->GetDirectBufferAddress(env, by);
    uint8_t *U = (*env)->GetDirectBufferAddress(env, bu);
    uint8_t *V = (*env)->GetDirectBufferAddress(env, bv);
    jlong cy = (*env)->GetDirectBufferCapacity(env, by);
    jlong cu = (*env)->GetDirectBufferCapacity(env, bu);
    jlong cv = (*env)->GetDirectBufferCapacity(env, bv);
    if (!Y || !U || !V || W < 16 || H < 16 || (W & 1) || (H & 1) || ys < W || (cps != 1 && cps != 2) ||
        cy < (jlong)ys * (H - 1) + W || cu < (jlong)cs * (H / 2 - 1) + (jlong)(W / 2 - 1) * cps + 1 ||
        cv < (jlong)cs * (H / 2 - 1) + (jlong)(W / 2 - 1) * cps + 1)
        return -3;
    return dvd_escrever((Dvd *)(intptr_t)h, Y, ys, U, V, cs, cps, W, H);
}

// Até `max` amostras estéreo s16 da faixa no ByteBuffer direto `saida` (4 bytes por amostra).
JNIEXPORT jint JNICALL FN(som)(JNIEnv *env, jclass cls, jlong h, jint faixa, jobject saida, jint max) {
    (void)cls;
    int16_t *o = (*env)->GetDirectBufferAddress(env, saida);
    if (!o || max <= 0 || (*env)->GetDirectBufferCapacity(env, saida) < (jlong)max * 4) return -3;
    return dvd_som((Dvd *)(intptr_t)h, faixa, o, max);
}

JNIEXPORT jint JNICALL FN(canalCopiado)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    return dvd_canal_copiado((Dvd *)(intptr_t)h);
}

JNIEXPORT jlongArray JNICALL FN(contadores)(JNIEnv *env, jclass cls, jlong h) {
    (void)cls;
    int64_t v[DVD_N_CONTADORES];
    int n = dvd_contadores((Dvd *)(intptr_t)h, v, DVD_N_CONTADORES);
    jlongArray a = (*env)->NewLongArray(env, n);
    if (a) {
        jlong t[DVD_N_CONTADORES];
        for (int i = 0; i < n; i++) t[i] = v[i];
        (*env)->SetLongArrayRegion(env, a, 0, n, t);
    }
    return a;
}

JNIEXPORT void JNICALL FN(diario)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    dvd_diario((Dvd *)(intptr_t)h);
}

JNIEXPORT void JNICALL FN(fechar)(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    dvd_libera((Dvd *)(intptr_t)h);
}

// ---- o MP4 do DVD (midia.c, `mp4_abre_faixas`) ---------------------------------------------------
// O vídeo e o fechamento são os da câmera (`QuallDv.mp4VideoComDuracao`, `QuallDv.mp4Fechar`).
JNIEXPORT jlong JNICALL FN(mp4AbrirFaixas)(JNIEnv *env, jclass cls, jint fd, jint w, jint h, jbyteArray sps_pps,
                                           jobjectArray ascs, jobjectArray idiomas, jint bitrate, jint padrao,
                                           jint faixa, jint transferencia) {
    (void)cls;
    jsize ns = sps_pps ? (*env)->GetArrayLength(env, sps_pps) : 0;
    jsize n = ascs ? (*env)->GetArrayLength(env, ascs) : 0;
    if (n > MP4_MAX_SOM) n = MP4_MAX_SOM;
    jsize ni = idiomas ? (*env)->GetArrayLength(env, idiomas) : 0;
    jbyte *ps = ns ? (*env)->GetByteArrayElements(env, sps_pps, NULL) : NULL;
    jbyteArray arr[MP4_MAX_SOM] = {0};
    jbyte *pa[MP4_MAX_SOM] = {0};
    const uint8_t *a[MP4_MAX_SOM] = {0};
    int na[MP4_MAX_SOM] = {0};
    jstring js[MP4_MAX_SOM] = {0};
    const char *id[MP4_MAX_SOM] = {0};
    for (int k = 0; k < n; k++) {
        arr[k] = (jbyteArray)(*env)->GetObjectArrayElement(env, ascs, k);
        na[k] = arr[k] ? (*env)->GetArrayLength(env, arr[k]) : 0;
        pa[k] = na[k] ? (*env)->GetByteArrayElements(env, arr[k], NULL) : NULL;
        a[k] = (const uint8_t *)pa[k];
        js[k] = k < ni ? (jstring)(*env)->GetObjectArrayElement(env, idiomas, k) : NULL;
        id[k] = js[k] ? (*env)->GetStringUTFChars(env, js[k], NULL) : NULL;
    }
    char erro[160] = "";
    Mp4 *m = mp4_abre_faixas(fd, w, h, (const uint8_t *)ps, ns, n, a, na, id, 48000, 2, bitrate, padrao, faixa,
                             transferencia, erro, sizeof erro);
    for (int k = 0; k < n; k++) {
        if (pa[k]) (*env)->ReleaseByteArrayElements(env, arr[k], pa[k], JNI_ABORT);
        if (id[k]) (*env)->ReleaseStringUTFChars(env, js[k], id[k]);
        if (arr[k]) (*env)->DeleteLocalRef(env, arr[k]);
        if (js[k]) (*env)->DeleteLocalRef(env, js[k]);
    }
    if (ps) (*env)->ReleaseByteArrayElements(env, sps_pps, ps, JNI_ABORT);
    if (!m) __android_log_print(ANDROID_LOG_WARN, "QuallDvd", "mp4: não abriu: %s", erro);
    else __android_log_print(ANDROID_LOG_INFO, "QuallDvd", "mp4: aberto %dx%d, %d faixa(s) de som, cor %d/%d/%d, "
                             "hybrid_fragmented", w, h, (int)n, padrao, faixa, transferencia);
    return (jlong)(intptr_t)m;
}

JNIEXPORT jint JNICALL FN(mp4SomDaFaixa)(JNIEnv *env, jclass cls, jlong m, jint faixa, jobject buf, jint off,
                                         jint n, jlong pts, jint duracao) {
    (void)cls;
    uint8_t *p = (*env)->GetDirectBufferAddress(env, buf);
    if (!p || off < 0 || n <= 0 || (*env)->GetDirectBufferCapacity(env, buf) < (jlong)off + n) return -22;
    return mp4_som_faixa((Mp4 *)(intptr_t)m, faixa, p + off, n, pts, duracao);
}
