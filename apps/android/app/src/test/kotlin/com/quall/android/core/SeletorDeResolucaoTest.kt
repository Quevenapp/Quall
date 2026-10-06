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

    /** A menor taxa nunca se apaga: um 4K que só vai a 24 mantém o "30", que vai a 24. */
    @Test
    fun a_menor_taxa_nunca_se_apaga() {
        val e = SeletorDeResolucao.estado(false, tetos = mapOf(Resolucao.P2160 to 24), escolhida = Resolucao.P2160, fps = 30)
        assertEquals(setOf(60), e.taxasFora)
        assertEquals(24, e.fpsEfetivo)
    }
}
