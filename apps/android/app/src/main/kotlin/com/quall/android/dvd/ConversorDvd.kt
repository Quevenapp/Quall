package com.quall.android.dvd

import com.quall.android.escritorYuv420
import com.quall.android.R
import android.hardware.HardwareBuffer
import android.graphics.ImageFormat
import android.hardware.DataSpace
import android.media.ImageWriter
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import com.quall.android.capture.dv.QuallDv
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * **O MP4 do título** (`docs/dvd-para-mp4.md` §2.6, a D1c): o quadro e o som que o pipeline em C
 * ([QuallDvd]) entrega viram H.264 pelo hardware (`MediaCodec` + `ImageWriter`, o caminho YUV da
 * gravação da fita, sem RGB no meio) e um AAC por faixa de som, e vão ao MP4 fragmentado da
 * `libqualldv` (`midia.c`, `mp4_abre_faixas`) — **todas as faixas** (a resposta do Pessoa Exemplo, §2.9): a
 * primeira é a padrão, as outras são faixas a mais, com o idioma do IFO.
 *
 * - **H.264 a [BITRATE_VIDEO] (3 Mbit/s), GOP de 1 s, sem quadro B**, no tamanho de pixel quadrado
 *   ([tamanhoDeSaida]); a cor BT.601 (525 ou 625 linhas) de faixa limitada, como veio do disco;
 * - **taxa variável**: o carimbo de cada quadro é o do C (o PTS do disco no tempo do título), e a
 *   duração no MP4 é a distância até o seguinte (o *pulldown* do filme sai em 3003/4504);
 * - **o AAC**: 48 kHz estéreo a [BITRATE_SOM], o carimbo pela contagem de amostras (o C já ancorou
 *   o som no PTS, com silêncio nos buracos) menos o atraso do encoder, como na fita;
 * - **o parcial é jogável**: o MP4 é `hybrid_fragmented`, e parar no meio (o Cancelar, o leitor
 *   que caiu, o limite do sistema) fecha o arquivo normalmente com o que já foi.
 *
 * Threads: [converter] roda na thread de quem chama (a `quall-dvd-conversao` do serviço) e chama o
 * C; a `quall-dvd-mp4` drena os codificadores e escreve o MP4.
 */
class ConversorDvd(
    private val h: Long,
    private val fd: Int,
    /** Do IFO; sem ele, o que o fluxo disse ([QuallDvd.Info]). */
    private val pal: Boolean,
    private val aspecto169: Boolean,
    /** O número de faixas de som que o C entrega (`Info.faixas.size`). */
    private val nFaixas: Int,
    /** O idioma de cada faixa, em ISO 639-2 (três letras; "und" quando o IFO não diz). */
    private val idiomas: List<String>,
    /**
     * A largura já decidida por outro encoder (a gravação da transmissão, a T4: a da rede, 854 ou 848),
     * para os dois quadros serem o mesmo; `null` decide aqui.
     */
    larguraPedida: Int? = null,
) {
    val largura: Int
    val altura: Int
    private val video: MediaCodec
    private val sons: List<MediaCodec>
    private val escritor: ImageWriter
    private val threadDasImagens = HandlerThread("quall-dvd-imagens").also { it.start() }
    private val travaImagens = Object()
    private var livres = MAX_IMAGENS

    @Volatile private var fim = false
    @Volatile private var fimEm = 0L
    /** O erro que parou o conversor, para a tela (sem idioma: [Frase]); `null` sem erro. */
    @Volatile var erro: Frase? = null
        private set
    @Volatile var quadros = 0L
        private set
    @Volatile var bytes = 0L
        private set
    /** O carimbo (90 kHz) do último quadro que foi ao encoder: o progresso em tempo do título. */
    @Volatile var tempo90k = 0L
        private set
    @Volatile private var ultimaDuracao90k = 3003L
    private val amostrasEnviadas = LongArray(nFaixas)
    /** A thread do MP4: sobe no começo de [converter] (depois de todo o estado desta classe existir). */
    @Volatile private var saida: Thread? = null

    // o estado da thread do MP4
    private var mp4 = 0L
    private var formatoVideo: MediaFormat? = null
    private val formatosSom = arrayOfNulls<MediaFormat>(nFaixas)
    private val atrasos = IntArray(nFaixas) { -1 }
    private class Pendente(val faixa: Int, val dados: ByteArray, val pts: Long, val dur: Long, val chave: Boolean)
    private val pendentes = ArrayList<Pendente>()
    private var retido: ByteArray? = null
    private var retidoPts = 0L
    private var retidoChave = false
    private var ultimoFsync = 0L

    init {
        val (w0, a) = tamanhoDeSaida(pal, aspecto169)
        val w = larguraPedida ?: w0
        val nome = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(formatoDoVideo(w, a))
            ?: throw IllegalStateException("sem encoder H.264 ${w}x$a neste aparelho")
        val codec = MediaCodec.createByCodecName(nome)
        val tipo = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
        // 854 não é múltiplo de 16: se o encoder não aceita, 848 (a imagem estica 0,7 %).
        largura = if (larguraPedida != null || tipo.videoCapabilities?.isSizeSupported(w, a) != false) w else (w / 16) * 16
        altura = a
        if (largura != w) Log.w(TAG, "o encoder $nome não aceita ${w}x$a: ${largura}x$altura")
        video = codec
        val fv = formatoDoVideo(largura, altura)
        val high = tipo.profileLevels.any { it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh }
        if (high) {
            fv.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
            fv.setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel31)
        }
        val abertos = ArrayList<MediaCodec>()
        var w2: ImageWriter? = null
        try {
            video.configure(fv, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val sup = video.createInputSurface()
            video.start()
            w2 = if (Build.VERSION.SDK_INT >= 33) {
                // O formato pelo HardwareBuffer (YCBCR_420_888): `setImageFormat` + `setDataSpace` deu
                // RGBA no S24 (a gravação da fita, `FonteDv.novoEscritor`).
                ImageWriter.Builder(sup)
                    .setMaxImages(MAX_IMAGENS)
                    .setHardwareBufferFormat(HardwareBuffer.YCBCR_420_888)
                    .setDataSpace(if (pal) DataSpace.DATASPACE_BT601_625 else DataSpace.DATASPACE_BT601_525)
                    .build()
            } else {
                escritorYuv420(sup, MAX_IMAGENS)
            }
            w2.setOnImageReleasedListener({
                synchronized(travaImagens) { livres++; travaImagens.notifyAll() }
            }, Handler(threadDasImagens.looper))
            repeat(nFaixas) { abertos += abrirSom() }
        } catch (e: Exception) {
            runCatching { w2?.close() }
            abertos.forEach { runCatching { it.release() } }
            runCatching { video.release() }
            threadDasImagens.quitSafely()
            throw e
        }
        escritor = w2
        sons = abertos
        Log.i(TAG, "conversor: $nome ${largura}x$altura ${BITRATE_VIDEO / 1000} kbit/s " +
            "${if (high) "High 3.1" else "perfil padrão"}, ${if (pal) "BT.601 625" else "BT.601 525"}, " +
            "$nFaixas faixa(s) AAC ${BITRATE_SOM / 1000} kbit/s (${idiomas.joinToString(",")})")
    }

    private fun formatoDoVideo(w: Int, a: Int) = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, a).apply {
        setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        setInteger(MediaFormat.KEY_BIT_RATE, BITRATE_VIDEO)
        setInteger(MediaFormat.KEY_FRAME_RATE, if (pal) 25 else 30)
        setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, 1f)
        setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
        setInteger(MediaFormat.KEY_COLOR_STANDARD, padraoDeCor)
        setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
    }

    private val padraoDeCor get() =
        if (pal) MediaFormat.COLOR_STANDARD_BT601_PAL else MediaFormat.COLOR_STANDARD_BT601_NTSC

    private fun abrirSom(): MediaCodec {
        val f = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, TAXA, 2)
        f.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        f.setInteger(MediaFormat.KEY_BIT_RATE, BITRATE_SOM)
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        val nome = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(f)
            ?: throw IllegalStateException("sem encoder AAC 48 kHz estéreo")
        return MediaCodec.createByCodecName(nome).also {
            it.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            it.start()
        }
    }

    // ---- a thread da conversão ---------------------------------------------------------------

    /**
     * O laço: passo do C, os quadros ao encoder, o som de cada faixa ao AAC dela. Volta no fim do
     * título ([QuallDvd.FIM]: `null`), num erro do C (o código), ou quando [parar] diz (`null`: a
     * parada é de quem chamou). O MP4 é fechado em [encerrar], que quem chama chama sempre.
     */
    fun converter(parar: () -> Boolean): Int? {
        garantirSaida()
        val tempos = LongArray(2)
        val pcm = ByteBuffer.allocateDirect(PCM_POR_VEZ * 4).order(ByteOrder.nativeOrder())
        while (!parar() && erro == null) {
            val r = QuallDvd.passo(h)
            if (r < 0) return r
            if (r == QuallDvd.QUADRO) {
                while (QuallDvd.quadro(h, tempos) == 1) {
                    if (!quadroAoEncoder(tempos[0], tempos[1], parar) { img ->
                        val p = img.planes
                        QuallDvd.escrever(h, p[0].buffer, p[0].rowStride, p[1].buffer, p[2].buffer,
                            p[1].rowStride, p[1].pixelStride, img.width, img.height)
                    }) break
                }
            }
            for (k in 0 until nFaixas) {
                while (true) {
                    val n = QuallDvd.som(h, k, pcm, PCM_POR_VEZ)
                    if (n <= 0) break
                    somAoEncoder(k, pcm, n, parar)
                }
            }
            if (r == QuallDvd.FIM) return null
        }
        return null
    }

    @Synchronized
    private fun garantirSaida() {
        if (saida == null) saida = Thread({ drenar() }, "quall-dvd-mp4").also { it.start() }
    }

    // ---- a gravação da transmissão (a T4: `GravacaoDaTransmissao`) ------------------------------

    /**
     * O quadro já escalado (a transmissão o tem num buffer seu) vai ao encoder por [copiar], com o
     * carimbo [pts90k] do arquivo. Espera no máximo 40 ms por um `Image` livre; sem ele, o quadro cai
     * (`false`) — quem chama é o ritmo da transmissão, que não pode parar.
     */
    fun gravarQuadro(pts90k: Long, dur90k: Long, copiar: (android.media.Image) -> Unit): Boolean {
        garantirSaida()
        val antes = quadros
        val limite = SystemClock.elapsedRealtime() + 40
        quadroAoEncoder(pts90k, dur90k, { SystemClock.elapsedRealtime() > limite }) { img -> copiar(img); 0 }
        return quadros > antes
    }

    /** [amostras] estéreo s16 da faixa [k] em [pcm] (direto, ordem nativa) ao AAC dela. */
    fun gravarSom(k: Int, pcm: ByteBuffer, amostras: Int) {
        garantirSaida()
        if (k in 0 until nFaixas && amostras > 0) somAoEncoder(k, pcm, amostras) { erro != null }
    }

    private fun quadroAoEncoder(pts90k: Long, dur90k: Long, parar: () -> Boolean, escrever: (android.media.Image) -> Int): Boolean {
        synchronized(travaImagens) {
            // O encoder segura as Images um pouco; a thread do MP4 drena a saída enquanto isso.
            while (livres <= 0) {
                if (parar() || erro != null) return false
                travaImagens.wait(20)
            }
            livres--
        }
        val img = try { escritor.dequeueInputImage() } catch (e: Exception) {
            synchronized(travaImagens) { livres++ }
            erro = Frase(R.string.dvd_erro_escritor, e.message ?: e.javaClass.simpleName)
            return false
        }
        var foi = false
        try {
            val r = escrever(img)
            if (r == 0) {
                img.timestamp = pts90k * 100_000L / 9L  // 90 kHz → ns
                escritor.queueInputImage(img)
                foi = true
                quadros++
                tempo90k = pts90k
                ultimaDuracao90k = dur90k
            } else {
                Log.w(TAG, "conversor: o quadro em $pts90k não foi escrito ($r)")
            }
        } finally {
            if (!foi) { runCatching { img.close() }; synchronized(travaImagens) { livres++ } }
        }
        return true
    }

    private fun somAoEncoder(k: Int, pcm: ByteBuffer, amostras: Int, parar: () -> Boolean) {
        val c = sons[k]
        val total = amostras * 4
        var feito = 0
        try {
            while (feito < total) {
                if (parar() || erro != null) return
                val i = c.dequeueInputBuffer(10_000)
                if (i < 0) continue
                val b = c.getInputBuffer(i) ?: continue
                val n = minOf(b.capacity(), total - feito) and 3.inv()
                pcm.limit(feito + n).position(feito)
                b.clear()
                b.put(pcm)
                c.queueInputBuffer(i, 0, n, amostrasEnviadas[k] * 1_000_000L / TAXA, 0)
                amostrasEnviadas[k] += (n / 4).toLong()
                feito += n
            }
        } finally {
            pcm.clear()
        }
    }

    /**
     * Fecha: o fim de fluxo aos codificadores, a thread do MP4 drena o resto e escreve o `moov`.
     * Devolve o erro, se houve.
     */
    fun encerrar(): Frase? {
        fimEm = SystemClock.elapsedRealtime()
        fim = true
        runCatching { video.signalEndOfInputStream() }
        for ((k, c) in sons.withIndex()) {
            runCatching {
                val limite = SystemClock.elapsedRealtime() + 2000
                while (SystemClock.elapsedRealtime() < limite) {
                    val i = c.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        c.queueInputBuffer(i, 0, 0, amostrasEnviadas[k] * 1_000_000L / TAXA, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        break
                    }
                }
            }
        }
        val t = saida
        if (t != null) {
            t.join(15_000)
            if (t.isAlive) erro = erro ?: Frase(R.string.dvd_erro_mp4_15s)
        } else {
            // A conversão nem começou: não há MP4; os codificadores só são soltos.
            runCatching { video.stop() }; runCatching { video.release() }
            for (c in sons) { runCatching { c.stop() }; runCatching { c.release() } }
        }
        runCatching { escritor.close() }
        threadDasImagens.quitSafely()
        Log.i(TAG, "conversor: encerrado; quadros=$quadros bytes=$bytes som=${amostrasEnviadas.joinToString(",")} " +
            "erro=${erro?.let { Log.erroExterno(it) } ?: "nenhum"}")
        return erro
    }

    /** O MP4 fechou (a thread saiu): o fd pode ser fechado. */
    val terminou: Boolean get() = saida?.isAlive != true

    // ---- a thread do MP4 ---------------------------------------------------------------------

    private fun drenar() {
        val info = MediaCodec.BufferInfo()
        var videoAcabou = false
        val somAcabou = BooleanArray(nFaixas)
        try {
            while (!(videoAcabou && somAcabou.all { it })) {
                if (fim && SystemClock.elapsedRealtime() - fimEm > 8000) {
                    Log.w(TAG, "conversor: o fim de fluxo não veio em 8 s; fecho com o que chegou")
                    break
                }
                if (!videoAcabou) {
                    val i = video.dequeueOutputBuffer(info, 5_000)
                    if (i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        formatoVideo = video.outputFormat
                        abrirSePronto()
                    } else if (i >= 0) {
                        val b = video.getOutputBuffer(i)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                            b.position(info.offset).limit(info.offset + info.size)
                            val pts = (info.presentationTimeUs * 9L + 50L) / 100L  // µs → 90 kHz
                            reter(b, pts, info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0)
                        }
                        video.releaseOutputBuffer(i, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) videoAcabou = true
                    }
                }
                for (k in 0 until nFaixas) {
                    if (somAcabou[k]) continue
                    val s = sons[k]
                    val i = s.dequeueOutputBuffer(info, 0)
                    if (i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        formatosSom[k] = s.outputFormat
                        abrirSePronto()
                    } else if (i >= 0) {
                        val b = s.getOutputBuffer(i)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                            b.position(info.offset).limit(info.offset + info.size)
                            if (atrasos[k] < 0) atrasos[k] = atrasoDoEncoder(s)
                            val pts = (info.presentationTimeUs * TAXA + 500_000L) / 1_000_000L - atrasos[k]
                            if (pts >= 0) escrever(k, b, pts, 1024, true)
                        }
                        s.releaseOutputBuffer(i, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) somAcabou[k] = true
                    }
                }
            }
            soltarRetido(null)
        } catch (e: Exception) {
            erro = Frase(R.string.dvd_conversao_falhou, Frase.cru("${e.javaClass.simpleName}: ${e.message}"))
            Log.e(TAG, "conversor: ${Log.erroExterno(erro)}", e)
        } finally {
            if (mp4 != 0L) {
                val r = QuallDv.mp4Fechar(mp4)
                if (r < 0 && erro == null) erro = Frase(R.string.dvd_erro_mp4_fechou, r)
                mp4 = 0L
            }
            runCatching { video.stop() }
            runCatching { video.release() }
            for (s in sons) { runCatching { s.stop() }; runCatching { s.release() } }
        }
    }

    /** O MP4 abre quando o vídeo e todas as faixas de som deram o formato. */
    private fun abrirSePronto() {
        if (mp4 != 0L) return
        val fv = formatoVideo ?: return
        if (formatosSom.any { it == null }) return
        val csd = bytesDe(fv.getByteBuffer("csd-0")) + bytesDe(fv.getByteBuffer("csd-1"))
        val ascs = Array(nFaixas) { bytesDe(formatosSom[it]!!.getByteBuffer("csd-0")) }
        mp4 = QuallDvd.mp4AbrirFaixas(fd, largura, altura, csd, ascs, idiomas.toTypedArray(), BITRATE_SOM,
            padraoDeCor, MediaFormat.COLOR_RANGE_LIMITED, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        if (mp4 == 0L) throw IllegalStateException("o MP4 não abriu (ver o logcat, QuallDv)")
        val tmp = ByteBuffer.allocateDirect(1 shl 20)
        for (p in pendentes) {
            val b = if (p.dados.size <= tmp.capacity()) tmp else ByteBuffer.allocateDirect(p.dados.size)
            b.clear(); b.put(p.dados); b.flip()
            gravar(p.faixa, b, p.pts, p.dur, p.chave)
        }
        pendentes.clear()
    }

    /** O pacote de vídeo espera o seguinte, que diz a duração dele; o último sai com a nominal. */
    private fun reter(b: ByteBuffer, pts90k: Long, chave: Boolean) {
        soltarRetido(pts90k)
        retido = ByteArray(b.remaining()).also { b.get(it) }
        retidoPts = pts90k
        retidoChave = chave
    }

    private fun soltarRetido(proximo: Long?) {
        val d = retido ?: return
        retido = null
        val dur = if (proximo != null && proximo > retidoPts) proximo - retidoPts else ultimaDuracao90k
        val b = ByteBuffer.allocateDirect(d.size)
        b.put(d); b.flip()
        escrever(-1, b, retidoPts, dur, retidoChave)
    }

    /** [faixa] -1 é o vídeo (pts e duração em 90 kHz); senão o som (em amostras). */
    private fun escrever(faixa: Int, b: ByteBuffer, pts: Long, dur: Long, chave: Boolean) {
        if (mp4 == 0L) {
            abrirSePronto()
            if (mp4 == 0L) {
                if (pendentes.size > MAX_PENDENTES) {
                    throw IllegalStateException("o MP4 não abriu em $MAX_PENDENTES pacotes (um encoder sem formato)")
                }
                pendentes += Pendente(faixa, ByteArray(b.remaining()).also { b.get(it) }, pts, dur, chave)
                return
            }
        }
        gravar(faixa, b, pts, dur, chave)
    }

    private fun gravar(faixa: Int, b: ByteBuffer, pts: Long, dur: Long, chave: Boolean) {
        val n = b.remaining()
        val r = if (faixa < 0) QuallDv.mp4VideoComDuracao(mp4, b, b.position(), n, pts, dur, chave)
        else QuallDvd.mp4SomDaFaixa(mp4, faixa, b, b.position(), n, pts, dur.toInt())
        if (r < 0) throw IllegalStateException("o muxer recusou um pacote ($r)")
        bytes += n
        val agora = SystemClock.elapsedRealtime()
        if (agora - ultimoFsync > 10_000) {
            ultimoFsync = agora
            QuallDv.sincronizar(fd)
        }
    }

    private fun atrasoDoEncoder(c: MediaCodec): Int {
        val f = runCatching { c.outputFormat }.getOrNull()
        val d = if (f != null && f.containsKey(MediaFormat.KEY_ENCODER_DELAY)) f.getInteger(MediaFormat.KEY_ENCODER_DELAY) else -1
        return if (d >= 0) d else ATRASO_AAC
    }

    private fun bytesDe(b: ByteBuffer?): ByteArray {
        if (b == null) return ByteArray(0)
        val d = b.duplicate()
        d.position(0)
        return ByteArray(d.remaining()).also { d.get(it) }
    }

    companion object {
        private const val TAG = "QuallDvd"
        const val BITRATE_VIDEO = 3_000_000
        const val BITRATE_SOM = 160_000
        const val TAXA = 48_000
        private const val MAX_IMAGENS = 4
        private const val PCM_POR_VEZ = 4096
        private const val MAX_PENDENTES = 4000
        /** O atraso do AAC quando o encoder não declara (o da fita, medido no S24). */
        private const val ATRASO_AAC = 2048

        /** O encoder H.264 do aparelho aceita 854×480 (senão 848, como a DV). */
        fun aceita854(): Boolean = runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(
                MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 854, 480)) != null
        }.getOrDefault(false)

        /**
         * O tamanho de saída em pixels quadrados (§2.5): 4:3 → 640×480 (NTSC) ou 768×576 (PAL);
         * 16:9 → 854×480 ou 1024×576.
         */
        fun tamanhoDeSaida(pal: Boolean, aspecto169: Boolean): Pair<Int, Int> = when {
            pal && aspecto169 -> 1024 to 576
            pal -> 768 to 576
            aspecto169 -> 854 to 480
            else -> 640 to 480
        }

        /** O idioma do IFO (ISO 639-1, duas letras) no do MP4 (ISO 639-2/T, três); "und" sem ele. */
        fun idioma639_2(duas: String?): String {
            val c = duas?.trim()?.lowercase() ?: return "und"
            return IDIOMAS[c] ?: "und"
        }

        private val IDIOMAS = mapOf(
            "pt" to "por", "en" to "eng", "es" to "spa", "fr" to "fra", "de" to "deu", "it" to "ita",
            "ja" to "jpn", "zh" to "zho", "ko" to "kor", "ru" to "rus", "nl" to "nld", "sv" to "swe",
            "da" to "dan", "no" to "nor", "fi" to "fin", "pl" to "pol", "cs" to "ces", "hu" to "hun",
            "el" to "ell", "tr" to "tur", "he" to "heb", "ar" to "ara", "hi" to "hin", "th" to "tha",
            "ca" to "cat", "la" to "lat", "ro" to "ron", "uk" to "ukr", "is" to "isl", "gl" to "glg",
            "eu" to "eus", "hr" to "hrv", "sk" to "slk", "sl" to "slv", "sr" to "srp", "bg" to "bul",
            "id" to "ind", "ms" to "msa", "vi" to "vie", "tl" to "tgl", "fa" to "fas",
        )
    }
}
