package com.quall.android.teleprompter

import com.quall.android.R
import com.quall.android.core.Textos

/**
 * **Onde o texto está, e quanto ele anda** — a conta da rolagem, sem uma linha de Android.
 *
 * O contrato (§3) define a posição como **fração do percurso**: 0 = começo na linha de leitura,
 * 1 = fim nela. Aqui "começo" e "fim" são o **centro da primeira linha** e o **centro da última**:
 * em 0 a primeira linha está sobre a linha de leitura, em 1 a última está. O percurso, em pixels, é
 * a distância entre os dois centros — num texto de uma linha só ele é zero, e a posição não anda.
 *
 * A velocidade é em **linhas por segundo**, e "linha" é a altura da linha na fonte do prompter
 * (§3). Em pixels por segundo: `velocidade × altura_da_linha`. A posição anda
 * `velocidade × altura_da_linha × dt / percurso` por quadro — **constante no tempo**, e não por
 * quadro: um quadro atrasado anda o que atrasou, e a leitura não desacelera quando o aparelho
 * soluça.
 *
 * A posição depende do layout **deste** aparelho: 0,5 aqui é o meio do percurso aqui (§3). Quem
 * controla só a mostra, e quem salta pede uma fração.
 */
object Percurso {

    /**
     * O maior `dt` que um quadro pode andar, em segundos. Um quadro que atrasou 50 ms anda 50 ms —
     * velocidade constante —, mas a volta do segundo plano (o `Choreographer` para com a tela
     * escondida) não vira um salto de vários segundos no meio do roteiro.
     */
    const val DT_MAXIMO_S = 0.25

    fun dtLimitado(dtS: Double): Double =
        if (dtS.isNaN() || dtS <= 0.0) 0.0 else minOf(dtS, DT_MAXIMO_S)

    /** A posição depois de `dtS` segundos rolando. Nunca sai de 0..1. */
    fun avancar(
        posicao: Double,
        linhasPorSegundo: Double,
        alturaDaLinhaPx: Double,
        percursoPx: Double,
        dtS: Double,
    ): Double {
        val p = posicao.coerceIn(0.0, 1.0)
        if (percursoPx <= 0.0 || alturaDaLinhaPx <= 0.0 || linhasPorSegundo <= 0.0 || dtS <= 0.0) return p
        return (p + linhasPorSegundo * alturaDaLinhaPx * dtS / percursoPx).coerceIn(0.0, 1.0)
    }

    /**
     * A posição depois de `dtS` segundos rolando **para trás** — "segurar para rolar", o botão
     * "Rolar para cima" (§12.5): a mesma velocidade de sempre, e **para no começo** (0), sem que
     * quem chama mude `rolando`.
     */
    fun recuar(
        posicao: Double,
        linhasPorSegundo: Double,
        alturaDaLinhaPx: Double,
        percursoPx: Double,
        dtS: Double,
    ): Double {
        val p = posicao.coerceIn(0.0, 1.0)
        if (percursoPx <= 0.0 || alturaDaLinhaPx <= 0.0 || linhasPorSegundo <= 0.0 || dtS <= 0.0) return p
        return (p - linhasPorSegundo * alturaDaLinhaPx * dtS / percursoPx).coerceIn(0.0, 1.0)
    }

    /**
     * Onde desenhar o **topo do texto**, em pixels da vista, para que a posição caia na linha de
     * leitura. `centroDaPrimeiraPx` é o centro da primeira linha medido a partir do topo do texto.
     */
    fun topoDoTexto(linhaDeLeituraPx: Double, centroDaPrimeiraPx: Double, percursoPx: Double, posicao: Double): Double =
        linhaDeLeituraPx - centroDaPrimeiraPx - posicao.coerceIn(0.0, 1.0) * maxOf(percursoPx, 0.0)

    /** O inverso de [topoDoTexto]: a posição que põe o topo do texto em `topoPx` (arrastar com o dedo). */
    fun posicaoDoTopo(topoPx: Double, linhaDeLeituraPx: Double, centroDaPrimeiraPx: Double, percursoPx: Double): Double {
        if (percursoPx <= 0.0) return 0.0
        return ((linhaDeLeituraPx - centroDaPrimeiraPx - topoPx) / percursoPx).coerceIn(0.0, 1.0)
    }

    /** Quantos segundos faltam para o fim, na velocidade de agora; `null` se não anda. */
    fun segundosAteOFim(posicao: Double, linhasPorSegundo: Double, alturaDaLinhaPx: Double, percursoPx: Double): Double? {
        if (percursoPx <= 0.0 || alturaDaLinhaPx <= 0.0 || linhasPorSegundo <= 0.0) return null
        return (1.0 - posicao.coerceIn(0.0, 1.0)) * percursoPx / (linhasPorSegundo * alturaDaLinhaPx)
    }
}

/**
 * **Os passos dos botões**, dentro das faixas do contrato (§3). Fora da faixa o núcleo recusa com
 * `QUALL_STATUS_INVALID` e nada muda — então o botão para na borda em vez de pedir o impossível.
 *
 * Os mesmos passos nas duas telas: o "+" do controle e o "+" do prompter fazem a mesma coisa.
 */
object Ajustes {
    val FAIXA_DA_VELOCIDADE = 0.05..20.0
    val FAIXA_DA_FONTE = 8.0..400.0
    val FAIXA_DA_MARGEM = 0.0..0.45
    val FAIXA_DA_LINHA = 0.0..1.0

    const val PASSO_DA_VELOCIDADE = 0.1
    const val PASSO_DA_FONTE = 4.0
    const val PASSO_DA_MARGEM = 0.02

    /**
     * 1 %, e não os 5 % de antes (14/09): com as setas arrastáveis no prompter fazendo o grosso, os
     * botões são o ajuste fino da linha na altura da lente da câmera — 5 % eram 80 px num telefone
     * em pé (mais de meia linha na fonte de 60 sp); 1 % são 16 px em pé e 7 px deitado.
     */
    const val PASSO_DA_LINHA = 0.01

    /** Quanto "pular" anda: 5 % do percurso do prompter (§3: a posição é fração, não linha). */
    const val PULO = 0.05

    /**
     * Um passo, arredondado ao próprio passo e preso na faixa. Arredondar ao passo evita que
     * `0.1 + 0.2` acumule e que a tela mostre "0,30000000004"; o núcleo ainda quantiza na resolução
     * dele (centésimos, décimos, décimos de milésimo), e um valor igual ao atual não gera envio.
     */
    fun passo(atual: Double, passo: Double, sentido: Int, faixa: ClosedFloatingPointRange<Double>): Double {
        val alvo = atual + passo * sentido
        val arredondado = Math.round(alvo / passo) * passo
        return arredondado.coerceIn(faixa.start, faixa.endInclusive)
    }

    fun velocidade(atual: Double, sentido: Int) = passo(atual, PASSO_DA_VELOCIDADE, sentido, FAIXA_DA_VELOCIDADE)
    fun fonte(atual: Double, sentido: Int) = passo(atual, PASSO_DA_FONTE, sentido, FAIXA_DA_FONTE)
    fun margem(atual: Double, sentido: Int) = passo(atual, PASSO_DA_MARGEM, sentido, FAIXA_DA_MARGEM)
    fun linha(atual: Double, sentido: Int) = passo(atual, PASSO_DA_LINHA, sentido, FAIXA_DA_LINHA)

    /**
     * `12,3 KB de 128 KB` (`12.3 KB of 128 KB` em inglês) — o tamanho do roteiro contra o teto, em
     * bytes de UTF-8. O teto sai sem casa decimal quando é inteiro em KB, como sempre saiu.
     */
    fun tamanhoDoRoteiro(bytes: Long, teto: Long, t: Textos): String {
        fun kb(b: Long) = String.format(t.locale, "%.1f", b / 1024.0)
        val tetoKb = if (teto % 1024 == 0L) String.format(t.locale, "%d", teto / 1024) else kb(teto)
        return t.s(R.string.tp_tamanho_do_roteiro, kb(bytes), tetoKb)
    }
}
