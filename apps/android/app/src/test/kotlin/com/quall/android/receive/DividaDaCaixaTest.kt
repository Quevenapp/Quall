package com.quall.android.receive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Testes de [DividaDaCaixa]. Rodam na JVM (`gradle testDebugUnitTest`); o portão de compilação
 * roda os dois.
 *
 * O relógio começa em **zero** de propósito: o estado "nunca pedi" não pode depender de o relógio
 * ser diferente de zero.
 */
class DividaDaCaixaTest {

    /** Microssegundos a partir de [ms] milissegundos. */
    private fun em(ms: Long): Long = ms * 1000L

    @Test
    fun sem_descarte_nao_ha_pedido() {
        val d = DividaDaCaixa()
        assertFalse(d.devePedir(em(0)))
        assertFalse(d.devePedir(em(60_000)))
        assertEquals(0L, d.episodios)
    }

    /** O descarte só anota: o pedido espera a caixa ficar 500 ms sem descartar. */
    @Test
    fun o_pedido_espera_a_calmaria() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        assertFalse(d.devePedir(em(0)))
        assertFalse(d.devePedir(em(499)))
        assertTrue(d.devePedir(em(500)))
    }

    @Test
    fun calmaria_zero_pede_na_hora() {
        val d = DividaDaCaixa(calmariaUs = 0)
        d.notarDescarte(em(0))
        assertTrue(d.devePedir(em(0)))
    }

    /** Descarte novo durante a espera recomeça a calmaria, e continua sendo um episódio só. */
    @Test
    fun rajada_de_descartes_e_um_episodio_e_recomeca_a_calmaria() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.notarDescarte(em(300))
        d.notarDescarte(em(450))
        assertFalse(d.devePedir(em(900)))
        assertTrue(d.devePedir(em(950)))
        assertEquals(1L, d.episodios)
    }

    /**
     * **Transbordo sem fim nunca pede** — o caso do Windows (358 IDRs em 105 s quando pedia durante
     * o transbordo). E quando o transbordo acaba, o pedido sai depois da calmaria.
     */
    @Test
    fun caixa_descartando_sem_parar_so_pede_quando_para() {
        val d = DividaDaCaixa()
        var t = 0L
        while (t < 10_000) {
            d.notarDescarte(em(t))
            assertFalse("pediu em $t ms", d.devePedir(em(t + 99)))
            t += 100
        }
        assertEquals(1L, d.episodios)
        assertFalse(d.devePedir(em(10_399)))
        assertTrue(d.devePedir(em(10_400)))
    }

    /** Um IDR que chega antes do pedido (GOP, perda de rede) paga a dívida: nada sai à toa. */
    @Test
    fun idr_antes_do_pedido_paga_sem_pedir() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.notarIdr(em(100))
        assertFalse(d.devePedir(em(5_000)))
        assertEquals(1L, d.pagasSemPedido)
        assertEquals(0L, d.pedidos)
    }

    /**
     * Descarte e IDR **na mesma tirada**: o laço chama `notarDescarte` e depois `notarIdr`, e a
     * ordem tem de pagar — a caixa descarta o mais velho, então o descarte é anterior ao IDR.
     */
    @Test
    fun descarte_e_idr_na_mesma_tirada_pagam() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.notarIdr(em(0))
        assertFalse(d.devendoAgora)
        assertFalse(d.devePedir(em(5_000)))
    }

    @Test
    fun idr_sem_divida_nao_conta_nada() {
        val d = DividaDaCaixa()
        d.notarIdr(em(0))
        d.notarIdr(em(1_000))
        assertEquals(0L, d.pagasSemPedido)
        assertEquals(0L, d.episodios)
    }

    /** Pedido feito no instante zero do relógio: continua valendo como pedido feito. */
    @Test
    fun depois_do_pedido_espera_um_segundo_para_repedir() {
        val d = DividaDaCaixa(calmariaUs = 0)
        d.notarDescarte(em(0))
        assertTrue(d.devePedir(em(0)))
        d.pediu(em(0))
        assertFalse(d.devePedir(em(1)))
        assertFalse(d.devePedir(em(999)))
        assertTrue(d.devePedir(em(1_000)))
    }

    /** Pedido que falhou (status ruim): `pediu` não é chamado, e o pedido continua devido. */
    @Test
    fun pedido_que_nao_saiu_continua_devido() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        assertTrue(d.devePedir(em(500)))
        assertTrue(d.devePedir(em(501)))
        assertEquals(0L, d.pedidos)
    }

    /** Cada repetição sem resposta dobra a espera: 1 s, 2 s, 4 s, e para no teto. */
    @Test
    fun repetir_sem_resposta_recua_ate_o_teto() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.pediu(em(500))
        assertTrue(d.devePedir(em(1_500)))
        d.pediu(em(1_500))
        assertFalse(d.devePedir(em(3_499)))
        assertTrue(d.devePedir(em(3_500)))
        d.pediu(em(3_500))
        assertFalse(d.devePedir(em(7_499)))
        assertTrue(d.devePedir(em(7_500)))
        d.pediu(em(7_500))
        assertTrue(d.devePedir(em(11_500)))
        // Um IDR que nunca cabe: 30 s de insistência são poucos pedidos, não trinta.
        var t = 11_500L
        while (t < 41_500) {
            if (d.devePedir(em(t))) d.pediu(em(t))
            t += 10
        }
        assertTrue("pedidos=${d.pedidos}", d.pedidos <= 4 + 8)
    }

    /** O IDR pedido chega: dívida paga, e não conta como paga sem pedido. */
    @Test
    fun o_idr_pedido_paga_a_divida() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.pediu(em(500))
        d.notarIdr(em(560))
        assertFalse(d.devePedir(em(5_000)))
        assertEquals(0L, d.pagasSemPedido)
        assertFalse(d.devendoAgora)
    }

    /**
     * Descarte depois do pedido e antes do IDR: é o IDR pedido sendo descartado na caixa, ou um
     * buraco novo. Nenhum dos dois pede de novo antes de repedir **e** da calmaria.
     */
    @Test
    fun descarte_depois_do_pedido_respeita_as_duas_esperas() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.pediu(em(500))
        d.notarDescarte(em(1_300))
        assertFalse(d.devePedir(em(1_500)))
        assertTrue(d.devePedir(em(1_800)))
        assertEquals(1L, d.episodios)
    }

    /** Pedido de outra causa **durante** a dívida: o IDR dele vai pagar; não se pede em cima. */
    @Test
    fun pedido_de_outra_causa_durante_a_divida_segura_o_nosso() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.outroPedidoSaiu(em(480))
        assertFalse(d.devePedir(em(500)))
        assertFalse(d.devePedir(em(1_479)))
        assertTrue(d.devePedir(em(1_480)))
        d.notarIdr(em(600))
        assertEquals(1L, d.pagasSemPedido)
    }

    /** Pedido de outra causa **antes** da dívida não conta: o IDR dele pode já ter passado. */
    @Test
    fun pedido_de_outra_causa_antes_da_divida_nao_conta() {
        val d = DividaDaCaixa()
        d.outroPedidoSaiu(em(0))
        d.notarDescarte(em(100))
        assertTrue(d.devePedir(em(600)))
    }

    /**
     * **A espiral**: o IDR pedido chega e a caixa descarta logo depois, de novo e de novo. A
     * calmaria dobra a cada volta até 4 s, e em 60 s saem poucos pedidos em vez de ~100.
     */
    @Test
    fun espiral_de_idr_e_descarte_recua_ate_o_teto() {
        val d = DividaDaCaixa()
        var t = 0L
        d.notarDescarte(em(t))
        while (t < 60_000) {
            t += 10
            if (d.devePedir(em(t))) {
                d.pediu(em(t))
                t += 55
                d.notarIdr(em(t))
                t += 50
                d.notarDescarte(em(t))
            }
        }
        assertTrue("reincidencias=${d.reincidencias}", d.reincidencias >= 3)
        // 0,5 + 1 + 2 + 4 s de calmaria e depois um a cada ~4,1 s: 16 pedidos em 60 s. Sem o
        // recuo, com 0,5 s fixos, seriam ~100.
        assertTrue("pedidos=${d.pedidos}", d.pedidos <= 16)
    }

    /** Depois de uma calmaria longa, o episódio seguinte volta à calmaria de base. */
    @Test
    fun episodio_longe_do_ultimo_idr_volta_a_calmaria_de_base() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.pediu(em(500))
        d.notarIdr(em(560))
        d.notarDescarte(em(600))
        assertEquals(1L, d.reincidencias)
        assertFalse(d.devePedir(em(1_599)))
        assertTrue(d.devePedir(em(1_600)))
        d.pediu(em(1_600))
        d.notarIdr(em(1_660))
        d.notarDescarte(em(9_000))
        assertFalse(d.devePedir(em(9_499)))
        assertTrue(d.devePedir(em(9_500)))
    }

    /** Um IDR de GOP que pagou não conta para a espiral: só IDR nosso. */
    @Test
    fun idr_do_gop_nao_conta_como_reincidencia() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.notarIdr(em(100))
        d.notarDescarte(em(200))
        assertEquals(0L, d.reincidencias)
        assertTrue(d.devePedir(em(700)))
    }

    @Test
    fun a_linha_diz_a_divida_pendente() {
        val d = DividaDaCaixa()
        d.notarDescarte(em(0))
        d.pediu(em(500))
        d.notarIdr(em(560))
        d.notarDescarte(em(5_000))
        assertEquals(
            "episodios=2 pedidos=1 pagas_sem_pedido=0 reincidencias=0 pendente=sim",
            d.linha(),
        )
    }
}
