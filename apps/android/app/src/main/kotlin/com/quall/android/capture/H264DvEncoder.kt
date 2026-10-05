package com.quall.android.capture

import android.media.MediaFormat
import android.view.Surface
import com.quall.android.EncodePreset
import com.quall.android.capture.dv.FonteDv

/**
 * Encoder da **filmadora DV por USB**: o mesmo [H264SurfaceEncoder] das câmeras, com a
 * superfície de entrada alimentada por um `ImageWriter` ([FonteDv.ligar]), e não pelo CameraX.
 *
 * O carimbo de cada quadro é o `CLOCK_MONOTONIC` do pacote USB que o fechou. O [RelogioDoPts]
 * classifica MONOTONIC e soma zero, e a latência é comparável ao [MonotonicClock] (o padrão de
 * [nowMicrosParaLatencia]).
 *
 * O tamanho vem da abertura (854x480 em 16:9, 640x480 em 4:3, ou 848 se o codec não aceitar 854).
 * Uma troca de aspecto no meio da sessão sai **encaixada** com faixas, no mesmo tamanho, como no
 * Windows (`regras_da_camera::encaixe`).
 */
class H264DvEncoder(
    private val fonte: FonteDv,
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
    targetFps = 30,
    bitrateBps = bitrateBps,
    gopSeconds = gopSeconds,
    preset = EncodePreset.CAMERA,
    colecionarQuadros = false,
    refreshIntraQuadros = refreshIntraQuadros,
    modoDeTaxa = modoDeTaxa,
    chavesDeFornecedor = chavesDeFornecedor,
    latenciaComparavel = true,
) {
    override val padraoDeCor: Int = MediaFormat.COLOR_STANDARD_BT601_NTSC
    override val limitarFpsNaEntrada: Boolean = false

    override fun iniciarFonte(inputSurface: Surface) {
        fonte.ligar(inputSurface, width, height)
    }

    override fun pararFonte() {
        fonte.desligar()
    }
}
