package com.quall.android.audio

/**
 * G.711 µ-law (RFC 3551 §4.5.14), nos dois sentidos.
 *
 * ## Por que isto mora na casca e não na fronteira C
 *
 * Porque a fronteira **recusa PCMU de propósito**, na ida e na volta, e diz por quê:
 * *"G.711 µ-law é uma tabela de consulta de 8 bits — codifique na casca"*. Trazê-la para o núcleo
 * seria uma porta a mais para um problema que não é dele. `docs/audio.md` §2 chama o PCMU de
 * **piso**, não de alternativa: ele existe para que um par que não fale Opus ainda tenha som.
 *
 * ## O detalhe que não é detalhe: PCMU é mono
 *
 * RFC 3551 §6 fixa um canal para o payload type 0. Uma track de áudio de **sistema** negociada em
 * PCMU é mono, mesmo o preset da espécie dizendo estéreo — e é por isso que [PresetDeAudio.de]
 * recebe o codec negociado, e não só a espécie. Foi defeito medido, não detalhe.
 *
 * ## O silêncio de µ-law não é zero
 *
 * `0xFF` é o silêncio (0 linear); um buffer de bytes zerados é o valor linear mais negativo
 * possível, repetido — o oposto de silêncio. Quem preencher um buraco de PCMU à mão preenche com
 * [SILENCIO], nunca com `0`.
 */
object UlawG711 {

    /** O byte que decodifica para 0 linear. Um buffer de `0x00` é ruído, não silêncio. */
    const val SILENCIO: Byte = 0xFF.toByte()

    private const val VIES = 0x84
    private const val CLIP = 32635

    /** Tabela de 256 entradas, construída uma vez. A volta é pura consulta. */
    private val PARA_LINEAR = ShortArray(256) { i ->
        val u = i.inv() and 0xFF
        val sinal = u and 0x80
        val expoente = (u shr 4) and 0x07
        val mantissa = u and 0x0F
        var amostra = ((mantissa shl 3) + VIES) shl expoente
        amostra -= VIES
        (if (sinal != 0) -amostra else amostra).toShort()
    }

    /** Um byte de µ-law para PCM linear de 16 bits. */
    fun paraLinear(b: Byte): Short = PARA_LINEAR[b.toInt() and 0xFF]

    /**
     * Decodifica `n` bytes de `entrada` em `saida`. Devolve quantas amostras foram escritas.
     *
     * Uma amostra por byte: em G.711 não há quadro, e 20 ms a 8 kHz são exatamente 160 bytes.
     */
    fun decodificar(entrada: ByteArray, n: Int, saida: ShortArray): Int {
        val quantas = minOf(n, saida.size)
        for (i in 0 until quantas) {
            saida[i] = PARA_LINEAR[entrada[i].toInt() and 0xFF]
        }
        return quantas
    }

    /** PCM linear de 16 bits para um byte de µ-law. */
    fun deLinear(amostra: Short): Byte {
        var v = amostra.toInt()
        val sinal = if (v < 0) 0x80 else 0x00
        if (v < 0) v = -v
        if (v > CLIP) v = CLIP
        v += VIES
        var expoente = 7
        var mascara = 0x4000
        while (expoente > 0 && (v and mascara) == 0) {
            expoente--
            mascara = mascara shr 1
        }
        val mantissa = (v shr (expoente + 3)) and 0x0F
        return ((sinal or (expoente shl 4) or mantissa).inv() and 0xFF).toByte()
    }
}
