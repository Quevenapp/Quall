package com.quall.android.receive

import org.junit.Assert.*
import org.junit.Test

class GravacaoRecebidaTest {
    @Test fun comecaNoIdrEConservaOsBuracosDaRede() {
        val t = TempoDaGravacaoRecebida()
        assertNull(t.video(100_000, false))
        assertEquals(0L, t.video(900_000, true))
        assertEquals(33_333L, t.video(933_333, false))
        assertEquals(200_000L, t.video(1_100_000, true))
        assertNull(t.video(1_100_000, false))
        assertNull(t.video(933_333, false))
    }
    @Test fun somUsaRelogioComumNaoChegadaENaoContaSlotRepetido() {
        val t = TempoDaGravacaoRecebida()
        t.video(2_000_000, true)
        // Both tracks refer to capture 3 s; their independent bases differ by 900 ms.
        assertEquals(0L, t.som(1_100_000, 100, 1_900_000, 1_000_000))
        assertNull(t.som(1_100_000, 100, 1_900_000, 1_000_000))
        assertEquals(60_000L, t.som(1_160_000, 103, 1_900_000, 1_000_000))
        assertNull(t.som(1_140_000, 102, 1_900_000, 1_000_000))
    }
    @Test fun somAnteriorAoVideoMantemCarimboNegativoParaSerRecortado() {
        val t = TempoDaGravacaoRecebida()
        t.video(100_000, true)
        assertEquals(-20_000L, t.som(80_000, 1, 0, 0))
    }
    @Test fun telaEstaticaVaiAtePararSemContarTempoDeFechamento() {
        val t = TempoDaGravacaoRecebida()
        assertEquals(0L, t.fimUs(20_000_000, 1_000_000))
        t.video(900_000, true)
        assertEquals(15_500_000L, t.fimUs(16_500_000, 1_000_000))
        // Two seconds spent closing AAC/disk do not become extra recorded seconds.
        assertEquals(15_500_000L, t.fimUs(18_500_000, 1_000_000, 16_500_000))
        t.video(933_333, false)
        assertEquals(66_666L, t.fimUs(20_000_000, 20_000_000, 16_500_000))
    }
    @Test fun muxerRecebePrefixosDeQuatroBytesSemCortarOPayload() {
        val a = byteArrayOf(0x68, 0xce.toByte(), 0x0f, 0xc8.toByte())
        val b = byteArrayOf(0x06, 0x05, 0x02, 0x80.toByte())
        val c = byteArrayOf(0x65, 0x88.toByte(), 0x84.toByte(), 0xe0.toByte())
        val curto = byteArrayOf(0, 0, 1)
        val longo = byteArrayOf(0, 0, 0, 1)
        assertArrayEquals(longo + a + longo + b + longo + c,
            ContinuidadeH264Recebida.paraMediaMuxer(longo + a + curto + b + curto + c))
    }
    @Test fun nenhumaReferenciaQuebradaVaiAoArquivoAntesDeNovoIdr() {
        val g = ContinuidadeH264Recebida()
        assertFalse(g.aceitar(fatia(1)))
        assertTrue(g.aceitar(parametros() + fatia(0, true)))
        assertTrue(g.aceitar(fatia(1)))
        assertFalse(g.aceitar(fatia(3))) // missing frame_num 2
        assertFalse(g.aceitar(fatia(4)))
        assertTrue(g.aceitar(parametros() + fatia(0, true)))
        assertTrue(g.aceitar(fatia(1)))
    }
    @Test fun rupturaDaFilaENumeroQueDaAVolta() {
        val g = ContinuidadeH264Recebida()
        assertTrue(g.aceitar(parametros() + fatia(0, true)))
        for (n in 1..15) assertTrue("frame $n", g.aceitar(fatia(n)))
        assertTrue(g.aceitar(fatia(0)))
        g.ruptura()
        assertFalse(g.aceitar(fatia(1)))
        assertTrue(g.aceitar(parametros() + fatia(0, true)))
    }
    @Test fun bitstreamCortadoNaoChegaAoMuxer() {
        val g = ContinuidadeH264Recebida()
        assertFalse(g.aceitar(byteArrayOf(0, 0, 1, 0x65)))
        assertTrue(g.aceitar(parametros() + fatia(0, true)))
    }
    private fun parametros(): ByteArray {
        val sps = Bits().u(66, 8).u(0, 8).u(31, 8).ue(0).ue(0).bytes()
        val pps = Bits().ue(0).ue(0).bytes()
        return nal(0x67, sps) + nal(0x68, pps)
    }
    private fun fatia(numero: Int, idr: Boolean = false): ByteArray =
        nal(if (idr) 0x65 else 0x41, Bits().ue(0).ue(if (idr) 2 else 0).ue(0).u(numero, 4).bytes())
    private fun nal(cabecalho: Int, bytes: ByteArray) = byteArrayOf(0, 0, 0, 1, cabecalho.toByte()) + bytes
    private class Bits {
        private val b = StringBuilder()
        fun u(v: Int, n: Int): Bits { for (i in n - 1 downTo 0) b.append((v ushr i) and 1); return this }
        fun ue(v: Int): Bits { val s = (v + 1).toString(2); repeat(s.length - 1) { b.append('0') }; b.append(s); return this }
        fun bytes(): ByteArray { b.append('1'); while (b.length % 8 != 0) b.append('0'); return b.toString().chunked(8).map { it.toInt(2).toByte() }.toByteArray() }
    }
}
