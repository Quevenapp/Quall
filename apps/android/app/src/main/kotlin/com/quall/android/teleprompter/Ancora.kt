package com.quall.android.teleprompter

/**
 * O que a âncora precisa saber de um texto diagramado, em pixels **do texto** (o topo dele = 0).
 * Na tela é um `StaticLayout` (`ui/VistaDoRoteiro.kt`); nos testes, uma quebra de mentira.
 */
interface Diagramacao {
    val linhas: Int

    /** O centro vertical da linha. */
    fun centro(linha: Int): Double

    /** A altura da linha (as linhas com emoji podem ser mais altas). */
    fun altura(linha: Int): Double

    /** A linha que contém a altura `y`. */
    fun linhaNaAltura(y: Double): Int

    /** O primeiro caractere da linha. */
    fun inicio(linha: Int): Int

    /** A linha que contém o caractere. */
    fun linhaDoCaractere(caractere: Int): Int
}

/**
 * **A leitura presa ao texto, e não à fração**, quando o mesmo roteiro é diagramado de novo —
 * girar a tela, trocar a fonte ou a margem.
 *
 * A posição é **fração do percurso** (contrato §3; [Percurso]): 0 = a primeira linha na linha de
 * leitura, 1 = a última. Guardar só a fração quando o layout muda põe na linha de leitura **outra
 * frase**: a mesma fração cai noutra linha, porque as quebras não são proporcionais (fim de
 * parágrafo, linha curta). A Frente I mediu no iOS 50–200 linhas com 100–128 KB, na troca de
 * fonte; aqui, na troca de retrato para paisagem, está em `apps/android/README.md`.
 *
 * O conserto é o mesmo do iOS: **marca o caractere que está na linha de leitura** no layout velho
 * (e quanto da altura da linha a leitura está do centro dela), acha esse caractere no layout novo e
 * **recalcula a fração** que o põe na linha de leitura. A fração continua sendo o que vai no fio —
 * o prompter relata a nova —, e o contrato não muda.
 */
object Ancora {

    /** O caractere na linha de leitura, e o desvio da leitura em relação ao centro da linha dele (−0,5..0,5 da altura). */
    data class Marca(val caractere: Int, val desvio: Double)

    /** A altura (px do texto) que a posição `p` põe na linha de leitura. */
    fun alturaNaLeitura(d: Diagramacao, p: Double): Double {
        if (d.linhas <= 0) return 0.0
        val primeira = d.centro(0)
        val ultima = d.centro(d.linhas - 1)
        return primeira + p.coerceIn(0.0, 1.0) * maxOf(ultima - primeira, 0.0)
    }

    /** O inverso: a posição que põe a altura `y` na linha de leitura. */
    fun posicaoDaAltura(d: Diagramacao, y: Double): Double {
        if (d.linhas <= 0) return 0.0
        val primeira = d.centro(0)
        val percurso = d.centro(d.linhas - 1) - primeira
        if (percurso <= 0.0) return 0.0
        return ((y - primeira) / percurso).coerceIn(0.0, 1.0)
    }

    /** A linha que está na linha de leitura na posição `p`. */
    fun linhaNaLeitura(d: Diagramacao, p: Double): Int =
        if (d.linhas <= 0) 0 else d.linhaNaAltura(alturaNaLeitura(d, p)).coerceIn(0, d.linhas - 1)

    /** O que está na linha de leitura na posição `p`. */
    fun marcar(d: Diagramacao, p: Double): Marca {
        if (d.linhas <= 0) return Marca(0, 0.0)
        val y = alturaNaLeitura(d, p)
        val l = d.linhaNaAltura(y).coerceIn(0, d.linhas - 1)
        val h = d.altura(l)
        val desvio = if (h > 0.0) ((y - d.centro(l)) / h).coerceIn(-0.5, 0.5) else 0.0
        return Marca(d.inicio(l), desvio)
    }

    /** A posição, no layout novo, que põe na linha de leitura o caractere marcado (com o mesmo desvio). */
    fun reposicionar(novo: Diagramacao, marca: Marca): Double {
        if (novo.linhas <= 0) return 0.0
        val l = novo.linhaDoCaractere(marca.caractere).coerceIn(0, novo.linhas - 1)
        return posicaoDaAltura(novo, novo.centro(l) + marca.desvio * novo.altura(l))
    }

    /**
     * **A medida**: quantas linhas (do layout novo) a leitura andaria se só a fração `p` fosse
     * mantida — positivo = adiante no texto. Zero quer dizer que a fração, sozinha, já acertaria.
     */
    fun linhasAndadasSemAncora(antes: Diagramacao, depois: Diagramacao, p: Double): Int {
        if (antes.linhas <= 0 || depois.linhas <= 0) return 0
        val ancorada = depois.linhaDoCaractere(marcar(antes, p).caractere)
        return linhaNaLeitura(depois, p) - ancorada
    }
}
