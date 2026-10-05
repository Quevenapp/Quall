package com.quall.android.capture

import android.media.MediaFormat
import android.view.Surface
import com.quall.android.EncodePreset
import com.quall.android.dvd.TransmissaoDoDvd

/**
 * Encoder do **DVD transmitido** (`docs/dvd-para-mp4.md` §9, a T1): o mesmo [H264SurfaceEncoder]
 * das câmeras, com a superfície de entrada alimentada pelo `ImageWriter` da [TransmissaoDoDvd], como
 * o da DV ([H264DvEncoder]).
 *
 * O carimbo de cada quadro é a hora (`CLOCK_MONOTONIC`) em que o relógio do vídeo o põe na tela —
 * o carimbo do disco ancorado no primeiro quadro —, e por isso a latência é comparável ao
 * [MonotonicClock]. A cor é BT.601 (525 ou 625 linhas), a do disco.
 */
class H264DvdEncoder(
    private val fonte: TransmissaoDoDvd,
    sink: FrameSink,
    width: Int,
    height: Int,
    bitrateBps: Int,
    gopSeconds: Float,
    refreshIntraQuadros: Int = 0,
    modoDeTaxa: Int = MODO_TAXA_AUTOMATICO,
    chavesDeFornecedor: Map<String, Int> = emptyMap(),
) : H264SurfaceEncoder(
    sink = sink,
    width = width,
    height = height,
    targetFps = fonte.fps,
    bitrateBps = bitrateBps,
    gopSeconds = gopSeconds,
    preset = EncodePreset.CAMERA,
    colecionarQuadros = false,
    refreshIntraQuadros = refreshIntraQuadros,
    modoDeTaxa = modoDeTaxa,
    chavesDeFornecedor = chavesDeFornecedor,
    latenciaComparavel = true,
) {
    override val padraoDeCor: Int =
        if (fonte.pal) MediaFormat.COLOR_STANDARD_BT601_PAL else MediaFormat.COLOR_STANDARD_BT601_NTSC

    /** O ritmo é o do disco (29,97 ou 25): nada de descartar na entrada. */
    override val limitarFpsNaEntrada: Boolean = false

    override fun iniciarFonte(inputSurface: Surface) {
        fonte.ligar(inputSurface, width, height)
    }

    override fun pararFonte() {
        fonte.desligar()
    }
}
