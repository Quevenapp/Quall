package com.quall.android.capture

import com.quall.android.capture.RegrasDosControles.Chave
import com.quall.android.capture.RegrasDosControles.Medida
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.core.TextosDeTeste.Companion.PT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * As regras do R9 no Android (`docs/controles-de-camera.md` §2.1, §2.2, §3.5, §4.4 e a tabela do §4.5),
 * com as capacidades das câmeras da bancada (`bancada.md` §8.76).
 */
class RegrasDosControlesTest {

    private val identidade = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
    private val forward = doubleArrayOf(0.7034, 0.1558, 0.1050, 0.2910, 0.8008, -0.0918, 0.0135, -0.1880, 0.9994)
    private val cal = KelvinDng.Calibracao(2856.0, identidade, forward, 6504.0, identidade, forward)

    /** A frontal do A07: LEVEL_3, com as duas capacidades, ISO 50–6400 (analógico até 800), 1/10000 a 1/5 s. */
    private val a07 = CapacidadesDaCamera(
        manualSensor = true, manualPosProcessamento = true, leSensor = true,
        isoMin = 50, isoMax = 6400, isoMaxAnalogico = 800,
        exposicaoMinNs = 100_000, exposicaoMaxNs = 200_000_000,
        evIndiceMin = -20, evIndiceMax = 20, evPassoNum = 1, evPassoDen = 10,
        modosDeBalanco = setOf(0, 1, 2, 3, 4, 5, 6, 7, 8), modosAntiCintilacao = setOf(0, 1, 2, 3),
        travaAe = true, travaAwb = true, temAf = true, focoMinimoDioptrias = 10f, focoLido = true,
        calibracao = cal, regioesAe = 1, regioesAf = 1, regioesAwb = 0, abertura = 2.0f,
    )

    /** O tablet: LIMITED, sem `MANUAL_SENSOR` nem `MANUAL_POST_PROCESSING`. */
    private val tablet = a07.copy(manualSensor = false, manualPosProcessamento = false, leSensor = false, calibracao = null,
        focoNaRequisicao = true, focoLido = false)

    /** Uma frontal de foco fixo, sem AF. */
    private val fixa = a07.copy(temAf = false, focoMinimoDioptrias = 0f, regioesAf = 0)

    private val m30 = RegrasDosControles.Momento(fps = 30)

    private fun chaves(a: AjusteDaCamera, c: CapacidadesDaCamera = a07, m: RegrasDosControles.Momento = m30) =
        RegrasDosControles.plano(a, c, m).chaves

    // --- a tabela do §4.5 ---

    @Test
    fun o_padrao_nao_leva_chave_nenhuma() {
        val p = RegrasDosControles.plano(AjusteDaCamera(), a07, m30)
        assertTrue(p.chaves.isEmpty())
        assertEquals(0, p.indiceDoEv)
        assertFalse(p.travarFocoNoCentro)
    }

    @Test
    fun exposicao_manual_leva_ae_off_iso_tempo_e_duracao_do_quadro() {
        val a = AjusteDaCamera(exposicao = AjusteDaCamera.Exposicao.MANUAL, iso = 400, obturadorNs = 33_333_333)
        val k = chaves(a, m = RegrasDosControles.Momento(fps = 60))
        assertEquals(setOf(Chave.CONTROL_AE_MODE, Chave.SENSOR_SENSITIVITY, Chave.SENSOR_EXPOSURE_TIME, Chave.SENSOR_FRAME_DURATION), k.keys)
        assertEquals(Camera2Valores.AE_MODE_OFF, k[Chave.CONTROL_AE_MODE])
        assertEquals(400, k[Chave.SENSOR_SENSITIVITY])
        // O guardado 1/30 a 60 fps vai no teto 1/60, e o quadro é 1e9/60.
        assertEquals(16_666_667L, k[Chave.SENSOR_EXPOSURE_TIME])
        assertEquals(16_666_667L, k[Chave.SENSOR_FRAME_DURATION])
        val p = RegrasDosControles.plano(a, a07, m30)
        assertEquals(33_333_333L, p.obturadorAplicadoNs)
        assertEquals(33_333_333L, p.chaves[Chave.SENSOR_FRAME_DURATION])
        assertNull("o EV só com exposição Auto", p.indiceDoEv)
    }

    @Test
    fun exposicao_manual_sem_manual_sensor_nao_leva_nada() {
        val a = AjusteDaCamera(exposicao = AjusteDaCamera.Exposicao.MANUAL, iso = 400, obturadorNs = 33_333_333)
        assertTrue(chaves(a, tablet).isEmpty())
    }

    @Test
    fun a_trava_de_exposicao_reaplicada_como_manual_com_os_valores_guardados() {
        val a = AjusteDaCamera(travaExposicao = true, travaIso = 250, travaObturadorNs = 8_000_000)
        val k = chaves(a)
        assertEquals(Camera2Valores.AE_MODE_OFF, k[Chave.CONTROL_AE_MODE])
        assertEquals(250, k[Chave.SENSOR_SENSITIVITY])
        assertEquals(8_000_000L, k[Chave.SENSOR_EXPOSURE_TIME])
        assertFalse(Chave.CONTROL_AE_LOCK in k)
        // O ISO guardado fora da faixa é cortado (§2.2).
        assertEquals(6400, chaves(a.copy(travaIso = 12800))[Chave.SENSOR_SENSITIVITY])
    }

    @Test
    fun a_trava_de_exposicao_sem_manual_so_vai_depois_de_convergir() {
        val a = AjusteDaCamera(travaExposicao = true)
        val antes = RegrasDosControles.plano(a, tablet, RegrasDosControles.Momento(30, aeConvergiu = false))
        assertTrue(antes.chaves.isEmpty())
        assertTrue(antes.esperandoAe)
        val depois = RegrasDosControles.plano(a, tablet, RegrasDosControles.Momento(30, aeConvergiu = true))
        assertEquals(mapOf(Chave.CONTROL_AE_LOCK to true), depois.chaves)
        // No A07 sem os valores lidos (o resultado ainda não veio), também cai no AE_LOCK.
        assertEquals(mapOf(Chave.CONTROL_AE_LOCK to true), chaves(a))
    }

    @Test
    fun anti_cintilacao_so_fora_do_auto_e_so_os_modos_da_camera() {
        assertTrue(Chave.CONTROL_AE_ANTIBANDING_MODE !in chaves(AjusteDaCamera()))
        assertEquals(Camera2Valores.ANTIBANDING_60HZ,
            chaves(AjusteDaCamera(antiCintilacao = AjusteDaCamera.AntiCintilacao.HZ60))[Chave.CONTROL_AE_ANTIBANDING_MODE])
        assertEquals(Camera2Valores.ANTIBANDING_OFF,
            chaves(AjusteDaCamera(antiCintilacao = AjusteDaCamera.AntiCintilacao.DESLIGADA))[Chave.CONTROL_AE_ANTIBANDING_MODE])
        assertTrue(chaves(AjusteDaCamera(antiCintilacao = AjusteDaCamera.AntiCintilacao.HZ50), a07.copy(modosAntiCintilacao = setOf(3))).isEmpty())
    }

    @Test
    fun o_preset_leva_so_o_modo_de_awb_e_so_se_a_camera_lista() {
        assertEquals(mapOf(Chave.CONTROL_AWB_MODE to Camera2Valores.AWB_MODE_DAYLIGHT),
            chaves(AjusteDaCamera(balanco = AjusteDaCamera.Balanco.LUZ_DO_DIA)))
        assertEquals(mapOf(Chave.CONTROL_AWB_MODE to Camera2Valores.AWB_MODE_CLOUDY_DAYLIGHT),
            chaves(AjusteDaCamera(balanco = AjusteDaCamera.Balanco.NUBLADO)))
        // O S24 não tem o 4 (WARM_FLUORESCENT), mas tem os quatro da grade.
        val s24 = a07.copy(modosDeBalanco = setOf(0, 1, 2, 3, 5, 6))
        assertEquals(4, s24.presets.size)
        assertTrue(chaves(AjusteDaCamera(balanco = AjusteDaCamera.Balanco.INCANDESCENTE), a07.copy(modosDeBalanco = setOf(0, 1))).isEmpty())
    }

    @Test
    fun o_kelvin_leva_awb_off_matriz_ganhos_e_correcao_que_nao_e_identidade() {
        val p = RegrasDosControles.plano(AjusteDaCamera(balanco = AjusteDaCamera.Balanco.KELVIN, kelvin = 5234), a07, m30)
        assertEquals(setOf(Chave.CONTROL_AWB_MODE, Chave.COLOR_CORRECTION_MODE, Chave.COLOR_CORRECTION_GAINS,
            Chave.COLOR_CORRECTION_TRANSFORM), p.chaves.keys)
        assertEquals(Camera2Valores.AWB_MODE_OFF, p.chaves[Chave.CONTROL_AWB_MODE])
        assertEquals(Camera2Valores.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX, p.chaves[Chave.COLOR_CORRECTION_MODE])
        @Suppress("UNCHECKED_CAST") val g = p.chaves[Chave.COLOR_CORRECTION_GAINS] as List<Double>
        assertEquals(4, g.size)
        assertEquals(g[1], g[2], 0.0)
        @Suppress("UNCHECKED_CAST") val t = p.chaves[Chave.COLOR_CORRECTION_TRANSFORM] as List<Double>
        assertEquals(9, t.size)
        assertFalse(t == identidade.toList())
        assertEquals(5200, p.kelvinAplicado)
        // Sem a calibração, o Kelvin não vai.
        assertTrue(chaves(AjusteDaCamera(balanco = AjusteDaCamera.Balanco.KELVIN, kelvin = 5200), a07.copy(calibracao = null)).isEmpty())
    }

    @Test
    fun a_trava_de_balanco_com_ganhos_vira_manual_e_sem_manual_espera_convergir() {
        val g = KelvinDng.ganhos(cal, 4300.0)!!.toList()
        val k = chaves(AjusteDaCamera(travaBalanco = true, travaGanhos = g))
        assertEquals(Camera2Valores.AWB_MODE_OFF, k[Chave.CONTROL_AWB_MODE])
        assertEquals(g, k[Chave.COLOR_CORRECTION_GAINS])
        assertTrue(Chave.COLOR_CORRECTION_TRANSFORM in k)
        val antes = RegrasDosControles.plano(AjusteDaCamera(travaBalanco = true), tablet, RegrasDosControles.Momento(30, awbConvergiu = false))
        assertTrue(antes.chaves.isEmpty())
        assertTrue(antes.esperandoAwb)
        assertEquals(mapOf(Chave.CONTROL_AWB_LOCK to true), chaves(AjusteDaCamera(travaBalanco = true), tablet))
    }

    @Test
    fun o_foco_manual_leva_af_off_e_a_distancia_e_o_auto_nunca_leva_af_mode() {
        val k = chaves(AjusteDaCamera(foco = AjusteDaCamera.Foco.MANUAL, focoPosicao = 0.5))
        assertEquals(mapOf(Chave.CONTROL_AF_MODE to Camera2Valores.AF_MODE_OFF, Chave.LENS_FOCUS_DISTANCE to 5f), k)
        val travado = chaves(AjusteDaCamera(foco = AjusteDaCamera.Foco.TRAVADO, focoPosicao = 0.2))
        assertEquals(2f, travado[Chave.LENS_FOCUS_DISTANCE])
        // Travado sem a posição lida (ou sem foco manual): pelo toque no centro, e nunca AF_MODE no interop.
        val semPosicao = RegrasDosControles.plano(AjusteDaCamera(foco = AjusteDaCamera.Foco.TRAVADO), a07, m30)
        assertTrue(semPosicao.chaves.isEmpty())
        assertTrue(semPosicao.travarFocoNoCentro)
        val semManual = RegrasDosControles.plano(AjusteDaCamera(foco = AjusteDaCamera.Foco.TRAVADO, focoPosicao = 0.2),
            a07.copy(manualSensor = false, focoNaRequisicao = false), m30)
        assertTrue(Chave.CONTROL_AF_MODE !in semManual.chaves)
        assertTrue(semManual.travarFocoNoCentro)
        // Foco fixo: nada.
        assertTrue(RegrasDosControles.plano(AjusteDaCamera(foco = AjusteDaCamera.Foco.TRAVADO), fixa, m30).let {
            it.chaves.isEmpty() && !it.travarFocoNoCentro
        })
    }

    /**
     * **O tablet da corrida de 01/10**: sem `READ_SENSOR_SETTINGS`, o toque longo leu `focoPosicao` 1 (o
     * mais perto) e a reabertura pôs a lente a 10 cm. A trava de foco só volta como manual com posição
     * lida de confiança; sem ela, é o AF no centro sem cancelar (§4.5) — e o foco manual do deslizante,
     * que não depende de leitura, continua valendo.
     */
    @Test
    fun a_trava_de_foco_sem_leitura_confiavel_volta_pelo_af_no_centro() {
        val travado = AjusteDaCamera(travaExposicao = true, foco = AjusteDaCamera.Foco.TRAVADO, focoPosicao = 1.0)
        val noTablet = RegrasDosControles.plano(travado, tablet, RegrasDosControles.Momento(30, aeConvergiu = false))
        assertFalse(Chave.CONTROL_AF_MODE in noTablet.chaves)
        assertFalse(Chave.LENS_FOCUS_DISTANCE in noTablet.chaves)
        assertTrue(noTablet.travarFocoNoCentro)
        assertTrue("a exposição sem manual espera o 3A (§2.1)", noTablet.esperandoAe)
        val noA07 = RegrasDosControles.plano(travado.copy(focoPosicao = 0.56), a07, m30)
        assertEquals(Camera2Valores.AF_MODE_OFF, noA07.chaves[Chave.CONTROL_AF_MODE])
        assertFalse(noA07.travarFocoNoCentro)
        // O foco manual do deslizante no tablet (a chave está na requisição): vale, a posição é a pedida.
        assertTrue(tablet.focoManual)
        assertEquals(Camera2Valores.AF_MODE_OFF,
            chaves(AjusteDaCamera(foco = AjusteDaCamera.Foco.MANUAL, focoPosicao = 0.0), tablet)[Chave.CONTROL_AF_MODE])
    }

    @Test
    fun o_interop_nunca_leva_af_mode_em_auto_nem_compensacao_nem_regioes() {
        val todos = listOf(
            AjusteDaCamera(ev = 1.0, travaExposicao = true, travaIso = 100, travaObturadorNs = 10_000_000,
                antiCintilacao = AjusteDaCamera.AntiCintilacao.HZ60, balanco = AjusteDaCamera.Balanco.KELVIN, kelvin = 3200),
            AjusteDaCamera(exposicao = AjusteDaCamera.Exposicao.MANUAL, iso = 100, obturadorNs = 1_000_000,
                travaBalanco = true, travaGanhos = listOf(2.0, 1.0, 1.0, 1.5)),
        )
        for (a in todos) {
            val k = chaves(a)
            assertFalse(Chave.CONTROL_AF_MODE in k)
            assertFalse(Chave.LENS_FOCUS_DISTANCE in k)
        }
        // E não há chave de compensação nem de região no enum: o EV vai pelo CameraX.
        assertFalse(Chave.entries.any { "COMPENSATION" in it.name || "REGION" in it.name })
    }

    @Test
    fun o_ev_vai_pelo_indice_no_passo_da_camera() {
        assertEquals(5, RegrasDosControles.plano(AjusteDaCamera(ev = 0.5), a07, m30).indiceDoEv)
        val a10s = a07.copy(evIndiceMin = -4, evIndiceMax = 4, evPassoDen = 2)
        assertEquals(1, RegrasDosControles.plano(AjusteDaCamera(ev = 0.3), a10s, m30).indiceDoEv)
        assertNull(RegrasDosControles.plano(AjusteDaCamera(ev = 0.3), a07.copy(evIndiceMin = 0, evIndiceMax = 0), m30).indiceDoEv)
    }

    // --- §3.5 quem limita ---

    @Test
    fun os_textos_de_quem_limita_sao_literais() {
        assertEquals("O fabricante deste aparelho não libera ISO para outros apps.",
            RegrasDosControles.limite(PT, RegrasDosControles.Controle.ISO, tablet))
        assertEquals("O fabricante deste aparelho não libera o obturador para outros apps.",
            RegrasDosControles.limite(PT, RegrasDosControles.Controle.OBTURADOR, tablet))
        assertEquals("O fabricante deste aparelho não libera o Kelvin para outros apps.",
            RegrasDosControles.limite(PT, RegrasDosControles.Controle.KELVIN, tablet))
        assertEquals("Esta câmera não publica a calibração de cor que o Kelvin precisa.",
            RegrasDosControles.limite(PT, RegrasDosControles.Controle.KELVIN, a07.copy(calibracao = null)))
        assertEquals("Esta câmera tem foco fixo.", RegrasDosControles.limite(PT, RegrasDosControles.Controle.FOCO_MANUAL, fixa))
        assertEquals("Esta câmera tem foco fixo.", RegrasDosControles.limite(PT, RegrasDosControles.Controle.TRAVA_FOCO, fixa))
        assertEquals("O fabricante deste aparelho não libera o foco manual para outros apps.",
            RegrasDosControles.limite(PT, RegrasDosControles.Controle.FOCO_MANUAL, tablet.copy(focoNaRequisicao = false)))
        assertNull(RegrasDosControles.limite(PT, RegrasDosControles.Controle.TRAVA_EXPOSICAO, tablet))
        assertNull(RegrasDosControles.limite(PT, RegrasDosControles.Controle.ISO, a07))
        assertEquals("O fabricante deste aparelho não libera ISO e o obturador para outros apps.",
            RegrasDosControles.limiteDaAbaIsoEObturador(PT, tablet))
        assertNull(RegrasDosControles.limiteDaAbaIsoEObturador(PT, a07))
        // Os nomes do §3.5, com o artigo, dentro da frase de cada controle (uma chave por controle).
        assertEquals(listOf("ISO", "o obturador", "o Kelvin", "os presets de balanço", "o foco manual", "a anti-cintilação",
            "a compensação de exposição", "o toque para focar", "a trava de exposição", "a trava de balanço", "a trava de foco"),
            RegrasDosControles.Controle.entries.map {
                PT.s(it.naoLibera).removePrefix("O fabricante deste aparelho não libera ").removeSuffix(" para outros apps.")
            })
    }

    /** Em inglês a frase é outra composição, e não o nome português encaixado (`docs/traducao.md`). */
    @Test
    fun os_textos_de_quem_limita_em_ingles() {
        assertEquals("This device’s manufacturer doesn’t give other apps access to the shutter.",
            RegrasDosControles.limite(EN, RegrasDosControles.Controle.OBTURADOR, tablet))
        assertEquals("This camera has fixed focus.", RegrasDosControles.limite(EN, RegrasDosControles.Controle.FOCO_MANUAL, fixa))
        assertEquals("This device’s manufacturer doesn’t give other apps access to ISO or the shutter.",
            RegrasDosControles.limiteDaAbaIsoEObturador(EN, tablet))
        for (c in RegrasDosControles.Controle.entries) {
            val frase = EN.s(c.naoLibera)
            assertTrue(frase, frase.startsWith("This device’s manufacturer doesn’t give other apps access to "))
        }
        assertEquals("Exposure and focus locked",
            RegrasDosControles.pilulaDoToqueLongo(EN, RegrasDosControles.travasDoToqueLongo(AjusteDaCamera(), a07)))
    }

    // --- §4.4 o toque ---

    @Test
    fun o_que_o_toque_mede() {
        val todas = a07.copy(regioesAwb = 1)
        assertEquals(setOf(Medida.AF, Medida.AE, Medida.AWB), RegrasDosControles.medidasDoToque(AjusteDaCamera(), todas))
        val manual = AjusteDaCamera(exposicao = AjusteDaCamera.Exposicao.MANUAL, iso = 100, obturadorNs = 1_000_000)
        assertEquals(setOf(Medida.AF), RegrasDosControles.medidasDoToque(manual, todas))
        val focoManual = AjusteDaCamera(foco = AjusteDaCamera.Foco.MANUAL, focoPosicao = 0.1)
        assertEquals(setOf(Medida.AE, Medida.AWB), RegrasDosControles.medidasDoToque(focoManual, todas))
        assertEquals(setOf(Medida.AE, Medida.AWB), RegrasDosControles.medidasDoToque(AjusteDaCamera(), fixa.copy(regioesAwb = 1)))
        assertTrue(RegrasDosControles.medidasDoToque(manual.copy(foco = AjusteDaCamera.Foco.MANUAL, focoPosicao = 0.1), todas).isEmpty())
    }

    @Test
    fun o_toque_longo_trava_e_o_simples_destrava() {
        val t = RegrasDosControles.travasDoToqueLongo(AjusteDaCamera(), a07)
        assertEquals("Exposição e foco travados", RegrasDosControles.pilulaDoToqueLongo(PT, t))
        val travado = RegrasDosControles.aposToqueLongo(AjusteDaCamera(), t)
        assertTrue(travado.travaExposicao)
        assertEquals(AjusteDaCamera.Foco.TRAVADO, travado.foco)
        assertNull("os valores vêm depois de convergir", travado.travaIso)
        val comValores = RegrasDosControles.comValoresDaTrava(travado, 320, 20_000_000, null, 0.4)
        assertEquals(320, comValores.travaIso)
        assertEquals(20_000_000L, comValores.travaObturadorNs)
        assertEquals(0.4, comValores.focoPosicao!!, 0.0)
        assertEquals(AjusteDaCamera(), RegrasDosControles.aposToqueSimplesQueDestrava(comValores, t).copy(focoPosicao = null))

        assertEquals("Exposição travada", RegrasDosControles.pilulaDoToqueLongo(PT, RegrasDosControles.travasDoToqueLongo(AjusteDaCamera(), fixa)))
        val focoSo = RegrasDosControles.travasDoToqueLongo(AjusteDaCamera(exposicao = AjusteDaCamera.Exposicao.MANUAL), a07)
        assertEquals("Foco travado", RegrasDosControles.pilulaDoToqueLongo(PT, focoSo))
        assertNull(RegrasDosControles.pilulaDoToqueLongo(PT, RegrasDosControles.TravasDoToque(false, false)))
    }

    @Test
    fun passar_para_manual_parte_do_lido() {
        val a = RegrasDosControles.passarParaManual(AjusteDaCamera(travaExposicao = true), 320, 20_000_000, a07, 30)
        assertEquals(AjusteDaCamera.Exposicao.MANUAL, a.exposicao)
        assertEquals(320, a.iso)
        assertEquals(20_000_000L, a.obturadorNs)
        assertFalse(a.travaExposicao)
        // Lido acima do teto: cortado.
        assertEquals(16_666_667L, RegrasDosControles.passarParaManual(AjusteDaCamera(), 320, 40_000_000, a07, 60).obturadorNs)
    }

    // --- §3.6 e §2.2 ---

    @Test
    fun a_divergencia_so_acende_depois_de_2_s_e_mais_de_um_passo() {
        assertFalse(RegrasDosControles.divergeEmStops(400.0, 500.0))
        assertTrue(RegrasDosControles.divergeEmStops(400.0, 640.0))
        assertFalse(RegrasDosControles.divergeEmKelvin(5200, 5300))
        assertTrue(RegrasDosControles.divergeEmKelvin(5200, 5400))
        val v = RegrasDosControles.VigiaDaDivergencia()
        assertFalse(v.observar(0, true))
        assertFalse(v.observar(1_999, true))
        assertTrue(v.observar(2_000, true))
        assertFalse(v.observar(2_100, false))
        assertFalse(v.observar(2_200, true))
    }

    @Test
    fun os_envios_sao_no_maximo_15_por_segundo() {
        val c = RegrasDosControles.Cadencia()
        assertEquals(0, c.atraso(1_000))
        c.enviou(1_000)
        assertEquals(67, c.atraso(1_000))
        assertEquals(27, c.atraso(1_040))
        assertEquals(0, c.atraso(1_100))
    }

    // --- a pouca luz (§3.1) ---

    @Test
    fun o_piso_do_automatico_e_o_das_faixas_da_bancada() {
        // As faixas anunciadas em 06/10 (`dumpsys media.camera`).
        val a07 = listOf(10 to 10, 15 to 15, 15 to 20, 20 to 20, 5 to 30, 30 to 30)
        val a07Frontal = listOf(10 to 10, 15 to 15, 15 to 20, 20 to 20, 10 to 30, 30 to 30)
        val tablet = listOf(15 to 15, 15 to 20, 20 to 20, 24 to 24, 15 to 30, 30 to 30)
        assertEquals(5, RegrasDosControles.pisoDoAutomatico(a07, 30))
        assertEquals(10, RegrasDosControles.pisoDoAutomatico(a07Frontal, 30))
        assertEquals(15, RegrasDosControles.pisoDoAutomatico(tablet, 30))
        // Prefere o piso de 10 a um que desce mais; sem faixa variável, a fixa de antes.
        assertEquals(10, RegrasDosControles.pisoDoAutomatico(listOf(5 to 30, 10 to 30, 30 to 30), 30))
        assertEquals(60, RegrasDosControles.pisoDoAutomatico(listOf(30 to 30, 60 to 60), 60))
        assertEquals(30, RegrasDosControles.pisoDoAutomatico(emptyList(), 30))
    }

    @Test
    fun um_fps_que_a_camera_nao_alcanca_vira_o_teto_dela() {
        // O A07 traseiro (06/10): nada chega a 60.
        val a07 = listOf(10 to 10, 15 to 15, 15 to 20, 20 to 20, 5 to 30, 10 to 30, 30 to 30)
        assertEquals(30, RegrasDosControles.tetoAlcancavel(a07, 60))
        assertEquals(10, RegrasDosControles.pisoDoAutomatico(a07, RegrasDosControles.tetoAlcancavel(a07, 60)))
        assertEquals(30, RegrasDosControles.tetoAlcancavel(a07, 30))
        // Quem faz 60 continua pedindo 60; sem faixas lidas, o pedido.
        assertEquals(60, RegrasDosControles.tetoAlcancavel(listOf(30 to 30, 60 to 60), 60))
        assertEquals(60, RegrasDosControles.tetoAlcancavel(emptyList(), 60))
    }

    @Test
    fun a_pouca_luz_acende_depois_de_1_s_e_apaga_depois_de_2_s() {
        val v = RegrasDosControles.VigiaDaPoucaLuz()
        val lento = 100_000_000L // 10 fps
        val normal = 33_333_333L
        assertNull(v.observar(0, auto = true, duracaoDoQuadroNs = lento, fps = 30))
        assertNull(v.observar(999, auto = true, duracaoDoQuadroNs = lento, fps = 30))
        assertEquals(10, v.observar(1_000, auto = true, duracaoDoQuadroNs = lento, fps = 30))
        // Um quadro normal no meio não apaga (e o fps dito é o do quadro); 2 s seguidos apagam.
        assertEquals(30, v.observar(1_250, auto = true, duracaoDoQuadroNs = normal, fps = 30))
        assertEquals(10, v.observar(1_500, auto = true, duracaoDoQuadroNs = lento, fps = 30))
        assertEquals(30, v.observar(2_000, auto = true, duracaoDoQuadroNs = normal, fps = 30))
        assertEquals(30, v.observar(3_999, auto = true, duracaoDoQuadroNs = normal, fps = 30))
        assertNull(v.observar(4_000, auto = true, duracaoDoQuadroNs = normal, fps = 30))
    }

    @Test
    fun a_pouca_luz_nao_acende_com_exposicao_manual_nem_na_folga_do_hal() {
        val v = RegrasDosControles.VigiaDaPoucaLuz()
        assertNull(v.observar(0, auto = false, duracaoDoQuadroNs = 100_000_000, fps = 30))
        assertNull(v.observar(5_000, auto = false, duracaoDoQuadroNs = 100_000_000, fps = 30))
        val w = RegrasDosControles.VigiaDaPoucaLuz()
        assertNull(w.observar(0, auto = true, duracaoDoQuadroNs = 36_000_000, fps = 30))
        assertNull(w.observar(5_000, auto = true, duracaoDoQuadroNs = 36_000_000, fps = 30))
    }

    @Test
    fun o_texto_da_pouca_luz_nas_duas_linguas() {
        assertEquals("Pouca luz: 15 fps para clarear a imagem. Para 30 fps, use a exposição manual na engrenagem.",
            RegrasDosControles.textoDaPoucaLuz(PT, 15, 30, temManual = true))
        assertEquals("Low light: 15 fps to brighten the picture. For 30 fps, use manual exposure in the gear menu.",
            RegrasDosControles.textoDaPoucaLuz(EN, 15, 30, temManual = true))
        assertEquals("Pouca luz: 15 fps para clarear a imagem. Mais luz no ambiente devolve os 30 fps.",
            RegrasDosControles.textoDaPoucaLuz(PT, 15, 30, temManual = false))
    }
}
