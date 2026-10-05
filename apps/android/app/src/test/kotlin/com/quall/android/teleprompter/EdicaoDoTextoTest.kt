package com.quall.android.teleprompter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A regra desta tela para o texto que chega do outro lado com o editor aberto (item 3 da F6b): o
 * rascunho **nunca** é apagado sem a pessoa escolher, e o `set_text` só sai ao confirmar.
 */
class EdicaoDoTextoTest {

    @Test
    fun editor_fechado_nao_reage() {
        val e = EdicaoDoTexto()
        assertEquals(EdicaoDoTexto.Reacao.NADA, e.chegou("novo", "qualquer"))
    }

    /** Sem mexer no rascunho, ele acompanha o texto que chegou — não há o que perder. */
    @Test
    fun rascunho_intocado_acompanha_em_silencio() {
        val e = EdicaoDoTexto()
        val r = e.abrir("Boa noite.")
        assertEquals(EdicaoDoTexto.Reacao.TROCAR_O_RASCUNHO, e.chegou("Bom dia.", r))
        assertEquals("Bom dia.", e.base)
        // Confirmar sem mexer: nada a mandar (a réplica já tem o texto).
        assertNull(e.confirmar("Bom dia."))
    }

    /** Com o rascunho mexido, pergunta — e o rascunho fica. */
    @Test
    fun rascunho_mexido_pergunta() {
        val e = EdicaoDoTexto()
        e.abrir("Boa noite.")
        assertEquals(EdicaoDoTexto.Reacao.PERGUNTAR, e.chegou("Bom dia.", "Boa noite, Brasil."))
        assertEquals("Bom dia.", e.chegadoPendente)
        assertEquals("Boa noite.", e.base)
    }

    @Test
    fun usar_o_novo_troca_o_rascunho() {
        val e = EdicaoDoTexto()
        e.abrir("A")
        e.chegou("B", "A editado")
        assertEquals("B", e.aceitarONovo())
        assertNull(e.chegadoPendente)
        assertEquals("B", e.base)
        assertNull(e.aceitarONovo())
    }

    /** "Manter o meu": ao confirmar, o texto daqui sai — é a edição mais recente, vale para os dois. */
    @Test
    fun manter_o_meu_e_confirmar_manda_o_meu() {
        val e = EdicaoDoTexto()
        e.abrir("A")
        e.chegou("B", "A editado")
        e.manterOMeu()
        assertNull(e.chegadoPendente)
        assertEquals("A editado", e.confirmar("A editado"))
        assertFalse(e.aberta)
    }

    /** Depois de "manter o meu", um terceiro texto chegando pergunta de novo. */
    @Test
    fun um_terceiro_texto_pergunta_de_novo() {
        val e = EdicaoDoTexto()
        e.abrir("A")
        e.chegou("B", "A editado")
        e.manterOMeu()
        assertEquals(EdicaoDoTexto.Reacao.PERGUNTAR, e.chegou("C", "A editado"))
        assertEquals("C", e.chegadoPendente)
    }

    /** Os dois lados chegaram ao mesmo texto: nada a perguntar. */
    @Test
    fun coincidencia_nao_pergunta() {
        val e = EdicaoDoTexto()
        e.abrir("A")
        assertEquals(EdicaoDoTexto.Reacao.NADA, e.chegou("AB", "AB"))
        assertNull(e.confirmar("AB"))
    }

    @Test
    fun cancelar_descarta_o_rascunho() {
        val e = EdicaoDoTexto()
        e.abrir("A")
        e.chegou("B", "A editado")
        e.cancelar()
        assertFalse(e.aberta)
        assertNull(e.chegadoPendente)
        assertEquals(EdicaoDoTexto.Reacao.NADA, e.chegou("C", "A editado"))
    }

    /**
     * O editor pergunta o que mandaria **sem fechar**: se o núcleo recusar, a pergunta de um texto
     * que chegou continua de pé (achado 5 da revisão de 13/09).
     */
    @Test
    fun perguntar_o_que_mandaria_nao_fecha_nem_apaga_a_pergunta() {
        val e = EdicaoDoTexto()
        e.abrir("A")
        e.chegou("B", "A editado")
        assertEquals("A editado", e.aMandar("A editado"))
        assertEquals(true, e.aberta)
        assertEquals("B", e.chegadoPendente)
        // O "usar o texto novo" continua funcionando depois da recusa.
        assertEquals("B", e.aceitarONovo())
    }

    /** Voltar só pergunta quando há algo digitado que fechar jogaria fora. */
    @Test
    fun ha_rascunho_so_quando_ele_muda_o_texto() {
        val e = EdicaoDoTexto()
        assertFalse(e.temRascunho("qualquer"))
        e.abrir("A")
        assertFalse(e.temRascunho("A"))
        assertEquals(true, e.temRascunho("A!"))
        assertEquals(true, e.temRascunho(""))
    }

    /** Confirmar um rascunho diferente da base manda; igual não manda nada. */
    @Test
    fun confirmar_so_manda_o_que_mudou() {
        val e = EdicaoDoTexto()
        e.abrir("A")
        assertEquals("A2", e.confirmar("A2"))
        e.abrir("A")
        assertNull(e.confirmar("A"))
    }
}
