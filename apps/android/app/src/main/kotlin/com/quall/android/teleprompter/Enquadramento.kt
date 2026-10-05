package com.quall.android.teleprompter

import java.util.Locale

/**
 * **"Enquadramento"**: as duas setas laterais do prompter, cada uma arrastável sozinha, com o texto
 * **centralizado** entre elas (`docs/teleprompter-ajustes-locais.md` §2 e §3). Ajuste **local**:
 * guardado só no aparelho, fora do salvo do núcleo; o controle não o vê nem o muda.
 *
 * As duas são frações da largura do quadro do texto (0 = a borda esquerda, 1 = a direita), no quadro
 * **do texto**: com o espelho ligado elas espelham junto com ele (a da esquerda na tela é a da direita
 * no vidro). A área entre elas é a "vista do texto" do contrato — a `margem` sincronizada passa a ser
 * fração **dessa** largura, de cada lado. Padrão: a largura inteira. Uma para retrato e outra para
 * paisagem ([formato]): o enquadramento de um não é o do outro.
 */
data class Enquadramento(val esquerda: Double, val direita: Double) {

    val largura: Double get() = direita - esquerda

    /** A seta da esquerda em `x` (fração), presa entre 0 e a da direita menos a folga. */
    fun comEsquerda(x: Double): Enquadramento = copy(esquerda = arredondar(x.coerceIn(0.0, direita - FOLGA_MINIMA)))

    /** A seta da direita em `x` (fração), presa entre a da esquerda mais a folga e 1. */
    fun comDireita(x: Double): Enquadramento = copy(direita = arredondar(x.coerceIn(esquerda + FOLGA_MINIMA, 1.0)))

    /**
     * A coluna do texto, em px do quadro do texto: onde ela começa e quanto mede — o enquadramento,
     * e dentro dele a `margem` sincronizada de cada lado.
     */
    fun coluna(larguraDoQuadro: Int, margem: Double): Pair<Double, Double> {
        val larguraDoEnquadramento = largura * larguraDoQuadro
        val m = margem.coerceIn(0.0, 0.49)
        return (esquerda * larguraDoQuadro + m * larguraDoEnquadramento) to (larguraDoEnquadramento * (1 - 2 * m))
    }

    /** Como vai para as preferências: `"0.1000,0.9000"`. */
    fun guardado(): String = String.format(Locale.ROOT, "%.4f,%.4f", esquerda, direita)

    companion object {
        val INTEIRO = Enquadramento(0.0, 1.0)

        /** A coluna nunca fica mais estreita que 20 % da largura: duas setas coladas perderiam o texto. */
        const val FOLGA_MINIMA = 0.2

        const val RETRATO = "retrato"
        const val PAISAGEM = "paisagem"

        /** Qual enquadramento vale: o quadro do texto em pé usa o de retrato; deitado, o de paisagem. */
        fun formato(larguraDoQuadro: Int, alturaDoQuadro: Int): String =
            if (larguraDoQuadro < alturaDoQuadro) RETRATO else PAISAGEM

        /** O que estava guardado; ilegível ou fora da regra, a largura inteira. */
        fun doGuardado(texto: String?): Enquadramento {
            val partes = texto?.split(',')?.mapNotNull { it.trim().toDoubleOrNull() } ?: return INTEIRO
            if (partes.size != 2) return INTEIRO
            val (e, d) = partes
            if (e < 0.0 || d > 1.0 || d - e < FOLGA_MINIMA - 1e-9) return INTEIRO
            return Enquadramento(e, d)
        }

        private fun arredondar(x: Double) = Math.round(x * 10_000) / 10_000.0

        /**
         * **Onde ficam as marcas das bordas** (as setas azuis): no alto do quadro do texto
         * (`false`) ou no pé (`true`). No prompter comum, no alto, como sempre ([yDaLente] `null`).
         * Na tela R5, **longe da lente** (o pedido de 24/09, visto no A07: no alto elas ficavam
         * junto da frontal, em cima das primeiras linhas, onde a pessoa lê): [yDaLente] é onde a
         * borda da lente cai no quadro do texto (0 = alto, [alturaDoTexto] = pé). Lente no alto →
         * marcas no pé; lente no pé (o aparelho de ponta-cabeça) → no alto; lente de lado (deitado)
         * → no pé, como o iOS (`EnquadramentoDoTexto.noPe`).
         */
        fun marcasNoPe(yDaLente: Float?, alturaDoTexto: Float): Boolean {
            if (yDaLente == null || alturaDoTexto <= 0f) return false
            return yDaLente <= alturaDoTexto * 0.75f
        }
    }
}
