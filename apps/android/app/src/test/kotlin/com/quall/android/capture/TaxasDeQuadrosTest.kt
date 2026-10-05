package com.quall.android.capture

import com.quall.android.capture.dv.Preferencia
import com.quall.android.capture.dv.TaxasDeQuadros
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** O cardápio de quadros por segundo da placa (`docs/placa-de-captura-usb.md` §14.6). */
class TaxasDeQuadrosTest {
    @Test
    fun a_placa_a_60_oferece_tambem_50_30_25_e_24() {
        val c = TaxasDeQuadros.cardapio(listOf(166_666L))
        assertEquals(listOf(60, 50, 30, 25, 24), c.map { it.fps })
        assertTrue(c.first { it.fps == 60 }.daPlaca)
        // 30 sai de 60 com cadência regular (um de cada dois); 24, 25 e 50 não.
        assertTrue(c.first { it.fps == 30 }.regular)
        assertFalse(c.first { it.fps == 24 }.regular)
        assertFalse(c.first { it.fps == 50 }.regular)
        assertTrue(c.all { it.intervaloDaPlaca == 166_666L })
    }

    @Test
    fun com_120_e_60_o_24_sai_do_120_e_o_30_do_60() {
        val c = TaxasDeQuadros.cardapio(listOf(83_333L, 166_666L))
        assertEquals(listOf(120, 60, 50, 30, 25, 24), c.map { it.fps })
        val t24 = c.first { it.fps == 24 }
        assertEquals(83_333L, t24.intervaloDaPlaca)
        assertTrue(t24.regular)
        assertEquals(166_666L, c.first { it.fps == 30 }.intervaloDaPlaca)
    }

    @Test
    fun a_placa_a_30_so_desce_para_25_e_24() {
        assertEquals(listOf(30, 25, 24), TaxasDeQuadros.cardapio(listOf(333_333L)).map { it.fps })
    }

    @Test
    fun a_preferencia_antiga_sem_os_quadros_continua_valendo() {
        assertEquals(Preferencia("NV12", 1280, 720, 166_666L, 0), Preferencia.de("NV12;1280;720;166666"))
        val p = Preferencia("MJPEG", 1920, 1080, 166_666L, 24)
        assertEquals(p, Preferencia.de(p.texto()))
    }
}
