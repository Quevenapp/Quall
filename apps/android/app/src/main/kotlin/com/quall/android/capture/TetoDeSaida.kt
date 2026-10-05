package com.quall.android.capture

/**
 * O teto instantâneo de saída do emissor, e o **episódio de descarte** que ele abre quando barra.
 *
 * Aritmética pura: sem JNI, sem relógio do sistema, sem `Log`. O relógio entra por parâmetro, e é
 * isso que deixa [TetoDeSaidaTest] exercitar na JVM o caminho que 210 janelas de campo nunca
 * exercitaram (`docs/bancada.md` §8.66: `barrados=0`).
 *
 * # O defeito que esta classe conserta, achado antes de o caminho rodar uma vez
 *
 * A primeira versão (§8.66, dentro do `TrackFrameSink`) barrava **o quadro que não cabia** e
 * deixava passar os seguintes. Só que um quadro barrado aqui nunca ganha número de sequência RTP:
 * o receptor não vê buraco nenhum, a condenação dele não dispara, e os quadros P seguintes — que
 * referenciam o barrado — são decodificados sobre uma referência que não existe. Nenhuma casca
 * deste projeto lê `frame_num`. Seria exatamente a "sujeira de movimento" de §8.63, agora sem perda
 * nenhuma no contador para denunciá-la.
 *
 * Então barrar um quadro de referência **abre um episódio**: todo quadro P seguinte é
 * [Veredito.CONDENADO] até passar um IDR. O receptor fica com a última imagem boa em vez de lixo.
 *
 * # O pedido de IDR, e a rajada que ele poderia virar
 *
 * **Um pedido por episódio**, e um novo só depois de [repedirNs] sem IDR. A revisão adversarial de
 * 10/09/2026 apontou o laço: o codificador lê `querIdr()` a cada ≤10 ms e cada `true` rearma um
 * `REQUEST_SYNC_FRAME`; pedir a cada quadro condenado seria um IDR atrás do outro, e como o IDR
 * sempre passa e zera o crédito, o descarte seguinte pediria outro.
 *
 * # O quadro que não quebra nada
 *
 * Um quadro com `nal_ref_idc = 0` não é referência de ninguém. Se ele não couber, cai sozinho
 * ([Veredito.DESCARTAVEL]) e a cadeia continua sã — sem episódio e sem IDR.
 */
class TetoDeSaida(
    /** Quanto do orçamento de um segundo o balde guarda. Ver `TrackFrameSink` para os 250 ms. */
    private val creditoSegundos: Double = 0.25,
    /** Quanto o instantâneo pode passar do alvo antes de barrar. Ver `TrackFrameSink` para o 2x. */
    private val folga: Double = 2.0,
    /** Sem IDR em tanto tempo depois do pedido, pede de novo. */
    private val repedirNs: Long = 500_000_000L,
) {

    enum class Veredito {
        /** Vai para a track. */
        PASSA,

        /** Não coube, e é referência: a cadeia quebrou aqui. Abre um episódio e pede IDR. */
        BARRADO,

        /** A cadeia já está quebrada: quadro P descartado até o IDR. */
        CONDENADO,

        /** Não coube, mas ninguém o referencia: cai sem quebrar nada. */
        DESCARTAVEL,
    }

    @Volatile var barrados = 0L
        private set

    @Volatile var condenados = 0L
        private set

    @Volatile var descartaveis = 0L
        private set

    @Volatile var episodios = 0L
        private set

    /** Duração, em ms, e quadros condenados do último episódio **fechado**. */
    @Volatile var ultimoEpisodioMs = 0L
        private set

    @Volatile var ultimoEpisodioQuadros = 0L
        private set

    private var creditoBits = 0.0
    private var ultimoCreditoNs = Long.MIN_VALUE
    /** `Long.MIN_VALUE` quando a cadeia está sã. */
    private var quebradaDesdeNs = Long.MIN_VALUE
    private var condenadosNoEpisodio = 0L
    private var ultimoPedidoNs = 0L
    private var pedidoPendente = false
    private var fechouAgora = false

    val cadeiaQuebrada: Boolean get() = quebradaDesdeNs != Long.MIN_VALUE

    /**
     * O que fazer com este quadro. `tetoBps <= 0` desliga o teto — mas **não** fecha um episódio
     * aberto: a cadeia quebrada continua quebrada até o IDR, com ou sem teto.
     *
     * `referencia` só é chamada quando o quadro não cabe, que é raro; ela lê o `nal_ref_idc`.
     */
    fun decidir(
        tetoBps: Int,
        tamanho: Int,
        idr: Boolean,
        agoraNs: Long,
        referencia: () -> Boolean,
    ): Veredito {
        fechouAgora = false
        val bits = tamanho.toLong() * 8.0
        if (idr) {
            if (cadeiaQuebrada) {
                ultimoEpisodioMs = (agoraNs - quebradaDesdeNs) / 1_000_000L
                ultimoEpisodioQuadros = condenadosNoEpisodio
                quebradaDesdeNs = Long.MIN_VALUE
                condenadosNoEpisodio = 0
                pedidoPendente = false
                fechouAgora = true
            }
            // O IDR passa sempre e paga o que puder: o crédito nunca fica negativo, senão o quadro
            // seguinte seria barrado por causa dele.
            if (tetoBps > 0) {
                reabastecer(tetoBps, agoraNs)
                creditoBits = (creditoBits - bits).coerceAtLeast(0.0)
            }
            return Veredito.PASSA
        }
        if (cadeiaQuebrada) {
            condenados++
            condenadosNoEpisodio++
            if (agoraNs - ultimoPedidoNs >= repedirNs) {
                pedidoPendente = true
                ultimoPedidoNs = agoraNs
            }
            return Veredito.CONDENADO
        }
        if (tetoBps <= 0) return Veredito.PASSA
        reabastecer(tetoBps, agoraNs)
        if (bits <= creditoBits) {
            creditoBits -= bits
            return Veredito.PASSA
        }
        if (!referencia()) {
            descartaveis++
            return Veredito.DESCARTAVEL
        }
        barrados++
        episodios++
        quebradaDesdeNs = agoraNs
        condenadosNoEpisodio = 0
        pedidoPendente = true
        ultimoPedidoNs = agoraNs
        return Veredito.BARRADO
    }

    /** Consome o pedido de IDR deste teto. Um por episódio, e de novo só depois de [repedirNs]. */
    fun tomarPedidoDeIdr(): Boolean {
        val p = pedidoPendente
        pedidoPendente = false
        return p
    }

    /** `true` uma vez, na chamada de [decidir] em que um IDR fechou um episódio. */
    fun acabouDeCurar(): Boolean = fechouAgora

    private fun reabastecer(tetoBps: Int, agoraNs: Long) {
        val tetoComFolga = tetoBps * folga
        val maximo = tetoComFolga * creditoSegundos
        if (ultimoCreditoNs == Long.MIN_VALUE) {
            creditoBits = maximo
        } else {
            val dt = (agoraNs - ultimoCreditoNs).coerceAtLeast(0) / 1_000_000_000.0
            creditoBits = (creditoBits + tetoComFolga * dt).coerceAtMost(maximo)
        }
        ultimoCreditoNs = agoraNs
    }
}
