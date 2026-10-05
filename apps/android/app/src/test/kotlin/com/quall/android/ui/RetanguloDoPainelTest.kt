package com.quall.android.ui

import com.quall.android.ui.RetanguloDoPainel.Recuos
import com.quall.android.ui.RetanguloDoPainel.Ret
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** O retângulo do painel "Ajustes da câmera" dentro da área útil, com as barras de qualquer lado. */
class RetanguloDoPainelTest {

    @Test
    fun a_r5_do_a10s_deitado_com_a_barra_a_direita() {
        // O dumpsys de 01/10: a janela 1520×720, o texto 0,0-1520,360, a barra de navegação de 139 px à direita.
        val p = RetanguloDoPainel.daR5(Ret(0, 0, 1520, 360), 1520, 720, Recuos(direita = 139))
        assertEquals(Ret(0, 0, 1381, 360), p)
        // O "Pronto" fica no canto de cima à direita do painel: dentro da área útil.
        assertTrue(p.direita <= 1520 - 139)
    }

    @Test
    fun deitado_ao_contrario_a_barra_fica_a_esquerda() {
        // Rotação 270: a barra de navegação à esquerda, e o recorte da câmera também pode cair ali.
        val p = RetanguloDoPainel.daR5(Ret(0, 0, 1520, 360), 1520, 720, Recuos(esquerda = 139))
        assertEquals(Ret(139, 0, 1520, 360), p)
    }

    @Test
    fun em_pe_a_barra_de_status_corta_o_alto() {
        val p = RetanguloDoPainel.daR5(Ret(0, 0, 720, 760), 720, 1520, Recuos(topo = 42, baixo = 84))
        assertEquals(Ret(0, 42, 720, 760), p)
        // Um texto embaixo (a R5 de ponta-cabeça): a barra de navegação corta o pé.
        assertEquals(Ret(0, 760, 720, 1436), RetanguloDoPainel.daR5(Ret(0, 760, 720, 1520), 720, 1520, Recuos(topo = 42, baixo = 84)))
    }

    @Test
    fun sem_barras_o_retangulo_e_o_do_texto() {
        assertEquals(Ret(10, 20, 300, 400), RetanguloDoPainel.daR5(Ret(10, 20, 300, 400), 1000, 1000, Recuos()))
        // Um texto inteiro debaixo da barra não vira retângulo negativo.
        val vazio = RetanguloDoPainel.daR5(Ret(1400, 0, 1520, 360), 1520, 720, Recuos(direita = 139))
        assertEquals(0, vazio.largura)
    }

    @Test
    fun a_camera_comum_em_pe_e_deitada_dos_dois_lados() {
        val (emPe, previaEmPe) = RetanguloDoPainel.daCameraComum(720, 1520, Recuos(topo = 42, baixo = 84), deitado = false)
        assertEquals(Ret(0, 739, 720, 1436), emPe)
        assertEquals(Ret(0, 0, 720, 739), previaEmPe)
        val (direita, previa) = RetanguloDoPainel.daCameraComum(1520, 720, Recuos(topo = 42, direita = 139), deitado = true)
        assertEquals(Ret(690, 42, 1381, 720), direita)
        assertEquals(Ret(0, 0, 690, 720), previa)
        val (esq, _) = RetanguloDoPainel.daCameraComum(1520, 720, Recuos(esquerda = 139), deitado = true)
        assertEquals(Ret(829, 0, 1520, 720), esq)
    }
}
