package com.quall.android.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Testes de [RelogioDoSom] e [HoraDaCaptura] (`docs/som-no-receptor.md` §19.3). **Rodam na JVM,
 * sem aparelho**: as duas peças são aritmética pura. O caminho do `AudioRecord` (a captura do
 * próprio app) só se prova aqui — ele nunca roda em corrida, pela regra do som só sintético.
 *
 * Os casos do Mac (`TestesDoRelogioDoSom.swift`) estão aqui com os mesmos números: a lacuna de
 * 1,5 s, a curta abaixo do limiar, a deriva sem reancorar abaixo de 40 ms. E os do Android: a vaga
 * do tom quando o laço religa o acumulador, e a captura que carimba na captura, e não no envio.
 */
class RelogioDoSomTest {

    private val quadroUs = 20_000L
    private val t0 = 7_000_000_000L // ~1 h 57 min de MONOTONIC

    @Test
    fun o_primeiro_quadro_ancora_e_a_linha_anda_um_quadro_por_vez() {
        val r = RelogioDoSom(quadroUs)
        // A hora da fonte com jitter de ±5 ms: o carimbo não tem jitter nenhum.
        val jitter = longArrayOf(0, 3_000, -4_000, 5_000, -1_000, 2_000)
        val carimbos = (0 until 6).map { r.carimbar(t0 + it * quadroUs + jitter[it]) }
        assertEquals((0 until 6).map { t0 + it * quadroUs }, carimbos)
        assertEquals(0, r.reancoragens)
        assertEquals(5_000L, r.maiorDesvioUs)
    }

    @Test
    fun a_lacuna_de_1_5_s_reancora() {
        val r = RelogioDoSom(quadroUs)
        repeat(500) { r.carimbar(t0 + it * quadroUs) }
        // 1,5 s de quadros que não vieram (a fonte parou e voltou).
        val volta = t0 + 500 * quadroUs + 1_500_000
        assertEquals(volta, r.carimbar(volta))
        assertEquals(volta + quadroUs, r.carimbar(volta + quadroUs))
        assertEquals(1, r.reancoragens)
        assertEquals(1_500_000L, r.maiorSaltoUs)
        assertEquals(0L, r.desvioUs)
    }

    @Test
    fun o_controle_sem_reancorar_fica_1_5_s_atras() {
        // O comportamento que a reancoragem conserta: o tempo de mídia puro, da primeira âncora.
        val r = RelogioDoSom(quadroUs, reancorar = false)
        repeat(500) { r.carimbar(t0 + it * quadroUs) }
        val volta = t0 + 500 * quadroUs + 1_500_000
        val c = r.carimbar(volta)
        assertEquals(t0 + 500 * quadroUs, c)
        assertEquals(1_500_000L, volta - c)
        assertEquals(0, r.reancoragens)
        assertEquals(1_500_000L, r.maiorDesvioUs)
    }

    @Test
    fun a_lacuna_curta_fica_abaixo_do_limiar_e_e_medida() {
        val r = RelogioDoSom(quadroUs)
        repeat(10) { r.carimbar(t0 + it * quadroUs) }
        r.carimbar(t0 + 10 * quadroUs + 30_000)
        assertEquals(0, r.reancoragens)
        assertEquals(30_000L, r.desvioUs)
        assertEquals(30_000L, r.maiorDesvioUs)
    }

    @Test
    fun o_carimbo_nunca_volta() {
        val r = RelogioDoSom(quadroUs)
        repeat(10) { r.carimbar(t0 + it * quadroUs) }
        // A fonte diz 100 ms antes do que a linha espera: conta, e não volta.
        val c = r.carimbar(t0 + 10 * quadroUs - 100_000)
        assertEquals(t0 + 10 * quadroUs, c)
        assertEquals(1, r.adiantados)
        assertEquals(0, r.reancoragens)
    }

    @Test
    fun a_deriva_de_50_ppm_por_30_min_fica_abaixo_de_40_ms() {
        // A fonte 50 ppm mais lenta que o MONOTONIC: a hora dela anda 20 001 µs por quadro. A
        // linha fica para trás 1 µs por quadro, e reancora quando passa de 40 ms — como o Mac.
        val r = RelogioDoSom(quadroUs)
        var pior = 0L
        for (n in 0 until 90_000L) {
            val hora = t0 + n * 20_001L
            val c = r.carimbar(hora)
            pior = maxOf(pior, abs(hora - c))
        }
        assertEquals(2, r.reancoragens)
        assertTrue("pior=$pior", pior <= RelogioDoSom.LIMIAR_DE_REANCORAGEM_US + 1)
    }

    /**
     * O tom sintético não tem captura: a hora dele é a vaga do quadro no acumulador do emissor. Quando
     * o laço fica mais de dez quadros para trás, o emissor religa o acumulador na hora de agora — a
     * vaga salta, e o carimbo reancora junto. Antes, o carimbo era a hora do envio, e saltava sozinho.
     */
    @Test
    fun a_vaga_do_tom_religada_reancora() {
        val r = RelogioDoSom(quadroUs)
        var vaga = t0
        repeat(100) { r.carimbar(vaga); vaga += quadroUs }
        // O laço parou 400 ms (mais de dez quadros): o acumulador religa em "agora".
        vaga += 400_000L
        assertEquals(vaga, r.carimbar(vaga))
        assertEquals(1, r.reancoragens)
    }

    /**
     * **A captura do próprio app carimba na captura, e não no envio.** O `AudioRecord` guarda até
     * 160 ms: o quadro que a leitura devolve agora foi capturado 160 ms antes. A hora dele sai do par
     * do `getTimestamp`; o carimbo antigo era a hora do envio, 160 ms depois.
     */
    @Test
    fun a_captura_com_160_ms_no_buffer_carimba_160_ms_antes_do_envio() {
        val taxa = 48_000
        val r = RelogioDoSom(quadroUs)
        val atrasoDoBuffer = 160_000L
        var lidos = 0L
        repeat(50) { k ->
            val envioUs = t0 + k * quadroUs + atrasoDoBuffer
            // O par do dispositivo, lido junto com a leitura: a última amostra capturada é "agora".
            val posicaoDoPar = lidos + 960 + atrasoDoBuffer * taxa / 1_000_000
            val nanosDoPar = envioUs * 1000L + 20_000_000L
            val hora = HoraDaCaptura.instanteUs(lidos, posicaoDoPar, nanosDoPar, taxa)
            val c = r.carimbar(hora)
            assertEquals(t0 + k * quadroUs, c)
            assertEquals(atrasoDoBuffer, envioUs - c)
            lidos += 960
        }
        assertEquals(0, r.reancoragens)
    }

    @Test
    fun a_hora_da_captura_sai_do_par_pela_taxa() {
        val nanos = 5_000_000_000L
        assertEquals(5_000_000L, HoraDaCaptura.instanteUs(48_000, 48_000, nanos, 48_000))
        assertEquals(5_020_000L, HoraDaCaptura.instanteUs(48_960, 48_000, nanos, 48_000))
        assertEquals(4_980_000L, HoraDaCaptura.instanteUs(47_040, 48_000, nanos, 48_000))
        // Uma hora de som não estoura: 172,8 milhões de amostras × 10⁹.
        assertEquals(5_000_000L + 3_600_000_000L,
            HoraDaCaptura.instanteUs(48_000 + 172_800_000L, 48_000, nanos, 48_000))
    }
}
