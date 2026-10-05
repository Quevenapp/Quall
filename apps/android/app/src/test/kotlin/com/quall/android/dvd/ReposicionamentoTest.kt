package com.quall.android.dvd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A T2 sem aparelho: o pulo pela lista de células, o NAV do VOBU, e a leitura de manutenção. */
class ReposicionamentoTest {
    // Três células: 60 s em 3000 setores, 30 s em 1500 (com um buraco de setores antes), 90 s em 9000.
    private val trechos = listOf(
        TrechoDoTitulo(1000, 3999, 0),
        TrechoDoTitulo(5000, 6499, 60 * 90_000L),
        TrechoDoTitulo(7000, 15999, 90 * 90_000L),
    )
    private val duracao = 180 * 90_000L

    @Test
    fun `o tempo vira a celula e o setor pela fracao da celula`() {
        assertEquals(listOf(60 * 90_000L, 30 * 90_000L, 90 * 90_000L), Reposicionamento.duracoes(trechos, duracao))
        val a = Reposicionamento.alvo(trechos, duracao, 30 * 90_000L)
        assertEquals(0, a.celula)
        assertEquals(2500L, a.lba)  // metade da primeira
        val b = Reposicionamento.alvo(trechos, duracao, 75 * 90_000L)
        assertEquals(1, b.celula)
        assertEquals(5750L, b.lba)
        // A fronteira é da célula seguinte.
        assertEquals(2, Reposicionamento.alvo(trechos, duracao, 90 * 90_000L).celula)
        assertEquals(7000L, Reposicionamento.alvo(trechos, duracao, 90 * 90_000L).lba)
    }

    @Test
    fun `pular para antes do comeco ou alem do fim fica dentro do titulo`() {
        val a = Reposicionamento.alvo(trechos, duracao, -30 * 90_000L)
        assertEquals(0, a.celula)
        assertEquals(1000L, a.lba)
        assertEquals(0L, a.tempo90k)
        val b = Reposicionamento.alvo(trechos, duracao, 500 * 90_000L)
        assertEquals(2, b.celula)
        assertEquals(179 * 90_000L, b.tempo90k)  // o último segundo
        assertEquals(15900L, b.lba)
    }

    /** Um NAV pack: o pack MPEG-2, o system header, o PCI (0xBF, substream 0) e o DSI. */
    private fun nav(sPtm: Long, ePtm: Long): ByteArray {
        val s = ByteArray(2048)
        fun put32(o: Int, v: Long) { s[o] = (v shr 24).toByte(); s[o + 1] = (v shr 16).toByte(); s[o + 2] = (v shr 8).toByte(); s[o + 3] = v.toByte() }
        put32(0, 0x1BA); s[4] = 0x44  // '01' do MPEG-2
        s[13] = 0xF8.toByte()          // sem enchimento
        put32(14, 0x1BB); s[18] = 0; s[19] = 18        // system header de 18 bytes
        put32(38, 0x1BF); s[42] = 0x03; s[43] = 0xD4.toByte()  // PCI de 980 bytes
        s[44] = 0x00                                    // substream do PCI
        put32(44 + 0x0D, sPtm); put32(44 + 0x11, ePtm)
        val dsi = 38 + 6 + 980
        put32(dsi, 0x1BF); s[dsi + 4] = 0x03; s[dsi + 5] = 0xFA.toByte(); s[dsi + 6] = 0x01
        return s
    }

    @Test
    fun `o NAV do setor e o tempo do VOBU na celula`() {
        assertEquals(123_456L, Reposicionamento.navDoSetor(nav(123_456, 123_456 + 45_045)))
        assertNull(Reposicionamento.navDoSetor(nav(0, 0)))  // o NAV zerado não vale
        assertNull(Reposicionamento.navDoSetor(ByteArray(2048)))
        // Num bloco de vários setores, pelo deslocamento.
        val bloco = ByteArray(4096)
        System.arraycopy(nav(900, 1000), 0, bloco, 2048, 2048)
        assertNull(Reposicionamento.navDoSetor(bloco, 0))
        assertEquals(900L, Reposicionamento.navDoSetor(bloco, 2048))
        // O VOBU 20 s depois do primeiro da célula que começa aos 60 s do título.
        assertEquals(80 * 90_000L, Reposicionamento.tempoDoVobu(60 * 90_000L, 30 * 90_000L, 1_000_000, 1_000_000 + 20 * 90_000L, 77))
        // A volta do relógio de 33 bits.
        val quase = (1L shl 33) - 90_000
        assertEquals(60 * 90_000L + 180_000, Reposicionamento.tempoDoVobu(60 * 90_000L, 30 * 90_000L, quase, 90_000, 77))
        // Fora da célula (outra base) ou sem o NAV da célula: a estimativa.
        assertEquals(77L, Reposicionamento.tempoDoVobu(0, 30 * 90_000L, 1_000_000, 500_000, 77))
        assertEquals(77L, Reposicionamento.tempoDoVobu(0, 30 * 90_000L, null, 500_000, 77))
    }

    @Test
    fun `os trechos a partir do VOBU comecam no zero da saida`() {
        val t = Reposicionamento.trechosDesde(trechos, 1, 5800, 76 * 90_000L)
        assertEquals(TrechoDoTitulo(5800, 6499, 0), t[0])
        assertEquals(TrechoDoTitulo(7000, 15999, 14 * 90_000L), t[1])
        assertEquals(2, t.size)
    }

    @Test
    fun `o carimbo da gravacao anda pelo conteudo e costura o pulo sem salto`() {
        // O primeiro quadro é o zero.
        assertEquals(0L to false, Reposicionamento.carimboDaGravacao(-1, -1, 0, 3003, 0, 450_000))
        // O seguinte da mesma geração: a distância de conteúdo (a pausa no meio não conta).
        assertEquals(3003L to true, Reposicionamento.carimboDaGravacao(0, 0, 450_000, 3003, 0, 453_003))
        // O pulldown: 4504.
        assertEquals(7507L to true, Reposicionamento.carimboDaGravacao(3003, 0, 453_003, 3003, 0, 457_507))
        // O pulo (outra geração, conteúdo 30 s à frente): um quadro depois, sem os 30 s.
        assertEquals(10_510L to false, Reposicionamento.carimboDaGravacao(7507, 0, 457_507, 3003, 1, 3_150_000))
        // Um salto de mais de 1 s na mesma geração, ou o conteúdo que volta: também um quadro.
        assertEquals(10_510L to false, Reposicionamento.carimboDaGravacao(7507, 0, 457_507, 3003, 0, 700_000))
        assertEquals(10_510L to false, Reposicionamento.carimboDaGravacao(7507, 0, 457_507, 3003, 0, 400_000))
    }

    @Test
    fun `a manutencao le perto, a frente, e um setor diferente a cada vez`() {
        val a = Reposicionamento.setorDeManutencao(trechos, 8000, 0)
        val b = Reposicionamento.setorDeManutencao(trechos, 8000, 1)
        assertEquals(9024L, a)
        assertEquals(9280L, b)
        // No fim da célula: atrás.
        assertEquals(15900L - 1024, Reposicionamento.setorDeManutencao(trechos, 15900, 0))
        // Fora de qualquer célula (entre duas): a mais perto.
        val c = Reposicionamento.setorDeManutencao(trechos, 4500, 0)
        assertEquals(true, c in 1000..3999 || c in 5000..6499)
        // Célula pequena demais para o passo: dentro dela.
        val pequena = listOf(TrechoDoTitulo(100, 199, 0))
        assertEquals(true, Reposicionamento.setorDeManutencao(pequena, 150, 7) in 100..199)
    }
}
