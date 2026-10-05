package com.quall.android.teleprompter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * O estado que as duas telas leem, contra o JSON **literal** do contrato
 * (`docs/contrato-teleprompter.md` §6) — e o leitor de JSON que o lê sem o `org.json` do Android.
 */
class EstadoDoTeleprompterTest {

    /** O literal do §6, com os contadores inteiros. */
    private val literal = """
        {"rolando":false,"velocidade":1.0,"fonte":48.0,"margem":0.1,"linha_de_leitura":0.3,
         "espelho":false,"posicao":0.0,"salto":null,"texto_bytes":0,"par_visto_ha_ms":null,
         "sem_confirmacao_ha_ms":null,"contadores":{"estados_enviados":0,"textos_enviados":0,
         "recebidas":0,"invalidas":0,"de_outro_app":0,"de_outra_versao":0,"campos_recusados":0,
         "carimbos_do_futuro":0,"mensagens_impossiveis":0,"reenvios_desistidos":0}}
    """.trimIndent()

    @Test
    fun o_literal_do_contrato_e_o_padrao() {
        val e = EstadoDoTeleprompter.ler(literal)!!
        assertEquals(EstadoDoTeleprompter(contadores = e.contadores), e)
        assertEquals(10, e.contadores.size)
        assertNull(e.salto)
        assertNull(e.parVistoHaMs)
        assertNull(e.semConfirmacaoHaMs)
    }

    @Test
    fun um_estado_de_sessao_se_le_campo_a_campo() {
        val e = EstadoDoTeleprompter.ler(
            """{"rolando":true,"velocidade":2.9,"fonte":52.0,"margem":0.12,"linha_de_leitura":0.35,
               "espelho":true,"posicao":0.4321,"salto":0.14,"texto_bytes":100000,"par_visto_ha_ms":312,
               "sem_confirmacao_ha_ms":1600,"contadores":{"de_outra_versao":2}}"""
        )!!
        assertTrue(e.rolando)
        assertEquals(2.9, e.velocidade, 0.0)
        assertEquals(52.0, e.fonte, 0.0)
        assertEquals(0.12, e.margem, 0.0)
        assertEquals(0.35, e.linhaDeLeitura, 0.0)
        assertTrue(e.espelho)
        assertEquals(0.4321, e.posicao, 0.0)
        assertEquals(0.14, e.salto!!, 0.0)
        assertEquals(100_000L, e.textoBytes)
        assertEquals(312L, e.parVistoHaMs)
        assertEquals(1600L, e.semConfirmacaoHaMs)
        assertEquals(2L, e.contador("de_outra_versao"))
        assertEquals(0L, e.contador("nao_existe"))
    }

    /** Campo de tipo errado cai no padrão — nunca derruba a leitura inteira (a regra do núcleo). */
    @Test
    fun campo_de_tipo_errado_cai_no_padrao_e_o_resto_entra() {
        val e = EstadoDoTeleprompter.ler("""{"rolando":"sim","velocidade":null,"fonte":60,"espelho":1}""")!!
        assertFalse(e.rolando)
        assertEquals(1.0, e.velocidade, 0.0)
        assertEquals(60.0, e.fonte, 0.0)
        assertFalse(e.espelho)
    }

    @Test
    fun o_que_nao_e_objeto_nao_e_estado() {
        assertNull(EstadoDoTeleprompter.ler(""))
        assertNull(EstadoDoTeleprompter.ler("[]"))
        assertNull(EstadoDoTeleprompter.ler("{\"rolando\":tru"))
        assertNull(EstadoDoTeleprompter.ler("{} lixo"))
    }

    @Test
    fun o_leitor_de_json_le_escapes_numeros_e_listas() {
        @Suppress("UNCHECKED_CAST")
        val o = JsonSimples.ler("""{"a":"ação \"x\"\nç 🎬","n":-1.5e2,"l":[1,true,null,{"b":[]}]}""") as Map<String, Any?>
        assertEquals("ação \"x\"\nç 🎬", o["a"])
        assertEquals(-150.0, o["n"] as Double, 0.0)
        val l = o["l"] as List<*>
        assertEquals(4, l.size)
        assertEquals(1.0, l[0])
        assertEquals(true, l[1])
        assertNull(l[2])
        assertEquals(mapOf("b" to emptyList<Any?>()), l[3])
    }

    /** O mesmo resumo do núcleo (`teleprompter::resumo`): 8 bytes do SHA-256, em hex. */
    @Test
    fun o_resumo_e_o_do_nucleo() {
        assertEquals("e3b0c44298fc1c14", Resumo.de(""))
        assertEquals("f08d42c4e869f8ec", Resumo.de("Boa noite."))
        assertEquals("773e2f864b35825b", Resumo.de("ação 🎬"))
    }

    /** As quatro chaves da gravação (§13.7), literais, e o `n` de Lamport inteiro no `Double`. */
    @Test
    fun a_gravacao_do_contrato_se_le_campo_a_campo() {
        val parado = EstadoDoTeleprompter.ler(
            """{"rolando":false,"gravando_ha_ms":null,"pedido_de_gravacao":null,"gravacao_recusada":null,"par_entende_gravar":false}"""
        )!!
        assertNull(parado.gravandoHaMs)
        assertNull(parado.pedidoDeGravacao)
        assertNull(parado.gravacaoRecusada)
        assertFalse(parado.parEntendeGravar)
        val e = EstadoDoTeleprompter.ler(
            """{"gravando_ha_ms":5000,"pedido_de_gravacao":{"n":1790272721890,"gravar":true,"ha_ms":12},
               "gravacao_recusada":{"n":1790272721889,"gravar":true,"motivo":"sem espaço: sobram 312 MB"},
               "par_entende_gravar":true}"""
        )!!
        assertEquals(5000L, e.gravandoHaMs)
        assertEquals(EstadoDoTeleprompter.PedidoDeGravacao(1790272721890, true, 12), e.pedidoDeGravacao)
        assertEquals("sem espaço: sobram 312 MB", e.gravacaoRecusada!!.motivo)
        assertEquals(1790272721889L, e.gravacaoRecusada!!.n)
        assertTrue(e.parEntendeGravar)
    }
}
