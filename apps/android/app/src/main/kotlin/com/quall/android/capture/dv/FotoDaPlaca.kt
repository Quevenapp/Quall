package com.quall.android.capture.dv

/**
 * **A foto do quadro da placa** (§11, item 6; a "foto" do EasyCap Recorder, §10): o quadro já
 * **decodificado** (os planos YUV do `mjpeg` do FFmpeg), e não o MJPEG cru da placa — ele pode vir sem
 * tabela Huffman (DHT), e muito leitor de JPEG não o abre (§5, P0: o Preview do Mac não abriu).
 *
 * Aqui só a conta pura, testada em JVM: os planos (luma `larguraY × alturaY`, croma `larguraC ×
 * alturaC`, qualquer subamostragem: 4:2:2 na placa, 4:2:0, 4:4:4) viram **NV21** (o que o
 * `YuvImage.compressToJpeg` aceita): o luma inteiro, e o croma em 4:2:0 pela **média da região** que
 * cada amostra cobre (duas linhas no 4:2:2), intercalado V,U.
 *
 * **A faixa**: o conteúdo da placa é faixa limitada (16–235, medido na P0, §8.1) e o JPEG que sai
 * daqui é JFIF, faixa cheia por definição. Sem expandir, a foto sairia lavada (o preto em cinza 16).
 * [expandir] leva 16–235 a 0–255 no luma e 16–240 a 0–255 no croma (em torno de 128), como um
 * visualizador faria com o vídeo.
 */
object FotoDaPlaca {
    /** NV21 de `largura × altura` pares (o quadro ímpar perde a última coluna ou linha). */
    class Nv21(val dados: ByteArray, val largura: Int, val altura: Int)

    fun nv21(
        y: ByteArray, u: ByteArray, v: ByteArray,
        larguraY: Int, alturaY: Int, larguraC: Int, alturaC: Int,
        expandir: Boolean = true,
    ): Nv21 {
        require(larguraY >= 2 && alturaY >= 2 && larguraC >= 1 && alturaC >= 1) { "quadro pequeno demais" }
        require(y.size >= larguraY * alturaY && u.size >= larguraC * alturaC && v.size >= larguraC * alturaC) { "planos curtos" }
        val w = larguraY and 1.inv()
        val h = alturaY and 1.inv()
        val out = ByteArray(w * h + w * h / 2)
        val ly = if (expandir) TABELA_Y else IDENTIDADE
        val lc = if (expandir) TABELA_C else IDENTIDADE
        for (j in 0 until h) {
            val o = j * w
            val s = j * larguraY
            for (i in 0 until w) out[o + i] = ly[y[s + i].toInt() and 0xFF]
        }
        // O croma: cada amostra 4:2:0 (i, j) cobre a região [x0, x1) × [y0, y1) do croma de entrada.
        val cw = w / 2
        val ch = h / 2
        var o = w * h
        for (j in 0 until ch) {
            val y0 = j * alturaC / ch
            val y1 = maxOf(y0 + 1, (j + 1) * alturaC / ch)
            for (i in 0 until cw) {
                val x0 = i * larguraC / cw
                val x1 = maxOf(x0 + 1, (i + 1) * larguraC / cw)
                var su = 0
                var sv = 0
                var n = 0
                for (yy in y0 until minOf(y1, alturaC)) {
                    val base = yy * larguraC
                    for (xx in x0 until minOf(x1, larguraC)) {
                        su += u[base + xx].toInt() and 0xFF
                        sv += v[base + xx].toInt() and 0xFF
                        n++
                    }
                }
                val mu = if (n > 0) (su + n / 2) / n else 128
                val mv = if (n > 0) (sv + n / 2) / n else 128
                out[o++] = lc[mv]  // NV21: V primeiro
                out[o++] = lc[mu]
            }
        }
        return Nv21(out, w, h)
    }

    /** Luma limitada (16–235) → cheia (0–255). */
    private val TABELA_Y = ByteArray(256) { k -> (((k - 16) * 255 + 109) / 219).coerceIn(0, 255).toByte() }
    /** Croma limitado (16–240, centro 128) → cheio (0–255). */
    private val TABELA_C = ByteArray(256) { k ->
        val d = (k - 128) * 255
        (128 + (if (d >= 0) (d + 112) / 224 else (d - 112) / 224)).coerceIn(0, 255).toByte()
    }
    private val IDENTIDADE = ByteArray(256) { it.toByte() }

    /**
     * A largura com o pixel quadrado para a altura [altura] no aspecto de exibição [aspectoN]:[aspectoD]
     * (par). **A filmadora DV** (`docs/placa-de-captura-usb.md` §13) manda 720x480 para 4:3 ou 16:9: a
     * foto sai 640x480 ou 854x480, como a tela a mostra. A placa (640x480 em 4:3) já é quadrada.
     */
    fun larguraQuadrada(altura: Int, aspectoN: Int, aspectoD: Int): Int {
        if (aspectoN <= 0 || aspectoD <= 0) return 0
        val w = (altura.toLong() * aspectoN + aspectoD / 2) / aspectoD
        return ((w + 1) and 1L.inv()).toInt()
    }

    /**
     * O [n] esticado ou encolhido na horizontal até [largura] (par), em interpolação linear (o luma e
     * cada croma, que em NV21 é um par V,U por amostra). A altura não muda.
     */
    fun redimensionar(n: Nv21, largura: Int): Nv21 {
        require(largura >= 2 && largura % 2 == 0) { "largura ímpar ou pequena" }
        if (largura == n.largura) return n
        val w0 = n.largura
        val h = n.altura
        val out = ByteArray(largura * h + largura * h / 2)
        fun linha(orig: Int, largOrig: Int, dest: Int, largDest: Int, passo: Int, canal: Int) {
            for (i in 0 until largDest) {
                // O centro da amostra de saída na grade de entrada (em 1/1024).
                val x = ((2L * i + 1) * largOrig * 1024 / (2L * largDest) - 512).coerceAtLeast(0)
                val x0 = (x shr 10).toInt().coerceAtMost(largOrig - 1)
                val x1 = (x0 + 1).coerceAtMost(largOrig - 1)
                val f = (x and 1023).toInt()
                val a = n.dados[orig + x0 * passo + canal].toInt() and 0xFF
                val b = n.dados[orig + x1 * passo + canal].toInt() and 0xFF
                out[dest + i * passo + canal] = ((a * (1024 - f) + b * f + 512) shr 10).toByte()
            }
        }
        for (j in 0 until h) linha(j * w0, w0, j * largura, largura, 1, 0)
        val cw0 = w0 / 2
        val cw = largura / 2
        for (j in 0 until h / 2) {
            val o = w0 * h + j * w0
            val d = largura * h + j * largura
            linha(o, cw0, d, cw, 2, 0)
            linha(o, cw0, d, cw, 2, 1)
        }
        return Nv21(out, largura, h)
    }

    /** `Quall-Placa-AAAAMMDD-HHMMSS.jpg` (a filmadora: `Quall-DV-…`). */
    fun nome(agora: java.util.Date = java.util.Date(), prefixo: String = "Quall-Placa-"): String =
        prefixo + java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US).format(agora) + ".jpg"
}
