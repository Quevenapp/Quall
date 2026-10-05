package com.quall.android.receive

/**
 * **O tamanho da imagem no formato de saída do `MediaCodec`**: o recorte (`crop-left/right/top/bottom`,
 * inclusivos) quando o codec o declara, e o `KEY_WIDTH`/`KEY_HEIGHT` sem ele.
 *
 * O `KEY_WIDTH` é o do **buffer**, alinhado pelo componente. No controle da troca de tamanho de
 * 21/09/2026 o S24 (`c2.qti.avc.decoder`) disse 864 para um fluxo de 854, e a superfície ficou 1 %
 * mais larga que a imagem; o tablet (`c2.mtk.avc.decoder`) disse 854 certo. O A10s já tinha medido o
 * mesmo alinhamento, 1280x720 para 1274x716 (`docs/app-windows.md`). A imagem de verdade é o
 * recorte, que é o que o SPS declara (`Sps.ler` também o aplica).
 *
 * Separado do [H264Decoder] para rodar na JVM, sem `MediaFormat`: quem lê as chaves é o
 * decodificador, e aqui só entra o número.
 */
object TamanhoDaSaida {
    /** `null` quando nada serve: o chamador fica com o tamanho que já tinha. */
    fun de(chaveL: Int?, chaveA: Int?, cropEsq: Int?, cropDir: Int?, cropTopo: Int?, cropBase: Int?): Pair<Int, Int>? {
        if (cropEsq != null && cropDir != null && cropTopo != null && cropBase != null &&
            cropEsq >= 0 && cropTopo >= 0 && cropDir >= cropEsq && cropBase >= cropTopo
        ) {
            return Pair(cropDir - cropEsq + 1, cropBase - cropTopo + 1)
        }
        if (chaveL != null && chaveA != null && chaveL > 0 && chaveA > 0) return Pair(chaveL, chaveA)
        return null
    }
}
