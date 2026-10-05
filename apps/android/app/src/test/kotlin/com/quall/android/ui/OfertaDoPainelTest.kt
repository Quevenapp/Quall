package com.quall.android.ui

import com.quall.android.capture.AjusteDaCamera.AntiCintilacao
import com.quall.android.capture.AjusteDaCamera.Balanco
import com.quall.android.capture.AjusteDaCamera.Foco
import com.quall.android.capture.CapacidadesDaCamera
import com.quall.android.capture.CapacidadesRemotas
import com.quall.android.capture.KelvinDng
import com.quall.android.capture.RegrasDosControles.Controle
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.teleprompter.JsonSimples
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * O que o painel "Ajustes da câmera" oferece (R9 e R9b): o da câmera deste aparelho e o da câmera do
 * outro lado, desenhado das capacidades que chegaram (`docs/controle-remoto-da-camera.md` §3.2, §12).
 */
class OfertaDoPainelTest {

    private val identidade = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
    private val forward = doubleArrayOf(0.7034, 0.1558, 0.1050, 0.2910, 0.8008, -0.0918, 0.0135, -0.1880, 0.9994)
    private val cal = KelvinDng.Calibracao(2856.0, identidade, forward, 6504.0, identidade, forward)

    private val a07 = CapacidadesDaCamera(
        manualSensor = true, manualPosProcessamento = true, leSensor = true,
        isoMin = 50, isoMax = 6400, isoMaxAnalogico = 800,
        exposicaoMinNs = 100_000, exposicaoMaxNs = 200_000_000,
        evIndiceMin = -20, evIndiceMax = 20, evPassoNum = 1, evPassoDen = 10,
        modosDeBalanco = setOf(0, 1, 2, 3, 4, 5, 6, 7, 8), modosAntiCintilacao = setOf(0, 1, 2, 3),
        travaAe = true, travaAwb = true, temAf = true, focoMinimoDioptrias = 10f, focoLido = true, focoCalibrado = true,
        calibracao = cal, regioesAe = 1, regioesAf = 1, regioesAwb = 0, abertura = 2.0f,
    )
    private val tablet = a07.copy(manualSensor = false, manualPosProcessamento = false, leSensor = false, calibracao = null,
        focoNaRequisicao = false, focoLido = false, focoCalibrado = false)

    private fun remota(caps: CapacidadesDaCamera, fps: Int = 30) =
        OfertaDoPainel.deRemota(JsonSimples.objeto(CapacidadesRemotas.json(caps, fps))!!, PT)

    private fun remota(json: String, t: com.quall.android.core.Textos = PT) = OfertaDoPainel.deRemota(JsonSimples.objeto(json)!!, t)

    /**
     * **O receptor desenha a câmera Android como o próprio filmador a desenha**: o que vai pelo fio
     * (§3.2) volta, do outro lado, ao mesmo painel — os mesmos degraus, o mesmo apagado.
     */
    @Test
    fun a_camera_android_do_outro_lado_e_a_mesma_que_a_daqui() {
        for (caps in listOf(a07, tablet)) {
            val local = OfertaDoPainel.deLocal(caps, 30, PT)
            val r = remota(caps)
            assertEquals(local.exposicaoManual, r.exposicaoManual)
            assertEquals(local.evs.size, r.evs.size)
            for (i in local.evs.indices) assertEquals(local.evs[i], r.evs[i], 1e-9)
            assertEquals(local.travaExposicao, r.travaExposicao)
            assertEquals(local.antiCintilacao, r.antiCintilacao)
            assertEquals(local.isos, r.isos)
            assertEquals(local.isoAnalogicoMax?.takeIf { local.exposicaoManual }, r.isoAnalogicoMax)
            assertEquals(local.fracoes, r.fracoes)
            assertEquals(local.balancos, r.balancos)
            assertEquals(local.travaBalanco, r.travaBalanco)
            assertEquals(local.focos, r.focos)
            assertEquals(local.toque, r.toque)
            assertEquals(local.dioptriasDoFoco, r.dioptriasDoFoco)
            assertEquals(local.limiteDaAbaIsoEObturador, r.limiteDaAbaIsoEObturador)
            assertEquals(local.limite(Controle.KELVIN), r.limite(Controle.KELVIN))
            assertEquals(local.limite(Controle.FOCO_MANUAL), r.limite(Controle.FOCO_MANUAL))
        }
    }

    @Test
    fun o_tablet_do_outro_lado_diz_que_o_fabricante_nao_libera() {
        val r = remota(tablet)
        assertFalse(r.exposicaoManual)
        assertEquals("O fabricante deste aparelho não libera ISO e o obturador para outros apps.", r.limiteDaAbaIsoEObturador)
        assertEquals("O fabricante deste aparelho não libera o foco manual para outros apps.", r.limite(Controle.FOCO_MANUAL))
    }

    /** O Mac (§3.2): só as travas e o ponto, e `macos` no resto; sem `exposicao` nem `balanco`. */
    private val mac = """{"plataforma":"macos","controles":{"travaExposicao":{},"travaBalanco":{},
        "foco":{"valores":["auto","travado"]},"toque":{}},
        "limites":{"ev":"macos","iso":"macos","obturadorNs":"macos","kelvin":"macos","antiCintilacao":"macos","focoPosicao":"macos"}}"""

    @Test
    fun o_mac_do_outro_lado_so_tem_as_travas_e_o_ponto() {
        val r = remota(mac)
        assertFalse(r.exposicaoManual)
        assertFalse(r.ev)
        assertTrue(r.travaExposicao)
        assertTrue(r.travaBalanco)
        assertEquals(setOf(Balanco.AUTO), r.balancos)
        assertEquals(setOf(Foco.AUTO, Foco.TRAVADO), r.focos)
        assertTrue(r.toque)
        assertTrue(r.antiCintilacao.isEmpty())
        assertEquals("O macOS não oferece a compensação de exposição para câmeras.", r.limite(Controle.EV))
        assertEquals("O macOS não oferece ISO e o obturador para câmeras.", r.limiteDaAbaIsoEObturador)
        assertEquals("O macOS não oferece o Kelvin para câmeras.", r.limite(Controle.KELVIN))
        assertEquals("macOS doesn’t offer exposure compensation for cameras.", remota(mac, EN).limite(Controle.EV))
    }

    /** O Windows (§3.2, achado I7): o brilho do driver em `ev`, o ganho em `iso`, o obturador em log2. */
    private val windows = """{"plataforma":"windows","controles":{
        "exposicao":{"valores":["auto","manual"]},
        "ev":{"min":-64,"max":64,"passo":1,"unidade":"brilho","origem":128},
        "iso":{"min":0,"max":100,"passo":1,"inteiro":true,"unidade":"ganho"},
        "obturadorNs":{"min":1000000,"max":33333333,"inteiro":true,"escala":"log2"},
        "balanco":{"valores":["auto","kelvin"]},"kelvin":{"min":2800,"max":6500,"passo":100,"inteiro":true}},
        "limites":{"focoPosicao":"camera_nao_oferece","foco":"camera_nao_oferece","toque":"camera_nao_oferece",
          "antiCintilacao":"outro_app"}}"""

    @Test
    fun o_windows_do_outro_lado_mostra_brilho_e_ganho() {
        val r = remota(windows)
        assertEquals("Brilho", r.tituloDoEv(PT))
        assertEquals("128", r.textoDoEv(PT, 0.0))
        assertEquals("138", r.textoDoEv(PT, 10.0))
        assertEquals(129, r.evs.size)
        assertEquals("Ganho", r.tituloDoIso(PT))
        assertEquals("Gain", r.tituloDoIso(EN))
        assertTrue(r.isoEhGanho)
        assertEquals((0..100).toList(), r.isos)
        assertEquals("40", r.textoDoIso(40))
        // 1/2^k s dentro de 1 ms a 33 ms: 1/32 a 1/512 (1/1024 é 0,98 ms, abaixo do mínimo).
        assertEquals(listOf(32, 64, 128, 256, 512), r.fracoes)
        assertEquals(2800, r.kelvinMin)
        assertEquals(6500, r.kelvinMax)
        assertTrue(r.focos.isEmpty())
        assertEquals("Esta câmera não oferece o foco.", r.limiteDoFoco)
        assertEquals("Esta câmera não oferece o toque para focar.", r.limite(Controle.TOQUE))
        assertEquals("Outro app está controlando esta câmera. Feche-o para ajustar.", r.limite(Controle.ANTI_CINTILACAO))
    }

    @Test
    fun o_ev_do_outro_lado_nao_passa_do_maximo() {
        val r = remota("""{"controles":{"ev":{"min":-2.0,"max":2.0,"passo":0.1}}}""")
        assertEquals(41, r.evs.size)
        assertEquals(-2.0, r.evs.first(), 0.0)
        assertEquals(2.0, r.evs.last(), 0.0)
        assertTrue(r.evs.all { it in -2.0..2.0 })
    }

    @Test
    fun as_frases_de_quem_limita_por_codigo() {
        assertEquals("O iOS ajusta a cintilação sozinho.", OfertaDoPainel.frase(PT, "ios_cintilacao", Controle.ANTI_CINTILACAO))
        assertEquals("Esta câmera tem foco fixo.", OfertaDoPainel.frase(PT, "foco_fixo", Controle.FOCO_MANUAL))
        assertEquals("Este aparelho não oferece a trava de foco.", OfertaDoPainel.frase(PT, "codigo_novo", Controle.TRAVA_FOCO))
        assertEquals("This device doesn’t offer focus lock.", OfertaDoPainel.frase(EN, "codigo_novo", Controle.TRAVA_FOCO))
        assertEquals("O fabricante deste aparelho não libera o Kelvin para outros apps.", OfertaDoPainel.frase(PT, "fabricante", Controle.KELVIN))
        assertNull(remota(a07).limite(Controle.ISO))
    }

    @Test
    fun anti_cintilacao_do_outro_lado_so_com_o_que_veio() {
        val r = remota("""{"controles":{"antiCintilacao":{"valores":["auto","60"]}}}""")
        assertEquals(setOf(AntiCintilacao.AUTO, AntiCintilacao.HZ60), r.antiCintilacao)
    }
}
