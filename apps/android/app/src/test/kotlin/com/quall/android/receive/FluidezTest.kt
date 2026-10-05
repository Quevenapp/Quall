package com.quall.android.receive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

/**
 * Testes de [Fluidez]. **Rodam na JVM, sem aparelho e sem emulador** — a peça é aritmética pura e
 * não toca uma linha de API do Android, que é o motivo de ela ser uma classe própria em vez de
 * campos soltos dentro do [H264Decoder].
 *
 * São os mesmos casos do `mod testes` de `apps/windows/src/fluidez.rs`, na mesma ordem e com os
 * mesmos números, mais dois que só esta casca precisa: o teto de amostras e a locale.
 *
 * `gradle testDebugUnitTest` os roda. **O portão de compilação não** — ele chama `assembleDebug`,
 * que nem compila este arquivo. Ver `docs/android-para-android.md`, §18.
 */
class FluidezTest {

    /** Microssegundos, [ms] depois da base. O relógio da peça é o `MonotonicClock`, em µs. */
    private fun em(baseUs: Long, ms: Long): Long = baseUs + ms * 1000L

    /**
     * **A primeira chamada só ancora.** Não existe intervalo antes do primeiro quadro, e contar o
     * tempo desde a abertura da sessão poria a subida do ICE, o pareamento e a espera pelo
     * primeiro IDR dentro da distribuição da imagem — nesta casca, segundos.
     */
    @Test
    fun a_primeira_apresentacao_so_ancora() {
        val f = Fluidez()
        f.apresentou(1_000_000L)
        assertTrue(f.linha(), f.linha().contains("n=0"))
        assertEquals(0L, f.trancos())
    }

    /** Dois quadros, um intervalo — e ele é o decorrido real, não o nominal de 30 fps. */
    @Test
    fun dois_quadros_dao_um_intervalo() {
        val t = 5_000_000L
        val f = Fluidez()
        f.apresentou(t)
        f.apresentou(em(t, 33))
        val l = f.linha()
        assertTrue(l, l.contains("n=1"))
        assertTrue(l, l.contains("p50=33"))
        assertTrue(l, l.contains("max=33"))
        assertTrue(l, l.contains("trancos=0"))
    }

    /**
     * **O que a média escondia.** Vinte e nove intervalos de 33 ms e um de 226 ms — a média dá
     * ~39 ms e parece saudável; o `max` mostra o buraco e `trancos` o conta. É a corrida real de
     * 01/09/2026 em miniatura.
     */
    @Test
    fun um_buraco_no_meio_de_uma_sessao_regular_aparece_no_max_e_nos_trancos() {
        val t = 5_000_000L
        val f = Fluidez()
        var agora = 0L
        f.apresentou(em(t, agora))
        for (i in 0 until 30) {
            agora += if (i == 15) 226L else 33L
            f.apresentou(em(t, agora))
        }
        val l = f.linha()
        assertTrue(l, l.contains("n=30"))
        assertTrue(l, l.contains("p50=33"))
        assertTrue(l, l.contains("max=226"))
        assertTrue(l, l.contains("trancos=1"))
        // A prova de que o centro não responde: a média destes trinta intervalos é ~39 ms.
        val media = (29 * 33 + 226) / 30.0
        assertTrue("a média destes intervalos é $media ms e não acusa nada", media < 40.0)
    }

    /**
     * O corte de `trancos` é **estrito**: exatamente no limiar não conta, e um micro acima conta.
     * Fica fixado para que a comparação entre duas corridas não dependa de arredondamento.
     */
    @Test
    fun o_corte_do_tranco_e_estrito() {
        val t = 5_000_000L
        val f = Fluidez()
        f.apresentou(t)
        f.apresentou(em(t, Fluidez.TRANCO_MS))
        assertEquals("no limiar não é tranco", 0L, f.trancos())
        f.apresentou(em(t, Fluidez.TRANCO_MS) + Fluidez.TRANCO_MS * 1000L + 1L)
        assertEquals("um microssegundo acima é", 1L, f.trancos())
    }

    /**
     * **A porta aparece aqui, e é o ponto.** Segurar um quadro condenado não o conserta: a tela
     * para. Este teste é a forma que isso tem na distribuição — os intervalos em que a porta
     * segurou três quadros viram um intervalo de quatro tempos.
     *
     * Nesta casca a porta é `releaseOutputBuffer(idx, false)` em [H264Decoder.drenar], que **não**
     * chama [Fluidez.apresentou]: por isso o intervalo cresce em vez de aparecer como três
     * intervalos curtos. Medir chegadas, ou contar todo `releaseOutputBuffer`, esconderia isso.
     */
    @Test
    fun a_porta_que_segura_quadros_aparece_como_intervalo_maior() {
        val t = 5_000_000L
        val f = Fluidez()
        var agora = 0L
        f.apresentou(em(t, agora))
        for (i in 0 until 10) {
            // A cada cinco quadros, três ficam retidos: o intervalo seguinte é 4 x 33.
            agora += if (i % 5 == 0) 33L * 4 else 33L
            f.apresentou(em(t, agora))
        }
        val l = f.linha()
        assertTrue(l, l.contains("n=10"))
        assertTrue(l, l.contains("max=132"))
        assertEquals("dois intervalos de 132 ms passam do corte de 100", 2L, f.trancos())
    }

    /** Uma sessão sem quadro nenhum não afirma nada — e não divide por zero. */
    @Test
    fun sem_quadro_nenhum_a_linha_existe_e_nao_mente() {
        val f = Fluidez()
        assertEquals("fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0", f.linha())
        assertEquals(0L, f.trancos())
    }

    /**
     * **O teto é dito, não fingido.** Passado o teto o `n` para de crescer, e a linha diz quantas
     * amostras ficaram de fora em vez de deixar o leitor achar que `n` é a sessão inteira. A 30 fps
     * o teto chega em ~5,5 minutos, e sessões de bancada passam disso.
     */
    @Test
    fun passado_o_teto_a_linha_diz_o_que_descartou() {
        val t = 5_000_000L
        val f = Fluidez()
        val quantos = Fluidez.MAXIMO_DE_AMOSTRAS + 7
        for (i in 0..quantos) f.apresentou(t + i * 33_000L)
        val l = f.linha()
        assertTrue(l, l.contains("n=${Fluidez.MAXIMO_DE_AMOSTRAS}"))
        assertTrue(l, l.contains("(+7 além do teto)"))
    }

    /**
     * **A linha é lida por máquina e não pode depender do idioma do celular.** Os aparelhos desta
     * bancada estão em pt-BR; `"%.0f".format(...)` sob essa locale escreve vírgula decimal, e os
     * roteiros de bancada partem esta linha em `=` e espaço. Este teste falha no dia em que alguém
     * trocar a aritmética inteira de [Fluidez.linha] por formatação de ponto flutuante.
     */
    @Test
    fun a_linha_nao_muda_com_a_locale_do_aparelho() {
        val antes = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("pt-BR"))
            val t = 5_000_000L
            val f = Fluidez()
            f.apresentou(t)
            f.apresentou(em(t, 1234))
            val l = f.linha()
            assertEquals("fluidez_ms=[n=1 p50=1234 p95=1234 max=1234] trancos=1", l)
            assertTrue("nenhuma vírgula na linha: $l", !l.contains(","))
        } finally {
            Locale.setDefault(antes)
        }
    }

    /**
     * A forma da linha é contrato, e ela é literal. Ver `docs/regras-de-frente.md`.
     *
     * De quebra fixa o índice do percentil: com três amostras, `p95` é `v[(0,95 × 2).toInt()]` =
     * `v[1]` = 33 ms, e **não** o máximo. É o mesmo índice do original em Rust, e ele importa
     * porque duas cascas que arredondassem o índice para lados diferentes dariam números que a
     * bancada compararia como se fossem o mesmo.
     */
    @Test
    fun a_forma_da_linha_e_a_do_contrato() {
        val t = 5_000_000L
        val f = Fluidez()
        f.apresentou(t)
        f.apresentou(em(t, 33))
        f.apresentou(em(t, 66))
        f.apresentou(em(t, 300))
        assertEquals("fluidez_ms=[n=3 p50=33 p95=33 max=234] trancos=1", f.linha())
    }
}
