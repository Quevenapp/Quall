package com.quall.android.capture

import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer

/**
 * Destino "sem rede": grava o Annex-B num `.h264`. O `.json` que o acompanha é escrito por quem
 * chamou o encoder, a partir do [H264ScreenEncoder.Result] — o sidecar precisa de campos
 * (`encoder`, `encoder_is_hardware`) que só existem depois que o codec foi criado.
 *
 * Escreve pelo `FileChannel`: o buffer que chega é o de saída do `MediaCodec`, direto, e mandá-lo
 * ao canal evita a cópia para um `ByteArray` que a versão anterior fazia por quadro.
 */
class SidecarFrameSink(private val arquivo: File) : FrameSink {

    private val out = FileOutputStream(arquivo)
    var bytesGravados = 0L
        private set

    override fun aoQuadro(
        dados: ByteBuffer,
        deslocamento: Int,
        tamanho: Int,
        timestampUs: Long,
        idr: Boolean,
    ) {
        val fatia = fatiar(dados, deslocamento, tamanho)
        var restante = tamanho
        while (restante > 0) {
            val n = out.channel.write(fatia)
            if (n <= 0) break
            restante -= n
        }
        bytesGravados += tamanho - restante
    }

    override fun fechar() {
        runCatching { out.flush() }
        runCatching { out.close() }
    }
}
