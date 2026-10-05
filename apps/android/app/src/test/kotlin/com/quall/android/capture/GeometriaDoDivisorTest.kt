package com.quall.android.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A conta do divisor GL da tela R5: espelho e eixos da matriz, rotação, corte e tarjas. */
class GeometriaDoDivisorTest {

    private fun ponto(m: GeometriaDoDivisor.Afim, x: Double, y: Double): Pair<Double, Double> = m.aplicar(x, y)

    private fun perto(esperado: Pair<Double, Double>, obtido: Pair<Double, Double>) {
        assertEquals(esperado.first, obtido.first, 1e-9)
        assertEquals(esperado.second, obtido.second, 1e-9)
    }

    /** Uma matriz de `SurfaceTexture` por colunas, com o bloco 2×2 [a c; b d] e a translação. */
    private fun st(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) = FloatArray(16).also {
        it[0] = a; it[1] = b; it[4] = c; it[5] = d; it[10] = 1f; it[12] = tx; it[13] = ty; it[15] = 1f
    }

    @Test
    fun a_inversao_vertical_do_gl_sozinha_nao_e_espelho() {
        // Sem transformação nenhuma, a `SurfaceTexture` devolve só a inversão vertical.
        assertFalse(GeometriaDoDivisor.espelhada(st(1f, 0f, 0f, -1f, 0f, 1f)))
        // Inversão vertical + giro de 90°: ainda não é espelho, e troca os eixos.
        val giro = st(0f, -1f, -1f, 0f, 1f, 1f)
        assertFalse(GeometriaDoDivisor.espelhada(giro))
        assertTrue(GeometriaDoDivisor.trocaEixos(giro))
        // Com o espelho da frontal (FLIP_H) o sinal troca.
        assertTrue(GeometriaDoDivisor.espelhada(st(-1f, 0f, 0f, -1f, 1f, 1f)))
        assertTrue(GeometriaDoDivisor.espelhada(st(0f, 1f, -1f, 0f, 1f, 0f)))
        assertFalse(GeometriaDoDivisor.trocaEixos(st(-1f, 0f, 0f, -1f, 1f, 1f)))
    }

    @Test
    fun o_tamanho_natural_e_o_da_tela() {
        assertEquals(1080 to 1920, GeometriaDoDivisor.tamanhoNatural(1920, 1080, trocaEixos = true))
        assertEquals(1920 to 1080, GeometriaDoDivisor.tamanhoNatural(1920, 1080, trocaEixos = false))
        assertEquals(1080 to 1920, GeometriaDoDivisor.tamanhoNaTela(1080, 1920, 0))
        assertEquals(1920 to 1080, GeometriaDoDivisor.tamanhoNaTela(1080, 1920, 1))
        assertEquals(1080 to 1920, GeometriaDoDivisor.tamanhoNaTela(1080, 1920, 2))
        assertEquals(1920 to 1080, GeometriaDoDivisor.tamanhoNaTela(1080, 1920, 3))
    }

    private fun m(rot: Int, lSaida: Int, aSaida: Int, preencher: Boolean = false, espelho: Boolean = false,
                  textura: Boolean = true, frontal: Boolean = true) =
        GeometriaDoDivisor.matriz(1080, 1920, rot, lSaida, aSaida, preencher = preencher,
            espelharNaTela = espelho, texturaEspelhada = textura, frontal = frontal)

    @Test
    fun em_retrato_a_rede_da_frontal_desfaz_o_espelho_da_textura() {
        // A textura espelhada (o AUTO da Camera2): a rede lê x espelhado — a imagem verdadeira.
        perto(1.0 to 0.0, ponto(m(0, 1080, 1920), 0.0, 0.0))
        perto(0.75 to 0.75, ponto(m(0, 1080, 1920), 0.25, 0.75))
        // A textura sem espelho já é a verdadeira: a rede lê direto.
        perto(0.25 to 0.75, ponto(m(0, 1080, 1920, textura = false), 0.25, 0.75))
        // A prévia espelhada de uma textura espelhada é a textura como veio.
        perto(0.25 to 0.75, ponto(m(0, 1080, 1920, espelho = true), 0.25, 0.75))
    }

    @Test
    fun na_frontal_o_giro_vale_para_a_imagem_espelhada() {
        // A revisão de 24/09 (B2): o giro do Camera2Basic deixa em pé a imagem espelhada da frontal.
        // Na ROTATION_90 a prévia espelhada (de uma textura espelhada) é exatamente o giro da textura.
        val previa = m(1, 1920, 1080, espelho = true)
        perto(0.0 to 1.0, ponto(previa, 0.0, 0.0)) // n = (p.y, 1 − p.x)
        perto(1.0 to 0.0, ponto(previa, 1.0, 1.0))
        // A rede é a prévia espelhada na tela, em qualquer rotação e com qualquer textura.
        for (rot in 0..3) for (textura in listOf(true, false)) {
            val (l, a) = GeometriaDoDivisor.tamanhoNaTela(1080, 1920, rot)
            val rede = m(rot, l, a, textura = textura)
            val esp = m(rot, l, a, espelho = true, textura = textura)
            for ((x, y) in listOf(0.0 to 0.0, 0.3 to 0.8, 1.0 to 0.5)) perto(ponto(esp, 1.0 - x, y), ponto(rede, x, y))
        }
    }

    @Test
    fun na_rotacao_90_a_rede_da_frontal_nao_sai_de_ponta_cabeca() {
        // O defeito da primeira versão: a rede em ROTATION_90/270 saía 180° errada. Com a textura
        // sem espelho (a verdadeira) e o aparelho com o alto à esquerda de quem olha a tela, o alto
        // do mundo é o lado x = 0 da imagem natural (a foto de frente tem o x trocado em relação ao
        // aparelho), e a direita da foto é o y natural: o canto de baixo à esquerda da rede é (1, 0).
        perto(1.0 to 0.0, ponto(m(1, 1920, 1080, textura = false), 0.0, 0.0))
        perto(0.0 to 1.0, ponto(m(1, 1920, 1080, textura = false), 1.0, 1.0))
        perto(0.0 to 1.0, ponto(m(3, 1920, 1080, textura = false), 0.0, 0.0))
        // Meia volta.
        perto(1.0 to 1.0, ponto(m(2, 1080, 1920, textura = false), 0.0, 0.0))
    }

    @Test
    fun a_traseira_gira_como_sai() {
        val t = m(1, 1920, 1080, textura = false, frontal = false)
        perto(0.0 to 1.0, ponto(t, 0.0, 0.0))
        perto(1.0 to 0.0, ponto(t, 1.0, 1.0))
    }

    @Test
    fun preencher_corta_e_encaixar_poe_tarjas() {
        // Preencher uma saída quadrada com uma imagem em pé 1080x1920: corta em cima e embaixo.
        // (Ninguém mais preenche: a prévia encaixa desde a prova de 24/09; a conta fica testada.)
        val corta = m(0, 1000, 1000, preencher = true, espelho = true)
        perto(0.0 to 0.5 - 0.5 * 0.5625, ponto(corta, 0.0, 0.0))
        perto(1.0 to 0.5 + 0.5 * 0.5625, ponto(corta, 1.0, 1.0))
        // A rede ficou em 1080x1920 (retrato no começo da sessão) e a tela girou: a imagem deitada
        // cabe inteira na largura, e sobra em cima e embaixo — fora de [0,1], que o shader pinta de preto.
        val tarja = m(1, 1080, 1920, textura = false)
        val (x, y) = ponto(tarja, 0.5, 0.0)
        assertTrue(x !in 0.0..1.0)
        assertEquals(0.5, y, 1e-9)
        perto(0.5 to 0.5, ponto(tarja, 0.5, 0.5))
    }

    /**
     * O defeito da prova de 24/09 no S24: em paisagem, com o F no centro do quadro da rede, a prévia
     * (metade da tela) mostrava um recorte bem mais apertado. Agora a imagem inteira cai numa área
     * centrada da prévia, e cada ponto dessa área lê o mesmo ponto da câmera que a rede lê — o
     * mesmo enquadramento, espelhado ou não pelo ajuste local.
     */
    @Test
    fun a_previa_mostra_o_mesmo_enquadramento_da_rede() {
        // Metade de um S24 deitado, a tela inteira em pé, um painel estreito e um achatado.
        val paineis = listOf(1170 to 1080, 1080 to 2340, 1080 to 1100, 540 to 1920, 2340 to 400)
        for (rot in 0..3) for (textura in listOf(true, false)) for (frontal in listOf(true, false)) {
            val (lt, at) = GeometriaDoDivisor.tamanhoNaTela(1080, 1920, rot)
            val rede = m(rot, lt, at, textura = textura, frontal = frontal)
            for ((w, h) in paineis) for (espelho in listOf(false, true)) {
                val previa = m(rot, w, h, espelho = espelho, textura = textura, frontal = frontal)
                val a = GeometriaDoDivisor.areaDaImagem(lt, at, w, h)
                // A área encosta em duas bordas opostas da prévia: nada sobra além das tarjas.
                assertTrue("rot=$rot ${w}x$h", a.largura == w || a.altura == h)
                for ((u, v) in listOf(0.0 to 0.0, 1.0 to 1.0, 0.5 to 0.5, 0.2 to 0.7, 1.0 to 0.0)) {
                    // (u, v) no quadro da rede; o mesmo ponto na prévia, na convenção do GL.
                    val qx = (a.x + u * a.largura) / w
                    val qy = (h - a.y - a.altura + v * a.altura).toDouble() / h
                    val esperado = ponto(rede, if (espelho) 1.0 - u else u, v)
                    val obtido = ponto(previa, qx, qy)
                    // Tolerância de um pixel de arredondamento da área.
                    assertEquals("x rot=$rot ${w}x$h esp=$espelho", esperado.first, obtido.first, 2.0 / minOf(w, h))
                    assertEquals("y rot=$rot ${w}x$h esp=$espelho", esperado.second, obtido.second, 2.0 / minOf(w, h))
                }
            }
        }
    }

    @Test
    fun a_area_da_imagem_encaixa_centrada() {
        // A imagem deitada 1920x1080 na metade de um S24 deitado: tarjas em cima e embaixo.
        assertEquals(GeometriaDoDivisor.Area(0, 211, 1170, 658), GeometriaDoDivisor.areaDaImagem(1920, 1080, 1170, 1080))
        // A imagem em pé numa saída do mesmo formato: sem tarja.
        assertEquals(GeometriaDoDivisor.Area(0, 0, 1080, 1920), GeometriaDoDivisor.areaDaImagem(1080, 1920, 1080, 1920))
    }

    @Test
    fun a_mat4_leva_o_ponto_como_a_afim() {
        val m = GeometriaDoDivisor.matriz(1080, 1920, 3, 800, 600, preencher = true,
            espelharNaTela = true, texturaEspelhada = true)
        val g = m.mat4()
        val (x, y) = 0.2 to 0.9
        val gx = g[0] * x + g[4] * y + g[12]
        val gy = g[1] * x + g[5] * y + g[13]
        val (ex, ey) = ponto(m, x, y)
        assertEquals(ex, gx, 1e-5)
        assertEquals(ey, gy, 1e-5)
    }

    @Test
    fun a_orientacao_fisica_vira_a_rotacao_da_tela_com_folga() {
        // Em pé, lado esquerdo para cima, de ponta-cabeça, lado direito para cima.
        assertEquals(0, GeometriaDoDivisor.rotacaoDaOrientacao(0, null))
        assertEquals(3, GeometriaDoDivisor.rotacaoDaOrientacao(90, null))
        assertEquals(2, GeometriaDoDivisor.rotacaoDaOrientacao(180, null))
        assertEquals(1, GeometriaDoDivisor.rotacaoDaOrientacao(270, null))
        assertEquals(0, GeometriaDoDivisor.rotacaoDaOrientacao(350, null))
        // A folga: a 50° o aparelho em pé continua em pé; a 65°, deitou.
        assertEquals(0, GeometriaDoDivisor.rotacaoDaOrientacao(50, 0))
        assertEquals(3, GeometriaDoDivisor.rotacaoDaOrientacao(65, 0))
        assertEquals(1, GeometriaDoDivisor.rotacaoDaOrientacao(300, 1))
        // Sem leitura (de face para cima): fica a de antes.
        assertEquals(1, GeometriaDoDivisor.rotacaoDaOrientacao(-1, 1))
        assertEquals(null, GeometriaDoDivisor.rotacaoDaOrientacao(-1, null))
    }
}
