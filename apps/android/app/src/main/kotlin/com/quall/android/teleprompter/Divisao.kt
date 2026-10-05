package com.quall.android.teleprompter

import androidx.annotation.StringRes
import com.quall.android.R
import com.quall.android.core.Textos

/**
 * **A divisão da tela R5** (`docs/teleprompter-com-camera.md` §2.5): o roteiro, a prévia da câmera
 * ao lado dele e a faixa dos controles. É a conta do iOS (`TelaDoPrompterComCamera.divisao`), portada
 * para o Android no pedido do Pessoa Exemplo de 28/09 ("siga o mesmo modelo das telas do iOS";
 * `docs/telas-android-como-ios.md` §1). Pura: a vista ([com.quall.android.ui.DivisaoDaTela]) só
 * aplica.
 *
 * ## Deitado, o texto fica em cima, empilhado como em pé (30/09)
 *
 * O pedido do Pessoa Exemplo, palavra por palavra: *"na horizontal o texto do teleprompter precisa ficar no
 * centro embaixo da camera, não no lado esquerdo e a camera no lado direito, ai segue o mesmo modelo
 * da vertical"*. Até aqui o automático punha o texto **do lado da lente**: deitado, à esquerda ou à
 * direita, com a prévia do outro lado. No tablet SM-X230, que nasce em pé e tem a lente na borda
 * longa, deitado a lente fica **em cima** e o texto ia para a esquerda; no celular deitado, o mesmo
 * lado a lado.
 *
 * A regra nova do [Escolha.AUTOMATICO] ([doAutomatico], o nome do iOS; o rótulo passa de "Do lado da
 * lente" para "Automático"; a chave gravada, `automatico`, não muda): **o texto fica em cima, empilhado sobre a prévia**, nas
 * rotações 0, 1 e 3; **embaixo só de ponta-cabeça** (`ROTATION_180`, a lente embaixo). O automático
 * **nunca** põe lado a lado — "À esquerda" e "À direita" continuam no ajuste "Lado do texto", para quem
 * quiser. O iOS recebe a mesma regra e o mesmo rótulo.
 *
 * **Empilhado numa tela larga e baixa** (deitado num celular: largura maior que a altura **e** altura
 * abaixo de [Medidas.alturaDaTelaBaixa], 540 dp — a mesma regra e o mesmo nome do iOS) a faixa dos
 * controles **sai do pé da tela e vai para o lado da prévia**: uma coluna à direita (nas duas paisagens),
 * dentro da banda da prévia, com a largura de [Medidas.colunaLadoALado] (no máximo metade da tela),
 * encostada no pé — no alto, com o texto embaixo. A prévia fica com o resto da banda, na altura toda dela.
 * Assim o celular deitado (o A07 tem 853 × 384 dp) não perde o texto para a faixa: o teto do texto usa o
 * maior entre a prévia mínima e a reserva da faixa, e não a soma. **O tablet deitado** (800 dp de altura)
 * passa dos 540: continua empilhado como em pé, com a faixa no pé, na largura toda. Empilhado numa tela
 * larga, alta ou baixa, a posição da borda tem uma chave própria (`empilhada-larga`, [formato]; no iOS,
 * `teleprompter.camera.divisao.empilhada-larga`), e a de quem está em pé não vaza para quem está deitado.
 *
 * ## O lado da lente
 *
 * A frontal do celular fica na borda de cima **natural** do aparelho. Na tela, essa borda está em
 * cima na `ROTATION_0`, à esquerda na `ROTATION_90` (o aparelho girado no sentido anti-horário, o
 * alto dele à esquerda de quem olha — a "Paisagem" do prompter), embaixo na `ROTATION_180` e à
 * direita na `ROTATION_270` ([ladoDaLente]). Desde 30/09 ela não decide mais o lado do texto: só as
 * marcas do enquadramento, que vão para a ponta do texto longe dela (`VistaDoRoteiro.ladoDaLente`). O
 * ajuste local "Lado do texto" fixa o texto num dos quatro lados, para a webcam de fora ou o aparelho
 * que tenha a lente em outra borda (as mesmas cinco opções do iOS, `LadoDoTexto`).
 *
 * ## A faixa, e por que ela é dela
 *
 * Até 28/09 os avisos, a espera e a barra moravam numa pilha **por cima** do painel da câmera. O iOS
 * provou em 24/09 (iPhone X) que isso cobre a prévia quase inteira, e passou a dar à faixa uma área
 * própria. Aqui é igual:
 *
 * - **o texto é uma fração da tela inteira** (a mesma gravada), e **só a prévia** absorve a faixa:
 *   um aviso que aparece encolhe a prévia e **nunca move a linha de leitura** de quem está lendo;
 * - empilhado numa tela alta (retrato) ou larga e alta (o tablet deitado), a faixa vai para a ponta
 *   oposta ao texto; empilhado numa tela larga e baixa (o celular deitado), para a coluna ao lado da
 *   prévia; lado a lado (escolhido no ajuste), para o pé da coluna da
 *   prévia; com a prévia escondida, para o pé da tela (para o alto, com o texto embaixo). Nunca entre
 *   o texto e a lente (o pedido de 24/09).
 */
object Divisao {

    enum class Lado { TOPO, ESQUERDA, BAIXO, DIREITA }

    /**
     * O ajuste local "Lado do texto" — as cinco opções do iOS, com os mesmos nomes. O nome na tela é
     * [rotulo] (`r5_lado_*`), no idioma escolhido; a [chave] é a das preferências e da bancada.
     */
    enum class Escolha(val chave: String, @StringRes val rotulo: Int) {
        AUTOMATICO("automatico", R.string.r5_lado_automatico),
        TOPO("cima", R.string.r5_lado_cima),
        BAIXO("baixo", R.string.r5_lado_baixo),
        ESQUERDA("esquerda", R.string.r5_lado_esquerda),
        DIREITA("direita", R.string.r5_lado_direita);

        /** O nome na tela, no idioma de [t]. */
        fun nome(t: Textos): String = t.s(rotulo)

        companion object {
            fun daChave(c: String?): Escolha? = entries.firstOrNull { it.chave == c }
        }
    }

    /** Nenhum dos dois lados fica com menos que isto da tela (§2.5; hipótese de produto). */
    const val MINIMO = 0.2

    /** 50/50 por padrão (§0). */
    const val PADRAO = 0.5

    fun ladoDaLente(rotacao: Int): Lado = when (((rotacao % 4) + 4) % 4) {
        0 -> Lado.TOPO
        1 -> Lado.ESQUERDA
        2 -> Lado.BAIXO
        else -> Lado.DIREITA
    }

    fun oposto(l: Lado): Lado = when (l) {
        Lado.TOPO -> Lado.BAIXO
        Lado.BAIXO -> Lado.TOPO
        Lado.ESQUERDA -> Lado.DIREITA
        Lado.DIREITA -> Lado.ESQUERDA
    }

    /**
     * **O automático** (30/09; `doAutomatico` também no iOS): em cima, empilhado, em qualquer rotação menos
     * de ponta-cabeça (`ROTATION_180`, a lente embaixo), em que fica embaixo. Nunca lado a lado.
     */
    fun doAutomatico(rotacao: Int): Lado = if (((rotacao % 4) + 4) % 4 == 2) Lado.BAIXO else Lado.TOPO

    /** Onde o texto fica, na [rotacao] da tela, com a [escolha] do ajuste local. */
    fun ladoDoTexto(rotacao: Int, escolha: Escolha): Lado = when (escolha) {
        Escolha.AUTOMATICO -> doAutomatico(rotacao)
        Escolha.TOPO -> Lado.TOPO
        Escolha.BAIXO -> Lado.BAIXO
        Escolha.ESQUERDA -> Lado.ESQUERDA
        Escolha.DIREITA -> Lado.DIREITA
    }

    /** O texto e a prévia um sobre o outro (e não lado a lado). */
    fun empilhado(l: Lado): Boolean = l == Lado.TOPO || l == Lado.BAIXO

    /**
     * Empilhado numa tela larga **e baixa** (deitado num celular, 30/09): a faixa vai para uma coluna ao
     * lado da prévia, e não para o pé da tela. Larga e alta (o tablet deitado), a faixa fica no pé.
     */
    fun faixaAoLadoDaPrevia(l: Lado, largura: Int, altura: Int, m: Medidas): Boolean =
        empilhado(l) && largura > altura && altura < m.alturaDaTelaBaixa

    /**
     * A chave em que a posição da borda se guarda: `retrato` (empilhado numa tela alta),
     * `empilhada-larga` (empilhado numa tela larga, desde 30/09 — o sufixo do iOS) ou `paisagem` (lado a
     * lado). Cada formato tem a sua: a borda de quem está em pé não vaza para quem está deitado.
     */
    fun formato(l: Lado, largura: Int, altura: Int): String = when {
        !empilhado(l) -> "paisagem"
        largura > altura -> "empilhada-larga"
        else -> "retrato"
    }

    fun limitar(fracao: Double): Double =
        if (fracao.isNaN()) PADRAO else fracao.coerceIn(MINIMO, 1.0 - MINIMO)

    /** Um retângulo em pixels: esquerda, topo, direita, baixo. */
    data class Retangulo(val esquerda: Int, val topo: Int, val direita: Int, val baixo: Int) {
        val largura get() = direita - esquerda
        val altura get() = baixo - topo
        val vazio get() = largura <= 0 || altura <= 0

        fun cruza(o: Retangulo): Boolean =
            esquerda < o.direita && o.esquerda < direita && topo < o.baixo && o.topo < baixo

        fun intersecao(o: Retangulo): Retangulo? {
            val r = Retangulo(maxOf(esquerda, o.esquerda), maxOf(topo, o.topo), minOf(direita, o.direita), minOf(baixo, o.baixo))
            return if (r.vazio) null else r
        }
    }

    /**
     * As medidas fixas da conta, em pixels (a vista converte de dp). Os valores do iOS:
     * [previaMinima] 120, [reservaDaFaixa] 150 (**constante de propósito**: o limite da borda não
     * pode depender da altura medida da faixa, senão um aviso que aparece mexe no texto),
     * [colunaLadoALado] 340 (a coluna que leva a faixa lado a lado, e desde 30/09 a coluna da faixa ao
     * lado da prévia no empilhado deitado), [espessuraDaZona] 44 e [alturaDaTelaBaixa] 540 (30/09: abaixo
     * dela, empilhado numa tela larga, a faixa vai para o lado da prévia; o nome é o do iOS).
     */
    data class Medidas(
        val previaMinima: Int,
        val reservaDaFaixa: Int,
        val colunaLadoALado: Int,
        val espessuraDaZona: Int,
        val alturaDaTelaBaixa: Int = 540,
    )

    /** As medidas do iOS (em pt) em pixels, na [densidade] da tela: a mesma conversão da vista. */
    fun medidas(densidade: Float): Medidas {
        fun px(dp: Float) = (dp * densidade).toInt()
        return Medidas(
            previaMinima = px(120f), reservaDaFaixa = px(150f), colunaLadoALado = px(340f), espessuraDaZona = px(44f),
            alturaDaTelaBaixa = px(540f),
        )
    }

    /**
     * O resultado da conta: os três retângulos, a zona de toque da borda (`null` sem prévia à
     * mostra), a ponta da zona que encosta no texto (onde a alça se desenha), o comprimento do eixo
     * da divisão e a fração do texto que valeu (a guardada, limitada pelo teto desta tela).
     */
    data class Partes(
        val texto: Retangulo,
        val previa: Retangulo,
        val faixa: Retangulo,
        val zona: Retangulo?,
        val ponta: Lado?,
        val eixo: Int,
        val fracao: Double,
        /** O teto da fração nesta tela: o arrasto não passa dele. */
        val teto: Double,
    )

    /**
     * **A divisão**: texto | prévia | faixa — a conta do iOS (`TelaDoPrompterComCamera.divisao`), linha
     * a linha, mais a faixa ao lado da prévia no empilhado deitado num celular (30/09, [faixaAoLadoDaPrevia]).
     *
     * [fracao] é a do texto (a guardada, ou a do arrasto); [alturaDaFaixa], a medida. Com
     * [previaEscondida], a **moldura da prévia não muda** (a vista some e o texto a cobre); a faixa
     * vai para o pé da tela — para o alto com o texto embaixo — e o texto fica com o resto.
     *
     * Empilhado numa tela larga e baixa, a faixa é uma coluna à direita da banda da prévia (a largura de
     * [Medidas.colunaLadoALado], no máximo metade da tela), encostada no pé da banda (no alto, com o
     * texto embaixo); a prévia fica com o resto da banda, na altura toda dela. O teto do texto deixa o
     * maior entre a prévia mínima e a reserva da faixa (elas não se somam: uma está ao lado da outra).
     */
    fun comFaixa(
        largura: Int,
        altura: Int,
        lado: Lado,
        fracao: Double,
        alturaDaFaixa: Int,
        previaEscondida: Boolean,
        m: Medidas,
    ): Partes {
        val w = largura
        val h = altura
        val emPilha = empilhado(lado)
        val aoLado = faixaAoLadoDaPrevia(lado, w, h, m)
        val eixo = maxOf(1, if (emPilha) h else w)
        val precisa = when {
            aoLado -> maxOf(m.previaMinima, m.reservaDaFaixa)
            emPilha -> m.previaMinima + m.reservaDaFaixa
            else -> m.colunaLadoALado
        }
        val teto = maxOf(MINIMO, minOf(1.0 - MINIMO, 1.0 - precisa.toDouble() / eixo))
        val f = minOf(teto, limitar(fracao))
        val n = Math.round(eixo * f).toInt()
        // **A faixa nunca passa por cima do texto** (a revisão do código, 28/09): muitos avisos
        // abertos, numa tela baixa com a borda no teto, pediriam mais que a sobra. Ela fica com a
        // sobra, no máximo — a prévia vai a zero antes de o texto perder uma linha (ao lado da prévia,
        // a coluna fica com a altura da banda, no máximo). (A vista também limita a lista aberta; isto
        // é a garantia.)
        val sobra = when {
            previaEscondida -> h
            emPilha -> h - n
            else -> h
        }
        val hF = alturaDaFaixa.coerceIn(0, maxOf(0, sobra))
        // A coluna da faixa ao lado da prévia (só no empilhado deitado num celular).
        val wC = if (aoLado) minOf(m.colunaLadoALado, w / 2) else 0
        var texto: Retangulo
        val previa: Retangulo
        var faixa: Retangulo
        when (lado) {
            Lado.BAIXO -> {
                texto = Retangulo(0, h - n, w, h)
                if (aoLado) {
                    faixa = Retangulo(w - wC, 0, w, hF)
                    previa = Retangulo(0, 0, w - wC, maxOf(0, h - n))
                } else {
                    faixa = Retangulo(0, 0, w, hF)
                    previa = Retangulo(0, hF, w, hF + maxOf(0, h - n - hF))
                }
            }
            Lado.ESQUERDA -> {
                texto = Retangulo(0, 0, n, h)
                previa = Retangulo(n, 0, w, maxOf(0, h - hF))
                faixa = Retangulo(n, h - hF, w, h)
            }
            Lado.DIREITA -> {
                texto = Retangulo(w - n, 0, w, h)
                previa = Retangulo(0, 0, w - n, maxOf(0, h - hF))
                faixa = Retangulo(0, h - hF, w - n, h)
            }
            Lado.TOPO -> {
                texto = Retangulo(0, 0, w, n)
                if (aoLado) {
                    previa = Retangulo(0, n, w - wC, maxOf(n, h))
                    faixa = Retangulo(w - wC, h - hF, w, h)
                } else {
                    previa = Retangulo(0, n, w, n + maxOf(0, h - n - hF))
                    faixa = Retangulo(0, h - hF, w, h)
                }
            }
        }
        if (previaEscondida) {
            if (lado == Lado.BAIXO) {
                faixa = Retangulo(0, 0, w, hF)
                texto = Retangulo(0, hF, w, maxOf(hF, h))
            } else {
                faixa = Retangulo(0, h - hF, w, h)
                texto = Retangulo(0, 0, w, maxOf(0, h - hF))
            }
        }
        val z = if (previaEscondida) null else zona(texto, previa, m.espessuraDaZona)
        return Partes(texto, previa, faixa, z, if (z == null) null else pontaDaAlca(texto, previa), eixo, f, teto)
    }

    /**
     * **Onde a borda pega o toque** (`ZonaDaBordaDaDivisao` do iOS): uma faixa de [espessura] px
     * **inteira do lado da prévia**, encostada na linha da divisão, recortada pela prévia — nunca
     * entra no texto nem na faixa dos controles. No texto quem pega o toque são as camadas dele: as
     * setas azuis do enquadramento (que moram na ponta do texto que encosta na prévia), as setas da
     * linha de leitura e o rolador. A bancada de 27/09 (iPad) viu a zona centrada na linha roubar o
     * arrasto das setas azuis. `null` sem prévia onde pôr a zona.
     */
    fun zona(texto: Retangulo, previa: Retangulo, espessura: Int): Retangulo? {
        if (previa.vazio) return null
        val bruta = when {
            texto.baixo <= previa.topo -> Retangulo(previa.esquerda, texto.baixo, previa.direita, texto.baixo + espessura)
            texto.topo >= previa.baixo -> Retangulo(previa.esquerda, texto.topo - espessura, previa.direita, texto.topo)
            texto.direita <= previa.esquerda -> Retangulo(texto.direita, previa.topo, texto.direita + espessura, previa.baixo)
            else -> Retangulo(texto.esquerda - espessura, previa.topo, texto.esquerda, previa.baixo)
        }
        val z = bruta.intersecao(previa) ?: return null
        return if (z.largura < 1 || z.altura < 1) null else z
    }

    /** A ponta da zona que encosta no texto: é ali que a alça visível se desenha. */
    fun pontaDaAlca(texto: Retangulo, previa: Retangulo): Lado = when {
        texto.baixo <= previa.topo -> Lado.TOPO
        texto.topo >= previa.baixo -> Lado.BAIXO
        texto.direita <= previa.esquerda -> Lado.ESQUERDA
        else -> Lado.DIREITA
    }

    /**
     * A fração do texto depois de arrastar a borda [dx], [dy] px a partir de [base], num [eixo] de
     * tantos px — pelo **deslocamento**, como o iOS: a zona fica ao lado da linha, e a posição
     * absoluta do dedo faria a borda pular a distância entre o dedo e a linha. Já limitada.
     */
    fun fracaoArrastada(lado: Lado, base: Double, dx: Float, dy: Float, eixo: Int): Double {
        val e = maxOf(1, eixo).toDouble()
        val delta = when (lado) {
            Lado.TOPO -> dy / e
            Lado.BAIXO -> -dy / e
            Lado.ESQUERDA -> dx / e
            Lado.DIREITA -> -dx / e
        }
        return limitar(base + delta)
    }
}
