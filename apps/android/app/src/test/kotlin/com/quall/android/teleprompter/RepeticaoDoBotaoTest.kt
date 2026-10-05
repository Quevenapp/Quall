package com.quall.android.teleprompter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** O ritmo da tartaruga e do coelho: o mesmo do iOS (`RepeticaoDoBotao.swift`). */
class RepeticaoDoBotaoTest {
    @Test
    fun a_primeira_repeticao_espera_e_as_outras_aceleram_ate_o_minimo() {
        assertEquals(0.4, RepeticaoDoBotao.intervalo(1)!!, 1e-12)
        assertEquals(0.18, RepeticaoDoBotao.intervalo(2)!!, 1e-12)
        assertEquals(0.18 * 0.85, RepeticaoDoBotao.intervalo(3)!!, 1e-12)
        var antes = Double.MAX_VALUE
        for (n in 2..RepeticaoDoBotao.TETO) {
            val v = RepeticaoDoBotao.intervalo(n)!!
            assertTrue("n=$n", v <= antes && v >= RepeticaoDoBotao.MINIMO_S)
            antes = v
        }
        assertEquals(0.05, RepeticaoDoBotao.intervalo(RepeticaoDoBotao.TETO)!!, 1e-12)
    }

    @Test
    fun fora_da_faixa_nao_ha_repeticao() {
        assertNull(RepeticaoDoBotao.intervalo(0))
        assertNull(RepeticaoDoBotao.intervalo(RepeticaoDoBotao.TETO + 1))
    }
}
