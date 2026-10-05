package com.quall.android.capture

import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import com.quall.android.EncodePreset

/**
 * O codificador da **rede** na tela R5 e no espelhamento de câmera comum: [H264SurfaceEncoder] alimentado por uma saída do
 * [DivisorGl] do [DonoDaCaptura]. Nascer é pendurar uma saída no divisor; morrer é soltá-la.
 * **Nenhum dos dois toca na câmera** — é o que faz a prévia não piscar quando o receptor conecta,
 * cai e volta (`docs/teleprompter-com-camera.md` §8, fase 1).
 *
 * O tamanho é o da imagem em pé na tela no instante do pareamento, e fica fixo pela sessão (a
 * superfície de um `MediaCodec` não muda de tamanho). Se a tela girar no meio, o divisor desenha a
 * imagem girada dentro do mesmo quadro, com tarjas, como o espelhamento da tela já faz.
 *
 * O carimbo é o da câmera (`eglPresentationTimeANDROID`, no divisor), e o relógio dele é o que a
 * câmera declara — por isso [nowMicrosParaLatencia] é a mesma escolha de [H264CameraEncoder].
 */
class H264DivisorEncoder(
    private val dono: DonoDaCaptura,
    sink: FrameSink,
    width: Int,
    height: Int,
    targetFps: Int = 30,
    bitrateBps: Int = 6_000_000,
    gopSeconds: Float = 2f,
    refreshIntraQuadros: Int = 0,
    modoDeTaxa: Int = H264SurfaceEncoder.MODO_TAXA_AUTOMATICO,
    chavesDeFornecedor: Map<String, Int> = emptyMap(),
    /**
     * A rotação congelada da rede (a câmera comum: a do aparelho no pareamento, a revisão de 24/09,
     * B1), ou `null` (a tela R5: segue a tela, com tarjas num giro).
     */
    private val rotacaoFixa: Int? = null,
    /**
     * A porta da rede no divisor: o máximo de quadros em trânsito neste codificador (§14.11); 0
     * desliga (o padrão até a prova, `Bancada.filaDoCodificadorQuadros`). A conta vai ao diário sempre.
     */
    tetoDaFila: Int = 0,
) : H264SurfaceEncoder(
    sink = sink,
    width = width,
    height = height,
    targetFps = targetFps,
    bitrateBps = bitrateBps,
    gopSeconds = gopSeconds,
    preset = EncodePreset.CAMERA,
    colecionarQuadros = false,
    refreshIntraQuadros = refreshIntraQuadros,
    modoDeTaxa = modoDeTaxa,
    chavesDeFornecedor = chavesDeFornecedor,
    latenciaComparavel = dono.timestampSourceRealtime,
) {
    companion object {
        private const val TAG = "QuallDivisorEncoder"
    }

    @Volatile private var saida: DivisorGl.Saida? = null
    private val trava = Any()
    private val fila = FilaDoCodificador(tetoDaFila)

    override fun iniciarFonte(inputSurface: Surface) {
        Log.i(TAG, "pendurando a rede no divisor (${width}x$height" +
            (rotacaoFixa?.let { ", rotação fixa em ${it * 90}°" } ?: "") + ") — a câmera já está aberta e não é tocada")
        saida = dono.ligarCodificador("rede", inputSurface, width, height, rotacaoFixa, fila)
    }

    override fun aoSairQuadro(ptsCruUs: Long) = fila.saiu(ptsCruUs)

    /** Idempotente: chamada antes do fim de fluxo e de novo na limpeza. */
    override fun pararFonte() {
        val s = synchronized(trava) { saida.also { saida = null } } ?: return
        dono.desligar(s)
    }

    /**
     * A frontal do S24 declara `REALTIME` e é `BOOTTIME` (S-A1): com o microfone junto, a zona
     * ambígua do [RelogioDoPts] é desempatada por isto, e não deixada com até 300 ms de erro. **Só
     * na tela R5** ([DonoDaCaptura.desempatePelaDeclaracao]): na câmera comum a traseira do A07
     * declara `REALTIME` e é `MONOTONIC`, e o desempate trocaria um erro de 0 por um de `|b|`.
     */
    override val ptsDeclaradoBoottime: Boolean get() = dono.timestampSourceRealtime && dono.desempatePelaDeclaracao

    override fun nowMicrosParaLatencia(): Long =
        if (dono.timestampSourceRealtime) SystemClock.elapsedRealtimeNanos() / 1000L else MonotonicClock.micros()
}
