package com.quall.android.bancada

import android.app.Activity
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import com.quall.android.core.LogSeguro as Log
import java.io.File
import java.io.RandomAccessFile
import kotlin.concurrent.thread

/**
 * Codifica uma sequência YUV **de arquivo** com o `MediaCodec` deste aparelho.
 *
 * # Por que existe
 *
 * `docs/bancada.md` §8.40 e §8.41 tentaram medir quanto de imagem custa baixar o bitrate usando a
 * câmera, e **as duas falharam pelo mesmo motivo**: com fonte viva, duas capturas do *mesmo*
 * ajuste diferem tanto quanto duas de ajustes diferentes. Não era a cena mexendo — foi medido com
 * luz artificial constante, janelas fechadas, suporte rígido, ISO 1492 estável e variação
 * quadro-a-quadro de 0,7 nível. **Câmera viva não é fonte repetível**, porque o ruído do sensor é
 * aleatório por quadro, e nenhuma montagem física conserta isso.
 *
 * A única saída é dar ao codificador **os mesmos quadros duas vezes**. É o que esta tela faz: lê
 * YUV cru de um arquivo, empurra quadro a quadro, e grava o `.h264`. Com a origem sendo arquivo,
 * PSNR e SSIM contra ela valem — e `tools/qualidade-de-imagem.py` mede sem a ressalva de
 * procedência, porque não há casa de ninguém dentro do quadro.
 *
 * # A ressalva que não dá para eliminar
 *
 * Produção entra por **superfície** (`COLOR_FormatSurface`): a câmera desenha direto no buffer do
 * encoder, sem cópia. Fonte de arquivo entra por **byte buffer**, que é outro caminho de cor. Os
 * números absolutos daqui **não** são os de produção.
 *
 * O que vale é a **diferença entre os braços**: os dois recebem exatamente os mesmos pixels pelo
 * mesmo caminho, então tudo que o caminho de entrada acrescenta é comum aos dois e sai na
 * subtração. Esta bancada responde "quanto custa 6,87 contra 13,45 Mbps", não "qual o PSNR
 * absoluto do produto".
 *
 * # Como se usa
 *
 * ```sh
 * adb push fonte.yuv /sdcard/Android/data/com.quall.android/files/bancada/fonte.yuv
 * adb shell am start -n com.quall.android/.bancada.CodificaYuvActivity \
 *     --es entrada fonte.yuv --es saida saida-13500.h264 \
 *     --ei largura 1920 --ei altura 1080 --ei fps 30 --ei bitrate 13500000
 * adb logcat -s QuallCodificaYuv
 * ```
 *
 * O resultado sai no logcat como uma linha `RESULTADO ...` e o arquivo fica ao lado da entrada.
 */
class CodificaYuvActivity : Activity() {

    override fun onCreate(estado: Bundle?) {
        super.onCreate(estado)
        val pasta = File(getExternalFilesDir(null), "bancada").also { it.mkdirs() }
        val entrada = File(pasta, intent.getStringExtra("entrada") ?: "fonte.yuv")
        val saida = File(pasta, intent.getStringExtra("saida") ?: "saida.h264")
        val largura = intent.getIntExtra("largura", 1920)
        val altura = intent.getIntExtra("altura", 1080)
        val fps = intent.getIntExtra("fps", 30)
        val bitrate = intent.getIntExtra("bitrate", 6_750_000)
        val gop = intent.getFloatExtra("gop", 2f)
        // `modo` é opcional e **por padrão não é escrito**, porque produção também não escreve:
        // `KEY_BITRATE_MODE` não existe em nenhum ponto do app. Serve para testar se o piso de
        // 4,77 Mbps do `c2.mtk.avc.encoder` (§8.43) é o modo de taxa padrão dele.
        val modo = intent.getStringExtra("modo")

        thread(name = "quall-codifica-yuv") {
            val r = runCatching { correr(entrada, saida, largura, altura, fps, bitrate, gop, modo) }
            r.exceptionOrNull()?.let { Log.e(TAG, "RESULTADO erro=${it.javaClass.simpleName}: ${Log.erroExterno(it.message)}", it) }
            runOnUiThread { finish() }
        }
    }

    private fun correr(
        entrada: File,
        saida: File,
        largura: Int,
        altura: Int,
        fps: Int,
        bitrate: Int,
        gop: Float,
        modo: String?,
    ) {
        require(entrada.isFile) { "entrada não existe: $entrada" }
        val porQuadro = largura * altura * 3 / 2          // YUV420 planar, 12 bits por pixel
        val quadros = (entrada.length() / porQuadro).toInt()
        require(quadros > 0) { "arquivo menor que um quadro ($porQuadro bytes)" }

        val formato = MediaFormat.createVideoFormat(MIME, largura, altura).apply {
            // **A única diferença deliberada em relação a `H264SurfaceEncoder.formato()`.**
            // Lá é `COLOR_FormatSurface`, porque a câmera desenha direto. Aqui os pixels vêm de
            // arquivo, então é buffer flexível — e `getInputImage` resolve o leiaute que este
            // codec quiser (NV12, NV21, planar), em vez de eu adivinhar.
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, gop)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LATENCY, 1)
            }
            when (modo?.lowercase()) {
                "cbr" -> setInteger(MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                "vbr" -> setInteger(MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                "cq" -> setInteger(MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CQ)
                null -> Unit          // igual à produção: não escreve, e o codec usa o que quiser
                else -> error("modo desconhecido: $modo")
            }
            // `KEY_MAX_FPS_TO_ENCODER` fica de fora **de propósito**: ela descarta o excesso que um
            // produtor ao vivo entrega acima da taxa. Aqui não há produtor ao vivo, e descartar
            // quadro faria a saída deixar de corresponder à entrada — que é a base da medida.
        }

        val codec = MediaCodec.createEncoderByType(MIME)
        // **O nome tem de ser guardado antes do `release()`.** Depois dele, `codec.name` lança
        // "codec is released already" — e a linha de RESULTADO é escrita no fim, já no finally.
        val nomeDoCodec = codec.name
        Log.i(TAG, "codec=$nomeDoCodec ${largura}x$altura@$fps bitrate=$bitrate gop=$gop " +
            "quadros=$quadros modo=${modo ?: "(padrão do codec)"} entrada=${entrada.name}")
        codec.configure(formato, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        val fonte = RandomAccessFile(entrada, "r")
        val destino = saida.outputStream().buffered(1 shl 20)
        val info = MediaCodec.BufferInfo()
        var enviados = 0
        var recebidos = 0
        var bytes = 0L
        var fim = false
        val planoY = ByteArray(largura * altura)
        val planoU = ByteArray(largura * altura / 4)
        val planoV = ByteArray(largura * altura / 4)

        try {
            while (!fim) {
                if (enviados <= quadros) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        if (enviados == quadros) {
                            codec.queueInputBuffer(i, 0, 0, us(enviados, fps),
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            enviados++
                        } else {
                            fonte.seek(enviados.toLong() * porQuadro)
                            fonte.readFully(planoY); fonte.readFully(planoU); fonte.readFully(planoV)
                            // `getInputImage` entrega os três planos com o passo e o intervalo que
                            // ESTE codec usa. Copiar respeitando `rowStride`/`pixelStride` é o que
                            // faz o mesmo arquivo virar a mesma imagem em silícios diferentes.
                            val img = codec.getInputImage(i)!!
                            copiarPlano(planoY, img.planes[0], largura, altura)
                            copiarPlano(planoU, img.planes[1], largura / 2, altura / 2)
                            copiarPlano(planoV, img.planes[2], largura / 2, altura / 2)
                            codec.queueInputBuffer(i, 0, porQuadro, us(enviados, fps), 0)
                            enviados++
                        }
                    }
                }
                var o = codec.dequeueOutputBuffer(info, 10_000)
                while (o >= 0) {
                    val buf = codec.getOutputBuffer(o)!!
                    buf.position(info.offset); buf.limit(info.offset + info.size)
                    val bloco = ByteArray(info.size)
                    buf.get(bloco)
                    destino.write(bloco)
                    bytes += info.size
                    // `BUFFER_FLAG_CODEC_CONFIG` é SPS+PPS e não conta como quadro.
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                        recebidos++
                    }
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) fim = true
                    codec.releaseOutputBuffer(o, false)
                    o = codec.dequeueOutputBuffer(info, 0)
                }
            }
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { fonte.close() }
            runCatching { destino.flush(); destino.close() }
        }

        val segundos = quadros.toDouble() / fps
        Log.i(TAG, "RESULTADO arquivo=${saida.name} codec=$nomeDoCodec bitrate_pedido=$bitrate " +
            "quadros_entrada=$quadros quadros_saida=$recebidos bytes=$bytes " +
            "bitrate_obtido=${(bytes * 8 / segundos).toLong()}")
    }

    /** Copia um plano respeitando o passo de linha e o intervalo de pixel que o codec declarou. */
    private fun copiarPlano(origem: ByteArray, plano: android.media.Image.Plane, w: Int, h: Int) {
        val buf = plano.buffer
        val passo = plano.rowStride
        val intervalo = plano.pixelStride
        if (intervalo == 1 && passo == w) {
            buf.put(origem, 0, w * h)                      // caso denso: uma cópia só
            return
        }
        val linha = ByteArray(passo)
        var pos = 0
        for (y in 0 until h) {
            if (intervalo == 1) {
                buf.position(y * passo)
                buf.put(origem, pos, w)
            } else {
                // Semiplanar: U e V intercalados no mesmo buffer, um byte sim outro não.
                buf.position(y * passo)
                buf.get(linha, 0, minOf(passo, buf.remaining()))
                buf.position(y * passo)
                for (x in 0 until w) linha[x * intervalo] = origem[pos + x]
                buf.put(linha, 0, minOf(passo, buf.remaining()))
            }
            pos += w
        }
    }

    private fun us(quadro: Int, fps: Int): Long = quadro.toLong() * 1_000_000L / fps

    private companion object {
        const val TAG = "QuallCodificaYuv"
        const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
    }
}
