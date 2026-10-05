package com.quall.android.capture

import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import com.quall.android.EncodePreset

/**
 * Encoder de **tela**: [H264SurfaceEncoder] alimentado por [MediaProjection] + `VirtualDisplay`.
 *
 * Toda a lógica de dreno do `MediaCodec` (Annex-B, csd, start code, estatística, o "IDR devido"
 * confirmado no bitstream) mora na classe-mãe, comum com [H264CameraEncoder]. Esta classe só
 * sabe abrir e fechar a fonte: criar a `VirtualDisplay` sobre a superfície de entrada, e ouvir o
 * `MediaProjection.Callback` que o Android 14+ exige registrado antes de criar a `VirtualDisplay`.
 */
class H264ScreenEncoder(
    private val mediaProjection: MediaProjection,
    sink: FrameSink,
    width: Int,
    height: Int,
    private val densityDpi: Int,
    /** Braço de bancada do giro. Ver [com.quall.android.core.Bancada.giroResize]. */
    private val giroResize: Boolean = false,
    /** Só para observar a rotação do display no braço de bancada. Nulo em produto. */
    private val contexto: android.content.Context? = null,
    targetFps: Int = 30,
    // Preset tela (M6): bitrate menor, GOP curto — mudança brusca de cena pede IDR rápido, e
    // área plana comprime bem. Alinhado com `apps/macos/.../H264Encoder.swift` (`.screen`), a
    // referência do projeto para esta divisão. Ver `MirrorService.BITRATE_BPS_TELA`.
    bitrateBps: Int = 4_000_000,
    gopSeconds: Float = 1f,
    colecionarQuadros: Boolean = false,
    // Os dois botões do encoder que `docs/idr-pequeno.md` mede. Repassados sem interpretação:
    // quem decide o valor é quem constrói (produto: `MirrorService`; bancada: `Bancada`).
    refreshIntraQuadros: Int = 0,
    modoDeTaxa: Int = H264SurfaceEncoder.MODO_TAXA_AUTOMATICO,
    chavesDeFornecedor: Map<String, Int> = emptyMap(),
    // A janela do fio: instrumento, não produto. Ver `H264SurfaceEncoder.janelaDoFioMs`.
    janelaDoFioMs: Long = 0,
) : H264SurfaceEncoder(
    sink = sink,
    width = width,
    height = height,
    targetFps = targetFps,
    bitrateBps = bitrateBps,
    gopSeconds = gopSeconds,
    preset = EncodePreset.SCREEN,
    colecionarQuadros = colecionarQuadros,
    refreshIntraQuadros = refreshIntraQuadros,
    modoDeTaxa = modoDeTaxa,
    chavesDeFornecedor = chavesDeFornecedor,
    janelaDoFioMs = janelaDoFioMs,
) {
    companion object {
        private const val TAG = "QuallScreenSource"
    }

    private var virtualDisplay: VirtualDisplay? = null
    private var ouvinteDeGiro: Pair<DisplayManager, DisplayManager.DisplayListener>? = null
    @Volatile private var ultimaRotacao = -1
    private var callback: MediaProjection.Callback? = null
    @Volatile private var parado = false

    override fun iniciarFonte(inputSurface: Surface) {
        // Obrigatório a partir do Android 14: criar a VirtualDisplay sem callback registrado
        // derruba com IllegalStateException. Registrar sempre, para o mesmo caminho valer nos três
        // aparelhos da bancada.
        val cb = object : MediaProjection.Callback() {
            override fun onStop() {
                Log.i(TAG, "MediaProjection.onStop — a sessão de consentimento terminou")
                stop()
            }

            /**
             * **NÃO DISPARA no giro, e isso foi medido em 09/09/2026 no S24.**
             *
             * A hipótese era que girar mudasse o tamanho do conteúdo capturado. Não muda: o log do
             * sistema mostra `mBounds=Rect(0, 0 - 1440, 3120)` com `mDisplayRotation=ROTATION_0`
             * antes e depois. O display é 1440x3120 sempre; o que gira é o conteúdo **dentro**
             * dele, e a tarja preta é o compositor do Android encaixando a interface deitada no
             * quadro em pé — antes de qualquer pixel chegar até nós.
             *
             * Fica registrado porque a ausência é o achado: quem for mexer no giro precisa saber
             * que este caminho não serve de gatilho.
             *
             * **Só existe a partir do Android 14**, e por isso o braço de bancada é declarado como
             * não disponível abaixo disso em vez de silenciosamente não fazer nada.
             *
             * O que ele faz é UMA coisa e nada além: redimensionar o `VirtualDisplay`. O
             * `MediaCodec` **não** é tocado, nenhum SPS novo sai, nenhum receptor é reconfigurado.
             * É o experimento mínimo que separa dois caminhos opostos para a frente do giro —
             * ver `Bancada.giroResize`.
             */
            override fun onCapturedContentResize(largura: Int, altura: Int) {
                Log.i(TAG, "conteúdo capturado mudou para ${largura}x$altura " +
                    "(encoder segue em ${width}x$height, giro_resize=$giroResize)")
                if (!giroResize) return
                val vd = virtualDisplay ?: return
                val r = runCatching { vd.resize(largura, altura, densityDpi) }
                Log.i(TAG, "VirtualDisplay.resize(${largura}x$altura) -> " +
                    if (r.isSuccess) "ok" else "falhou: ${r.exceptionOrNull()}")
            }
        }
        callback = cb
        mediaProjection.registerCallback(cb, fonteHandler)

        virtualDisplay = mediaProjection.createVirtualDisplay(
            "quall-capture",
            width,
            height,
            densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface,
            null,
            fonteHandler,
        )
        contexto?.let { observarGiro(it) }
    }

    /**
     * Observa a **rotação** do display, que é o que de fato muda no giro.
     *
     * `onCapturedContentResize` não serve — ver a nota nele. O `DisplayManager` avisa em
     * `onDisplayChanged`, e ali dá para ler `display.rotation` e decidir.
     *
     * Só entra com o braço de bancada ligado. Ver `Bancada.giroResize`.
     */
    private fun observarGiro(contexto: android.content.Context) {
        if (!giroResize) return
        val dm = contexto.getSystemService(DisplayManager::class.java) ?: return
        val ouvinte = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(id: Int) {}
            override fun onDisplayRemoved(id: Int) {}
            override fun onDisplayChanged(id: Int) {
                if (id != android.view.Display.DEFAULT_DISPLAY) return
                val d = dm.getDisplay(id) ?: return
                val r = d.rotation
                if (r == ultimaRotacao) return
                ultimaRotacao = r
                val deitado = r == android.view.Surface.ROTATION_90 || r == android.view.Surface.ROTATION_270
                val (l, a2) = if (deitado) maxOf(width, height) to minOf(width, height)
                              else minOf(width, height) to maxOf(width, height)
                Log.i(TAG, "giro: rotation=$r deitado=$deitado — pedindo resize para ${l}x$a2 " +
                    "(encoder segue em ${width}x$height)")
                val vd = virtualDisplay
                if (vd == null) { Log.w(TAG, "giro: sem VirtualDisplay"); return }
                val res = runCatching { vd.resize(l, a2, densityDpi) }
                Log.i(TAG, "giro: VirtualDisplay.resize(${l}x$a2) -> " +
                    if (res.isSuccess) "ok" else "falhou: ${res.exceptionOrNull()}")
            }
        }
        dm.registerDisplayListener(ouvinte, fonteHandler)
        ouvinteDeGiro = dm to ouvinte
        ultimaRotacao = dm.getDisplay(android.view.Display.DEFAULT_DISPLAY)?.rotation ?: -1
        Log.i(TAG, "giro: observando rotação (inicial=$ultimaRotacao)")
    }

    override fun pararFonte() {
        if (parado) return
        parado = true
        ouvinteDeGiro?.let { (dm, o) -> runCatching { dm.unregisterDisplayListener(o) } }
        ouvinteDeGiro = null
        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        callback?.let { runCatching { mediaProjection.unregisterCallback(it) } }
        callback = null
    }
}
