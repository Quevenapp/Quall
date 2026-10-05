package com.quall.android.capture

/**
 * Leitura mínima de Annex-B H.264: achar unidades NAL por start code e ler o tipo de cada uma.
 *
 * O `MediaCodec` de encode de vídeo no Android já devolve os buffers de saída em Annex-B (start
 * code `00 00 00 01` ou `00 00 01`), diferente do `MediaExtractor`/`MediaMuxer`, que usa AVCC com
 * comprimento na frente. Por isso não há conversão de formato aqui — só leitura, para: (1) saber
 * se um buffer de saída carrega um NAL IDR (tipo 5), o que o `docs/contrato-sidecar.md` exige no
 * campo `idr`; e (2) medir se um pedido de IDR via `PARAMETER_KEY_REQUEST_SYNC_FRAME` foi
 * atendido de verdade — no `.h264`, não no retorno da chamada.
 */
object AnnexB {
    /** Tipo de unidade NAL, mascarando os 5 bits baixos do primeiro byte após o start code. */
    fun nalType(byte: Byte): Int = byte.toInt() and 0x1F

    const val NAL_SPS = 7
    const val NAL_PPS = 8
    const val NAL_IDR = 5

    /**
     * Devolve o offset de início de cada unidade NAL em `buffer[0 until size)`, isto é, o byte
     * logo após o start code (`00 00 01` ou `00 00 00 01`).
     */
    fun nalStarts(buffer: ByteArray, size: Int): List<Int> {
        val starts = ArrayList<Int>()
        var i = 0
        while (i + 2 < size) {
            if (buffer[i] == 0.toByte() && buffer[i + 1] == 0.toByte() && buffer[i + 2] == 1.toByte()) {
                starts.add(i + 3)
                i += 3
                continue
            }
            i++
        }
        return starts
    }

    /** Se algum NAL do buffer é IDR (tipo 5). */
    fun containsIdr(buffer: ByteArray, size: Int): Boolean {
        for (start in nalStarts(buffer, size)) {
            if (start < size && nalType(buffer[start]) == NAL_IDR) return true
        }
        return false
    }

    /** Se o buffer só carrega parâmetros (SPS/PPS), sem nenhum NAL de imagem. */
    fun isParameterSetsOnly(buffer: ByteArray, size: Int): Boolean {
        val starts = nalStarts(buffer, size)
        if (starts.isEmpty()) return false
        return starts.all { start -> start < size && (nalType(buffer[start]) == NAL_SPS || nalType(buffer[start]) == NAL_PPS) }
    }

    // -----------------------------------------------------------------------------------------
    // Mesmas leituras sobre `ByteBuffer`
    //
    // O caminho da track não copia o buffer de saída do `MediaCodec` para um `ByteArray` — ele
    // manda o endereço direto para o JNI. Precisa, portanto, decidir "é IDR?" e "já tem SPS?"
    // lendo o buffer no lugar, com deslocamento explícito (o `BufferInfo.offset` do OMX legado do
    // A10s não é zero).
    // -----------------------------------------------------------------------------------------

    /** Offsets absolutos do primeiro byte de cada NAL em `[offset, offset+size)`. */
    fun nalStarts(buffer: java.nio.ByteBuffer, offset: Int, size: Int): List<Int> {
        val starts = ArrayList<Int>(8)
        var i = offset
        val fim = offset + size
        while (i + 2 < fim) {
            if (buffer.get(i) == 0.toByte() &&
                buffer.get(i + 1) == 0.toByte() &&
                buffer.get(i + 2) == 1.toByte()
            ) {
                starts.add(i + 3)
                i += 3
                continue
            }
            i++
        }
        return starts
    }

    /** Conjunto de tipos de NAL presentes em `[offset, offset+size)`. */
    fun nalTypes(buffer: java.nio.ByteBuffer, offset: Int, size: Int): Set<Int> {
        val fim = offset + size
        val tipos = HashSet<Int>(4)
        for (start in nalStarts(buffer, offset, size)) {
            if (start < fim) tipos.add(nalType(buffer.get(start)))
        }
        return tipos
    }

    /**
     * A primeira fatia do quadro (NAL 1 ou 5) é **referência** de alguém (`nal_ref_idc != 0`)?
     *
     * É o que decide se o teto instantâneo pode jogar o quadro fora sem quebrar a cadeia — ver
     * `TetoDeSaida`. Sem fatia nenhuma no buffer a resposta é `true`: na dúvida, trata-se como
     * referência, que é o lado que pede IDR em vez do lado que deixa lixo passar.
     */
    fun primeiraFatiaReferenciada(buffer: java.nio.ByteBuffer, offset: Int, size: Int): Boolean {
        val fim = offset + size
        var i = offset
        while (i + 3 < fim) {
            if (buffer.get(i) == 0.toByte() &&
                buffer.get(i + 1) == 0.toByte() &&
                buffer.get(i + 2) == 1.toByte()
            ) {
                val cabecalho = buffer.get(i + 3).toInt()
                val tipo = cabecalho and 0x1F
                if (tipo == 1 || tipo == 5) return ((cabecalho shr 5) and 0x3) != 0
                i += 3
                continue
            }
            i++
        }
        return true
    }

    /**
     * O buffer começa com start code Annex-B (`00 00 01` ou `00 00 00 01`)?
     *
     * Conferido a cada quadro no caminho da track. Não é zelo: se o deslocamento estiver errado,
     * `quall_track_send_frame` devolve `QUALL_STATUS_OK` alegremente e o receptor recebe lixo —
     * exatamente o modo de falha que o `SetValue`/`S_OK` do Windows ensinou a não confiar.
     */
    fun comecaComStartCode(buffer: java.nio.ByteBuffer, offset: Int, size: Int): Boolean {
        if (size < 4) return false
        if (buffer.get(offset) != 0.toByte() || buffer.get(offset + 1) != 0.toByte()) return false
        if (buffer.get(offset + 2) == 1.toByte()) return true
        return buffer.get(offset + 2) == 0.toByte() && buffer.get(offset + 3) == 1.toByte()
    }
}
