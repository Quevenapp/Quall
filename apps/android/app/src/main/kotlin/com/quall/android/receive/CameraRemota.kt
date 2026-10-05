package com.quall.android.receive

import com.quall.android.R
import com.quall.android.capture.AjusteDaCamera
import com.quall.android.core.QuallNative
import com.quall.android.core.Textos
import com.quall.android.teleprompter.JsonSimples

/**
 * **O estado do controle da câmera do outro lado**, lido do `quall_camera_remote_state_json` (contrato
 * `docs/controle-remoto-da-camera.md` §11.1). Puro: provado na JVM contra o JSON literal do contrato.
 */
data class EstadoDaCameraRemota(
    /** `esperando`, `sem_resposta`, `sem_camera`, `nao_permitido` ou `pronto`. */
    val situacao: String = ESPERANDO,
    /** As capacidades do contrato §3.2, como vieram (`null` antes de chegarem). */
    val capacidades: Map<String, Any?>? = null,
    /** O texto das capacidades, para saber quando mudaram sem comparar mapas a cada tique. */
    val capacidadesJson: String? = null,
    /** O aplicado com o pendente por cima: é o que o painel mostra. */
    val ajuste: AjusteDaCamera? = null,
    val lido: Lido = Lido(),
    val autor: String? = null,
    val recusa: Recusa? = null,
) {
    data class Lido(
        val iso: Int? = null,
        val obturadorNs: Long? = null,
        val kelvin: Int? = null,
        val abertura: Float? = null,
        val focoPosicao: Double? = null,
        val divergentes: List<String> = emptyList(),
    )

    data class Recusa(val motivo: String, val campo: String?)

    /** Os controles aparecem (vivos em `pronto`, apagados em `nao_permitido`); nas outras situações, não. */
    val mostraControles: Boolean get() = (situacao == PRONTO || situacao == NAO_PERMITIDO) && capacidades != null && ajuste != null
    val vivo: Boolean get() = situacao == PRONTO

    companion object {
        const val ESPERANDO = "esperando"
        const val SEM_RESPOSTA = "sem_resposta"
        const val SEM_CAMERA = "sem_camera"
        const val NAO_PERMITIDO = "nao_permitido"
        const val PRONTO = "pronto"

        /** `null` se o texto não é o estado (vazio em falha do JNI: quem chama mantém o que tinha). */
        fun ler(json: String): EstadoDaCameraRemota? {
            if (json.isBlank()) return null
            val o = JsonSimples.objeto(json) ?: return null
            val situacao = o["situacao"] as? String ?: return null
            @Suppress("UNCHECKED_CAST")
            val caps = o["capacidades"] as? Map<String, Any?>
            @Suppress("UNCHECKED_CAST")
            val ajuste = (o["ajuste"] as? Map<String, Any?>)?.let { AjusteDaCamera.deMapa(it) }
            val l = o["lido"] as? Map<*, *>
            fun n(k: String): Double? = (l?.get(k) as? Double)?.takeIf { it.isFinite() }
            val lido = Lido(
                iso = n("iso")?.let { Math.round(it).toInt() },
                obturadorNs = n("obturadorNs")?.let { Math.round(it) },
                kelvin = n("kelvin")?.let { Math.round(it).toInt() },
                abertura = n("abertura")?.toFloat(),
                focoPosicao = n("focoPosicao"),
                divergentes = (l?.get("divergentes") as? List<*>)?.mapNotNull { it as? String }.orEmpty(),
            )
            val r = o["recusa"] as? Map<*, *>
            val recusa = (r?.get("motivo") as? String)?.let { Recusa(it, r["campo"] as? String) }
            return EstadoDaCameraRemota(situacao, caps, caps?.let { capsTexto(it) }, ajuste, lido, o["autor"] as? String, recusa)
        }

        /** Uma assinatura estável das capacidades (o mapa do [JsonSimples] preserva a ordem). */
        private fun capsTexto(m: Map<String, Any?>): String = m.toString()

        /** O nome do campo do ajuste dentro da frase da recusa ("Este aparelho não aceitou {controle}."). */
        private fun nomeDoCampo(campo: String?): Int = when (campo) {
            "exposicao" -> R.string.cam_nome_exposicao
            "ev" -> R.string.cam_nome_ev
            "travaExposicao" -> R.string.cam_nome_trava_exposicao
            "iso" -> R.string.cam_nome_iso
            "obturadorNs" -> R.string.cam_nome_obturador
            "antiCintilacao" -> R.string.cam_nome_anti_cintilacao
            "balanco" -> R.string.cam_nome_balanco
            "kelvin" -> R.string.cam_nome_kelvin
            "travaBalanco" -> R.string.cam_nome_trava_balanco
            "foco" -> R.string.cam_nome_foco
            "focoPosicao" -> R.string.cam_nome_foco_manual
            "toque" -> R.string.cam_nome_toque
            else -> R.string.cam_nome_ajuste
        }

        /**
         * **A linha da recusa** (contrato §3.5, a coluna "o receptor mostra"), ou `null` quando o motivo
         * não mostra nada (`superado`, `ocupado`, `camera_trocada`…). Um código que esta build não conhece
         * é mostrado como `nao_aplicado`.
         */
        fun fraseDaRecusa(t: Textos, r: Recusa): String? = when (r.motivo) {
            "nao_permitido" -> t.s(R.string.cam_remoto_nao_permitido)
            "campo_desconhecido", "fora_da_faixa", "incoerente" -> t.s(R.string.cam_remoto_nao_aceitou, t.s(nomeDoCampo(r.campo)))
            "sem_resposta" -> t.s(R.string.cam_remoto_nao_respondeu)
            "nao_pareado", "sem_camera", "camera_trocada", "superado", "ocupado", "invalido", "fora_da_imagem" -> null
            else -> t.s(R.string.cam_remoto_nao_aplicou)
        }
    }
}

/**
 * **A bombeada do controle da câmera numa sessão de recepção** (R9b): o `QuallCameraRemote` e as
 * mensagens da sessão, e a thread que os bombeia (100 ms por volta) e publica o estado no
 * [CameraRemotaBus] a cada mudança. [fechar] para a thread, espera por ela, e só então libera o controle
 * (sob a trava do bus) e as mensagens.
 */
class ControleDaCameraRemota private constructor(
    private val remoto: Long,
    private val mensagens: Long,
    private val continuar: () -> Boolean,
) {
    @Volatile private var parar = false
    private val thread = kotlin.concurrent.thread(name = "quall-receptor-camera", isDaemon = true) { rodar() }

    private fun rodar() {
        CameraRemotaBus.definir(remoto)
        var ultimo = ""
        try {
            while (!parar && continuar()) {
                val b = QuallNative.cameraRemoteBombear(remoto, mensagens, 100)
                // O estado se relê também sem bit: a recusa some sozinha depois de 3 s (`ha_ms`).
                val json = QuallNative.cameraRemoteStateJson(remoto)
                if (json.isNotEmpty() && json != ultimo) {
                    ultimo = json
                    val e = EstadoDaCameraRemota.ler(json)
                    if (e != null) {
                        if (b.mudou and QuallNative.MudouNoReceptor.SITUACAO != 0 || e.situacao != CameraRemotaBus.estado.situacao) {
                            com.quall.android.core.LogSeguro.i(TAG, "r9b: a câmera do outro lado está em ${e.situacao}") // i18n-fora: diário técnico de estado da câmera remota; não é texto da interface
                        }
                        CameraRemotaBus.publicar(e)
                    }
                }
                if (b.status == QuallNative.Status.CLOSED) break
                if (b.status != QuallNative.Status.OK) Thread.sleep(100)
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    fun fechar() {
        parar = true
        runCatching { thread.join(1500) }
        if (thread.isAlive) {
            com.quall.android.core.LogSeguro.e(TAG, "r9b: a bombeada da câmera não saiu em 1,5 s — o controle e as mensagens ficam vazados") // i18n-fora: diário técnico de término da thread; não é texto da interface
            return
        }
        CameraRemotaBus.liberar(remoto)
        QuallNative.messagesFree(mensagens)
    }

    companion object {
        private const val TAG = "QuallReceptor"

        /** Cria o controle e a bombeada da sessão, ou `null` sem núcleo ou sem mensagens. */
        fun abrir(sessao: Long, continuar: () -> Boolean): ControleDaCameraRemota? {
            val r = QuallNative.cameraRemoteNew()
            if (r == 0L) return null
            val m = QuallNative.sessionMessages(sessao)
            if (m == 0L) {
                QuallNative.cameraRemoteFree(r)
                return null
            }
            return ControleDaCameraRemota(r, m, continuar)
        }
    }
}

/**
 * **O controle da câmera do outro lado, para a tela** (R9b, o receptor): a sessão de recepção cria o
 * `QuallCameraRemote`, bombeia numa thread dela e publica aqui o estado lido; a tela lê o [estado] a cada
 * tique e chama os gestos ([pedir], [restaurar], [tocar]) da thread dela.
 *
 * **O handle vive sob a [trava]**: a sessão o põe ao nascer e o tira (e libera) no fim, sob a mesma
 * trava; um gesto tardio da tela, depois da sessão, encontra `0` e não faz nada — nunca um ponteiro
 * liberado.
 */
object CameraRemotaBus {
    private val trava = Any()
    private var handle = 0L

    @Volatile
    var estado: EstadoDaCameraRemota = EstadoDaCameraRemota()
        private set

    /** A sessão de recepção: o handle novo (ou `0` no fim, que limpa o estado). */
    internal fun definir(h: Long) = synchronized(trava) {
        handle = h
        if (h == 0L) estado = EstadoDaCameraRemota()
    }

    /** A sessão de recepção, com o handle ainda de pé: libera sob a trava. */
    internal fun liberar(h: Long) = synchronized(trava) {
        if (handle == h) {
            handle = 0L
            estado = EstadoDaCameraRemota()
        }
        QuallNative.cameraRemoteFree(h)
    }

    internal fun publicar(e: EstadoDaCameraRemota) {
        estado = e
    }

    /** Um ajuste parcial (só os campos mexidos), de gesto da pessoa. Devolve o [QuallNative.Status]. */
    fun pedir(json: String): Int = synchronized(trava) {
        if (handle == 0L) QuallNative.Status.CLOSED else QuallNative.cameraRemoteRequest(handle, json)
    }

    fun restaurar(): Int = synchronized(trava) {
        if (handle == 0L) QuallNative.Status.CLOSED else QuallNative.cameraRemoteRestore(handle)
    }

    /** Um toque em ([x], [y]) de 0 a 1 no quadro decodificado. */
    fun tocar(x: Double, y: Double, longo: Boolean): Int = synchronized(trava) {
        if (handle == 0L) QuallNative.Status.CLOSED else QuallNative.cameraRemoteTouch(handle, x, y, longo)
    }

    /** O estado de agora, relido do núcleo (depois de um gesto, para o painel não esperar a bombeada). */
    fun reler() {
        val json = synchronized(trava) { if (handle == 0L) return else QuallNative.cameraRemoteStateJson(handle) }
        EstadoDaCameraRemota.ler(json)?.let { estado = it }
    }
}
