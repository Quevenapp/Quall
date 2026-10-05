package com.quall.android.teleprompter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.floor

/**
 * A leitura presa ao texto quando o mesmo roteiro é diagramado de novo (girar, fonte, margem).
 *
 * A diagramação aqui é de mentira — quebra gulosa por palavra, `colunas` caracteres por linha,
 * linhas da mesma altura —, mas tem o que importa: as quebras **não** são proporcionais entre uma
 * largura e outra (fim de parágrafo, palavra que não coube), e é isso que faz a fração sozinha cair
 * noutra frase.
 */
class AncoraTest {

    private class Quebra(texto: String, colunas: Int, private val h: Double = 10.0) : Diagramacao {
        private val inicios: IntArray

        init {
            val l = mutableListOf<Int>()
            var s = 0
            for (paragrafo in texto.split('\n')) {
                if (paragrafo.isEmpty()) {
                    l.add(s)
                } else {
                    var pos = 0
                    while (pos < paragrafo.length) {
                        l.add(s + pos)
                        if (paragrafo.length - pos <= colunas) break
                        val espaco = paragrafo.lastIndexOf(' ', pos + colunas)
                        pos = if (espaco > pos) espaco + 1 else pos + colunas
                    }
                }
                s += paragrafo.length + 1
            }
            inicios = l.toIntArray()
        }

        override val linhas get() = inicios.size
        override fun centro(linha: Int) = linha * h + h / 2
        override fun altura(linha: Int) = h
        override fun linhaNaAltura(y: Double) = floor(y / h).toInt().coerceIn(0, linhas - 1)
        override fun inicio(linha: Int) = inicios[linha]
        override fun linhaDoCaractere(caractere: Int): Int {
            var lo = 0
            var hi = inicios.size - 1
            while (lo < hi) {
                val meio = (lo + hi + 1) / 2
                if (inicios[meio] <= caractere) lo = meio else hi = meio - 1
            }
            return lo
        }
    }

    /** Um roteiro de prosa, com parágrafos de tamanhos diferentes (determinístico). */
    private fun prosa(bytes: Int): String {
        val palavras = listOf(
            "boa", "noite", "e", "bem-vindos", "ao", "programa", "de", "hoje", "a", "gente", "vai", "falar",
            "sobre", "o", "que", "mudou", "na", "cidade", "neste", "ano", "com", "calma", "porque", "tem",
            "muita", "coisa", "para", "contar", "entrevista", "logo", "depois", "do", "intervalo",
        )
        val sb = StringBuilder()
        var semente = 7L
        fun proximo(n: Int): Int {
            semente = (semente * 1103515245L + 12345L) and 0x7fffffffL
            return (semente % n).toInt()
        }
        while (sb.length < bytes) {
            val frases = 1 + proximo(7)
            repeat(frases) {
                val n = 4 + proximo(18)
                repeat(n) { i -> sb.append(if (i == 0) palavras[proximo(palavras.size)].replaceFirstChar { it.uppercase() } else palavras[proximo(palavras.size)]).append(if (i == n - 1) ". " else " ") }
            }
            sb.setLength(sb.length - 1)
            sb.append('\n')
        }
        return sb.toString()
    }

    private val texto = prosa(60_000)
    private val retrato = Quebra(texto, colunas = 18)
    private val paisagem = Quebra(texto, colunas = 44)

    @Test
    fun a_fracao_sozinha_poe_outra_frase_na_linha_de_leitura() {
        // É a medida do que o prompter fazia até aqui: mesma fração, layout novo.
        val andadas = listOf(0.25, 0.5, 0.75).map { Ancora.linhasAndadasSemAncora(retrato, paisagem, it) }
        assertTrue("a fração sozinha acertou em todos os pontos: $andadas", andadas.any { abs(it) >= 2 })
    }

    @Test
    fun a_ancora_poe_o_mesmo_caractere_na_linha_de_leitura() {
        for (i in 0..200) {
            val p = i / 200.0
            for ((antes, depois) in listOf(retrato to paisagem, paisagem to retrato)) {
                val marca = Ancora.marcar(antes, p)
                val nova = Ancora.reposicionar(depois, marca)
                assertEquals(
                    "p=$p: a linha de leitura não tem o caractere marcado",
                    depois.linhaDoCaractere(marca.caractere), Ancora.linhaNaLeitura(depois, nova),
                )
            }
        }
    }

    @Test
    fun ida_e_volta_devolve_a_mesma_linha() {
        // Girar para paisagem e voltar para retrato não pode deixar a leitura noutra linha.
        for (i in 0..100) {
            val p = i / 100.0
            val naPaisagem = Ancora.reposicionar(paisagem, Ancora.marcar(retrato, p))
            val deVolta = Ancora.reposicionar(retrato, Ancora.marcar(paisagem, naPaisagem))
            val l0 = Ancora.linhaNaLeitura(retrato, p)
            val l1 = Ancora.linhaNaLeitura(retrato, deVolta)
            // A linha larga começa numa das linhas estreitas de antes, no máximo tantas linhas acima
            // quantas a linha larga cobre (44/18 → até 3).
            assertTrue("p=$p: saiu da linha $l0 e voltou na $l1", l1 in (l0 - 3)..l0)
        }
    }

    @Test
    fun no_mesmo_layout_a_posicao_nao_muda_e_o_desvio_na_linha_fica() {
        for (i in 0..100) {
            val p = i / 100.0
            assertEquals(p, Ancora.reposicionar(retrato, Ancora.marcar(retrato, p)), 1e-9)
        }
    }

    @Test
    fun as_pontas() {
        assertEquals(0.0, Ancora.reposicionar(paisagem, Ancora.marcar(retrato, 0.0)), 0.0)
        assertEquals(0, Ancora.linhasAndadasSemAncora(retrato, paisagem, 0.0))
        // No fim, a última linha estreita começa dentro da última larga (ou perto): fica no fim.
        assertEquals(paisagem.linhas - 1, Ancora.linhaNaLeitura(paisagem, Ancora.reposicionar(paisagem, Ancora.marcar(retrato, 1.0))))
    }

    @Test
    fun texto_de_uma_linha_nao_tem_percurso() {
        val curto = Quebra("uma linha só", colunas = 40)
        assertEquals(1, curto.linhas)
        assertEquals(0.0, Ancora.reposicionar(curto, Ancora.marcar(retrato, 0.6)), 0.0)
    }
}
