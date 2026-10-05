package com.quall.android.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** O caminho do toque da prévia ao buffer da câmera (`docs/controles-de-camera.md` §4.4, passos 1–4). */
class CaminhoDoToqueTest {

    /** Uma matriz de `SurfaceTexture` por colunas, com o bloco 2×2 [a c; b d] e a translação. */
    private fun st(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) = FloatArray(16).also {
        it[0] = a; it[1] = b; it[4] = c; it[5] = d; it[10] = 1f; it[12] = tx; it[13] = ty; it[15] = 1f
    }

    /** Só a inversão vertical do GL: o buffer já está em pé. */
    private val soInversao = st(1f, 0f, 0f, -1f, 0f, 1f)

    private fun perto(esperado: Pair<Double, Double>, obtido: Pair<Double, Double>?) {
        requireNotNull(obtido)
        assertEquals(esperado.first, obtido.first, 1e-6)
        assertEquals(esperado.second, obtido.second, 1e-6)
    }

    @Test
    fun traseira_em_pe_o_alto_da_previa_e_o_alto_do_buffer() {
        // Prévia 1080×1920 com a imagem natural 1080×1920: sem tarja.
        fun p(x: Float, y: Float) = CaminhoDoToque.pontoNoBuffer(x, y, 1080, 1920, 1080, 1920, 0,
            espelharNaTela = false, texturaEspelhada = false, frontal = false, st = soInversao)
        perto(0.0 to 0.0, p(0f, 0f))
        perto(0.25 to 0.75, p(270f, 1440f))
        perto(1.0 to 1.0, p(1080f, 1920f))
    }

    @Test
    fun o_toque_na_tarja_e_descartado() {
        // Imagem 1080×1920 numa prévia larga 1920×1080: tarjas dos lados (a imagem tem 608 px de largura).
        fun p(x: Float, y: Float) = CaminhoDoToque.pontoNoBuffer(x, y, 1920, 1080, 1080, 1920, 0,
            espelharNaTela = false, texturaEspelhada = false, frontal = false, st = soInversao)
        assertNull(p(100f, 540f))
        assertNull(p(1800f, 540f))
        perto(0.5 to 0.5, p(960f, 540f))
        assertNull(CaminhoDoToque.pontoNoBuffer(-1f, 10f, 100, 100, 100, 100, 0, false, false, false, soInversao))
    }

    @Test
    fun a_previa_espelhada_da_frontal_desfaz_o_espelho() {
        // A frontal com a textura espelhada (o AUTO da Camera2: `st` com o x invertido) e a prévia como espelho:
        // o lado esquerdo da prévia é o lado esquerdo da textura, que é o direito do buffer.
        val espelhada = st(-1f, 0f, 0f, -1f, 1f, 1f)
        val p = CaminhoDoToque.pontoNoBuffer(108f, 960f, 1080, 1920, 1080, 1920, 0,
            espelharNaTela = true, texturaEspelhada = true, frontal = true, st = espelhada)
        perto(0.9 to 0.5, p)
        // A mesma frontal sem o espelho da prévia: a esquerda da tela é a esquerda da cena, a esquerda do buffer
        // espelhado... que é o direito da textura lida.
        val q = CaminhoDoToque.pontoNoBuffer(108f, 960f, 1080, 1920, 1080, 1920, 0,
            espelharNaTela = false, texturaEspelhada = true, frontal = true, st = espelhada)
        perto(0.1 to 0.5, q)
    }

    @Test
    fun o_buffer_do_sensor_girado_de_90_graus() {
        // O sensor a 90°: o buffer 1920×1080 deitado, a matriz troca os eixos (com a inversão do GL).
        val giro = st(0f, -1f, -1f, 0f, 1f, 1f)
        // Em pé, a imagem natural é 1080×1920. O alto da prévia (y=0) é ny = 1, que vai a s = 0 no buffer.
        val p = CaminhoDoToque.pontoNoBuffer(540f, 0f, 1080, 1920, 1080, 1920, 0,
            espelharNaTela = false, texturaEspelhada = false, frontal = false, st = giro)
        perto(0.0 to 0.5, p)
    }
}
