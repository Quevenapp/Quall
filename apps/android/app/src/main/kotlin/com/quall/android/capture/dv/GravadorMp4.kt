package com.quall.android.capture.dv

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * A gravação da fita num MP4: H.264 1280×720 e AAC, com o muxer da libavformat
 * (`movflags=hybrid_fragmented`: fragmentado enquanto grava, MP4 comum ao fechar) sobre um fd.
 *
 * **Os números são os do 720p do próprio S24** (`/vendor/etc/media_profiles.xml`, lido no aparelho
 * em 22/09/2026): H.264 1280×720 a 30 fps e 12 Mbit/s; AAC 96 kbit/s a 48 kHz. O perfil é mono, e a
 * fita é estéreo: vai **estéreo a 96 kbit/s**, o mesmo espaço sem jogar fora o estéreo (escolha
 * relatada ao Pessoa Exemplo).
 *
 * **O tempo é de mídia**, e não de relógio: o quadro n da gravação está em n × 1001/30000 s. O
 * som chega do C já em 48 kHz (a fita de 32 kHz é reamostrada) e **ancorado no quadro**: ao fim do
 * quadro n o total de amostras fica a menos de meio quadro de (n+1) × 1601,6. Quadro sem som (fita
 * em branco, dropout no AAUX) vira silêncio, e o som adiantado é cortado; a pausa da fita não vira
 * buraco no arquivo.
 *
 * **A placa de captura** ([daPlaca], a P4 adiantada, `docs/placa-de-captura-usb.md` §9.6): o
 * vídeo no tamanho nativo (640x480, sem ampliar) e **carimbado pela chegada** (o CLOCK_MONOTONIC do
 * quadro, relativo ao primeiro: a placa manda ~29,9/s, e n × 1001/30000 escorregaria contra o som),
 * escrito com a duração de cada quadro (`mp4AbrirCamera`, 1/90000, um pacote retido até o seguinte
 * dizer a duração; o último sai com [QUADRO_90K]). O som não vem do quadro: é o PCM da placa ([SomDaPlaca]),
 * duplicado para estéreo e já posto na linha do tempo do vídeo ([LinhaDoSomDaPlaca]); aqui ele
 * entra pelo mesmo [aoSom], com o tempo pela contagem de amostras. Sem som ([comSom] falso, ou
 * [semSom]), o MP4 abre só com o vídeo.
 *
 * Threads: a `quall-dv` chama [aoSom]/[aoQuadro] (pela [FonteDv.SaidaDeGravacao]; na placa, o
 * [aoSom] vem da thread do `AudioRecord`); a thread `quall-gravador` drena os dois codecs e escreve
 * o MP4; [parar] é chamado de qualquer thread e espera o fim.
 */
class GravadorMp4(
    private val fd: Int,
    override val largura: Int = 1280,
    override val altura: Int = 720,
    private val bitrateVideo: Int = BITRATE_VIDEO,
    private val daPlaca: Boolean = false,
    comSom: Boolean = true,
    /** Os quadros por segundo da fonte (as HDMI em 720p: 60): o encoder e o nível H.264 seguem. */
    private val fps: Int = 30,
    /** A fonte é alta definição (HDMI): a cor declarada é BT.709. */
    private val hd: Boolean = false,
    /** HEVC (H.265) no lugar do H.264 (a escolha da pessoa na placa, §14.5). */
    private val hevc: Boolean = false,
) : FonteDv.SaidaDeGravacao {
    private val mime get() = if (hevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
    private val padraoDeCor get() = if (hd) MediaFormat.COLOR_STANDARD_BT709 else MediaFormat.COLOR_STANDARD_BT601_NTSC


    private val video: MediaCodec
    override val superficie: Surface

    @Volatile private var som: MediaCodec? = null
    private val taxaDoSom = 48000
    private var amostrasEnviadas = 0L
    private var ultimoFsync = 0L
    @Volatile private var falhaDoSom: String? = null
    @Volatile var somPerdido = 0L
        private set
    /** As amostras (por canal) que foram ao encoder de som. */
    val amostrasDeSom: Long get() = amostrasEnviadas
    /** Placa: o carimbo (CLOCK_MONOTONIC, ns) do primeiro quadro gravado; -1 antes dele. */
    @Volatile var t0Ns = -1L
        private set
    /** Placa: o carimbo do último quadro que foi ao encoder (o fim do vídeo é ele + [QUADRO_NS]); -1 antes. */
    @Volatile var ultimoQuadroNs = -1L
        private set
    // placa: o pacote de vídeo retido até o seguinte dizer a duração (pts em 1/90000)
    private var retido: ByteArray? = null
    private var retidoPts = 0L
    private var retidoChave = false
    /**
     * O atraso do encoder AAC (`encoder-delay` do formato de saída, ou [ATRASO_AAC]), em amostras:
     * sai do PTS do som, e os pacotes que ficam antes de 0 caem. O muxer mp4 do FFmpeg não faz
     * lista de edição a partir do `initial_padding` (a revisão do código, A2).
     */
    private var atrasoDoSom = -1

    private var mp4 = 0L
    private var formatoVideo: MediaFormat? = null
    private var formatoSom: MediaFormat? = null
    private class Pendente(val ehVideo: Boolean, val dados: ByteArray, val pts: Long, val extra: Int, val duracao: Long)
    private val pendentes = ArrayList<Pendente>()

    @Volatile var quadros = 0L
        private set
    @Volatile var bytes = 0L
        private set
    @Volatile var erro: String? = null
        private set
    @Volatile private var fim = false
    @Volatile private var fimEm = 0L
    private val thread: Thread

    init {
        val f = MediaFormat.createVideoFormat(mime, largura, altura)
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        f.setInteger(MediaFormat.KEY_BIT_RATE, bitrateVideo)
        f.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        f.setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, 1f)
        f.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        f.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
        f.setInteger(MediaFormat.KEY_COLOR_STANDARD, padraoDeCor)
        // Sem quadro B: o muxer recebe pts = dts (a revisão, A10).
        f.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
        f.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        val nome = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(f)
            ?: throw IllegalStateException(UsbDv.frase(R.string.placa_sem_encoder_video, if (hevc) "HEVC" else "H.264", largura, altura))
        video = MediaCodec.createByCodecName(nome)
        val caps = video.codecInfo.getCapabilitiesForType(mime)
        // O menor nível que cabe o tamanho e os quadros por segundo (640x480 a 30 e a fita: 3.1).
        val nivel = maxOf(31, com.quall.android.capture.ParametrosDaGravacao.nivelMinimo(largura, altura, fps) ?: 51)
        // (No HEVC o perfil e o nível ficam com o encoder: Main, e o nível que o tamanho pede.)
        val high = !hevc && caps.profileLevels.any { it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh }
        if (high) {
            f.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
            f.setInteger(MediaFormat.KEY_LEVEL, when (nivel) {
                31 -> MediaCodecInfo.CodecProfileLevel.AVCLevel31
                32 -> MediaCodecInfo.CodecProfileLevel.AVCLevel32
                40 -> MediaCodecInfo.CodecProfileLevel.AVCLevel4
                42 -> MediaCodecInfo.CodecProfileLevel.AVCLevel42
                50 -> MediaCodecInfo.CodecProfileLevel.AVCLevel5
                else -> MediaCodecInfo.CodecProfileLevel.AVCLevel51
            })
        }
        try {
            video.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            superficie = video.createInputSurface()
            video.start()
        } catch (e: Exception) {
            runCatching { video.release() }
            throw e
        }
        Log.i(TAG, "gravador: $nome ${largura}x$altura ${bitrateVideo / 1_000_000} Mbit/s " +
            "a $fps qps, ${if (hevc) "HEVC" else if (high) "High ${nivel / 10}.${nivel % 10}" else "perfil padrão"}, ${if (hd) "BT.709" else "BT.601"} limitada, sem B" +
            if (daPlaca) ", placa: carimbo pela chegada" else "")
        // O som sobe já, a 48 kHz: a trilha existe mesmo que a fita comece sem som (a revisão, A2).
        // Sem som (a placa sem a permissão), quem cria diz o motivo por [semSom].
        som = if (comSom) abrirSom(taxaDoSom) else null
        thread = Thread({ drenar() }, "quall-gravador").also { it.start() }
    }

    // ---- da thread quall-dv -------------------------------------------------------------------

    override fun aoSom(pcm: ByteBuffer, amostras: Int, n: Long) {
        val c = som ?: return
        if (fim || falhaDoSom != null) return
        try {
            var feito = 0
            val total = amostras * 4
            val limite = android.os.SystemClock.elapsedRealtime() + 200
            while (feito < total && !fim) {
                val i = c.dequeueInputBuffer(20_000)
                if (i < 0) {
                    // O encoder de som não pega entrada há 200 ms: o resto deste quadro cai (e conta),
                    // em vez de a thread da câmera ficar presa aqui.
                    if (android.os.SystemClock.elapsedRealtime() > limite) { somPerdido += (total - feito) / 4; break }
                    continue
                }
                val b = c.getInputBuffer(i) ?: continue
                val k = minOf(b.capacity(), total - feito) and 3.inv()
                pcm.limit(feito + k).position(feito)
                b.clear()
                b.put(pcm)
                val ptsUs = amostrasEnviadas * 1_000_000L / taxaDoSom
                c.queueInputBuffer(i, 0, k, ptsUs, 0)
                amostrasEnviadas += k / 4
                feito += k
            }
        } catch (e: Exception) {
            falhaDoSom = UsbDv.frase(R.string.placa_encoder_de_som_falhou, "${e.javaClass.simpleName}: ${e.message}")
            Log.w(TAG, "gravador: ${Log.erroExterno(falhaDoSom)}")
        }
    }

    override fun aoQuadro(n: Long) {
        quadros = n + 1
    }

    override fun aoPrimeiroQuadro(tsNs: Long) {
        if (t0Ns < 0) t0Ns = tsNs
    }

    override fun aoQuadroCarimbado(tsNs: Long) {
        ultimoQuadroNs = tsNs
    }

    /** O som não virá (o `AudioRecord` não abriu ou morreu): o MP4 não espera por ele. */
    fun semSom(motivo: String) {
        if (falhaDoSom == null) falhaDoSom = motivo
        Log.w(TAG, "gravador: sem som: ${Log.erroExterno(motivo)}")
    }

    private fun abrirSom(taxa: Int): MediaCodec? {
        val f = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, taxa, 2)
        f.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        f.setInteger(MediaFormat.KEY_BIT_RATE, BITRATE_SOM)
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        return try {
            val nome = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(f)
                ?: throw IllegalStateException(UsbDv.frase(R.string.placa_sem_encoder_aac, taxa))
            MediaCodec.createByCodecName(nome).also {
                it.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                it.start()
                Log.i(TAG, "gravador: som $nome $taxa Hz estéreo ${BITRATE_SOM / 1000} kbit/s")
            }
        } catch (e: Exception) {
            falhaDoSom = UsbDv.frase(R.string.placa_sem_encoder_de_som, e.message ?: e.javaClass.simpleName)
            Log.w(TAG, "gravador: ${Log.erroExterno(falhaDoSom)}")
            null
        }
    }

    // ---- da thread quall-gravador -------------------------------------------------------------

    private fun drenar() {
        val info = MediaCodec.BufferInfo()
        var videoAcabou = false
        var somAcabou = false
        var eosDoSomPedido = false
        try {
            while (!(videoAcabou && (somAcabou || som == null))) {
                if (fim && fimEm > 0 && android.os.SystemClock.elapsedRealtime() - fimEm > 5000) {
                    Log.w(TAG, "gravador: o fim de fluxo não veio em 5 s; fecho com o que chegou")
                    break
                }
                if (!videoAcabou) {
                    val i = video.dequeueOutputBuffer(info, 10_000)
                    if (i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        formatoVideo = video.outputFormat
                        abrirMp4SePronto()
                    } else if (i >= 0) {
                        val b = video.getOutputBuffer(i)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                            b.position(info.offset).limit(info.offset + info.size)
                            val chave = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            if (daPlaca) {
                                reter(b, com.quall.android.capture.ParametrosDaGravacao.us90k(info.presentationTimeUs), chave)
                            } else {
                                val pts = (info.presentationTimeUs * 30000L + 500_000L) / 1_000_000L
                                escrever(true, b, pts, if (chave) 1 else 0)
                            }
                        }
                        video.releaseOutputBuffer(i, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) videoAcabou = true
                    }
                }
                val s = som
                if (s != null && !somAcabou) {
                    if (fim && !eosDoSomPedido && falhaDoSom != null) {
                        // O encoder de som em erro não recebe fim de fluxo: dá o som por encerrado.
                        somAcabou = true
                    } else if (fim && !eosDoSomPedido) {
                        val i = s.dequeueInputBuffer(10_000)
                        if (i >= 0) {
                            s.queueInputBuffer(i, 0, 0, amostrasEnviadas * 1_000_000L / taxaDoSom, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            eosDoSomPedido = true
                        }
                    }
                    val i = s.dequeueOutputBuffer(info, if (videoAcabou) 10_000 else 0)
                    if (i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        formatoSom = s.outputFormat
                        abrirMp4SePronto()
                    } else if (i >= 0) {
                        val b = s.getOutputBuffer(i)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                            b.position(info.offset).limit(info.offset + info.size)
                            if (atrasoDoSom < 0) atrasoDoSom = atrasoDoEncoder(s)
                            val pts = (info.presentationTimeUs * taxaDoSom + 500_000L) / 1_000_000L - atrasoDoSom
                            if (pts >= 0) escrever(false, b, pts, 1024)
                        }
                        s.releaseOutputBuffer(i, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) somAcabou = true
                    }
                }
                if (fim && videoAcabou && som == null) break
            }
            soltarRetido(null)
        } catch (e: Exception) {
            erro = UsbDv.frase(R.string.placa_gravacao_falhou, "${e.javaClass.simpleName}: ${e.message}")
            Log.e(TAG, "gravador: ${Log.erroExterno(erro)}", e)
        } finally {
            fecharMp4()
        }
    }

    /**
     * O MP4 abre quando o vídeo já deu o formato (SPS/PPS) e o som também, ou quando já passou um
     * segundo de vídeo sem som (fita sem áudio). Até lá, os pacotes esperam em [pendentes].
     */
    private fun abrirMp4SePronto() {
        if (mp4 != 0L) return
        val fv = formatoVideo ?: return
        val semSom = (som == null || falhaDoSom != null) && (quadros > 30 || fim)
        val fs = formatoSom
        if (fs == null && !semSom) return
        // H.264: SPS (csd-0) e PPS (csd-1); HEVC: VPS, SPS e PPS juntos no csd-0.
        val csd = bytesDe(fv.getByteBuffer("csd-0")) + (fv.getByteBuffer("csd-1")?.let { bytesDe(it) } ?: ByteArray(0))
        val asc = fs?.getByteBuffer("csd-0")?.let { bytesDe(it) }
        mp4 = if (daPlaca) {
            // O vídeo em 1/90000 com a duração de cada quadro (a chegada, e não 1001/30000), e a cor
            // declarada: BT.601, faixa limitada (a placa, medido na P0, §8.1), SDR.
            QuallDv.mp4AbrirCamera(fd, largura, altura, csd, if (fs != null) taxaDoSom else 0, 2, BITRATE_SOM, asc,
                padraoDeCor, MediaFormat.COLOR_RANGE_LIMITED, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        } else {
            QuallDv.mp4Abrir(fd, largura, altura, csd, if (fs != null) taxaDoSom else 0, 2, BITRATE_SOM, asc, ATRASO_AAC)
        }
        if (mp4 == 0L) throw IllegalStateException(UsbDv.frase(R.string.placa_mp4_nao_abriu))
        val tmp = ByteBuffer.allocateDirect(1 shl 20)
        for (p in pendentes) {
            val b = if (p.dados.size <= tmp.capacity()) tmp else ByteBuffer.allocateDirect(p.dados.size)
            b.clear(); b.put(p.dados); b.flip()
            gravarPacote(p.ehVideo, b, p.pts, p.extra, p.duracao)
        }
        pendentes.clear()
    }

    /**
     * Placa: o pacote de vídeo fica retido até o seguinte chegar, que diz a duração dele (a
     * diferença dos carimbos). O último sai em [soltarRetido] com a duração de um quadro a 30.
     */
    private fun reter(b: ByteBuffer, pts90k: Long, chave: Boolean) {
        soltarRetido(pts90k)
        retido = ByteArray(b.remaining()).also { b.get(it) }
        retidoPts = pts90k
        retidoChave = chave
    }

    private fun soltarRetido(proximoPts: Long?) {
        val d = retido ?: return
        retido = null
        val dur = if (proximoPts != null && proximoPts > retidoPts) proximoPts - retidoPts else QUADRO_90K
        val b = ByteBuffer.allocateDirect(d.size)
        b.put(d); b.flip()
        escrever(true, b, retidoPts, if (retidoChave) 1 else 0, dur)
    }

    private fun escrever(ehVideo: Boolean, b: ByteBuffer, pts: Long, extra: Int, duracao: Long = 0) {
        if (mp4 == 0L) {
            abrirMp4SePronto()
            if (mp4 == 0L) {
                if (pendentes.size > 600) throw IllegalStateException(UsbDv.frase(R.string.placa_mp4_nao_abriu_600))
                val copia = ByteArray(b.remaining()).also { b.get(it) }
                pendentes += Pendente(ehVideo, copia, pts, extra, duracao)
                return
            }
        }
        gravarPacote(ehVideo, b, pts, extra, duracao)
    }

    private fun gravarPacote(ehVideo: Boolean, b: ByteBuffer, pts: Long, extra: Int, duracao: Long) {
        val n = b.remaining()
        val r = if (ehVideo && daPlaca) QuallDv.mp4VideoComDuracao(mp4, b, b.position(), n, pts, duracao, extra == 1)
        else if (ehVideo) QuallDv.mp4Video(mp4, b, b.position(), n, pts, extra == 1)
        else QuallDv.mp4Som(mp4, b, b.position(), n, pts, extra)
        if (r < 0) throw IllegalStateException(UsbDv.frase(R.string.placa_muxer_recusou, r))
        bytes += n
        // fsync a cada ~10 s: numa queda de energia de verdade, o que já foi escrito não some.
        val agora = android.os.SystemClock.elapsedRealtime()
        if (agora - ultimoFsync > 10_000) {
            ultimoFsync = agora
            QuallDv.sincronizar(fd)
        }
    }

    private fun fecharMp4() {
        if (mp4 != 0L) {
            val r = QuallDv.mp4Fechar(mp4)
            if (r < 0 && erro == null) erro = UsbDv.frase(R.string.placa_mp4_nao_fechou, r)
            mp4 = 0L
        }
        runCatching { video.stop() }
        runCatching { video.release() }
        runCatching { som?.stop() }
        runCatching { som?.release() }
        runCatching { superficie.release() }
    }

    /**
     * Encerra: o vídeo recebe fim de fluxo, o som também, a thread drena o resto, escreve o
     * trailer e sai. Chame depois de [FonteDv.desligarGravador] (nenhum quadro a mais chega).
     * Devolve o erro, se houve.
     */
    fun parar(): String? {
        fimEm = android.os.SystemClock.elapsedRealtime()
        fim = true
        runCatching { video.signalEndOfInputStream() }
        thread.join(10_000)
        if (thread.isAlive) {
            erro = erro ?: UsbDv.frase(R.string.placa_gravador_nao_terminou)
            Log.e(TAG, "gravador: ${Log.erroExterno(erro)}")
        }
        Log.i(TAG, "gravador: parado; quadros=$quadros bytes=$bytes som=${falhaDoSom?.let { Log.erroExterno(it) } ?: "ok"} erro=${erro?.let { Log.erroExterno(it) } ?: "nenhum"}")
        return erro
    }

    /** A falha do som (o aviso que não é falha — a entrada errada, o silêncio — é do [DonoDaPlaca]). */
    val avisoDoSom: String? get() = falhaDoSom

    private fun atrasoDoEncoder(c: MediaCodec): Int {
        val f = runCatching { c.outputFormat }.getOrNull()
        val d = if (f != null && f.containsKey(MediaFormat.KEY_ENCODER_DELAY)) f.getInteger(MediaFormat.KEY_ENCODER_DELAY) else -1
        val usado = if (d >= 0) d else ATRASO_AAC
        Log.i(TAG, "gravador: atraso do AAC = $usado amostras (${if (d >= 0) "declarado pelo encoder" else "medido"})")
        return usado
    }

    val terminou: Boolean get() = !thread.isAlive

    private fun bytesDe(b: ByteBuffer?): ByteArray {
        if (b == null) return ByteArray(0)
        val d = b.duplicate()
        d.position(0)
        return ByteArray(d.remaining()).also { d.get(it) }
    }

    companion object {
        private const val TAG = "QuallDv"
        const val BITRATE_VIDEO = 12_000_000
        /** Um quadro a 30/s em 1/90000 (a duração do último quadro da placa). */
        const val QUADRO_90K = 3000L
        /** O mesmo quadro em ns (o fim do vídeo para o som, [SomDaPlaca.encerrar]). */
        const val QUADRO_NS = QUADRO_90K * 1_000_000_000L / 90_000L
        const val BITRATE_SOM = 96_000
        /**
         * O atraso do encoder AAC, em amostras, quando o encoder não declara `encoder-delay`.
         * Medido no S24 (c2.android.aac.encoder, 48 kHz estéreo) com o clarão e o bipe sintéticos
         * (`tools/espiao-dv-s24/prova-gravacao.py --sincronia`): o som saía +42,7 ms atrasado em
         * todos os 11 clarões, 2048 amostras exatas. Múltiplo de 1024: tirado do PTS, os dois
         * primeiros pacotes caem e o resto fica no tempo certo.
         */
        const val ATRASO_AAC = 2048
    }
}
