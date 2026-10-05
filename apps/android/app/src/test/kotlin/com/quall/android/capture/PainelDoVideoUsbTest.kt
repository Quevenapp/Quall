// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.capture

import com.quall.android.capture.dv.GravacaoBus
import com.quall.android.capture.dv.PainelDoVideoUsb
import com.quall.android.capture.dv.PainelDoVideoUsb.Candidato
import com.quall.android.capture.dv.PainelDoVideoUsb.Entrada
import com.quall.android.capture.dv.PainelDoVideoUsb.Tipo
import com.quall.android.capture.dv.PainelDoVideoUsb.Transmissao
import com.quall.android.capture.dv.VideoUsb.Conhecido
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.mirror.MirrorBus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A tela "Placa de captura e filmadora" (`docs/placa-de-captura-usb.md` §13): o que é puro nela. */
class PainelDoVideoUsbTest {
    @Test
    fun quem_aparece_na_tela() {
        assertTrue(PainelDoVideoUsb.naTela(Conhecido.PLACA, chaveDv = false))
        // A filmadora aparece sem a chave de bancada: a tela é dela também (diferente da lista de Espelhar).
        assertTrue(PainelDoVideoUsb.naTela(Conhecido.FILMADORA_DV, chaveDv = false))
        assertTrue(PainelDoVideoUsb.naTela(Conhecido.DESCONHECIDO, chaveDv = false))
        assertFalse(PainelDoVideoUsb.naTela(Conhecido.RECUSADO, chaveDv = false))
        assertTrue(PainelDoVideoUsb.naTela(Conhecido.RECUSADO, chaveDv = true))
    }

    @Test
    fun a_escolha_prefere_a_placa_e_nao_troca_sozinha() {
        val dv = Candidato("usb-dv:/1", Conhecido.FILMADORA_DV, false)
        val placa = Candidato("usb-dv:/2", Conhecido.PLACA, true)
        val nova = Candidato("usb-dv:/3", Conhecido.DESCONHECIDO, true)
        val muda = Candidato("usb-dv:/4", Conhecido.DESCONHECIDO, false)
        assertEquals(placa, PainelDoVideoUsb.escolher(listOf(dv, placa, nova), null))
        assertEquals(dv, PainelDoVideoUsb.escolher(listOf(muda, dv), null))
        assertEquals(nova, PainelDoVideoUsb.escolher(listOf(muda, nova), null))
        // O que a pessoa escolheu fica enquanto estiver plugado.
        assertEquals(dv, PainelDoVideoUsb.escolher(listOf(dv, placa), "usb-dv:/1"))
        // Saiu do USB: volta à regra.
        assertEquals(placa, PainelDoVideoUsb.escolher(listOf(dv, placa), "usb-dv:/9"))
        assertNull(PainelDoVideoUsb.escolher(emptyList(), null))
    }

    @Test
    fun a_transmissao_vista_pelo_bus() {
        assertEquals(Transmissao.NENHUMA, PainelDoVideoUsb.transmissao(MirrorBus.Estado()))
        val esta = MirrorBus.Estado(fase = MirrorBus.Fase.ESPERANDO, videoUsb = true)
        assertEquals(Transmissao.ESTA, PainelDoVideoUsb.transmissao(esta))
        assertEquals(Transmissao.OUTRA, PainelDoVideoUsb.transmissao(MirrorBus.Estado(fase = MirrorBus.Fase.ESPELHANDO)))
        assertEquals(Transmissao.OUTRA, PainelDoVideoUsb.transmissao(esta.copy(daTelaR5 = true)))
        assertEquals(Transmissao.NENHUMA, PainelDoVideoUsb.transmissao(esta.copy(fase = MirrorBus.Fase.ERRO)))
    }

    @Test
    fun a_placa_grava_e_transmite_junto() {
        val b = PainelDoVideoUsb.botoes(PT, Entrada(Tipo.PLACA, pronto = true, gravando = true, transmissao = Transmissao.ESTA))
        assertEquals("Parar a gravação", b.gravarTexto)
        assertEquals("Parar a transmissão", b.transmitirTexto)
        assertTrue(b.gravarHabilitado)
        assertTrue(b.transmitirHabilitado)
        assertTrue(b.ouvirVisivel)
        assertTrue(b.fotoVisivel)
        assertEquals("", b.nota)
        val parada = PainelDoVideoUsb.botoes(PT, Entrada(Tipo.PLACA, pronto = true, gravando = false, transmissao = Transmissao.NENHUMA))
        assertEquals("Gravar", parada.gravarTexto)
        assertEquals("Transmitir", parada.transmitirTexto)
        assertTrue(parada.gravarHabilitado && parada.transmitirHabilitado)
    }

    @Test
    fun a_filmadora_faz_uma_coisa_por_vez() {
        val gravando = PainelDoVideoUsb.botoes(PT, Entrada(Tipo.FILMADORA_DV, pronto = true, gravando = true, transmissao = Transmissao.NENHUMA))
        assertTrue(gravando.gravarHabilitado)
        assertFalse(gravando.transmitirHabilitado)
        assertTrue(gravando.nota.contains(PainelDoVideoUsb.fraseDvUmaCoisa(PT)))
        val noAr = PainelDoVideoUsb.botoes(PT, Entrada(Tipo.FILMADORA_DV, pronto = true, gravando = false, transmissao = Transmissao.ESTA))
        assertFalse(noAr.gravarHabilitado)
        assertTrue(noAr.transmitirHabilitado)
        assertEquals("Gravar a fita", noAr.gravarTexto)
        // Com ouvir (o som da fita vem dentro do DV, e a fonte o toca, §13.7) e com foto.
        assertTrue(noAr.ouvirVisivel)
        assertTrue(noAr.fotoVisivel)
    }

    @Test
    fun outra_transmissao_no_ar_apaga_o_transmitir() {
        val b = PainelDoVideoUsb.botoes(PT, Entrada(Tipo.PLACA, pronto = true, gravando = false,
            transmissao = Transmissao.OUTRA, outraFonte = "a tela"))
        assertFalse(b.transmitirHabilitado)
        assertTrue(b.gravarHabilitado)
        assertTrue(b.nota.contains("transmitindo a tela"))
    }

    @Test
    fun sem_permissao_nada_comeca_mas_o_que_esta_no_ar_para() {
        val b = PainelDoVideoUsb.botoes(PT, Entrada(Tipo.DESCONHECIDO, pronto = false, gravando = false, transmissao = Transmissao.NENHUMA))
        assertFalse(b.gravarHabilitado)
        assertFalse(b.transmitirHabilitado)
        assertFalse(b.ouvirVisivel)
        assertFalse(b.fotoVisivel)
        val parar = PainelDoVideoUsb.botoes(PT, Entrada(Tipo.PLACA, pronto = false, gravando = true, transmissao = Transmissao.ESTA))
        assertTrue(parar.gravarHabilitado)
        assertTrue(parar.transmitirHabilitado)
    }

    @Test
    fun o_ouvir_diz_o_estado() {
        assertEquals("Parar de ouvir", PainelDoVideoUsb.botoes(PT, 
            Entrada(Tipo.PLACA, pronto = true, gravando = false, transmissao = Transmissao.NENHUMA, ouvindo = true)).ouvirTexto)
    }

    @Test
    fun o_texto_da_gravacao() {
        assertEquals("", PainelDoVideoUsb.textoDaGravacao(PT, GravacaoBus.Estado()))
        assertEquals("Preparando a gravação…", PainelDoVideoUsb.textoDaGravacao(PT, GravacaoBus.Estado(fase = GravacaoBus.Fase.PREPARANDO)))
        val g = GravacaoBus.Estado(fase = GravacaoBus.Fase.GRAVANDO, nome = "Quall-Placa-1.mp4", decorridoMs = 3_723_000,
            bytes = 12_340_000, espacoLivre = 20_100_000_000, daPlaca = true, pausada = true, avisoDoSom = "sem som")
        assertEquals(
            "Gravando Quall-Placa-1.mp4\n1:02:03 · 12,3 MB · livre: 20,10 GB\n" +
                "A placa não está mandando imagem; esperando (fecha sozinho em 5 min).\nSom: sem som",
            PainelDoVideoUsb.textoDaGravacao(PT, g),
        )
        assertTrue(PainelDoVideoUsb.textoDaGravacao(PT, g.copy(daPlaca = false)).contains("A fita está parada"))
        assertEquals("Gravação parada: gravação encerrada — salvo em Movies/Quall", PainelDoVideoUsb.textoDaGravacao(PT, 
            GravacaoBus.Estado(fase = GravacaoBus.Fase.PARADA, mensagem = "gravação encerrada — salvo em Movies/Quall")))
    }

    @Test
    fun a_espera_mostra_o_pin_e_o_endereco() {
        assertNull(PainelDoVideoUsb.espera(PT, MirrorBus.Estado()))
        val m = MirrorBus.Estado(fase = MirrorBus.Fase.ESPERANDO, videoUsb = true, pin = "123456",
            enderecos = listOf("192.168.57.4:7000", "10.77.0.2:7000"))
        val e = PainelDoVideoUsb.espera(PT, m)!!
        assertEquals("123 456", e.pin)
        assertEquals("192.168.57.4:7000", e.endereco)
        assertEquals("também: 10.77.0.2:7000", e.outros)
        assertEquals("", e.para)
        assertEquals("sem rede", PainelDoVideoUsb.espera(PT, m.copy(enderecos = emptyList()))!!.endereco)
        // "sem rede" vem tipado: a tela não compara a frase (que muda com o idioma) para saber se copia.
        assertTrue(PainelDoVideoUsb.espera(EN, m.copy(enderecos = emptyList()))!!.semRede)
        assertFalse(e.semRede)
        val enviando = PainelDoVideoUsb.espera(PT, m.copy(fase = MirrorBus.Fase.ESPELHANDO, par = "MacBook"))!!
        assertEquals("", enviando.pin)
        assertEquals("Enviando para MacBook", enviando.para)
        // Outra transmissão (a tela, a R5) não é desta tela.
        assertNull(PainelDoVideoUsb.espera(PT, m.copy(videoUsb = false)))
    }

    @Test
    fun o_tempo_e_o_tamanho() {
        assertEquals("0:00:00", PainelDoVideoUsb.tempo(-5))
        assertEquals("0:01:05", PainelDoVideoUsb.tempo(65_400))
        assertEquals("0,0 MB", PainelDoVideoUsb.tamanho(PT, 0))
        assertEquals("999,9 MB", PainelDoVideoUsb.tamanho(PT, 999_900_000))
        assertEquals("1,50 GB", PainelDoVideoUsb.tamanho(PT, 1_500_000_000))
        // Em inglês, o ponto decimal (o formato mora no recurso, `docs/traducao.md`).
        assertEquals("999.9 MB", PainelDoVideoUsb.tamanho(EN, 999_900_000))
        assertEquals("1.50 GB", PainelDoVideoUsb.tamanho(EN, 1_500_000_000))
    }

    /** As mesmas decisões em inglês: só as frases mudam (`docs/traducao.md`, Android). */
    @Test
    fun em_ingles() {
        val b = PainelDoVideoUsb.botoes(EN, Entrada(Tipo.FILMADORA_DV, pronto = true, gravando = false, transmissao = Transmissao.ESTA))
        assertEquals("Record the tape", b.gravarTexto)
        assertEquals("Stop sending", b.transmitirTexto)
        assertEquals("Listen", b.ouvirTexto)
        assertFalse(b.gravarHabilitado)
        assertEquals(PainelDoVideoUsb.fraseDvUmaCoisa(EN), b.nota)
        val g = GravacaoBus.Estado(fase = GravacaoBus.Fase.GRAVANDO, nome = "Quall-Placa-1.mp4", decorridoMs = 3_723_000,
            bytes = 12_340_000, espacoLivre = 20_100_000_000, daPlaca = true)
        assertEquals("Recording Quall-Placa-1.mp4\n1:02:03 · 12.3 MB · free: 20.10 GB", PainelDoVideoUsb.textoDaGravacao(EN, g))
        val m = MirrorBus.Estado(fase = MirrorBus.Fase.ESPERANDO, videoUsb = true, pin = "123456",
            enderecos = listOf("192.168.57.4:7000", "10.77.0.2:7000"))
        assertEquals("Waiting for the other device", PainelDoVideoUsb.espera(EN, m)!!.manchete)
        assertEquals("also: 10.77.0.2:7000", PainelDoVideoUsb.espera(EN, m)!!.outros)
    }
}
