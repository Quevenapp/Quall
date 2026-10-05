package com.quall.android.teleprompter

/**
 * **O ritmo do botão que repete enquanto pressionado** — a tartaruga e o coelho (a velocidade), e o
 * − e o + da velocidade na folha de Ajustes. Pedido do Pessoa Exemplo, 27/09: "tem que dar vários toques". O
 * mesmo ritmo do iOS (`RepeticaoDoBotao.swift`), para os dois aparelhos responderem igual ao dedo.
 * Pura: roda no teste de JVM.
 *
 * Um toque é um passo (ao soltar); segurando, o primeiro passo vem depois de [ESPERA_S], e os
 * seguintes cada vez mais depressa, até [MINIMO_S]. Soltar para. [TETO] repetições por aperto, no
 * máximo: um gesto que o sistema cancelar sem avisar não pode ficar mudando a velocidade para sempre.
 */
object RepeticaoDoBotao {
    const val ESPERA_S = 0.4
    const val PRIMEIRO_S = 0.18
    const val MINIMO_S = 0.05
    const val FATOR = 0.85
    const val TETO = 150

    /** Quanto o dedo pode andar, em dp, e ainda ser um aperto (e não uma rolagem). */
    const val FOLGA_DP = 10f

    /**
     * O intervalo antes da repetição [n] (1 é a primeira), em segundos: [ESPERA_S], depois
     * `PRIMEIRO_S × FATOR^(n−2)`, nunca abaixo de [MINIMO_S]. `null` passado o [TETO].
     */
    fun intervalo(n: Int): Double? {
        if (n < 1 || n > TETO) return null
        if (n == 1) return ESPERA_S
        var v = PRIMEIRO_S
        repeat(n - 2) { v *= FATOR }
        return maxOf(MINIMO_S, v)
    }
}
