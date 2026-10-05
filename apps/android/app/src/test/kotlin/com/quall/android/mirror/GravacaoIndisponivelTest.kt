package com.quall.android.mirror

import com.quall.android.capture.EtapaDaAbertura
import com.quall.android.capture.ParametrosDaGravacao
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.core.TextosDeTeste.Companion.PT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [GravacaoIndisponivel.decidir]: quando o aparelho diz "não grava" antes do toque
 * (`docs/teleprompter-com-camera.md` §14.3, caso 1, e a revisão da D1, 12). E o recuo da 720 (§14.4).
 */
class GravacaoIndisponivelTest {

    @Test
    fun o_aparelho_comum_grava() {
        assertNull(GravacaoIndisponivel.decidir(PT, false, 0, null, 32, "c2.mtk.avc.encoder", false))
        assertNull(GravacaoIndisponivel.decidir(PT, false, 0, null, null, null, false))
    }

    @Test
    fun a_bandeira_de_bancada_forca() {
        assertEquals("bancada: sem_gravador", GravacaoIndisponivel.decidir(PT, true, 0, null, 32, "x", true))
    }

    @Test
    fun uma_falha_so_nao_marca_duas_marcam() {
        assertNull(GravacaoIndisponivel.decidir(PT, false, 1, EtapaDaAbertura.CODIFICADOR_DE_VIDEO.codigo, 32, "x", false))
        val m = GravacaoIndisponivel.decidir(PT, false, 2, EtapaDaAbertura.CODIFICADOR_DE_VIDEO.codigo, 32, "x", false)
        assertNotNull(m)
        assertEquals("a gravação falhou ao abrir 2 vezes neste aparelho: o codificador de vídeo não abriu", m)
    }

    /**
     * **Guardado é código** (`docs/traducao.md`, Android): a etapa guardada vira frase no idioma de quem
     * pergunta; um texto que não é código (a frase de uma versão antiga) não vaza para a tela.
     */
    @Test
    fun a_etapa_guardada_vira_frase_no_idioma_de_agora() {
        assertEquals("recording failed to start 2 times on this device: the audio encoder didn’t open",
            GravacaoIndisponivel.decidir(EN, false, 2, EtapaDaAbertura.CODIFICADOR_DE_SOM.codigo, 32, "x", false))
        assertEquals("a gravação falhou ao abrir 3 vezes neste aparelho",
            GravacaoIndisponivel.decidir(PT, false, 3, "o codificador recusou 1080x1920", 32, "x", false))
        assertEquals("a gravação falhou ao abrir 2 vezes neste aparelho",
            GravacaoIndisponivel.decidir(PT, false, 2, EtapaDaAbertura.OUTRA.codigo, 32, "x", false))
        assertEquals("o codificador H.264 OMX.x abre 1 de cada vez (a rede e a gravação pedem 2)",
            GravacaoIndisponivel.decidir(PT, false, 0, null, 1, "OMX.x", false))
        for (e in EtapaDaAbertura.entries) assertEquals(e, EtapaDaAbertura.deCodigo(e.codigo))
    }

    @Test
    fun uma_instancia_so_nao_grava_a_menos_que_ja_tenha_gravado() {
        assertNotNull(GravacaoIndisponivel.decidir(PT, false, 0, null, 1, "OMX.x", false))
        assertNull(GravacaoIndisponivel.decidir(PT, false, 0, null, 1, "OMX.x", true))
        assertNull(GravacaoIndisponivel.decidir(PT, false, 0, null, 2, "OMX.x", false))
    }

    @Test
    fun a_mensagem_e_a_do_desenho() {
        assertEquals("Este aparelho não grava vídeo; ele só transmite.\nPara gravar, use o OBS no computador que recebe.",
            GravacaoIndisponivel.mensagem(PT))
        // O legado em português (até a MainActivity e a tela R5 passarem a `mensagem(t)`) diz o mesmo.
        assertEquals(GravacaoIndisponivel.mensagem(PT), GravacaoIndisponivel.MENSAGEM)
        assertEquals("This device can’t record video; it can only send.\nTo record, use OBS on the receiving computer.",
            GravacaoIndisponivel.mensagem(EN))
    }

    @Test
    fun o_recuo_da_720_mantem_a_proporcao_e_nao_mexe_no_que_cabe() {
        assertEquals(720 to 1280, ParametrosDaGravacao.teto720(1080, 1920))
        assertEquals(1280 to 720, ParametrosDaGravacao.teto720(1920, 1080))
        assertEquals(720 to 1280, ParametrosDaGravacao.teto720(720, 1280))
        assertEquals(640 to 480, ParametrosDaGravacao.teto720(640, 480))
        // 4:3 grande: o lado menor manda.
        assertEquals(960 to 720, ParametrosDaGravacao.teto720(1440, 1080))
    }
}
