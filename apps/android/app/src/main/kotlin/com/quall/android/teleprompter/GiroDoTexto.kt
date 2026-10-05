package com.quall.android.teleprompter

/**
 * **Girar só o texto quando o sistema recusa a orientação pedida.**
 *
 * No telefone, `requestedOrientation` trava a tela ([Orientacao]). Numa **tela grande** (largura
 * mínima ≥ 600 dp) no Android 16, um app com `targetSdk 36` tem a orientação pedida ignorada — o
 * tablet SM-X230 (800 dp) é um deles. A decisão do usuário, a mesma do iPad: quando a trava não
 * vale, **a vista do roteiro gira só o texto** — 90°, 180° ou 270° em relação à rotação em que o
 * sistema deixou a tela — até a orientação escolhida. Barra, avisos e painel seguem o aparelho.
 *
 * Tudo aqui é conta pura, na convenção do Android: a rotação da tela (`Display.getRotation`, 0..3)
 * é quantos quartos de volta **horária** o conteúdo foi girado em relação à orientação natural
 * (a tela em 1 = o aparelho girado 90° anti-horário = o topo à esquerda de quem olha). Os quartos
 * do texto são horários também, e `Canvas.rotate` com graus positivos gira no sentido horário.
 */
object GiroDoTexto {

    /**
     * A rotação que o sistema daria à tela se aceitasse a orientação pedida — a tabela do
     * `DisplayRotation` do Android (sem `config_reverseDefaultRotation`, que esta bancada não tem).
     * `null` para [Orientacao.AUTOMATICA]: nada foi pedido, nada a girar.
     */
    fun rotacaoPedida(o: Orientacao, naturalEmPaisagem: Boolean): Int? = when (o) {
        Orientacao.AUTOMATICA -> null
        Orientacao.RETRATO -> if (naturalEmPaisagem) 3 else 0
        Orientacao.PAISAGEM -> if (naturalEmPaisagem) 0 else 1
        Orientacao.PAISAGEM_INVERTIDA -> if (naturalEmPaisagem) 2 else 3
    }

    /**
     * Quantos quartos de volta (horários, 0..3) o texto gira dentro da vista para chegar à
     * orientação pedida, com a tela na rotação `rotacaoAtual`. Zero quando o sistema aceitou (o
     * telefone) ou quando nada foi pedido.
     */
    fun quartos(o: Orientacao, rotacaoAtual: Int, naturalEmPaisagem: Boolean): Int {
        val alvo = rotacaoPedida(o, naturalEmPaisagem) ?: return 0
        return ((alvo - rotacaoAtual) % 4 + 4) % 4
    }

    /**
     * Um ponto da vista (px, a vista com `largura` × `altura`) → o mesmo ponto no quadro do texto
     * girado de `q` quartos. O quadro do texto tem `altura` × `largura` quando `q` é ímpar.
     */
    fun daVistaParaOTexto(q: Int, largura: Float, altura: Float, x: Float, y: Float): FloatArray = when (q) {
        1 -> floatArrayOf(y, largura - x)
        2 -> floatArrayOf(largura - x, altura - y)
        3 -> floatArrayOf(altura - y, x)
        else -> floatArrayOf(x, y)
    }

    /**
     * O inverso: um ponto do quadro do texto → a vista. É o que o `Canvas` faz com
     * `translate(largura, 0) + rotate(90)` (q = 1), `translate(largura, altura) + rotate(180)`
     * (q = 2) e `translate(0, altura) + rotate(270)` (q = 3).
     */
    fun doTextoParaAVista(q: Int, largura: Float, altura: Float, x: Float, y: Float): FloatArray = when (q) {
        1 -> floatArrayOf(largura - y, x)
        2 -> floatArrayOf(largura - x, altura - y)
        3 -> floatArrayOf(y, altura - x)
        else -> floatArrayOf(x, y)
    }
}
