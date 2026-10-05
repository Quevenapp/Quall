package com.quall.android.dvd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A T1 sem aparelho: o relógio de saída da transmissão e o som na hora dele. */
class RitmoDoDiscoTest {
    @Test
    fun `o quadro sai quando o carimbo chega no relogio ancorado no primeiro`() {
        val r = RelogioDoDisco()
        assertFalse(r.ancorado)
        assertEquals(0L, r.instanteUs(3003))
        r.ancorar(geracao = 0, t90k = 1_000, agoraUs = 5_000_000)
        assertEquals(5_000_000L, r.instanteUs(1_000))
        // Um quadro NTSC depois (3003 a 90 kHz = 33 366,6 µs).
        assertEquals(5_033_366L, r.instanteUs(1_000 + 3003))
        // Dez segundos de título depois: dez segundos de relógio.
        assertEquals(15_000_000L, r.instanteUs(1_000 + 900_000))
        assertEquals(1_000L + 90_000, r.posicao90k(6_000_000))
    }

    @Test
    fun `pausar para o relogio e continuar anda a ancora o tempo da pausa`() {
        val r = RelogioDoDisco()
        r.ancorar(0, 0, 1_000_000)
        r.pausar(2_000_000)  // 1 s de título
        assertEquals(90_000L, r.posicao90k(9_000_000))  // parado no segundo 1
        assertNull(r.amostraEm(0, 2_500_000))           // pausado: sem som
        r.continuar(5_000_000)                          // 3 s de pausa
        assertEquals(5_000_000L, r.instanteUs(90_000))   // o segundo 1 sai na volta
        assertEquals(90_000L + 45_000, r.posicao90k(5_500_000))
        // Pausar duas vezes e continuar duas vezes não soma nada.
        r.pausar(6_000_000); r.pausar(7_000_000); r.continuar(8_000_000); r.continuar(9_000_000)
        assertEquals(7_000_000L, r.instanteUs(90_000))
    }

    @Test
    fun `o quadro atrasado empurra a ancora em vez de sair uma rajada`() {
        val r = RelogioDoDisco()
        r.ancorar(0, 0, 0)
        // 30 ms atrasado: dentro da tolerância de 60 ms, nada muda.
        assertFalse(r.alinharSeAtrasado(3003, 33_366 + 30_000, 60_000))
        // 500 ms atrasado (a leitura engasgou): a âncora anda até ele sair agora.
        assertTrue(r.alinharSeAtrasado(3003, 33_366 + 500_000, 60_000))
        assertEquals(33_366L + 500_000, r.instanteUs(3003))
        assertEquals(1, r.reancoragens)
        // O seguinte sai um quadro depois dele, e não logo em seguida.
        assertEquals(33_366L + 500_000 + 33_367, r.instanteUs(6006))
    }

    @Test
    fun `o som pela hora e pela geracao`() {
        val r = RelogioDoDisco()
        assertNull(r.amostraEm(0, 0))
        r.ancorar(3, 0, 1_000_000)
        assertNull(r.amostraEm(2, 1_500_000))           // outra geração
        assertEquals(24_000L, r.amostraEm(3, 1_500_000)) // meio segundo = 24 000 amostras
        r.soltar()                                      // o pulo
        assertNull(r.amostraEm(3, 1_500_000))
    }

    private fun rampa(de: Int, n: Int) = ShortArray(2 * n) { ((de + it / 2) % 30000).toShort() }

    @Test
    fun `o som segue continuo dentro da tolerancia`() {
        val f = FilaDoSomDoDisco()
        f.reiniciar(1)
        f.empurrar(1, rampa(0, 4800), 4800)
        val s = ShortArray(960 * 2)
        // 5 ms adiantado em relação à fila (240 amostras): contínuo, sem pular nada.
        f.tirar(1, 240, s, 960, 2)
        assertEquals(0, s[0].toInt())
        assertEquals(959, s[2 * 959].toInt())
        f.tirar(1, 240 + 960, s, 960, 2)
        assertEquals(960, s[0].toInt())
        assertEquals(0L, f.caidas)
        assertEquals(0L, f.silencio)
    }

    @Test
    fun `o som atrasado cai e o adiantado espera em silencio`() {
        val f = FilaDoSomDoDisco()
        f.reiniciar(0)
        f.empurrar(0, rampa(0, 48_000), 48_000)
        val s = ShortArray(960 * 2)
        // O relógio andou meio segundo (a leitura engasgou): as velhas caem, e sai a amostra da hora.
        f.tirar(0, 24_000, s, 960, 2)
        assertEquals(24_000, s[0].toInt())
        assertEquals(24_000L, f.caidas)
        // Um buraco: a fila começa 10 000 amostras depois da hora — silêncio, sem consumir.
        val h = FilaDoSomDoDisco()
        h.reiniciar(0)
        h.empurrar(0, rampa(0, 960), 960)
        h.tirar(0, -10_000, s, 960, 2)
        assertTrue(s.all { it.toInt() == 0 })
        assertEquals(960, h.tamanho)
        assertEquals(960L, h.silencio)
        // Parte do quadro (além dos 10 ms de tolerância): 600 amostras de silêncio, e o som dali em diante.
        h.tirar(0, -600, s, 960, 2)
        assertEquals(1560L, h.silencio)
        assertEquals(1, s[2 * 601].toInt())
        assertEquals(359, s[2 * 959].toInt())
        assertEquals(600, h.tamanho)
        // A fila secou: o que falta é silêncio.
        val g = FilaDoSomDoDisco()
        g.reiniciar(0)
        g.empurrar(0, rampa(0, 100), 100)
        g.tirar(0, 0, s, 960, 2)  // consome as 100, e o resto é silêncio (a fila secou)
        assertEquals(99, s[2 * 99].toInt())
        assertEquals(0, s[2 * 100].toInt())
        assertEquals(860L, g.silencio)
    }

    @Test
    fun `sem ancora ou de outra geracao e silencio sem consumir`() {
        val f = FilaDoSomDoDisco()
        f.reiniciar(2)
        f.empurrar(1, rampa(5, 960), 960)  // de uma geração velha: cai
        assertEquals(0, f.tamanho)
        f.empurrar(2, rampa(5, 960), 960)
        val s = ShortArray(960 * 2) { 7 }
        f.tirar(2, null, s, 960, 2)
        assertTrue(s.all { it.toInt() == 0 })
        assertEquals(960, f.tamanho)
        f.tirar(1, 0, s, 960, 2)
        assertEquals(960, f.tamanho)
    }

    @Test
    fun `mono e a media dos dois lados`() {
        val f = FilaDoSomDoDisco()
        f.reiniciar(0)
        val pcm = ShortArray(2 * 960) { if (it % 2 == 0) 1000 else 3000 }
        f.empurrar(0, pcm, 960)
        val s = ShortArray(960)
        f.tirar(0, 0, s, 960, 1)
        assertEquals(2000, s[0].toInt())
        assertEquals(2000, s[959].toInt())
    }

    @Test
    fun `a fila cheia solta o mais velho e o indice anda junto`() {
        val f = FilaDoSomDoDisco(capacidade = 1000)
        f.reiniciar(0)
        f.empurrar(0, rampa(0, 800), 800)
        f.empurrar(0, rampa(800, 800), 800)  // 600 velhas saem
        assertEquals(1000, f.tamanho)
        assertEquals(600L, f.recusadas)
        val s = ShortArray(2 * 100)
        f.tirar(0, 600, s, 100, 2)
        assertEquals(600, s[0].toInt())
    }
}
