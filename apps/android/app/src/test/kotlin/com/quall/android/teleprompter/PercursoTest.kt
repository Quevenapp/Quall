package com.quall.android.teleprompter

import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.core.TextosDeTeste.Companion.EN
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A conta da rolagem. O que ela promete: **velocidade constante no tempo** (e não por quadro), a
 * posição sempre em 0..1, e o topo do texto no lugar certo para a linha de leitura.
 */
class PercursoTest {

    /** 1 linha/s, linha de 60 px, percurso de 6000 px: 100 s do começo ao fim. */
    @Test
    fun anda_uma_linha_por_segundo() {
        val p = Percurso.avancar(0.0, 1.0, 60.0, 6000.0, 1.0)
        assertEquals(0.01, p, 1e-12)
    }

    /**
     * O que faz a leitura não desacelerar quando o aparelho soluça: dez quadros de 16 ms andam o
     * mesmo que um quadro atrasado de 160 ms.
     */
    @Test
    fun dez_quadros_andam_o_mesmo_que_um_quadro_atrasado() {
        var aos_poucos = 0.2
        repeat(10) { aos_poucos = Percurso.avancar(aos_poucos, 2.5, 72.0, 30_000.0, 0.016) }
        val de_uma_vez = Percurso.avancar(0.2, 2.5, 72.0, 30_000.0, 0.160)
        assertEquals(de_uma_vez, aos_poucos, 1e-12)
    }

    @Test
    fun nunca_passa_do_fim_nem_volta_do_comeco() {
        assertEquals(1.0, Percurso.avancar(0.999, 20.0, 100.0, 1000.0, 0.25), 0.0)
        assertEquals(0.0, Percurso.avancar(-0.5, 0.0, 100.0, 1000.0, 0.25), 0.0)
        assertEquals(1.0, Percurso.avancar(3.0, 1.0, 100.0, 1000.0, 0.0), 0.0)
    }

    /** Texto de uma linha só: percurso zero, a posição não anda (e não divide por zero). */
    @Test
    fun percurso_zero_nao_anda() {
        assertEquals(0.3, Percurso.avancar(0.3, 5.0, 60.0, 0.0, 1.0), 0.0)
        assertNull(Percurso.segundosAteOFim(0.3, 5.0, 60.0, 0.0))
    }

    /** A volta do segundo plano não vira salto: o dt é limitado a 250 ms. */
    @Test
    fun o_dt_e_limitado() {
        assertEquals(0.25, Percurso.dtLimitado(5.0), 0.0)
        assertEquals(0.016, Percurso.dtLimitado(0.016), 0.0)
        assertEquals(0.0, Percurso.dtLimitado(-1.0), 0.0)
        assertEquals(0.0, Percurso.dtLimitado(Double.NaN), 0.0)
    }

    /** Em 0 a primeira linha está na linha de leitura; em 1, a última; arrastar é o inverso. */
    @Test
    fun o_topo_poe_a_posicao_na_linha_de_leitura_e_volta() {
        val leitura = 300.0
        val centroDaPrimeira = 30.0
        val percurso = 5_940.0
        // Posição 0: o centro da primeira linha (topo + 30) cai em 300.
        assertEquals(270.0, Percurso.topoDoTexto(leitura, centroDaPrimeira, percurso, 0.0), 1e-9)
        // Posição 1: o centro da última (topo + 30 + 5940) cai em 300.
        assertEquals(300.0 - 30.0 - 5940.0, Percurso.topoDoTexto(leitura, centroDaPrimeira, percurso, 1.0), 1e-9)
        for (p in listOf(0.0, 0.1234, 0.5, 0.999, 1.0)) {
            val topo = Percurso.topoDoTexto(leitura, centroDaPrimeira, percurso, p)
            assertEquals(p, Percurso.posicaoDoTopo(topo, leitura, centroDaPrimeira, percurso), 1e-12)
        }
    }

    @Test
    fun faltam_os_segundos_da_velocidade_de_agora() {
        assertEquals(50.0, Percurso.segundosAteOFim(0.5, 1.0, 60.0, 6000.0)!!, 1e-9)
    }

    /** "Segurar para rolar" para trás: a mesma velocidade, e para no começo sem passar dele. */
    @Test
    fun recuar_anda_para_tras_na_mesma_velocidade_e_para_no_comeco() {
        // 1 linha/s, linha de 50 px, percurso de 5 000 px: 1 s anda 0,01 — para a frente e para trás.
        assertEquals(0.51, Percurso.avancar(0.5, 1.0, 50.0, 5_000.0, 1.0), 1e-12)
        assertEquals(0.49, Percurso.recuar(0.5, 1.0, 50.0, 5_000.0, 1.0), 1e-12)
        assertEquals(0.0, Percurso.recuar(0.005, 1.0, 50.0, 5_000.0, 1.0), 0.0)
        assertEquals(0.0, Percurso.recuar(0.0, 1.0, 50.0, 5_000.0, 1.0), 0.0)
        assertEquals(0.3, Percurso.recuar(0.3, 1.0, 50.0, 0.0, 1.0), 0.0) // percurso zero não anda
    }

    /** Os passos dos botões param na borda da faixa do contrato em vez de pedir o impossível. */
    @Test
    fun os_passos_param_na_borda_da_faixa() {
        assertEquals(1.1, Ajustes.velocidade(1.0, +1), 1e-12)
        assertEquals(0.3, Ajustes.velocidade(0.2, +1), 1e-12)
        assertEquals(0.05, Ajustes.velocidade(0.1, -1), 1e-12)
        assertEquals(0.05, Ajustes.velocidade(0.05, -1), 1e-12)
        assertEquals(20.0, Ajustes.velocidade(20.0, +1), 1e-12)
        assertEquals(52.0, Ajustes.fonte(48.0, +1), 1e-12)
        assertEquals(8.0, Ajustes.fonte(10.0, -1), 1e-12)
        assertEquals(400.0, Ajustes.fonte(398.0, +1), 1e-12)
        assertEquals(0.12, Ajustes.margem(0.1, +1), 1e-12)
        assertEquals(0.45, Ajustes.margem(0.44, +1), 1e-12)
        assertEquals(0.0, Ajustes.margem(0.01, -1), 1e-12)
        // A linha anda de 1 % (o ajuste fino da altura da lente; o grosso é arrastar as setas).
        assertEquals(0.29, Ajustes.linha(0.3, -1), 1e-12)
        assertEquals(0.99, Ajustes.linha(0.98, +1), 1e-12)
        assertEquals(1.0, Ajustes.linha(0.995, +1), 1e-12)
        assertEquals(0.0, Ajustes.linha(0.004, -1), 1e-12)
    }

    @Test
    fun o_tamanho_do_roteiro_contra_o_teto() {
        assertEquals("97,7 KB de 128 KB", Ajustes.tamanhoDoRoteiro(100_000, 131_072, PT))
        assertEquals("0,0 KB de 128 KB", Ajustes.tamanhoDoRoteiro(0, 131_072, PT))
        // Em inglês, o ponto decimal; um teto que não é inteiro em KB sai com a casa.
        assertEquals("97.7 KB of 128 KB", Ajustes.tamanhoDoRoteiro(100_000, 131_072, EN))
        assertEquals("1,0 KB de 1,5 KB", Ajustes.tamanhoDoRoteiro(1_024, 1_536, PT))
    }
}
