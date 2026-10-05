package com.quall.android.capture

import com.quall.android.core.LogSeguro as Log
import com.quall.android.core.QuallNative
import java.nio.ByteBuffer

/**
 * Destino "com rede": entrega cada quadro à track de mídia do núcleo
 * (`quall_track_send_frame`) e lê o pedido de IDR do receptor
 * (`quall_track_take_idr_request`).
 *
 * É a ligação inteira entre o MediaCodec e o RTP — não há mais nada entre um e outro. Sem fila,
 * sem cópia guardada, sem thread intermediária: o laço de dreno do encoder chama isto e segue.
 * O contrato (`docs/contrato-track.md`) chama isso de "empacota e solta", e é o que mantém o
 * núcleo dentro dos ~50 MB da extension do iOS — a mesma disciplina vale aqui, no aparelho de
 * 1,79 GB.
 *
 * Falha de envio **não** é enfileirada: a track ainda não abriu (normal enquanto o ICE não
 * fechou) ou o transporte caiu. Nos dois casos o quadro é descartado e o laço segue, que é o que
 * o header manda fazer.
 */
class TrackFrameSink(
    private val track: Long,
    /** Quantas falhas seguidas contam como "o receptor foi embora". Um segundo de vídeo. */
    private val falhasParaDesistir: Int,
) : FrameSink {

    companion object {
        private const val TAG = "QuallTrackSink"

        /**
         * Quanto do orçamento de um segundo o balde guarda. 250 ms.
         *
         * Grande o bastante para um IDR inteiro passar sem ser barrado (a 13,5 Mbps são 3,4 Mbit
         * de crédito contra ~1,6 Mbit de um IDR de 1080p) e pequeno o bastante para não deixar o
         * atraso de uma pausa virar enxurrada: foi exatamente isso que o receptor mediu em
         * 09/09/2026, `8572 pacotes numa janela de 509 ms, 50,92% perdidos` — ~164 Mbps de um
         * emissor pedindo 13,5. Ver `docs/bancada.md` §8.65.
         */
        private const val CREDITO_SEGUNDOS = 0.25

        /**
         * Quanto o instantâneo pode passar do alvo antes de o balde barrar. **Duas vezes.**
         *
         * Não é um Y sobre o alvo escolhido por gosto: vídeo real tem quadro-chave, e um GOP com
         * IDR grande legitimamente estoura a média por alguns milissegundos. O que este teto
         * proíbe é a ordem de grandeza que a bancada mediu — doze vezes o alvo, sustentada por
         * meio segundo.
         */
        private const val FOLGA_DO_TETO = 2.0
    }

    /**
     * Teto instantâneo de saída, em bits por segundo. **Zero desliga**, e é o valor de quem não
     * tem controlador de taxa.
     *
     * Quem escreve é o laço de taxa do `MirrorService`, a cada janela, a partir do alvo corrente
     * do controlador. Ver [aoQuadro] para o que acontece quando um quadro não cabe.
     */
    @Volatile
    var tetoInstantaneoBps: Int = 0

    /** Bytes que de fato saíram pela track. É a medida de **o que sai**, não do que se pede. */
    @Volatile var bytesEnviados = 0L
        private set

    /**
     * O balde e o episódio de descarte. Ver [TetoDeSaida] — inclusive o defeito da primeira
     * versão, que barrava um quadro P e deixava passar os que dependiam dele.
     */
    private val teto = TetoDeSaida(creditoSegundos = CREDITO_SEGUNDOS, folga = FOLGA_DO_TETO)

    /** Quadros de referência que o teto barrou — cada um abre um episódio e pede **um** IDR. */
    val descartadosPeloTeto: Long get() = teto.barrados

    /** Quadros P jogados fora porque a cadeia já estava quebrada, esperando o IDR. */
    val condenadosAteIdr: Long get() = teto.condenados

    /** Quadros não-referência que não couberam e caíram sem quebrar nada. */
    val descartaveisPeloTeto: Long get() = teto.descartaveis

    @Volatile var enviados = 0L
        private set

    @Volatile var falhas = 0L
        private set

    @Volatile var pedidosDeIdr = 0L
        private set

    @Volatile var ultimoErro = QuallNative.Status.OK
        private set

    private var falhasSeguidas = 0
    private var jaEnviouAlgum = false

    override fun querIdr(): Boolean {
        val quer = QuallNative.trackTakeIdrRequest(track)
        if (quer) {
            pedidosDeIdr++
            Log.i(TAG, "pedido de IDR do receptor (PLI/FIR) — total $pedidosDeIdr")
        }
        // **O pedido local vem junto, e é o par do descarte.** Barrar um quadro de referência
        // quebra a cadeia de quem assiste; o conserto é o quadro-chave seguinte, não a esperança
        // de que o GOP chegue. **Um pedido por episódio**, e outro só se o IDR não vier — ver
        // [TetoDeSaida.tomarPedidoDeIdr] para a rajada que "um pedido por descarte" produziria.
        val porTeto = teto.tomarPedidoDeIdr()
        return quer || porTeto
    }

    override fun aoQuadro(
        dados: ByteBuffer,
        deslocamento: Int,
        tamanho: Int,
        timestampUs: Long,
        idr: Boolean,
    ) {
        val veredito = teto.decidir(tetoInstantaneoBps, tamanho, idr, System.nanoTime()) {
            AnnexB.primeiraFatiaReferenciada(dados, deslocamento, tamanho)
        }
        when (veredito) {
            TetoDeSaida.Veredito.PASSA -> {
                if (teto.acabouDeCurar()) {
                    Log.i(
                        TAG,
                        "teto: IDR passou — episódio ${teto.episodios} curado em " +
                            "${teto.ultimoEpisodioMs} ms, ${teto.ultimoEpisodioQuadros} quadro(s) " +
                            "condenado(s) no caminho",
                    )
                }
            }
            TetoDeSaida.Veredito.BARRADO -> {
                if (teto.episodios <= 3 || teto.episodios % 20 == 0L) {
                    Log.w(
                        TAG,
                        "teto instantâneo barrou um quadro de $tamanho B " +
                            "(teto=${tetoInstantaneoBps}bps, episódio ${teto.episodios}) — a cadeia " +
                            "quebrou aqui: segurando os quadros P até o IDR, que foi pedido",
                    )
                }
                return
            }
            TetoDeSaida.Veredito.CONDENADO, TetoDeSaida.Veredito.DESCARTAVEL -> return
        }
        val status = QuallNative.trackSendFrame(track, dados, deslocamento, tamanho, timestampUs, idr)
        if (status == QuallNative.Status.OK) {
            enviados++
            bytesEnviados += tamanho.toLong()
            falhasSeguidas = 0
            jaEnviouAlgum = true
        } else {
            falhas++
            falhasSeguidas++
            ultimoErro = status
            if (falhas <= 3 || falhasSeguidas == falhasParaDesistir) {
                Log.w(TAG, "envio recusado: ${QuallNative.Status.nome(status)} (seguidas=$falhasSeguidas)")
            }
        }
    }

    /**
     * Só desiste depois de ter enviado alguma coisa: antes disso, falha seguida é a track ainda
     * abrindo, não o receptor tendo saído.
     */
    override fun desistiu(): Boolean = jaEnviouAlgum && falhasSeguidas > falhasParaDesistir

    /** Contadores do lado do núcleo, como JSON — inclusive `idrs_without_parameters`. */
    fun estatisticasDoNucleo(): String = QuallNative.trackStatsJson(track)
}
