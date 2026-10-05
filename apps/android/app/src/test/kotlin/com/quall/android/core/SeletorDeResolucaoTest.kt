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
}
