// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.teleprompter

import com.quall.android.core.TextosDeTeste.Companion.PT
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.core.QuallNative.Status
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * O que cada lado faz depois de cada falha — a regra do §2 ("Quando o controle cai", passo 3).
 */
class PoliticasTest {

    private fun prompter(st: Int, ms: Long = 5_000, falhas: Int = 0) =
        PoliticaDoPrompter.depoisDaEspera(st, ms, falhas, "motivo", 7979, PT)

    /** Depois de erro de PIN numa espera, o PIN é trocado: repeti-lo abriria força bruta (§2). */
    @Test
    fun erro_de_pin_troca_o_pin_e_espera_um_segundo() {
        val esperado = PoliticaDoPrompter.Depois.PinNovo(PoliticaDoPrompter.PAUSA_DEPOIS_DE_PIN_ERRADO_MS)
        assertEquals(esperado, prompter(Status.WRONG_PIN))
        assertEquals(esperado, prompter(Status.PAIRING))
        // Mesmo que o erro volte depressa: a regra é do PIN, não do relógio.
        assertEquals(esperado, prompter(Status.WRONG_PIN, ms = 30))
        assertEquals(1_000L, esperado.pausaMs)
    }

    /** O prazo da espera, a recusa por versão e as quedas: mesmo PIN, sem contar para desistir. */
    @Test
    fun prazo_e_versao_mantem_o_pin() {
        assertEquals(PoliticaDoPrompter.Depois.MesmoPin(0, false), prompter(Status.TIMEOUT, ms = 300_000))
        assertEquals(PoliticaDoPrompter.Depois.MesmoPin(PoliticaDoPrompter.PAUSA_DEPOIS_DE_RECUSA_MS, false),
            prompter(Status.PROTOCOL))
        assertEquals(PoliticaDoPrompter.Depois.MesmoPin(PoliticaDoPrompter.PAUSA_DEPOIS_DE_RECUSA_MS, false),
            prompter(Status.IO, ms = 5_000))
    }

    /**
     * **O achado da revisão de 13/09**: um aparelho da LAN que manda um `Hello` de outra versão
     * assim que a porta abre faz a espera voltar com `PROTOCOL` em milissegundos. Isso é decisão
     * de um candidato, não porta ocupada — não conta para desistir, nem na 100ª vez.
     */
    @Test
    fun recusa_rapida_de_candidato_nunca_faz_o_prompter_desistir() {
        for (falhas in listOf(0, 7, 100)) {
            val d = prompter(Status.PROTOCOL, ms = 3, falhas = falhas)
            assertEquals(PoliticaDoPrompter.Depois.MesmoPin(PoliticaDoPrompter.PAUSA_DEPOIS_DE_RECUSA_MS, false), d)
        }
    }

    /** A porta ocupada por um instante (a sessão velha soltando o `bind`) merece insistência — com teto. */
    @Test
    fun falha_imediata_da_porta_insiste_e_depois_desiste() {
        val limite = PoliticaDoPrompter.FALHAS_IMEDIATAS_ATE_DESISTIR
        assertEquals(PoliticaDoPrompter.Depois.MesmoPin(PoliticaDoPrompter.PAUSA_DEPOIS_DE_FALHA_MS, true),
            prompter(Status.IO, ms = 10, falhas = limite - 2))
        val d = prompter(Status.IO, ms = 10, falhas = limite - 1)
        assertTrue(d is PoliticaDoPrompter.Depois.Desistir)
        assertTrue((d as PoliticaDoPrompter.Depois.Desistir).mensagem.contains("7979"))
    }

    @Test
    fun erro_de_configuracao_desiste_na_hora() {
        assertTrue(prompter(Status.INVALID) is PoliticaDoPrompter.Depois.Desistir)
    }

    private fun controle(st: Int, jaConectou: Boolean) =
        PoliticaDoControle.depoisDaFalha(st, jaConectou, "motivo", "192.168.57.8:7979", PT)

    /** "Ocupado" nunca é queda: tenta de novo em ~1 s, na primeira vez e na volta. */
    @Test
    fun ocupado_tenta_de_novo_a_cada_segundo() {
        for (ja in listOf(false, true)) {
            val d = controle(Status.BUSY, ja)
            assertTrue(d is PoliticaDoControle.Depois.TentarDeNovo)
            assertEquals(PoliticaDoControle.INTERVALO_MS, (d as PoliticaDoControle.Depois.TentarDeNovo).esperaMs)
        }
    }

    /** Depois de ter entrado, toda falha de rede é "ele está voltando": insiste. */
    @Test
    fun depois_de_ter_entrado_a_rede_que_falha_e_tentar_de_novo() {
        for (st in listOf(Status.IO, Status.TIMEOUT, Status.NO_ROUTE, Status.SIGNALING, Status.TRANSPORT, Status.CLOSED)) {
            assertTrue("status $st", controle(st, jaConectou = true) is PoliticaDoControle.Depois.TentarDeNovo)
        }
    }

    /** Na primeira conexão a mesma falha é quase sempre endereço errado: diz, em vez de insistir. */
    @Test
    fun na_primeira_conexao_a_rede_que_falha_e_mensagem() {
        for (st in listOf(Status.IO, Status.TIMEOUT, Status.NO_ROUTE)) {
            assertTrue("status $st", controle(st, jaConectou = false) is PoliticaDoControle.Depois.Desistir)
        }
    }

    @Test
    fun pin_esquecido_ou_errado_pede_o_pin() {
        for (st in listOf(Status.NEEDS_PIN, Status.WRONG_PIN, Status.PAIRING)) {
            for (ja in listOf(false, true)) {
                assertTrue("status $st", controle(st, ja) is PoliticaDoControle.Depois.PedirPin)
            }
        }
    }

    /** Um aparelho que não é teleprompter (ou de outra versão) não vira insistência infinita. */
    @Test
    fun nao_teleprompter_desiste() {
        assertTrue(controle(Status.PROTOCOL, false) is PoliticaDoControle.Depois.Desistir)
        assertTrue(controle(Status.PROTOCOL, true) is PoliticaDoControle.Depois.Desistir)
    }

    /** As mensagens, nos dois idiomas: a porta e o endereço entram no lugar (`docs/traducao.md`, Android). */
    @Test
    fun as_mensagens_nos_dois_idiomas() {
        val limite = PoliticaDoPrompter.FALHAS_IMEDIATAS_ATE_DESISTIR
        assertEquals(PoliticaDoPrompter.Depois.Desistir("não consegui abrir a porta 7979: motivo"),
            PoliticaDoPrompter.depoisDaEspera(Status.IO, 10, limite - 1, "motivo", 7979, PT))
        assertEquals(PoliticaDoPrompter.Depois.Desistir("couldn’t open port 7979: motivo"),
            PoliticaDoPrompter.depoisDaEspera(Status.IO, 10, limite - 1, "motivo", 7979, EN))
        assertEquals(PoliticaDoControle.Depois.Desistir("192.168.57.8:7979 não respondeu a tempo. O teleprompter está aberto, esperando?"),
            controle(Status.TIMEOUT, jaConectou = false))
        assertEquals(PoliticaDoControle.Depois.TentarDeNovo(PoliticaDoControle.INTERVALO_MS, "Trying to reconnect…"),
            PoliticaDoControle.depoisDaFalha(Status.IO, true, "motivo", "x:7979", EN))
    }
}
