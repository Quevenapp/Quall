package com.quall.android.capture

import com.quall.android.capture.TetoDeSaida.Veredito
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Testes de [TetoDeSaida]. **Rodam na JVM** — o teto nunca barrou um quadro em campo (210 janelas
 * de `docs/bancada.md` §8.66), então este é o único lugar onde o caminho do descarte roda antes da
 * corrida que provoca a enxurrada de propósito.
 *
 * `gradle testDebugUnitTest` os roda; o portão de compilação (`assembleDebug`) não.
 */
class TetoDeSaidaTest {

    private val ms = 1_000_000L
    private val teto = 13_500_000 // o alvo da câmera frontal do S24 a 1080p60

    /** Um quadro P comum a 13,5 Mbps e 60 fps: ~28 KB. */
    private val quadroP = 28_000

    @Test
    fun em_regime_tudo_passa_e_nada_e_pedido() {
        val t = TetoDeSaida()
        var agora = 0L
        repeat(600) {
            assertEquals(Veredito.PASSA, t.decidir(teto, quadroP, it % 120 == 0, agora) { true })
            agora += 16 * ms
        }
        assertEquals(0L, t.barrados)
        assertFalse(t.tomarPedidoDeIdr())
    }

    /**
     * **A enxurrada de §8.65**, em miniatura: o codificador para e solta o atraso de uma vez — 60
     * quadros no mesmo milissegundo. O balde de 250 ms com folga de 2x passa uns ~30 e barra o
     * resto; e o que ele barra **não pode** deixar os P seguintes passarem.
     */
    @Test
    fun a_enxurrada_e_barrada_e_os_p_seguintes_sao_condenados_ate_o_idr() {
        val t = TetoDeSaida()
        t.decidir(teto, quadroP, true, 0L) { true } // IDR de abertura, balde cheio
        val agora = 100 * ms
        val vereditos = (0 until 60).map { t.decidir(teto, quadroP, false, agora) { true } }
        val primeiroBarrado = vereditos.indexOf(Veredito.BARRADO)
        assertTrue("algum quadro tem de ser barrado: $vereditos", primeiroBarrado > 0)
        assertEquals(1L, t.barrados)
        // Todo quadro depois do barrado é condenado — nenhum P passa sobre a referência perdida.
        assertTrue(vereditos.drop(primeiroBarrado + 1).all { it == Veredito.CONDENADO })
        assertTrue(t.cadeiaQuebrada)

        // Mesmo com o balde reabastecido muito depois, o P continua condenado: cadeia quebrada é
        // quebrada até o IDR, não até ter crédito.
        assertEquals(Veredito.CONDENADO, t.decidir(teto, quadroP, false, agora + 5_000 * ms) { true })

        // O IDR passa e fecha o episódio; o P seguinte volta a passar.
        assertEquals(Veredito.PASSA, t.decidir(teto, 200_000, true, agora + 5_010 * ms) { true })
        assertTrue(t.acabouDeCurar())
        assertFalse(t.cadeiaQuebrada)
        assertEquals(5_010L, t.ultimoEpisodioMs)
        assertEquals(Veredito.PASSA, t.decidir(teto, quadroP, false, agora + 5_030 * ms) { true })
        assertFalse(t.acabouDeCurar())
    }

    /**
     * **Um pedido de IDR por episódio**, e não um por quadro condenado. O codificador lê
     * `querIdr()` a cada ≤10 ms; um `true` a cada volta viraria um `REQUEST_SYNC_FRAME` atrás do
     * outro — a rajada que a revisão adversarial de 10/09/2026 apontou.
     */
    @Test
    fun o_episodio_pede_um_idr_e_so_repede_depois_do_prazo() {
        val t = TetoDeSaida(repedirNs = 500 * ms)
        t.decidir(teto, quadroP, true, 0L) { true }
        var agora = 10 * ms
        while (t.decidir(teto, quadroP, false, agora) { true } != Veredito.BARRADO) Unit
        assertTrue(t.tomarPedidoDeIdr())
        assertFalse("o pedido é consumido", t.tomarPedidoDeIdr())

        // 400 ms de quadros condenados a 60 fps: nenhum pedido novo.
        repeat(24) {
            agora += 16 * ms
            assertEquals(Veredito.CONDENADO, t.decidir(teto, quadroP, false, agora) { true })
            assertFalse("pediu de novo antes do prazo, em +${agora / ms} ms", t.tomarPedidoDeIdr())
        }
        // Passou do prazo sem IDR: um pedido novo, e só um.
        agora += 200 * ms
        t.decidir(teto, quadroP, false, agora) { true }
        assertTrue(t.tomarPedidoDeIdr())
        agora += 16 * ms
        t.decidir(teto, quadroP, false, agora) { true }
        assertFalse(t.tomarPedidoDeIdr())
    }

    /** Um quadro que ninguém referencia cai sozinho: sem episódio, sem IDR, cadeia sã. */
    @Test
    fun o_quadro_nao_referencia_que_nao_cabe_cai_sem_quebrar_nada() {
        val t = TetoDeSaida()
        t.decidir(teto, quadroP, true, 0L) { true }
        val agora = 100 * ms
        val vereditos = (0 until 60).map { t.decidir(teto, quadroP, false, agora) { false } }
        assertTrue(vereditos.contains(Veredito.DESCARTAVEL))
        assertFalse(vereditos.contains(Veredito.BARRADO))
        assertFalse(t.cadeiaQuebrada)
        assertFalse(t.tomarPedidoDeIdr())
    }

    /** O IDR passa sempre, mesmo sem crédito nenhum — barrá-lo seria barrar a cura. */
    @Test
    fun o_idr_passa_sempre_e_nao_deixa_credito_negativo() {
        val t = TetoDeSaida()
        t.decidir(teto, quadroP, true, 0L) { true }
        val enorme = 5_000_000 // 40 Mbit: muito além do balde
        assertEquals(Veredito.PASSA, t.decidir(teto, enorme, true, 1 * ms) { true })
        // Crédito zerado, e não negativo: 16 ms depois reabasteceu ~430 kbit, e um P de 28 KB
        // (224 kbit) cabe.
        assertEquals(Veredito.PASSA, t.decidir(teto, quadroP, false, 17 * ms) { true })
    }

    /** Teto desligado deixa tudo passar — mas não cura uma cadeia que já quebrou. */
    @Test
    fun teto_zero_desliga_mas_nao_fecha_episodio_aberto() {
        val t = TetoDeSaida()
        assertEquals(Veredito.PASSA, t.decidir(0, 10_000_000, false, 0L) { true })
        t.decidir(teto, quadroP, true, 0L) { true }
        while (t.decidir(teto, quadroP, false, 1 * ms) { true } != Veredito.BARRADO) Unit
        assertEquals(Veredito.CONDENADO, t.decidir(0, quadroP, false, 2 * ms) { true })
        assertEquals(Veredito.PASSA, t.decidir(0, quadroP, true, 3 * ms) { true })
        assertEquals(Veredito.PASSA, t.decidir(0, quadroP, false, 4 * ms) { true })
    }
}
