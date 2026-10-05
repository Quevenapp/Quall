package com.quall.android.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Testes de [RitmoDoEmissor] (a crítica da disciplina da deriva, M6). **Rodam na JVM, sem
 * aparelho**: a captura do próprio app só roda em teste, pela regra do som só sintético.
 *
 * O dispositivo de mentira produz um quadro de 20 ms a cada `20 ms / (1 + ppm)` do host, e a
 * leitura bloqueia até o próximo estar pronto — o `AudioRecord.read`. A fila é o que o dispositivo
 * produziu e o laço ainda não leu.
 */
class RitmoDoEmissorTest {

    private val quadroUs = 20_000L

    /** Devolve a maior fila, em quadros, na última hora de uma corrida de [minutos]. */
    private fun maiorFila(ppm: Double, minutos: Int, ritmoDeHoje: Boolean): Double {
        val periodoUs = quadroUs / (1.0 + ppm * 1e-6)
        // O controle é a regra de antes: dormir até a vaga do host, qualquer que seja a fonte.
        val ritmo = RitmoDoEmissor(quadroUs, ritmadaPeloDispositivo = !ritmoDeHoje, inicioUs = 0L)
        var agora = 0.0
        var lidos = 0L
        var pior = 0.0
        val fim = minutos * 60_000_000.0
        while (agora < fim) {
            // A leitura bloqueia até o quadro `lidos` estar pronto.
            val pronto = (lidos + 1) * periodoUs
            if (agora < pronto) agora = pronto
            lidos++
            // O que o dispositivo já produziu e ninguém leu.
            val fila = agora / periodoUs - lidos
            if (agora > fim - 3_600_000_000.0) pior = maxOf(pior, fila)
            agora += ritmo.depoisDoQuadro(agora.toLong()).toDouble()
        }
        return pior
    }

    @Test
    fun com_o_dispositivo_50_ppm_mais_rapido_a_fila_do_audiorecord_nao_cresce() {
        // O controle: dormir até a vaga do host deixa a fila crescer 2,4 amostras por segundo; em
        // 60 min, 8 quadros além do que está sendo lido (medido: 8,0), os 160 ms do buffer inteiro
        // do `AudioRecord`.
        val antes = maiorFila(50.0, 60, ritmoDeHoje = true)
        assertTrue("o controle tinha de crescer: $antes quadros", antes > 7.5)
        // O conserto: a leitura dá o ritmo, e a fila fica abaixo de um quadro.
        val depois = maiorFila(50.0, 60, ritmoDeHoje = false)
        assertTrue("fila de $depois quadros", depois < 1.0)
    }

    @Test
    fun a_300_ppm_o_controle_transborda_em_minutos_e_o_conserto_nao() {
        val antes = maiorFila(300.0, 10, ritmoDeHoje = true)
        assertTrue("o controle: $antes quadros", antes > 7.5) // 160 ms em 10 min (medido: 8,0)
        val depois = maiorFila(300.0, 10, ritmoDeHoje = false)
        assertTrue("fila de $depois quadros", depois < 1.0)
    }

    @Test
    fun o_tom_continua_no_acumulador() {
        val r = RitmoDoEmissor(quadroUs, ritmadaPeloDispositivo = false, inicioUs = 1_000_000L)
        // O quadro saiu 3 ms depois da vaga: dorme até a próxima.
        assertEquals(17_000L, r.depoisDoQuadro(1_003_000L))
        assertEquals(1_020_000L, r.vagaUs)
        // Atrasou mais de dez quadros: religa em "agora", sem dormir.
        assertEquals(0L, r.depoisDoQuadro(1_300_000L))
        assertEquals(1_300_000L, r.vagaUs)
        assertEquals(1, r.religadas)
    }

    @Test
    fun a_fonte_que_bloqueia_nunca_dorme() {
        val r = RitmoDoEmissor(quadroUs, ritmadaPeloDispositivo = true, inicioUs = 0L)
        assertEquals(0L, r.depoisDoQuadro(5_000L))
        assertEquals(5_000L, r.vagaUs)
        assertEquals(0L, r.depoisDoQuadro(24_000L))
        assertEquals(0, r.religadas)
    }
}
