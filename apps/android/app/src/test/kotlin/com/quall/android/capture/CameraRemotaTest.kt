package com.quall.android.capture

import com.quall.android.teleprompter.JsonSimples
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * O lado de quem filma no controle remoto da câmera (R9b, `docs/controle-remoto-da-camera.md` §3.2, §3.3
 * e §6), sem aparelho: as capacidades que o Android publica, o pedido da fila e o que se aplica dele.
 */
class CameraRemotaTest {

    private val identidade = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
    private val forward = doubleArrayOf(0.7034, 0.1558, 0.1050, 0.2910, 0.8008, -0.0918, 0.0135, -0.1880, 0.9994)
    private val cal = KelvinDng.Calibracao(2856.0, identidade, forward, 6504.0, identidade, forward)

    /** A frontal do A07 (a mesma de `RegrasDosControlesTest`), com o foco calibrado. */
    private val a07 = CapacidadesDaCamera(
        manualSensor = true, manualPosProcessamento = true, leSensor = true,
        isoMin = 50, isoMax = 6400, isoMaxAnalogico = 800,
        exposicaoMinNs = 100_000, exposicaoMaxNs = 200_000_000,
        evIndiceMin = -20, evIndiceMax = 20, evPassoNum = 1, evPassoDen = 10,
        modosDeBalanco = setOf(0, 1, 2, 3, 4, 5, 6, 7, 8), modosAntiCintilacao = setOf(0, 1, 2, 3),
        travaAe = true, travaAwb = true, temAf = true, focoMinimoDioptrias = 10f, focoLido = true, focoCalibrado = true,
        calibracao = cal, regioesAe = 1, regioesAf = 1, regioesAwb = 0, abertura = 2.0f,
    )

    /** O tablet: sem `MANUAL_SENSOR` nem `MANUAL_POST_PROCESSING` (bancada §8.76). */
    private val tablet = a07.copy(manualSensor = false, manualPosProcessamento = false, leSensor = false, calibracao = null,
        focoNaRequisicao = false, focoLido = false, focoCalibrado = false)

    private fun mapa(json: String): Map<String, Any?> = requireNotNull(JsonSimples.objeto(json)) { json }

    @Suppress("UNCHECKED_CAST")
    private fun controles(json: String) = mapa(json)["controles"] as Map<String, Map<String, Any?>>

    @Suppress("UNCHECKED_CAST")
    private fun limites(json: String) = mapa(json)["limites"] as Map<String, String>

    // --- as capacidades (§3.2) ---

    @Test
    fun as_capacidades_do_a07_tem_os_quatro_grupos_e_inteiro_onde_o_registro_trunca() {
        val j = CapacidadesRemotas.json(a07, 30, "Frontal")
        val c = controles(j)
        assertEquals(listOf("auto", "manual"), c["exposicao"]!!["valores"])
        assertEquals(true, c["iso"]!!["inteiro"])
        assertEquals(true, c["kelvin"]!!["inteiro"])
        assertEquals(true, c["obturadorNs"]!!["inteiro"])
        assertEquals(800.0, c["iso"]!!["analogicoMax"])
        assertEquals(listOf("auto", "50", "60", "desligada"), c["antiCintilacao"]!!["valores"])
        assertEquals(listOf("auto", "incandescente", "fluorescente", "luzDoDia", "nublado", "kelvin"), c["balanco"]!!["valores"])
        assertEquals(listOf("auto", "travado", "manual"), c["foco"]!!["valores"])
        assertEquals(10.0, c["focoPosicao"]!!["calibrado"])
        for (k in listOf("travaExposicao", "travaBalanco", "toque")) assertTrue(k, c[k]!!.isEmpty())
        assertTrue(limites(j).isEmpty())
        assertEquals("android", mapa(j)["plataforma"])
        assertEquals("Frontal", mapa(j)["nomeDaCamera"])
        // Os campos de trava lida nunca aparecem (§3.2).
        for (k in listOf("travaIso", "travaObturadorNs", "travaGanhos")) assertFalse(k, k in c)
        assertTrue("cabe no teto de 2.048 bytes: ${j.length}", j.toByteArray().size <= 2048)
    }

    @Test
    fun o_ev_vai_do_indice_e_o_maximo_nao_passa_por_um_bit() {
        val ev = controles(CapacidadesRemotas.json(a07, 30))["ev"]!!
        assertEquals(-2.0, ev["min"])
        assertEquals(2.0, ev["max"])
        assertEquals(0.1, ev["passo"])
    }

    @Test
    fun o_teto_do_obturador_segue_o_fps() {
        val a30 = controles(CapacidadesRemotas.json(a07, 30))["obturadorNs"]!!
        val a60 = controles(CapacidadesRemotas.json(a07, 60))["obturadorNs"]!!
        assertEquals(33_333_333.0, a30["max"])
        assertEquals(16_666_667.0, a60["max"])
        assertEquals(100_000.0, a30["min"])
        // O número inteiro vai sem ".0" no fio (§3).
        assertTrue(CapacidadesRemotas.json(a07, 30).contains("\"max\":33333333,"))
    }

    @Test
    fun o_tablet_poe_fabricante_no_iso_no_obturador_e_no_foco_manual() {
        val j = CapacidadesRemotas.json(tablet, 30)
        val c = controles(j)
        val l = limites(j)
        assertFalse("exposicao" in c)
        assertFalse("iso" in c)
        assertFalse("obturadorNs" in c)
        assertFalse("focoPosicao" in c)
        assertFalse("kelvin" in c)
        assertEquals("fabricante", l["iso"])
        assertEquals("fabricante", l["obturadorNs"])
        assertEquals("fabricante", l["focoPosicao"])
        assertEquals("fabricante", l["kelvin"])
        // Sem foco manual, Auto e Travado continuam.
        assertEquals(listOf("auto", "travado"), c["foco"]!!["valores"])
    }

    @Test
    fun foco_fixo_e_kelvin_sem_calibracao() {
        val fixa = a07.copy(temAf = false, focoMinimoDioptrias = 0f, regioesAf = 0, calibracao = null)
        val l = limites(CapacidadesRemotas.json(fixa, 30))
        assertEquals("foco_fixo", l["foco"])
        assertEquals("foco_fixo", l["focoPosicao"])
        assertEquals("sem_calibracao", l["kelvin"])
    }

    @Test
    fun o_nome_da_camera_corta_em_64_bytes_sem_partir_caractere() {
        val nome = "câmera ".repeat(20)
        val cortado = CapacidadesRemotas.cortarEmBytes(nome, 64)
        assertTrue(cortado.toByteArray().size <= 64)
        assertTrue(nome.startsWith(cortado))
        assertEquals("😀😀", CapacidadesRemotas.cortarEmBytes("😀😀😀", 9))
    }

    // --- o pedido da fila (§6) ---

    @Test
    fun le_o_pedido_da_fila_do_nucleo() {
        val p = PedidoRemoto.ler("""{"n":5,"autor":"OBS no Dell","autor_id":"dell-7f2a","ajuste":{"exposicao":"manual","iso":800},"restaurar":false,"toque":{"x":0.25,"y":0.75,"longo":true}}""")!!
        assertEquals(5L, p.n)
        assertEquals("OBS no Dell", p.autor)
        assertEquals("manual", p.ajuste["exposicao"])
        assertEquals(800.0, p.ajuste["iso"])
        assertEquals(PedidoRemoto.Toque(0.25, 0.75, true), p.toque)
        assertNull(PedidoRemoto.ler("""{"ajuste":{}}"""))
        assertNull(PedidoRemoto.ler("lixo"))
    }

    private val lidos = RegrasDoPedidoRemoto.Lidos(iso = 320, obturadorNs = 10_000_000, ganhos = listOf(2.0, 1.0, 1.0, 1.5),
        focoPosicao = 0.4, kelvin = 4870)

    private fun pedido(ajuste: Map<String, Any?>, restaurar: Boolean = false) = PedidoRemoto(1, "OBS", ajuste, restaurar, null)

    @Test
    fun manual_com_iso_fica_com_o_iso_pedido_e_o_obturador_parte_do_lido() {
        val a = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("exposicao" to "manual", "iso" to 800.0)), lidos, a07, 30)!!
        assertEquals(AjusteDaCamera.Exposicao.MANUAL, a.exposicao)
        assertEquals(800, a.iso)
        assertEquals(10_000_000L, a.obturadorNs)
    }

    @Test
    fun manual_sozinho_parte_do_lido_como_o_passar_para_manual() {
        val a = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("exposicao" to "manual")), lidos, a07, 30)!!
        assertEquals(RegrasDosControles.passarParaManual(AjusteDaCamera(), 320, 10_000_000, a07, 30), a)
    }

    @Test
    fun manual_sem_lido_e_sem_valor_e_recusado() {
        val semLido = RegrasDoPedidoRemoto.Lidos()
        assertNull(RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("exposicao" to "manual")), semLido, a07, 30))
        // Com os dois valores no pedido, não precisa do lido.
        val a = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("exposicao" to "manual", "iso" to 400.0, "obturadorNs" to 20_000_000.0)),
            semLido, a07, 30)!!
        assertEquals(400, a.iso)
        assertEquals(20_000_000L, a.obturadorNs)
    }

    @Test
    fun restaurar_vem_antes_dos_campos_do_mesmo_pedido() {
        val antes = AjusteDaCamera(exposicao = AjusteDaCamera.Exposicao.MANUAL, iso = 1600, obturadorNs = 5_000_000, ev = 1.0,
            balanco = AjusteDaCamera.Balanco.NUBLADO)
        val a = RegrasDoPedidoRemoto.aplicar(antes, pedido(mapOf("ev" to 0.5), restaurar = true), lidos, a07, 30)!!
        assertEquals(AjusteDaCamera(ev = 0.5), a)
    }

    @Test
    fun kelvin_pedido_junto_com_o_modo_e_cortado_a_100() {
        val a = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("balanco" to "kelvin", "kelvin" to 5230.0)), lidos, a07, 30)!!
        assertEquals(AjusteDaCamera.Balanco.KELVIN, a.balanco)
        assertEquals(5200, a.kelvin)
        // Só o modo: parte do lido.
        val b = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("balanco" to "kelvin")), lidos, a07, 30)!!
        assertEquals(4900, b.kelvin)
    }

    @Test
    fun foco_manual_com_posicao_e_travado_le_a_posicao() {
        val a = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("foco" to "manual", "focoPosicao" to 0.123)), lidos, a07, 30)!!
        assertEquals(AjusteDaCamera.Foco.MANUAL, a.foco)
        assertEquals(0.12, a.focoPosicao!!, 1e-9)
        val t = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("foco" to "travado")), lidos, a07, 30)!!
        assertEquals(0.4, t.focoPosicao!!, 1e-9)
    }

    @Test
    fun ev_vai_ao_passo_da_camera() {
        val a = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("ev" to 0.37)), lidos, a07, 30)!!
        assertEquals(0.4, a.ev, 1e-9)
    }

    @Test
    fun trava_grava_o_lido_mas_nao_quando_o_modo_muda_no_mesmo_pedido() {
        val t = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(), pedido(mapOf("travaExposicao" to true)), lidos, a07, 30)!!
        assertEquals(320, t.travaIso)
        assertEquals(10_000_000L, t.travaObturadorNs)
        val manual = AjusteDaCamera(exposicao = AjusteDaCamera.Exposicao.MANUAL, iso = 1600, obturadorNs = 5_000_000)
        val m = RegrasDoPedidoRemoto.aplicar(manual, pedido(mapOf("exposicao" to "auto", "travaExposicao" to true)), lidos, a07, 30)!!
        assertTrue(m.travaExposicao)
        assertNull("o lido é do modo manual, não do automático que ainda vai convergir", m.travaIso)
        val b = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(balanco = AjusteDaCamera.Balanco.NUBLADO),
            pedido(mapOf("balanco" to "auto", "travaBalanco" to true)), lidos, a07, 30)!!
        assertTrue(b.travaBalanco)
        assertNull(b.travaGanhos)
    }

    @Test
    fun anti_cintilacao_e_iso_cortado_na_faixa() {
        val a = RegrasDoPedidoRemoto.aplicar(AjusteDaCamera(exposicao = AjusteDaCamera.Exposicao.MANUAL, iso = 100, obturadorNs = 1_000_000),
            pedido(mapOf("antiCintilacao" to "60", "iso" to 99999.0)), lidos, a07, 30)!!
        assertEquals(AjusteDaCamera.AntiCintilacao.HZ60, a.antiCintilacao)
        assertEquals(6400, a.iso)
    }

    // --- o lido (§3.3) ---

    @Test
    fun o_lido_so_leva_o_que_a_camera_leu_e_os_divergentes() {
        val j = RegrasDoPedidoRemoto.lidoJson(400, 16_666_666, null, 1.7f, 0.5, listOf("iso"))
        assertEquals("""{"iso":400,"obturadorNs":16666666,"abertura":1.7,"focoPosicao":0.5,"divergentes":["iso"]}""", j)
        assertEquals("""{"divergentes":[]}""", RegrasDoPedidoRemoto.lidoJson(null, null, null, null, null, emptyList()))
        assertNotNull(JsonSimples.objeto(j))
    }
}
