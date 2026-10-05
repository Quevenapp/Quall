package com.quall.android.teleprompter

import org.junit.Assert.assertEquals
import org.junit.Test

/** As duas setas laterais: independentes, com folga mínima, a margem sincronizada dentro delas. */
class EnquadramentoTest {

    @Test
    fun as_duas_andam_sozinhas_e_nao_se_cruzam() {
        val e = Enquadramento.INTEIRO.comEsquerda(0.25)
        assertEquals(Enquadramento(0.25, 1.0), e)
        assertEquals(Enquadramento(0.25, 0.9), e.comDireita(0.9))
        // A direita não passa da esquerda mais a folga de 20 %, e a esquerda não passa da direita menos ela.
        assertEquals(0.45, e.comDireita(0.3).direita, 1e-9)
        assertEquals(0.8, Enquadramento(0.0, 1.0).comEsquerda(0.95).esquerda, 1e-9)
        // Nem fora da tela.
        assertEquals(0.0, e.comEsquerda(-0.3).esquerda, 0.0)
        assertEquals(1.0, e.comDireita(1.7).direita, 0.0)
    }

    @Test
    fun a_coluna_do_texto_e_o_enquadramento_menos_a_margem_de_cada_lado() {
        // Largura inteira e margem 15 %: o que a vista fazia antes (a margem é da largura toda).
        val (x0, l0) = Enquadramento.INTEIRO.coluna(720, 0.15)
        assertEquals(108.0, x0, 1e-9)
        assertEquals(504.0, l0, 1e-9)
        // Setas em 0,2 e 0,9 (504 px entre elas) e margem 10 %: começa em 144 + 50,4, mede 403,2.
        val (x1, l1) = Enquadramento(0.2, 0.9).coluna(720, 0.1)
        assertEquals(194.4, x1, 1e-9)
        assertEquals(403.2, l1, 1e-9)
        // Centralizada entre as setas: sobra o mesmo dos dois lados.
        assertEquals((x1 - 0.2 * 720), (0.9 * 720 - (x1 + l1)), 1e-9)
    }

    @Test
    fun guardado_por_formato_e_ilegivel_vira_a_largura_inteira() {
        assertEquals(Enquadramento.RETRATO, Enquadramento.formato(720, 1600))
        assertEquals(Enquadramento.PAISAGEM, Enquadramento.formato(1600, 720))
        val e = Enquadramento(0.1234, 0.8765)
        assertEquals("0.1234,0.8765", e.guardado())
        assertEquals(e, Enquadramento.doGuardado(e.guardado()))
        assertEquals(Enquadramento.INTEIRO, Enquadramento.doGuardado(null))
        assertEquals(Enquadramento.INTEIRO, Enquadramento.doGuardado("lixo"))
        assertEquals(Enquadramento.INTEIRO, Enquadramento.doGuardado("0.6,0.7")) // mais estreita que a folga
        assertEquals(Enquadramento.INTEIRO, Enquadramento.doGuardado("-0.1,0.9"))
    }

    @Test
    fun as_marcas_ficam_longe_da_lente_na_tela_com_camera() {
        // O prompter comum: no alto, como sempre.
        org.junit.Assert.assertFalse(Enquadramento.marcasNoPe(null, 1000f))
        // A lente no alto do texto (em pé): as marcas no pé.
        org.junit.Assert.assertTrue(Enquadramento.marcasNoPe(0f, 1000f))
        // A lente no pé do texto (de ponta-cabeça): no alto.
        org.junit.Assert.assertFalse(Enquadramento.marcasNoPe(1000f, 1000f))
        // A lente de lado (deitado): no pé.
        org.junit.Assert.assertTrue(Enquadramento.marcasNoPe(500f, 1000f))
    }
}
