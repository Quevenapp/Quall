package com.quall.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** O cardápio de resolução com a filmadora DV (pedido do Pessoa Exemplo, 22/09/2026). */
class SeletorDeResolucaoTest {

    @Test
    fun a_filmadora_desativa_o_cardapio_e_diz_por_que() {
        val e = SeletorDeResolucao.estado(fonteEhFilmadoraDv = true)
        assertFalse(e.ativo)
        val nota = TextosDeTeste.PT.s(e.nota!!)
        assertTrue(nota, nota.startsWith("A fita define o tamanho"))
        assertTrue(nota.contains("1280×720"))
    }

    @Test
    fun a_camera_do_celular_e_a_tela_deixam_o_cardapio_ativo_com_a_nota_de_custo() {
        val e = SeletorDeResolucao.estado(fonteEhFilmadoraDv = false)
        assertTrue(e.ativo)
        assertNull(e.nota)
    }

    /** A placa de captura também desativa, com a frase dela (sem "fita"; §11, item 2). */
    @Test
    fun a_placa_desativa_o_cardapio_com_a_frase_dela() {
        val e = SeletorDeResolucao.estado(fonteEhFilmadoraDv = true, daPlaca = true)
        assertFalse(e.ativo)
        val nota = TextosDeTeste.PT.s(e.nota!!)
        assertTrue(nota, nota.startsWith("A placa define o tamanho"))
        assertFalse(nota.contains("fita"))
        assertTrue(nota.contains("640×480"))
        assertFalse(TextosDeTeste.EN.s(e.nota!!).contains("tape"))
        // "é placa" sem vídeo USB não vale nada: a câmera do celular segue ativa
        assertTrue(SeletorDeResolucao.estado(fonteEhFilmadoraDv = false, daPlaca = true).ativo)
    }

    /** Ir e voltar não mexe em nada além do estado: a escolha salva é da tela, e fica. */
    @Test
    fun ir_e_voltar_devolve_o_estado_inicial() {
        val antes = SeletorDeResolucao.estado(false)
        SeletorDeResolucao.estado(true)
        assertEquals(antes, SeletorDeResolucao.estado(false))
    }

    /** O A07 (06/10): até 30 fps em tudo e sem 4K. O 60 e o 4K se apagam, e o salvo em 60 vai a 30. */
    @Test
    fun o_que_a_camera_nao_faz_fica_apagado() {
        val a07 = mapOf(Resolucao.P720 to 30, Resolucao.P1080 to 30, Resolucao.P1440 to 30, Resolucao.P2160 to null)
        val e = SeletorDeResolucao.estado(false, tetos = a07, escolhida = Resolucao.P1080, fps = 60)
        assertTrue(e.ativo)
        assertEquals(setOf(Resolucao.P2160), e.resolucoesFora)
        assertEquals(setOf(60), e.taxasFora)
        assertEquals(30, e.fpsEfetivo)
        // Quem faz 60 não perde nada; sem tetos (a tela, ou nada legível), tudo disponível.
        val s24 = mapOf(Resolucao.P1080 to 60, Resolucao.P2160 to 30)
        val e2 = SeletorDeResolucao.estado(false, tetos = s24, escolhida = Resolucao.P1080, fps = 60)
        assertEquals(emptySet<Int>(), e2.taxasFora)
        assertEquals(null, e2.fpsEfetivo)
        assertEquals(setOf(60), SeletorDeResolucao.estado(false, tetos = s24, escolhida = Resolucao.P2160, fps = 30).taxasFora)
        assertEquals(SeletorDeResolucao.estado(false), SeletorDeResolucao.estado(false, tetos = emptyMap()))
    }

    /** Num teto 24, nenhum preset acima dele é oferecido; o indicador derivado não grava taxa. */
    @Test
    fun teto_vinte_e_quatro_desativa_os_dois_presets_e_indica_a_taxa_real() {
        val e = SeletorDeResolucao.estado(false, tetos = mapOf(Resolucao.P2160 to 24), escolhida = Resolucao.P2160, fps = 30)
        assertEquals(setOf(30, 60), e.taxasFora)
        assertEquals(24, e.fpsEfetivo)
        assertEquals(24, e.taxaSomenteLeitura(30))
        assertEquals(24, e.tetoDeQuadros)
    }

    @Test
    fun quatro_k_salvo_indisponivel_usa_dois_k_e_o_teto_desse_tamanho() {
        val tetos = mapOf(Resolucao.P720 to 60, Resolucao.P1080 to 60,
            Resolucao.P1440 to 30, Resolucao.P2160 to null)
        val salva = Resolucao.P2160
        val e = SeletorDeResolucao.estado(false, tetos = tetos, escolhida = salva, fps = 60)
        assertEquals(Resolucao.P1440, e.resolucaoPara(salva))
        assertEquals(30, e.quadrosPara(60))
        assertNull(e.taxaSomenteLeitura(60))
        assertEquals(setOf(60), e.taxasFora)
        // Voltar à tela recupera a escolha: o estado não altera a entrada nem a preferência.
        val tela = SeletorDeResolucao.estado(false, escolhida = salva, fps = 60)
        assertEquals(Resolucao.P2160, tela.resolucaoPara(salva))
        assertEquals(60, tela.quadrosPara(60))
    }

    @Test
    fun trocar_camera_recalcula_o_tamanho_e_a_taxa_sem_carregar_o_fallback_anterior() {
        val salva = Resolucao.P2160
        val traseira = mapOf(Resolucao.P720 to 30, Resolucao.P1080 to 30,
            Resolucao.P1440 to null, Resolucao.P2160 to null)
        val frontal = traseira + (Resolucao.P1440 to 45)
        val a = SeletorDeResolucao.estado(false, tetos = traseira, escolhida = salva, fps = 60)
        val b = SeletorDeResolucao.estado(false, tetos = frontal, escolhida = salva, fps = 60)
        assertEquals(Resolucao.P1080, a.resolucaoPara(salva))
        assertEquals(30, a.quadrosPara(60))
        assertEquals(Resolucao.P1440, b.resolucaoPara(salva))
        assertEquals(45, b.quadrosPara(60))
        assertEquals(45, b.taxaSomenteLeitura(60))
    }

    @Test
    fun teto_quarenta_e_cinco_e_independente_da_escolha_trinta() {
        val e = SeletorDeResolucao.estado(false, tetos = mapOf(Resolucao.P1080 to 45), fps = 30)
        assertNull(e.fpsEfetivo)
        assertEquals(30, e.quadrosPara(30))
        assertNull(e.taxaSomenteLeitura(30))
        assertEquals(45, e.tetoDeQuadros)
        assertEquals(setOf(60), e.taxasFora)
    }

    @Test
    fun desconhecido_nao_vira_fallback_inventado_nem_taxa_zero() {
        val desconhecido = SeletorDeResolucao.estado(false,
            tetos = mapOf(Resolucao.P1080 to 30), escolhida = Resolucao.P2160, fps = 60)
        assertNull(desconhecido.resolucaoEfetiva)
        assertNull(desconhecido.fpsEfetivo)
        val todosFora = SeletorDeResolucao.estado(false,
            tetos = Resolucao.entries.associateWith { null }, escolhida = Resolucao.P2160, fps = 60)
        assertNull(todosFora.resolucaoEfetiva)
        val invalido = SeletorDeResolucao.estado(false,
            tetos = mapOf(Resolucao.P2160 to null, Resolucao.P1080 to 0), escolhida = Resolucao.P2160, fps = 60)
        assertNull(invalido.resolucaoEfetiva)
        assertNull(invalido.tetoDeQuadros)
    }

    @Test
    fun sem_tamanho_menor_o_fallback_e_o_menor_oferecido_acima() {
        val e = SeletorDeResolucao.estado(false,
            tetos = mapOf(Resolucao.P720 to null, Resolucao.P1080 to 30, Resolucao.P1440 to 60),
            escolhida = Resolucao.P720, fps = 60)
        assertEquals(Resolucao.P1080, e.resolucaoPara(Resolucao.P720))
        assertEquals(30, e.quadrosPara(60))
    }

    @Test
    fun encoder_usa_o_teto_da_camera_e_depois_o_menor_teto_negociado() {
        val e = SeletorDeResolucao.estado(false, tetos = mapOf(Resolucao.P1080 to 30), fps = 60)
        assertEquals(30, e.quadrosParaCodificar(60))
        assertEquals(24, e.quadrosParaCodificar(60, 24))
        // Um relato maior não eleva o pedido acima da capacidade; inválido não vira fps zero.
        assertEquals(30, e.quadrosParaCodificar(60, 60))
        assertEquals(30, e.quadrosParaCodificar(60, 0))
        assertEquals(30, e.quadrosParaCodificar(60, -1))
        // A tela não tem mapa de câmera: a escolha 60 continua 60.
        assertEquals(60, SeletorDeResolucao.estado(false).quadrosParaCodificar(60))
    }
}
