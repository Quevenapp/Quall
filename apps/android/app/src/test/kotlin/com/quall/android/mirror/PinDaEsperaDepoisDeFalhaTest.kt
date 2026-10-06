package com.quall.android.mirror

import com.quall.android.core.QuallNative.Status
import org.junit.Assert.*
import org.junit.Test

class PinDaEsperaDepoisDeFalhaTest {
    @Test fun recusas_wrong_pin_e_pairing_renovam_sem_inferir_fase_ou_modo() {
        for (status in listOf(Status.WRONG_PIN, Status.PAIRING)) {
            var chamadas = 0
            assertEquals("654321", pinDepoisDaFalhaDaEspera("123456", status) { chamadas++; "654321" })
            assertEquals(1, chamadas)
        }
    }

    @Test fun dois_erros_de_autenticacao_nao_reutilizam_os_valores_anteriores() {
        val primeiro = pinDepoisDaFalhaDaEspera("123456", Status.WRONG_PIN) { "654321" }
        val segundo = pinDepoisDaFalhaDaEspera(primeiro!!, Status.PAIRING) { "333333" }
        assertEquals("654321", primeiro)
        assertEquals("333333", segundo)
        assertNotEquals(primeiro, segundo)
    }

    @Test fun outros_status_nao_sorteiam_nem_renovam() {
        for (status in listOf(Status.TIMEOUT, Status.NO_ROUTE, Status.IO, Status.CLOSED,
            Status.SIGNALING, Status.TRANSPORT, Status.PROTOCOL, Status.NEEDS_PIN, Status.BUSY, Status.CANCELLED)) {
            assertEquals("123456", pinDepoisDaFalhaDaEspera("123456", status) {
                fail("este status mantém o PIN disponível")
                "654321"
            })
        }
    }

    @Test fun retorno_bem_sucedido_nao_modifica_pin_ou_exige_sorteio() {
        assertEquals("123456", pinDepoisDaFalhaDaEspera("123456", Status.OK) {
            fail("a política só trata falhas")
            "654321"
        })
    }

    @Test fun colisao_nao_reintroduz_pin_anterior() {
        val valores = ArrayDeque(listOf("123456", "123456", "654321"))
        assertEquals("654321", pinDepoisDaFalhaDaEspera("123456", Status.PAIRING) { valores.removeFirst() })
    }

    @Test fun repeticao_tem_limite_e_falha_fechada() {
        var chamadas = 0
        assertNull(pinDepoisDaFalhaDaEspera("123456", Status.WRONG_PIN) { chamadas++; "123456" })
        assertEquals(8, chamadas)
    }

    @Test fun pin_invalido_ou_falha_do_sorteador_nao_reusa_o_pin_anterior() {
        for (invalido in listOf("", "12345", "1234567", "12345a", "１２３４５６")) {
            assertNull(pinDepoisDaFalhaDaEspera("123456", Status.PAIRING) { invalido })
        }
        assertNull(pinDepoisDaFalhaDaEspera("123456", Status.PAIRING) { throw IllegalStateException("generator unavailable") })
    }
}
