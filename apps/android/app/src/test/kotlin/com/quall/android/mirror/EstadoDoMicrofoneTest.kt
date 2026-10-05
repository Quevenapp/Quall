package com.quall.android.mirror

import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.core.TextosDeTeste.Companion.PT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A frase do botão do microfone (R5, fase 2). **Na JVM, sem aparelho.** O que ela não pode fazer é
 * dizer "ligado" sem dizer que o microfone ainda não abriu (sem receptor), nem calar o motivo de uma
 * recusa.
 */
class EstadoDoMicrofoneTest {

    @Test
    fun sem_camera_nao_ha_botao_nem_frase() {
        assertEquals("", EstadoDoMicrofone().frase(PT))
        assertEquals("", EstadoDoMicrofone(ligado = true, capturando = true).frase(PT))
    }

    @Test
    fun comeca_desligado() {
        assertEquals("Microfone desligado", EstadoDoMicrofone(disponivel = true).frase(PT))
    }

    @Test
    fun ligado_sem_receptor_diz_que_ainda_nao_abriu() {
        assertEquals(
            "Microfone ligado · abre quando o receptor conectar",
            EstadoDoMicrofone(disponivel = true, ligado = true).frase(PT),
        )
    }

    @Test
    fun ligado_e_mandando() {
        assertEquals(
            "Microfone ligado",
            EstadoDoMicrofone(disponivel = true, ligado = true, capturando = true, origem = "microfone (MIC, cru)").frase(PT),
        )
    }

    /** A bancada diz que é o tom, e não o microfone: quem olha a tela não se engana. */
    @Test
    fun o_tom_da_bancada_aparece_na_frase() {
        assertEquals(
            "Microfone ligado (tom sintético ritmado a +0 ppm (bancada))",
            EstadoDoMicrofone(
                disponivel = true, ligado = true, capturando = true,
                origem = "tom sintético ritmado a +0 ppm (bancada)",
            ).frase(PT),
        )
    }

    @Test
    fun a_recusa_diz_por_que() {
        assertEquals(
            "Microfone desligado: a permissão de microfone foi negada — toque de novo para pedir",
            EstadoDoMicrofone(
                disponivel = true,
                motivo = "a permissão de microfone foi negada — toque de novo para pedir",
            ).frase(PT),
        )
    }

    /** O Android 10+ não falha com outro app no microfone: grava zeros. A tela diz. */
    @Test
    fun o_silencio_digital_aparece() {
        assertEquals(
            "Microfone ligado: só silêncio — outro app pode estar com o microfone",
            EstadoDoMicrofone(
                disponivel = true, ligado = true, capturando = true, origem = "microfone (MIC, cru)",
                aviso = "só silêncio — outro app pode estar com o microfone",
            ).frase(PT),
        )
    }

    /** A placa de captura: o botão é o "Som da placa", e o silêncio diz o cabo (§11, item 3). */
    @Test
    fun a_placa_diz_som_da_placa_e_o_cabo() {
        val placa = EstadoDoMicrofone(disponivel = true, daPlaca = true)
        assertEquals("Som da placa desligado", placa.frase(PT))
        assertEquals("Som da placa ligado · abre quando o receptor conectar", placa.copy(ligado = true).frase(PT))
        assertEquals(
            "Som da placa ligado: a placa não está recebendo som (confira o cabo de áudio)",
            placa.copy(ligado = true, capturando = true, origem = "som da placa",
                aviso = com.quall.android.capture.dv.DonoDaPlaca.FRASE_DO_SILENCIO).frase(PT),
        )
        assertEquals("Som da placa desligado: sem permissão de microfone", placa.copy(motivo = "sem permissão de microfone").frase(PT))
    }

    /**
     * **O motivo tipado** (`docs/traducao.md`, Android): a tela decide pelo código ("Sem acesso", abrir os
     * Ajustes), e a frase sai no idioma de quem desenha — não no de quem escreveu.
     */
    @Test
    fun o_motivo_tipado_decide_e_fala_os_dois_idiomas() {
        val negada = EstadoDoMicrofone(disponivel = true).comMotivo(PT, MotivoDoMicrofone.PERMISSAO_NOS_AJUSTES)
        assertTrue(negada.semPermissao)
        assertTrue(negada.pedeAjustes)
        assertTrue(negada.frase(PT), negada.frase(PT).startsWith("Microfone desligado: sem permissão de microfone — toque de novo"))
        // Escrito em português, desenhado em inglês: a frase acompanha a tela.
        assertTrue(negada.frase(EN), negada.frase(EN).startsWith("Microphone off: no microphone permission — tap again"))
        val semVideo = EstadoDoMicrofone(disponivel = true).comMotivo(EN, MotivoDoMicrofone.SEM_VIDEO_NO_AR)
        assertFalse(semVideo.semPermissao)
        assertFalse(semVideo.pedeAjustes)
        assertEquals("Microfone desligado: o vídeo da câmera não está no ar", semVideo.frase(PT))
    }

    /** Quem escreve só a frase depois (o serviço) não herda o código velho. */
    @Test
    fun o_codigo_velho_nao_vale_para_uma_frase_nova() {
        val velho = EstadoDoMicrofone(disponivel = true).comMotivo(PT, MotivoDoMicrofone.PERMISSAO_NEGADA)
        val novo = velho.copy(motivo = "o microfone não abriu")
        assertEquals(null, novo.motivoTipado)
        assertFalse(novo.semPermissao)
        assertEquals("Microphone off: o microfone não abriu", novo.frase(EN))
        // O legado do serviço ("sem permissão de microfone", sem código) ainda conta como permissão.
        assertTrue(EstadoDoMicrofone(disponivel = true, motivo = "sem permissão de microfone").semPermissao)
    }

    @Test
    fun em_ingles() {
        assertEquals("Microphone off", EstadoDoMicrofone(disponivel = true).frase(EN))
        assertEquals("Card audio on · opens when the receiver connects",
            EstadoDoMicrofone(disponivel = true, ligado = true, daPlaca = true).frase(EN))
        assertEquals("Microphone on · opens when the receiver connects or when you record",
            EstadoDoMicrofone(disponivel = true, ligado = true, abreAoGravar = true).frase(EN))
        assertEquals("Tape audio", EstadoDoMicrofone(daFita = true).nome(EN))
    }
}
