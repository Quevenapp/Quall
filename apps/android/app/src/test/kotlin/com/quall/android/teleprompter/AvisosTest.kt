// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.teleprompter

import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.core.TextosDeTeste.Companion.EN
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Os avisos das duas telas: a regra do usuário (13/09) de que, com o controle caído, **o prompter
 * continua como estava e as duas telas avisam até ele voltar**.
 */
class AvisosTest {

    @Test
    fun antes_do_primeiro_controle_o_prompter_nao_avisa_queda() {
        // Esperando o primeiro controle: a tela mostra o PIN, não "controle desconectado".
        assertFalse(Avisos.controleSumido(jaTeveControle = false, sessaoDePe = false, parVistoHaMs = null))
        assertTrue(Avisos.doPrompter(EstadoDoTeleprompter(), false, false, "424242", "x:7979", PT).isEmpty())
    }

    @Test
    fun com_o_controle_falando_nao_ha_aviso() {
        assertFalse(Avisos.controleSumido(true, sessaoDePe = true, parVistoHaMs = 400))
        assertFalse(Avisos.controleSumido(true, sessaoDePe = true, parVistoHaMs = 2_499))
    }

    @Test
    fun o_controle_mudo_por_2_5_s_ja_e_aviso_antes_de_a_sessao_cair() {
        assertTrue(Avisos.controleSumido(true, sessaoDePe = true, parVistoHaMs = 2_500))
    }

    /**
     * Depois da queda o aviso fica **até a primeira mensagem do controle de volta**: a sessão nova
     * de pé com `par_visto` ainda nulo continua avisando (§2, passo 2).
     */
    @Test
    fun o_aviso_fica_ate_a_primeira_mensagem_do_controle_de_volta() {
        assertTrue(Avisos.controleSumido(true, sessaoDePe = false, parVistoHaMs = null))
        assertTrue(Avisos.controleSumido(true, sessaoDePe = true, parVistoHaMs = null))
        assertFalse(Avisos.controleSumido(true, sessaoDePe = true, parVistoHaMs = 10))
    }

    @Test
    fun o_aviso_do_prompter_diz_que_segue_rolando_e_da_o_pin() {
        val rolando = EstadoDoTeleprompter(rolando = true)
        val linhas = Avisos.doPrompter(rolando, jaTeveControle = true, sessaoDePe = false, pin = "424242", endereco = "192.168.57.8:7979", t = PT)
        assertEquals(1, linhas.size)
        assertTrue(linhas[0], linhas[0].contains("rolando"))
        assertTrue(linhas[0], linhas[0].contains("424242"))
        assertTrue(linhas[0], linhas[0].contains("192.168.57.8:7979"))
        val parado = Avisos.doPrompter(EstadoDoTeleprompter(rolando = false), true, false, null, null, PT)
        assertTrue(parado[0], parado[0].contains("parado"))
    }

    /** A tela R5 (24/09): o mesmo aviso numa linha curta, para o pé do painel da câmera. */
    @Test
    fun o_aviso_compacto_diz_o_mesmo_numa_linha_curta() {
        val rolando = EstadoDoTeleprompter(rolando = true)
        val cheio = Avisos.doPrompter(rolando, true, false, "424242", "192.168.57.7:7979", PT)[0]
        val curto = Avisos.doPrompter(rolando, true, false, "424242", "192.168.57.7:7979", PT, compacto = true)
        assertEquals(1, curto.size)
        val l = curto[0]
        assertFalse(l, l.contains("\n"))
        assertTrue(l, l.startsWith("Controle desconectado"))
        assertTrue(l, l.contains("rolando"))
        assertTrue(l, l.contains("424242"))
        assertTrue(l, l.contains("192.168.57.7:7979"))
        assertTrue("$l / $cheio", l.length < cheio.length - 20)
        assertTrue(l, l.indexOf("424242") < l.indexOf("rolando"))
        // O outro aviso do prompter também numa linha.
        val semEco = EstadoDoTeleprompter(parVistoHaMs = 100, semConfirmacaoHaMs = 2_000)
        val eco = Avisos.doPrompter(semEco, true, true, "424242", null, PT, compacto = true)
        assertEquals(1, eco.size)
        assertFalse(eco[0], eco[0].contains("\n"))
    }

    /** No controle, o prompter ainda não falou logo que a sessão sobe: só vira aviso em 2,5 s. */
    @Test
    fun o_controle_nao_pisca_o_aviso_ao_conectar() {
        assertFalse(Avisos.conexaoPerdida(reconectando = false, sessaoDePe = true, sessaoHaMs = 300, parVistoHaMs = null))
        assertTrue(Avisos.conexaoPerdida(reconectando = false, sessaoDePe = true, sessaoHaMs = 2_600, parVistoHaMs = null))
        assertFalse(Avisos.conexaoPerdida(false, true, 60_000, parVistoHaMs = 900))
        assertTrue(Avisos.conexaoPerdida(false, true, 60_000, parVistoHaMs = 3_000))
    }

    @Test
    fun reconectando_o_controle_sempre_avisa() {
        assertTrue(Avisos.conexaoPerdida(reconectando = true, sessaoDePe = false, sessaoHaMs = 0, parVistoHaMs = null))
        val linhas = Avisos.doControle(EstadoDoTeleprompter(), reconectando = true, sessaoDePe = false, sessaoHaMs = 0, motivo = "O teleprompter saiu.", t = PT)
        assertEquals(1, linhas.size)
        assertTrue(linhas[0], linhas[0].startsWith("Conexão perdida"))
        assertTrue(linhas[0], linhas[0].contains("O teleprompter saiu."))
    }

    /** §3: acima de 1,5 s sem confirmação, "o comando não chegou" — só com a sessão de pé. */
    @Test
    fun comando_sem_confirmacao_por_1_5_s_e_aviso() {
        assertFalse(Avisos.comandoNaoChegou(true, null))
        assertFalse(Avisos.comandoNaoChegou(true, 1_499))
        assertTrue(Avisos.comandoNaoChegou(true, 1_500))
        assertFalse(Avisos.comandoNaoChegou(false, 9_000))
        val e = EstadoDoTeleprompter(parVistoHaMs = 100, semConfirmacaoHaMs = 2_000)
        assertEquals(listOf("O último comando ainda não chegou ao teleprompter."),
            Avisos.doControle(e, false, true, 10_000, null, PT))
    }

    /** §4: `de_outra_versao` diferente de zero, a tela diz "atualize". */
    @Test
    fun outra_versao_pede_atualizar_nas_duas_telas() {
        val e = EstadoDoTeleprompter(parVistoHaMs = 10, contadores = mapOf("de_outra_versao" to 3L))
        assertTrue(Avisos.doControle(e, false, true, 10_000, null, PT).any { it.contains("atualize") })
        assertTrue(Avisos.doPrompter(e, true, true, null, null, PT).any { it.contains("atualize") })
    }

    /** Em inglês: os mesmos avisos, com o PIN e o endereço no lugar (`docs/traducao.md`, Android). */
    @Test
    fun os_avisos_em_ingles() {
        val rolando = EstadoDoTeleprompter(rolando = true)
        val curto = Avisos.doPrompter(rolando, true, false, "424242", "192.168.57.7:7979", EN, compacto = true).single()
        assertEquals("Remote disconnected · PIN 424242 · 192.168.57.7:7979 · text keeps scrolling", curto)
        val e = EstadoDoTeleprompter(parVistoHaMs = 100, semConfirmacaoHaMs = 2_000)
        assertEquals(listOf("The last command hasn’t reached the teleprompter yet."), Avisos.doControle(e, false, true, 10_000, null, EN))
        val perdida = Avisos.doControle(EstadoDoTeleprompter(), true, false, 0, null, EN).single()
        assertEquals("Lost connection to the teleprompter — it keeps going as it was. Trying again…", perdida)
    }
}
