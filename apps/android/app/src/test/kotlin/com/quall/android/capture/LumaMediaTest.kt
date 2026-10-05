package com.quall.android.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A conta da luma média da bandeira `luma_media` (`docs/controles-de-camera.md` §5). */
class LumaMediaTest {

    private fun cheio(r: Int, g: Int, b: Int, n: Int = 256) = ByteArray(4 * n) { i ->
        when (i % 4) { 0 -> r; 1 -> g; 2 -> b; else -> 255 }.toByte()
    }

    @Test
    fun branco_e_preto_e_os_pesos_da_bt709() {
        assertEquals(255.0, LumaMedia.de(cheio(255, 255, 255)), 1e-9)
        assertEquals(0.0, LumaMedia.de(cheio(0, 0, 0)), 1e-9)
        assertEquals(0.7152 * 255, LumaMedia.de(cheio(0, 255, 0)), 1e-9)
        assertEquals(0.2126 * 200, LumaMedia.de(cheio(200, 0, 0)), 1e-9)
    }

    @Test
    fun a_media_e_sobre_os_pixels_e_o_byte_e_sem_sinal() {
        val metade = cheio(255, 255, 255, 128) + cheio(0, 0, 0, 128)
        assertEquals(127.5, LumaMedia.de(metade), 1e-9)
        assertEquals(0.0, LumaMedia.de(ByteArray(0)), 0.0)
    }

    @Test
    fun o_fps_entre_dois_carimbos() {
        assertEquals(30.0, LumaMedia.fps(30, 0, 1_000_000_000)!!, 1e-9)
        assertNull(LumaMedia.fps(30, 5, 5))
    }
}
