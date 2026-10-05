package com.quall.android.capture

import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import com.quall.android.EncodePreset

/**
 * Encoder de **câmera**: [H264SurfaceEncoder] alimentado pelo CameraX através de [CameraXSource].
 *
 * A resolução vem pronta no construtor porque [CameraXSource.ligarCodificador] já negociou com a
 * câmera **antes** deste objeto existir — o mesmo padrão que [H264ScreenEncoder] segue com a resolução da
 * tela, só que aqui quem decide o tamanho é a câmera, não a Activity.
 *
 * `preset = EncodePreset.CAMERA` é passado à classe-mãe como rótulo (`crates/quall-core/src/protocol.rs`
 * define `EncodePreset` como tag de protocolo, não como conjunto de números — cada casca decide os
 * números). Até o M6 os dois presets (tela/câmera) usavam os mesmos números aqui; agora o bitrate e
 * o GOP têm valor próprio, alinhados ao que o macOS já mede e declara desde o M1
 * (`apps/macos/Sources/QuallCaptureKit/H264Encoder.swift`, `PresetTuning` de `.camera`): mais bits
 * para o ruído de sensor, GOP mais largo porque o conteúdo já é redundante quadro a quadro e não
 * precisa de refresh frequente. Ver `MirrorService.BITRATE_BPS_CAMERA`/`GOP_SEGUNDOS_CAMERA`.
 * **Não medido no A07 nem no A10s por esta frente** — decisão de design (docs/ux-m6.md), não
 * número recalibrado em bancada.
 */
class H264CameraEncoder(
    private val cameraSource: CameraXSource,
    sink: FrameSink,
    targetFps: Int = 30,
    bitrateBps: Int = 6_000_000,
    gopSeconds: Float = 2f,
    colecionarQuadros: Boolean = false,
    refreshIntraQuadros: Int = 0,
    modoDeTaxa: Int = H264SurfaceEncoder.MODO_TAXA_AUTOMATICO,
    chavesDeFornecedor: Map<String, Int> = emptyMap(),
) : H264SurfaceEncoder(
    sink = sink,
    width = cameraSource.resolution.width,
    height = cameraSource.resolution.height,
    targetFps = targetFps,
    bitrateBps = bitrateBps,
    gopSeconds = gopSeconds,
    preset = EncodePreset.CAMERA,
    colecionarQuadros = colecionarQuadros,
    refreshIntraQuadros = refreshIntraQuadros,
    modoDeTaxa = modoDeTaxa,
    chavesDeFornecedor = chavesDeFornecedor,
    // Ver a doc de `latenciaComparavel` em H264SurfaceEncoder e de `nowMicrosParaLatencia`
    // abaixo: medido nos dois aparelhos que o M4 exige prova, e nos dois o resultado foi "não
    // confiável", por motivos diferentes.
    latenciaComparavel = cameraSource.timestampSourceRealtime,
) {
    companion object {
        private const val TAG = "QuallCameraEncSource"
    }

    override fun iniciarFonte(inputSurface: Surface) {
        Log.i(
            TAG,
            "entregando a superfície do encoder ao CameraX (${width}x$height, " +
                "timestamp_source=${if (cameraSource.timestampSourceRealtime) "REALTIME" else "UNKNOWN"})",
        )
        cameraSource.prover(inputSurface)
    }

    /**
     * `soltarCodificador()` e não `parar()`, e a diferença é de dono da câmera.
     *
     * Fechar a câmera aqui era certo enquanto ela pertencia à sessão: o encoder terminava, a
     * câmera terminava junto. Deixou de ser em 03/09, quando a prévia passou a existir **antes**
     * do pareamento — no iOS a `AVCaptureSession` da `TelaDaCamera` roda independente da sessão do
     * Quall, e a pessoa acerta o enquadramento enquanto espera. Se este método continuasse
     * fechando a câmera, a prévia morreria no fim de cada sessão e não voltaria quando o serviço
     * volta a esperar outro receptor.
     *
     * [CameraXSource.soltarCodificador] carrega essa distinção e não a espalha aqui: com prévia
     * persistente ela desbinda **só** o `VideoCapture`; sem ela — o instrumento de bancada
     * ([CameraCaptureService]), que nunca chama `parar()` por conta própria — faz o `parar()`
     * inteiro, byte a byte o que este caminho já fazia. **O caminho medido no §8.18
     * (`VideoCapture` → `SaidaDeVideoParaCodificador` → `MediaCodec`) não muda**: o que muda é o
     * que sobra depois que ele acaba.
     */
    override fun pararFonte() {
        cameraSource.soltarCodificador()
    }

    /**
     * Escolhe o relógio mais próximo do certo, sabendo que "certo" pode não existir.
     *
     * `SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME` promete que o carimbo é `CLOCK_BOOTTIME`, o mesmo
     * domínio de `SystemClock.elapsedRealtimeNanos()`; `UNKNOWN` promete o oposto — não comparável
     * a relógio de sistema nenhum. Medido nos dois aparelhos do M4:
     *
     * - **A07** (`c2.mtk.avc.encoder`, câmera traseira): declara **REALTIME**, e mesmo assim o
     *   delta contra `elapsedRealtimeNanos()` saiu em ~2,94 **horas** — a promessa da API não se
     *   sustentou. Pego pelo teto numérico de `H264SurfaceEncoder` (`latenciaComparavel=true`
     *   aqui não evita o descarte; só evita que a UI mostre algo antes da amostra ser julgada).
     * - **A10s** (`OMX.MTK.VIDEO.ENCODER.AVC`, câmera traseira): declara **UNKNOWN**, e o delta
     *   contra [MonotonicClock] saiu em ~103 ms — um número **plausível**, que passaria pelo teto
     *   numérico sozinho, mas que a documentação do Android diz que não significa nada. É por
     *   isso que `latenciaComparavel` passado ao construtor da classe-mãe existe: descarta de
     *   saída, sem depender de o número "parecer" errado.
     *
     * `fps_obtido` continua válido nos dois casos: vem só de deltas entre `presentationTimeUs`
     * consecutivos do mesmo fluxo de câmera, comparáveis entre si mesmo sob `UNKNOWN` (é o que a
     * própria documentação do `SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN` garante).
     */
    override fun nowMicrosParaLatencia(): Long =
        if (cameraSource.timestampSourceRealtime) {
            SystemClock.elapsedRealtimeNanos() / 1000L
        } else {
            MonotonicClock.micros()
        }
}
