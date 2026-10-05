package com.quall.android.capture

import com.quall.android.capture.dv.FotoDaPlaca
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A foto da placa: os planos decodificados em NV21, com a faixa expandida (§11, item 6). */
class FotoDaPlacaTest {
    private fun u8(b: Byte) = b.toInt() and 0xFF

    /** 4:2:2 (a placa): 4x2 de luma, croma 2x2; o NV21 tem o luma e uma linha de croma 2x1 (V,U). */
    @Test
    fun o_422_vira_nv21_pela_media_das_duas_linhas() {
        val y = ByteArray(8) { (16 + it * 10).toByte() }
        // U: linha 0 = 100, 110; linha 1 = 120, 130. V: 140, 150; 160, 170.
        val u = byteArrayOf(100, 110, 120, 130.toByte())
        val v = byteArrayOf(140.toByte(), 150.toByte(), 160.toByte(), 170.toByte())
        val n = FotoDaPlaca.nv21(y, u, v, 4, 2, 2, 2, expandir = false)
        assertEquals(4, n.largura)
        assertEquals(2, n.altura)
        assertEquals(12, n.dados.size)
        for (i in 0 until 8) assertEquals(u8(y[i]), u8(n.dados[i]))
        // (0,0): V = média(140,160)=150, U = média(100,120)=110; (1,0): V = 160, U = 120
        assertEquals(listOf(150, 110, 160, 120), (8 until 12).map { u8(n.dados[it]) })
    }

    @Test
    fun o_420_passa_o_croma_como_esta() {
        val y = ByteArray(16) { 50 }
        val u = byteArrayOf(10, 20, 30, 40)
        val v = byteArrayOf(50, 60, 70, 80)
        val n = FotoDaPlaca.nv21(y, u, v, 4, 4, 2, 2, expandir = false)
        assertEquals(listOf(50, 10, 60, 20, 70, 30, 80, 40), (16 until 24).map { u8(n.dados[it]) })
    }

    @Test
    fun o_444_e_a_media_de_quatro() {
        val y = ByteArray(4) { 0 }
        val u = byteArrayOf(10, 20, 30, 40)
        val v = byteArrayOf(0, 0, 0, 4)
        val n = FotoDaPlaca.nv21(y, u, v, 2, 2, 2, 2, expandir = false)
        assertEquals(listOf(1, 25), (4 until 6).map { u8(n.dados[it]) })
    }

    /** A placa manda faixa limitada (§8.1); o JPEG é faixa cheia: 16 → 0, 235 → 255, 128 fica. */
    @Test
    fun a_faixa_limitada_vira_cheia() {
        val y = byteArrayOf(16, 235.toByte(), 0, 255.toByte())
        val u = byteArrayOf(128.toByte())
        val v = byteArrayOf(240.toByte())
        val n = FotoDaPlaca.nv21(y, u, v, 2, 2, 1, 1)
        assertEquals(listOf(0, 255, 0, 255), (0 until 4).map { u8(n.dados[it]) })
        assertEquals(255, u8(n.dados[4]))  // V 240 -> 255
        assertEquals(128, u8(n.dados[5]))  // U 128 fica
        // o meio da escala sobe um pouco (125 -> ~127)
        val m = FotoDaPlaca.nv21(ByteArray(4) { 125 }, u, u, 2, 2, 1, 1)
        assertTrue(u8(m.dados[0]) in 126..128)
    }

    @Test
    fun o_quadro_impar_perde_a_ultima_coluna_e_linha() {
        val n = FotoDaPlaca.nv21(ByteArray(15) { 7 }, ByteArray(6) { 1 }, ByteArray(6) { 2 }, 5, 3, 3, 2, expandir = false)
        assertEquals(4, n.largura)
        assertEquals(2, n.altura)
        assertEquals(12, n.dados.size)
    }

    @Test
    fun o_nome_do_arquivo() {
        val d = java.util.GregorianCalendar(2026, 8, 28, 21, 5, 9).time
        assertEquals("Quall-Placa-20260928-210509.jpg", FotoDaPlaca.nome(d))
        assertEquals("Quall-DV-20260928-210509.jpg", FotoDaPlaca.nome(d, prefixo = "Quall-DV-"))
    }

    /** §13: a filmadora DV (720x480) sai no aspecto dela, com pixel quadrado; a placa não muda. */
    @Test
    fun a_largura_quadrada() {
        assertEquals(640, FotoDaPlaca.larguraQuadrada(480, 4, 3))
        assertEquals(854, FotoDaPlaca.larguraQuadrada(480, 16, 9))  // 853,3 → par
        assertEquals(0, FotoDaPlaca.larguraQuadrada(480, 0, 3))
    }

    /** O 4:1:1 da DV (croma 180x480) vira NV21 com cada amostra de croma cobrindo duas de saída. */
    @Test
    fun o_411_da_dv_vira_nv21() {
        // 8x2 de luma, croma 2x2 (4:1:1): U linha 0 = 10, 20; linha 1 = 30, 40.
        val n = FotoDaPlaca.nv21(ByteArray(16) { 50 }, byteArrayOf(10, 20, 30, 40), byteArrayOf(0, 0, 0, 0), 8, 2, 2, 2, expandir = false)
        assertEquals(8, n.largura)
        // 4 amostras 4:2:0 numa linha: as duas primeiras da coluna 0 (média 20), as outras da 1 (30).
        assertEquals(listOf(20, 20, 30, 30), (0 until 4).map { u8(n.dados[16 + it * 2 + 1]) })
    }

    @Test
    fun redimensionar_na_mesma_largura_devolve_o_mesmo() {
        val n = FotoDaPlaca.nv21(ByteArray(16) { it.toByte() }, ByteArray(4) { 9 }, ByteArray(4) { 9 }, 4, 4, 2, 2, expandir = false)
        assertTrue(FotoDaPlaca.redimensionar(n, 4) === n)
    }

    @Test
    fun redimensionar_estica_o_luma_e_o_croma_em_linha() {
        // Luma 4x2 em rampa 0, 100, 200, 250; croma (1 linha, 2 pares V,U): V 0/200, U 100/100.
        val y = byteArrayOf(0, 100, 200.toByte(), 250.toByte(), 0, 100, 200.toByte(), 250.toByte())
        val dados = y + byteArrayOf(0, 100, 200.toByte(), 100)
        val n = FotoDaPlaca.Nv21(dados, 4, 2)
        val r = FotoDaPlaca.redimensionar(n, 8)
        assertEquals(8, r.largura)
        assertEquals(2, r.altura)
        assertEquals(8 * 2 + 8, r.dados.size)
        val linha = (0 until 8).map { u8(r.dados[it]) }
        // As pontas ficam, e o meio é monótono (sem estouro nem volta).
        assertEquals(0, linha.first())
        assertEquals(250, linha.last())
        assertTrue(linha.zipWithNext().all { (a, b) -> b >= a })
        assertEquals(linha, (8 until 16).map { u8(r.dados[it]) })
        // O croma: 4 pares; V vai de 0 a 200, U fica 100.
        val v = (0 until 4).map { u8(r.dados[16 + it * 2]) }
        val u = (0 until 4).map { u8(r.dados[16 + it * 2 + 1]) }
        assertEquals(0, v.first())
        assertEquals(200, v.last())
        assertEquals(listOf(100, 100, 100, 100), u)
    }

    @Test
    fun redimensionar_encolhe_uma_cor_lisa_sem_mudar_a_cor() {
        val n = FotoDaPlaca.nv21(ByteArray(720 * 4) { 80 }, ByteArray(180 * 4) { 60 }, ByteArray(180 * 4) { 170.toByte() }, 720, 4, 180, 4, expandir = false)
        val r = FotoDaPlaca.redimensionar(n, 640)
        assertEquals(640, r.largura)
        assertTrue((0 until 640 * 4).all { u8(r.dados[it]) == 80 })
        assertTrue((0 until 320 * 2).all { u8(r.dados[640 * 4 + it * 2]) == 170 && u8(r.dados[640 * 4 + it * 2 + 1]) == 60 })
    }
}
