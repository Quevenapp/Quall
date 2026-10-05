package com.quall.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Testes de [Entrega]. Os casos são os de 10/09/2026 (`docs/bancada.md` §8.69): o S24 com "4K 60"
 * na frontal, que saiu em 1920x1080 a 60 sem ninguém dizer por quê.
 */
class EntregaTest {

    /** As frases em português, o texto-fonte (`docs/traducao.md`). */
    private val pt = TextosDeTeste.PT

    private val semTamanho = Entrega.Camera(ofereceOTamanhoPedido = false, quadrosNoTamanhoPedido = null)

    @Test
    fun o_pedido_atendido_nao_tem_motivo() {
        val e = Entrega.daCamera(pt, Resolucao.P1080, 60, 1920 to 1080, 60,
            Entrega.Camera(true, 60))
        assertEquals("1080p a 60 fps", e.pedido)
        assertEquals("1920x1080 a 60 fps", e.entregue)
        assertNull(e.motivo)
    }

    /** O caso do dia: a câmera não tem o tamanho, e a frase diz isso — não "o sistema baixou". */
    @Test
    fun a_camera_que_nao_oferece_4k_diz_isso() {
        val e = Entrega.daCamera(pt, Resolucao.P2160, 60, 1920 to 1080, 60, semTamanho)
        assertEquals("4K a 60 fps", e.pedido)
        assertEquals("1920x1080 a 60 fps", e.entregue)
        assertEquals("esta câmera não oferece 4K", e.motivo)
    }

    /** A câmera tem 4K, mas só a 30: é outra frase, e ela sugere a outra combinação. */
    @Test
    fun a_camera_que_faz_4k_so_a_30_diz_o_teto_dela() {
        val e = Entrega.daCamera(pt, Resolucao.P2160, 60, 1920 to 1080, 60,
            Entrega.Camera(ofereceOTamanhoPedido = true, quadrosNoTamanhoPedido = 30))
        assertEquals("esta câmera faz 4K só até 30 fps", e.motivo)
    }

    /** Sem fato que explique, a frase diz que não sabe — e não escolhe um culpado. */
    @Test
    fun sem_fato_que_explique_o_motivo_e_desconhecido() {
        val e = Entrega.daCamera(pt, Resolucao.P2160, 60, 1920 to 1080, 60,
            Entrega.Camera(ofereceOTamanhoPedido = true, quadrosNoTamanhoPedido = 60))
        assertTrue(e.motivo!!, e.motivo.contains("não foi identificado"))
    }

    /** A câmera negociou menos fps: a frase diz o número, sem nomear um culpado que não sabe. */
    @Test
    fun a_camera_que_negocia_menos_fps_diz_o_numero() {
        val e = Entrega.daCamera(pt, Resolucao.P1080, 60, 1920 to 1080, 30,
            Entrega.Camera(true, 60))
        assertEquals("1920x1080 a 30 fps", e.entregue)
        assertEquals("a câmera ficou em 30 fps", e.motivo)
    }

    @Test
    fun antes_de_a_camera_negociar_nao_ha_entrega() {
        val e = Entrega.daCamera(pt, Resolucao.P2160, 60, null, null, semTamanho)
        assertEquals("", e.entregue)
        assertNull(e.motivo)
    }

    /** O arredondamento da proporção não é "menor que o pedido": 976x2116 é o 1080p de um S24 em pé. */
    @Test
    fun na_tela_a_proporcao_do_painel_nao_vira_motivo() {
        val e = Entrega.daTela(pt, Resolucao.P1080, 60, painel = 1440 to 3120,
            entregue = 976 to 2116)
        assertNull(e.motivo)
    }

    /** 4K pedido numa tela de 1440x3120: quem limita é o painel, e a frase diz o tamanho dele. */
    @Test
    fun na_tela_o_painel_menor_que_o_pedido_e_o_motivo() {
        val e = Entrega.daTela(pt, Resolucao.P2160, 60, painel = 1440 to 3120,
            entregue = 1440 to 3120)
        assertEquals("a tela deste aparelho tem 1440x3120", e.motivo)
    }

    @Test
    fun na_tela_um_corte_alem_do_painel_e_do_pedido_nao_tem_culpado_inventado() {
        val e = Entrega.daTela(pt, Resolucao.P2160, 60, painel = 1440 to 3120,
            entregue = 720 to 1560)
        assertTrue(e.motivo!!, e.motivo.contains("não foi identificado"))
    }

    /** O inglês diz o mesmo, com "at" e a taxa com ponto. */
    @Test
    fun em_ingles_a_mesma_entrega() {
        val e = Entrega.daCamera(TextosDeTeste.EN, Resolucao.P2160, 60, 1920 to 1080, 60, semTamanho)
        assertEquals("4K at 60 fps", e.pedido)
        assertEquals("1920x1080 at 60 fps", e.entregue)
        assertEquals("1920×1080 · 60 fps", e.curto)
        assertEquals("this camera doesn’t offer 4K", e.motivo)
        val fixa = Entrega.fixa(TextosDeTeste.EN, "the DVD", 720, 480, 29.97)
        assertEquals("720x480 at 29.97 fps", fixa.entregue)
    }

    /** A forma curta da linha do alto, e a taxa da fita com vírgula em português. */
    @Test
    fun a_forma_curta_e_a_taxa_quebrada() {
        val tela = Entrega.daTela(pt, Resolucao.P1080, 60, painel = 1440 to 3120, entregue = 976 to 2116)
        assertEquals("976x2116 a até 60 fps", tela.entregue)
        assertEquals("976×2116 · até 60 fps", tela.curto)
        val fita = Entrega.fixa(pt, "a filmadora DV", 854, 480, 29.97)
        assertEquals("854x480 a 29,97 fps", fita.entregue)
        assertEquals("854×480 · 29,97 fps", fita.curto)
    }
}
