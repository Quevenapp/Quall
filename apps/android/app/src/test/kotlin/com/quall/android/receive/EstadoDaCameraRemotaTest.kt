package com.quall.android.receive

import com.quall.android.capture.AjusteDaCamera
import com.quall.android.core.TextosDeTeste.Companion.EN
import com.quall.android.core.TextosDeTeste.Companion.PT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** O estado do receptor do controle remoto da câmera (`docs/controle-remoto-da-camera.md` §11.1), lido como a tela o lê. */
class EstadoDaCameraRemotaTest {

    /** O literal do contrato (§11.1), com capacidades e lido de verdade. */
    private val pronto = """{"situacao":"pronto",
        "capacidades":{"plataforma":"android","controles":{"exposicao":{"valores":["auto","manual"]},"iso":{"min":50,"max":3200,"inteiro":true}},"limites":{}},
        "ajuste":{"exposicao":"manual","ev":0,"travaExposicao":false,"iso":800,"obturadorNs":16666666},
        "aplicado":{"exposicao":"manual","iso":400},"pendente":{"iso":800},
        "lido":{"iso":400,"obturadorNs":16666666,"kelvin":5150,"abertura":1.7,"divergentes":["iso"]},
        "autor":"Pixel do Pessoa Exemplo","versao":17,
        "recusa":{"motivo":"superado","campo":"iso","ha_ms":300},
        "contadores":{"recebidas":0}}"""

    @Test
    fun le_o_estado_literal_do_contrato() {
        val e = EstadoDaCameraRemota.ler(pronto)!!
        assertEquals(EstadoDaCameraRemota.PRONTO, e.situacao)
        assertTrue(e.mostraControles)
        assertTrue(e.vivo)
        // O ajuste é o aplicado com o pendente por cima: o painel mostra 800.
        assertEquals(800, e.ajuste!!.iso)
        assertEquals(AjusteDaCamera.Exposicao.MANUAL, e.ajuste!!.exposicao)
        assertEquals(400, e.lido.iso)
        assertEquals(5150, e.lido.kelvin)
        assertEquals(1.7f, e.lido.abertura!!, 1e-6f)
        assertEquals(listOf("iso"), e.lido.divergentes)
        assertEquals("Pixel do Pessoa Exemplo", e.autor)
        assertEquals(EstadoDaCameraRemota.Recusa("superado", "iso"), e.recusa)
    }

    @Test
    fun antes_de_chegar_e_sem_resposta_nao_mostra_controles() {
        val esperando = EstadoDaCameraRemota.ler("""{"situacao":"esperando","capacidades":null,"ajuste":null,"aplicado":null,"pendente":{},"lido":null,"autor":null,"versao":null,"recusa":null}""")!!
        assertFalse(esperando.mostraControles)
        assertNull(esperando.ajuste)
        assertFalse(EstadoDaCameraRemota.ler("""{"situacao":"sem_resposta"}""")!!.mostraControles)
        assertFalse(EstadoDaCameraRemota.ler("""{"situacao":"sem_camera"}""")!!.mostraControles)
        // Falha do JNI (vazio) e lixo: `null`, e a tela mantém o que tinha.
        assertNull(EstadoDaCameraRemota.ler(""))
        assertNull(EstadoDaCameraRemota.ler("{"))
    }

    @Test
    fun nao_permitido_mostra_os_valores_apagados() {
        val e = EstadoDaCameraRemota.ler(pronto.replace("\"situacao\":\"pronto\"", "\"situacao\":\"nao_permitido\""))!!
        assertTrue(e.mostraControles)
        assertFalse(e.vivo)
    }

    @Test
    fun as_frases_das_recusas() {
        fun f(motivo: String, campo: String? = null) = EstadoDaCameraRemota.fraseDaRecusa(PT, EstadoDaCameraRemota.Recusa(motivo, campo))
        assertEquals("O aparelho não permite controle remoto da câmera", f("nao_permitido"))
        assertEquals("This device doesn’t allow remote camera control",
            EstadoDaCameraRemota.fraseDaRecusa(EN, EstadoDaCameraRemota.Recusa("nao_permitido", null)))
        assertEquals("Este aparelho não aceitou o obturador.", f("fora_da_faixa", "obturadorNs"))
        assertEquals("Este aparelho não aceitou a compensação de exposição.", f("incoerente", "ev"))
        assertEquals("O aparelho não conseguiu aplicar o ajuste.", f("nao_aplicado"))
        assertEquals("O aparelho não conseguiu aplicar o ajuste.", f("codigo_que_esta_build_nao_conhece"))
        assertEquals("O aparelho não respondeu.", f("sem_resposta"))
        for (calado in listOf("superado", "ocupado", "camera_trocada", "nao_pareado", "invalido", "fora_da_imagem", "sem_camera")) {
            assertNull(calado, f(calado))
        }
    }
}
