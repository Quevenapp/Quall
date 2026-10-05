package com.quall.android.teleprompter

import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.teleprompter.Divisao.Escolha
import com.quall.android.teleprompter.Divisao.Lado
import com.quall.android.teleprompter.Divisao.Retangulo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A divisão da tela R5 — texto | prévia | faixa, a conta do iOS (`docs/telas-android-como-ios.md`
 * §1.3): o texto em cima no automático (também deitado, desde 30/09) e embaixo de ponta-cabeça, 50/50,
 * os limites, a faixa que não mexe no texto (e, deitado, a faixa ao lado da prévia), a zona da borda que
 * nunca entra no texto nem na faixa, e a prévia escondida.
 */
class DivisaoTest {

    /** Os valores do iOS, a 1 px por pt (a vista converte de dp). */
    private val m = Divisao.Medidas(previaMinima = 120, reservaDaFaixa = 150, colunaLadoALado = 340, espessuraDaZona = 44)

    /** As medidas em px como a vista as calcula (`DivisaoDaTela`), na densidade de cada aparelho. */
    private val a07 = Divisao.medidas(1.875f) // 720 × 1600 a 300 dpi
    private val tablet = Divisao.medidas(1.5f) // SM-X230, 1200 × 1920 a 240 dpi

    /**
     * **A regra do automático, 30/09** (o pedido do Pessoa Exemplo: deitado, o texto no centro embaixo da
     * câmera, "o mesmo modelo da vertical"): em cima nas rotações 0, 1 e 3; embaixo só de ponta-cabeça.
     * Nunca lado a lado.
     */
    @Test
    fun no_automatico_o_texto_fica_em_cima_e_so_de_ponta_cabeca_embaixo() {
        // `doAutomatico`: o nome da regra no iOS.
        assertEquals(listOf(Lado.TOPO, Lado.TOPO, Lado.BAIXO, Lado.TOPO), (0..3).map { Divisao.doAutomatico(it) })
        assertEquals(Lado.TOPO, Divisao.ladoDoTexto(0, Escolha.AUTOMATICO))
        assertEquals(Lado.TOPO, Divisao.ladoDoTexto(1, Escolha.AUTOMATICO))
        assertEquals(Lado.BAIXO, Divisao.ladoDoTexto(2, Escolha.AUTOMATICO))
        assertEquals(Lado.TOPO, Divisao.ladoDoTexto(3, Escolha.AUTOMATICO))
        // A rotação fora de 0..3 é a mesma, módulo 4.
        assertEquals(Lado.TOPO, Divisao.ladoDoTexto(5, Escolha.AUTOMATICO))
        assertEquals(Lado.BAIXO, Divisao.ladoDoTexto(-2, Escolha.AUTOMATICO))
        for (rot in 0..3) assertTrue("o automático pôs lado a lado (rot=$rot)", Divisao.empilhado(Divisao.ladoDoTexto(rot, Escolha.AUTOMATICO)))
        // O ajuste fixa o lado, em qualquer rotação — à esquerda e à direita continuam para quem quiser.
        for (rot in 0..3) {
            assertEquals(Lado.BAIXO, Divisao.ladoDoTexto(rot, Escolha.BAIXO))
            assertEquals(Lado.ESQUERDA, Divisao.ladoDoTexto(rot, Escolha.ESQUERDA))
            assertEquals(Lado.DIREITA, Divisao.ladoDoTexto(rot, Escolha.DIREITA))
        }
        // A lente continua pela rotação (as marcas do enquadramento vão para longe dela).
        assertEquals(Lado.ESQUERDA, Divisao.ladoDaLente(1))
        assertEquals(Lado.DIREITA, Divisao.ladoDaLente(3))
        // As chaves do iOS (`LadoDoTexto`) não mudam; o rótulo do automático, sim.
        assertEquals(listOf("automatico", "cima", "baixo", "esquerda", "direita"), Escolha.entries.map { it.chave })
        assertEquals("Automático", Escolha.AUTOMATICO.nome(PT))
        assertEquals("Auto", Escolha.AUTOMATICO.nome(EN))
        assertEquals(Escolha.AUTOMATICO, Escolha.daChave("automatico"))
        assertEquals(Escolha.ESQUERDA, Escolha.daChave("esquerda"))
        assertNull(Escolha.daChave("oposto"))
    }

    /**
     * Cada formato guarda a sua borda: em pé, deitado empilhado (o sufixo `empilhada-larga` do iOS, alta
     * ou baixa a tela) e lado a lado.
     */
    @Test
    fun o_formato_separa_em_pe_deitado_empilhado_e_lado_a_lado() {
        assertEquals("retrato", Divisao.formato(Lado.TOPO, 1080, 2340))
        assertEquals("retrato", Divisao.formato(Lado.BAIXO, 1080, 2340))
        assertEquals("empilhada-larga", Divisao.formato(Lado.TOPO, 1600, 720))
        assertEquals("empilhada-larga", Divisao.formato(Lado.BAIXO, 1920, 1200))
        assertEquals("paisagem", Divisao.formato(Lado.ESQUERDA, 2340, 1080))
        assertEquals("paisagem", Divisao.formato(Lado.DIREITA, 1080, 2340))
    }

    /**
     * **A faixa só vai para o lado da prévia numa tela larga e baixa** (a regra do iOS, 30/09): largura
     * maior que a altura **e** altura abaixo de 540 dp (`alturaDaTelaBaixa`). O celular deitado entra; o
     * tablet deitado (800 dp de altura), não.
     */
    @Test
    fun a_faixa_so_vai_para_o_lado_numa_tela_larga_e_baixa() {
        assertEquals(1012, a07.alturaDaTelaBaixa) // 540 dp a 1,875
        assertEquals(810, tablet.alturaDaTelaBaixa) // 540 dp a 1,5
        assertTrue(Divisao.faixaAoLadoDaPrevia(Lado.TOPO, 1600, 720, a07))
        assertTrue(Divisao.faixaAoLadoDaPrevia(Lado.BAIXO, 1600, 720, a07))
        assertFalse("em pé", Divisao.faixaAoLadoDaPrevia(Lado.TOPO, 720, 1600, a07))
        assertFalse("lado a lado", Divisao.faixaAoLadoDaPrevia(Lado.ESQUERDA, 1600, 720, a07))
        assertFalse("o tablet deitado", Divisao.faixaAoLadoDaPrevia(Lado.TOPO, 1920, 1200, tablet))
        // A borda dos 540 dp: abaixo, ao lado; nela, no pé.
        assertTrue(Divisao.faixaAoLadoDaPrevia(Lado.TOPO, 2000, 809, tablet))
        assertFalse(Divisao.faixaAoLadoDaPrevia(Lado.TOPO, 2000, 810, tablet))
    }

    /**
     * **O A07 deitado** (1600 × 720 px a 1,875; 853 × 384 dp), nas duas paisagens: o texto em cima, na
     * largura toda; a faixa numa coluna de 340 dp à direita da prévia, encostada no pé; a prévia com o
     * resto da banda, na altura toda dela. O teto do texto deixa o maior entre a prévia mínima e a
     * reserva da faixa (150 dp = 281 px), e não a soma.
     */
    @Test
    fun o_a07_deitado_empilha_o_texto_em_cima_e_a_faixa_vai_para_o_lado_da_previa() {
        for (rot in listOf(1, 3)) {
            val lado = Divisao.ladoDoTexto(rot, Escolha.AUTOMATICO)
            val p = Divisao.comFaixa(1600, 720, lado, 0.5, 281, previaEscondida = false, m = a07)
            assertEquals(Retangulo(0, 0, 1600, 360), p.texto)
            assertEquals(Retangulo(963, 439, 1600, 720), p.faixa)
            assertEquals(Retangulo(0, 360, 963, 720), p.previa)
            // A zona só sobre a prévia, encostada na linha; a alça na ponta de cima dela.
            assertEquals(Retangulo(0, 360, 963, 442), p.zona)
            assertEquals(Lado.TOPO, p.ponta)
            assertEquals(1.0 - 281.0 / 720, p.teto, 1e-9)
            assertEquals("empilhada-larga", Divisao.formato(lado, 1600, 720))
        }
        // Com a borda no teto, a prévia fica com a altura da reserva da faixa, e a faixa cabe ao lado.
        val q = Divisao.comFaixa(1600, 720, Lado.TOPO, 0.8, 281, previaEscondida = false, m = a07)
        assertEquals(439, q.texto.altura)
        assertEquals(281, q.previa.altura)
        assertEquals(281, q.faixa.altura)
        assertFalse(q.faixa.cruza(q.texto))
    }

    /**
     * **O tablet SM-X230 deitado** (1920 × 1200 px a 1,5; 1280 × 800 dp): o texto em cima, empilhado como
     * em pé, e a faixa **no pé, na largura toda** — 800 dp passam dos 540 da tela baixa. A borda guarda na
     * chave do deitado.
     */
    @Test
    fun o_tablet_deitado_empilha_o_texto_em_cima_com_a_faixa_no_pe() {
        for (rot in listOf(1, 3)) {
            val lado = Divisao.ladoDoTexto(rot, Escolha.AUTOMATICO)
            val p = Divisao.comFaixa(1920, 1200, lado, 0.5, 240, previaEscondida = false, m = tablet)
            assertEquals(Retangulo(0, 0, 1920, 600), p.texto)
            assertEquals(Retangulo(0, 960, 1920, 1200), p.faixa)
            assertEquals(Retangulo(0, 600, 1920, 960), p.previa)
            assertEquals(Retangulo(0, 600, 1920, 666), p.zona)
            // Empilhado com a faixa no pé: o teto deixa a prévia mínima e a reserva da faixa, somadas.
            assertEquals(1.0 - (180.0 + 225.0) / 1200, p.teto, 1e-9)
            assertEquals("empilhada-larga", Divisao.formato(lado, 1920, 1200))
        }
        // Em pé, como antes: o texto em cima, a faixa no pé da tela inteira.
        val emPe = Divisao.comFaixa(1200, 1920, Divisao.ladoDoTexto(0, Escolha.AUTOMATICO), 0.5, 240, previaEscondida = false, m = tablet)
        assertEquals(Retangulo(0, 0, 1200, 960), emPe.texto)
        assertEquals(Retangulo(0, 1680, 1200, 1920), emPe.faixa)
        assertEquals(Retangulo(0, 960, 1200, 1680), emPe.previa)
    }

    /** De ponta-cabeça (`ROTATION_180`), o texto embaixo, a faixa no alto da tela; deitado, no alto da coluna. */
    @Test
    fun de_ponta_cabeca_o_texto_fica_embaixo() {
        val lado = Divisao.ladoDoTexto(2, Escolha.AUTOMATICO)
        assertEquals(Lado.BAIXO, lado)
        val p = Divisao.comFaixa(1080, 2340, lado, 0.5, 300, previaEscondida = false, m = m)
        assertEquals(Retangulo(0, 1170, 1080, 2340), p.texto)
        assertEquals(Retangulo(0, 0, 1080, 300), p.faixa)
        assertEquals(Retangulo(0, 300, 1080, 1170), p.previa)
        assertEquals(Lado.BAIXO, p.ponta)
        // "Embaixo" escolhido numa tela larga: a coluna da faixa à direita, encostada no alto.
        val q = Divisao.comFaixa(1600, 720, Lado.BAIXO, 0.5, 281, previaEscondida = false, m = a07)
        assertEquals(Retangulo(0, 360, 1600, 720), q.texto)
        assertEquals(Retangulo(963, 0, 1600, 281), q.faixa)
        assertEquals(Retangulo(0, 0, 963, 360), q.previa)
        assertEquals(Retangulo(0, 278, 963, 360), q.zona)
        assertEquals(Lado.BAIXO, q.ponta)
    }

    /**
     * Deitado, **a faixa ao lado da prévia** cresce para cima dentro da coluna dela: o texto e a prévia
     * não mudam, e ela nunca passa da banda nem cobre o texto (também com a lista de avisos aberta).
     */
    @Test
    fun deitado_a_faixa_mora_ao_lado_da_previa_e_cresce_sem_mexer_em_nada() {
        for (lado in listOf(Lado.TOPO, Lado.BAIXO)) for (f in listOf(0.2, 0.5, 0.8)) {
            val baixa = Divisao.comFaixa(1600, 720, lado, f, 100, previaEscondida = false, m = a07)
            for (hF in listOf(200, 281, 400, 2000)) {
                val alta = Divisao.comFaixa(1600, 720, lado, f, hF, previaEscondida = false, m = a07)
                val caso = "lado=$lado f=$f faixa=$hF → $alta"
                assertEquals("texto mudou com a faixa: $caso", baixa.texto, alta.texto)
                assertEquals("prévia mudou com a faixa: $caso", baixa.previa, alta.previa)
                assertFalse("a faixa cobre o texto: $caso", alta.faixa.cruza(alta.texto))
                assertFalse("a faixa cobre a prévia: $caso", alta.faixa.cruza(alta.previa))
                assertTrue("a faixa passou da banda: $caso", alta.faixa.altura <= 720 - alta.texto.altura)
                assertEquals("a coluna não ficou à direita: $caso", 1600, alta.faixa.direita)
                assertEquals("a coluna não tem 340 dp: $caso", a07.colunaLadoALado, alta.faixa.largura)
                // Encostada no pé (texto em cima) ou no alto (texto embaixo).
                if (lado == Lado.TOPO) assertEquals(720, alta.faixa.baixo) else assertEquals(0, alta.faixa.topo)
            }
        }
        // Numa tela larga e estreita, a coluna fica com metade dela, no máximo.
        val estreita = Divisao.comFaixa(1000, 700, Lado.TOPO, 0.5, 200, previaEscondida = false, m = a07)
        assertEquals(500, estreita.faixa.largura)
        assertEquals(500, estreita.previa.largura)
    }

    /**
     * Deitado, **a zona da borda** fica só sobre a prévia: nunca sobre a faixa, nem sobre o texto — no
     * celular (a faixa ao lado) e no tablet (a faixa no pé).
     */
    @Test
    fun deitado_a_zona_fica_so_sobre_a_previa_e_nunca_sobre_a_faixa() {
        for ((larg, alt, med) in listOf(Triple(1600, 720, a07), Triple(1920, 1200, tablet))) {
            for (lado in listOf(Lado.TOPO, Lado.BAIXO)) for (f in listOf(0.2, 0.35, 0.5, 0.65, 0.8))
                for (hF in listOf(0, 60, 281, 500, 2000)) {
                    val p = Divisao.comFaixa(larg, alt, lado, f, hF, previaEscondida = false, m = med)
                    val caso = "${larg}x$alt lado=$lado f=$f faixa=$hF → $p"
                    val aoLado = Divisao.faixaAoLadoDaPrevia(lado, larg, alt, med)
                    // Com a faixa no pé (o tablet), a faixa alta demais leva a prévia a zero, e a zona some.
                    val z = p.zona ?: run {
                        assertFalse("sem zona com a faixa ao lado: $caso", aoLado)
                        assertTrue("sem zona com prévia: $caso", p.previa.vazio)
                        null
                    } ?: continue
                    assertEquals("a zona fora da prévia: $caso", z, z.intersecao(p.previa))
                    assertFalse("a zona entra na faixa: $caso", z.cruza(p.faixa))
                    assertFalse("a zona entra no texto: $caso", z.cruza(p.texto))
                    // Nem sobre o vão da coluna acima (ou abaixo) da faixa: a zona para onde a prévia para.
                    if (aoLado) {
                        assertTrue("a zona passa da prévia: $caso", z.direita <= larg - p.faixa.largura)
                    } else {
                        assertEquals("a faixa do tablet não ficou na largura toda: $caso", larg, p.faixa.largura)
                    }
                }
        }
    }

    @Test
    fun meio_a_meio_em_retrato_com_o_texto_em_cima_e_a_faixa_no_pe() {
        val p = Divisao.comFaixa(1080, 2340, Lado.TOPO, 0.5, 300, previaEscondida = false, m = m)
        assertEquals(Retangulo(0, 0, 1080, 1170), p.texto)
        assertEquals(Retangulo(0, 1170, 1080, 2040), p.previa)
        assertEquals(Retangulo(0, 2040, 1080, 2340), p.faixa)
        // A zona inteira do lado da prévia, encostada na linha; a alça na ponta de cima dela.
        assertEquals(Retangulo(0, 1170, 1080, 1214), p.zona)
        assertEquals(Lado.TOPO, p.ponta)
    }

    @Test
    fun lado_a_lado_a_faixa_mora_no_pe_da_coluna_da_previa() {
        // "À direita" escolhido no ajuste: o texto à direita, a coluna da prévia à esquerda.
        val p = Divisao.comFaixa(2340, 1080, Lado.DIREITA, 0.5, 200, previaEscondida = false, m = m)
        assertEquals(Retangulo(1170, 0, 2340, 1080), p.texto)
        assertEquals(Retangulo(0, 0, 1170, 880), p.previa)
        assertEquals(Retangulo(0, 880, 1170, 1080), p.faixa)
        assertEquals(Retangulo(1126, 0, 1170, 880), p.zona)
        assertEquals(Lado.DIREITA, p.ponta)
    }

    @Test
    fun a_faixa_que_cresce_encolhe_a_previa_e_nao_mexe_no_texto() {
        for (lado in Lado.entries) {
            val emPe = Divisao.empilhado(lado)
            val w = if (emPe) 1080 else 2340
            val h = if (emPe) 2340 else 1080
            val baixa = Divisao.comFaixa(w, h, lado, 0.45, 120, previaEscondida = false, m = m)
            val alta = Divisao.comFaixa(w, h, lado, 0.45, 420, previaEscondida = false, m = m)
            assertEquals("texto mudou com a faixa ($lado)", baixa.texto, alta.texto)
            assertTrue("a prévia não encolheu ($lado)", alta.previa.altura < baixa.previa.altura)
        }
    }

    @Test
    fun o_teto_da_fracao_deixa_a_previa_minima_e_a_reserva_da_faixa() {
        // 1000 px de altura: precisa de 120 + 150 → o texto vai no máximo a 73 %.
        val p = Divisao.comFaixa(600, 1000, Lado.TOPO, 0.8, 100, previaEscondida = false, m = m)
        assertEquals(0.73, p.fracao, 1e-9)
        assertEquals(730, p.texto.altura)
        // Numa tela estreita demais o teto não fica abaixo do mínimo.
        val q = Divisao.comFaixa(300, 600, Lado.ESQUERDA, 0.7, 100, previaEscondida = false, m = m)
        assertEquals(Divisao.MINIMO, q.fracao, 1e-9)
    }

    /**
     * **A regra**, por varredura: nas quatro rotações com o texto no automático, com a borda em
     * qualquer ponto, a faixa baixa ou alta, a prévia à mostra ou escondida —
     *
     * - a faixa nunca cobre a lente nem cruza o texto; e, quando o texto está do lado da lente (em pé e
     *   de ponta-cabeça), nem toca a borda dela;
     * - a zona da borda nunca entra no texto (as setas azuis ficam dele) nem na faixa, e fica dentro da
     *   prévia;
     * - texto, prévia e faixa não se cobrem.
     */
    @Test
    fun nada_entre_o_texto_e_a_lente_e_a_zona_nunca_entra_no_texto() {
        for (rot in 0..3) for (escondida in listOf(false, true))
            for (f in listOf(0.2, 0.35, 0.5, 0.65, 0.8)) for (hF in listOf(0, 60, 200, 400)) {
                val emPe = rot % 2 == 0
                val w = if (emPe) 1080 else 2340
                val h = if (emPe) 2340 else 1080
                val lado = Divisao.ladoDoTexto(rot, Escolha.AUTOMATICO)
                val p = Divisao.comFaixa(w, h, lado, f, hF, escondida, m)
                val caso = "rot=$rot escondida=$escondida f=$f faixa=$hF → $p"
                if (hF > 0) {
                    // A lente: o meio da borda dela (um quinto do comprimento, 20 px de fundo).
                    val lente = when (Divisao.ladoDaLente(rot)) {
                        Lado.TOPO -> Retangulo(w * 2 / 5, 0, w * 3 / 5, 20)
                        Lado.BAIXO -> Retangulo(w * 2 / 5, h - 20, w * 3 / 5, h)
                        Lado.ESQUERDA -> Retangulo(0, h * 2 / 5, 20, h * 3 / 5)
                        Lado.DIREITA -> Retangulo(w - 20, h * 2 / 5, w, h * 3 / 5)
                    }
                    assertFalse("a faixa cobre a lente: $caso", p.faixa.cruza(lente))
                    // Deitado (desde 30/09) o texto fica em cima, e a lente na borda do lado: a coluna
                    // da faixa encosta na borda da direita, mas no pé, longe do meio dela (onde a lente
                    // está) — o `cruza(lente)` de cima confere.
                    if (!escondida && lado == Divisao.ladoDaLente(rot)) {
                        // Com a prévia à mostra, a faixa nem toca a borda da lente.
                        val encosta = when (Divisao.ladoDaLente(rot)) {
                            Lado.TOPO -> p.faixa.topo <= 0
                            Lado.BAIXO -> p.faixa.baixo >= h
                            Lado.ESQUERDA -> p.faixa.esquerda <= 0
                            Lado.DIREITA -> p.faixa.direita >= w
                        }
                        assertFalse("a faixa encosta na borda da lente: $caso", encosta)
                    }
                    assertFalse("a faixa cruza o texto: $caso", p.faixa.cruza(p.texto))
                }
                if (escondida) {
                    assertNull("zona com a prévia escondida: $caso", p.zona)
                    continue
                }
                assertFalse("a prévia cruza o texto: $caso", p.previa.cruza(p.texto))
                assertFalse("a prévia cruza a faixa: $caso", p.previa.cruza(p.faixa))
                val z = p.zona ?: continue
                assertFalse("a zona entra no texto: $caso", z.cruza(p.texto))
                assertFalse("a zona entra na faixa: $caso", z.cruza(p.faixa))
                assertEquals("a zona fora da prévia: $caso", z, z.intersecao(p.previa))
            }
    }

    /**
     * A revisão do código de 28/09: com a borda no teto numa tela baixa e a lista de avisos aberta, a
     * faixa pedia mais que a sobra e passava por cima das últimas linhas do texto. Agora ela fica com
     * a sobra, no máximo, e a prévia vai a zero antes. As medidas a 3 px por dp, como num celular.
     */
    @Test
    fun a_faixa_alta_demais_nunca_cobre_o_texto() {
        val m3 = Divisao.Medidas(previaMinima = 360, reservaDaFaixa = 450, colunaLadoALado = 1020, espessuraDaZona = 132)
        for (lado in listOf(Lado.TOPO, Lado.BAIXO)) for (hF in listOf(800, 1200, 3000)) {
            val p = Divisao.comFaixa(1080, 2340, lado, 0.8, hF, previaEscondida = false, m = m3)
            val caso = "lado=$lado faixa=$hF → $p"
            assertFalse("a faixa cobre o texto: $caso", p.faixa.cruza(p.texto))
            assertTrue("a faixa passou da sobra: $caso", p.faixa.altura <= 2340 - p.texto.altura)
        }
    }

    @Test
    fun o_teto_vem_na_conta_para_o_arrasto_nao_passar_dele() {
        val p = Divisao.comFaixa(600, 1000, Lado.TOPO, 0.5, 100, previaEscondida = false, m = m)
        assertEquals(0.73, p.teto, 1e-9)
    }

    @Test
    fun com_a_previa_escondida_o_texto_fica_com_tudo_menos_a_faixa() {
        val p = Divisao.comFaixa(1080, 2340, Lado.TOPO, 0.5, 300, previaEscondida = true, m = m)
        assertEquals(Retangulo(0, 0, 1080, 2040), p.texto)
        assertEquals(Retangulo(0, 2040, 1080, 2340), p.faixa)
        // A moldura da prévia não muda: só a vista some.
        assertEquals(Retangulo(0, 1170, 1080, 2040), p.previa)
        // De ponta-cabeça (texto embaixo), a faixa no alto.
        val q = Divisao.comFaixa(1080, 2340, Lado.BAIXO, 0.5, 300, previaEscondida = true, m = m)
        assertEquals(Retangulo(0, 0, 1080, 300), q.faixa)
        assertEquals(Retangulo(0, 300, 1080, 2340), q.texto)
    }

    @Test
    fun o_arrasto_anda_pelo_deslocamento_e_nao_passa_dos_limites() {
        assertEquals(0.2, Divisao.limitar(0.05), 1e-12)
        assertEquals(0.8, Divisao.limitar(0.99), 1e-12)
        assertEquals(0.5, Divisao.limitar(Double.NaN), 1e-12)
        // Texto em cima: descer o dedo 234 px num eixo de 2340 dá 10 % a mais de texto.
        assertEquals(0.6, Divisao.fracaoArrastada(Lado.TOPO, 0.5, 0f, 234f, 2340), 1e-9)
        // Texto embaixo: descer o dedo dá menos texto.
        assertEquals(0.4, Divisao.fracaoArrastada(Lado.BAIXO, 0.5, 0f, 234f, 2340), 1e-9)
        assertEquals(0.4, Divisao.fracaoArrastada(Lado.DIREITA, 0.5, 234f, 0f, 2340), 1e-9)
        assertEquals(0.8, Divisao.fracaoArrastada(Lado.ESQUERDA, 0.5, 2000f, 0f, 2340), 1e-9)
    }

    @Test
    fun a_zona_some_sem_previa() {
        assertNull(Divisao.zona(Retangulo(0, 0, 100, 100), Retangulo(0, 100, 100, 100), 44))
        assertNotNull(Divisao.zona(Retangulo(0, 0, 100, 100), Retangulo(0, 100, 100, 120), 44))
        // Uma prévia mais baixa que a zona: a zona é a prévia inteira, e não passa dela.
        assertEquals(Retangulo(0, 100, 100, 120), Divisao.zona(Retangulo(0, 0, 100, 100), Retangulo(0, 100, 100, 120), 44))
    }
}
