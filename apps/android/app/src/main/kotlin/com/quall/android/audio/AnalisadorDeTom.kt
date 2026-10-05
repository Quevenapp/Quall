package com.quall.android.audio

import kotlin.math.cos
import kotlin.math.sqrt

/**
 * A testemunha de que **saiu som**, e de que é o som certo — sem gravar arquivo nenhum.
 *
 * ## Por que um contador, e não um `.wav`
 *
 * `docs/regras-de-frente.md` diz que um vídeo de bancada pode conter a vida do usuário, e
 * `docs/audio.md` §8 diz o mesmo do som com mais força: *"um `.wav` não carrega no nome o que tem
 * dentro"*. Um número que sai de amostras que ninguém guarda não tem esse problema. A ideia é a
 * mesma de `apps/windows/src/audio.rs`: um Goertzel na raia da nota responde *"que fração da
 * energia deste quadro está exatamente nessa frequência?"* lendo as amostras e **não guardando
 * nenhuma**.
 *
 * ## As quatro notas são as da sonda, e a troca delas é o segundo teste
 *
 * `quall-probe` emite 400, 500, 800 e 1000 Hz, 25 quadros (0,5 s) cada, 2 s por volta
 * (`crates/quall-probe/src/audio.rs`). Então há duas perguntas, e as duas importam:
 *
 * 1. **a energia está numa das quatro raias?** — prova que o conteúdo atravessou, e não só que
 *    chegaram bytes. Ruído branco, um decoder confuso ou o PCM zerado reprovam;
 * 2. **as notas trocam, e na ordem?** — prova a estrutura temporal. Um decoder preso repetindo o
 *    último quadro passa no teste 1 e reprova neste.
 *
 * É o análogo em áudio do que `Sps.kt` faz no vídeo: conferir o que chegou contra o que o emissor
 * disse que ia mandar, em vez de só cronometrar.
 *
 * **Isto não afirma que houve som audível no alto-falante.** Ele mede o PCM que a casca entregou
 * ao `AudioTrack`; do `AudioTrack` ao ar não há testemunha que um agente possa ler.
 */
class AnalisadorDeTom(private val taxaHz: Int, private val canais: Int) {

    companion object {
        /** As quatro notas do tom sintético do `quall-probe`, em Hz. */
        val NOTAS = intArrayOf(400, 500, 800, 1000)

        /**
         * Fração mínima da energia numa raia para dizer "é esta nota".
         *
         * 0,25 é folgado: um seno puro na raia dá acima de 0,9 mesmo depois do Opus a 32 kbit/s,
         * e ruído branco espalhado por 24 kHz de banda não chega perto. Frouxo de propósito —
         * este número existe para separar "som" de "não som", não para medir qualidade.
         */
        const val PISO_DA_RAIA = 0.25
    }

    /** Quadros analisados. */
    var quadros = 0L
        private set

    /** Quadros em que uma das quatro notas dominou. */
    var quadrosComNota = 0L
        private set

    /** Quantas vezes a nota dominante mudou. Com 0,5 s por nota, ~2 por segundo. */
    var trocasDeNota = 0L
        private set

    /** As quatro notas já vistas alguma vez? É o que separa "tocou" de "travou numa nota". */
    private val vistas = BooleanArray(NOTAS.size)

    private var notaAnterior = -1
    private var somaRms = 0.0
    private var somaRazao = 0.0

    /** RMS médio das amostras analisadas, em fração do fundo de escala. */
    val rmsMedio: Double get() = if (quadros == 0L) 0.0 else somaRms / quadros

    /** Fração média da energia que caiu na raia dominante. */
    val razaoMedia: Double get() = if (quadros == 0L) 0.0 else somaRazao / quadros

    /** Quantas das quatro notas apareceram ao menos uma vez. */
    val notasVistas: Int get() = vistas.count { it }

    /**
     * Analisa um quadro de PCM intercalado. Lê `amostrasPorCanal × canais` posições de [pcm].
     *
     * Só o canal 0 entra na conta: o tom sintético põe a **mesma** onda nos dois canais de
     * propósito (`quall-probe`), então o segundo canal não acrescentaria informação, e custaria
     * o dobro do laço no aparelho mais fraco da bancada.
     */
    fun analisar(pcm: ShortArray, amostrasPorCanal: Int) {
        if (amostrasPorCanal <= 0) return
        var energia = 0.0
        for (i in 0 until amostrasPorCanal) {
            val v = pcm[i * canais].toDouble()
            energia += v * v
        }
        quadros++
        somaRms += sqrt(energia / amostrasPorCanal) / 32768.0
        if (energia <= 0.0) {
            notaAnterior = -1
            return
        }

        var melhor = -1
        var melhorRazao = 0.0
        for ((idx, hz) in NOTAS.withIndex()) {
            val razao = goertzel(pcm, amostrasPorCanal, hz.toDouble()) / energia
            if (razao > melhorRazao) {
                melhorRazao = razao
                melhor = idx
            }
        }
        somaRazao += melhorRazao
        if (melhor < 0 || melhorRazao < PISO_DA_RAIA) {
            notaAnterior = -1
            return
        }
        quadrosComNota++
        vistas[melhor] = true
        if (notaAnterior >= 0 && melhor != notaAnterior) {
            trocasDeNota++
        }
        notaAnterior = melhor
    }

    /** Energia na raia `hz`, pelo filtro de Goertzel. */
    private fun goertzel(pcm: ShortArray, n: Int, hz: Double): Double {
        val w = 2.0 * Math.PI * hz / taxaHz
        val coef = 2.0 * cos(w)
        var s1 = 0.0
        var s2 = 0.0
        for (i in 0 until n) {
            val s = pcm[i * canais].toDouble() + coef * s1 - s2
            s2 = s1
            s1 = s
        }
        // |X(k)|² sem calcular a fase. O fator 2 põe a energia da raia na mesma escala da soma
        // dos quadrados acima (uma senoide real reparte a energia entre +f e −f).
        return 2.0 * (s1 * s1 + s2 * s2 - coef * s1 * s2) / n
    }

    fun linha(): String =
        "quadros=$quadros com_nota=$quadrosComNota trocas=$trocasDeNota " +
            "notas_vistas=$notasVistas/${NOTAS.size} " +
            "razao_media=${"%.3f".format(razaoMedia)} rms=${"%.4f".format(rmsMedio)}"

    /**
     * **Verde**: o tom de quatro notas atravessou e foi decodificado.
     *
     * Os três braços têm de passar juntos, e cada um pega um modo de falha diferente: energia na
     * raia (chegou conteúdo), as quatro notas (não travou numa só) e trocas (a linha do tempo
     * anda). 90% é folga sobre os transientes de troca de nota, que caem entre duas raias.
     */
    fun passou(): Boolean =
        quadros > 100 &&
            quadrosComNota * 100 >= quadros * 90 &&
            notasVistas == NOTAS.size &&
            trocasDeNota >= 2
}
