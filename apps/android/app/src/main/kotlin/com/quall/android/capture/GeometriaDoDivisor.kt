package com.quall.android.capture

import kotlin.math.abs

/**
 * **A conta do divisor GL** (`docs/teleprompter-com-camera.md` §2.1, braço a), sem GL nenhum: de um
 * ponto da saída até o ponto da imagem da câmera que ele mostra. Pura, para ser testada sem aparelho.
 *
 * ## Os quatro quadros
 *
 * - **a saída** `q` ∈ [0,1]², com a origem embaixo à esquerda (a convenção do GL);
 * - **a imagem na tela** `p`: a imagem em pé para quem olha a interface, na rotação em que ela está;
 * - **a imagem natural** `n`: em pé com o aparelho na orientação natural dele (retrato, no celular);
 * - **a textura** `t = ST · n`, com a matriz da `SurfaceTexture`.
 *
 * A matriz da `SurfaceTexture` já leva da textura até a imagem natural: com a câmera ligada direto
 * na superfície (sem nó GL do CameraX, que é o nosso caso), a câmera escreve a transformação da
 * orientação do sensor no próprio buffer, e ela aparece em `getTransformMatrix`
 * (`SurfaceRequest.TransformationInfo.hasCameraTransform`, CameraX 1.3+). **Hipótese conferida só
 * pela documentação**: a prova é o cartão com a letra "F" da fase 1 (§6).
 *
 * ## O espelho que a câmera põe, e o que nós pomos
 *
 * No modo `AUTO` da Camera2 a frontal sai **espelhada** na matriz (`OutputConfiguration
 * .setMirrorMode`). Se o CameraX 1.4.2 passa o `MIRROR_MODE_OFF` do `VideoCapture` para a saída
 * ou não, não está lido — e não precisa estar: a matriz diz. Toda matriz de `SurfaceTexture` traz a
 * inversão vertical do GL (`GLConsumer::computeTransformMatrix`, `mtxFlipV`), cujo determinante é
 * negativo; uma rotação não muda o sinal e um espelho o troca. **Determinante positivo é espelho.**
 *
 * ## A rotação da tela, e em qual imagem ela vale (a revisão de 24/09, B2)
 *
 * O `configureTransform` do Camera2Basic gira a imagem natural por `90 · (rotação − 2)` graus no
 * quadro da vista (na `ROTATION_90`, 90° anti-horário; na `ROTATION_270`, horário; na `180`, meia
 * volta). Esse giro deixa em pé a imagem **que se comporta como uma janela** — a da traseira como
 * sai, e a da **frontal espelhada** (um espelho gira com o aparelho como uma janela gira). A imagem
 * verdadeira da frontal (a que a rede leva) gira ao contrário; aplicar o giro nela sai de ponta-
 * cabeça em paisagem. A primeira versão deste arquivo fazia exatamente isso: desfazia o espelho da
 * câmera **antes** de girar.
 *
 * Então, na frontal, a conta é feita na imagem espelhada: a saída que quer a imagem verdadeira (a
 * rede, a gravação, a prévia sem espelho) espelha na tela, gira, e lê a imagem natural espelhada —
 * direto se a matriz já espelha, ou espelhando-a se a matriz não espelha.
 */
object GeometriaDoDivisor {

    /** Uma transformação afim do plano: `x' = a·x + c·y + tx`, `y' = b·x + d·y + ty`. */
    data class Afim(
        val a: Double, val b: Double, val c: Double, val d: Double, val tx: Double, val ty: Double,
    ) {
        /** `this ∘ antes`: primeiro [antes], depois esta. */
        fun apos(antes: Afim): Afim = Afim(
            a = a * antes.a + c * antes.b,
            b = b * antes.a + d * antes.b,
            c = a * antes.c + c * antes.d,
            d = b * antes.c + d * antes.d,
            tx = a * antes.tx + c * antes.ty + tx,
            ty = b * antes.tx + d * antes.ty + ty,
        )

        fun aplicar(x: Double, y: Double): Pair<Double, Double> = (a * x + c * y + tx) to (b * x + d * y + ty)

        /** A `mat4` do GL, por colunas, que leva `(x, y, 0, 1)` a `(x', y', 0, 1)`. */
        fun mat4(): FloatArray = FloatArray(16).also {
            it[0] = a.toFloat(); it[1] = b.toFloat()
            it[4] = c.toFloat(); it[5] = d.toFloat()
            it[10] = 1f
            it[12] = tx.toFloat(); it[13] = ty.toFloat()
            it[15] = 1f
        }

        companion object {
            val IDENTIDADE = Afim(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

            /** `x → 1 − x`. */
            val ESPELHO_X = Afim(-1.0, 0.0, 0.0, 1.0, 1.0, 0.0)
        }
    }

    /**
     * A matriz da `SurfaceTexture` espelha? Ver a doc do objeto: toda matriz traz a inversão
     * vertical do GL, então sem espelho o determinante do bloco 2×2 é negativo.
     */
    fun espelhada(st: FloatArray): Boolean = st[0] * st[5] - st[4] * st[1] > 0f

    /** A matriz troca os eixos — a imagem natural é o buffer girado de 90° ou 270°? */
    fun trocaEixos(st: FloatArray): Boolean = abs(st[0]) + abs(st[5]) < abs(st[1]) + abs(st[4])

    /** O tamanho da imagem natural, a partir do buffer da câmera e de se a matriz troca os eixos. */
    fun tamanhoNatural(larguraDoBuffer: Int, alturaDoBuffer: Int, trocaEixos: Boolean): Pair<Int, Int> =
        if (trocaEixos) alturaDoBuffer to larguraDoBuffer else larguraDoBuffer to alturaDoBuffer

    /** O tamanho da imagem em pé na tela, na [rotacao] dela (`Surface.ROTATION_*`, 0..3). */
    fun tamanhoNaTela(larguraNatural: Int, alturaNatural: Int, rotacao: Int): Pair<Int, Int> =
        if (rotacao and 1 == 1) alturaNatural to larguraNatural else larguraNatural to alturaNatural

    /** Um retângulo em pixels da saída, com a origem no canto de cima à esquerda. */
    data class Area(val x: Int, val y: Int, val largura: Int, val altura: Int)

    /**
     * Onde a imagem em pé ([larguraNaTela] x [alturaNaTela]) cai, inteira e centrada, numa saída de
     * [larguraDaSaida] x [alturaDaSaida] — o encaixe de [matriz] com `preencher = false`. O resto
     * da saída é tarja.
     */
    fun areaDaImagem(larguraNaTela: Int, alturaNaTela: Int, larguraDaSaida: Int, alturaDaSaida: Int): Area {
        val s = minOf(
            larguraDaSaida.toDouble() / larguraNaTela.coerceAtLeast(1),
            alturaDaSaida.toDouble() / alturaNaTela.coerceAtLeast(1),
        )
        val w = Math.round(larguraNaTela * s).toInt().coerceAtMost(larguraDaSaida)
        val h = Math.round(alturaNaTela * s).toInt().coerceAtMost(alturaDaSaida)
        return Area((larguraDaSaida - w) / 2, (alturaDaSaida - h) / 2, w, h)
    }

    /** Da imagem na tela para a imagem natural (`p → n`), na [rotacao] da tela. */
    fun daTelaParaANatural(rotacao: Int): Afim = when (((rotacao % 4) + 4) % 4) {
        0 -> Afim.IDENTIDADE
        // n = (p.y, 1 − p.x): a imagem natural girada 90° no sentido anti-horário.
        1 -> Afim(0.0, -1.0, 1.0, 0.0, 0.0, 1.0)
        2 -> Afim(-1.0, 0.0, 0.0, -1.0, 1.0, 1.0)
        // n = (1 − p.y, p.x)
        else -> Afim(0.0, 1.0, -1.0, 0.0, 1.0, 0.0)
    }

    /**
     * Da saída (`q`) à imagem natural sem espelho (`n`). O shader ainda pinta de preto o que cair
     * fora de [0,1]² (as tarjas de [preencher] falso) e só então aplica a matriz da `SurfaceTexture`.
     *
     * @param preencher `true`: a imagem cobre a saída inteira e o excesso é cortado. Ninguém usa
     *   mais: a prévia cortava assim até a prova de 24/09 no S24, e em paisagem a metade da tela
     *   mostrava um recorte bem mais apertado que a rede. `false`: a imagem inteira cabe, com tarjas
     *   se a proporção não bater — a rede, a gravação (que depois de um giro no meio da sessão
     *   continuam no tamanho do começo) e a prévia, que tem de mostrar o que o receptor vê.
     * @param espelharNaTela a saída mostra a imagem como um espelho (a prévia com o ajuste ligado).
     *   A rede e a gravação passam `false`: nunca espelham.
     * @param texturaEspelhada o que [espelhada] disse da matriz deste quadro.
     * @param frontal a câmera é frontal (ver a doc do objeto: é a imagem espelhada que gira como
     *   janela).
     */
    fun matriz(
        larguraNatural: Int,
        alturaNatural: Int,
        rotacao: Int,
        larguraDaSaida: Int,
        alturaDaSaida: Int,
        preencher: Boolean,
        espelharNaTela: Boolean,
        texturaEspelhada: Boolean,
        frontal: Boolean = true,
    ): Afim {
        val (lt, at) = tamanhoNaTela(larguraNatural, alturaNatural, rotacao)
        // A fração da imagem na tela que aparece na saída, em cada eixo: < 1 corta, > 1 sobra.
        val ew = larguraDaSaida.toDouble() / lt.coerceAtLeast(1)
        val eh = alturaDaSaida.toDouble() / at.coerceAtLeast(1)
        val s = if (preencher) maxOf(ew, eh) else minOf(ew, eh)
        val fx = ew / s
        val fy = eh / s
        var m = Afim(fx, 0.0, 0.0, fy, 0.5 - 0.5 * fx, 0.5 - 0.5 * fy)
        if (frontal) {
            // A imagem espelhada é a que gira em pé: quem quer a verdadeira espelha na tela antes.
            if (!espelharNaTela) m = Afim.ESPELHO_X.apos(m)
            m = daTelaParaANatural(rotacao).apos(m)
            // O ponto é da imagem natural ESPELHADA: a textura que não espelha é lida espelhada.
            if (!texturaEspelhada) m = Afim.ESPELHO_X.apos(m)
        } else {
            // A traseira gira em pé como sai; o espelho da tela, se pedido, é só da tela.
            if (espelharNaTela) m = Afim.ESPELHO_X.apos(m)
            m = daTelaParaANatural(rotacao).apos(m)
            if (texturaEspelhada) m = Afim.ESPELHO_X.apos(m)
        }
        return m
    }

    /**
     * **A rotação da tela (`Surface.ROTATION_*`) que a orientação física pede** — o
     * `OrientationEventListener` dá 0 com o aparelho em pé, 90 com o lado esquerdo para cima (a tela
     * giraria para `ROTATION_270`), 180 de ponta-cabeça, 270 com o lado direito para cima
     * (`ROTATION_90`). Com [atual] conhecida, só troca quando a leitura está a menos de 30° do centro
     * de outro degrau (a folga: um aparelho a 45° não fica trocando). `null` sem leitura
     * (`ORIENTATION_UNKNOWN`, o aparelho de face para cima) e sem [atual].
     */
    fun rotacaoDaOrientacao(graus: Int, atual: Int?): Int? {
        if (graus < 0) return atual
        val g = ((graus % 360) + 360) % 360
        fun rotacaoDoCentro(c: Int) = when (c) {
            0 -> 0
            90 -> 3
            180 -> 2
            else -> 1
        }
        val centro = ((g + 45) / 90 % 4) * 90
        val nova = rotacaoDoCentro(centro)
        if (atual == null || nova == atual) return nova
        val distancia = minOf(Math.abs(g - centro), 360 - Math.abs(g - centro))
        return if (distancia <= 30) nova else atual
    }
}
