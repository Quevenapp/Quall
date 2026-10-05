package com.quall.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** As medidas fixas do painel "Ajustes da câmera": as abas e o "Pronto" cabem em qualquer altura de 150 dp ou mais. */
class MedidasDoPainelTest {

    @Test
    fun o_cromo_fixo_cabe_em_150_dp_e_sobra_corpo() {
        assertEquals(92, MedidasDoPainel.CROMO_FIXO_DP)
        for (altura in MedidasDoPainel.ALTURA_MINIMA_DP..900) {
            assertTrue("em $altura dp", MedidasDoPainel.corpoDp(altura) > 0)
            assertEquals(altura, MedidasDoPainel.CROMO_FIXO_DP + MedidasDoPainel.corpoDp(altura))
        }
    }

    @Test
    fun as_alturas_da_bancada() {
        // A R5 do A10s deitado: a metade do texto tem 360 px a 1,75 = ~206 dp; o corpo rola em 114 dp.
        assertEquals(114, MedidasDoPainel.corpoDp(206))
        // A câmera comum do A10s em pé (~386 dp): o corpo tem 294 dp, e a aba mais alta (222), o aviso (16) e o
        // "Restaurar" (40) cabem sem rolar.
        assertTrue(MedidasDoPainel.corpoDp(386) >= 222 + 16 + 40)
    }
}
