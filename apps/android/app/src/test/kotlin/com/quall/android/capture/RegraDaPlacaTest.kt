package com.quall.android.capture

import com.quall.android.capture.dv.Formato
import com.quall.android.capture.dv.Quadro
import com.quall.android.capture.dv.RegraDaPlaca
import com.quall.android.capture.dv.TipoUsb
import com.quall.android.capture.dv.VideoUsb
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.core.TextosDeTeste.Companion.PT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **A regra da placa de hoje** (`docs/placa-de-captura-usb.md` §11, item 2), isolada para mudar com
 * as placas HDMI: estes testes dizem o que ela aceita e recusa agora. Quando a regra mudar (depois de
 * medir os descritores das placas novas), o caso da placa HDMI abaixo é o que troca de lado.
 */
class RegraDaPlacaTest {
    private fun mjpeg(vararg tamanhos: Pair<Int, Int>) = Formato(0x06, 1, "MJPEG").also { f ->
        tamanhos.forEachIndexed { i, (w, h) -> f.quadros += Quadro(i + 1, w, h, 333333, listOf(333333)) }
    }
    private fun yuy2() = Formato(0x04, 2, "subtipo-0x04")
    private fun h264() = Formato(0x10, 3, "subtipo-0x10")

    @Test
    fun a_easycap_medida_passa() {
        val v = RegraDaPlaca.julgar(listOf(mjpeg(640 to 480)))
        assertTrue(v.porque, v.aceita)
    }

    @Test
    fun pal_720x576_ainda_e_placa() {
        assertTrue(RegraDaPlaca.aceita(listOf(mjpeg(720 to 576, 640 to 480))))
    }

    @Test
    fun webcam_com_yuy2_nao_passa_e_diz_por_que() {
        val v = RegraDaPlaca.julgar(listOf(mjpeg(640 to 480), yuy2()))
        assertFalse(v.aceita)
        assertTrue(v.porque, v.porque.contains("0x04"))
    }

    @Test
    fun frame_based_nao_passa() {
        assertFalse(RegraDaPlaca.aceita(listOf(mjpeg(640 to 480), h264())))
    }

    @Test
    fun mjpeg_acima_de_720x576_nao_passa() {
        val v = RegraDaPlaca.julgar(listOf(mjpeg(640 to 480, 1280 to 720)))
        assertFalse(v.aceita)
        assertTrue(v.porque, v.porque.contains("1280x720"))
    }

    @Test
    fun sem_quadro_mjpeg_nao_passa() {
        assertFalse(RegraDaPlaca.aceita(listOf(Formato(0x06, 1, "MJPEG"))))
        assertFalse(RegraDaPlaca.aceita(emptyList()))
    }

    /**
     * **A placa HDMI típica** (hipótese do que o Pessoa Exemplo vai trazer: MJPEG e YUY2 até 1080p): hoje é
     * recusada. É o caso que muda de lado quando a regra for trocada — com a medida na mão.
     */
    @Test
    fun a_placa_hdmi_tipica_hoje_e_recusada() {
        assertFalse(RegraDaPlaca.aceita(listOf(mjpeg(1920 to 1080, 1280 to 720, 640 to 480), yuy2())))
    }

    // ------------------------------------------------------------------ como a tela a mostra

    @Test
    fun os_rotulos_por_tipo() {
        assertEquals("Placa de captura (USB2.0 PC CAMERA)", VideoUsb.rotulo(PT, VideoUsb.conhecido(TipoUsb.MJPEG, false), "USB2.0 PC CAMERA"))
        assertEquals("Filmadora DV (GS500)", VideoUsb.rotulo(PT, VideoUsb.conhecido(TipoUsb.DV, false), "GS500"))
        assertEquals("Vídeo USB (X)", VideoUsb.rotulo(PT, VideoUsb.conhecido(null, false), "X"))
        assertEquals("Vídeo USB (X)", VideoUsb.rotulo(PT, VideoUsb.conhecido(null, true), "X"))
        assertEquals("Capture card (USB2.0 PC CAMERA)", VideoUsb.rotulo(EN, VideoUsb.Conhecido.PLACA, "USB2.0 PC CAMERA"))
        assertEquals("DV camcorder (GS500)", VideoUsb.rotulo(EN, VideoUsb.Conhecido.FILMADORA_DV, "GS500"))
        // a abertura bem-sucedida vale mais que uma recusa velha
        assertEquals(VideoUsb.Conhecido.PLACA, VideoUsb.conhecido(TipoUsb.MJPEG, true))
    }

    @Test
    fun a_placa_para_todos_e_a_filmadora_so_com_a_chave() {
        val c = VideoUsb.Conhecido.entries
        // sem a chave: a placa sempre; a filmadora e a recusada, nunca; a desconhecida, pelo palpite do som
        assertTrue(VideoUsb.naLista(VideoUsb.Conhecido.PLACA, temSom = false, chaveDv = false))
        assertFalse(VideoUsb.naLista(VideoUsb.Conhecido.FILMADORA_DV, temSom = true, chaveDv = false))
        assertFalse(VideoUsb.naLista(VideoUsb.Conhecido.RECUSADO, temSom = true, chaveDv = false))
        assertTrue(VideoUsb.naLista(VideoUsb.Conhecido.DESCONHECIDO, temSom = true, chaveDv = false))
        assertFalse(VideoUsb.naLista(VideoUsb.Conhecido.DESCONHECIDO, temSom = false, chaveDv = false))
        // com a chave, tudo, como antes
        for (k in c) for (som in listOf(true, false)) assertTrue(VideoUsb.naLista(k, som, chaveDv = true))
    }

    @Test
    fun o_palpite_de_placa() {
        assertTrue(VideoUsb.pareceSerPlaca(VideoUsb.Conhecido.PLACA, temSom = false))
        assertTrue(VideoUsb.pareceSerPlaca(VideoUsb.Conhecido.DESCONHECIDO, temSom = true))
        assertFalse(VideoUsb.pareceSerPlaca(VideoUsb.Conhecido.DESCONHECIDO, temSom = false))
        assertFalse(VideoUsb.pareceSerPlaca(VideoUsb.Conhecido.FILMADORA_DV, temSom = true))
        assertEquals("a placa de captura", VideoUsb.nome(PT, VideoUsb.Conhecido.PLACA))
        assertEquals("a filmadora", VideoUsb.nome(PT, VideoUsb.Conhecido.FILMADORA_DV))
        assertEquals("the capture card", VideoUsb.nome(EN, VideoUsb.Conhecido.PLACA))
    }
}
