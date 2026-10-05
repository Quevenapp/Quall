package com.quall.android.teleprompter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** O arrasto da linha de leitura: no máximo um envio a cada 120 ms, e o último valor sempre sai. */
class LimitadorDeEnvioTest {

    @Test
    fun o_primeiro_valor_sai_na_hora_e_os_seguintes_esperam_o_intervalo() {
        val l = LimitadorDeEnvio(120)
        assertEquals(0.40, l.oferecer(0.40, 1_000)!!, 0.0)
        assertNull(l.oferecer(0.41, 1_016))
        assertNull(l.oferecer(0.42, 1_032))
        assertEquals(1_120L, l.quandoSai())
        assertNull("antes da hora não sai", l.vencer(1_119))
        // Na hora sai o mais novo, e não um do meio.
        assertEquals(0.42, l.vencer(1_120)!!, 0.0)
        assertNull(l.quandoSai())
        assertNull("nada espera: nada sai", l.vencer(1_500))
    }

    @Test
    fun um_arrasto_de_600_ms_vira_um_envio_por_intervalo_e_o_final() {
        // Um quadro a cada 16 ms, a linha descendo de 0,40 a 0,25; quem chama agenda o `vencer`.
        val l = LimitadorDeEnvio(120)
        val enviados = mutableListOf<Pair<Long, Double>>()
        var t = 0L
        var v = 0.40
        while (t <= 600) {
            l.quandoSai()?.let { q -> if (t >= q) l.vencer(t)?.let { enviados += t to it } }
            l.oferecer(v, t)?.let { enviados += t to it }
            t += 16
            v -= 0.004
        }
        val final = 0.25
        l.soltar(final, t)?.let { enviados += t to it }
        // Nunca dois envios a menos de 120 ms, fora o do soltar, que sai na hora.
        for (i in 1 until enviados.size - 1) {
            assertEquals(true, enviados[i].first - enviados[i - 1].first >= 120)
        }
        assertEquals(final, enviados.last().second, 0.0)
        assertEquals(6, enviados.size) // 0, 128, 256, 384, 512 ms e o soltar
    }

    @Test
    fun soltar_manda_o_final_na_hora_e_nada_fica_esperando() {
        val l = LimitadorDeEnvio(120)
        l.oferecer(0.40, 0)
        assertNull(l.oferecer(0.30, 50))
        assertEquals(0.31, l.soltar(0.31, 60)!!, 0.0)
        assertNull("o pendente morreu com o soltar", l.quandoSai())
        assertNull(l.vencer(1_000))
    }

    @Test
    fun soltar_no_valor_que_ja_saiu_nao_repete() {
        val l = LimitadorDeEnvio(120)
        assertEquals(0.33, l.oferecer(0.33, 0)!!, 0.0)
        assertNull(l.soltar(0.33, 500))
    }
}
