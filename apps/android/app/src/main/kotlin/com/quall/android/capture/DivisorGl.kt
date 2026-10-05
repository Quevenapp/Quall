package com.quall.android.capture

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * **O divisor GL da tela R5** (`docs/teleprompter-com-camera.md` §2.1, braço a, e §8.2): a câmera
 * escreve numa `SurfaceTexture` nossa, e cada quadro é desenhado em cada saída ligada — a prévia da
 * tela, a rede e, na fase 3, a gravação. **Ligar e desligar uma saída não toca na câmera.**
 *
 * ## Por que existe, e o que a fase 0 mediu (S24, 24/09)
 *
 * - Prévia + dois `VideoCapture` no mesmo bind: **recusado** (frontal LIMITED). O caso do produto
 *   (rede e gravação saindo da mesma câmera) só sai por um fluxo único dividido aqui (S-A2).
 * - Ligar um codificador com o divisor sempre no ar: buraco na imagem **p50 47 ms**, e a câmera
 *   não fecha; o `rebind_junto` de hoje fecha a câmera 3/3 e deixa 468 ms de buraco (S-A4).
 * - **O carimbo explícito é obrigatório**: com `eglPresentationTimeANDROID(getTimestamp)` o PTS de
 *   saída é o carimbo da câmera em 900/900; sem ele, 0/900 — sai o instante da troca (S-A3).
 *
 * ## A prévia também sai daqui, e não de um `Preview` do CameraX
 *
 * O desenho dizia "uma `PreviewView`". Ela está fora por um motivo medido neste repositório
 * (`docs/bancada.md` §8.65, e a doc de `CameraXSource.ligarCodificador`): a superfície de uma
 * `PreviewView` morre e renasce quando o app sai e volta, e o CameraX responde **refazendo a sessão
 * de captura** — 280 ms, com o codificador parando junto, porque ele está na mesma sessão. Com o
 * divisor, a rede **é** a mesma sessão de captura da prévia; um `Preview` bindado ali faria cada
 * volta ao app cortar a transmissão. Desenhando a prévia aqui, a câmera tem **um** use case, a
 * superfície da tela vem e vai sem a câmera saber, e esconder a prévia é só parar de desenhar nela.
 * De quebra o espelho da prévia é uma linha de shader, e a tela gira sem mexer na câmera.
 *
 * Tudo que toca GL roda na thread deste objeto. Nenhuma exceção sai de lá: um erro de uma saída é
 * contado e registrado, e as outras continuam.
 */
class DivisorGl(
    nome: String,
    /**
     * **A câmera pelo mais novo** (§14.11, conserto 1): a thread GL, ao acordar, pega o quadro mais
     * novo da `SurfaceTexture` e pula os que se acumularam, em vez de desenhar um por um, velhos. `false`
     * é o controle de bancada (`camera_pelo_mais_novo`): um quadro por aviso, como era.
     */
    private val pelaMaisNova: Boolean = false,
    /**
     * **A bandeira de bancada `luma_media`** (R9, `docs/controles-de-camera.md` §5): um quadro a cada
     * [LumaMedia.A_CADA] é desenhado num FBO de 16 × 16 e lido (1 KB), e a luma média vai ao diário com
     * o fps da câmera e o custo. Desligada no produto.
     */
    private val lumaMedia: Boolean = false,
) {

    companion object {
        private const val TAG = "QuallDivisor"
        private const val EGL_RECORDABLE_ANDROID = 0x3142

        /** Um intervalo entre quadros acima disto é buraco, contado e registrado (a prova da fase 1). */
        const val BURACO_MS = 100.0

        /** Quanto o `surfaceDestroyed` da prévia espera o desenho em curso nela. */
        private const val PRAZO_DA_PREVIA_MS = 500L

        /** De quanto em quanto tempo sai a linha de contagem. */
        private const val RELATO_A_CADA_NS = 5_000_000_000L

        /** A idade do quadro ao desenhar só entra no relato abaixo disto (o relógio da câmera pode ser outro). */
        private const val IDADE_PLAUSIVEL_NS = 2_000_000_000L
    }

    enum class Tipo { CODIFICADOR, PREVIA }

    /**
     * Uma saída ligada. [largura]/[altura] são fixas para um codificador (a superfície dele tem
     * tamanho fixo); na prévia valem 0 e o tamanho é lido da superfície a cada quadro, porque a tela
     * gira sem a superfície ser trocada.
     */
    inner class Saida internal constructor(
        val nome: String,
        val tipo: Tipo,
        internal val egl: EGLSurface,
        val largura: Int,
        val altura: Int,
        /**
         * A rotação da tela congelada para esta saída (`Surface.ROTATION_*`), ou `null` para seguir a
         * tela. **A gravação congela** (§5.2: um arquivo só, a orientação travada enquanto grava): o
         * quadro dela foi medido na rotação do toque em Gravar, e mesmo que a tela gire por baixo —
         * a trava da janela vale só com a tela R5 na frente — a imagem do arquivo não gira.
         */
        val rotacaoFixa: Int? = null,
        /**
         * Quantos quadros estão dentro do codificador, e a porta que os limita (§14.11): o
         * codificador anota o que sai, o divisor o que entra. `null` na prévia.
         */
        val fila: FilaDoCodificador? = null,
    ) {
        /** Falso a partir do pedido de desligar: o próximo quadro já não desenha nela. */
        @Volatile internal var ativa = true
        @Volatile var quadros = 0L; internal set
        @Volatile var falhasDoCarimbo = 0; internal set
        @Volatile var falhasDaTroca = 0; internal set
        internal var ultimaTrocaNs = 0L
        @Volatile var maiorIntervaloMs = 0.0; internal set
        @Volatile var buracos = 0; internal set
        /** Só a thread GL: a troca (`eglSwapBuffers`) mais demorada da janela do relato, em ns. */
        internal var maiorTrocaNaJanelaNs = 0L
        /** Só a thread GL: o último enquadramento que [relatarPrevia] escreveu. */
        internal var enquadramentoRelatado = ""
    }

    private val thread = HandlerThread(nome).apply { start() }
    val handler = Handler(thread.looper)

    /**
     * Onde a `SurfaceTexture` avisa quadro novo, com [pelaMaisNova]: esta thread só conta e agenda, e
     * a thread GL, ao acordar, pega o mais novo. No aviso direto à thread GL (como era), cada aviso
     * é uma mensagem na fila dela, e a fila não se sabe.
     */
    private val threadDoAviso: HandlerThread? = if (pelaMaisNova) HandlerThread("$nome-aviso").apply { start() } else null
    private val avisos = java.util.concurrent.atomic.AtomicInteger(0)
    private val agendado = java.util.concurrent.atomic.AtomicBoolean(false)
    private val processarAvisos = Runnable {
        // Zerado **antes** de ler (a revisão, 6): um aviso que chegar agora agenda outra volta, e
        // nunca fica um quadro contado a menos.
        agendado.set(false)
        val pedidos = avisos.getAndSet(0)
        if (pedidos > 0) chegou(pedidos)
    }

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var contexto: EGLContext = EGL14.EGL_NO_CONTEXT
    private lateinit var config: EGLConfig
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE

    private var textura = 0
    private lateinit var st: SurfaceTexture
    /** A superfície que a câmera recebe. Uma só pela vida do divisor. */
    lateinit var entrada: Surface
        private set
    private val matrizSt = FloatArray(16)
    private lateinit var programa: Programa

    private val saidas = CopyOnWriteArrayList<Saida>()
    @Volatile private var liberado = false
    private val jaLiberado = java.util.concurrent.atomic.AtomicBoolean(false)

    // --- o que o dono diz a cada quadro ------------------------------------------------------------

    /**
     * O tamanho do buffer que a câmera escreve (o do `SurfaceRequest`), num objeto só: largura e
     * altura lidas separadas por outra thread podiam sair de dois pedidos diferentes.
     */
    @Volatile var buffer: android.util.Size? = null; private set

    /** A câmera é frontal: a conta da rotação é feita na imagem espelhada ([GeometriaDoDivisor]). */
    @Volatile var frontal = true

    /** A rotação da tela agora (`Surface.ROTATION_*`), que o dono acompanha. */
    @Volatile var rotacaoDaTela = 0

    /** A prévia como espelho: ajuste local, ligado por padrão (§6). A rede nunca espelha. */
    @Volatile var espelharPrevia = true

    // --- o que o dono lê -----------------------------------------------------------------------------

    /** `null` até o primeiro quadro; depois, se a matriz da câmera troca os eixos. */
    @Volatile var trocaEixos: Boolean? = null; private set
    @Volatile var matrizEspelhada: Boolean? = null; private set

    /**
     * A matriz da `SurfaceTexture` do último quadro, **publicada para fora da thread GL** (R9,
     * `docs/controles-de-camera.md` §4.4, passo 4): o toque na prévia precisa dela para chegar ao
     * buffer. Uma cópia nova só quando muda; quem lê nunca vê um vetor pela metade.
     */
    @Volatile var matrizDaCamera: FloatArray? = null; private set
    @Volatile var quadrosDaCamera = 0L; private set
    @Volatile var ultimoCarimboNs = 0L; private set
    /** `System.nanoTime` da chegada do último quadro da câmera (0 antes do primeiro): a câmera caída se vê aqui. */
    @Volatile var ultimaChegadaNs = 0L; private set
    @Volatile var buracosDaCamera = 0; private set
    @Volatile var errosDaEntrada = 0; private set
    /** Quadros com o mesmo carimbo do anterior: não desenhados (um PTS repetido quebraria a rede). */
    @Volatile var carimbosRepetidos = 0L; private set

    /** A prévia: a pedida pela tela e a geração do pedido (ver [definirPrevia]). */
    private val geracaoDaPrevia = java.util.concurrent.atomic.AtomicLong(0)
    @Volatile private var saidaDaPrevia: Saida? = null

    /** Há prévia ligada e desenhando (só leitura, para a tela saber se o "Aguarde…" pode sair). */
    val previaLigada: Boolean get() = saidaDaPrevia?.let { it.ativa && it.quadros > 0 } == true

    private var maiorIntervaloDaCameraMs = 0.0
    /** Quadros da câmera pulados na entrada ([pelaMaisNova]): a thread GL estava atrás. Só a thread GL. */
    private var descartadosNaEntrada = 0L
    private var descartadosNoRelato = 0L
    /** A idade do quadro ao desenhar (`nanoTime − carimbo`), na janela do relato. Só a thread GL. */
    private val idadesNaJanela = ArrayList<Long>(200)
    private var idadesImplausiveis = 0L
    private var quadrosNoRelato = 0L
    private var inicioDoRelatoNs = 0L
    private var matrizRelatada: String? = null

    init {
        try {
            executar { iniciar() }
        } catch (t: Throwable) {
            // Sem isto a HandlerThread ficava viva sem ninguém para encerrá-la.
            thread.quitSafely()
            threadDoAviso?.quitSafely()
            throw t
        }
    }

    /**
     * Roda [bloco] na thread GL e espera, até [prazoMs]. Da própria thread, roda direto.
     *
     * **Quem desiste não deixa efeito para trás** (a revisão de 24/09, M2): estourado o prazo, o
     * bloco que ainda não começou não roda; o que terminou depois da desistência é desfeito por
     * [desfazer]. Sem isso, um `ligarCodificador` atrasado deixava uma saída órfã desenhando num
     * codificador que ninguém drena — que enche e prende a thread GL no `eglSwapBuffers`.
     */
    fun <T> executar(prazoMs: Long = 10_000, desfazer: ((T) -> Unit)? = null, bloco: () -> T): T {
        if (Looper.myLooper() == thread.looper) return bloco()
        check(thread.isAlive) { "a thread GL já saiu" }
        val trava = Any()
        var desistiu = false
        var r: Result<T>? = null
        val l = CountDownLatch(1)
        val postado = handler.post {
            if (synchronized(trava) { desistiu }) return@post
            val res = runCatching(bloco)
            synchronized(trava) {
                r = res
                if (desistiu) res.getOrNull()?.let { v -> runCatching { desfazer?.invoke(v) } }
                l.countDown()
            }
        }
        check(postado) { "a thread GL já saiu" }
        if (!l.await(prazoMs, TimeUnit.MILLISECONDS)) {
            synchronized(trava) {
                if (r == null) {
                    desistiu = true
                    throw IllegalStateException("a thread GL não respondeu em $prazoMs ms")
                }
            }
        }
        return r!!.getOrThrow()
    }

    private fun iniciar() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val v = IntArray(2)
        check(EGL14.eglInitialize(display, v, 0, v, 1)) { "eglInitialize falhou" }
        // RECORDABLE: o `MediaCodec` exige numa superfície de janela que vai a um codificador.
        val atrib = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val cfgs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        check(EGL14.eglChooseConfig(display, atrib, 0, cfgs, 0, 1, n, 0) && n[0] > 0) { "eglChooseConfig falhou" }
        config = cfgs[0]!!
        contexto = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(contexto != EGL14.EGL_NO_CONTEXT) { "eglCreateContext falhou" }
        pbuffer = EGL14.eglCreatePbufferSurface(
            display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
        )
        correntePbuffer()
        programa = Programa()

        val t = IntArray(1)
        GLES20.glGenTextures(1, t, 0)
        textura = t[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textura)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        st = SurfaceTexture(textura)
        val aviso = threadDoAviso
        if (aviso != null) {
            st.setOnFrameAvailableListener({
                avisos.incrementAndGet()
                if (agendado.compareAndSet(false, true)) handler.post(processarAvisos)
            }, Handler(aviso.looper))
        } else {
            st.setOnFrameAvailableListener({ chegou(1) }, handler)
        }
        entrada = Surface(st)
    }

    private fun correntePbuffer() {
        check(EGL14.eglMakeCurrent(display, pbuffer, pbuffer, contexto)) { "eglMakeCurrent(pbuffer) falhou" }
    }

    /**
     * O tamanho que a câmera vai escrever. Chamada a cada `SurfaceRequest` — inclusive o que o
     * CameraX emite sozinho ao reabrir a câmera depois de uma expulsão (a doc de
     * `CameraXSource.aoPedirSuperficie`). Uma geometria nova não é problema aqui: cada saída tem o
     * tamanho dela, e a conta é refeita por quadro.
     */
    fun ajustarBuffer(largura: Int, altura: Int) {
        // `setDefaultBufferSize` pode ser chamada de qualquer thread; só `updateTexImage` é da GL.
        st.setDefaultBufferSize(largura, altura)
        buffer = android.util.Size(largura, altura)
    }

    /**
     * Liga a superfície de entrada de um `MediaCodec`. Cada troca leva o carimbo da câmera.
     * [rotacaoFixa]: ver [Saida.rotacaoFixa] (a gravação); `null` segue a tela (a rede).
     */
    fun ligarCodificador(
        nome: String,
        superficie: Surface,
        largura: Int,
        altura: Int,
        rotacaoFixa: Int? = null,
        fila: FilaDoCodificador? = null,
    ): Saida =
        executar(3_000, desfazer = { s -> destruirAgora(s) }) {
            check(!liberado) { "o divisor já foi liberado" }
            val e = superficieDeJanela(superficie)
            Saida(nome, Tipo.CODIFICADOR, e, largura, altura, rotacaoFixa, fila).also {
                saidas.add(it)
                Log.i(TAG, "saída $nome ligada: ${largura}x$altura" +
                    (rotacaoFixa?.let { r -> ", rotação congelada em ${r * 90}°" } ?: "") + " (a câmera não foi tocada)")
            }
        }

    /**
     * A superfície da prévia (uma `SurfaceView` da tela), ou `null` quando ela vai morrer.
     *
     * **Ligar não espera**: vai para a fila da thread GL com a geração do pedido, e um pedido mais
     * novo (outro ligar, ou um soltar) anula o que ainda não rodou. A thread principal nunca fica
     * atrás da thread GL para mostrar a prévia (a revisão, M8).
     *
     * **Soltar espera pouco** ([PRAZO_DA_PREVIA_MS]): a saída deixa de receber quadro na hora
     * (`ativa` cai nesta thread); a espera é só pelo desenho que estiver em curso nela, porque a
     * superfície morre quando o `surfaceDestroyed` volta.
     *
     * A troca da prévia não espera o retraço (`eglSwapInterval 0`): ela nunca segura a thread que
     * alimenta a rede.
     */
    fun definirPrevia(superficie: Surface?) {
        val geracao = geracaoDaPrevia.incrementAndGet()
        saidaDaPrevia?.ativa = false
        val trocar = Runnable {
            if (geracao != geracaoDaPrevia.get() || liberado) {
                Log.i(TAG, "prévia: pedido $geracao passado por outro (${geracaoDaPrevia.get()}) ou divisor liberado ($liberado)")
                return@Runnable
            }
            saidaDaPrevia?.let { destruirAgora(it) }
            saidaDaPrevia = null
            if (superficie == null) return@Runnable
            if (!superficie.isValid) {
                // Dito, e não calado (a conferência de 28/09 no A07 viu a prévia da R5 nunca ligar sem
                // uma linha que dissesse por quê): a tela pede de novo (`PrompterComCameraActivity`).
                Log.w(TAG, "prévia: a superfície da tela não vale mais (pedido $geracao); espera outra")
                return@Runnable
            }
            try {
                val e = superficieDeJanela(superficie)
                EGL14.eglMakeCurrent(display, e, e, contexto)
                EGL14.eglSwapInterval(display, 0)
                correntePbuffer()
                saidaDaPrevia = Saida("previa", Tipo.PREVIA, e, 0, 0).also { saidas.add(it) }
                Log.i(TAG, "prévia ligada (a câmera não foi tocada)")
            } catch (t: Throwable) {
                Log.w(TAG, "a prévia não ligou: ${Log.erroExterno(t.message)}")
            }
        }
        if (Looper.myLooper() == thread.looper) { trocar.run(); return }
        if (!thread.isAlive) return
        if (superficie != null) {
            handler.post(trocar)
            return
        }
        val l = CountDownLatch(1)
        if (!handler.post { runCatching { trocar.run() }; l.countDown() }) return
        if (!l.await(PRAZO_DA_PREVIA_MS, TimeUnit.MILLISECONDS)) {
            Log.w(TAG, "a thread GL não soltou a prévia em $PRAZO_DA_PREVIA_MS ms; ela já não recebe quadro")
        }
    }

    /** Na thread GL: tira a saída da lista e destrói a superfície EGL dela. */
    private fun destruirAgora(s: Saida) {
        s.ativa = false
        if (!saidas.remove(s)) return
        runCatching { correntePbuffer() }
        runCatching { EGL14.eglDestroySurface(display, s.egl) }
        Log.i(TAG, "saída ${s.nome} desligada: ${s.quadros} quadros, maior intervalo " +
            "${fmt(s.maiorIntervaloMs)} ms, buracos>${BURACO_MS.toInt()}ms ${s.buracos}, " +
            "falhas de carimbo ${s.falhasDoCarimbo}, de troca ${s.falhasDaTroca}" +
            (s.fila?.let { f -> ", pulados pela porta ${f.pulados}, sondas ${f.sondas}" } ?: "") +
            " (a câmera não foi tocada)")
    }

    /**
     * Desliga uma saída **antes** de a superfície dela morrer: o `surfaceDestroyed` da tela e o
     * `pararFonte` do codificador esperam por isto. [ativa] cai já, na thread de quem chamou, e o
     * próximo quadro não desenha nela; a destruição da `EGLSurface` é na thread GL. Se a thread GL
     * estiver presa numa troca por mais de [prazoMs], quem chamou segue e a destruição sai depois.
     */
    fun desligar(s: Saida, prazoMs: Long = 2_000) {
        s.ativa = false
        if (Looper.myLooper() == thread.looper) { destruirAgora(s); return }
        if (!thread.isAlive) return
        val l = CountDownLatch(1)
        if (!handler.post { runCatching { destruirAgora(s) }; l.countDown() }) return
        if (!l.await(prazoMs, TimeUnit.MILLISECONDS)) {
            Log.w(TAG, "a thread GL não soltou a saída ${s.nome} em $prazoMs ms; ela já não recebe quadro e sai depois")
        }
    }

    private fun superficieDeJanela(s: Surface): EGLSurface {
        val e = EGL14.eglCreateWindowSurface(display, config, s, intArrayOf(EGL14.EGL_NONE), 0)
        check(e != null && e != EGL14.EGL_NO_SURFACE) {
            "eglCreateWindowSurface falhou: 0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        return e
    }

    // --- um quadro ---------------------------------------------------------------------------------

    /**
     * [pedidos] avisos de quadro novo desde a última volta: com [pelaMaisNova], a fila da
     * `SurfaceTexture` é andada até o fim (cada `updateTexImage` pega o próximo e solta o anterior,
     * sem desenhar) e só o último é desenhado. Um `updateTexImage` a mais do que havia não traz
     * quadro novo, e cai no teste do carimbo repetido abaixo.
     */
    private fun chegou(pedidos: Int) {
        if (liberado) return
        val chegada = System.nanoTime()
        try {
            for (i in 0 until pedidos) st.updateTexImage()
            if (pedidos > 1) descartadosNaEntrada += pedidos - 1
            st.getTransformMatrix(matrizSt)
            if (matrizDaCamera?.contentEquals(matrizSt) != true) matrizDaCamera = matrizSt.copyOf()
        } catch (t: Throwable) {
            errosDaEntrada++
            if (errosDaEntrada <= 3) Log.w(TAG, "updateTexImage: ${t.javaClass.simpleName}: ${Log.erroExterno(t.message)}")
            return
        }
        val carimbo = st.timestamp
        val anterior = ultimoCarimboNs
        if (anterior != 0L && carimbo == anterior) {
            // O mesmo quadro de novo (um `updateTexImage` que não trouxe buffer novo): desenhar
            // mandaria um PTS repetido à rede, e contar faria o fps mentir.
            carimbosRepetidos++
            return
        }
        ultimoCarimboNs = carimbo
        ultimaChegadaNs = chegada
        quadrosDaCamera++
        val idade = chegada - carimbo
        if (idade in 0..IDADE_PLAUSIVEL_NS) idadesNaJanela.add(idade) else idadesImplausiveis++
        contarChegada(chegada, if (anterior == 0L) 0L else carimbo - anterior)

        val troca = GeometriaDoDivisor.trocaEixos(matrizSt)
        val espelho = GeometriaDoDivisor.espelhada(matrizSt)
        if (trocaEixos != troca || matrizEspelhada != espelho) {
            trocaEixos = troca
            matrizEspelhada = espelho
        }
        relatarMatriz()
        val b = buffer ?: return
        val (ln, an) = GeometriaDoDivisor.tamanhoNatural(b.width, b.height, troca)
        val rot = rotacaoDaTela

        // Os codificadores primeiro: o carimbo deles é o que a rede e o arquivo levam, e a prévia
        // nunca pode atrasá-los.
        // A porta de cada codificador (§14.11): com o teto em trânsito, o quadro não entra nele.
        for (s in saidas) {
            if (!s.ativa || s.tipo != Tipo.CODIFICADOR) continue
            if (s.fila?.deveDesenhar(carimbo / 1000) == false) continue
            desenhar(s, ln, an, s.rotacaoFixa ?: rot, espelho, carimbo)
        }
        for (s in saidas) if (s.ativa && s.tipo == Tipo.PREVIA) desenhar(s, ln, an, rot, espelho, carimbo)
        runCatching { correntePbuffer() }
        if (lumaMedia && quadrosDaCamera % LumaMedia.A_CADA == 0L) medirLuma(carimbo)
    }

    // --- a luma média (bancada, R9) ------------------------------------------------------------------

    private var fbo = 0
    private var texturaDoFbo = 0
    private val pixelsDaLuma: ByteBuffer by lazy {
        ByteBuffer.allocateDirect(LumaMedia.LADO * LumaMedia.LADO * 4).order(ByteOrder.nativeOrder())
    }
    private val bytesDaLuma = ByteArray(LumaMedia.LADO * LumaMedia.LADO * 4)
    private var carimboDaUltimaLuma = 0L
    private var medidasDaLuma = 0L
    private var custoTotalDaLumaNs = 0L
    private var maiorCustoDaLumaNs = 0L

    /**
     * Desenha o quadro inteiro (a imagem natural, sem tarja nem espelho) no FBO de 16 × 16, lê os 1 KB e
     * registra `r9: luma_media=… fps=… custo_us=…`. O custo é o do desenho mais o `glReadPixels`, que
     * espera a GPU terminar: é o que esta medida tira da thread GL, a cada 30 quadros.
     */
    private fun medirLuma(carimbo: Long) {
        try {
            val inicio = System.nanoTime()
            if (fbo == 0) {
                val t = IntArray(1)
                GLES20.glGenTextures(1, t, 0)
                texturaDoFbo = t[0]
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texturaDoFbo)
                GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, LumaMedia.LADO, LumaMedia.LADO, 0,
                    GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
                val f = IntArray(1)
                GLES20.glGenFramebuffers(1, f, 0)
                fbo = f[0]
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
                GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, texturaDoFbo, 0)
                // Uma vez, para o diário: sem linha de luma, a prova diz se foi o FBO (e não a bandeira).
                val estado = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
                Log.i(TAG, "r9: luma_media ligada: FBO ${LumaMedia.LADO}x${LumaMedia.LADO}, estado 0x${Integer.toHexString(estado)}" +
                    if (estado == GLES20.GL_FRAMEBUFFER_COMPLETE) " (completo)" else " (INCOMPLETO)")
            } else {
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
            }
            programa.desenhar(textura, GeometriaDoDivisor.Afim.IDENTIDADE.mat4(), matrizSt, LumaMedia.LADO, LumaMedia.LADO)
            pixelsDaLuma.position(0)
            GLES20.glReadPixels(0, 0, LumaMedia.LADO, LumaMedia.LADO, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixelsDaLuma)
            val erro = GLES20.glGetError()
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            if (erro != GLES20.GL_NO_ERROR && medidasDaLuma < 3) Log.w(TAG, "r9: luma_media: erro GL 0x${Integer.toHexString(erro)}")
            pixelsDaLuma.position(0)
            pixelsDaLuma.get(bytesDaLuma)
            val custo = System.nanoTime() - inicio
            val luma = LumaMedia.de(bytesDaLuma)
            medidasDaLuma++
            custoTotalDaLumaNs += custo
            if (custo > maiorCustoDaLumaNs) maiorCustoDaLumaNs = custo
            val fps = if (carimboDaUltimaLuma == 0L) null else LumaMedia.fps(LumaMedia.A_CADA.toLong(), carimboDaUltimaLuma, carimbo)
            carimboDaUltimaLuma = carimbo
            Log.i(TAG, String.format(Locale.ROOT,
                "r9: luma_media=%.1f quadro=%d fps=%s custo_us=%d custo_medio_us=%d custo_maior_us=%d",
                luma, quadrosDaCamera, fps?.let { String.format(Locale.ROOT, "%.2f", it) } ?: "-",
                custo / 1000, custoTotalDaLumaNs / medidasDaLuma / 1000, maiorCustoDaLumaNs / 1000))
        } catch (t: Throwable) {
            runCatching { GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0) }
            Log.w(TAG, "r9: luma_media: ${t.javaClass.simpleName}: ${Log.erroExterno(t.message)}")
        }
    }

    private fun desenhar(s: Saida, ln: Int, an: Int, rot: Int, espelho: Boolean, carimbo: Long) {
        try {
            if (!EGL14.eglMakeCurrent(display, s.egl, s.egl, contexto)) {
                s.falhasDaTroca++
                return
            }
            val (w, h) = if (s.tipo == Tipo.PREVIA) {
                val v = IntArray(1)
                EGL14.eglQuerySurface(display, s.egl, EGL14.EGL_WIDTH, v, 0)
                val w = v[0]
                EGL14.eglQuerySurface(display, s.egl, EGL14.EGL_HEIGHT, v, 0)
                w to v[0]
            } else s.largura to s.altura
            if (w <= 0 || h <= 0) return
            val previa = s.tipo == Tipo.PREVIA
            // A prévia **encaixa** a imagem inteira, como a rede (a prova de 24/09 no S24): quem se
            // enquadra precisa ver o que o receptor vê. Cortando para preencher, em paisagem a
            // metade da tela mostrava só o meio do quadro, e o que o receptor via na borda sumia.
            if (previa) relatarPrevia(s, ln, an, rot, w, h)
            val m = GeometriaDoDivisor.matriz(
                ln, an, rot, w, h,
                preencher = false,
                espelharNaTela = previa && espelharPrevia,
                texturaEspelhada = espelho,
                frontal = frontal,
            )
            programa.desenhar(textura, m.mat4(), matrizSt, w, h)
            // O carimbo explícito é obrigatório (S-A3): sem ele o codificador carimba na troca.
            if (s.tipo == Tipo.CODIFICADOR && !EGLExt.eglPresentationTimeANDROID(display, s.egl, carimbo)) {
                s.falhasDoCarimbo++
            }
            val antesDaTroca = System.nanoTime()
            if (!EGL14.eglSwapBuffers(display, s.egl)) {
                s.falhasDaTroca++
                return
            }
            val agora = System.nanoTime()
            if (agora - antesDaTroca > s.maiorTrocaNaJanelaNs) s.maiorTrocaNaJanelaNs = agora - antesDaTroca
            s.fila?.desenhou(carimbo / 1000)
            if (s.ultimaTrocaNs != 0L) {
                val ms = (agora - s.ultimaTrocaNs) / 1e6
                if (ms > s.maiorIntervaloMs) s.maiorIntervaloMs = ms
                if (ms > BURACO_MS) {
                    s.buracos++
                    Log.w(TAG, "r5: buraco de ${fmt(ms)} ms na saída ${s.nome} (${s.buracos}º)")
                }
            }
            s.ultimaTrocaNs = agora
            s.quadros++
        } catch (t: Throwable) {
            s.falhasDaTroca++
            if (s.falhasDaTroca <= 3) Log.w(TAG, "saída ${s.nome}: ${t.javaClass.simpleName}: ${Log.erroExterno(t.message)}")
        }
    }

    /**
     * A contagem que a prova da fase 1 lê: o intervalo entre quadros **da câmera**, e uma linha a
     * cada 5 s. Um buraco aqui é a câmera que parou (o ciclo que o divisor existe para evitar); um
     * buraco numa saída e não aqui é o desenho que atrasou.
     */
    private fun contarChegada(agora: Long, deltaDoCarimboNs: Long) {
        // **Pelo carimbo da câmera, e não pela hora em que a thread GL acordou** (a revisão, M6):
        // uma thread GL atrasada não é a câmera parada. O atraso da thread aparece nos buracos das
        // saídas; o da câmera, aqui.
        if (deltaDoCarimboNs > 0) {
            val ms = deltaDoCarimboNs / 1e6
            if (ms > maiorIntervaloDaCameraMs) maiorIntervaloDaCameraMs = ms
            if (ms > BURACO_MS) {
                buracosDaCamera++
                Log.w(TAG, "r5: buraco de ${fmt(ms)} ms na câmera (${buracosDaCamera}º, pelo carimbo)")
            }
        }
        if (inicioDoRelatoNs == 0L) inicioDoRelatoNs = agora
        quadrosNoRelato++
        val dt = agora - inicioDoRelatoNs
        if (dt >= RELATO_A_CADA_NS) {
            val fps = quadrosNoRelato * 1e9 / dt
            idadesNaJanela.sort()
            val idade = if (idadesNaJanela.isEmpty()) "-" else
                "${fmt(idadesNaJanela[idadesNaJanela.size / 2] / 1e6)}/${fmt(idadesNaJanela.last() / 1e6)}"
            // A idade é `nanoTime − carimbo`: a latência da câmera até o divisor quando o carimbo é
            // `MONOTONIC`; noutro relógio sai fora da faixa e conta como "fora do relógio".
            Log.i(TAG, "r5: câmera ${fmt(fps, 1)} fps, maior intervalo ${fmt(maiorIntervaloDaCameraMs)} ms, " +
                "buracos>${BURACO_MS.toInt()}ms ${buracosDaCamera} (total), carimbos repetidos $carimbosRepetidos, " +
                "buffer ${buffer?.let { "${it.width}x${it.height}" } ?: "?"}, " +
                "rotação ${rotacaoDaTela * 90}°, " +
                "descartados_na_entrada=${descartadosNaEntrada - descartadosNoRelato} (${if (pelaMaisNova) "pelo mais novo" else "um por aviso"}), " +
                "idade_ms p50/max=$idade${if (idadesImplausiveis > 0) " (fora do relógio: $idadesImplausiveis)" else ""}, saídas " +
                saidas.filter { it.ativa }.joinToString(", ") { s ->
                    "${s.nome}=${s.quadros}" + (s.fila?.let { f ->
                        " [${f.linhaDaJanela()} troca_max_ms=${fmt(s.maiorTrocaNaJanelaNs / 1e6)}]"
                    } ?: "")
                }.ifEmpty { "nenhuma" })
            for (s in saidas) s.maiorTrocaNaJanelaNs = 0
            descartadosNoRelato = descartadosNaEntrada
            idadesNaJanela.clear()
            idadesImplausiveis = 0
            quadrosNoRelato = 0
            inicioDoRelatoNs = agora
            maiorIntervaloDaCameraMs = 0.0
        }
    }

    /**
     * O enquadramento da prévia, uma vez e a cada mudança de tamanho ou de giro: onde a imagem
     * inteira cai dentro dela. É o que a prova confere contra o quadro da rede.
     */
    private fun relatarPrevia(s: Saida, ln: Int, an: Int, rot: Int, w: Int, h: Int) {
        val chave = "$ln x $an r$rot ${w}x$h"
        if (chave == s.enquadramentoRelatado) return
        s.enquadramentoRelatado = chave
        val (lt, at) = GeometriaDoDivisor.tamanhoNaTela(ln, an, rot)
        val a = GeometriaDoDivisor.areaDaImagem(lt, at, w, h)
        Log.i(TAG, "r5: prévia ${w}x$h, imagem ${lt}x$at inteira em x=${a.x} y=${a.y} ${a.largura}x${a.altura} " +
            "(encaixe com tarjas, o mesmo enquadramento da rede)")
    }

    /** A matriz da câmera, uma vez e a cada mudança: é o que diz se a conta do espelho e da rotação vale. */
    private fun relatarMatriz() {
        val m = matrizSt
        val txt = String.format(Locale.ROOT, "[%.2f %.2f; %.2f %.2f | %.2f %.2f]", m[0], m[4], m[1], m[5], m[12], m[13])
        if (txt == matrizRelatada) return
        matrizRelatada = txt
        Log.i(TAG, "r5: matriz da câmera $txt, troca eixos=${trocaEixos}, espelhada=${matrizEspelhada} " +
            "(a rede sai sem espelho; a prévia espelha pelo ajuste local)")
    }

    /** Solta tudo. Chame depois de a câmera parar de escrever na [entrada]. */
    /**
     * Solta tudo. Chame depois de a câmera parar de escrever na [entrada]. A limpeza vai para a
     * fila da thread GL **sempre** (e `quitSafely` a roda antes de a thread sair), mesmo que ela
     * esteja presa: quem chama espera no máximo 1 s, e da principal não espera.
     */
    fun liberar() {
        if (!jaLiberado.compareAndSet(false, true)) return
        liberado = true
        val fim = CountDownLatch(1)
        val limpar = Runnable {
            try {
                for (s in saidas) runCatching { EGL14.eglDestroySurface(display, s.egl) }
                saidas.clear()
                saidaDaPrevia = null
                runCatching { st.setOnFrameAvailableListener(null) }
                runCatching { st.release() }
                // Depois do ouvinte e da `SurfaceTexture` (a revisão, 6): nenhum aviso mais chega.
                runCatching { threadDoAviso?.quitSafely() }
                runCatching { entrada.release() }
                runCatching { GLES20.glDeleteTextures(1, intArrayOf(textura), 0) }
                if (fbo != 0) runCatching {
                    GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
                    GLES20.glDeleteTextures(1, intArrayOf(texturaDoFbo), 0)
                }
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                EGL14.eglDestroySurface(display, pbuffer)
                EGL14.eglDestroyContext(display, contexto)
                EGL14.eglTerminate(display)
            } catch (t: Throwable) {
                Log.w(TAG, "liberar: ${Log.erroExterno(t.message)}")
            } finally {
                fim.countDown()
            }
        }
        if (Looper.myLooper() == thread.looper) {
            limpar.run()
        } else if (handler.post(limpar) && Looper.myLooper() != Looper.getMainLooper()) {
            runCatching { fim.await(1, TimeUnit.SECONDS) }
        }
        thread.quitSafely()
        // Também fora do `limpar` (a revisão do código, 7): se o `post` falhou, ela não vaza. Um aviso
        // que ainda chegue só tenta um `post` numa thread que saiu, e cai.
        threadDoAviso?.quitSafely()
    }

    private fun fmt(v: Double, casas: Int = 0) = String.format(Locale.ROOT, "%.${casas}f", v)

    /**
     * O desenho: a matriz afim da saída (`uN`, de [GeometriaDoDivisor.matriz]) leva o quadrado ao
     * ponto da imagem natural; fora de [0,1]² é tarja preta; dentro, a matriz da `SurfaceTexture`
     * leva à textura. `highp` onde houver: 1080 linhas em `mediump` já borram.
     */
    private class Programa {
        private val id: Int
        private val aPos: Int
        private val aTex: Int
        private val uN: Int
        private val uSt: Int
        private val vertices: FloatBuffer = buffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
        private val coords: FloatBuffer = buffer(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))

        init {
            val vs = compilar(GLES20.GL_VERTEX_SHADER, """
                attribute vec4 aPos;
                attribute vec4 aTex;
                uniform mat4 uN;
                varying vec2 vN;
                void main() { gl_Position = aPos; vN = (uN * aTex).xy; }
            """.trimIndent())
            val fs = compilar(GLES20.GL_FRAGMENT_SHADER, """
                #extension GL_OES_EGL_image_external : require
                #ifdef GL_FRAGMENT_PRECISION_HIGH
                precision highp float;
                #else
                precision mediump float;
                #endif
                varying vec2 vN;
                uniform mat4 uSt;
                uniform samplerExternalOES s;
                void main() {
                    if (vN.x < 0.0 || vN.x > 1.0 || vN.y < 0.0 || vN.y > 1.0) {
                        gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
                    } else {
                        gl_FragColor = texture2D(s, (uSt * vec4(vN, 0.0, 1.0)).xy);
                    }
                }
            """.trimIndent())
            id = GLES20.glCreateProgram()
            GLES20.glAttachShader(id, vs)
            GLES20.glAttachShader(id, fs)
            GLES20.glLinkProgram(id)
            val ok = IntArray(1)
            GLES20.glGetProgramiv(id, GLES20.GL_LINK_STATUS, ok, 0)
            check(ok[0] == GLES20.GL_TRUE) { "link: ${GLES20.glGetProgramInfoLog(id)}" }
            aPos = GLES20.glGetAttribLocation(id, "aPos")
            aTex = GLES20.glGetAttribLocation(id, "aTex")
            uN = GLES20.glGetUniformLocation(id, "uN")
            uSt = GLES20.glGetUniformLocation(id, "uSt")
        }

        fun desenhar(textura: Int, n: FloatArray, st: FloatArray, largura: Int, altura: Int) {
            GLES20.glViewport(0, 0, largura, altura)
            GLES20.glUseProgram(id)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textura)
            GLES20.glUniformMatrix4fv(uN, 1, false, n, 0)
            GLES20.glUniformMatrix4fv(uSt, 1, false, st, 0)
            GLES20.glEnableVertexAttribArray(aPos)
            GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, vertices)
            GLES20.glEnableVertexAttribArray(aTex)
            GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 0, coords)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        }

        private fun compilar(tipo: Int, fonte: String): Int {
            val s = GLES20.glCreateShader(tipo)
            GLES20.glShaderSource(s, fonte)
            GLES20.glCompileShader(s)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] == GLES20.GL_TRUE) { "shader: ${GLES20.glGetShaderInfoLog(s)}" }
            return s
        }

        private fun buffer(v: FloatArray): FloatBuffer =
            ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(v); position(0) }
    }
}
