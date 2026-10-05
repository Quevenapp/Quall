package com.quall.android.capture

import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.core.TextosDeTeste.Companion.PT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * As escalas e os textos do R9 (`docs/controles-de-camera.md` §3.1–§3.3, §3.6), com as faixas das
 * câmeras da bancada (`bancada.md` §8.76).
 */
class EscalasDaCameraTest {

    @Test
    fun o_obturador_nunca_passa_de_1_sobre_fps() {
        // A07 frontal: 1/10000 a 1/5 s.
        val min = 100_000L
        val max = 200_000_000L
        assertEquals(listOf(30, 48, 50, 60, 100, 120, 125, 250, 500, 1000, 2000, 4000, 8000),
            EscalasDaCamera.escalaDoObturador(min, max, 30))
        assertEquals(listOf(60, 100, 120, 125, 250, 500, 1000, 2000, 4000, 8000),
            EscalasDaCamera.escalaDoObturador(min, max, 60))
        assertEquals(33_333_333L, EscalasDaCamera.tetoDoObturadorNs(30, max))
        assertEquals(16_666_667L, EscalasDaCamera.tetoDoObturadorNs(60, max))
        // O máximo da câmera vence quando é menor que 1/fps.
        assertEquals(10_000_000L, EscalasDaCamera.tetoDoObturadorNs(30, 10_000_000L))
    }

    @Test
    fun o_proprio_1_sobre_fps_entra_quando_nao_esta_na_lista() {
        assertTrue(15 in EscalasDaCamera.escalaDoObturador(100_000, 500_000_000, 15))
        assertEquals(listOf(15, 24, 25, 30), EscalasDaCamera.escalaDoObturador(30_000_000, 500_000_000, 15))
        // E o mínimo da câmera corta embaixo: 1/8000 = 125 µs não cabe num mínimo de 1/5000.
        assertFalse(8000 in EscalasDaCamera.escalaDoObturador(200_000, 500_000_000, 30))
    }

    @Test
    fun o_corte_ao_reaplicar_respeita_a_faixa_e_o_teto() {
        // Guardado 1/30 com a sessão em 60 fps: aplicado no teto 1/60; o guardado fica intacto (quem guarda é o registro).
        assertEquals(16_666_667L, EscalasDaCamera.cortarObturador(33_333_333, 100_000, 200_000_000, 60))
        assertEquals(33_333_333L, EscalasDaCamera.cortarObturador(33_333_333, 100_000, 200_000_000, 30))
        assertEquals(100_000L, EscalasDaCamera.cortarObturador(10_000, 100_000, 200_000_000, 30))
        assertEquals(3250, EscalasDaCamera.cortarIso(6400, 30, 3250))
        assertEquals(100, EscalasDaCamera.cortarIso(50, 100, 1600))
    }

    @Test
    fun o_texto_do_obturador_e_sempre_1_sobre_n() {
        assertEquals("1/60 s", EscalasDaCamera.textoDoObturador(PT, 16_666_667))
        assertEquals("1/80 s", EscalasDaCamera.textoDoObturador(PT, 12_500_000))
        assertEquals("1/30 s", EscalasDaCamera.textoDoObturador(PT, 33_350_000))
        assertEquals("1/8000 s", EscalasDaCamera.textoDoObturador(PT, EscalasDaCamera.nsDaFracao(8000)))
    }

    @Test
    fun a_sugestao_contra_cintilacao_e_legenda() {
        val br = EscalasDaCamera.redeDaSugestao(AjusteDaCamera.AntiCintilacao.AUTO, "BR")
        assertEquals(EscalasDaCamera.Rede.HZ60, br)
        assertEquals(setOf(60, 120), EscalasDaCamera.fracoesSemCintilacao(br))
        assertEquals("sem cintilação em luz de 60 Hz", EscalasDaCamera.legendaDaCintilacao(PT, br!!))
        assertNull(EscalasDaCamera.redeDaSugestao(AjusteDaCamera.AntiCintilacao.AUTO, "PT"))
        val cinquenta = EscalasDaCamera.redeDaSugestao(AjusteDaCamera.AntiCintilacao.HZ50, "BR")
        assertEquals(setOf(50, 100), EscalasDaCamera.fracoesSemCintilacao(cinquenta))
        assertEquals("sem cintilação em luz de 50 Hz", EscalasDaCamera.legendaDaCintilacao(PT, cinquenta!!))
        assertNull(EscalasDaCamera.redeDaSugestao(AjusteDaCamera.AntiCintilacao.DESLIGADA, "BR"))
    }

    @Test
    fun o_iso_anda_em_tercos_com_as_pontas_exatas_e_a_marca_do_ganho_digital() {
        // O tablet, traseira: 30–3250, analógico até 325.
        val e = EscalasDaCamera.escalaDoIso(30, 3250)
        assertEquals(30, e.first())
        assertEquals(3250, e.last())
        assertEquals(listOf(30, 50, 64, 80, 100), e.take(5))
        assertTrue(3200 in e)
        assertFalse(4000 in e)
        // A10s frontal: 100–6400, analógico até 240.
        assertEquals(listOf(100, 125, 160, 200, 250), EscalasDaCamera.escalaDoIso(100, 6400).take(5))
        assertFalse(EscalasDaCamera.ganhoDigital(200, 240))
        assertTrue(EscalasDaCamera.ganhoDigital(250, 240))
        assertFalse(EscalasDaCamera.ganhoDigital(6400, null))
        assertEquals("ganho digital", EscalasDaCamera.marcaDoGanhoDigital(PT))
    }

    @Test
    fun o_ev_no_passo_da_camera_com_sinal_sempre_visivel() {
        // A maioria: passo 1/10, −20..20. O A10s: 1/2, −4..4.
        assertEquals(3, EscalasDaCamera.indiceDoEv(0.3, 1, 10, -20, 20))
        assertEquals(1, EscalasDaCamera.indiceDoEv(0.3, 1, 2, -4, 4))
        assertEquals(4, EscalasDaCamera.indiceDoEv(5.0, 1, 2, -4, 4))
        assertEquals(-4, EscalasDaCamera.indiceDoEv(-3.0, 1, 2, -4, 4))
        assertEquals(0.5, EscalasDaCamera.evDoIndice(1, 1, 2), 1e-9)
        assertEquals("+0,3 EV", EscalasDaCamera.textoDoEv(PT, 0.3))
        assertEquals("0 EV", EscalasDaCamera.textoDoEv(PT, 0.0))
        assertEquals("0 EV", EscalasDaCamera.textoDoEv(PT, -0.01))
        assertEquals("−0,5 EV", EscalasDaCamera.textoDoEv(PT, -0.5))
        assertEquals("+2 EV", EscalasDaCamera.textoDoEv(PT, 2.0))
        assertEquals("+0,7 EV", EscalasDaCamera.textoDoEv(PT, 2.0 / 3))
        assertEquals("Destrave a exposição para compensar.", EscalasDaCamera.evComTrava(PT))
    }

    @Test
    fun a_linha_de_leitura_com_virgula_e_so_o_que_se_leu() {
        assertEquals("ISO 400 · 1/60 s · 5200 K · f/1,7", EscalasDaCamera.linhaDeLeitura(PT, 400, 16_666_667, 5200, 1.7f))
        assertEquals("ISO 100 · 1/80 s", EscalasDaCamera.linhaDeLeitura(PT, 100, 12_500_000, null, null))
        assertEquals("f/2", EscalasDaCamera.linhaDeLeitura(PT, null, null, null, 2.0f))
        assertEquals("A câmera usou ISO 800 em vez de ISO 400.", EscalasDaCamera.textoDaDivergencia(PT, "ISO 800", "ISO 400"))
        assertEquals("1,7", EscalasDaCamera.virgula(1.7, 1))
        assertEquals("2", EscalasDaCamera.virgula(2.0, 1))
        assertEquals("0,25", EscalasDaCamera.virgula(0.25, 2))
    }

    @Test
    fun kelvin_de_100_em_100_e_foco_em_dioptrias() {
        assertEquals(5200, EscalasDaCamera.cortarKelvin(5234))
        assertEquals(2000, EscalasDaCamera.cortarKelvin(1500))
        assertEquals(10000, EscalasDaCamera.cortarKelvin(12000))
        // No Android o 0 é o infinito: focoPosicao 1 é a distância mínima.
        assertEquals(10f, EscalasDaCamera.dioptriasDoFoco(1.0, 10f), 1e-6f)
        assertEquals(0f, EscalasDaCamera.dioptriasDoFoco(0.0, 10f), 1e-6f)
        assertEquals(0.25, EscalasDaCamera.posicaoDoFoco(2.5f, 10f), 1e-9)
        assertEquals(0.37, EscalasDaCamera.cortarFoco(0.3712), 1e-9)
        assertEquals("∞", EscalasDaCamera.textoDoFocoEmMetros(PT, 0f))
        assertEquals("0,5 m", EscalasDaCamera.textoDoFocoEmMetros(PT, 2f))
    }

    /** Em inglês, ponto decimal e as frases de `values/` (`docs/traducao.md`, Android). */
    @Test
    fun em_ingles_o_numero_tem_ponto() {
        assertEquals("+0.3 EV", EscalasDaCamera.textoDoEv(EN, 0.3))
        assertEquals("−0.5 EV", EscalasDaCamera.textoDoEv(EN, -0.5))
        assertEquals("ISO 400 · 1/60 s · 5200 K · f/1.7", EscalasDaCamera.linhaDeLeitura(EN, 400, 16_666_667, 5200, 1.7f))
        assertEquals("0.5 m", EscalasDaCamera.textoDoFocoEmMetros(EN, 2f))
        assertEquals("The camera used ISO 800 instead of ISO 400.", EscalasDaCamera.textoDaDivergencia(EN, "ISO 800", "ISO 400"))
        assertEquals("no flicker under 60 Hz light", EscalasDaCamera.legendaDaCintilacao(EN, EscalasDaCamera.Rede.HZ60))
        assertEquals("Unlock exposure to compensate.", EscalasDaCamera.evComTrava(EN))
    }
}
