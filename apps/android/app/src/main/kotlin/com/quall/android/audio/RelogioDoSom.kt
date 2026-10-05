package com.quall.android.audio

import kotlin.math.abs

/**
 * **O carimbo do som**: tempo de mídia (passos exatos de um quadro), ancorado na hora da primeira
 * amostra do primeiro quadro e **reancorado a cada descontinuidade** (`docs/som-no-receptor.md`
 * §5.1 e §19.3). É a mesma regra do `RelogioDoSomCapturado` do Mac (§19.1), em Kotlin.
 *
 * ## Por que existe
 *
 * O [EmissorDeAudio] carimbava o som com `MonotonicClock.micros()` **no envio**, depois do encode,
 * e não na captura. Na captura do próprio app o `AudioRecord` guarda até 160 ms, e o som saía
 * carimbado atrasado por tudo isso (crítica 3, §1.4). Carimbar a hora da fonte direto também não
 * serve: ela tem o jitter de quem a lê, e o RTP de som anda em passos de um quadro.
 *
 * ## O que ela faz
 *
 * A cada quadro, compara a hora que a fonte diz para a primeira amostra dele (em `MONOTONIC`) com
 * o carimbo que a linha do tempo dá a ele. A diferença é o que uma lacuna, ou a deriva, abriu.
 * - **Acima de +40 ms** (dois quadros) **reancora**: o carimbo vira a hora da fonte (um estouro do
 *   buffer, uma retomada, o laço que ficou para trás e religou o acumulador).
 * - O carimbo **nunca volta**: abaixo de −40 ms (a linha à frente da fonte) é contado em
 *   [adiantados], e não reancora — voltar o carimbo seria um degrau para trás no RTP.
 * - Entre os dois, a diferença é medida ([desvioUs], [maiorDesvioUs]) e não corrigida: é a deriva
 *   do relógio de amostras contra o `MONOTONIC` (§19.5).
 *
 * Pura, sem relógio: quem chama passa as horas.
 */
class RelogioDoSom(
    private val quadroUs: Long,
    /**
     * `false` só na bancada: o controle da prova (`prova_sem_reancorar`), o carimbo em tempo de
     * mídia puro a partir da primeira âncora. É o comportamento que a reancoragem conserta.
     */
    private val reancorar: Boolean = true,
) {
    companion object {
        /** Acima disto, a diferença é descontinuidade, e não jitter nem deriva. Dois quadros. */
        const val LIMIAR_DE_REANCORAGEM_US = 40_000L
    }

    /** O carimbo do próximo quadro; `null` antes do primeiro. */
    var proximoUs: Long? = null
        private set
    var reancoragens = 0
        private set
    /** O maior salto de uma reancoragem, em µs (o tamanho da maior lacuna). */
    var maiorSaltoUs = 0L
        private set
    /** A última diferença medida (hora da fonte − carimbo da linha), em µs. */
    var desvioUs = 0L
        private set
    /** A maior diferença, em módulo, fora das reancoragens. Com sinal. */
    var maiorDesvioUs = 0L
        private set
    /** Quadros em que a linha estava mais de 40 ms **à frente** da fonte. */
    var adiantados = 0
        private set

    /**
     * O carimbo do quadro cuja primeira amostra a fonte diz ser de [horaUs]; a linha anda um
     * quadro. Chamado **uma vez por quadro, antes do encode**: se o encode falhar, o quadro ocupou
     * os 20 ms dele assim mesmo.
     */
    fun carimbar(horaUs: Long): Long {
        val p = proximoUs
        if (p == null) {
            proximoUs = horaUs + quadroUs
            return horaUs
        }
        val erro = horaUs - p
        desvioUs = erro
        if (reancorar && erro > LIMIAR_DE_REANCORAGEM_US) {
            reancoragens++
            if (erro > maiorSaltoUs) maiorSaltoUs = erro
            proximoUs = horaUs + quadroUs
            return horaUs
        }
        if (erro < -LIMIAR_DE_REANCORAGEM_US) adiantados++
        if (abs(erro) > abs(maiorDesvioUs)) maiorDesvioUs = erro
        proximoUs = p + quadroUs
        return p
    }

    fun linha(): String =
        "reancoragens=$reancoragens maior_salto_ms=${"%.1f".format(java.util.Locale.ROOT, maiorSaltoUs / 1000.0)} " +
            "desvio_ms=${"%.1f".format(java.util.Locale.ROOT, desvioUs / 1000.0)} " +
            "maior_desvio_ms=${"%.1f".format(java.util.Locale.ROOT, maiorDesvioUs / 1000.0)} " +
            "adiantados=$adiantados reancorar=$reancorar"
}

/**
 * A hora da amostra de índice `posicao` (quadros por canal desde o começo da gravação), em µs de
 * `MONOTONIC`, a partir de um par (posição, hora em ns) do próprio dispositivo — o que
 * `AudioRecord.getTimestamp(…, TIMEBASE_MONOTONIC)` devolve: "o quadro `posicaoDoPar` foi capturado
 * em `nanosDoPar`". A hora das outras amostras sai do par pela taxa.
 */
object HoraDaCaptura {
    fun instanteUs(posicao: Long, posicaoDoPar: Long, nanosDoPar: Long, taxaHz: Int): Long =
        (nanosDoPar + (posicao - posicaoDoPar) * 1_000_000_000L / taxaHz.coerceAtLeast(1)) / 1000L
}
