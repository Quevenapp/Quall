package com.quall.android.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** O registro do R9 (`docs/controles-de-camera.md` §2): os nomes literais e o JSON de ida e volta. */
class AjusteDaCameraTest {

    @Test
    fun o_padrao_e_o_da_tabela() {
        val p = AjusteDaCamera()
        assertEquals(AjusteDaCamera.Exposicao.AUTO, p.exposicao)
        assertEquals(0.0, p.ev, 0.0)
        assertFalse(p.travaExposicao)
        assertEquals(AjusteDaCamera.AntiCintilacao.AUTO, p.antiCintilacao)
        assertEquals(AjusteDaCamera.Balanco.AUTO, p.balanco)
        assertEquals(AjusteDaCamera.Foco.AUTO, p.foco)
        assertTrue(p.ehPadrao)
        assertNull(p.iso)
        assertNull(p.travaGanhos)
    }

    @Test
    fun o_json_usa_os_nomes_e_os_valores_literais() {
        val j = AjusteDaCamera(
            exposicao = AjusteDaCamera.Exposicao.MANUAL, iso = 400, obturadorNs = 16_666_667,
            antiCintilacao = AjusteDaCamera.AntiCintilacao.HZ60, balanco = AjusteDaCamera.Balanco.LUZ_DO_DIA,
            foco = AjusteDaCamera.Foco.TRAVADO, focoPosicao = 0.25,
        ).paraJson()
        for (trecho in listOf("\"exposicao\":\"manual\"", "\"iso\":400", "\"obturadorNs\":16666667",
            "\"antiCintilacao\":\"60\"", "\"balanco\":\"luzDoDia\"", "\"foco\":\"travado\"", "\"focoPosicao\":0.25",
            "\"travaExposicao\":false", "\"travaIso\":null", "\"travaObturadorNs\":null", "\"kelvin\":null",
            "\"travaBalanco\":false", "\"travaGanhos\":null", "\"ev\":0")) {
            assertTrue("falta $trecho em $j", trecho in j)
        }
        assertTrue("\"antiCintilacao\":\"desligada\"" in AjusteDaCamera(antiCintilacao = AjusteDaCamera.AntiCintilacao.DESLIGADA).paraJson())
        assertTrue("\"antiCintilacao\":\"50\"" in AjusteDaCamera(antiCintilacao = AjusteDaCamera.AntiCintilacao.HZ50).paraJson())
    }

    @Test
    fun ida_e_volta_preserva_tudo() {
        val a = AjusteDaCamera(
            exposicao = AjusteDaCamera.Exposicao.AUTO, ev = -0.7, travaExposicao = true, travaIso = 250,
            travaObturadorNs = 8_333_333, iso = 1600, obturadorNs = 33_333_333,
            antiCintilacao = AjusteDaCamera.AntiCintilacao.HZ50, balanco = AjusteDaCamera.Balanco.AUTO, kelvin = 5200,
            travaBalanco = true, travaGanhos = listOf(2.71875, 1.0, 1.0, 0.86328125),
            foco = AjusteDaCamera.Foco.MANUAL, focoPosicao = 0.37,
        )
        assertEquals(a, AjusteDaCamera.deJson(a.paraJson()))
        assertEquals(AjusteDaCamera(), AjusteDaCamera.deJson(AjusteDaCamera().paraJson()))
        for (b in AjusteDaCamera.Balanco.entries) {
            assertEquals(b, AjusteDaCamera.deJson(AjusteDaCamera(balanco = b).paraJson())!!.balanco)
        }
    }

    @Test
    fun valor_desconhecido_fica_no_padrao_e_lixo_e_nulo() {
        val a = AjusteDaCamera.deJson("""{"exposicao":"prioridade","balanco":"sombra","iso":200,"travaGanhos":[1,2]}""")!!
        assertEquals(AjusteDaCamera.Exposicao.AUTO, a.exposicao)
        assertEquals(AjusteDaCamera.Balanco.AUTO, a.balanco)
        assertEquals(200, a.iso)
        assertNull("ganhos são quatro (RGGB)", a.travaGanhos)
        assertNull(AjusteDaCamera.deJson("isto não é json"))
        assertNull(AjusteDaCamera.deJson(null))
        assertNull(AjusteDaCamera.deJson(""))
    }
}
