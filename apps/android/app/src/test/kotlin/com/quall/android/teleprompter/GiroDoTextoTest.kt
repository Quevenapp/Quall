package com.quall.android.teleprompter

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/** Girar só o texto quando o sistema recusa a orientação: os quartos, e os pontos de um quadro no outro. */
class GiroDoTextoTest {

    @Test
    fun no_telefone_o_sistema_aceita_e_o_texto_nao_gira() {
        // Natural em retrato; a tela já está onde foi pedido.
        assertEquals(0, GiroDoTexto.quartos(Orientacao.RETRATO, 0, naturalEmPaisagem = false))
        assertEquals(0, GiroDoTexto.quartos(Orientacao.PAISAGEM, 1, naturalEmPaisagem = false))
        assertEquals(0, GiroDoTexto.quartos(Orientacao.PAISAGEM_INVERTIDA, 3, naturalEmPaisagem = false))
        // Automática nunca gira o texto, esteja a tela onde estiver.
        for (r in 0..3) assertEquals(0, GiroDoTexto.quartos(Orientacao.AUTOMATICA, r, naturalEmPaisagem = false))
    }

    @Test
    fun no_tablet_que_recusa_o_texto_gira_ate_a_orientacao_pedida() {
        // O SM-X230: natural em retrato (1200 × 1920), deitado no suporte, o sistema em 0.
        assertEquals(1, GiroDoTexto.quartos(Orientacao.PAISAGEM, 0, naturalEmPaisagem = false))
        assertEquals(3, GiroDoTexto.quartos(Orientacao.PAISAGEM_INVERTIDA, 0, naturalEmPaisagem = false))
        assertEquals(0, GiroDoTexto.quartos(Orientacao.RETRATO, 0, naturalEmPaisagem = false))
        // O sensor pôs a tela em paisagem (1), mas a pessoa pediu Retrato ou a invertida.
        assertEquals(3, GiroDoTexto.quartos(Orientacao.RETRATO, 1, naturalEmPaisagem = false))
        assertEquals(2, GiroDoTexto.quartos(Orientacao.PAISAGEM_INVERTIDA, 1, naturalEmPaisagem = false))
        // Um aparelho natural em paisagem: Paisagem é a rotação 0.
        assertEquals(0, GiroDoTexto.quartos(Orientacao.PAISAGEM, 0, naturalEmPaisagem = true))
        assertEquals(2, GiroDoTexto.quartos(Orientacao.PAISAGEM_INVERTIDA, 0, naturalEmPaisagem = true))
        assertEquals(3, GiroDoTexto.quartos(Orientacao.RETRATO, 0, naturalEmPaisagem = true))
    }

    @Test
    fun o_alto_do_texto_aponta_para_onde_o_sistema_poria_o_alto_da_tela() {
        // Paisagem num aparelho natural em retrato = o topo do aparelho à esquerda de quem olha: o
        // "alto" de quem lê é a borda direita natural. O alto do texto (−y no quadro dele) tem de
        // apontar para +x na vista com 1 quarto.
        val (w, h) = 1200f to 1920f
        val a = GiroDoTexto.doTextoParaAVista(1, w, h, 100f, 500f)
        val b = GiroDoTexto.doTextoParaAVista(1, w, h, 100f, 499f)
        assertEquals(1f, b[0] - a[0], 0f)
        assertEquals(0f, b[1] - a[1], 0f)
        // Paisagem invertida: o alto do texto aponta para −x (a borda esquerda natural).
        val c = GiroDoTexto.doTextoParaAVista(3, w, h, 100f, 500f)
        val d = GiroDoTexto.doTextoParaAVista(3, w, h, 100f, 499f)
        assertEquals(-1f, d[0] - c[0], 0f)
    }

    @Test
    fun ida_e_volta_entre_a_vista_e_o_texto_e_os_cantos_ficam_dentro() {
        val (w, h) = 1200f to 1920f
        for (q in 0..3) {
            val (lw, lh) = if (q % 2 == 0) w to h else h to w
            for ((x, y) in listOf(0f to 0f, 37f to 911f, lw to lh, lw / 2 to lh / 3)) {
                val v = GiroDoTexto.doTextoParaAVista(q, w, h, x, y)
                assertArrayEquals("q=$q", floatArrayOf(x, y), GiroDoTexto.daVistaParaOTexto(q, w, h, v[0], v[1]), 1e-3f)
                // Todo ponto do quadro do texto cai dentro da vista.
                assert(v[0] in 0f..w && v[1] in 0f..h) { "q=$q: ($x, $y) caiu fora da vista em (${v[0]}, ${v[1]})" }
            }
        }
    }
}
