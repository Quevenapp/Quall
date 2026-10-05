// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.receive

import com.quall.android.core.TextosDeTeste
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Testes de [FraseDoAviso] (`docs/traducao.md`, Android). **Em português, as frases são as de antes da
 * tradução**, letra por letra: até 02/10/2026 a sessão as publicava prontas e a tela só punha a maiúscula.
 */
class FraseDoAvisoTest {

    private fun estado(aviso: ReceptorBus.Aviso, detalhe: String = "", endpoint: String = "192.168.57.3:7877") =
        ReceptorBus.Estado(aviso = aviso, detalhe = detalhe, endpoint = endpoint)

    private val pt = TextosDeTeste.PT
    private val en = TextosDeTeste.EN

    @Test
    fun `as frases de antes, em portugues`() {
        assertEquals("Retomando pareamento…", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.RETOMANDO)))
        assertEquals("Conectando e pareando…", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.CONECTANDO_E_PAREANDO)))
        assertEquals("Cancelado", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.CANCELADO)))
        assertEquals(
            "O outro aparelho não reconhece mais este. Digite o PIN de seis dígitos que aparece na tela dele.",
            FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.PRECISA_DE_PIN)),
        )
        assertEquals(
            "Os dois aparelhos não acharam caminho um para o outro. Confira se estão na mesma rede Wi-Fi.",
            FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.SEM_ROTA)),
        )
        assertEquals(
            "192.168.57.3:7877 não respondeu a tempo. O outro aparelho ainda está esperando?",
            FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.SEM_RESPOSTA, "192.168.57.3:7877")),
        )
        assertEquals(
            "Não consegui conectar em 192.168.57.3:7877: connection refused",
            FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.NAO_CONECTOU, "connection refused")),
        )
        // A tela trocava o jargão "esperando a track do emissor…" por esta.
        assertEquals("Esperando a imagem…", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.ESPERANDO_A_IMAGEM)))
        assertEquals("Tela: o emissor saiu", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.EMISSOR_SAIU, "tela")))
        assertEquals("Tela: o transporte falhou", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.TRANSPORTE_FALHOU, "tela")))
        assertEquals("Tela: 10 s sem nenhum quadro", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.SEM_QUADRO, "tela")))
        assertEquals("Recepção encerrada", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.RECEPCAO_ENCERRADA)))
        assertEquals("A recepção terminou", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.RECEPCAO_TERMINOU)))
        assertEquals("Recebendo só som", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.SO_SOM)))
        assertEquals("A sessão caiu (evento 2)", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.SESSAO_CAIU, "2")))
        assertEquals(
            "Recepção morreu: IllegalStateException: x",
            FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.RECEPCAO_MORREU, "IllegalStateException: x")),
        )
    }

    @Test
    fun `o par sem nome vira emissor, e o audio sem motivo diz que nao toca`() {
        assertEquals(
            "Emissor conectou mas não abriu nenhuma track de mídia",
            FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.SEM_TRACK)),
        )
        assertEquals(
            "Mac do Pessoa Exemplo conectou mas não abriu nenhuma track de mídia",
            FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.SEM_TRACK, "Mac do Pessoa Exemplo")),
        )
        assertEquals("O áudio não está tocando", FraseDoAviso.de(pt, estado(ReceptorBus.Aviso.AUDIO_PAROU)))
        assertEquals("Sender connected but didn’t open any media track", FraseDoAviso.de(en, estado(ReceptorBus.Aviso.SEM_TRACK)))
    }

    @Test
    fun `sem aviso vale a mensagem pronta, e nada vira nada`() {
        assertEquals("", FraseDoAviso.de(pt, ReceptorBus.Estado()))
        assertEquals("Texto da vitrine", FraseDoAviso.de(en, ReceptorBus.Estado(mensagem = "texto da vitrine")))
    }

    @Test
    fun `em ingles, todo aviso tem frase e nenhuma e a de portugues`() {
        for (a in ReceptorBus.Aviso.values()) {
            if (a == ReceptorBus.Aviso.NENHUM) continue
            val e = estado(a, detalhe = "x")
            val ingles = FraseDoAviso.de(en, e)
            assertTrue("$a sem frase", ingles.isNotBlank())
            if (a != ReceptorBus.Aviso.AUDIO_PAROU) {
                assertTrue("$a igual nos dois idiomas: $ingles", ingles != FraseDoAviso.de(pt, e))
            }
        }
        assertEquals("Waiting for the picture…", FraseDoAviso.de(en, estado(ReceptorBus.Aviso.ESPERANDO_A_IMAGEM)))
        assertEquals("Screen: no frames for 10 s", FraseDoAviso.de(en, estado(ReceptorBus.Aviso.SEM_QUADRO, "screen")))
    }
}
