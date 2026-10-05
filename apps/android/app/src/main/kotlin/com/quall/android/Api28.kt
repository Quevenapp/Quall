package com.quall.android

import android.media.MediaCodecInfo
import android.os.Build

// O Android 9 (API 28) das centrais MediaTek que se anunciam "Android 10" (a AC8257 da bancada,
// 01/10): `isHardwareAccelerated` só existe do 29 em diante. Abaixo dele, vale o critério antigo,
// pelos prefixos dos codecs de software do próprio Android.

/**
 * **A captura pelo USB (placa, filmadora DV e DVD) só do Android 11 em diante.** A `libqualldv` e o
 * FFmpeg dela pedem `memfd_create` (libc do 30), e a DV e o DVD usam `ImageWriter.newInstance` com
 * formato e `startForeground` com tipo (29). Abaixo do 11 os ladrilhos somem, em vez de falharem;
 * o resto do app (receber, espelhar, câmera, teleprompter e controle) vale do 9 em diante.
 */
val capturaUsbPossivel: Boolean
    get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

/** Se o codec é de hardware. */
val MediaCodecInfo.aceleradoPorHardware: Boolean
    get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) isHardwareAccelerated
    else !name.startsWith("OMX.google.") && !name.startsWith("c2.android.")

/**
 * O `ImageWriter` em YUV 4:2:0 dos aparelhos sem o `ImageWriter.Builder` (abaixo do 33). O
 * `newInstance` com formato é do 29, e a placa, a DV e o DVD só existem do 30 em diante
 * ([capturaUsbPossivel]): abaixo do 29 isto nunca roda, e se rodar diz o porquê.
 */
fun escritorYuv420(superficie: android.view.Surface, maxImagens: Int): android.media.ImageWriter =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        android.media.ImageWriter.newInstance(superficie, maxImagens, android.graphics.ImageFormat.YUV_420_888)
    } else {
        throw IllegalStateException("captura pelo USB abaixo do Android 10 (ver capturaUsbPossivel)")
    }
