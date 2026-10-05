// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.teleprompter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A regra de porta das quatro cascas (13/09): o prompter na 7979 por padrão, o controle completando
 * só o host com 7979 — nunca com a 7877 do vídeo —, e a leitura tolerante de um
 * `quall://<pin>@<host>:<porta>` colado (nenhuma tela o mostra desde 24/09; ler continua).
 */
class EnderecoDoTeleprompterTest {

    private fun d(t: String) = EnderecoDoTeleprompter.doControle(t)

    @Test
    fun so_o_ip_ganha_a_porta_do_teleprompter_e_nao_a_do_video() {
        assertEquals("192.168.57.8:7979", d("192.168.57.8")!!.endpoint)
        assertEquals("192.168.57.8:7979", d("  192.168.57.8  ")!!.endpoint)
        assertEquals("quall-944d0e.local:7979", d("quall-944d0e.local")!!.endpoint)
    }

    @Test
    fun a_porta_digitada_fica() {
        assertEquals("192.168.57.8:8000", d("192.168.57.8:8000")!!.endpoint)
        assertEquals("192.168.57.8:7877", d("192.168.57.8:7877")!!.endpoint)
    }

    @Test
    fun ipv6_vai_entre_colchetes() {
        assertEquals("[2804:1b1:fec0:1458::1]:7979", d("2804:1b1:fec0:1458::1")!!.endpoint)
        assertEquals("[fe80::1]:7979", d("[fe80::1]")!!.endpoint)
        assertEquals("[fe80::1]:8000", d("[fe80::1]:8000")!!.endpoint)
    }

    @Test
    fun o_link_colado_traz_o_pin_e_a_porta() {
        val x = d("quall://424242@192.168.57.8:7979")!!
        assertEquals("192.168.57.8:7979", x.endpoint)
        assertEquals("424242", x.pin)
        // Link sem porta (de uma casca antiga): completa com a do teleprompter.
        assertEquals("192.168.57.8:7979", d("QUALL://424242@192.168.57.8/")!!.endpoint)
        // PIN que não é de seis dígitos não vira PIN.
        assertNull(d("quall://12@192.168.57.8:7979")!!.pin)
        assertNull(d("quall://192.168.57.8:7979")!!.pin)
        // IPv6 entre colchetes, como as cascas antigas escreviam.
        val v6 = d("quall://123456@[fe80::1]:7980")!!
        assertEquals("[fe80::1]:7980", v6.endpoint)
        assertEquals("123456", v6.pin)
    }

    @Test
    fun o_que_nao_se_entende_e_nulo() {
        assertNull(d(""))
        assertNull(d("   "))
        assertNull(d("192.168.57.8:0"))
        assertNull(d("192.168.57.8:70000"))
        assertNull(d("192.168.57.8:abc"))
        assertNull(d(":7979"))
        assertNull(d("quall://424242@"))
        assertNull(d("[fe80::1"))
    }

    @Test
    fun a_porta_ocupada_da_lugar_a_proxima_livre() {
        assertEquals(7979, EnderecoDoTeleprompter.escolherPorta(7979) { true })
        assertEquals(7981, EnderecoDoTeleprompter.escolherPorta(7979) { it >= 7981 })
        // Nenhuma livre: fica a preferida, e o núcleo diz por que não abriu.
        assertEquals(7979, EnderecoDoTeleprompter.escolherPorta(7979) { false })
        assertEquals(7979, EnderecoDoTeleprompter.PORTA_PADRAO)
    }
}
