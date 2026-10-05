package com.quall.android.capture

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * A receita do Kelvin pelo DNG (`docs/controles-de-camera.md` §3.4): K → xy, a interpolação em 1/K, os
 * ganhos RGGB, a matriz de correção que nunca é a identidade, e a conta inversa dos ganhos ao K.
 */
class KelvinDngTest {

    private val identidade = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)

    /** Uma matriz de cor plausível (XYZ → câmera) em D65, e outra em A, no formato do `ColorMatrix` do DNG. */
    private val corD65 = doubleArrayOf(0.4716, 0.0603, -0.0830, -0.7798, 1.5474, 0.2480, -0.1496, 0.1937, 0.6651)
    private val corA = doubleArrayOf(0.5309, -0.0231, -0.0463, -0.8027, 1.5592, 0.2440, -0.1209, 0.2040, 0.7700)

    /** Uma forward plausível: cada linha soma o branco D50 (0,9642; 1; 0,8249), como o DNG exige. */
    private val forward = doubleArrayOf(0.7034, 0.1558, 0.1050, 0.2910, 0.8008, -0.0918, 0.0135, -0.1880, 0.9994)
    private val forwardA = doubleArrayOf(0.6596, 0.2050, 0.0996, 0.2600, 0.8414, -0.1014, 0.0010, -0.1460, 0.9699)

    private val cal = KelvinDng.Calibracao(2856.0, corA, forwardA, 6504.0, corD65, forward)

    @Test
    fun o_lugar_de_planck_e_o_da_luz_do_dia_batem_com_a_e_d65() {
        val (xa, ya) = KelvinDng.xyDoKelvin(2856.0)
        assertEquals(0.4476, xa, 0.0015)
        assertEquals(0.4074, ya, 0.0015)
        val (xd, yd) = KelvinDng.xyDoKelvin(6504.0)
        assertEquals(0.3127, xd, 0.0015)
        assertEquals(0.3290, yd, 0.0015)
        // 5003 K (D50) e o corte da conta.
        val (x50, y50) = KelvinDng.xyDoKelvin(5003.0)
        assertEquals(0.3457, x50, 0.0015)
        assertEquals(0.3585, y50, 0.0015)
        assertEquals(KelvinDng.xyDoKelvin(1667.0), KelvinDng.xyDoKelvin(1000.0))
        assertEquals(1.0, KelvinDng.xyzDoKelvin(4500.0)[1], 0.0)
    }

    @Test
    fun as_iluminacoes_da_bancada_tem_temperatura() {
        assertEquals(2856.0, KelvinDng.temperaturaDaIluminacao(17)!!, 0.0)
        assertEquals(6504.0, KelvinDng.temperaturaDaIluminacao(21)!!, 0.0)
        assertNull(KelvinDng.temperaturaDaIluminacao(0))
        assertNull(KelvinDng.Calibracao.de(21, corD65, forward, null, corA, forwardA))
        assertNull(KelvinDng.Calibracao.de(21, corD65, forward, 17, corA, null))
        assertNull("duas iluminações iguais não interpolam", KelvinDng.Calibracao.de(21, corD65, forward, 21, corA, forwardA))
        assertNotNull(KelvinDng.Calibracao.de(17, corA, forwardA, 21, corD65, forward))
    }

    @Test
    fun a_interpolacao_e_em_1_sobre_k_e_vale_a_ponta_fora_do_intervalo() {
        assertEquals(1.0, KelvinDng.pesoDa1(cal, 2856.0), 1e-12)
        assertEquals(0.0, KelvinDng.pesoDa1(cal, 6504.0), 1e-12)
        assertEquals(1.0, KelvinDng.pesoDa1(cal, 2000.0), 0.0)
        assertEquals(0.0, KelvinDng.pesoDa1(cal, 9000.0), 0.0)
        // No meio em 1/K, e não em K: (1/K = média de 1/2856 e 1/6504) ≈ 3969 K, e não 4680 K.
        val meio = 1.0 / ((1.0 / 2856 + 1.0 / 6504) / 2)
        assertEquals(0.5, KelvinDng.pesoDa1(cal, meio), 1e-12)
        assertTrue(KelvinDng.pesoDa1(cal, 4680.0) < 0.5)
    }

    @Test
    fun com_a_matriz_identidade_os_ganhos_sao_1_sobre_o_xyz() {
        val c = KelvinDng.Calibracao(2856.0, identidade, identidade, 6504.0, identidade, identidade)
        val xyz = KelvinDng.xyzDoKelvin(6504.0)
        val g = KelvinDng.ganhos(c, 6504.0)!!
        assertEquals(4, g.size)
        assertEquals(1.0 / xyz[0], g[0], 1e-12)
        assertEquals(1.0, g[1], 0.0)
        assertEquals(g[1], g[2], 0.0)
        assertEquals(1.0 / xyz[2], g[3], 1e-12)
    }

    @Test
    fun luz_quente_pede_mais_azul_e_menos_vermelho() {
        val quente = KelvinDng.ganhos(cal, 2856.0)!!
        val fria = KelvinDng.ganhos(cal, 7500.0)!!
        assertTrue(quente[3] > fria[3])
        assertTrue(quente[0] < fria[0])
    }

    @Test
    fun a_matriz_de_correcao_leva_o_branco_ao_branco_e_nunca_e_a_identidade() {
        for (k in listOf(2000.0, 2856.0, 4000.0, 5500.0, 6504.0, 10000.0)) {
            val m = KelvinDng.matrizDeCorrecao(cal, k)
            val branco = KelvinDng.vezes(m, doubleArrayOf(1.0, 1.0, 1.0))
            for (v in branco) assertEquals("branco em $k K", 1.0, v, 0.01)
            assertFalse(m.contentEquals(identidade))
            assertTrue(abs(m[0] - 1.0) > 0.05)
        }
        // A de Lindbloom leva o branco D50 ao branco do sRGB.
        val d50 = KelvinDng.vezes(KelvinDng.XYZ_D50_PARA_SRGB, doubleArrayOf(0.9642, 1.0, 0.8249))
        for (v in d50) assertEquals(1.0, v, 0.001)
    }

    @Test
    fun a_conta_inversa_volta_ao_mesmo_kelvin() {
        for (k in listOf(2000, 2500, 2856, 3200, 3800, 4200, 4500, 5200, 6504, 7500, 10000)) {
            val g = KelvinDng.ganhos(cal, k.toDouble())!!
            val volta = KelvinDng.kelvinDosGanhos(cal, g)!!
            assertEquals("ida e volta em $k K", k.toDouble(), volta, k * 0.005)
        }
    }

    /**
     * **A dobra dos 4000 K.** A receita do §3.4 troca de lugar em 4000 K: abaixo, Planck (Kim et al.);
     * dali em diante, a luz do dia da CIE, que passa acima de Planck (em 4000 K, xy 0,3823/0,3838 contra
     * 0,3805/0,3768). A razão vermelho/azul do neutro **salta para trás** ali, e as razões do salto
     * correspondem a dois K, um de cada lado. Medido com as matrizes deste teste: entre 3900 e 4100 K a
     * conta inversa erra até ~100 K (um passo do deslizante); fora dessa janela, a ida e volta é exata.
     */
    @Test
    fun perto_de_4000_k_a_conta_inversa_erra_ate_um_passo() {
        for (k in 3900..4100 step 10) {
            val volta = KelvinDng.kelvinDosGanhos(cal, KelvinDng.ganhos(cal, k.toDouble())!!)!!
            assertEquals("em $k K", k.toDouble(), volta, 110.0)
        }
        val (xp, yp) = KelvinDng.xyDoKelvin(3999.999)
        val (xd, yd) = KelvinDng.xyDoKelvin(4000.0)
        assertTrue(yd - yp > 0.005)
        assertTrue(xd > xp)
    }

    @Test
    fun a_conta_inversa_aguenta_ganhos_arredondados_a_1_sobre_256_e_verdes_desiguais() {
        // O HAL do A10s devolve os ganhos arredondados a 1/256 (`bancada.md` §8.77).
        val g = KelvinDng.ganhos(cal, 5200.0)!!
        val arredondado = DoubleArray(4) { Math.round(g[it] * 256) / 256.0 }
        arredondado[2] = arredondado[1] * 1.004
        val volta = KelvinDng.kelvinDosGanhos(cal, arredondado)!!
        assertEquals(5200.0, volta, 100.0)
        assertNull(KelvinDng.kelvinDosGanhos(cal, doubleArrayOf(1.0, 1.0, 1.0)))
        assertNull(KelvinDng.kelvinDosGanhos(cal, doubleArrayOf(0.0, 1.0, 1.0, 1.0)))
    }

    @Test
    fun ganhos_fora_do_lugar_param_na_ponta() {
        val g = KelvinDng.ganhos(cal, 25000.0)!!
        val alem = doubleArrayOf(g[0] * 1.5, 1.0, 1.0, g[3] / 1.5)
        assertEquals(25000.0, KelvinDng.kelvinDosGanhos(cal, alem)!!, 1e-6)
        val g2 = KelvinDng.ganhos(cal, 1667.0)!!
        assertEquals(1667.0, KelvinDng.kelvinDosGanhos(cal, doubleArrayOf(g2[0] / 1.5, 1.0, 1.0, g2[3] * 1.5))!!, 1e-6)
    }

    /**
     * **A câmera 0 do A07, com os números do aparelho** (o dump cru da sonda de 01/10: iluminação 1 =
     * D65, 2 = A, as matrizes em /65536) e os ganhos que o `CaptureResult` devolveu na corrida da sessão
     * principal de 01/10 (arredondados a 1/256 pelo HAL). Naquela corrida o roteiro leu "None K": a conta
     * estava certa e o defeito era do roteiro, que limpava o logcat antes de ler a linha
     * `r9: lido depois de aplicar` (ver `prova-r9-controles.py`). Este teste prende a conta.
     */
    @Test
    fun a07_camera_0_os_ganhos_do_quadro_voltam_ao_kelvin_pedido() {
        fun m(vararg v: Int) = DoubleArray(9) { v[it] / 65536.0 }
        val a07 = KelvinDng.Calibracao.de(
            21, m(43699, -10413, -5619, -37614, 91081, 9373, -9036, 17377, 39559),
            m(44115, 12782, 6293, 18100, 53622, -6187, 1419, -15234, 67896),
            17, m(100366, -30776, -14094, -31210, 94721, 439, -4702, 15645, 15267),
            m(37650, 12059, 13481, 12702, 48849, 3984, -950, -34648, 89680),
        )!!
        // O que o Quall pediu (o dumpsys mostrou o mesmo): 3000 K → 0,8796/1/1/3,5327; 7000 K → 2,6975/1/1/1,2116.
        val g3000 = KelvinDng.ganhos(a07, 3000.0)!!
        assertEquals(0.87957, g3000[0], 1e-4)
        assertEquals(3.53275, g3000[3], 1e-4)
        val g7000 = KelvinDng.ganhos(a07, 7000.0)!!
        assertEquals(2.69746, g7000[0], 1e-4)
        assertEquals(1.21159, g7000[3], 1e-4)
        // O que o quadro devolveu.
        assertEquals(3000.0, KelvinDng.kelvinDosGanhos(a07, doubleArrayOf(0.87890625, 1.0, 1.0, 3.53320312))!!, 50.0)
        assertEquals(7000.0, KelvinDng.kelvinDosGanhos(a07, doubleArrayOf(2.69726562, 1.0, 1.0, 1.2109375))!!, 100.0)
    }

    @Test
    fun a_algebra() {
        val a = doubleArrayOf(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0)
        assertArrayEquals(a, KelvinDng.vezes3(a, identidade), 0.0)
        assertArrayEquals(a, KelvinDng.vezes3(identidade, a), 0.0)
        assertArrayEquals(doubleArrayOf(6.0, 15.0, 24.0), KelvinDng.vezes(a, doubleArrayOf(1.0, 1.0, 1.0)), 0.0)
    }
}
