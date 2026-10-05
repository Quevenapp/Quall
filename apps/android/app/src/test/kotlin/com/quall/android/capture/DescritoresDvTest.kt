package com.quall.android.capture

import com.quall.android.capture.dv.Descritores
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Os descritores da Panasonic GS500 em modo DV (`04da:231e`), remontados do que o espião de
 * bancada leu dela no S24 em 22/09/2026 (`quall-scratch/dv-s24/corrida-2.log`): IAD, VC com
 * cabeçalho UVC 1.00 e endpoint de interrupção 0x86, VS com alt 0 sem endpoint e alt 1 isócrona em
 * 0x81 (wMaxPacketSize 0x01ec = 492), e um formato só, `VS_FORMAT_DV` SD-DV 60 Hz.
 */
class DescritoresDvTest {
    private fun b(vararg v: Int) = v.map { it.toByte() }

    private val panasonic: ByteArray = (
        b(9, 2, 193, 0, 2, 1, 0, 0x80, 50) +                       // configuração
            b(8, 0x0B, 0, 2, 0x0E, 3, 0, 0) +                      // IAD
            b(9, 4, 0, 0, 1, 0x0E, 1, 0, 0) +                      // interface 0 (VC)
            b(13, 0x24, 1, 0x00, 0x01, 51, 0, 0, 0x6C, 0xDC, 0x02, 1, 1) + // VC_HEADER 1.00
            b(7, 5, 0x86, 3, 0x40, 0, 10) +                         // endpoint de interrupção
            b(9, 4, 1, 0, 0, 0x0E, 2, 0, 0) +                      // interface 1 alt 0 (VS)
            b(14, 0x24, 1, 1, 30, 0, 0x81, 0, 0, 0, 0, 0, 0, 0) +  // VS_INPUT_HEADER, ep 0x81
            b(9, 0x24, 0x0C, 1, 0xC0, 0xD4, 0x01, 0x00, 0x80) +    // FORMAT_DV 1, 120000, SD-DV 60Hz
            b(9, 4, 1, 1, 1, 0x0E, 2, 0, 0) +                      // interface 1 alt 1
            b(7, 5, 0x81, 5, 0xEC, 0x01, 1)                         // isócrono, 492
        ).toByteArray()

    @Test
    fun aPanasonicEmDv() {
        val d = Descritores.analisar(panasonic)
        assertEquals(0x0100, d.bcdUvc)
        assertEquals(0, d.vcInterface)
        val vs = d.vss[1]
        assertNotNull(vs)
        vs!!
        assertEquals(0x81, vs.endpointDoCabecalho)
        assertEquals(1, vs.formatos.size)
        assertEquals(0x0C, vs.formatos[0].subtipo)
        assertEquals(1, vs.formatos[0].indice)
        assertEquals("SD-DV-60Hz", vs.formatos[0].detalhe)
        assertEquals(1, vs.alts.size)
        assertEquals(1, vs.alts[0].alt)
        assertEquals(1, vs.alts[0].tipo)
        assertEquals(492, vs.alts[0].psize)
    }

    @Test
    fun altaLarguraDeBandaSomaAsTransacoes() {
        // wMaxPacketSize 0x1400 = 1024 x (1 + 2) numa alternativa de alta largura de banda.
        val alt = (b(9, 4, 1, 0, 0, 0x0E, 2, 0, 0) + b(9, 4, 1, 2, 1, 0x0E, 2, 0, 0) +
            b(7, 5, 0x81, 5, 0x00, 0x14, 1)).toByteArray()
        assertEquals(3072, Descritores.analisar(alt).vss[1]!!.alts[0].psize)
    }

    @Test
    fun descritorTortoNaoEstoura() {
        val torto = byteArrayOf(9, 4, 1, 0, 0, 0x0E, 2, 0, 0, 40, 0x24, 0x0C)
        val d = Descritores.analisar(torto)
        assertEquals(0, d.vss[1]!!.formatos.size)
    }
}
