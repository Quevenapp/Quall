package com.quall.android.receive

/**
 * **A distribuição dos intervalos entre apresentações** — o número que faltava para "sem fluidez"
 * deixar de ser impressão.
 *
 * É a mesma peça de `apps/windows/src/fluidez.rs`, com o mesmo contrato e os mesmos nomes. O
 * arquivo de lá é a referência; este é a casca Android dele.
 *
 * # Por que a média não serve, e por que ela existia
 *
 * O receptor já media `decode_p50`/`decode_p95` — chegada→compositor — e a linha final já trazia
 * `fps`. Nenhum dos dois responde "falta fluidez". Na corrida de 01/09/2026 que originou esta
 * medida, no Windows, a média de fila→tela dava **6,5 ms** e estava **certa**: o pior caso da
 * mesma corrida era **226 ms**, e é nele que a pessoa vê a imagem parar. Média não vê tranco — um
 * segundo com 29 quadros pontuais e um buraco de 200 ms tem a mesma média de um segundo regular.
 *
 * O que se vê é o **intervalo entre um quadro e o seguinte na tela**, e o que descreve isso é a
 * distribuição dele, não o centro. Que a cauda é o sinal está medido nesta bancada e não é
 * teoria: A10s → Dell, 90 s, o mesmo aparelho pelos dois caminhos
 * (`docs/bancada.md`, "O cabo salva o enlace ruim"):
 *
 *     Wi-Fi 2,4 GHz : p50 33  p95 113  max 177 ms   trancos=190
 *     cabo USB      : p50 34  p95  39  max  83 ms   trancos=0
 *
 * **`p50` praticamente idêntico nos dois.** Toda a diferença está na cauda, e é ela que o olho vê.
 *
 * # O intervalo é entre **apresentações**, e isso é escolha
 *
 * Não entre chegadas, não entre decodificações: entre os instantes em que um quadro de fato foi
 * entregue para ser mostrado. É o único ponto do caminho que corresponde ao que o olho recebe, e é
 * por isso que ele mede também o custo das políticas desta casca — a porta que segura o quadro
 * condenado ([ReceptorSessao.congelarNaRuptura]) aparece aqui como intervalo maior, que é
 * exatamente o que ela custa e o que precisava ficar visível. Medir chegadas esconderia a porta.
 *
 * Nesta casca o ponto é `MediaCodec.releaseOutputBuffer(idx, true)`, em [H264Decoder.drenar] — ver
 * a doc de lá para o que essa marca garante a mais que as cascas Apple, e o que ela continua não
 * garantindo.
 *
 * # `trancos` é convenção de comparação, não afirmação perceptual
 *
 * A 30 fps o orçamento é 33 ms. `trancos` conta os intervalos acima de [TRANCO_MS] — três tempos
 * de quadro. **Não** se está afirmando que 100 ms é o limiar em que uma pessoa percebe; o que se
 * afirma é que duas corridas com o mesmo emissor e a mesma origem podem ser comparadas por esse
 * número. Quem quiser outro corte tem os percentis ao lado.
 *
 * # Nada é alocado por quadro, e isso não é economia
 *
 * [apresentou] roda no caminho de exibição, uma vez por quadro. Uma lista que cresça — e portanto
 * um `ArrayList<Long>` com autoboxing — poria alocação e coleta de lixo exatamente onde a medida
 * mora: **uma pausa de GC aparece nesta distribuição como tranco**, e o instrumento estaria
 * medindo a si mesmo. Daí o [LongArray] de tamanho fixo, alocado uma vez (80 KiB, e o A10s tem
 * 1,79 GB). A ordenação de [linha] aloca, mas ela roda a 2 Hz, fora do caminho do quadro.
 *
 * # Uma thread só
 *
 * [apresentou] é chamado de [H264Decoder.drenar] e [linha] de `ReceptorSessao.relatar`; os dois
 * vêm do **mesmo** laço de recepção. Não há trava aqui porque não há segunda thread, pela mesma
 * disciplina que o resto do receptor segue.
 */
class Fluidez {

    companion object {
        /**
         * O corte de `trancos`: três tempos de quadro a 30 fps. Ver a nota da classe — é convenção
         * de comparação, e a distribuição completa sai junto para quem quiser outro corte.
         */
        const val TRANCO_MS = 100L

        /**
         * Teto de amostras guardadas. A 30 fps são ~5 minutos de sessão; passado isso a
         * distribuição para de crescer em vez de a sessão longa comer memória. Mesmo teto do
         * `Fluidez` do Windows.
         */
        const val MAXIMO_DE_AMOSTRAS = 10_000
    }

    private val intervalosUs = LongArray(MAXIMO_DE_AMOSTRAS)
    private var n = 0

    private var anteriorUs = 0L
    private var temAnterior = false

    /**
     * Quantas amostras foram descartadas por teto — dito em voz alta em vez de fingir que o `n` é
     * a sessão inteira.
     */
    private var descartadas = 0L

    /**
     * Marca que um quadro foi entregue para ser mostrado agora, em microssegundos do
     * [com.quall.android.capture.MonotonicClock].
     *
     * A primeira chamada **só ancora**: não existe intervalo antes do primeiro quadro, e contar o
     * tempo desde a abertura da sessão como se fosse um intervalo poria a subida do ICE, o
     * pareamento e a espera pelo primeiro IDR dentro da distribuição da imagem — que nesta casca
     * são segundos, não milissegundos.
     */
    fun apresentou(agoraUs: Long) {
        if (temAnterior) {
            // `coerceAtLeast(0)` é o `saturating_duration_since` do original. `System.nanoTime()`
            // é `CLOCK_MONOTONIC` e não anda para trás, então isto nunca deveria morder; um
            // intervalo negativo entrando na distribuição seria pior que um zero.
            val us = (agoraUs - anteriorUs).coerceAtLeast(0L)
            if (n < MAXIMO_DE_AMOSTRAS) {
                intervalosUs[n++] = us
            } else {
                descartadas++
            }
        }
        anteriorUs = agoraUs
        temAnterior = true
    }

    /** Quantos intervalos passaram de [TRANCO_MS]. O corte é **estrito**: ver [linha]. */
    fun trancos(): Long {
        var t = 0L
        for (i in 0 until n) if (intervalosUs[i] > TRANCO_MS * 1000L) t++
        return t
    }

    /**
     * `fluidez_ms=[n=… p50=… p95=… max=…] trancos=…`, em milissegundos.
     *
     * Mesma forma de `sem_referencia_ms`, de propósito: quatro números e não um, porque este
     * repositório já pagou por relatório que mostrava só o centro.
     *
     * **Os milissegundos são inteiros calculados na mão, e não `"%.0f".format(...)`.** `format`
     * usa a locale padrão do aparelho, e os aparelhos desta bancada estão em pt-BR: um número com
     * casa decimal sairia com vírgula e os roteiros que leem esta linha (`aa-corrida.py` e
     * companhia) partem em `=` e `espaço`. A linha é lida por máquina; ela não pode depender do
     * idioma do celular.
     *
     * O corte de `trancos` é **estrito** — exatamente no limiar não conta —, para que a comparação
     * entre duas corridas não dependa de arredondamento.
     */
    fun linha(): String {
        val sufixo = if (descartadas > 0) " (+$descartadas além do teto)" else "" // i18n-fora: linha de relato do diário
        if (n == 0) return "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0$sufixo"
        val v = intervalosUs.copyOf(n)
        v.sort()
        fun p(q: Int): Long = emMs(v[((q / 100.0) * (v.size - 1)).toInt().coerceIn(0, v.size - 1)])
        return "fluidez_ms=[n=$n p50=${p(50)} p95=${p(95)} max=${emMs(v[v.size - 1])}] " +
            "trancos=${trancos()}$sufixo"
    }

    /** Microssegundos para milissegundos inteiros, arredondando. Ver a nota de [linha]. */
    private fun emMs(us: Long): Long = (us + 500L) / 1000L
}
