package com.quall.android.teleprompter

import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.mirror.GravacaoDaTelaBus.Fase
import com.quall.android.teleprompter.DecisaoDaGravacao.Acao
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** [DecisaoDaGravacao]: o pedido do controle contra o estado do arquivo (§13.8 do contrato). */
class DecisaoDaGravacaoTest {

    @Test
    fun gravar_parado_comeca_e_gravando_responde() {
        assertEquals(Acao.COMECAR, DecisaoDaGravacao.decidir(true, Fase.PARADA))
        assertEquals(Acao.RESPONDER, DecisaoDaGravacao.decidir(true, Fase.GRAVANDO))
    }

    @Test
    fun parar_gravando_para_e_parado_responde() {
        assertEquals(Acao.PARAR, DecisaoDaGravacao.decidir(false, Fase.GRAVANDO))
        assertEquals(Acao.RESPONDER, DecisaoDaGravacao.decidir(false, Fase.PARADA))
    }

    @Test
    fun abrindo_ou_fechando_espera_a_proxima_fase() {
        for (g in listOf(true, false)) {
            assertEquals(Acao.ESPERAR, DecisaoDaGravacao.decidir(g, Fase.COMECANDO))
            assertEquals(Acao.ESPERAR, DecisaoDaGravacao.decidir(g, Fase.PARANDO))
        }
    }

    @Test
    fun o_tempo_e_o_espaco_do_indicador() {
        assertEquals("0:00", DecisaoDaGravacao.tempo(0))
        assertEquals("1:05", DecisaoDaGravacao.tempo(65_400))
        assertEquals("1:00:01", DecisaoDaGravacao.tempo(3_601_000))
        assertEquals("850 MB", DecisaoDaGravacao.espaco(850_000_000, PT.locale))
        assertEquals("12,3 GB", DecisaoDaGravacao.espaco(12_345_000_000, PT.locale))
    }

    @Test
    fun o_motivo_cabe_no_teto_do_contrato_e_nunca_vazio() {
        assertEquals("não deu para gravar", DecisaoDaGravacao.motivo("   ", PT))
        assertEquals("sem espaço", DecisaoDaGravacao.motivo("sem\u0000espaço", PT))
        val longo = "ação ".repeat(100)
        val m = DecisaoDaGravacao.motivo(longo, PT)
        val b = m.toByteArray(Charsets.UTF_8).size
        org.junit.Assert.assertTrue("$b bytes", b in 1..DecisaoDaGravacao.TETO_DO_MOTIVO)
        org.junit.Assert.assertTrue(m.endsWith("…"))
        // Cortado numa fronteira de caractere: decodifica igual.
        assertEquals(m, String(m.toByteArray(Charsets.UTF_8), Charsets.UTF_8))
        assertEquals("sem espaço: sobram 312 MB", DecisaoDaGravacao.motivo("sem espaço: sobram 312 MB", PT))
    }

    @Test
    fun gravar_sem_o_microfone_diz_sem_som_e_o_que_fazer() {
        val g = com.quall.android.mirror.GravacaoDaTelaBus.Fase.GRAVANDO
        assertEquals("● Gravando 1:05 SEM SOM — ligue o microfone · sobram 850 MB",
            DecisaoDaGravacao.indicador(g, 65_400, 850_000_000, microfoneLigado = false, microfoneCapturando = false, t = PT))
        assertEquals("● Gravando 1:05 · sobram 850 MB",
            DecisaoDaGravacao.indicador(g, 65_400, 850_000_000, microfoneLigado = true, microfoneCapturando = true, t = PT))
        assertEquals("● Gravando 0:02 · sem som ainda: o microfone está abrindo",
            DecisaoDaGravacao.indicador(g, 2_000, 0, microfoneLigado = true, microfoneCapturando = false, t = PT))
        assertEquals("", DecisaoDaGravacao.indicador(com.quall.android.mirror.GravacaoDaTelaBus.Fase.PARADA, 0, 0, false, false, PT))
    }

    @Test
    fun o_botao_avisa_antes_do_toque_que_vai_gravar_sem_som() {
        val parada = com.quall.android.mirror.GravacaoDaTelaBus.Fase.PARADA
        assertEquals("● Gravar", DecisaoDaGravacao.rotuloDoBotao(parada, microfoneLigado = true, t = PT))
        assertTrue(DecisaoDaGravacao.rotuloDoBotao(parada, microfoneLigado = false, t = PT).contains("sem som"))
        assertEquals("■ Parar gravação",
            DecisaoDaGravacao.rotuloDoBotao(com.quall.android.mirror.GravacaoDaTelaBus.Fase.GRAVANDO, microfoneLigado = false, t = PT))
    }

    /** Em inglês: o ponto decimal e as frases do indicador (`docs/traducao.md`, Android). */
    @Test
    fun o_indicador_em_ingles() {
        assertEquals("12.3 GB", DecisaoDaGravacao.espaco(12_345_000_000, EN.locale))
        assertEquals("● Recording 1:05 NO AUDIO — turn on the microphone · 850 MB left",
            DecisaoDaGravacao.indicador(Fase.GRAVANDO, 65_400, 850_000_000, microfoneLigado = false, microfoneCapturando = false, t = EN))
        assertEquals("● Record (no audio)", DecisaoDaGravacao.rotuloDoBotao(Fase.PARADA, microfoneLigado = false, t = EN))
        assertEquals("couldn’t record", DecisaoDaGravacao.motivo("", EN))
    }
}
