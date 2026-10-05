package com.quall.android.receive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Testes de [TamanhoDaSaida]: o tamanho que vai à tela quando o formato de saída muda. Rodam na JVM
 * (`gradle testDebugUnitTest`).
 */
class TamanhoDaSaidaTest {

    /**
     * **O S24 no controle de 21/09**: o fluxo passou de 640x480 a 854x480, e o `c2.qti` disse
     * `KEY_WIDTH` 864. O recorte 0..853 é o **esperado**, e não medido: o logcat daquele controle não
     * gravava as chaves `crop-*` (a revisão do `23eb480`, B3). A linha "formato de saída" nova grava.
     * A superfície tem de ser do tamanho da imagem, 854.
     */
    @Test
    fun o_recorte_manda_e_nao_a_largura_alinhada() {
        assertEquals(Pair(854, 480), TamanhoDaSaida.de(864, 480, 0, 853, 0, 479))
        // O A10s de agosto: 1280x720 no buffer, 1274x716 de imagem.
        assertEquals(Pair(1274, 716), TamanhoDaSaida.de(1280, 720, 0, 1273, 0, 715))
    }

    /** **O tablet no mesmo controle**: o `c2.mtk` disse 854 sem alinhar; com ou sem recorte, 854. */
    @Test
    fun sem_recorte_vale_a_chave() {
        assertEquals(Pair(854, 480), TamanhoDaSaida.de(854, 480, null, null, null, null))
        assertEquals(Pair(640, 480), TamanhoDaSaida.de(640, 480, 0, 639, 0, 479))
    }

    @Test
    fun recorte_incompleto_ou_invertido_nao_vale() {
        assertEquals(Pair(864, 480), TamanhoDaSaida.de(864, 480, 0, 853, null, 479), "recorte pela metade")
        assertEquals(Pair(864, 480), TamanhoDaSaida.de(864, 480, 10, 5, 0, 479))
        assertNull(TamanhoDaSaida.de(null, null, null, null, null, null))
        assertNull(TamanhoDaSaida.de(0, 480, null, null, null, null))
    }

    private fun assertEquals(esperado: Pair<Int, Int>, obtido: Pair<Int, Int>?, porque: String) {
        assertEquals(porque, esperado, obtido)
    }
}
