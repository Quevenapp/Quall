package com.quall.android.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [ComportaDoSom]: o som da gravação espera o vídeo (o achado A da prova de 24/09 no A07: o som
 * terminava +136,4 ms depois da imagem). **Rodam na JVM**, com a [LinhaDoSomDaGravacao] de verdade
 * na frente, como no `GravadorDaCamera`.
 */
class ComportaDoSomTest {

    private val taxa = 48_000
    private val q = 960 // 20 ms mono

    private fun us(amostras: Long) = amostras * 1_000_000 / taxa

    /** O AAC de mentira: aceita tudo, confere a continuidade e guarda o fim. */
    private class Aac(private val porVez: Int = Int.MAX_VALUE) : ComportaDoSom.Consumidor {
        var fim = 0L
        override fun aceitar(pcm: ShortArray, desde: Int, n: Int, posicao: Long): Int {
            assertEquals("contínuo: o pedaço começa onde o anterior acabou", fim, posicao)
            val k = minOf(n, porVez)
            fim = posicao + k
            return k
        }
    }

    /**
     * O fim de uma gravação, como no aparelho: o vídeo codifica com [latenciaDoVideoUs] de atraso, o
     * último quadro é capturado em [ultimoQuadroUs], e o fim de fluxo só sai do codificador
     * [fimDeFluxoDepoisUs] depois dele; o microfone entrega a cada 20 ms com [latenciaDoSomUs].
     * Devolve o fim do som no AAC menos o fim da imagem, em ms.
     */
    private fun fim(comComporta: Boolean, latenciaDoVideoUs: Long, fimDeFluxoDepoisUs: Long, latenciaDoSomUs: Long): Double {
        val zero = 10_000_000L
        val quadroUs = 33_333L
        val ultimoQuadroUs = zero + 60 * quadroUs // 2 s de vídeo
        val fimDaImagem = ultimoQuadroUs + quadroUs
        val linha = LinhaDoSomDaGravacao(taxa, 1)
        linha.zeroUs = zero
        val comporta = ComportaDoSom(1)
        val aac = Aac()
        val saida = LinhaDoSomDaGravacao.Saida { pcm, desde, n, posicao ->
            if (comComporta) comporta.entrar(pcm, desde, n, posicao) else aac.aceitar(pcm, desde, n, posicao)
        }
        var ultimoQuadroQueSaiu = Long.MIN_VALUE
        var proximoSom = zero
        var agora = zero
        val fimDeFluxo = ultimoQuadroUs + latenciaDoVideoUs + fimDeFluxoDepoisUs
        // O relógio anda de 1 ms em 1 ms até o fim de fluxo sair do codificador.
        while (agora <= fimDeFluxo) {
            // O som captado em `proximoSom` chega `latenciaDoSomUs` depois.
            while (proximoSom + us(q.toLong()) + latenciaDoSomUs <= agora) {
                linha.quadro(ShortArray(q) { 1 }, q, proximoSom, saida)
                proximoSom += us(q.toLong())
            }
            // O quadro de vídeo capturado em t sai do codificador em t + latência.
            val saiuAte = agora - latenciaDoVideoUs
            if (saiuAte >= zero) {
                val k = minOf((saiuAte - zero) / quadroUs, 60)
                ultimoQuadroQueSaiu = zero + k * quadroUs
            }
            if (comComporta) {
                comporta.teto = if (ultimoQuadroQueSaiu == Long.MIN_VALUE) 0 else linha.amostraDe(ultimoQuadroQueSaiu)
                comporta.soltar(aac)
            }
            agora += 1_000
        }
        // O fim de fluxo saiu: o limite, o silêncio até ele, o corte e o resto.
        linha.limiteUs = fimDaImagem
        linha.silencioAte(fimDaImagem, saida)
        if (comComporta) {
            val lim = linha.amostraDe(fimDaImagem)
            comporta.teto = lim
            comporta.cortarDesde(lim)
            comporta.soltar(aac)
            assertTrue("a comporta esvaziou", comporta.vazia)
        }
        return (us(aac.fim) - (fimDaImagem - zero)) / 1000.0
    }

    @Test
    fun sem_a_comporta_o_som_passa_do_fim_da_imagem_como_no_a07() {
        // O controle: o defeito reproduzido. 60 ms de codificador de vídeo, 120 ms até o fim de fluxo
        // sair, 40 ms de microfone — o som codificado passa do fim da imagem em ~100 ms.
        val d = fim(comComporta = false, latenciaDoVideoUs = 60_000, fimDeFluxoDepoisUs = 120_000, latenciaDoSomUs = 40_000)
        assertTrue("sem a comporta: $d ms", d > 50)
    }

    @Test
    fun com_a_comporta_o_som_termina_com_a_imagem() {
        for (lv in listOf(0L, 30_000L, 60_000L, 150_000L)) {
            for (ff in listOf(0L, 90_000L, 300_000L)) {
                for (ls in listOf(0L, 40_000L, 120_000L)) {
                    val d = fim(comComporta = true, latenciaDoVideoUs = lv, fimDeFluxoDepoisUs = ff, latenciaDoSomUs = ls)
                    assertEquals("vídeo $lv µs, fim de fluxo $ff µs, som $ls µs: $d ms", 0.0, d, 0.05)
                }
            }
        }
    }

    @Test
    fun a_comporta_segura_o_que_passa_do_teto_e_solta_em_ordem() {
        val c = ComportaDoSom(1)
        val aac = Aac()
        c.entrar(ShortArray(q), 0, q, 0)
        c.entrar(ShortArray(q), 0, q, q.toLong())
        c.teto = 1_000
        c.soltar(aac)
        assertEquals(1_000L, aac.fim)
        assertEquals((2 * q - 1_000).toLong(), c.esperando)
        c.teto = null
        c.soltar(aac)
        assertEquals((2 * q).toLong(), aac.fim)
        assertTrue(c.vazia)
    }

    @Test
    fun sem_lugar_no_aac_o_resto_espera_a_proxima_vez() {
        val c = ComportaDoSom(2)
        val aac = Aac(porVez = 100)
        c.entrar(ShortArray(2 * q), 0, q, 0)
        c.teto = null
        c.soltar(aac)
        assertEquals(q.toLong(), aac.fim)
        val cheio = ComportaDoSom.Consumidor { _, _, _, _ -> 0 }
        c.entrar(ShortArray(2 * q), 0, q, q.toLong())
        c.soltar(cheio)
        assertEquals(q.toLong(), c.esperando)
        c.soltar(aac)
        assertEquals((2 * q).toLong(), aac.fim)
    }

    @Test
    fun o_corte_joga_fora_o_que_passa_da_posicao_e_conta() {
        val c = ComportaDoSom(1)
        c.entrar(ShortArray(q), 0, q, 0)
        c.entrar(ShortArray(q), 0, q, q.toLong())
        c.entrar(ShortArray(q), 0, q, 2L * q)
        c.cortarDesde(q + 100L)
        assertEquals((2 * q - 100).toLong(), c.cortadas)
        c.teto = null
        val aac = Aac()
        c.soltar(aac)
        assertEquals(q + 100L, aac.fim)
    }

    @Test
    fun a_copia_protege_do_vetor_reaproveitado() {
        val c = ComportaDoSom(1)
        val v = ShortArray(q) { 7 }
        c.entrar(v, 0, q, 0)
        v.fill(0)
        var visto: Short = 0
        c.teto = null
        c.soltar { pcm, desde, n, _ -> visto = pcm[desde]; n }
        assertEquals(7.toShort(), visto)
    }
}
