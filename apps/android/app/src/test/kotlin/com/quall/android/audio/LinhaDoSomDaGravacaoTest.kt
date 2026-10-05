package com.quall.android.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [LinhaDoSomDaGravacao]: o som da gravação local no tempo do arquivo (R5, fase 3; §5.2, G3).
 * **Rodam na JVM.** O que se confere em todos: o que sai é **contínuo** (cada pedaço começa onde o
 * anterior acabou) e cada amostra de verdade cai perto da hora em que foi capturada.
 */
class LinhaDoSomDaGravacaoTest {

    private val taxa = 48_000
    private val q = 960 // 20 ms mono

    /** Guarda o que saiu: a posição de cada amostra de verdade (o valor dela é a posição de captura). */
    private class Coleta(private val guardar: Boolean = true) : LinhaDoSomDaGravacao.Saida {
        var fim = 0L
        var pedacos = 0
        /** posição no arquivo → valor (0 = silêncio). */
        val amostras = HashMap<Long, Short>()
        override fun pedaco(pcm: ShortArray, desde: Int, n: Int, posicao: Long) {
            assertEquals("contínuo: o pedaço começa onde o anterior acabou", fim, posicao)
            if (guardar) for (i in 0 until n) amostras[posicao + i] = pcm[desde + i]
            fim = posicao + n
            pedacos++
        }
    }

    /** Um quadro de 20 ms cujas amostras valem 1 (som de verdade, distinguível do silêncio). */
    private fun quadro() = ShortArray(q) { 1 }

    private fun us(amostras: Long) = amostras * 1_000_000 / taxa

    @Test
    fun antes_do_zero_nada_entra_e_o_quadro_que_cruza_o_zero_e_cortado() {
        val l = LinhaDoSomDaGravacao(taxa, 1)
        val c = Coleta()
        l.quadro(quadro(), q, 1_000_000, c)
        assertEquals(0, c.pedacos)
        l.zeroUs = 1_000_000 + us(300) // o vídeo começa 300 amostras depois deste quadro
        l.quadro(quadro(), q, 1_000_000, c)
        assertEquals(1, c.pedacos)
        assertEquals((q - 300).toLong(), c.fim)
    }

    @Test
    fun quadros_seguidos_no_tempo_saem_seguidos_sem_correcao() {
        val l = LinhaDoSomDaGravacao(taxa, 1)
        l.zeroUs = 5_000_000
        val c = Coleta()
        for (i in 0 until 500) l.quadro(quadro(), q, 5_000_000 + us(i * q.toLong()), c)
        assertEquals(500L * q, c.fim)
        assertEquals(0L, l.correcoes)
        assertEquals(0L, l.silencioInserido)
    }

    @Test
    fun o_microfone_que_abre_depois_recebe_silencio_ate_a_hora_dele() {
        val l = LinhaDoSomDaGravacao(taxa, 1)
        l.zeroUs = 0
        val c = Coleta()
        // O microfone abre 250 ms depois do primeiro quadro de vídeo.
        l.quadro(quadro(), q, 250_000, c)
        assertEquals(12_000L + q, c.fim)
        assertEquals(0.toShort(), c.amostras[11_999])
        assertEquals(1.toShort(), c.amostras[12_000])
    }

    @Test
    fun a_deriva_do_relogio_do_microfone_e_corrigida_antes_de_passar_do_limiar() {
        val l = LinhaDoSomDaGravacao(taxa, 1)
        l.zeroUs = 0
        // O microfone anda 500 ppm mais devagar que o MONOTONIC: 10 min de som.
        val quadroUs = 20_000.0 * (1 + 500e-6)
        val c = Coleta(guardar = false)
        for (i in 0 until 30_000) l.quadro(quadro(), q, (i * quadroUs).toLong(), c)
        assertTrue("corrigiu", l.correcoes > 0)
        // No fim, a última amostra de verdade está a menos de 20 ms + um quadro da hora dela.
        val ultimaHora = ((30_000 - 1) * quadroUs).toLong()
        val posicaoDaUltima = c.fim - q
        val desvioMs = Math.abs(posicaoDaUltima - ultimaHora * taxa / 1_000_000) * 1000.0 / taxa
        assertTrue("desvio $desvioMs ms", desvioMs <= 20.5)
    }

    @Test
    fun o_quadro_que_chega_depois_do_silencio_perde_o_que_ja_passou() {
        val l = LinhaDoSomDaGravacao(taxa, 1)
        l.zeroUs = 0
        val c = Coleta()
        l.silencioAte(100_000, c) // o botão desligado: 100 ms de silêncio
        assertEquals(4_800L, c.fim)
        // Um quadro capturado em 60 ms chega agora: 40 ms dele já passaram.
        l.quadro(quadro(), q, 60_000, c)
        assertEquals(4_800L, c.fim) // 960 amostras de 60..80 ms: tudo antes de 100 ms → cai
        l.quadro(quadro(), q, 90_000, c)
        // 90..110 ms: 10 ms passaram (480 amostras), dentro do limiar de 20 ms → entra inteiro.
        assertEquals(4_800L + q, c.fim)
    }

    @Test
    fun o_limite_do_fim_corta_o_som_que_passa_do_ultimo_quadro_e_o_silencio_completa() {
        val l = LinhaDoSomDaGravacao(taxa, 1)
        l.zeroUs = 0
        val c = Coleta()
        for (i in 0 until 10) l.quadro(quadro(), q, us(i * q.toLong()), c)
        l.limiteUs = 250_000 // o vídeo acaba em 250 ms
        for (i in 10 until 20) l.quadro(quadro(), q, us(i * q.toLong()), c)
        assertEquals(12_000L, c.fim)
        // Sem som até o fim: o silêncio completa, e só até o limite.
        val l2 = LinhaDoSomDaGravacao(taxa, 1)
        l2.zeroUs = 0
        val c2 = Coleta()
        l2.quadro(quadro(), q, 0, c2)
        l2.limiteUs = 500_000
        l2.silencioAte(10_000_000, c2)
        assertEquals(24_000L, c2.fim)
    }

    @Test
    fun sem_hora_o_quadro_cai_onde_a_linha_esta() {
        val l = LinhaDoSomDaGravacao(taxa, 2)
        l.zeroUs = 0
        val c = Coleta()
        val pcm = ShortArray(q * 2) { 1 }
        l.quadro(pcm, q, null, c)
        l.quadro(pcm, q, null, c)
        assertEquals(2L * q, c.fim)
        assertEquals(2L, l.quadrosSemHora)
    }
}
