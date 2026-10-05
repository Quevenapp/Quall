package com.quall.bancada.sondar5

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.view.Surface
import kotlin.concurrent.thread

/**
 * Um `MediaCodec` H.264 com entrada por superfície. A saída é **contada e descartada**: o PTS, o
 * tamanho e a hora de cada pacote; nenhum byte de vídeo é guardado.
 */
class Codificador(val nome: String, val largura: Int, val altura: Int, taxaBits: Int, fps: Int = 30) {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    val entrada: Surface
    private val pts = ArrayList<Long>()
    @Volatile var primeiraSaidaNs = 0L; private set
    @Volatile var bytes = 0L; private set
    @Volatile var chaves = 0; private set
    @Volatile private var parar = false
    private val drenagem: Thread

    init {
        val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, largura, altura).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, taxaBits)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
        }
        codec.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        entrada = codec.createInputSurface()
        codec.start()
        drenagem = thread(name = "drena-$nome") { drenar() }
    }

    private fun drenar() {
        val info = MediaCodec.BufferInfo()
        while (!parar) {
            val i = try { codec.dequeueOutputBuffer(info, 10_000) } catch (e: IllegalStateException) { break }
            if (i < 0) continue
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                synchronized(pts) {
                    if (primeiraSaidaNs == 0L) primeiraSaidaNs = System.nanoTime()
                    pts.add(info.presentationTimeUs)
                    bytes += info.size
                    if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) chaves++
                }
            }
            runCatching { codec.releaseOutputBuffer(i, false) }
        }
    }

    fun ptsUs(): List<Long> = synchronized(pts) { ArrayList(pts) }

    fun liberar() {
        parar = true
        drenagem.join(2000)
        runCatching { codec.stop() }
        runCatching { codec.release() }
        runCatching { entrada.release() }
    }
}
