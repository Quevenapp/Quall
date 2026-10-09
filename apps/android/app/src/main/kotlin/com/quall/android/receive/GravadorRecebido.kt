package com.quall.android.receive

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.os.StatFs
import android.provider.MediaStore
import androidx.core.content.FileProvider
import com.quall.android.audio.PresetDeAudio
import com.quall.android.capture.CopiaCrua
import com.quall.android.capture.FormatosDaGravacao
import com.quall.android.capture.MuxerMediaMuxer
import com.quall.android.capture.ParametrosDaGravacao
import com.quall.android.core.LogSeguro as Log
import com.quall.android.core.QuallNative
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicLong

/** Received H.264 is muxed directly; only received PCM is encoded to AAC. No capture permission. */
class GravadorRecebido(
    private val contexto: Context,
    private val caixa: Long,
    private val videoTrack: Long,
    private val audioTrack: () -> Long,
    preset: PresetDeAudio?,
    private val presetDeAudio: () -> PresetDeAudio? = { preset },
    /** Offline debug probe, never supplied by the product UI. Uses the same mux/AAC/finalization. */
    private val quadroDeBancada: ((ByteBuffer, LongArray, Int) -> Int)? = null,
) {
    private data class Som(val pcm: ShortArray, val n: Int, val seq: Long, val ts: Long, val taxa: Int, val canais: Int, val chegadaUs: Long)
    private data class Destino(val nome: String, val uri: Uri, val fd: ParcelFileDescriptor, val copia: File, val id: Long)
    private val filaSom = ArrayBlockingQueue<Som>(250) // <= five seconds at the native 20 ms slot.
    private val somPerdido = AtomicLong()
    @Volatile private var fim = false
    @Volatile private var vivo = true
    private val thread = Thread({ rodar() }, "quall-gravacao-recebida")
    private var destino: Destino? = null
    private var muxer: MuxerMediaMuxer? = null
    private var aac: MediaCodec? = null
    private var erro: String? = null
    private var tempo = TempoDaGravacaoRecebida()
    private var guarda = ContinuidadeH264Recebida()
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private var parte = 1
    private var bytes = 0L
    private var quadros = 0L
    private var quadrosParte = 0L
    private var t0ChegadaUs = 0L
    private var zeroSomChegadaUs: Long? = null
    private var zeroSomTs: Long? = null
    private var proximaAmostra = 0L
    private var ultimaSaidaSomUs = -1L
    private var atrasoAac = 1024L
    private var relogioChegada = false
    private var offsetVideo: Long? = null
    private var offsetSom: Long? = null
    private var presetAtual = preset
    @Volatile private var audioAtivo = preset != null
    private val canais get() = presetAtual?.canais ?: 1
    private val somInfo = MediaCodec.BufferInfo()
    private var ultimoPliMs = 0L
    private var ultimoEspacoMs = 0L
    private var ultimoEstadoMs = 0L
    private var uriSalva: Uri? = null
    private var nomeSalvo = ""
    private val dono = Any()
    @Volatile private var paradaUs: Long? = null
    private var ultimaChegadaVideoUs = 0L
    private var fimParteFixadoUs: Long? = null

    fun iniciar(): Boolean {
        if (!GravacaoRecebidaBus.tentarIniciar(dono)) { vivo = false; return false }
        try { thread.start() } catch (e: Exception) {
            vivo = false
            GravacaoRecebidaBus.concluir(dono, GravacaoRecebidaBus.Estado(GravacaoRecebidaBus.Fase.ERRO, detalhe = "iniciar"))
            throw e
        }
        return true
    }
    /** Audio playback owns its array; copy into bounded queue without waiting for codecs or disk. */
    fun som(pcm: ShortArray, n: Int, seq: Long, ts: Long, taxa: Int, canais: Int) {
        if (fim || !vivo || !audioAtivo) return
        if (filaSom.remainingCapacity() == 0) { somPerdido.incrementAndGet(); return }
        val item = Som(pcm.copyOf(n * canais), n, seq, ts, taxa, canais, SystemClock.elapsedRealtimeNanos() / 1000)
        if (!filaSom.offer(item)) somPerdido.incrementAndGet()
    }
    /** Caller first detaches the native mailbox; session/track handles stay alive until this returns. */
    fun pedirParada() {
        if (!fim) {
            paradaUs = SystemClock.elapsedRealtimeNanos() / 1000
            fim = true
            GravacaoRecebidaBus.publicar(dono, GravacaoRecebidaBus.Estado(GravacaoRecebidaBus.Fase.SALVANDO,
                nome = destino?.nome.orEmpty(), parte = parte))
        }
    }
    fun parar() { pedirParada(); thread.join() }
    fun terminou(): Boolean = !vivo

    private fun rodar() {
        val b = ByteBuffer.allocateDirect(4 * 1024 * 1024)
        val meta = LongArray(6)
        val inicio = SystemClock.elapsedRealtime()
        var descartados = 0L
        try {
            pedirIdr()
            while (true) {
                if (!audioAtivo) {
                    val novoPreset = presetDeAudio()
                    if (novoPreset != null) {
                        val tinhaParte = muxer != null
                        if (tinhaParte) { fecharParte(); if (erro != null) error(erro!!); proximaParte() }
                        presetAtual = novoPreset; audioAtivo = true
                        tempo = TempoDaGravacaoRecebida(); guarda = ContinuidadeH264Recebida()
                        offsetVideo = null; offsetSom = null
                        proximaAmostra = 0; ultimaSaidaSomUs = -1
                        zeroSomTs = null; zeroSomChegadaUs = null; relogioChegada = false
                        fimParteFixadoUs = null
                        pedirIdr()
                    }
                }
                b.clear()
                val n = quadroDeBancada?.invoke(b, meta, if (fim) 0 else 10) ?: QuallNative.frameBoxTake(caixa, b, meta, if (fim) 0 else 10)
                if (n < 0 && fim) break
                if (n > 0) {
                    if (meta[3] + meta[4] + meta[5] > descartados) {
                        descartados = meta[3] + meta[4] + meta[5]
                        guarda.ruptura()
                    }
                    val dados = ByteArray(n); b.position(0); b.get(dados)
                    receberVideo(dados, meta[0])
                }
                lerRelogio()
                drenarSomRecebido()
                // Keep silent or interrupted tracks moving while recording. At most two seconds
                // remain for stop/finalization; an hour with the sender mic off must not encode
                // an hour of silence only after the user taps Stop.
                if (audioAtivo && muxer != null && (relogioChegada || (offsetVideo != null && offsetSom != null))) {
                    preencherAte((fimDaImagemUs() - 2_000_000).coerceAtLeast(0) * 48_000 / 1_000_000)
                }
                drenarAac()
                if (quadros == 0L && SystemClock.elapsedRealtime() - inicio > 12_000) error("idr")
                verificarEspaco()
                if (n <= 0 && quadros == 0L) pedirIdr()
                publicarEstado()
            }
            // Capture-clock aligned audio may arrive after the last frame; only data already queued
            // belongs to this recording. Background/disconnect finalization never reopens local inputs.
            fimParteFixadoUs = fimDaImagemUs()
            drenarSomRecebido(forcar = true)
            if (audioAtivo && quadrosParte > 0) {
                preencherAte(fimDaImagemUs() * 48_000 / 1_000_000)
                fimAac()
            }
        } catch (e: Exception) {
            erro = e.message ?: "io"
            Log.w(TAG, "gravação recebida falhou: ${e.javaClass.simpleName}: ${Log.erroExterno(e.message)}")
        } finally {
            GravacaoRecebidaBus.publicar(dono, GravacaoRecebidaBus.Estado(GravacaoRecebidaBus.Fase.SALVANDO, nome = destino?.nome.orEmpty(), parte = parte))
            fecharParte()
            vivo = false
            val fase = if (erro != null) GravacaoRecebidaBus.Fase.ERRO else if (uriSalva != null) GravacaoRecebidaBus.Fase.SALVA else GravacaoRecebidaBus.Fase.PARADA
            GravacaoRecebidaBus.concluir(dono, GravacaoRecebidaBus.Estado(fase, nome = nomeSalvo, uri = uriSalva, detalhe = erro.orEmpty(), parte = parte))
            Log.i(TAG, "gravação recebida fechada: quadros=$quadros bytes=$bytes partes=$parte som_fila_perdido=${somPerdido.get()} relogio=${if (relogioChegada) "chegada" else "captura"}")
        }
    }

    private fun receberVideo(dados: ByteArray, timestampUs: Long) {
        val nals = ContinuidadeH264Recebida.nals(dados)
        val idr = nals.any { (it[0].toInt() and 31) == 5 }
        val novoSps = nals.firstOrNull { (it[0].toInt() and 31) == 7 }?.let { START + it }
        val novoPps = nals.firstOrNull { (it[0].toInt() and 31) == 8 }?.let { START + it }
        val mudou = muxer != null && ((novoSps != null && !novoSps.contentEquals(sps)) || (novoPps != null && !novoPps.contentEquals(pps)))
        if (mudou) {
            // Even an in-place SPS/PPS change gets a separate playable part, not stale avcC metadata.
            fimParteFixadoUs = fimDaImagemUs()
            drenarSomRecebido(forcar = true)
            if (audioAtivo) { preencherAte(fimDaImagemUs() * 48_000 / 1_000_000); fimAac() }
            fecharParte()
            if (erro != null) error(erro!!)
            proximaParte()
            tempo = TempoDaGravacaoRecebida(); guarda = ContinuidadeH264Recebida()
            offsetVideo = null; offsetSom = null; proximaAmostra = 0; ultimaSaidaSomUs = -1
            zeroSomTs = null; zeroSomChegadaUs = null; relogioChegada = false
            fimParteFixadoUs = null
        }
        if (novoSps != null) sps = novoSps
        if (novoPps != null) pps = novoPps
        if (!guarda.aceitar(dados)) { pedirIdr(); return }
        if (muxer == null) {
            if (!idr || sps == null || pps == null) { pedirIdr(); return }
            val info = Sps.ler(ByteBuffer.wrap(sps!!), 0, sps!!.size) ?: error("formato")
            abrirParte(info)
            t0ChegadaUs = SystemClock.elapsedRealtimeNanos() / 1000
            Log.i(TAG, "gravação recebida: parte=$parte idr_zero_us=$timestampUs tamanho=${info.largura}x${info.altura}")
        }
        val pts = tempo.video(timestampUs, idr) ?: return
        ultimaChegadaVideoUs = SystemClock.elapsedRealtimeNanos() / 1000
        val normalizado = ContinuidadeH264Recebida.paraMediaMuxer(dados)
        val buffer = ByteBuffer.allocateDirect(normalizado.size).put(normalizado).apply { flip() }
        if (muxer!!.video(buffer, ParametrosDaGravacao.us90k(pts), 3000, idr) < 0) error("io")
        bytes += normalizado.size
        quadros++; quadrosParte++
        if (bytes >= MuxerMediaMuxer.LIMITE - 16 * 1024 * 1024) error("tamanho")
    }

    private fun abrirParte(info: Sps.Info) {
        val nome = "Quall-Recebido-" + SimpleDateFormat("yyyyMMdd-HHmmss-SSS", Locale.US).format(Date()) + "-p$parte.mp4"
        val destinoNovo = criarDestino(contexto, nome)
        destino = destinoNovo
        val asc = byteArrayOf(0x11, if (canais == 1) 0x88.toByte() else 0x90.toByte()) // AAC-LC, 48 kHz.
        val f = FormatosDaGravacao(info.largura, info.altura, sps!!, pps!!, 48_000, canais, 128_000, asc,
            if (info.altura >= 720) MediaFormat.COLOR_STANDARD_BT709 else MediaFormat.COLOR_STANDARD_BT601_NTSC,
            if (info.faixaCompleta == true) MediaFormat.COLOR_RANGE_FULL else MediaFormat.COLOR_RANGE_LIMITED,
            MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        muxer = MuxerMediaMuxer(destinoNovo.fd.fileDescriptor,
            CopiaCrua.Escritor(destinoNovo.copia, destinoNovo.id, nome, esperarFechamento = true), audioAtivo)
        muxer!!.abrir(f)
        if (audioAtivo) {
            val formato = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, 48_000, canais).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
            }
            aac = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).also {
                it.configure(formato, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); it.start()
            }
        }
    }

    private fun lerRelogio() {
        if (tempo.zeroVideoUs == null || relogioChegada) return
        if (quadroDeBancada != null) { offsetVideo = 0; offsetSom = 0; return }
        val out = LongArray(2)
        if (offsetVideo == null && QuallNative.trackCaptureOffsetRawUs(videoTrack, out) == 1) offsetVideo = out[0]
        val track = audioTrack()
        if (audioAtivo && track != 0L && offsetSom == null && QuallNative.trackCaptureOffsetRawUs(track, out) == 1) offsetSom = out[0]
        if (audioAtivo && (offsetVideo == null || offsetSom == null) && SystemClock.elapsedRealtimeNanos() / 1000 - t0ChegadaUs >= 5_000_000) {
            relogioChegada = true
            Log.w(TAG, "gravação recebida: relógio comum indisponível após 5s; alinhamento pela chegada")
        }
    }

    private fun drenarSomRecebido(forcar: Boolean = false) {
        if (!audioAtivo || muxer == null || tempo.zeroVideoUs == null) return
        if (offsetVideo == null || offsetSom == null) {
            if (!relogioChegada && !forcar) return
            relogioChegada = true
        }
        while (true) {
            val item = filaSom.peek() ?: break
            if (zeroSomTs == null) { zeroSomTs = item.ts; zeroSomChegadaUs = item.chegadaUs }
            val alinhado = if (relogioChegada) item.ts - zeroSomTs!! + zeroSomChegadaUs!! - t0ChegadaUs
                else item.ts + offsetSom!! - (tempo.zeroVideoUs!! + offsetVideo!!)
            // Keep the whole slot until video covers it. Trimming a live 20 ms slot at a 30 fps
            // boundary would throw away its tail and insert false silence on the next frame.
            if (!forcar && alinhado + item.n * 1_000_000L / item.taxa > fimDaImagemUs()) break
            filaSom.poll()
            val pts = tempo.som(item.ts, item.seq,
                if (relogioChegada) zeroSomChegadaUs!! - zeroSomTs!! else offsetSom!!,
                if (relogioChegada) t0ChegadaUs - tempo.zeroVideoUs!! else offsetVideo!!) ?: continue
            val inicio = pts * 48_000 / 1_000_000
            val n = item.n * 48_000 / item.taxa
            val fimVideo = fimDaImagemUs() * 48_000 / 1_000_000
            if (inicio >= fimVideo || inicio + n <= 0) continue
            preencherAte(inicio.coerceAtMost(fimVideo))
            val pular = (proximaAmostra - inicio).coerceAtLeast(0).toInt().coerceAtMost(n)
            val levar = minOf(n - pular, (fimVideo - proximaAmostra).coerceAtLeast(0).toInt())
            if (levar <= 0) continue
            val pcm = ShortArray(levar * canais)
            for (j in 0 until levar) {
                // PCMU 8 kHz → 48 kHz; linear interpolation, before any playback volume.
                val origem = (j + pular).toDouble() * item.taxa / 48_000
                val k = origem.toInt().coerceAtMost(item.n - 1)
                val k2 = minOf(k + 1, item.n - 1); val fracao = origem - k
                for (ch in 0 until canais) {
                    val c = minOf(ch, item.canais - 1)
                    pcm[j * canais + ch] = (item.pcm[k * item.canais + c] * (1 - fracao) + item.pcm[k2 * item.canais + c] * fracao).toInt().toShort()
                }
            }
            enviarPcm(pcm, levar)
        }
    }

    private fun preencherAte(amostra: Long) {
        while (proximaAmostra < amostra) {
            val n = minOf(960L, amostra - proximaAmostra).toInt()
            enviarPcm(ShortArray(n * canais), n)
        }
    }
    private fun enviarPcm(pcm: ShortArray, n: Int) {
        val codec = aac ?: return
        var feito = 0
        while (feito < n) {
            var idx = codec.dequeueInputBuffer(0)
            val limite = SystemClock.elapsedRealtime() + 500
            while (idx < 0) {
                drenarAac()
                if (SystemClock.elapsedRealtime() > limite) error("aac")
                Thread.sleep(2)
                idx = codec.dequeueInputBuffer(0)
            }
            val b = codec.getInputBuffer(idx) ?: error("aac")
            b.clear(); b.order(ByteOrder.nativeOrder())
            val k = minOf(n - feito, b.remaining() / (2 * canais))
            require(k > 0)
            b.asShortBuffer().put(pcm, feito * canais, k * canais)
            codec.queueInputBuffer(idx, 0, k * canais * 2, proximaAmostra * 1_000_000 / 48_000, 0)
            proximaAmostra += k; feito += k
            drenarAac()
        }
    }
    private fun drenarAac(): Boolean {
        val codec = aac ?: return false
        while (true) {
            val i = codec.dequeueOutputBuffer(somInfo, 0)
            if (i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val f = codec.outputFormat
                if (f.containsKey("encoder-delay")) atrasoAac = f.getInteger("encoder-delay").toLong()
                continue
            }
            if (i < 0) return false
            val eos = somInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            try {
                if (somInfo.size > 0 && somInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                    val pts = somInfo.presentationTimeUs - atrasoAac * 1_000_000 / 48_000
                    val fimVideo = fimDaImagemUs()
                    if (pts >= 0 && pts > ultimaSaidaSomUs && pts < fimVideo) {
                        val b = codec.getOutputBuffer(i) ?: error("aac")
                        b.position(somInfo.offset); b.limit(somInfo.offset + somInfo.size)
                        if (muxer!!.som(b, pts * 48_000 / 1_000_000, 1024) < 0) error("io")
                        ultimaSaidaSomUs = pts; bytes += somInfo.size
                    }
                }
            } finally { codec.releaseOutputBuffer(i, false) }
            if (eos) return true
        }
    }
    private fun fimAac() {
        val codec = aac ?: return
        var idx = codec.dequeueInputBuffer(0)
        val limite = SystemClock.elapsedRealtime() + 2_000
        while (idx < 0 && SystemClock.elapsedRealtime() < limite) { drenarAac(); Thread.sleep(2); idx = codec.dequeueInputBuffer(0) }
        if (idx < 0) error("aac")
        codec.queueInputBuffer(idx, 0, 0, proximaAmostra * 1_000_000 / 48_000, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        while (SystemClock.elapsedRealtime() < limite) { if (drenarAac()) return; Thread.sleep(2) }
        error("aac")
    }
    private fun pedirIdr() {
        val agora = SystemClock.elapsedRealtime()
        if (agora - ultimoPliMs >= 250) { if (videoTrack != 0L) QuallNative.trackRequestIdr(videoTrack); ultimoPliMs = agora }
    }
    private fun verificarEspaco() {
        val agora = SystemClock.elapsedRealtime()
        if (agora - ultimoEspacoMs < 2_000) return
        ultimoEspacoMs = agora
        val dir = contexto.getExternalFilesDir(null) ?: contexto.filesDir
        if (StatFs(dir.path).availableBytes < 128 * 1024 * 1024) error("espaco")
    }
    private fun publicarEstado() {
        if (fim) return
        val agora = SystemClock.elapsedRealtime()
        if (agora - ultimoEstadoMs < 500) return
        ultimoEstadoMs = agora
        val e = GravacaoRecebidaBus.Estado(if (quadrosParte == 0L) GravacaoRecebidaBus.Fase.ESPERANDO_IDR else GravacaoRecebidaBus.Fase.GRAVANDO,
            segundos = fimDaImagemUs() / 1_000_000, nome = destino?.nome.orEmpty(), parte = parte)
        GravacaoRecebidaBus.publicar(dono, e)
    }
    private fun fimDaImagemUs(): Long = fimParteFixadoUs ?: tempo.fimUs(
        SystemClock.elapsedRealtimeNanos() / 1000, ultimaChegadaVideoUs, paradaUs)
    private fun proximaParte() {
        if (parte >= 64) error("partes")
        parte++
    }
    private fun fecharParte() {
        runCatching { aac?.stop() }; runCatching { aac?.release() }; aac = null
        val d = destino ?: return
        val fimFalhou = if (quadrosParte > 0) runCatching { muxer?.fimDoVideo(fimDaImagemUs()) }.exceptionOrNull() else null
        val falha = runCatching { muxer?.fechar() }.getOrElse { it.message ?: "io" } ?: fimFalhou?.message
        muxer = null
        runCatching { d.fd.close() }
        if (quadrosParte > 0 && falha == null) {
            val publicada = runCatching {
                if (Build.VERSION.SDK_INT >= 29) contexto.contentResolver.update(d.uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null) > 0 else true
            }.getOrDefault(false)
            if (publicada) {
                CopiaCrua.apagar(d.copia); uriSalva = d.uri; nomeSalvo = d.nome
                contexto.getSharedPreferences("quall-gravacao-recebida", Context.MODE_PRIVATE).edit()
                    .putString("uri", d.uri.toString()).putString("nome", d.nome).apply()
            }
            else if (erro == null) erro = "publicar"
        } else if (quadrosParte == 0L) {
            runCatching { if (Build.VERSION.SDK_INT >= 29) contexto.contentResolver.delete(d.uri, null, null) else File(contexto.getExternalFilesDir(Environment.DIRECTORY_MOVIES), d.nome).delete() }
            CopiaCrua.apagar(d.copia)
        } else if (erro == null) erro = "salvar"
        destino = null; quadrosParte = 0
    }
    companion object {
        private const val TAG = "QuallGravacaoRecebida"
        private val START = byteArrayOf(0, 0, 0, 1)
        /** Android 9 has no scoped MediaStore; recover its private MP4 from the same journal. */
        @Synchronized fun recuperarAndroid9(c: Context) {
            if (Build.VERSION.SDK_INT >= 29 || GravacaoRecebidaBus.atual.ocupada) return
            val dir = c.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: return
            val copias = CopiaCrua.listar(File(dir, "recuperacao"))
            val comecos = GravacaoRecebidaBus.comecos
            for ((_, copia) in copias) {
                if (GravacaoRecebidaBus.atual.ocupada || GravacaoRecebidaBus.comecos != comecos) return
                runCatching {
                    val leitura = copia.inputStream().buffered().use { CopiaCrua.varrer(it) }
                    val nome = leitura?.cabecalho?.nome ?: return@runCatching
                    require(nome == File(nome).name && nome.startsWith("Quall-Recebido-") && nome.endsWith(".mp4"))
                    if (!leitura.legivel || CopiaCrua.contarTentativa(copia) > 2) { CopiaCrua.apagar(copia); return@runCatching }
                    val original = File(dir, nome)
                    val pronto = runCatching {
                        val x = android.media.MediaExtractor()
                        try { x.setDataSource(original.path); x.trackCount > 0 } finally { x.release() }
                    }.getOrDefault(false)
                    if (!pronto) {
                        val novo = File(dir, nome.removeSuffix(".mp4") + "-recuperado.mp4")
                        val resultado = ParcelFileDescriptor.open(novo, ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_TRUNCATE).use {
                            CopiaCrua.remontar(copia, it.fileDescriptor)
                        }
                        if (resultado.erro != null || resultado.quadros == 0) { novo.delete(); return@runCatching }
                        original.delete()
                        require(novo.renameTo(original))
                    }
                    CopiaCrua.apagar(copia)
                    val uri = FileProvider.getUriForFile(c, c.packageName + ".gravacoes", original)
                    c.getSharedPreferences("quall-gravacao-recebida", Context.MODE_PRIVATE).edit()
                        .putString("uri", uri.toString()).putString("nome", nome).apply()
                    Log.i(TAG, "gravação recebida recuperada no Android9: $nome")
                }.onFailure { Log.w(TAG, "recuperação recebida: ${Log.erroExterno(it.message)}") }
            }
        }

        private fun criarDestino(c: Context, nome: String): Destino {
            if (Build.VERSION.SDK_INT >= 29) {
                val valores = ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, nome); put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Quall")
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                }
                val uri = c.contentResolver.insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), valores) ?: error("abrir")
                try {
                    val fd = c.contentResolver.openFileDescriptor(uri, "rw") ?: error("abrir")
                    val id = ContentUris.parseId(uri)
                    val dir = CopiaCrua.diretorio(c) ?: run { fd.close(); error("abrir") }
                    return Destino(nome, uri, fd, CopiaCrua.arquivoDe(dir, id), id)
                } catch (e: Exception) { c.contentResolver.delete(uri, null, null); throw e }
            }
            // Android 9: app Movies + share/export chooser, without WRITE_EXTERNAL_STORAGE.
            val dir = c.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: error("abrir")
            dir.mkdirs()
            val file = File(dir, nome)
            val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_TRUNCATE)
            val uri = FileProvider.getUriForFile(c, c.packageName + ".gravacoes", file)
            val copiaDir = File(dir, "recuperacao").apply { mkdirs() }
            val id = System.currentTimeMillis()
            return Destino(nome, uri, fd, CopiaCrua.arquivoDe(copiaDir, id), id)
        }
    }
}
