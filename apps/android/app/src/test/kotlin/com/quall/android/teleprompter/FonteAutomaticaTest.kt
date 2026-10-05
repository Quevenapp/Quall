package com.quall.android.teleprompter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A fonte automática: "pelo menos 2 palavras por linha", com as duas exceções (fim de parágrafo e
 * palavra de 12 letras ou mais), e a busca da maior fonte. A diagramação é de mentira — quebra gulosa
 * por palavra, com `colunas` caracteres por linha e a fonte `f` dando 1000/f colunas numa coluna fixa
 * (monoespaçada) —, o bastante para a regra.
 */
class FonteAutomaticaTest {

    private class Quebra(texto: String, colunas: Int) : LinhasDiagramadas {
        private val ini = mutableListOf<Int>()
        private val fins = mutableListOf<Int>()

        init {
            var s = 0
            for (p in texto.split('\n')) {
                if (p.isEmpty()) {
                    ini += s; fins += (s + 1).coerceAtMost(texto.length)
                } else {
                    var pos = 0
                    while (pos < p.length) {
                        ini += s + pos
                        if (p.length - pos <= colunas) {
                            fins += (s + p.length + 1).coerceAtMost(texto.length)
                            break
                        }
                        val espaco = p.lastIndexOf(' ', pos + colunas)
                        val prox = if (espaco > pos) espaco + 1 else pos + colunas
                        fins += s + prox
                        pos = prox
                    }
                }
                s += p.length + 1
            }
        }

        override val quantas get() = ini.size
        override fun inicio(linha: Int) = ini[linha]
        override fun fim(linha: Int) = fins[linha]
    }

    private fun naFonte(texto: String, f: Int) = Quebra(texto, (1000 / f).coerceAtLeast(1))
    private fun maior(texto: String) = FonteAutomatica.maiorFonte { FonteAutomatica.respeita(texto, naFonte(texto, it)) }

    /**
     * §5, alinhado nas quatro telas (14/09): palavra é um trecho sem espaço com pelo menos uma letra
     * ou algarismo. "— vamos" sozinho numa linha, fora do fim do parágrafo, é **uma** palavra só — e
     * reprova (antes, o travessão contava como a segunda palavra e a linha passava).
     */
    @Test
    fun travessao_vamos_sozinho_numa_linha_reprova() {
        assertEquals(1, FonteAutomatica.contarPalavras("— vamos", 0, 7))
        assertEquals(0, FonteAutomatica.contarPalavras("— …", 0, 3))
        assertEquals(2, FonteAutomatica.contarPalavras("a1 — 2", 0, 6))
        val t = "— vamos embora daqui"
        val l = Quebra(t, colunas = 8) // "— vamos " cabe; "embora" vai para a linha de baixo
        assertEquals("— vamos", t.substring(l.inicio(0), l.fim(0)).trim())
        assertFalse("não é o fim do parágrafo", FonteAutomatica.fimDeParagrafo(t, l.inicio(0), l.fim(0)))
        assertEquals(FonteAutomatica.Linha.UMA_PALAVRA_SO, FonteAutomatica.classificar(t, l, 0))
        assertFalse(FonteAutomatica.respeita(t, l))
    }

    @Test
    fun vamos_sozinha_numa_linha_conta_em_qualquer_fonte() {
        // O caso que a primeira versão (a de meia largura) deixou passar numa fonte grande.
        val t = "vamos começar agora com calma"
        val l = Quebra(t, colunas = 6) // "vamos " cabe, "começar" não cabe junto
        assertEquals("vamos", t.substring(l.inicio(0), l.fim(0)).trim())
        assertEquals(FonteAutomatica.Linha.UMA_PALAVRA_SO, FonteAutomatica.classificar(t, l, 0))
        assertFalse(FonteAutomatica.respeita(t, l))
    }

    @Test
    fun as_duas_excecoes_fim_de_paragrafo_e_doze_letras() {
        // "fim" sobra sozinha no fim do parágrafo: não conta.
        val t = "boa noite fim\nsegundo parágrafo aqui"
        val l = Quebra(t, colunas = 10)
        assertEquals(FonteAutomatica.Linha.FIM_DE_PARAGRAFO, FonteAutomatica.classificar(t, l, 1))
        // "responsabilidade" (16 letras) sozinha no meio: não conta; "desenvolver" (11), sim.
        val longa = "a responsabilidade é nossa"
        val ll = Quebra(longa, colunas = 17)
        val i = (0 until ll.quantas).first { longa.substring(ll.inicio(it), ll.fim(it)).trim() == "responsabilidade" }
        assertEquals(FonteAutomatica.Linha.PALAVRA_LONGA, FonteAutomatica.classificar(longa, ll, i))
        val onze = "o desenvolver da casa"
        val lo = Quebra(onze, colunas = 12)
        val j = (0 until lo.quantas).first { onze.substring(lo.inicio(it), lo.fim(it)).trim() == "desenvolver" }
        assertEquals(FonteAutomatica.Linha.UMA_PALAVRA_SO, FonteAutomatica.classificar(onze, lo, j))
        // As letras são só as letras: "desenvolvimento," tem 15, a vírgula não conta.
        val pont = "o desenvolvimento, sim"
        val lp = Quebra(pont, colunas = 17)
        val k = (0 until lp.quantas).first { pont.substring(lp.inicio(it), lp.fim(it)).trim() == "desenvolvimento," }
        assertEquals(FonteAutomatica.Linha.PALAVRA_LONGA, FonteAutomatica.classificar(pont, lp, k))
        // Linha vazia (parágrafo em branco) também não.
        val vazio = "um dois\n\ntrês quatro"
        assertEquals(FonteAutomatica.Linha.VAZIA, FonteAutomatica.classificar(vazio, Quebra(vazio, 40), 1))
    }

    @Test
    fun palavra_partida_no_meio_quebra_a_regra() {
        // Nem sozinha cabe: o motor a parte, e um pedaço de 12 letras não pode passar por palavra longa.
        val t = "a otorrinolaringologista b"
        val l = Quebra(t, colunas = 14)
        assertEquals(FonteAutomatica.Linha.PALAVRA_PARTIDA, FonteAutomatica.classificar(t, l, 1))
        assertFalse(FonteAutomatica.respeita(t, l))
    }

    @Test
    fun a_maior_fonte_e_a_ultima_que_respeita() {
        val curtas = List(60) { "a e o de um tu" }.joinToString(" ")
        val f = maior(curtas)
        assertTrue(FonteAutomatica.respeita(curtas, naFonte(curtas, f)))
        assertFalse("a fonte seguinte já quebraria", FonteAutomatica.respeita(curtas, naFonte(curtas, f + 1)))
        // Palavras longas (12 letras ou mais) sozinhas não contam: a fonte pode crescer até a maior delas
        // não caber inteira na linha — e para aí, sem fugir para 400.
        val compridas = List(30) { "extraordinariamente inconstitucionalmente" }.joinToString(" ")
        val g = maior(compridas)
        assertTrue("devolveu $g", g < FonteAutomatica.MAXIMA)
        assertTrue("em $g a palavra de 21 letras não cabe", 1000 / g >= 21)
        // E uma palavra curta no meio das longas volta a segurar a fonte.
        val mistura = List(30) { "extraordinariamente vamos inconstitucionalmente" }.joinToString(" ")
        assertTrue("mistura ${maior(mistura)} × compridas $g", maior(mistura) < g)
    }

    @Test
    fun as_pontas_da_busca() {
        assertEquals(FonteAutomatica.MAXIMA, FonteAutomatica.maiorFonte { true })
        assertEquals(FonteAutomatica.MINIMA, FonteAutomatica.maiorFonte { false })
        assertEquals(57, FonteAutomatica.maiorFonte { it <= 57 })
    }

    @Test
    fun a_contagem_por_tipo() {
        // Com 5 colunas: "um ", "dois ", "três " (sozinhas), "quatr" (partida), "o\n" e "fim" (fins de parágrafo).
        val t = "um dois três quatro\nfim"
        val l = Quebra(t, colunas = 5)
        val (porTipo, violacoes) = FonteAutomatica.contar(t, l)
        assertEquals(6, l.quantas)
        assertEquals(3, porTipo[FonteAutomatica.Linha.UMA_PALAVRA_SO])
        assertEquals(1, porTipo[FonteAutomatica.Linha.PALAVRA_PARTIDA])
        assertEquals(2, porTipo[FonteAutomatica.Linha.FIM_DE_PARAGRAFO])
        assertEquals(listOf(0, 1, 2, 3), violacoes)
    }
}
