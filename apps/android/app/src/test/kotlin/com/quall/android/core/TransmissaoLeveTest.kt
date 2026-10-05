package com.quall.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A conta do aparelho fraco (`TransmissaoLeve`), com os números que a bancada leu em 28/09. */
class TransmissaoLeveTest {

    @Test
    fun oA10sQueNaoDeclara1080pEstimaAbaixoDe30() {
        // O sistema estima pelo 720p declarado (29–102 fps): 1080p tem 2,25 vezes os pixels.
        assertTrue(TransmissaoLeve.fraco(piso = 29.0 / 2.25, recusaOTamanho = false))
    }

    @Test
    fun oA07EOTabletNaoSaoFracos() {
        assertFalse(TransmissaoLeve.fraco(piso = 36.0, recusaOTamanho = false))
        assertFalse(TransmissaoLeve.fraco(piso = 30.0, recusaOTamanho = false))
    }

    @Test
    fun semDeclaracaoARegraNaoAge() {
        assertFalse(TransmissaoLeve.fraco(piso = null, recusaOTamanho = false))
    }

    @Test
    fun oCodificadorQueRecusa1080pEFraco() {
        assertTrue(TransmissaoLeve.fraco(piso = null, recusaOTamanho = true))
    }

    @Test
    fun oTetoSoDesceNuncaSobe() {
        assertEquals(Resolucao.P720.maxFs, TransmissaoLeve.maxFs(Resolucao.P1080, fraco = true))
        assertEquals(Resolucao.P720.maxFs, TransmissaoLeve.maxFs(Resolucao.P2160, fraco = true))
        assertEquals(Resolucao.P720.maxFs, TransmissaoLeve.maxFs(Resolucao.P720, fraco = true))
        assertEquals(Resolucao.P1080.maxFs, TransmissaoLeve.maxFs(Resolucao.P1080, fraco = false))
    }
}
