package com.quall.android.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [FilaDoCodificador]: a conta dos quadros dentro de um codificador do divisor e a porta
 * (`docs/teleprompter-com-camera.md` §14.11, §14.12 achado 1). Na JVM, com a câmera a 30 fps.
 */
class FilaDoCodificadorTest {

    private val passo = 33_333L

    @Test
    fun desligada_nada_e_barrado_mas_a_conta_existe() {
        val f = FilaDoCodificador(teto = 0)
        for (i in 0 until 20) {
            assertTrue(f.deveDesenhar(i * passo))
            f.desenhou(i * passo)
        }
        f.saiu(4 * passo)
        assertEquals(15, f.emTransito())
        assertEquals(0L, f.pulados)
    }

    @Test
    fun antes_do_primeiro_quadro_sair_nada_e_barrado() {
        val f = FilaDoCodificador(teto = 3)
        for (i in 0 until 10) {
            assertTrue(f.deveDesenhar(i * passo))
            f.desenhou(i * passo)
        }
        assertEquals(10, f.emTransito())
    }

    @Test
    fun com_o_teto_cheio_pula_e_reabre_quando_o_codificador_solta() {
        val f = FilaDoCodificador(teto = 3)
        f.deveDesenhar(0); f.desenhou(0)
        f.saiu(0)
        for (i in 1..3) { assertTrue(f.deveDesenhar(i * passo)); f.desenhou(i * passo) }
        // 3 em trânsito: o quarto espera.
        assertFalse(f.deveDesenhar(4 * passo))
        assertEquals(1L, f.pulados)
        // O codificador soltou o primeiro deles: a porta reabre já, sem esperar a sonda (o achado 1).
        f.saiu(1 * passo)
        assertTrue(f.deveDesenhar(5 * passo))
    }

    @Test
    fun o_quadro_que_o_codificador_descarta_sai_da_conta_quando_um_mais_novo_sai() {
        val f = FilaDoCodificador(teto = 3)
        for (i in 0..3) { f.deveDesenhar(i * passo); f.desenhou(i * passo) }
        // Os quadros 1 e 2 nunca saem (o `KEY_MAX_FPS_TO_ENCODER` os jogou fora); o 3 sai.
        f.saiu(0)
        f.saiu(3 * passo)
        assertEquals(0, f.emTransito())
    }

    @Test
    fun a_sonda_passa_um_quadro_contra_o_impasse() {
        val f = FilaDoCodificador(teto = 2)
        f.deveDesenhar(0); f.desenhou(0); f.saiu(0)
        f.deveDesenhar(passo); f.desenhou(passo)
        f.deveDesenhar(2 * passo); f.desenhou(2 * passo)
        // O codificador parou de soltar: tudo barrado até passar a sonda desde o último desenhado.
        var t = 3 * passo
        while (t - 2 * passo < FilaDoCodificador.SONDA_US) {
            assertFalse(f.deveDesenhar(t))
            t += passo
        }
        assertTrue(f.deveDesenhar(t))
        assertEquals(1L, f.sondas)
    }

    @Test
    fun a_linha_da_janela_diz_o_maximo_e_zera() {
        val f = FilaDoCodificador(teto = 0)
        for (i in 0 until 5) { f.deveDesenhar(i * passo); f.desenhou(i * passo) }
        val l = f.linhaDaJanela()
        assertTrue(l, l.contains("p50/max=2/4 "))
        assertTrue(l, l.contains("porta desligada"))
        assertTrue(f.linhaDaJanela().contains("p50/max=0/0"))
    }
}
