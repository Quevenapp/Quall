package com.quall.android.capture

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import com.quall.android.core.LogSeguro as Log
import com.quall.android.capture.dv.QuallDv
import java.io.FileDescriptor
import java.nio.ByteBuffer

/**
 * **O que o gravador precisa saber para abrir o arquivo** (`docs/teleprompter-com-camera.md` §14.4 e
 * §14.10): os parâmetros dos dois codificadores, já saídos deles. O SPS e o PPS vêm separados
 * (`csd-0`, `csd-1`), com o código de início, como o `MediaCodec` os dá.
 */
class FormatosDaGravacao(
    val largura: Int,
    val altura: Int,
    val sps: ByteArray,
    val pps: ByteArray,
    val taxaDoSom: Int,
    val canaisDoSom: Int,
    val bitrateDoSom: Int,
    val asc: ByteArray,
    val padraoDeCor: Int,
    val faixaDeCor: Int,
    val transferencia: Int,
)

/**
 * **O muxer da gravação local** (§14.4): o `GravadorDaCamera` fala com isto, e não com a
 * `libqualldv` direto. Duas implementações: [MuxerQuallDv] (o MP4 fragmentado de sempre, nos
 * aparelhos com a `libqualldv`, arm64) e [MuxerMediaMuxer] (o `MediaMuxer` do Android, nos que não
 * têm — o 32 bits). As regras de tempo (§5.2) ficam **acima** daqui, iguais nas duas.
 *
 * Tudo roda na thread do gravador, menos [nome] e [limiteDeBytes].
 */
interface MuxerDaGravacao {
    /** `qualldv` ou `mediamuxer`: o diário diz qual gravou. */
    val nome: String

    /** O maior arquivo que este muxer escreve direito; o gravador para antes. */
    val limiteDeBytes: Long

    /** Os dois formatos chegaram: abre. Uma exceção aqui é **falha ao abrir** (§14.3). */
    fun abrir(f: FormatosDaGravacao)

    /** Um quadro: carimbo e duração em 1/90000 s, a partir do zero do arquivo. Negativo: recusado. */
    fun video(b: ByteBuffer, pts90k: Long, dur90k: Long, chave: Boolean): Int

    /** Um pacote AAC: carimbo e duração em amostras, a partir do zero. Negativo: recusado. */
    fun som(b: ByteBuffer, ptsEmAmostras: Long, durEmAmostras: Int): Int

    /**
     * Fecha. Devolve `null` se o arquivo ficou legível, ou o motivo. [fechar] é chamado uma vez,
     * mesmo sem [abrir] (então não há arquivo, e devolve `null`).
     */
    fun fechar(): String?

    /** Uma linha para o `fechado` do gravador (a cópia crua, no `MediaMuxer`). */
    fun linha(): String = "gravador=$nome"
}

/** O MP4 fragmentado da `libqualldv` (a fita e a gravação da câmera no arm64), como era. */
class MuxerQuallDv(private val fd: Int) : MuxerDaGravacao {
    override val nome = "qualldv"
    override val limiteDeBytes = Long.MAX_VALUE
    private var mp4 = 0L
    private var ultimoFsync = 0L

    override fun abrir(f: FormatosDaGravacao) {
        mp4 = QuallDv.mp4AbrirCamera(
            fd, f.largura, f.altura, f.sps + f.pps, f.taxaDoSom, f.canaisDoSom, f.bitrateDoSom, f.asc,
            f.padraoDeCor, f.faixaDeCor, f.transferencia,
        )
        if (mp4 == 0L) throw IllegalStateException("o MP4 não abriu (ver o logcat, QuallDv)")
    }

    override fun video(b: ByteBuffer, pts90k: Long, dur90k: Long, chave: Boolean): Int {
        val r = QuallDv.mp4VideoComDuracao(mp4, b, b.position(), b.remaining(), pts90k, dur90k, chave)
        sincronizarAsVezes()
        return r
    }

    override fun som(b: ByteBuffer, ptsEmAmostras: Long, durEmAmostras: Int): Int {
        val r = QuallDv.mp4Som(mp4, b, b.position(), b.remaining(), ptsEmAmostras, durEmAmostras)
        sincronizarAsVezes()
        return r
    }

    /** fsync a cada ~10 s: numa queda de energia de verdade, o que foi escrito não some. */
    private fun sincronizarAsVezes() {
        val agora = android.os.SystemClock.elapsedRealtime()
        if (agora - ultimoFsync > 10_000) {
            ultimoFsync = agora
            QuallDv.sincronizar(fd)
        }
    }

    override fun fechar(): String? {
        if (mp4 == 0L) return null
        val r = QuallDv.mp4Fechar(mp4)
        mp4 = 0L
        return if (r < 0) "o MP4 não fechou direito ($r)" else null // i18n-fora: detalhe técnico do muxer (diário)
    }
}

/**
 * **O `MediaMuxer` do Android** (§14.4), nos aparelhos sem a `libqualldv`.
 *
 * - **o `moov` só sai no [fechar]**: um processo morto gravando deixa um MP4 sem índice. Por isso
 *   cada amostra vai também à [copia] (§14.4, proposta 1), que a volta remonta;
 * - **os formatos montados aqui**, e não o `outputFormat` dos codificadores: nenhuma chave de atraso
 *   do AAC chega ao `MPEG4Writer`, e o atraso continua compensado uma vez só, no carimbo do gravador;
 * - `setOrientationHint(0)`: o divisor já entrega o quadro de pé (o fMP4 também não tem matriz);
 * - **4 GB** (hipótese pela leitura do `MPEG4Writer` do AOSP: sem o deslocamento de 64 bits, que o
 *   `MediaMuxer` não pede, o arquivo para em 2³² bytes, e o `writeSampleData` pode prender em vez de
 *   falhar): [limiteDeBytes] em 3,8 GB, e o gravador corta antes, na thread dele.
 */
class MuxerMediaMuxer(
    fd: FileDescriptor,
    /** A cópia crua ao lado, ou `null` (a remontagem, que lê de uma cópia e não escreve outra). */
    copia: CopiaCrua.Escritor?,
    /**
     * Com a trilha de som. `false` só na remontagem de uma cópia sem nenhum pacote de som na faixa
     * da imagem: o `MPEG4Writer` recusa no `stop()` uma trilha sem amostra (a revisão do código, 2).
     */
    private val comSom: Boolean = true,
) : MuxerDaGravacao {
    private var copia: CopiaCrua.Escritor? = copia
    companion object {
        private const val TAG = "QuallGravacao"
        const val LIMITE = 3_800_000_000L

        /** O formato de vídeo que o `MediaMuxer` recebe: só o que ele precisa (§14.10, item 1). */
        fun formatoDoVideo(f: FormatosDaGravacao): MediaFormat =
            MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, f.largura, f.altura).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(f.sps))
                setByteBuffer("csd-1", ByteBuffer.wrap(f.pps))
                setInteger(MediaFormat.KEY_COLOR_STANDARD, f.padraoDeCor)
                setInteger(MediaFormat.KEY_COLOR_RANGE, f.faixaDeCor)
                setInteger(MediaFormat.KEY_COLOR_TRANSFER, f.transferencia)
            }

        /** O de som: o ASC e a taxa, **sem** `encoder-delay` (o carimbo já desconta o atraso). */
        fun formatoDoSom(f: FormatosDaGravacao): MediaFormat =
            MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, f.taxaDoSom, f.canaisDoSom).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(f.asc))
                setInteger(MediaFormat.KEY_BIT_RATE, f.bitrateDoSom)
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            }
    }

    override val nome = "mediamuxer"
    override val limiteDeBytes = LIMITE

    /** Construído já: um fd que o `MediaMuxer` recusa é falha ao abrir, antes do primeiro quadro. */
    private val muxer = MediaMuxer(fd, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private var trilhaVideo = -1
    private var trilhaSom = -1
    private var comecou = false
    private var taxaDoSom = 48_000
    private val info = MediaCodec.BufferInfo()
    private var resultadoDaCopia = "sem_copia"

    override fun abrir(f: FormatosDaGravacao) {
        taxaDoSom = f.taxaDoSom
        trilhaVideo = muxer.addTrack(formatoDoVideo(f))
        if (comSom) trilhaSom = muxer.addTrack(formatoDoSom(f))
        muxer.setOrientationHint(0)
        muxer.start()
        comecou = true
        // A cópia que não abre (o disco cheio, a pasta sumida) não é falha do gravador (a revisão do
        // código, 3): a gravação segue sem ela, e o diário diz.
        try {
            copia?.abrir(f)
        } catch (e: Exception) {
            Log.w(TAG, "gravador: a cópia crua não abriu (${e.javaClass.simpleName}: ${Log.erroExterno(e.message)}); a gravação segue sem ela")
            runCatching { copia?.fechar() }
            copia = null
            resultadoDaCopia = "falhou"
        }
    }

    override fun video(b: ByteBuffer, pts90k: Long, dur90k: Long, chave: Boolean): Int {
        val us = ParametrosDaGravacao.de90kUs(pts90k)
        val r = escrever(trilhaVideo, b, us, chave)
        if (r >= 0) copia?.amostra(true, chave, us, b)
        return r
    }

    override fun som(b: ByteBuffer, ptsEmAmostras: Long, durEmAmostras: Int): Int {
        if (!comSom) return 0
        val us = ptsEmAmostras * 1_000_000L / taxaDoSom
        val r = escrever(trilhaSom, b, us, true)
        if (r >= 0) copia?.amostra(false, true, us, b)
        return r
    }

    private fun escrever(trilha: Int, b: ByteBuffer, us: Long, chave: Boolean): Int {
        info.set(b.position(), b.remaining(), us, if (chave) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
        return try {
            // O `writeSampleData` lê de `offset` a `offset+size` sem mexer na posição do buffer.
            muxer.writeSampleData(trilha, b, info)
            0
        } catch (e: Exception) {
            Log.e(TAG, "gravador: o MediaMuxer recusou a amostra: ${e.javaClass.simpleName}: ${Log.erroExterno(e.message)}")
            -1
        }
    }

    /** MP4 EOS metadata sets the final sample duration without duplicating a reference slice. */
    fun fimDoVideo(ptsUs: Long) {
        if (!comecou || trilhaVideo < 0) return
        info.set(0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        muxer.writeSampleData(trilhaVideo, ByteBuffer.allocateDirect(0), info)
    }

    override fun fechar(): String? {
        var erro: String? = null
        if (comecou) {
            try {
                muxer.stop()
            } catch (e: Exception) {
                erro = "o MediaMuxer não fechou o arquivo (${e.javaClass.simpleName}: ${e.message})" // i18n-fora: detalhe técnico do muxer (diário)
            }
        }
        runCatching { muxer.release() }
        // **A cópia não é apagada aqui** (a revisão do código, 1): só depois de o arquivo ser
        // publicado (`GravacaoDaTela`), senão um processo morto entre o `stop` e a publicação, ou um
        // `parar` que desistiu antes deste fim, perderia um MP4 bom.
        copia?.let { resultadoDaCopia = it.fechar() }
        return erro
    }

    override fun linha(): String = "gravador=$nome copia_crua=$resultadoDaCopia"
}
