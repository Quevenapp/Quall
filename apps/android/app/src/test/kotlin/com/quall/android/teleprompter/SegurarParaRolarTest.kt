package com.quall.android.teleprompter

import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.R
import com.quall.android.core.QuallNative
import com.quall.android.teleprompter.SegurarParaRolar.Botao
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * O lado do controle do "segurar para rolar" (§12.5): o que sai para a réplica a cada toque, com um
 * dedo e com dois, e o texto que para sozinho com o dedo no botão.
 */
class SegurarParaRolarTest {

    /** A réplica de mentira: anota cada chamada e devolve o status escolhido para o `hold`. */
    private class Porta(var statusDoSegurar: Int = QuallNative.Status.OK) : SegurarParaRolar.Porta {
        val chamadas = mutableListOf<String>()
        override fun segurar(paraTras: Boolean): Int {
            chamadas += if (paraTras) "hold(true)" else "hold(false)"
            return statusDoSegurar
        }

        override fun soltar(): Int {
            chamadas += "release"
            return QuallNative.Status.OK
        }
    }

    @Test
    fun o_mapeamento_da_12_5_num_lugar_so() {
        assertTrue("Rolar para cima volta o texto: hold(t, true)", SegurarParaRolar.paraTras(Botao.CIMA))
        assertFalse("Rolar para baixo avança o texto: hold(t, false)", SegurarParaRolar.paraTras(Botao.BAIXO))
        assertEquals("volta o texto", SegurarParaRolar.efeito(Botao.CIMA, PT))
        assertEquals("avança o texto", SegurarParaRolar.efeito(Botao.BAIXO, PT))
    }

    /**
     * "Inverter botões" (pedido do usuário, 14/09 à tarde): o de cima manda `para_tras=false` (avança)
     * e o de baixo `true` (volta); as legendas trocam junto, as setas e os rótulos não.
     */
    @Test
    fun inverter_troca_o_sentido_e_as_legendas() {
        assertFalse(SegurarParaRolar.paraTras(Botao.CIMA, invertido = true))
        assertTrue(SegurarParaRolar.paraTras(Botao.BAIXO, invertido = true))
        assertEquals("avança o texto", SegurarParaRolar.efeito(Botao.CIMA, PT, invertido = true))
        assertEquals("volta o texto", SegurarParaRolar.efeito(Botao.BAIXO, PT, invertido = true))
        val p = Porta()
        val s = SegurarParaRolar(p, invertido = true)
        s.encostou(0, Botao.CIMA)
        s.saiu(0)
        s.encostou(0, Botao.BAIXO)
        s.saiu(0)
        // Desligada de novo, volta o de sempre.
        assertTrue(s.inverter(false))
        s.encostou(0, Botao.CIMA)
        s.saiu(0)
        assertEquals(listOf("hold(false)", "release", "hold(true)", "release", "hold(true)", "release"), p.chamadas)
    }

    /** Com um dedo num botão de rolar a troca não vale — nem no meio do aperto, nem para o segundo dedo. */
    @Test
    fun inverter_com_o_dedo_no_botao_nao_vale() {
        val p = Porta()
        val s = SegurarParaRolar(p)
        s.encostou(0, Botao.BAIXO)
        assertFalse(s.inverter(true))
        assertFalse(s.invertido)
        s.encostou(1, Botao.CIMA) // o segundo dedo segue o mapeamento de sempre
        s.saiu(1)
        s.saiu(0)
        assertTrue("sem dedo, vale", s.inverter(true))
        assertTrue(s.invertido)
        assertEquals(listOf("hold(false)", "hold(true)", "hold(false)", "release"), p.chamadas)
    }

    @Test
    fun um_dedo_segura_ao_encostar_e_solta_ao_sair() {
        val p = Porta()
        val s = SegurarParaRolar(p)
        s.encostou(0, Botao.BAIXO)
        assertEquals(Botao.BAIXO, s.seguro)
        assertEquals(Botao.BAIXO, s.ativo)
        s.saiu(0)
        assertNull(s.seguro)
        assertFalse(s.algumDedo)
        assertEquals(listOf("hold(false)", "release"), p.chamadas)
        // O mesmo dedo saindo de novo (o MOVE depois de escorregar para fora, o UP depois): nada.
        assertNull(s.saiu(0))
        assertEquals(2, p.chamadas.size)
    }

    /** Dois dedos: vale o último apertado; soltar só quando nenhum sobra. */
    @Test
    fun dois_dedos_vale_o_ultimo_e_solta_quando_nenhum_sobra() {
        val p = Porta()
        val s = SegurarParaRolar(p)
        s.encostou(0, Botao.CIMA)
        s.encostou(1, Botao.BAIXO)
        assertEquals(Botao.BAIXO, s.ativo)
        // O último sai: o que sobrou segura no sentido dele.
        s.saiu(1)
        assertEquals(Botao.CIMA, s.ativo)
        assertEquals(Botao.CIMA, s.seguro)
        s.saiu(0)
        assertEquals(listOf("hold(true)", "hold(false)", "hold(true)", "release"), p.chamadas)
    }

    /** O primeiro sai com o último ainda no botão: nada muda, e o soltar espera o último. */
    @Test
    fun o_primeiro_saindo_nao_muda_nada() {
        val p = Porta()
        val s = SegurarParaRolar(p)
        s.encostou(0, Botao.CIMA)
        s.encostou(1, Botao.BAIXO)
        assertNull(s.saiu(0))
        assertEquals(Botao.BAIXO, s.seguro)
        s.saiu(1)
        assertEquals(listOf("hold(true)", "hold(false)", "release"), p.chamadas)
    }

    /** Dois dedos no mesmo botão: sai um, o outro segue segurando sem mandar nada. */
    @Test
    fun dois_dedos_no_mesmo_botao() {
        val p = Porta()
        val s = SegurarParaRolar(p)
        s.encostou(3, Botao.BAIXO)
        s.encostou(4, Botao.BAIXO)
        assertNull(s.saiu(3))
        s.saiu(4)
        assertEquals(listOf("hold(false)", "hold(false)", "release"), p.chamadas)
    }

    /**
     * §12.4: `"segurando"` voltou a `false` com o dedo no botão — o texto parou. Nada aperta de novo
     * sozinho, nem o dedo que sobra quando o outro sai; o próximo aperto de verdade segura.
     */
    @Test
    fun o_texto_que_parou_nao_aperta_de_novo_sozinho() {
        val p = Porta()
        val s = SegurarParaRolar(p)
        s.encostou(0, Botao.CIMA)
        s.encostou(1, Botao.BAIXO)
        assertFalse(s.conferir(segurando = true))
        assertTrue("a queda com o dedo no botão", s.conferir(segurando = false))
        assertTrue(s.parou)
        assertFalse("avisa uma vez só", s.conferir(segurando = false))
        // O último dedo sai e sobra o outro, em outro botão: não segura de novo.
        assertNull(s.saiu(1))
        assertTrue(s.parou)
        // Soltar e apertar de novo: segura.
        s.saiu(0)
        assertFalse(s.parou)
        s.encostou(0, Botao.CIMA)
        assertEquals(Botao.CIMA, s.seguro)
        assertEquals(listOf("hold(true)", "hold(false)", "release", "hold(true)"), p.chamadas)
    }

    /** Um aperto de verdade com o texto parado (outro dedo) segura na hora, sem precisar soltar tudo. */
    @Test
    fun apertar_de_novo_com_outro_dedo_segura() {
        val p = Porta()
        val s = SegurarParaRolar(p)
        s.encostou(0, Botao.BAIXO)
        s.conferir(segurando = false)
        s.encostou(1, Botao.BAIXO)
        assertFalse(s.parou)
        assertEquals(Botao.BAIXO, s.seguro)
        assertEquals(listOf("hold(false)", "hold(false)"), p.chamadas)
    }

    /** `PROTOCOL` (o prompter não entende) ou `CLOSED`: nada seguro, e o dedo que sobra não tenta de novo. */
    @Test
    fun o_aperto_recusado_nao_segura_nem_tenta_de_novo() {
        val p = Porta(statusDoSegurar = QuallNative.Status.PROTOCOL)
        val s = SegurarParaRolar(p)
        s.encostou(0, Botao.CIMA)
        assertNull(s.seguro)
        assertEquals(QuallNative.Status.PROTOCOL, s.ultimoStatus)
        s.encostou(1, Botao.BAIXO)
        assertNull(s.saiu(1))
        assertFalse("sem nada seguro, não há o que parar", s.conferir(segurando = false))
        s.saiu(0)
        assertEquals(listOf("hold(true)", "hold(false)", "release"), p.chamadas)
    }

    /** O segundo plano e o fechar da tela soltam o que houver — e, sem dedo, não mandam nada. */
    @Test
    fun soltar_tudo() {
        val p = Porta()
        val s = SegurarParaRolar(p)
        assertNull(s.soltarTudo())
        s.encostou(0, Botao.CIMA)
        s.encostou(1, Botao.BAIXO)
        assertEquals(QuallNative.Status.OK, s.soltarTudo())
        assertFalse(s.algumDedo)
        assertNull(s.seguro)
        assertNull(s.saiu(0))
        assertEquals(listOf("hold(true)", "hold(false)", "release"), p.chamadas)
    }

    /** O "Rolar"/"Parar" manda só o que a pessoa apertou, e nunca reafirma o que já está. */
    @Test
    fun rolar_ou_parar_so_o_que_a_pessoa_apertou() {
        assertEquals(true, SegurarParaRolar.rolarOuParar(querRolar = true, rolandoAgora = false))
        assertEquals(false, SegurarParaRolar.rolarOuParar(querRolar = false, rolandoAgora = true))
        // O rótulo velho dizia "Rolar", mas o texto já rola (um segurar começou): nada de set_scrolling(true).
        assertNull(SegurarParaRolar.rolarOuParar(querRolar = true, rolandoAgora = true))
        assertNull(SegurarParaRolar.rolarOuParar(querRolar = false, rolandoAgora = false))
        // No controle, nunca durante o segurar — nem para parar.
        assertNull(SegurarParaRolar.rolarOuParar(querRolar = false, rolandoAgora = true, segurandoAgora = true))
    }

    @Test
    fun a_situacao_por_ordem_de_importancia() {
        fun sit(sem: String? = null, visto: Boolean = true, entende: Boolean = true, recusado: Boolean = false,
                parou: Boolean = false, naoChegou: Boolean = false) =
            SegurarParaRolar.situacao(sem, visto, entende, recusado, parou, naoChegou, PT)

        assertEquals(SegurarParaRolar.Situacao(true, null), sit())
        assertEquals(SegurarParaRolar.Situacao(false, "Conectando…"), sit(sem = "Conectando…", entende = false))
        assertEquals(
            SegurarParaRolar.Situacao(false, "O texto parou. O prompter não responde. Esperando…"),
            sit(sem = "O prompter não responde. Esperando…", parou = true),
        )
        assertEquals(SegurarParaRolar.Situacao(false, PT.s(R.string.tp_segurar_esperando)), sit(visto = false, entende = false))
        assertEquals(SegurarParaRolar.Situacao(false, PT.s(R.string.tp_segurar_atualize)), sit(entende = false, parou = true))
        assertEquals(SegurarParaRolar.Situacao(false, PT.s(R.string.tp_segurar_atualize)), sit(recusado = true))
        assertEquals(SegurarParaRolar.Situacao(true, PT.s(R.string.tp_segurar_parou)), sit(parou = true, naoChegou = true))
        assertEquals(SegurarParaRolar.Situacao(true, PT.s(R.string.tp_segurar_nao_chegou)), sit(naoChegou = true))
        assertEquals("Atualize o app do prompter para usar este modo", PT.s(R.string.tp_segurar_atualize))
        assertEquals("O texto parou. Solte e aperte de novo.", PT.s(R.string.tp_segurar_parou))
    }

    /** Em inglês, o texto que o iOS fixou para a tabela do §6 (`Teleprompter.strings`). */
    @Test
    fun as_legendas_e_os_avisos_em_ingles() {
        assertEquals("moves the text back", SegurarParaRolar.efeito(Botao.CIMA, EN))
        assertEquals("moves the text forward", SegurarParaRolar.efeito(Botao.CIMA, EN, invertido = true))
        assertEquals(SegurarParaRolar.Situacao(false, "Update the app on the prompter to use this mode"),
            SegurarParaRolar.situacao(null, true, false, false, false, false, EN))
        assertEquals(SegurarParaRolar.Situacao(true, "The text stopped. Release and press again."),
            SegurarParaRolar.situacao(null, true, true, false, true, false, EN))
    }
}
