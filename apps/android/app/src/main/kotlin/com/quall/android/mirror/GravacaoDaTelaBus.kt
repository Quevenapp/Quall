package com.quall.android.mirror

import android.os.Handler
import android.os.Looper

/**
 * **A gravação local da câmera** (a tela R5 e, desde 24/09, a câmera comum), do serviço para a tela
 * (`docs/teleprompter-com-camera.md` §5.5 e §8.6):
 * o indicador, o tempo, o espaço que sobra, e as recusas com o motivo. No molde do [MicrofoneBus]:
 * um ouvinte por dono, e o estado inteiro a cada mudança.
 *
 * A tela usa isto para três coisas: desenhar o indicador; dizer ao núcleo que grava
 * (`teleprompterSetRecording`) **quando o arquivo de fato começou ou fechou** (§13.8 do contrato); e
 * recusar o pedido do controle com o motivo que o serviço deu.
 */
object GravacaoDaTelaBus {

    enum class Fase {
        /** Não grava. */
        PARADA,
        /** Abrindo o arquivo e o codificador, esperando o primeiro quadro. */
        COMECANDO,
        /** O arquivo começou (o primeiro quadro de vídeo entrou). */
        GRAVANDO,
        /** Fechando o arquivo. */
        PARANDO,
    }

    data class Estado(
        /** Há espelhamento de câmera com dono (a tela R5, ou a câmera comum): o botão Gravar existe. */
        val disponivel: Boolean = false,
        /** Quem grava é o espelhamento de câmera comum (a tela inicial), e não a tela R5 (§8.6). */
        val daCameraComum: Boolean = false,
        val fase: Fase = Fase.PARADA,
        /** `elapsedRealtime` do primeiro quadro gravado; 0 fora de [Fase.GRAVANDO]. */
        val desdeMs: Long = 0,
        val nome: String = "",
        val bytes: Long = 0,
        val espacoLivre: Long = 0,
        /** A frase da última parada ("salvo em Movies/Quall", ou o motivo), para a tela. */
        val mensagem: String = "",
        /** A última recusa de começar: o motivo, e um número que só cresce (a tela responde uma vez a cada). */
        val recusa: String = "",
        val numeroDaRecusa: Long = 0,
        /**
         * **Este aparelho não grava** (§14.3, caso 1): o motivo, dito antes do toque
         * ([GravacaoIndisponivel]); `null` quando grava. O botão fica apagado com a mensagem.
         */
        val indisponivel: String? = null,
        /**
         * [indisponivel] já foi conferido nesta abertura (a conta roda fora da principal: o
         * `MediaCodecList` e o pacote travavam o `onStartCommand` — a revisão de 28/09). Antes disso,
         * quem precisa do motivo usa o que ele mesmo calculou.
         */
        val indisponivelConferido: Boolean = false,
    ) {
        /** Há um arquivo aberto ou abrindo: a orientação trava, e um pedido novo espera. */
        val ocupada: Boolean get() = fase != Fase.PARADA
    }

    private val principal by lazy { Handler(Looper.getMainLooper()) }

    @Volatile
    var atual = Estado()
        private set

    /**
     * Quantas gravações começaram neste processo. `GravacaoDvService.publicarPendentes` desiste se
     * isto mudar enquanto ele trabalha: um arquivo que acabou de nascer pendente não é órfão.
     */
    @Volatile
    var comecos = 0L
        private set

    private val ouvintes = java.util.concurrent.ConcurrentHashMap<Any, (Estado) -> Unit>()

    fun ouvir(dono: Any, l: ((Estado) -> Unit)?) {
        if (l == null) {
            ouvintes.remove(dono)
            return
        }
        ouvintes[dono] = l
        val e = atual
        principal.post { l(e) }
    }

    @Synchronized
    fun atualizar(bloco: (Estado) -> Estado) {
        val antes = atual
        val e = bloco(antes)
        if (antes.fase == Fase.PARADA && e.fase == Fase.COMECANDO) comecos++
        atual = e
        for (l in ouvintes.values) principal.post { l(e) }
    }
}
