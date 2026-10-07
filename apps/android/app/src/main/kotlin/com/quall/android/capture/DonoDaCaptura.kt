package com.quall.android.capture

import com.quall.android.capture.CameraXSource.Companion.comSeletor
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import com.quall.android.core.LogSeguro as Log
import android.util.Size
import android.view.Display
import android.view.Surface
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.MirrorMode
import androidx.camera.core.SurfaceRequest
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.VideoCapture
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * **O dono da captura** (`docs/teleprompter-com-camera.md` §1.1, §2.1 e §8.6): abre a câmera
 * **uma vez** e a mantém enquanto alguém a usa. As saídas — a prévia, a rede e a gravação — ligam e
 * desligam no [DivisorGl] **sem reabrir a câmera**: a sessão de vídeo se pendura aqui quando um
 * receptor pareia e se solta quando ele cai, e a gravação idem.
 *
 * Dois donos usam isto:
 *
 * - **a tela R5** ("Teleprompter com câmera"): a frontal, aberta quando a tela abre e fechada quando
 *   ela fecha;
 * - **o espelhamento de câmera comum** (desde 24/09, §8.6): a frontal ou a traseira escolhida na
 *   tela inicial, aberta quando há tela olhando (a prévia da espera), uma sessão ou uma gravação, e
 *   fechada quando não há nenhum dos três. Antes ele era o `CameraXSource`, que fechava e reabria a
 *   câmera ao ligar o codificador (`rebind_junto`, S-A4: 468 ms de buraco e a câmera fechando 3/3).
 *
 * ## O que é diferente do `CameraXSource`
 *
 * - **Um use case só, bindado uma vez**: um `VideoCapture` cuja superfície é a `SurfaceTexture` do
 *   divisor. Nada de `rebind_junto` na conexão (que fecha a câmera: S-A4, 3/3), nada de `Preview`
 *   (a prévia sai do divisor; ver a doc de [DivisorGl]).
 * - **O dono não segue a tela**: quem abre e fecha é o serviço (a tela R5 abre e fecha com ela; a
 *   câmera comum fecha quando não há tela olhando, sessão nem gravação). Com o app em segundo plano
 *   a prévia some (a superfície morre) e a transmissão e a gravação seguem — o serviço em primeiro
 *   plano com tipo `camera` existe para isso.
 * - **A geometria não amarra a rede**: a câmera escreve na resolução do cardápio (a "melhor
 *   imagem" que a fase 3 grava) e cada saída é desenhada no tamanho dela.
 *
 * O `VideoCapture` continua sem nó GL do CameraX pelos mesmos motivos de `CameraXSource`
 * (`MIRROR_MODE_OFF`, `ResolutionSelector`, sem efeito nem `ViewPort`): com nó, o timebase vira
 * `UPTIME` e o carimbo que a rede leva viraria número plausível e errado.
 *
 * ## O carimbo
 *
 * Cada saída de codificador leva `eglPresentationTimeANDROID(SurfaceTexture.getTimestamp)` — o
 * carimbo do sensor (S-A1: 299/299). No S24 a frontal é `REALTIME`, ou seja `BOOTTIME`; quem o leva
 * a `MONOTONIC` é o [RelogioDoPts] do codificador, que mede e não acredita.
 */
class DonoDaCaptura private constructor(
    private val contexto: Context,
    val cameraId: String,
    private val provider: ProcessCameraProvider,
    private val videoCapture: VideoCapture<SaidaDeVideoParaCodificador>,
    private val divisor: DivisorGl,
    /** `SENSOR_INFO_TIMESTAMP_SOURCE == REALTIME`: o carimbo é comparável a `elapsedRealtimeNanos`. */
    val timestampSourceRealtime: Boolean,
    private val orientacaoDoSensor: Int,
    /** A taxa pedida à câmera (o cardápio), para o codificador pedir a mesma. */
    val fpsPedido: Int,
    /**
     * A declaração `REALTIME` desempata a zona ambígua do [RelogioDoPts] (`|b|` < 300 ms)? Só na
     * tela R5 — a frontal que a S-A1 mediu `BOOTTIME` no S24. Na câmera comum não: a traseira do A07
     * declara `REALTIME` e é `MONOTONIC` (§8.4, a revisão M5).
     */
    val desempatePelaDeclaracao: Boolean,
    /** A lente é a frontal (`LENS_FACING` não é `BACK`). */
    val frontal: Boolean,
    /** Para o diário: "da tela R5" ou "do espelhamento de câmera". */
    private val deQuem: String,
) {
    companion object {
        private const val TAG = "QuallDonoDaCaptura"
        private const val PRAZO_PADRAO_MS = 6_000L

        /**
         * Abre a câmera [cameraId] com o `VideoCapture` no divisor e espera o primeiro pedido de
         * superfície. Chame de uma thread de trabalho: o bind é postado na principal e esta função
         * espera por ele.
         */
        @androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
        fun abrir(
            contexto: Context,
            ciclo: LifecycleOwner,
            cameraId: String,
            /** Ver [desempatePelaDeclaracao]: `true` só na tela R5. */
            desempatePelaDeclaracao: Boolean,
            /** "da tela R5" ou "do espelhamento de câmera", para o diário. */
            deQuem: String,
            prazoMs: Long = PRAZO_PADRAO_MS,
        ): DonoDaCaptura {
            check(Looper.myLooper() != Looper.getMainLooper()) { "DonoDaCaptura.abrir na thread principal" }
            val provider = ProcessCameraProvider.getInstance(contexto).get(prazoMs, TimeUnit.MILLISECONDS)
            val seletor = CameraSelector.Builder()
                .addCameraFilter { infos -> infos.filter { Camera2CameraInfo.from(it).cameraId == cameraId }.toMutableList() }
                .build()
            val cm = contexto.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            val chars = runCatching { cm?.getCameraCharacteristics(cameraId) }.getOrNull()
            val realtime = chars?.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE) ==
                CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME
            val sensor = chars?.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            val frontal = chars?.get(CameraCharacteristics.LENS_FACING) != CameraCharacteristics.LENS_FACING_BACK

            val salva = com.quall.android.core.Resolucao.escolhida(contexto)
            val fps = com.quall.android.core.Resolucao.quadros(contexto)
            val cardapio = com.quall.android.core.SeletorDeResolucao.estado(false,
                tetos = CameraXSource.tetosPorResolucao(contexto, cameraId), escolhida = salva, fps = fps)
            val escolhida = cardapio.resolucaoPara(salva)
            val fpsAlvo = cardapio.quadrosPara(fps)
            val divisor = DivisorGl("quall-divisor", pelaMaisNova = com.quall.android.core.Bancada.cameraPeloMaisNovo(contexto),
                lumaMedia = com.quall.android.core.Bancada.lumaMedia(contexto)).also { it.frontal = frontal }
            val primeiro = CountDownLatch(1)
            // Um pedido que chegue antes de o dono existir espera na lista; a decisão "atender já ou
            // guardar" é sob a mesma trava que publica o dono, senão um pedido cairia no intervalo.
            var pronto: DonoDaCaptura? = null
            val pedidosAntes = ArrayList<SurfaceRequest>()
            val saida = SaidaDeVideoParaCodificador { req ->
                val d = synchronized(pedidosAntes) { pronto ?: run { pedidosAntes.add(req); null } }
                d?.atender(req)
                primeiro.countDown()
            }
            val vcBuilder = VideoCapture.Builder(saida)
                .setMirrorMode(MirrorMode.MIRROR_MODE_OFF)
                .comSeletor(CameraXSource.seletorPara(escolhida.pedido))
            // A taxa, como em `CameraXSource.pedirQuadros`: a faixa variável até o fps escolhido, a 30
            // também, para o automático clarear a imagem em pouca luz (`faixaDoAutomatico`).
            vcBuilder.setTargetFrameRate(CameraXSource.faixaDoAutomatico(CameraXSource.faixasDeQuadros(contexto, cameraId), fpsAlvo))
            // O que a câmera disse ter usado (R9, `docs/controles-de-camera.md` §3.6 e §6): o
            // `CaptureResult` de cada quadro, para a leitura de volta, o Kelvin lido e as travas que
            // guardam valores. Só se instala antes do bind.
            val leitor = LeitorDoResultado()
            Camera2Interop.Extender(vcBuilder).setSessionCaptureCallback(leitor)
            val vc = vcBuilder.build()

            val d = DonoDaCaptura(contexto.applicationContext, cameraId, provider, vc, divisor, realtime, sensor, fpsAlvo,
                desempatePelaDeclaracao, frontal, deQuem)
            val principal = Handler(Looper.getMainLooper())
            var falha: Throwable? = null
            val bind = CountDownLatch(1)
            principal.post {
                try {
                    // **Sem `unbindAll`** (a revisão, menor): o `ProcessCameraProvider` é do
                    // processo inteiro, e um `unbindAll` aqui derrubaria o bind de outro dono (o
                    // instrumento de bancada, por exemplo). O serviço garante uma espera por vez.
                    val cam = provider.bindToLifecycle(ciclo, seletor, vc)
                    CameraXSource.observarEstadoDaCamera(cam, ciclo, contexto)
                    // A `Camera` deixa de ser descartada (R9, §6): os controles chegam a ela por aqui,
                    // e o registro desta câmera é aplicado já, com o interop sempre (§2.2).
                    // Uma falha aqui não derruba a câmera: ela abre sem controles, e o diário diz.
                    d.controles = runCatching {
                        ControlesDaCamera(contexto, cameraId, cam, leitor, { d.quadrosNegociados ?: d.fpsPedido }, chars)
                    }.onFailure { Log.e(TAG, "r9: os controles da câmera $cameraId não nasceram", it) }
                        .getOrNull()?.also {
                            it.tocarPelaRede = { x, y, s -> d.pontoDaRede(x, y, s) }
                            // O nome que os receptores mostram, no idioma do app (R9b, `nomeDaCamera`).
                            it.nomeDaCamera = com.quall.android.core.Idioma.contexto(contexto)
                                .getString(if (frontal) com.quall.android.R.string.cam_frontal else com.quall.android.R.string.cam_traseira)
                            it.aoAbrir()
                        }
                } catch (t: Throwable) {
                    falha = t
                } finally {
                    bind.countDown()
                }
            }
            fun desfazer() {
                val l = CountDownLatch(1)
                principal.post { runCatching { provider.unbind(vc) }; l.countDown() }
                l.await(2, TimeUnit.SECONDS)
                divisor.liberar()
            }
            if (!bind.await(prazoMs, TimeUnit.MILLISECONDS)) {
                desfazer()
                throw IllegalStateException("o bind da câmera $cameraId não respondeu em $prazoMs ms")
            }
            falha?.let {
                desfazer()
                throw IllegalStateException("o bind da câmera $cameraId falhou: ${it.message}", it)
            }
            // Daqui em diante os pedidos vão direto ao dono; os que chegaram antes são atendidos já.
            // Qualquer saída por exceção a partir daqui fecha o dono (câmera e divisor): uma
            // interrupção no meio não deixa nada aberto.
            try {
                val antes = synchronized(pedidosAntes) { pronto = d; ArrayList(pedidosAntes).also { pedidosAntes.clear() } }
                antes.forEach { d.atender(it) }
                if (!primeiro.await(prazoMs, TimeUnit.MILLISECONDS)) {
                    throw IllegalStateException("a câmera $cameraId não pediu superfície em $prazoMs ms")
                }
                d.acompanharRotacao()
                d.acompanharOrientacaoFisica()
            } catch (t: Throwable) {
                d.fechar()
                throw t
            }
            Log.i(TAG, "câmera $cameraId (${if (frontal) "frontal" else "traseira"}) aberta $deQuem: um VideoCapture no divisor, " +
                "cardápio ${escolhida.rotulo} a $fps fps, sensor a $sensor°, " +
                "timestamp_source=${if (realtime) "REALTIME" else "UNKNOWN"}, " +
                "desempate_pela_declaracao=$desempatePelaDeclaracao, " +
                "luma_media=${com.quall.android.core.Bancada.lumaMedia(contexto)}")
            return d
        }
    }

    private val principal = Handler(Looper.getMainLooper())
    private val fechou = java.util.concurrent.atomic.AtomicBoolean(false)
    private val fechado: Boolean get() = fechou.get()
    private var ouvinteDeTela: DisplayManager.DisplayListener? = null

    /** A resolução que a câmera escreve agora, ou `null` antes do primeiro pedido. */
    @Volatile var resolucaoDaCamera: Size? = null
        private set

    /** O teto de fps que a câmera negociou (`SurfaceRequest.expectedFrameRate`), quando diz. */
    @Volatile var quadrosNegociados: Int? = null
        private set

    val divisorGl: DivisorGl get() = divisor

    /**
     * **Os controles de câmera do R9** (`docs/controles-de-camera.md`): nascem no bind, com a `Camera`
     * que o `bindToLifecycle` devolve, e são o que o `MirrorService` oferece à tela. `null` só antes do
     * bind. As fontes `usb-dv:` não têm dono, e por isso não têm controles (§2.2).
     */
    @Volatile var controles: ControlesDaCamera? = null
        internal set

    /** A prévia como espelho (§6). Ajuste local; a rede nunca espelha. */
    var espelharPrevia: Boolean
        get() = divisor.espelharPrevia
        set(v) { divisor.espelharPrevia = v }

    /**
     * Atende um pedido de superfície — o primeiro e os que o CameraX emite sozinho quando reabre a
     * câmera depois de uma expulsão (o desbloqueio por rosto do S24; ver
     * `CameraXSource.aoPedirSuperficie`). A superfície é sempre a mesma: a do divisor. Uma
     * resolução diferente não é recusada, porque cada saída tem o tamanho dela.
     */
    private fun atender(req: SurfaceRequest) {
        if (fechado) {
            req.willNotProvideSurface()
            return
        }
        val r = req.resolution
        val anterior = resolucaoDaCamera
        divisor.ajustarBuffer(r.width, r.height)
        resolucaoDaCamera = r
        quadrosNegociados = CameraXSource.quadrosDoPedido(req)
        runCatching {
            req.setTransformationInfoListener({ it.run() }) { info ->
                Log.i(TAG, "TransformationInfo: rotação ${info.rotationDegrees}°, " +
                    "hasCameraTransform=${info.hasCameraTransform()}, recorte ${info.cropRect}")
                if (!info.hasCameraTransform()) {
                    // A conta de [GeometriaDoDivisor] supõe que a matriz da `SurfaceTexture` já
                    // traz a orientação do sensor. Sem isso a rede e a prévia saem giradas: dito
                    // alto, na tela e no registro, e não escondido (a revisão, M4).
                    Log.e(TAG, "r5: SEM hasCameraTransform — a matriz da câmera não traz a orientação; " +
                        "a imagem da rede e da prévia pode sair girada")
                    com.quall.android.mirror.MirrorBus.atualizar {
                        it.copy(mensagem = com.quall.android.core.Idioma.contexto(contexto).getString(com.quall.android.R.string.cam_sem_orientacao))
                    }
                }
            }
        }
        req.provideSurface(divisor.entrada, { it.run() }) { resultado ->
            Log.i(TAG, "a câmera soltou a superfície do divisor: código ${resultado.resultCode}")
        }
        // A câmera reabriu sozinha (§2.2): o CameraX perdeu o EV e o toque; o registro volta inteiro.
        if (anterior != null) controles?.aoReabrir()
        Log.i(TAG, if (anterior == null) {
            "pedido de superfície: ${r.width}x${r.height}, fps negociado ${quadrosNegociados ?: "?"}"
        } else {
            "pedido de superfície NOVO (${r.width}x${r.height}; antes $anterior) — a câmera reabriu " +
                "sozinha; entregando a mesma superfície do divisor"
        })
    }

    /** A rotação da tela, que a prévia segue na hora e a rede segue com tarjas (tamanho fixo). */
    private fun acompanharRotacao() {
        val dm = contexto.getSystemService(DisplayManager::class.java) ?: return
        fun ler() {
            val r = dm.getDisplay(Display.DEFAULT_DISPLAY)?.rotation ?: return
            if (r != divisor.rotacaoDaTela) Log.i(TAG, "rotação da tela: ${r * 90}°")
            divisor.rotacaoDaTela = r
            // A última rotação com a tela do app à vista: o recurso da câmera comum sem sensor.
            if (PreviaDaCamera.telaOlhando) ultimaRotacaoComTela = r
        }
        ler()
        val o = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(id: Int) = Unit
            override fun onDisplayRemoved(id: Int) = Unit
            override fun onDisplayChanged(id: Int) {
                if (id == Display.DEFAULT_DISPLAY) ler()
            }
        }
        dm.registerDisplayListener(o, divisor.handler)
        ouvinteDeTela = o
    }

    /**
     * O tamanho da imagem em pé na tela, agora — o que a rede codifica, antes do teto do nível.
     * A orientação natural vem da matriz da câmera quando já chegou quadro, e da orientação do
     * sensor antes disso (as duas dizem a mesma coisa: a câmera gira o buffer pela do sensor).
     */
    fun tamanhoNaTela(rotacao: Int = divisor.rotacaoDaTela): Size {
        val r = resolucaoDaCamera ?: Size(1920, 1080)
        val troca = divisor.trocaEixos ?: (orientacaoDoSensor % 180 != 0)
        val (ln, an) = GeometriaDoDivisor.tamanhoNatural(r.width, r.height, troca)
        val (lt, at) = GeometriaDoDivisor.tamanhoNaTela(ln, an, rotacao)
        return Size(lt, at)
    }

    /** A rotação da tela agora, para o registro da sessão. */
    val rotacaoDaTela: Int get() = divisor.rotacaoDaTela

    // --- a orientação física (a câmera comum; a revisão de 24/09, B1) -------------------------------

    private var ouvinteFisico: android.view.OrientationEventListener? = null

    /** A rotação (`Surface.ROTATION_*`) que a orientação FÍSICA do aparelho pede, ou `null` sem leitura. */
    @Volatile var rotacaoFisica: Int? = null
        private set

    /**
     * **A rotação que a rede e a gravação congelam** ao nascer. Na tela R5 é a da tela: a R5 está na
     * frente, e quem a usa escolhe a orientação nela. **Na câmera comum é a do aparelho**, e nunca a
     * da tela do momento (a revisão de 24/09, B1): no tripé o app fica em segundo plano, e a tela do
     * momento é a de outro app, a do bloqueio (Samsung: retrato), ou retrato fixo com o giro
     * automático desligado e o aparelho deitado — a cena sairia de lado. Sem leitura física (o
     * aparelho deitado de face para cima, ou sem sensor), vale a última rotação vista com a tela
     * olhando, e só então a da tela agora.
     */
    val rotacaoDeReferencia: Int
        get() = if (desempatePelaDeclaracao) divisor.rotacaoDaTela
            else rotacaoFisica ?: ultimaRotacaoComTela ?: divisor.rotacaoDaTela

    /** A rotação da tela na última vez que havia tela olhando (a câmera comum). */
    @Volatile private var ultimaRotacaoComTela: Int? = null

    /** De onde vem [rotacaoDeReferencia], para o diário. */
    val origemDaReferencia: String
        get() = when {
            desempatePelaDeclaracao -> "a tela (R5)"
            rotacaoFisica != null -> "o aparelho (sensor)"
            ultimaRotacaoComTela != null -> "a última tela vista" // i18n-fora: diário
            else -> "a tela agora"
        }

    /**
     * Acompanha a orientação física pelo `OrientationEventListener`, com folga de 30° em volta de cada
     * degrau (um aparelho a 45° não fica trocando). Só na câmera comum.
     */
    private fun acompanharOrientacaoFisica() {
        if (desempatePelaDeclaracao) return
        val o = object : android.view.OrientationEventListener(contexto) {
            override fun onOrientationChanged(graus: Int) {
                val nova = GeometriaDoDivisor.rotacaoDaOrientacao(graus, rotacaoFisica) ?: return
                if (nova != rotacaoFisica) {
                    Log.i(TAG, "orientação física: ${graus}° -> rotação ${nova * 90}°")
                    rotacaoFisica = nova
                }
            }
        }
        if (o.canDetectOrientation()) {
            principal.post { runCatching { o.enable() } }
            ouvinteFisico = o
        } else {
            Log.w(TAG, "sem sensor de orientação: a rede usa a última rotação vista com a tela olhando")
        }
    }

    /**
     * Pendura um codificador (a rede; a gravação, com a [rotacaoFixa] do toque em Gravar). Não toca
     * na câmera.
     */
    fun ligarCodificador(
        nome: String,
        superficie: Surface,
        largura: Int,
        altura: Int,
        rotacaoFixa: Int? = null,
        fila: FilaDoCodificador? = null,
    ): DivisorGl.Saida {
        check(!fechado) { "a câmera $deQuem já foi fechada" }
        return divisor.ligarCodificador(nome, superficie, largura, altura, rotacaoFixa, fila)
    }

    /**
     * **O toque na prévia** (R9, §4.4) em ([x], [y]) pixels de uma prévia de [largura] × [altura]: leva
     * o ponto ao buffer da câmera pelo [CaminhoDoToque], com a mesma geometria com que o divisor desenha
     * a prévia e a matriz da câmera que ele publicou, e o entrega aos [controles]. Devolve `false` se o
     * toque caiu numa tarja, se ainda não chegou quadro, ou se nada se mede (sem quadrado).
     */
    fun tocarNaPrevia(x: Float, y: Float, largura: Int, altura: Int, longo: Boolean): Boolean {
        val c = controles ?: return false
        val st = divisor.matrizDaCamera ?: return false
        val b = divisor.buffer ?: return false
        val troca = divisor.trocaEixos ?: return false
        val (ln, an) = GeometriaDoDivisor.tamanhoNatural(b.width, b.height, troca)
        val p = CaminhoDoToque.pontoNoBuffer(x, y, largura, altura, ln, an, divisor.rotacaoDaTela,
            espelharNaTela = divisor.espelharPrevia, texturaEspelhada = divisor.matrizEspelhada == true,
            frontal = frontal, st = st) ?: return false
        return c.tocar(p.first, p.second, longo)
    }

    /**
     * **O toque de um receptor** (R9b, contrato §3.4): ([xn], [yn]) de 0 a 1 no quadro que a rede leva —
     * a saída do codificador [s], que o divisor desenha **sem espelho** e na rotação congelada da sessão
     * (ou na da tela, na R5). O mesmo [CaminhoDoToque] da prévia, com a geometria da rede. Um toque numa
     * tarja é [ControlesDaCamera.PontoDaRede.ForaDaImagem]; `null` sem quadro ainda.
     */
    fun pontoDaRede(xn: Double, yn: Double, s: FilmadorDaCamera.SaidaDaRede): ControlesDaCamera.PontoDaRede? {
        val st = divisor.matrizDaCamera ?: return null
        val b = divisor.buffer ?: return null
        val troca = divisor.trocaEixos ?: return null
        if (s.largura <= 0 || s.altura <= 0) return null
        val (ln, an) = GeometriaDoDivisor.tamanhoNatural(b.width, b.height, troca)
        val p = CaminhoDoToque.pontoNoBuffer((xn * s.largura).toFloat(), (yn * s.altura).toFloat(), s.largura, s.altura,
            ln, an, s.rotacaoFixa ?: divisor.rotacaoDaTela,
            espelharNaTela = false, texturaEspelhada = divisor.matrizEspelhada == true, frontal = frontal, st = st)
            ?: return ControlesDaCamera.PontoDaRede.ForaDaImagem
        return ControlesDaCamera.PontoDaRede.NoBuffer(p.first, p.second)
    }

    /** A câmera entregou quadro nos últimos [ms] ms. */
    fun entregando(ms: Long): Boolean {
        val u = divisor.ultimaChegadaNs
        return u != 0L && System.nanoTime() - u <= ms * 1_000_000L
    }

    val estaFechado: Boolean get() = fechado

    /** Solta uma saída. Não toca na câmera. */
    fun desligar(s: DivisorGl.Saida) = divisor.desligar(s)

    /**
     * A superfície da prévia mudou: `null` quando a tela a perdeu (escondida, app em segundo plano).
     * Chamada por [PreviaDoDono], com a trava dele.
     */
    internal fun previaMudou(s: Surface?) {
        if (fechado) return
        // Ligar não espera a thread GL; soltar espera no máximo o desenho em curso (ver
        // `DivisorGl.definirPrevia`). A principal não fica mais segundos atrás dela (a revisão, M8).
        divisor.definirPrevia(s)
    }

    /** Fecha a câmera e o divisor. Idempotente; pode ser chamada de qualquer thread. */
    fun fechar() {
        if (!fechou.compareAndSet(false, true)) return
        PreviaDoDono.esquecer(this)
        ouvinteDeTela?.let { o ->
            runCatching { contexto.getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(o) }
        }
        ouvinteDeTela = null
        ouvinteFisico?.let { o -> principal.post { runCatching { o.disable() } } }
        ouvinteFisico = null
        // A câmera para de escrever antes de o divisor soltar a superfície dela. Na principal o
        // `unbind` roda direto: postar e esperar dali seria esperar por si mesmo.
        val soltar = Runnable {
            // Antes do `unbind`: devolve a câmera como encontrou (R9, §2.2). O interop fica guardado
            // por câmera no processo inteiro, e o da R5 vazaria para o espelhamento comum.
            controles?.aoFechar()
            runCatching { provider.unbind(videoCapture) }.onFailure { Log.w(TAG, "unbind: ${Log.erroExterno(it.message)}") }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            soltar.run()
        } else {
            val l = CountDownLatch(1)
            principal.post { soltar.run(); l.countDown() }
            // Interrompida (o `shutdownNow` do `onDestroy`, a revisão, menor 2): o divisor é liberado
            // assim mesmo — sem isso a thread GL vazava, e o `fechar` seguinte já voltava cedo.
            try {
                l.await(2, TimeUnit.SECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        divisor.liberar()
        Log.i(TAG, "câmera $cameraId $deQuem fechada: ${divisor.quadrosDaCamera} quadros, " +
            "buracos>${DivisorGl.BURACO_MS.toInt()}ms ${divisor.buracosDaCamera}")
    }
}

/**
 * O encontro entre a `SurfaceView` da tela (a R5, ou a tela inicial no espelhamento de câmera) e o
 * [DonoDaCaptura] do serviço. Os dois nascem e
 * morrem em ordens diferentes, como no [PreviaDaCamera] — e aqui **cada superfície tem dono**
 * (`docs/teleprompter-com-camera.md` §2.1): só quem ligou solta. Um `surfaceDestroyed` atrasado de
 * uma tela velha não apaga a prévia da tela nova.
 *
 * Tudo sob uma trava: ligar a superfície no divisor espera a thread GL (milissegundos), e fazer isso
 * dentro da trava é o que impede um `soltar` e um `registrar` cruzados de deixarem o divisor
 * desenhando numa superfície morta.
 */
object PreviaDoDono {
    private const val TAG = "QuallPreviaDoDono"
    private val trava = Any()
    private var superficie: Surface? = null
    private var quem: Any? = null
    private var dono: DonoDaCaptura? = null
    /** A prévia como espelho: ajuste local da tela, ligado por padrão (§6). */
    private var espelho = true

    /** A superfície é da tela R5 (e não da tela inicial). */
    private var superficieDaR5 = false

    /** O dono registrado é o da tela R5. */
    private var donoDaR5 = false

    /**
     * A superfície que o dono pode receber: só a da mesma tela (a revisão, menor 3). A tela R5 aberta
     * com a câmera no espelhamento comum não recebe a prévia dele, e a tela inicial não recebe a da R5.
     */
    private fun paraODono(): Surface? = superficie?.takeIf { superficieDaR5 == donoDaR5 }

    /** A tela entrega a superfície da prévia. [quem] é a própria tela; [daTelaR5], se é a tela R5. */
    fun ligar(s: Surface, quem: Any, daTelaR5: Boolean) = synchronized(trava) {
        superficie = s
        this.quem = quem
        superficieDaR5 = daTelaR5
        Log.i(TAG, "prévia: a tela ${if (daTelaR5) "R5" else "inicial"} entregou a superfície (válida=${s.isValid}); " +
            "dono ${dono?.let { if (donoDaR5) "da R5" else "da câmera comum" } ?: "ainda nenhum"}")
        dono?.previaMudou(paraODono())
    }

    /** A superfície de [quem] vai morrer. Espera o divisor parar de desenhar nela. */
    fun soltar(quem: Any) = synchronized(trava) {
        if (this.quem !== quem) return@synchronized
        superficie = null
        this.quem = null
        dono?.previaMudou(null)
    }

    /** O espelho da prévia fixado pelo dono registrado (a câmera comum), ou `null` (a tela R5: o ajuste). */
    private var espelhoFixo: Boolean? = null

    /**
     * O serviço registra o dono aberto; ele já recebe a superfície que houver. [espelhoFixo]: a
     * câmera comum espelha a prévia **só na frontal** (como a `PreviewView` do CameraX fazia), e o
     * ajuste da tela R5 não vale para ela; `null` na tela R5, que segue o ajuste.
     */
    fun registrar(d: DonoDaCaptura, espelhoFixo: Boolean?, daTelaR5: Boolean) = synchronized(trava) {
        dono = d
        donoDaR5 = daTelaR5
        this.espelhoFixo = espelhoFixo
        d.espelharPrevia = espelhoFixo ?: espelho
        Log.i(TAG, "prévia: dono ${if (daTelaR5) "da R5" else "da câmera comum"} registrado; superfície " +
            (superficie?.let { if (superficieDaR5 == daTelaR5) "da mesma tela (válida=${it.isValid})" else "de outra tela" } ?: "nenhuma"))
        d.previaMudou(paraODono())
    }

    /** A prévia está ligada no divisor do dono registrado e já desenhou (só leitura, para a tela). */
    val previaDesenhando: Boolean get() = synchronized(trava) { dono?.divisorGl?.previaLigada == true }

    /** O ajuste "Prévia espelhada" da tela R5. A rede nunca espelha, com ele ligado ou não. */
    fun espelhar(ligar: Boolean) = synchronized(trava) {
        espelho = ligar
        if (espelhoFixo == null) dono?.espelharPrevia = ligar
    }

    internal fun esquecer(d: DonoDaCaptura) = synchronized(trava) {
        if (dono === d) dono = null
    }
}
