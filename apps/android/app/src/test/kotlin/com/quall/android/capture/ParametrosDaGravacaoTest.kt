package com.quall.android.capture

import com.quall.android.capture.ParametrosDaGravacao.Perfil
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** [ParametrosDaGravacao]: as contas da gravação local da tela R5 (§5.1). Na JVM. */
class ParametrosDaGravacaoTest {

    @Test
    fun a_taxa_e_a_regra_de_1080p30_a_14_mbit_escalada_pela_area_e_pelo_fps() {
        // 1080p30, em pé ou deitado: a referência (a faixa do Pessoa Exemplo, 12–16 Mbit/s).
        assertEquals(14_000_000, ParametrosDaGravacao.taxa(emptyList(), 1920, 1080, 30).first)
        assertEquals(14_000_000, ParametrosDaGravacao.taxa(emptyList(), 1080, 1920, 30).first)
        // Pela área: 720p30 é 4/9 dos pixels; 4K30, 4×.
        assertEquals(6_222_222, ParametrosDaGravacao.taxa(emptyList(), 1280, 720, 30).first)
        assertEquals(56_000_000, ParametrosDaGravacao.taxa(emptyList(), 3840, 2160, 30).first)
        // Pelo fps: dobrar custa 1,5×.
        val t60 = ParametrosDaGravacao.taxa(emptyList(), 1920, 1080, 60).first
        assertTrue("1080p60 = $t60", t60 in 20_900_000..21_100_000)
        // O piso e o teto.
        assertEquals(ParametrosDaGravacao.TAXA_MINIMA, ParametrosDaGravacao.taxa(emptyList(), 320, 240, 15).first)
        assertEquals(ParametrosDaGravacao.TAXA_MAXIMA, ParametrosDaGravacao.taxa(emptyList(), 3840, 2160, 60).first)
    }

    @Test
    fun o_defeito_do_a07_o_perfil_de_720p_escalado_nao_infla_mais_a_taxa() {
        // A prova de 24/09: o A07 declara 720p30 a 9 Mbit/s, e a gravação em 1080x1920 saiu a
        // 20 250 kbit/s ("perfil mais perto, escalado") — 1,5 GB em 10 min.
        val a07 = listOf(Perfil(1280, 720, 30, 9_000_000), Perfil(640, 480, 30, 3_000_000))
        val (t, deOnde) = ParametrosDaGravacao.taxa(a07, 1080, 1920, 30)
        assertEquals(14_000_000, t)
        assertTrue(deOnde, deOnde.startsWith("regra"))
        // 10 min a 14 Mbit/s + o som: ~1,06 GB, e não 1,5.
        assertTrue((t.toLong() + 96_000) * 600 / 8 < 1_100_000_000L)
    }

    @Test
    fun o_perfil_do_mesmo_tamanho_so_entra_como_teto() {
        // O S24 declara 1080p30 a 17 Mbit/s: acima da regra, não sobe.
        val s24 = listOf(Perfil(1920, 1080, 30, 17_000_000))
        assertEquals(14_000_000, ParametrosDaGravacao.taxa(s24, 1080, 1920, 30).first)
        // Um aparelho que declara menos no tamanho exato: vale o dele, ajustado ao fps.
        val modesto = listOf(Perfil(1920, 1080, 30, 12_000_000), Perfil(1280, 720, 30, 20_000_000))
        val (t, deOnde) = ParametrosDaGravacao.taxa(modesto, 1920, 1080, 30)
        assertEquals(12_000_000, t)
        assertTrue(deOnde, deOnde.contains("abaixo da regra"))
        val t60 = ParametrosDaGravacao.taxa(modesto, 1920, 1080, 60).first
        assertTrue("$t60", t60 in 17_900_000..18_100_000)
        // Perfil inválido não conta.
        assertEquals(14_000_000, ParametrosDaGravacao.taxa(listOf(Perfil(0, 0, 0, 0)), 1920, 1080, 30).first)
    }

    @Test
    fun o_nivel_minimo_pela_tabela_da_norma() {
        assertEquals(31, ParametrosDaGravacao.nivelMinimo(1280, 720, 30))
        assertEquals(40, ParametrosDaGravacao.nivelMinimo(1920, 1080, 30))
        assertEquals(40, ParametrosDaGravacao.nivelMinimo(1080, 1920, 30))
        assertEquals(42, ParametrosDaGravacao.nivelMinimo(1920, 1080, 60))
        assertEquals(51, ParametrosDaGravacao.nivelMinimo(3840, 2160, 30))
        assertNull(ParametrosDaGravacao.nivelMinimo(7680, 4320, 30))
    }

    @Test
    fun o_tamanho_recusado_desce_na_mesma_proporcao_e_par() {
        assertEquals(1080 to 1920, ParametrosDaGravacao.tamanhoAceito(1080, 1920) { _, _ -> true })
        val t = ParametrosDaGravacao.tamanhoAceito(1080, 1920) { w, h -> h <= 1440 }!!
        assertEquals(810 to 1440, t)
        assertTrue(t.first % 2 == 0 && t.second % 2 == 0)
        assertNull(ParametrosDaGravacao.tamanhoAceito(1080, 1920) { _, _ -> false })
    }

    @Test
    fun o_tempo_em_90k_e_a_duracao_de_cada_quadro() {
        assertEquals(3000L, ParametrosDaGravacao.us90k(33_333))
        assertEquals(90_000L, ParametrosDaGravacao.us90k(1_000_000))
        assertEquals(1_000_000L, ParametrosDaGravacao.de90kUs(90_000))
        // Até o próximo; sem o próximo, a do anterior; sem os dois, a do fps.
        assertEquals(3600L, ParametrosDaGravacao.duracao(1000, 4600, null, 30))
        assertEquals(3000L, ParametrosDaGravacao.duracao(1000, null, 3000, 30))
        assertEquals(1500L, ParametrosDaGravacao.duracao(0, null, null, 60))
        // Um carimbo repetido nunca dá duração zero.
        assertEquals(1L, ParametrosDaGravacao.duracao(1000, 1000, null, 30))
    }
}
