package com.quall.android.teleprompter

import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.R
import com.quall.android.core.QuallNative
import com.quall.android.teleprompter.CaixaDaPergunta.Caixa
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone

/**
 * A pergunta do texto no controle (§11.6 e §11.7): o estado literal do contrato, a caixa em cada
 * situação, e os textos da caixa e dos "Roteiros guardados".
 */
class PerguntaDoTextoTest {

    /** O literal da §11.6 (as duas chaves no fim do `_state_json`). */
    private val literal = """
        {"rolando":false,"contadores":{},
         "pergunta_do_texto":{"aberta":true,"retido_ha_ms":840,"prompter_id":"ipad-a1b2",
          "prompter_nome":"iPad da Maria",
          "meu":{"bytes":10,"resumo":"0123456789abcdef","previa":"Boa noite."},
          "do_prompter":{"bytes":15,"resumo":"fedcba9876543210","previa":"Bom dia a todos"}},
         "copias_do_texto":[{"origem":"prompter","prompter_id":"ipad-a1b2","prompter_nome":"iPad da Maria",
          "quando_ms":1757880000000,"bytes":15,"resumo":"fedcba9876543210","previa":"Bom dia a todos"}]}
    """.trimIndent()

    @Test
    fun o_literal_do_contrato() {
        val e = EstadoDoTeleprompter.ler(literal)!!
        val p = e.perguntaDoTexto!!
        assertTrue(p.aberta)
        assertEquals(840L, p.retidoHaMs)
        assertEquals("ipad-a1b2", p.prompterId)
        assertEquals("iPad da Maria", p.prompterNome)
        assertEquals(EstadoDoTeleprompter.VistaDoTexto(10, "0123456789abcdef", "Boa noite."), p.meu)
        assertEquals(EstadoDoTeleprompter.VistaDoTexto(15, "fedcba9876543210", "Bom dia a todos"), p.doPrompter)
        val c = e.copiasDoTexto.single()
        assertTrue(c.doPrompter)
        assertEquals(1757880000000L, c.quandoMs)
        assertEquals("fedcba9876543210", c.resumo)
        // Sem nada retido e sem cópias: o de antes.
        val vazio = EstadoDoTeleprompter.ler("""{"pergunta_do_texto":null,"copias_do_texto":[]}""")!!
        assertNull(vazio.perguntaDoTexto)
        assertTrue(vazio.copiasDoTexto.isEmpty())
        // Comparando: aberta falso e do_prompter nulo.
        val comparando = EstadoDoTeleprompter.ler(
            """{"pergunta_do_texto":{"aberta":false,"retido_ha_ms":1200,"prompter_id":"p","prompter_nome":"P",
               "meu":{"bytes":3,"resumo":"aaaaaaaaaaaaaaaa","previa":"oi."},"do_prompter":null}}"""
        )!!.perguntaDoTexto!!
        assertFalse(comparando.aberta)
        assertNull(comparando.doPrompter)
    }

    @Test
    fun a_caixa_em_cada_situacao() {
        val p = EstadoDoTeleprompter.ler(literal)!!.perguntaDoTexto!!
        assertEquals(Caixa.Escondida, CaixaDaPergunta.caixa(null, parVisto = true, ultimoStatus = null, PT))
        // Comparando: nada no primeiro segundo, "conferindo" depois, sem botões.
        val comparando = p.copy(aberta = false, doPrompter = null, retidoHaMs = 500)
        assertEquals(Caixa.Escondida, CaixaDaPergunta.caixa(comparando, true, null, PT))
        assertEquals(Caixa.Conferindo, CaixaDaPergunta.caixa(comparando.copy(retidoHaMs = 1500), true, null, PT))
        // Aberta: o título literal, os botões ligados, a escolha leva o resumo mostrado.
        val aberta = CaixaDaPergunta.caixa(p, true, null, PT) as Caixa.Perguntando
        assertEquals("O prompter iPad da Maria tem outro roteiro.", aberta.titulo)
        assertTrue(aberta.botoesLigados)
        assertNull(aberta.aviso)
        assertEquals("fedcba9876543210", aberta.resumoMostrado)
        // O prompter sumiu, ou a escolha deu CLOSED: botões desligados, com o aviso.
        for (c in listOf(CaixaDaPergunta.caixa(p, false, null, PT), CaixaDaPergunta.caixa(p, true, QuallNative.Status.CLOSED, PT))) {
            c as Caixa.Perguntando
            assertFalse(c.botoesLigados)
            assertEquals("O prompter saiu. A pergunta volta quando ele voltar.", c.aviso)
        }
        // BUSY: o roteiro do prompter mudou; a caixa já mostra o novo, e os botões seguem ligados.
        val mudou = CaixaDaPergunta.caixa(p, true, QuallNative.Status.BUSY, PT) as Caixa.Perguntando
        assertTrue(mudou.botoesLigados)
        assertEquals("O roteiro do prompter mudou. Confira de novo.", mudou.aviso)
    }

    @Test
    fun as_palavras_sao_as_da_fonte_automatica() {
        assertEquals(3, CaixaDaPergunta.contar("Bom dia a"))
        assertEquals(2, CaixaDaPergunta.contar("— vamos embora"))
        assertEquals(0, CaixaDaPergunta.contar(""))
    }

    /** pt-BR, igual nas quatro telas: concordância e ponto de milhar; o texto vazio tem "0 palavras". */
    @Test
    fun o_tamanho_em_palavras_em_pt_br() {
        assertEquals("0 palavras", CaixaDaPergunta.palavras(CaixaDaPergunta.contar(""), PT))
        assertEquals("1 palavra", CaixaDaPergunta.palavras(CaixaDaPergunta.contar("— vamos"), PT))
        assertEquals("2 palavras", CaixaDaPergunta.palavras(2, PT))
        assertEquals("999 palavras", CaixaDaPergunta.palavras(999, PT))
        assertEquals("1.234 palavras", CaixaDaPergunta.palavras(1234, PT))
        assertEquals("21.845 palavras", CaixaDaPergunta.palavras(21_845, PT))
    }

    @Test
    fun os_textos_dos_roteiros_guardados() {
        val c = EstadoDoTeleprompter.ler(literal)!!.copiasDoTexto.single()
        assertEquals("Do prompter iPad da Maria", RoteirosGuardados.origem(c, PT))
        assertEquals("Deste aparelho, antes de iPad da Maria", RoteirosGuardados.origem(c.copy(origem = "controle"), PT))
        val sp = TimeZone.getTimeZone("America/Sao_Paulo")
        // 1757880000000 = 14/09/2025 17:00 em São Paulo (20:00 UTC).
        assertEquals("17:00", RoteirosGuardados.quando(1757880000000, 1757880000000 + 3_600_000, PT, sp))
        assertEquals("14/09 17:00", RoteirosGuardados.quando(1757880000000, 1757880000000 + 86_400_000, PT, sp))
        assertEquals("Usar este roteiro? Ele substitui o roteiro atual, também no prompter conectado.", PT.s(R.string.tp_confirma_usar))
        assertEquals("Apagar este roteiro guardado?", PT.s(R.string.tp_confirma_apagar))
        assertEquals("Nenhum roteiro guardado.", PT.s(R.string.tp_nenhum_roteiro_guardado))
    }

    /**
     * Em inglês, o texto que o iOS fixou para as quatro telas (`Teleprompter.strings`): o título, os
     * avisos da caixa, as palavras com a vírgula de milhar, e a data no formato mês/dia.
     */
    @Test
    fun os_textos_em_ingles_sao_os_do_ios() {
        val p = EstadoDoTeleprompter.ler(literal)!!.perguntaDoTexto!!
        val aberta = CaixaDaPergunta.caixa(p, true, null, EN) as Caixa.Perguntando
        assertEquals("The prompter iPad da Maria has a different script.", aberta.titulo)
        assertEquals("The prompter left. The question comes back when it returns.",
            (CaixaDaPergunta.caixa(p, false, null, EN) as Caixa.Perguntando).aviso)
        assertEquals("1 word", CaixaDaPergunta.palavras(1, EN))
        assertEquals("0 words", CaixaDaPergunta.palavras(0, EN))
        assertEquals("1,234 words", CaixaDaPergunta.palavras(1234, EN))
        assertEquals("Use the prompter's", EN.s(R.string.tp_usar_o_do_prompter))
        assertEquals("Saved scripts", EN.s(R.string.tp_roteiros_guardados))
        val c = EstadoDoTeleprompter.ler(literal)!!.copiasDoTexto.single()
        assertEquals("From the prompter iPad da Maria", RoteirosGuardados.origem(c, EN))
        val sp = TimeZone.getTimeZone("America/Sao_Paulo")
        assertEquals("09/14 17:00", RoteirosGuardados.quando(1757880000000, 1757880000000 + 86_400_000, EN, sp))
    }
}
