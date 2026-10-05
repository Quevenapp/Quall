package com.quall.android.capture

/**
 * **A média de luma do quadro, em contador** (R9, `docs/controles-de-camera.md` §5, prova 2): o brilho
 * que sobe e desce com EV, ISO e obturador, sem salvar nem abrir quadro nenhum — as câmeras da bancada
 * filmam a sala (`regras-de-frente.md`, "Um vídeo de bancada pode conter a vida do usuário"). O
 * [DivisorGl] desenha um quadro a cada [A_CADA] num FBO de [LADO] × [LADO] e lê 1 KB; a conta é esta,
 * pura.
 *
 * O FBO de 16 × 16 amostra 256 pontos da imagem (o filtro linear da textura externa olha os vizinhos de
 * cada um, não a imagem inteira): é um termômetro de brilho, não um fotômetro. Basta para "subiu ou
 * desceu" entre dois ajustes na mesma cena.
 */
object LumaMedia {
    const val LADO = 16
    const val A_CADA = 30

    /**
     * A luma média (BT.709, 0 a 255) de [rgba], com [pixels] pixels em RGBA de 8 bits — o que o
     * `glReadPixels(GL_RGBA, GL_UNSIGNED_BYTE)` devolve. O RGB do GL aqui já é o não linear (sRGB/BT.709
     * com gama), então a soma ponderada é a luma Y', e não a luminância.
     */
    fun de(rgba: ByteArray, pixels: Int = LADO * LADO): Double {
        val n = minOf(pixels, rgba.size / 4)
        if (n <= 0) return 0.0
        var soma = 0.0
        for (i in 0 until n) {
            val r = rgba[4 * i].toInt() and 0xFF
            val g = rgba[4 * i + 1].toInt() and 0xFF
            val b = rgba[4 * i + 2].toInt() and 0xFF
            soma += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return soma / n
    }

    /** Os quadros por segundo entre dois carimbos (ns) separados por [quadros] quadros. */
    fun fps(quadros: Long, deCarimboNs: Long, ateCarimboNs: Long): Double? {
        val dt = ateCarimboNs - deCarimboNs
        return if (quadros <= 0 || dt <= 0) null else quadros * 1e9 / dt
    }
}
