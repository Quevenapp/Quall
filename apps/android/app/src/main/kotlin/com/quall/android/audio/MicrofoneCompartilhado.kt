package com.quall.android.audio

import com.quall.android.core.LogSeguro as Log
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/**
 * **O microfone da câmera aberto uma vez, para dois consumidores** (R5, fase 3;
 * `docs/teleprompter-com-camera.md` §4.2 e §5.3): a rede (o [EmissorDeAudio] da sessão, quando há
 * receptor) e a gravação local (quando grava). Os dois vêm e vão sem reabrir o microfone — o
 * receptor que conecta no meio de uma gravação não abre outro `AudioRecord`, e o que cai não fecha
 * o da gravação.
 *
 * Uma thread lê a [fonte] (o [MicrofoneCru], ou o [TomRitmado] da bancada) no ritmo dela, 20 ms por
 * vez, com a hora da captura da primeira amostra, e entrega cada quadro:
 *
 * - a cada [Ramal] — uma [FonteDeAudio] para o [EmissorDeAudio], com uma fila curta e a mesma hora
 *   da captura (o emissor carimba e disciplina a deriva como fazia com o microfone direto);
 * - à [gravacao], se houver: chamada **na thread do microfone**, e por isso não pode bloquear (a
 *   gravação só enfileira).
 *
 * Fechar ([fechar]) destrava a leitura de fora e fecha a fonte na thread dela, como o emissor fazia.
 */
class MicrofoneCompartilhado(
    private val fonte: FonteDeAudio,
    private val preset: PresetDeAudio,
    /** Chamado uma vez, da thread do microfone, quando a leitura parou sozinha (a fonte morreu). */
    private val aoSairSozinho: ((String) -> Unit)? = null,
) {
    /** Recebe cada quadro, na thread do microfone. Não pode bloquear. */
    fun interface Gravacao {
        fun quadro(pcm: ShortArray, amostras: Int, instanteUs: Long?)
    }

    companion object {
        private const val TAG = "QuallAudio"

        /** Quadros de 20 ms que um ramal segura antes de jogar fora o mais velho (1 s). */
        private const val FILA_DO_RAMAL = 50
    }

    val nome: String get() = fonte.nome

    @Volatile var gravacao: Gravacao? = null

    private val ramais = CopyOnWriteArrayList<Ramal>()
    @Volatile private var pararPedido = false
    private var thread: Thread? = null

    @Volatile var quadrosLidos = 0L; private set
    @Volatile var quadrosSemFonte = 0L; private set
    @Volatile var motivoDaSaida = ""; private set

    fun iniciar() {
        val t = Thread({ rodar() }, "quall-microfone-leitura")
        t.isDaemon = true
        thread = t
        t.start()
    }

    /** A leitura está de pé. */
    val vivo: Boolean get() = thread?.isAlive == true

    /**
     * Um consumidor novo para a rede: uma [FonteDeAudio] que devolve os quadros deste microfone a
     * partir de agora. `fechar` dela só a solta daqui; o microfone continua aberto.
     */
    fun ramal(): Ramal = Ramal().also { ramais.add(it) }

    /**
     * Fecha o microfone: pede a saída, destrava a leitura de fora se ela não sair em 500 ms, e
     * espera até 2 s. Devolve `true` quando a thread saiu (a fonte foi fechada nela).
     */
    fun fechar(): Boolean {
        pararPedido = true
        for (r in ramais) r.interromper()
        val t = thread ?: run { fonte.fechar(); return true }
        t.join(500)
        if (t.isAlive) {
            Log.w(TAG, "microfone: a leitura não saiu em 500 ms — interrompendo a fonte (${fonte.nome})")
            fonte.interromper()
            t.join(1_500)
        }
        return !t.isAlive
    }

    private fun rodar() {
        var semFonteSeguidos = 0
        try {
            while (!pararPedido) {
                val pcm = ShortArray(preset.amostrasPorQuadro)
                val n = fonte.proximoQuadro(pcm)
                if (n <= 0) {
                    quadrosSemFonte++
                    semFonteSeguidos++
                    if (semFonteSeguidos > 500) {
                        motivoDaSaida = "a origem de áudio parou de entregar quadros" // i18n-fora: detalhe técnico do diário
                        break
                    }
                    Thread.sleep(5)
                    continue
                }
                semFonteSeguidos = 0
                quadrosLidos++
                val hora = fonte.instanteDoQuadroUs()
                val q = Quadro(pcm, n, hora)
                for (r in ramais) r.entregar(q)
                gravacao?.let { g ->
                    runCatching { g.quadro(pcm, n, hora) }.onFailure {
                        Log.w(TAG, "microfone: a gravação recusou um quadro: ${Log.erroExterno(it.message)}")
                    }
                }
            }
        } catch (e: InterruptedException) {
            motivoDaSaida = "interrompido"
        } finally {
            runCatching { fonte.fechar() }
            for (r in ramais) r.interromper()
            Log.i(TAG, "microfone fechado: lidos=$quadrosLidos sem_fonte=$quadrosSemFonte origem=${fonte.nome}" +
                if (motivoDaSaida.isNotBlank()) " ($motivoDaSaida)" else "")
            if (!pararPedido) runCatching { aoSairSozinho?.invoke(motivoDaSaida.ifBlank { "a leitura parou" }) }
        }
    }

    internal class Quadro(val pcm: ShortArray, val amostras: Int, val instanteUs: Long?)

    /**
     * **Um consumidor da rede.** Bloqueia até 200 ms esperando o próximo quadro (a leitura do
     * microfone é quem dá o ritmo: [ritmadaPeloDispositivo]); devolve a hora da captura dele.
     */
    inner class Ramal internal constructor() : FonteDeAudio {
        private val fila = ArrayBlockingQueue<Quadro>(FILA_DO_RAMAL)
        @Volatile private var interrompido = false
        private var instante: Long? = null

        /** Quadros jogados fora com a fila cheia (o emissor da rede parado). */
        @Volatile var descartados = 0L; private set

        /** Quadros esperando na fila agora (o ouvir da placa segura a latência por aqui). */
        val naFila: Int get() = fila.size

        override val nome: String get() = fonte.nome

        internal fun entregar(q: Quadro) {
            if (interrompido) return
            while (!fila.offer(q)) {
                fila.poll()
                descartados++
            }
        }

        override fun proximoQuadro(pcm: ShortArray): Int {
            if (interrompido) return 0
            val q = fila.poll(200, TimeUnit.MILLISECONDS) ?: return 0
            if (q.pcm === VAZIO) return 0
            System.arraycopy(q.pcm, 0, pcm, 0, minOf(q.pcm.size, pcm.size))
            instante = q.instanteUs
            return q.amostras
        }

        override fun instanteDoQuadroUs(): Long? = instante

        override val ritmadaPeloDispositivo: Boolean get() = true

        override fun interromper() {
            interrompido = true
            fila.offer(Quadro(VAZIO, 0, null))
        }

        /** Solta daqui; o microfone continua aberto para os outros. */
        override fun fechar() {
            interrompido = true
            ramais.remove(this)
            fila.clear()
        }
    }
}

private val VAZIO = ShortArray(0)
