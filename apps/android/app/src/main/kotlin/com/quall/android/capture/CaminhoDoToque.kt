package com.quall.android.capture

/**
 * **O caminho do toque, da prévia ao sensor** (`docs/controles-de-camera.md` §4.4). O referencial do
 * ponto de foco e de medida é o do sensor, e não o da imagem que vai ao ar: a rede congela a rotação do
 * começo, com tarjas, e o crop do R11 vai mudar a imagem que vai ao ar.
 *
 * 1. da prévia ao quadro do divisor: o ponto da `SurfaceView`, com a origem embaixo (a convenção do GL),
 *    passa pela mesma [GeometriaDoDivisor.matriz] com que a prévia é desenhada — **com o espelho da
 *    prévia**, então o espelho da frontal se desfaz sozinho;
 * 2. o toque que cai numa tarja (fora de [0,1]² depois da matriz) é descartado;
 * 3. a matriz leva à imagem natural (a que a `SurfaceTexture` lê);
 * 4. a matriz da `SurfaceTexture` leva ao buffer. O eixo Y invertido do buffer (a linha 0 da memória é
 *    o alto da imagem, e o GL tem a origem embaixo) **já vem dentro da matriz**: é a inversão vertical
 *    que toda matriz de `SurfaceTexture` traz (`GLConsumer::computeTransformMatrix`, `mtxFlipV`; ver a
 *    [GeometriaDoDivisor]). A coordenada `t` da textura é a linha do buffer contada de cima, e inverter
 *    de novo aqui poria o ponto de ponta-cabeça. **Este passo lê a matriz**, que só existe na thread GL:
 *    o [DivisorGl] a publica ([DivisorGl.matrizDaCamera]); a conta com ela é pura e está aqui;
 * 5. o ponto normalizado do buffer vai à `SurfaceOrientedMeteringPointFactory(1f, 1f)` (fora daqui).
 *
 * Puro e testado sem aparelho, como a [GeometriaDoDivisor].
 */
object CaminhoDoToque {

    /**
     * O ponto do buffer da câmera, normalizado em [0,1]² com a origem em cima à esquerda, que o toque em
     * ([x], [y]) pixels de uma prévia de [largura] × [altura] mostra — ou `null` se o toque caiu numa
     * tarja. [st] é a matriz da `SurfaceTexture` (4×4 por colunas, como `getTransformMatrix`).
     */
    fun pontoNoBuffer(
        x: Float, y: Float, largura: Int, altura: Int,
        larguraNatural: Int, alturaNatural: Int, rotacao: Int,
        espelharNaTela: Boolean, texturaEspelhada: Boolean, frontal: Boolean,
        st: FloatArray,
    ): Pair<Double, Double>? {
        if (largura <= 0 || altura <= 0 || st.size < 16) return null
        // 1. a vista tem a origem em cima; a saída do divisor, embaixo.
        val qx = x.toDouble() / largura
        val qy = 1.0 - y.toDouble() / altura
        if (qx !in 0.0..1.0 || qy !in 0.0..1.0) return null
        val m = GeometriaDoDivisor.matriz(
            larguraNatural, alturaNatural, rotacao, largura, altura,
            preencher = false, espelharNaTela = espelharNaTela, texturaEspelhada = texturaEspelhada, frontal = frontal,
        )
        // 2–3. a imagem natural; fora dela é tarja (o shader pinta de preto).
        val (nx, ny) = m.aplicar(qx, qy)
        val folga = 1e-9
        if (nx < -folga || nx > 1 + folga || ny < -folga || ny > 1 + folga) return null
        // 4. o buffer, pela matriz da SurfaceTexture (por colunas), que já traz a inversão do Y.
        val tx = st[0] * nx + st[4] * ny + st[12]
        val ty = st[1] * nx + st[5] * ny + st[13]
        return tx.coerceIn(0.0, 1.0) to ty.coerceIn(0.0, 1.0)
    }
}
