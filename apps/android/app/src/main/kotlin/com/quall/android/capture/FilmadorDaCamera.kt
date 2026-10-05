package com.quall.android.capture

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.quall.android.core.LogSeguro as Log
import com.quall.android.core.QuallNative
import com.quall.android.teleprompter.JsonSimples

/**
 * **O filmador do controle remoto da câmera** (R9b, `docs/controle-remoto-da-camera.md` §6 e §12): o
 * `QuallCameraHost` deste aparelho, ligado aos [ControlesDaCamera] do dono aberto.
 *
 * - **Um por processo**, criado sob demanda e nunca liberado. No Android só há um [DonoDaCaptura] por vez
 *   (`MirrorService.donoDaCaptura`): a câmera comum e a R5 nunca estão abertas juntas, e o filmador segue
 *   o dono aberto com `set_camera` a cada abertura e `set_camera(null, null)` a cada fechamento — o que o
 *   contrato pede de quem troca de câmera (§7.2, §7.3). A `epoca` fica a mesma enquanto o app vive.
 * - **A opção "Permitir controle remoto da câmera"**, desligada por padrão, mora em SharedPreferences
 *   [PREFERENCIAS] e entra por `set_allowed` ao criar e a cada mudança ([permitir]).
 * - **Um consumidor só** da fila de pedidos (§6, achado I5): a thread principal, que já é a fila serial de
 *   tudo o que muda o registro (o painel, o toque, a câmera que reabre). Cada bombeada que vê o bit
 *   [QuallNative.MudouNoFilmador.PEDIDO] posta um "esvazie a fila"; o esvaziamento chama `next_request` até
 *   a fila acabar e trata um pedido por vez.
 * - **As bombeadas** são das sessões de vídeo da câmera (`MirrorService`, a thread `quall-mirror-camera`),
 *   com o `QuallMessages` de cada uma ([bombear]).
 */
object FilmadorDaCamera {
    private const val TAG = "QuallCameraRemota"
    const val PREFERENCIAS = "quall-camera-remota"
    private const val CHAVE_PERMITIR = "permitir"

    private val principal = Handler(Looper.getMainLooper())
    private val trava = Any()
    @Volatile private var host = 0L

    /**
     * **O filmador das sessões sem câmera** (a tela, o DVD, a placa): nunca recebe `set_camera`, então os
     * receptores delas ficam em `sem_camera` (contrato §9) em vez de `sem_resposta`, e não se expõe a
     * câmera do dono a quem recebe a tela. Mesma opção que o de câmera.
     */
    @Volatile private var hostSemCamera = 0L

    /** Os controles do dono aberto agora (na principal). */
    private var atuaisRef: java.lang.ref.WeakReference<ControlesDaCamera>? = null

    /** Fraca: o objeto vive o processo inteiro, e os controles seguram a `Camera` do CameraX. */
    private var atuais: ControlesDaCamera?
        get() = atuaisRef?.get()
        set(v) { atuaisRef = v?.let { java.lang.ref.WeakReference(it) } }
    private var capacidadesPublicadas: String? = null
    private var lidoPublicado: String? = null
    private var esvaziamentoPostado = false

    /** A saída da rede da sessão de câmera: o toque do receptor é um ponto **deste** quadro. */
    data class SaidaDaRede(val largura: Int, val altura: Int, val rotacaoFixa: Int?)

    @Volatile var saidaDaRede: SaidaDaRede? = null

    /** A opção, como está guardada (desligada por padrão). */
    fun permitido(c: Context): Boolean = prefs(c).getBoolean(CHAVE_PERMITIR, false)

    /** Liga ou desliga a opção: guarda e avisa o núcleo (que recusa o que está na fila, §6). */
    fun permitir(c: Context, sim: Boolean) {
        prefs(c).edit().putBoolean(CHAVE_PERMITIR, sim).apply()
        val h = garantir(c)
        if (h != 0L) QuallNative.cameraHostSetAllowed(h, sim)
        hostSemCamera.takeIf { it != 0L }?.let { QuallNative.cameraHostSetAllowed(it, sim) }
        Log.i(TAG, "r9b: controle remoto da câmera ${if (sim) "permitido" else "desligado"}")
    }

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFERENCIAS, Context.MODE_PRIVATE)

    /** O handle, criado na primeira vez (com a opção salva). `0` sem núcleo. */
    private fun garantir(c: Context): Long {
        host.takeIf { it != 0L }?.let { return it }
        if (!QuallNative.carregado) return 0L
        synchronized(trava) {
            if (host == 0L) {
                val h = QuallNative.cameraHostNew()
                if (h != 0L) {
                    QuallNative.cameraHostSetAllowed(h, permitido(c))
                    host = h
                }
            }
            return host
        }
    }

    private fun garantirSemCamera(c: Context): Long {
        hostSemCamera.takeIf { it != 0L }?.let { return it }
        if (!QuallNative.carregado) return 0L
        synchronized(trava) {
            if (hostSemCamera == 0L) {
                val h = QuallNative.cameraHostNew()
                if (h != 0L) {
                    QuallNative.cameraHostSetAllowed(h, permitido(c))
                    hostSemCamera = h
                }
            }
            return hostSemCamera
        }
    }

    // --- a câmera em uso (na principal) -------------------------------------------------------------

    /** A câmera abriu (os controles aplicaram o registro): publica as capacidades e o registro. */
    fun cameraAbriu(c: Context, controles: ControlesDaCamera) {
        val h = garantir(c)
        if (h == 0L) return
        atuais = controles
        val caps = controles.capacidadesRemotas()
        capacidadesPublicadas = caps
        lidoPublicado = null
        val st = QuallNative.cameraHostSetCamera(h, caps, controles.ajuste.paraJson())
        Log.i(TAG, "r9b: câmera ${controles.cameraId} no filmador (${caps.length} bytes de capacidades): ${QuallNative.Status.nome(st)}")
    }

    /** A câmera fechou: sem câmera (`camera` 0), e os receptores escondem o painel. */
    fun cameraFechou(controles: ControlesDaCamera) {
        if (atuais !== controles) return
        atuais = null
        capacidadesPublicadas = null
        val h = host
        if (h != 0L) QuallNative.cameraHostSetCamera(h, null, null)
        Log.i(TAG, "r9b: câmera ${controles.cameraId} fechada no filmador")
    }

    /** O registro mudou **aqui** (o painel, o toque na prévia): `set_settings(json, 0)`. */
    fun mudouAqui(controles: ControlesDaCamera) {
        val h = host
        if (h == 0L || atuais !== controles) return
        QuallNative.cameraHostSetSettings(h, controles.ajuste.paraJson(), 0L)
    }

    /**
     * O tique do lido (no máximo 4 por segundo): o lido, e as capacidades de novo quando as faixas
     * mudaram (o teto do obturador segue o fps, que só se sabe depois do primeiro pedido de superfície).
     */
    fun tique(controles: ControlesDaCamera, lido: String) {
        val h = host
        if (h == 0L || atuais !== controles) return
        val caps = controles.capacidadesRemotas()
        if (caps != capacidadesPublicadas) {
            capacidadesPublicadas = caps
            val st = QuallNative.cameraHostSetCapabilities(h, caps)
            Log.i(TAG, "r9b: faixas novas da câmera ${controles.cameraId} (fps ${controles.fpsAgora()}): ${QuallNative.Status.nome(st)}")
        }
        if (lido != lidoPublicado) {
            lidoPublicado = lido
            QuallNative.cameraHostSetRead(h, lido)
        }
    }

    /** O estado do filmador de câmera (contrato §11.1), para o diário e a bancada; vazio sem núcleo. */
    fun estadoJson(): String = host.takeIf { it != 0L }?.let { QuallNative.cameraHostStateJson(it) }.orEmpty()

    /** "Controlado por <aparelho>" (contrato §6): o nome, enquanto `controlado_por` não for nulo. */
    fun controladoPor(): String? {
        val h = host
        if (h == 0L) return null
        val o = JsonSimples.objeto(QuallNative.cameraHostStateJson(h)) ?: return null
        return ((o["controlado_por"] as? Map<*, *>)?.get("nome") as? String)?.takeIf { it.isNotBlank() }
    }

    // --- as sessões ----------------------------------------------------------------------------------

    /**
     * **A bombeada de uma sessão de vídeo**, da thread dela: até a sessão acabar ([continuar] falso, ou o
     * `CLOSED` da bombeada). No fim, `forget` (a vaga sai na hora). Quem chama libera o [mensagens] depois.
     * [comCamera]: a sessão transmite a câmera do dono; senão, o filmador sem câmera.
     */
    fun bombear(c: Context, mensagens: Long, comCamera: Boolean, continuar: () -> Boolean) {
        val h = if (comCamera) garantir(c) else garantirSemCamera(c)
        if (h == 0L || mensagens == 0L) return
        Log.i(TAG, "r9b: bombeando a sessão ${if (comCamera) "de câmera" else "sem câmera"}")
        try {
            while (continuar()) {
                val b = QuallNative.cameraHostBombear(h, mensagens, 100)
                if (b.mudou and QuallNative.MudouNoFilmador.PEDIDO != 0) {
                    if (comCamera) postarEsvaziamento() else recusarTudo(h)
                }
                if (b.mudou and QuallNative.MudouNoFilmador.RECEPTORES != 0) {
                    Log.i(TAG, "r9b: os receptores mudaram (status=${QuallNative.Status.nome(b.status)})")
                }
                if (b.status == QuallNative.Status.CLOSED) break
                if (b.status != QuallNative.Status.OK) {
                    Log.w(TAG, "r9b: a bombeada devolveu ${QuallNative.Status.nome(b.status)}")
                    Thread.sleep(100)
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            QuallNative.cameraHostForget(h, mensagens)
            Log.i(TAG, "r9b: sessão de câmera esquecida pelo filmador")
        }
    }

    /** O filmador sem câmera não aceita pedido (o núcleo já recusa com `sem_camera`); se algum passar, cai aqui. */
    private fun recusarTudo(h: Long) {
        val estado = IntArray(1)
        while (true) {
            val json = QuallNative.cameraHostNextRequest(h, estado) ?: break
            PedidoRemoto.ler(json)?.let { QuallNative.cameraHostReject(h, it.n, "sem_camera") }
        }
    }

    private fun postarEsvaziamento() {
        synchronized(trava) {
            if (esvaziamentoPostado) return
            esvaziamentoPostado = true
        }
        principal.post {
            synchronized(trava) { esvaziamentoPostado = false }
            esvaziar()
        }
    }

    /** O consumidor único: `next_request` até a fila acabar, um pedido por vez, na principal. */
    private fun esvaziar() {
        val h = host
        if (h == 0L) return
        val estado = IntArray(1)
        while (true) {
            val json = QuallNative.cameraHostNextRequest(h, estado) ?: break
            val p = PedidoRemoto.ler(json)
            if (p == null) {
                Log.w(TAG, "r9b: pedido ilegível da fila (json_chars=${json.length})")
                continue
            }
            tratar(h, p)
        }
        if (estado[0] < 0) Log.w(TAG, "r9b: next_request: ${QuallNative.Status.nome(-estado[0])}")
    }

    private fun tratar(h: Long, p: PedidoRemoto) {
        val c = atuais
        if (c == null) {
            QuallNative.cameraHostReject(h, p.n, "nao_aplicado")
            return
        }
        val r = runCatching { c.aplicarPedidoRemoto(p, saidaDaRede) }.getOrElse {
            Log.e(TAG, "r9b: o pedido ${p.n} falhou", it)
            ControlesDaCamera.ResultadoRemoto.Recusado("nao_aplicado")
        }
        when (r) {
            is ControlesDaCamera.ResultadoRemoto.Aplicado -> {
                val st = QuallNative.cameraHostSetSettings(h, r.registro, p.n)
                Log.i(TAG, "r9b: pedido ${p.n} aplicado: ${QuallNative.Status.nome(st)}")
            }
            is ControlesDaCamera.ResultadoRemoto.Recusado -> {
                QuallNative.cameraHostReject(h, p.n, r.motivo)
                Log.i(TAG, "r9b: pedido ${p.n} recusado: ${r.motivo}")
            }
        }
    }
}
