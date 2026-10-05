package com.quall.android.teleprompter

/** As linhas de um texto diagramado, o que a regra da fonte automática precisa delas. */
interface LinhasDiagramadas {
    val quantas: Int

    /** O primeiro caractere da linha. */
    fun inicio(linha: Int): Int

    /** Um depois do último (a quebra de parágrafo, quando há, está dentro). */
    fun fim(linha: Int): Int
}

/**
 * **"Fonte automática"** (`docs/teleprompter-ajustes-locais.md` §5): a **maior fonte em que nenhuma
 * linha fica com uma palavra só** — pedido do usuário: "pelo menos 2 palavras por linha". Duas
 * exceções não contam: a **última linha de um parágrafo** (a palavra que sobra no fim) e a linha cuja
 * única palavra é **longa, com 12 letras ou mais** ("responsabilidade", "desenvolvimento"). A exceção
 * **não depende da fonte** — a primeira versão, no Mac, usava "mais de meia largura", e em fonte grande
 * quase toda palavra ocupa meia largura: "vamos" ficou sozinha numa linha.
 *
 * **Uma palavra partida no meio também quebra a regra** (leitura desta frente, 14/09): quando nem uma
 * palavra cabe na linha, o motor a parte em pedaços — e um pedaço de 12 letras passaria por palavra
 * longa.
 *
 * A regra e a busca são contas puras; quem diagrama é a vista, com o mesmo motor de quebra de linha
 * dela (`ui/VistaDoRoteiro.kt`). As três definições são as do §5, iguais nas quatro telas: **palavra**
 * é um trecho sem espaço com pelo menos uma letra ou algarismo (um travessão sozinho não conta, e
 * "— vamos" é uma palavra só); as **letras** dela são só as letras; e a palavra **partida** conta.
 */
object FonteAutomatica {

    /** A faixa da busca, a mesma da fonte do contrato (§3), com resolução de 1. */
    const val MINIMA = 8
    const val MAXIMA = 400

    /** A partir de quantas letras uma palavra sozinha na linha não conta. */
    const val LETRAS_DA_PALAVRA_LONGA = 12

    enum class Linha { VAZIA, VARIAS_PALAVRAS, FIM_DE_PARAGRAFO, PALAVRA_LONGA, UMA_PALAVRA_SO, PALAVRA_PARTIDA }

    /** As que quebram a regra. */
    fun viola(c: Linha) = c == Linha.UMA_PALAVRA_SO || c == Linha.PALAVRA_PARTIDA

    fun classificar(texto: CharSequence, l: LinhasDiagramadas, i: Int): Linha {
        val ini = l.inicio(i)
        val fim = l.fim(i).coerceAtMost(texto.length)
        // A linha acaba no meio de uma palavra que segue na próxima: o motor a partiu.
        if (fim in (ini + 1) until texto.length && !texto[fim - 1].isWhitespace() && !texto[fim].isWhitespace()) {
            return Linha.PALAVRA_PARTIDA
        }
        val palavras = contarPalavras(texto, ini, fim)
        if (palavras == 0) return Linha.VAZIA
        if (palavras >= 2) return Linha.VARIAS_PALAVRAS
        if (fimDeParagrafo(texto, ini, fim)) return Linha.FIM_DE_PARAGRAFO
        if (letras(texto, ini, fim) >= LETRAS_DA_PALAVRA_LONGA) return Linha.PALAVRA_LONGA
        return Linha.UMA_PALAVRA_SO
    }

    /** A regra, no texto inteiro. */
    fun respeita(texto: CharSequence, l: LinhasDiagramadas): Boolean =
        (0 until l.quantas).none { viola(classificar(texto, l, it)) }

    /**
     * A maior fonte de `minima..maxima` que respeita a regra, por busca binária (a regra fica mais
     * difícil de cumprir quanto maior a fonte). Se nem a mínima respeita, a mínima.
     */
    fun maiorFonte(minima: Int = MINIMA, maxima: Int = MAXIMA, respeita: (Int) -> Boolean): Int {
        if (!respeita(minima)) return minima
        if (respeita(maxima)) return maxima
        var lo = minima // respeita
        var hi = maxima // não respeita
        while (hi - lo > 1) {
            val meio = (lo + hi) / 2
            if (respeita(meio)) lo = meio else hi = meio
        }
        return lo
    }

    /** Quantas linhas de cada tipo, e as primeiras que quebram a regra — a tabela que a bancada confere. */
    fun contar(texto: CharSequence, l: LinhasDiagramadas, quantasViolacoes: Int = 5): Pair<Map<Linha, Int>, List<Int>> {
        val porTipo = mutableMapOf<Linha, Int>()
        val violacoes = mutableListOf<Int>()
        for (i in 0 until l.quantas) {
            val c = classificar(texto, l, i)
            porTipo[c] = (porTipo[c] ?: 0) + 1
            if (viola(c) && violacoes.size < quantasViolacoes) violacoes += i
        }
        return porTipo to violacoes
    }

    /**
     * **Palavra** é um trecho sem espaço com pelo menos uma letra ou algarismo (§5, alinhado nas
     * quatro telas em 14/09): um travessão ou reticências sozinhos não contam, e "— vamos" é uma
     * palavra só.
     */
    fun contarPalavras(texto: CharSequence, inicio: Int, fim: Int): Int {
        var n = 0
        var temLetraOuAlgarismo = false
        for (k in inicio until fim.coerceAtMost(texto.length)) {
            val c = texto[k]
            if (c.isWhitespace()) {
                if (temLetraOuAlgarismo) n++
                temLetraOuAlgarismo = false
            } else if (c.isLetterOrDigit()) {
                temLetraOuAlgarismo = true
            }
        }
        return if (temLetraOuAlgarismo) n + 1 else n
    }

    private fun letras(texto: CharSequence, inicio: Int, fim: Int): Int {
        var n = 0
        for (k in inicio until fim.coerceAtMost(texto.length)) if (texto[k].isLetter()) n++
        return n
    }

    /** A linha é a última do parágrafo dela: termina na quebra de parágrafo, ou nada além de espaço vem até a próxima. */
    fun fimDeParagrafo(texto: CharSequence, inicio: Int, fim: Int): Boolean {
        if (fim >= texto.length) return true
        if (fim > inicio && texto[fim - 1] == '\n') return true
        var k = fim
        while (k < texto.length && texto[k] != '\n') {
            if (!texto[k].isWhitespace()) return false
            k++
        }
        return true
    }
}
