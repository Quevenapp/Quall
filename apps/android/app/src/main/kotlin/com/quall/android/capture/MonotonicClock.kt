package com.quall.android.capture

/**
 * Relógio monotônico em microssegundos, para o campo `timestamp_us` do sidecar.
 *
 * `System.nanoTime()` no Android é `CLOCK_MONOTONIC` — não anda para trás com ajuste de NTP ou
 * fuso, e é o mesmo domínio de relógio que o `presentationTimeUs` que o `BufferQueue` da
 * `VirtualDisplay` carimba nos buffers de entrada do encoder (produzidos por
 * `systemTime(CLOCK_MONOTONIC)` no lado nativo). É por isso que dá para subtrair um do outro em
 * [H264ScreenEncoder] e chamar a diferença de latência de encode: os dois lados do subtração
 * vêm do mesmo relógio.
 */
object MonotonicClock {
    fun micros(): Long = System.nanoTime() / 1000L
}
