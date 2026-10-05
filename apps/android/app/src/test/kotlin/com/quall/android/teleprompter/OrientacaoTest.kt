package com.quall.android.teleprompter

import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.core.TextosDeTeste.Companion.EN
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A orientação do prompter: os nomes literais, o valor que vai para a janela, e a chave guardada. */
class OrientacaoTest {

    @Test
    fun os_quatro_nomes_sao_os_literais_e_o_padrao_e_automatica() {
        assertEquals(
            listOf("Automática", "Retrato", "Paisagem", "Paisagem invertida"),
            Orientacao.entries.map { it.nome },
        )
        // Na tela, o rótulo: o mesmo nome em português, e o inglês.
        assertEquals(Orientacao.entries.map { it.nome }, Orientacao.entries.map { PT.s(it.rotulo) })
        assertEquals(listOf("Auto", "Portrait", "Landscape", "Reverse landscape"), Orientacao.entries.map { EN.s(it.rotulo) })
        assertEquals(Orientacao.AUTOMATICA, Orientacao.PADRAO)
    }

    @Test
    fun cada_uma_trava_a_janela_no_valor_do_android() {
        // Os números da documentação de `ActivityInfo`, escritos à mão: se alguém trocar a
        // constante de uma entrada, a paisagem sai de cabeça para baixo — e só no suporte.
        assertEquals(-1, Orientacao.AUTOMATICA.valorDoAndroid) // UNSPECIFIED: o sensor decide
        assertEquals(1, Orientacao.RETRATO.valorDoAndroid) // PORTRAIT
        assertEquals(0, Orientacao.PAISAGEM.valorDoAndroid) // LANDSCAPE: o topo à esquerda
        assertEquals(8, Orientacao.PAISAGEM_INVERTIDA.valorDoAndroid) // REVERSE_LANDSCAPE: o topo à direita
    }

    @Test
    fun le_a_chave_e_o_nome_sem_ligar_para_acento_caixa_ou_hifen() {
        assertEquals(Orientacao.PAISAGEM, Orientacao.daChave("paisagem"))
        assertEquals(Orientacao.PAISAGEM_INVERTIDA, Orientacao.daChave("paisagem_invertida"))
        assertEquals(Orientacao.PAISAGEM_INVERTIDA, Orientacao.daChave("Paisagem invertida"))
        assertEquals(Orientacao.PAISAGEM_INVERTIDA, Orientacao.daChave("paisagem-invertida"))
        assertEquals(Orientacao.AUTOMATICA, Orientacao.daChave("Automática"))
        assertEquals(Orientacao.AUTOMATICA, Orientacao.daChave("AUTOMATICA"))
        assertEquals(Orientacao.RETRATO, Orientacao.daChave("  retrato "))
        // A chave de cada uma volta ela mesma: é o que vai para as preferências.
        for (o in Orientacao.entries) assertEquals(o, Orientacao.daChave(o.chave))
    }

    @Test
    fun o_que_nao_se_entende_nao_vira_orientacao() {
        assertNull(Orientacao.daChave(null))
        assertNull(Orientacao.daChave(""))
        assertNull(Orientacao.daChave("landscape"))
        assertNull(Orientacao.daChave("paisagem2"))
        // Guardado ilegível (uma versão futura, um arquivo mexido): vale a automática.
        assertEquals(Orientacao.AUTOMATICA, Orientacao.doGuardado("deitado"))
        assertEquals(Orientacao.AUTOMATICA, Orientacao.doGuardado(null))
        assertEquals(Orientacao.PAISAGEM, Orientacao.doGuardado("paisagem"))
    }
}
