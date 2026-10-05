package com.quall.android.capture

import com.quall.android.aceleradoPorHardware

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import com.quall.android.audio.LinhaDoSomDaGravacao
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * **A gravação local da tela R5** (`docs/teleprompter-com-camera.md` §5, fase 3): um **segundo
 * codificador** H.264, alimentado pela saída de gravação do [DivisorGl] na resolução da câmera, e
 * um AAC com o som do microfone, num MP4 sobre o fd do MediaStore, pelo [MuxerDaGravacao]: o
 * **fragmentado** da fita (`hybrid_fragmented` da libavformat, [MuxerQuallDv]) onde há a `libqualldv`,
 * e o `MediaMuxer` do Android ([MuxerMediaMuxer], com a cópia crua ao lado) onde não há — o 32 bits
 * (`docs/teleprompter-com-camera.md` §14.4). As regras de tempo abaixo são as mesmas nos dois.
 *
 * ## O tempo do arquivo é o da câmera, e não o da fita (a revisão G3)
 *
 * - **o vídeo leva o carimbo real da câmera** (o `eglPresentationTimeANDROID` do divisor, S-A3),
 *   passado a `MONOTONIC` pelo [RelogioDoPts] (medido e não acreditado; a frontal do S24 é
 *   `BOOTTIME`, a do A07 não foi medida). Cada quadro com a **sua duração**, até o próximo: fps
 *   variável, e um buraco da câmera fica buraco no arquivo, do tamanho que teve;
 * - **o zero do arquivo é o primeiro quadro de vídeo**; o som anterior a ele cai;
 * - **o som leva a hora da captura** ([LinhaDoSomDaGravacao]), no mesmo `MONOTONIC`, contínuo: o
 *   microfone desligado (ou ainda não aberto) vira silêncio codificado, e a track de som existe do
 *   começo ao fim;
 * - **o atraso do AAC** sai do PTS do som, como na fita ([GravadorMp4][com.quall.android.capture.dv.GravadorMp4]);
 * - **o som espera o vídeo** ([ComportaDoSom][com.quall.android.audio.ComportaDoSom]): um pedaço só
 *   vai ao AAC até o último quadro de vídeo que já saiu do codificador. Sem isso (a prova de 24/09
 *   no A07) o microfone entregava, entre o último quadro desenhado e o fim de fluxo processado, som
 *   que já estava codificado quando o limite chegava: o som terminava **+136 ms** depois da imagem;
 * - **no fim**, o som é cortado ou completado até o fim do último quadro: as duas tracks têm a
 *   mesma duração a menos do arredondamento do AAC — o último pacote é inteiro (1024 amostras, 21
 *   ms); o `fase3-ffprobe.py` aceita 50 ms;
 * - **o som que chega antes do primeiro quadro sair do codificador espera na fila**, e não cai: a
 *   hora dele decide se é antes do zero. Antes ele caía pela *chegada*, e o som captado depois do
 *   primeiro quadro mas entregue antes de o codificador soltá-lo virava silêncio no começo.
 *
 * ## Threads
 *
 * - a thread GL do divisor desenha na [superficie];
 * - a do microfone chama [somDaCaptura], que só copia e enfileira;
 * - a `quall-gravador-r5` drena os dois codificadores, alinha o som e escreve o MP4;
 * - [parar] é de qualquer thread e espera o fim. **Antes** dele, a saída do divisor tem de ter sido
 *   desligada: nenhum quadro depois do fim de fluxo.
 */
class GravadorDaCamera(
    private val muxer: MuxerDaGravacao,
    larguraPedida: Int,
    alturaPedida: Int,
    private val fps: Int,
    bitrate: Int,
    /** A câmera declara `REALTIME`: desempata a zona ambígua do [RelogioDoPts], como na rede. */
    declaradoBoottime: Boolean,
    private val taxaDoSom: Int = 48_000,
    private val canaisDoSom: Int = 1,
    private val bitrateDoSom: Int = BITRATE_SOM,
    /** Chamado uma vez, da thread do gravador, quando o primeiro quadro de vídeo chegou. */
    private val aoComecar: () -> Unit = {},
    /** A porta desta saída no divisor (§14.11): o máximo em trânsito, 0 desliga. */
    tetoDaFila: Int = 0,
) {
    /**
     * **A gravação falhou ao abrir** (§14.3, caso 1): o codificador recusado no `configure`/`start`,
     * ou nenhum que aceite o tamanho. [transitoria]: um erro de recurso ou passageiro (outro app com o
     * codificador, a revisão, 12) — esse não é lembrado para a próxima vez.
     */
    class FalhaAoAbrir(
        mensagem: String,
        causa: Throwable?,
        val transitoria: Boolean,
        /** Onde falhou: o que a marca do aparelho guarda ([com.quall.android.mirror.GravacaoIndisponivel]). */
        val etapa: EtapaDaAbertura = EtapaDaAbertura.OUTRA,
    ) : Exception(mensagem, causa)
    companion object {
        private const val TAG = "QuallGravacao"
        const val BITRATE_SOM = 96_000

        /** Sem quadro do microfone há tanto tempo, a linha do som enche de silêncio até agora menos isto. */
        private const val FOLGA_DO_SILENCIO_US = 300_000L

        /** Depois do fim do vídeo, quanto esperar o microfone chegar ao fim antes de completar com silêncio. */
        private const val ESPERA_DO_SOM_NO_FIM_US = 600_000L

        /** Quadros de 20 ms do microfone que esperam o gravador (10 s). */
        private const val FILA_DO_SOM = 500
    }

    val largura: Int
    val altura: Int
    val nomeDoCodificador: String
    val bitrate: Int

    private val video: MediaCodec
    val superficie: Surface
    private val som: MediaCodec

    private val relogio = RelogioDoPts(declaradoBoottime = declaradoBoottime)

    /** A conta dos quadros em trânsito neste codificador, que o divisor lê (§14.11). */
    val fila = FilaDoCodificador(tetoDaFila)
    private val linha = LinhaDoSomDaGravacao(taxaDoSom, canaisDoSom)

    // --- da thread do microfone ----------------------------------------------------------------
    /** [chegadaUs]: `MONOTONIC` de quando o microfone o entregou — a hora de reserva sem o par do `getTimestamp`. */
    private class QuadroDeSom(val pcm: ShortArray, val n: Int, val instanteUs: Long?, val chegadaUs: Long)
    private val filaDoSom = ArrayBlockingQueue<QuadroDeSom>(FILA_DO_SOM)
    @Volatile var somPerdidoNaFila = 0L; private set

    // --- estado (lido de fora) -----------------------------------------------------------------
    @Volatile var quadros = 0L; private set
    @Volatile var bytes = 0L; private set
    @Volatile var erro: String? = null; private set
    /** O muxer não abriu (a trilha ou o `start` recusados): é falha ao abrir, e não da gravação. */
    @Volatile var falhouAoAbrir = false; private set
    /** O arquivo fechou legível: o muxer abriu e o `fechar` não reclamou. Lido depois de [parar]. */
    @Volatile var fechouLegivel = false; private set
    /** O muxer chegou a abrir (há um MP4, e a cópia crua dele, a recuperar). */
    @Volatile var abriuOMp4 = false; private set
    /** Quem gravou: `qualldv` ou `mediamuxer`. */
    val nomeDoMuxer: String get() = muxer.nome
    /** A duração do vídeo escrito até agora, em ms. */
    @Volatile var duracaoMs = 0L; private set
    @Volatile var buracosDeVideo = 0; private set
    @Volatile var maiorIntervaloMs = 0.0; private set
    @Volatile private var fimPedido = false
    @Volatile private var fimPedidoEm = 0L
    private val comecou = CountDownLatch(1)
    /** O MP4 abriu (os dois formatos chegaram): só então a gravação "começou" para o contrato (§13.8). */
    private val abriu = CountDownLatch(1)

    // --- só da thread do gravador --------------------------------------------------------------
    private var mp4Aberto = false
    private var formatoVideo: MediaFormat? = null
    private var formatoSom: MediaFormat? = null
    private val pendentesDoMp4 = ArrayList<PacotePendente>()
    private var zeroUs: Long? = null
    private var ultimoMonoUs = Long.MIN_VALUE
    /** O quadro que espera o próximo para saber a sua duração. */
    private var videoGuardado: ByteBuffer? = null
    private var ptsGuardado = 0L
    private var chaveGuardada = false
    private var temGuardado = false
    private var ultimaDuracao = 0L
    private var ultimoQuadroDeSomUs = 0L
    private var videoAcabou = false
    private var videoAcabouEmUs = 0L
    private var fimDoSomPedido = false
    private var fimDoSomNaFila = false
    private var somAcabou = false
    private var atrasoDoSom = -1
    /** O som que espera o vídeo andar (o achado A de 24/09). */
    private val comporta = com.quall.android.audio.ComportaDoSom(canaisDoSom)
    /** Amostras por canal já entregues ao AAC: o fim do som no arquivo, antes do arredondamento. */
    private var somAoAac = 0L
    private var fimCortado = false
    private var ultimoPtsDoSom = -1L
    private var pacotesDepoisDoFim = 0

    private class PacotePendente(val video: Boolean, val dados: ByteArray, val pts: Long, val dur: Long, val chave: Boolean)

    /** Declarada antes do `init`: a thread do gravador nasce no fim dele e já a usa. */
    private val saidaDoSom = LinhaDoSomDaGravacao.Saida { pcm, desde, n, posicao -> paraOAac(pcm, desde, n, posicao) }

    /**
     * Um pedaço da comporta no AAC. **Declarado antes do `init`** (a revisão, M1), como [saidaDoSom]:
     * a thread do gravador nasce no fim dele e já o usa. Devolve quantas amostras (por canal)
     * couberam, 0 sem buffer livre.
     */
    private val aoAac = com.quall.android.audio.ComportaDoSom.Consumidor { pcm, desde, n, posicao ->
        val i = som.dequeueInputBuffer(0)
        if (i < 0) return@Consumidor 0
        val buf = som.getInputBuffer(i) ?: return@Consumidor 0
        buf.clear()
        buf.order(ByteOrder.LITTLE_ENDIAN)
        val k = minOf(buf.remaining() / (2 * canaisDoSom), n)
        buf.asShortBuffer().put(pcm, desde * canaisDoSom, k * canaisDoSom)
        som.queueInputBuffer(i, 0, k * 2 * canaisDoSom, posicao * 1_000_000L / taxaDoSom, 0)
        somAoAac = posicao + k
        k
    }


    private val thread: Thread

    init {
        val tipo = MediaFormat.MIMETYPE_VIDEO_AVC
        val lista = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        // O codificador de hardware de H.264 que aceite o tamanho (ou, com o tamanho recusado, um
        // tamanho menor na mesma proporção): o primeiro da lista que tenha entrada por superfície.
        val candidatos = lista.codecInfos.filter { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(tipo, ignoreCase = true) }
        }.sortedBy { if (it.aceleradoPorHardware) 0 else 1 }
        var escolhido: MediaCodecInfo? = null
        var tamanho: Pair<Int, Int>? = null
        for (c in candidatos) {
            val caps = runCatching { c.getCapabilitiesForType(tipo).videoCapabilities }.getOrNull() ?: continue
            val t = ParametrosDaGravacao.tamanhoAceito(larguraPedida, alturaPedida) { w, h -> caps.isSizeSupported(w, h) }
            if (t != null) {
                escolhido = c
                tamanho = t
                break
            }
        }
        val info = escolhido
            ?: throw FalhaAoAbrir("nenhum codificador H.264 aceita ${larguraPedida}x$alturaPedida", null, transitoria = false,
                etapa = EtapaDaAbertura.CODIFICADOR_DE_VIDEO)
        val (w, h) = tamanho!!
        largura = w
        altura = h
        nomeDoCodificador = info.name
        val caps = info.getCapabilitiesForType(tipo)
        this.bitrate = caps.videoCapabilities?.bitrateRange?.clamp(bitrate) ?: bitrate

        val f = MediaFormat.createVideoFormat(tipo, w, h)
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        f.setInteger(MediaFormat.KEY_BIT_RATE, this.bitrate)
        f.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        // Um IDR por segundo: é o fragmento do MP4 (`frag_keyframe`), e o que se perde se o
        // processo morrer é no máximo isso (a S-I1 no iPhone 7: 1,5 s com fragmento de 2 s).
        f.setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, 1f)
        if (caps.encoderCapabilities?.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR) == true) {
            f.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        }
        // Sem quadro B: o muxer recebe pts = dts, como na fita.
        f.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
        // A cor da rede (BT.709, faixa limitada): a mesma imagem que o receptor vê.
        f.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
        f.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
        f.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        // Não é tempo real: a rede é. O codificador da gravação cede quando os dois disputam.
        f.setInteger(MediaFormat.KEY_PRIORITY, 1)
        val nivel = ParametrosDaGravacao.nivelMinimo(w, h, fps)
        val constante = nivel?.let { nivelAndroid(it) }
        val high = constante != null && caps.profileLevels.any {
            it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh && it.level >= constante
        }
        if (high) {
            f.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
            f.setInteger(MediaFormat.KEY_LEVEL, constante!!)
        }
        video = try {
            MediaCodec.createByCodecName(info.name)
        } catch (e: Exception) {
            throw FalhaAoAbrir("o codificador ${info.name} não abriu: ${e.message}", e, transitoria(e), EtapaDaAbertura.CODIFICADOR_DE_VIDEO)
        }
        try {
            video.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            superficie = video.createInputSurface()
            video.start()
        } catch (e: Exception) {
            runCatching { video.release() }
            throw FalhaAoAbrir("o codificador ${info.name} recusou ${w}x$h: ${e.javaClass.simpleName}: ${e.message}", e, transitoria(e),
                EtapaDaAbertura.CODIFICADOR_DE_VIDEO)
        }
        som = try {
            abrirSom()
        } catch (e: Exception) {
            runCatching { video.stop() }
            runCatching { video.release() }
            runCatching { superficie.release() }
            throw FalhaAoAbrir("o codificador de som não abriu: ${e.javaClass.simpleName}: ${e.message}", e, transitoria(e),
                EtapaDaAbertura.CODIFICADOR_DE_SOM)
        }
        Log.i(TAG, "gravador: gravador=${muxer.nome} ${info.name} ${w}x$h a $fps fps, ${this.bitrate / 1000} kbit/s VBR, " +
            "${if (high) "High $nivel" else "perfil padrão"}, BT.709 limitada, sem B, IDR a cada 1 s" +
            if (w != larguraPedida || h != alturaPedida) " (pedido ${larguraPedida}x$alturaPedida, recusado pelo codificador)" else "")
        thread = Thread({ drenar() }, "quall-gravador-r5").also { it.start() }
    }

    /**
     * Um erro que passa (a revisão, 12): o `MediaCodec` diz que é passageiro ou recuperável, ou que
     * faltou recurso (outro app com o codificador). Esse não marca o aparelho como "não grava".
     */
    private fun transitoria(e: Throwable): Boolean {
        val c = e as? MediaCodec.CodecException ?: return false
        return c.isTransient || c.isRecoverable ||
            c.errorCode == MediaCodec.CodecException.ERROR_INSUFFICIENT_RESOURCE ||
            c.errorCode == MediaCodec.CodecException.ERROR_RECLAIMED
    }

    private fun nivelAndroid(n: Int): Int = when (n) {
        31 -> MediaCodecInfo.CodecProfileLevel.AVCLevel31
        32 -> MediaCodecInfo.CodecProfileLevel.AVCLevel32
        40 -> MediaCodecInfo.CodecProfileLevel.AVCLevel4
        42 -> MediaCodecInfo.CodecProfileLevel.AVCLevel42
        50 -> MediaCodecInfo.CodecProfileLevel.AVCLevel5
        51 -> MediaCodecInfo.CodecProfileLevel.AVCLevel51
        else -> MediaCodecInfo.CodecProfileLevel.AVCLevel52
    }

    private fun abrirSom(): MediaCodec {
        val f = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, taxaDoSom, canaisDoSom)
        f.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        f.setInteger(MediaFormat.KEY_BIT_RATE, bitrateDoSom)
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
        val nome = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(f)
            ?: throw IllegalStateException("sem codificador AAC para $taxaDoSom Hz x $canaisDoSom")
        return MediaCodec.createByCodecName(nome).also {
            it.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            it.start()
            Log.i(TAG, "gravador: som $nome $taxaDoSom Hz x $canaisDoSom, ${bitrateDoSom / 1000} kbit/s")
        }
    }

    // ---- da thread do microfone ---------------------------------------------------------------

    /**
     * Um quadro do microfone, com a hora da captura (`MONOTONIC`). Copia e enfileira; nunca
     * bloqueia a leitura do microfone. Fila cheia (o gravador preso): o quadro cai, e conta.
     */
    fun somDaCaptura(pcm: ShortArray, amostras: Int, instanteUs: Long?) {
        val copia = pcm.copyOf(amostras * canaisDoSom)
        if (!filaDoSom.offer(QuadroDeSom(copia, amostras, instanteUs, MonotonicClock.micros()))) somPerdidoNaFila++
    }

    /** O que faltou no começo ([esperarComeco]): o dado; quem mostra monta a frase no idioma dela. */
    sealed class FaltaNoComeco {
        /** O primeiro quadro não chegou ao arquivo em [segundos]. */
        data class SemPrimeiroQuadro(val segundos: Long) : FaltaNoComeco()
        /** O MP4 não abriu em [segundos]; [erro] é o detalhe técnico do gravador, se houver (do diário). */
        data class Mp4NaoAbriu(val segundos: Long, val erro: String?) : FaltaNoComeco()
    }

    /**
     * Espera, até [ms] no total, o primeiro quadro de vídeo **e** o MP4 aberto — o arquivo de fato
     * começou (§13.8 do contrato: `set_recording` só então). Devolve o que faltou, ou `null`.
     */
    fun esperarComeco(ms: Long): FaltaNoComeco? {
        val fim = SystemClock.elapsedRealtime() + ms
        if (!comecou.await(ms, TimeUnit.MILLISECONDS)) return FaltaNoComeco.SemPrimeiroQuadro(ms / 1000)
        val resto = (fim - SystemClock.elapsedRealtime()).coerceAtLeast(1)
        if (!abriu.await(resto, TimeUnit.MILLISECONDS)) return FaltaNoComeco.Mp4NaoAbriu(ms / 1000, erro)
        return null
    }

    val comecado: Boolean get() = comecou.count == 0L

    // ---- da thread do gravador ----------------------------------------------------------------

    private fun drenar() {
        val info = MediaCodec.BufferInfo()
        try {
            while (true) {
                if (videoAcabou && somAcabou) break
                if (fimPedido && SystemClock.elapsedRealtime() - fimPedidoEm > 8_000) {
                    Log.w(TAG, "gravador: o fim de fluxo não veio em 8 s; fecho com o que chegou")
                    break
                }
                if (!videoAcabou) drenarVideo(info)
                tirarSomDaFila()
                val z = zeroUs
                if (z != null && !fimDoSomPedido) {
                    val agora = MonotonicClock.micros()
                    // O microfone calado (botão desligado, ou ainda abrindo): o arquivo recebe silêncio.
                    if (agora - ultimoQuadroDeSomUs > FOLGA_DO_SILENCIO_US) {
                        linha.silencioAte(agora - FOLGA_DO_SILENCIO_US, saidaDoSom)
                    }
                }
                if (videoAcabou && !fimDoSomPedido) {
                    val lim = linha.limiteUs
                    val chegou = lim == null || linha.escritas >= linha.amostraDe(lim)
                    if (chegou || MonotonicClock.micros() - videoAcabouEmUs > ESPERA_DO_SOM_NO_FIM_US) {
                        if (lim != null) linha.silencioAte(lim, saidaDoSom)
                        fimDoSomPedido = true
                    }
                }
                alimentarAac()
                drenarSom(info)
                // Sem o vídeo (que esperava 5 ms por saída), o laço não pode girar solto.
                if (videoAcabou) Thread.sleep(2)
            }
        } catch (e: Exception) {
            erro = "a gravação falhou: ${e.javaClass.simpleName}: ${e.message}" // i18n-fora: detalhe técnico do gravador (diário)
            Log.e(TAG, "gravador: ${Log.erroExterno(erro)}", e)
        } finally {
            fecharTudo()
        }
    }

    private fun drenarVideo(info: MediaCodec.BufferInfo) {
        val i = video.dequeueOutputBuffer(info, 5_000)
        if (i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            formatoVideo = video.outputFormat
            abrirMp4SePronto()
            return
        }
        if (i < 0) return
        val b = video.getOutputBuffer(i)!!
        val fimDeFluxo = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
            fila.saiu(info.presentationTimeUs)
            b.position(info.offset).limit(info.offset + info.size)
            val mono = relogio.quadro(info.presentationTimeUs, MonotonicClock.micros(), SystemClock.elapsedRealtimeNanos() / 1000)
            if (zeroUs == null) {
                zeroUs = mono
                linha.zeroUs = mono
                Log.i(TAG, "gravador: primeiro quadro: ${relogio.linha()}")
                comecou.countDown()
                runCatching { aoComecar() }
            }
            if (mono <= ultimoMonoUs) {
                Log.w(TAG, "gravador: carimbo que não anda (${mono - ultimoMonoUs} µs) — o quadro cai")
            } else {
                if (ultimoMonoUs != Long.MIN_VALUE) {
                    val ms = (mono - ultimoMonoUs) / 1000.0
                    if (ms > maiorIntervaloMs) maiorIntervaloMs = ms
                    if (ms > DivisorGl.BURACO_MS) {
                        buracosDeVideo++
                        Log.w(TAG, "gravador: buraco de ${"%.0f".format(java.util.Locale.ROOT, ms)} ms no vídeo (${buracosDeVideo}º) — fica no arquivo com o tamanho que teve")
                    }
                }
                ultimoMonoUs = mono
                val pts = ParametrosDaGravacao.us90k(mono - zeroUs!!)
                guardarVideo(b, pts, info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0)
                quadros++
            }
        }
        video.releaseOutputBuffer(i, false)
        if (fimDeFluxo) {
            soltarGuardado(null)
            videoAcabou = true
            videoAcabouEmUs = MonotonicClock.micros()
            val z = zeroUs
            if (z != null) {
                val fim = z + ParametrosDaGravacao.de90kUs(ptsGuardado + ultimaDuracao)
                linha.limiteUs = fim
                Log.i(TAG, "gravador: fim do vídeo: $quadros quadros, ${(fim - z) / 1000} ms")
            } else {
                // Nenhum quadro: não há arquivo a fazer; o som também acabou.
                fimDoSomPedido = true
            }
        }
    }

    /** O quadro novo espera o próximo: a duração dele é a distância até lá. */
    private fun guardarVideo(b: ByteBuffer, pts: Long, chave: Boolean) {
        soltarGuardado(pts)
        val n = b.remaining()
        var g = videoGuardado
        if (g == null || g.capacity() < n) {
            g = ByteBuffer.allocateDirect(maxOf(n, 256 * 1024))
            videoGuardado = g
        }
        g!!.clear()
        g.put(b)
        g.flip()
        ptsGuardado = pts
        chaveGuardada = chave
        temGuardado = true
    }

    private fun soltarGuardado(proximo: Long?) {
        if (!temGuardado) return
        val dur = ParametrosDaGravacao.duracao(ptsGuardado, proximo, ultimaDuracao.takeIf { it > 0 }, fps)
        ultimaDuracao = dur
        escrever(true, videoGuardado!!, ptsGuardado, dur, chaveGuardada)
        duracaoMs = ParametrosDaGravacao.de90kUs(ptsGuardado + dur) / 1000
        temGuardado = false
    }

    private fun tirarSomDaFila() {
        // Antes de o primeiro quadro sair do codificador, o som espera na fila: a hora dele (e não a
        // chegada) decide se é antes do zero. A fila segura 10 s; o começo desiste em 5.
        if (zeroUs == null && !videoAcabou) return
        while (true) {
            val q = filaDoSom.poll() ?: break
            ultimoQuadroDeSomUs = MonotonicClock.micros()
            if (fimDoSomPedido) continue
            // Sem o par do `getTimestamp` (o começo do microfone, ou um aparelho que não dá), a hora
            // de reserva é a chegada menos a duração do quadro — e não "onde a linha está", que com o
            // silêncio já posto à frente adiantaria o som em até 300 ms (a revisão, médio 4).
            val hora = q.instanteUs ?: (q.chegadaUs - q.n * 1_000_000L / taxaDoSom)
            linha.quadro(q.pcm, q.n, hora, saidaDoSom)
        }
    }

    /** Da [linha]: um pedaço contínuo de PCM, a partir da amostra [posicao] do arquivo, para a comporta. */
    private fun paraOAac(pcm: ShortArray, desde: Int, n: Int, posicao: Long) {
        comporta.entrar(pcm, desde, n, posicao)
    }

    private fun alimentarAac() {
        val z = zeroUs
        val lim = linha.limiteUs
        comporta.teto = when {
            // O fim da imagem é conhecido: nada passa dele, e o que já esperava além dele cai.
            lim != null && z != null -> linha.amostraDe(lim).also { fim ->
                if (fimDoSomPedido && !fimCortado) {
                    fimCortado = true
                    comporta.cortarDesde(fim)
                }
            }
            // Gravando: até o começo do último quadro que já saiu do codificador.
            z != null && ultimoMonoUs != Long.MIN_VALUE -> linha.amostraDe(ultimoMonoUs)
            else -> 0L
        }
        comporta.soltar(aoAac)
        if (fimDoSomPedido && !fimDoSomNaFila && (comporta.vazia || zeroUs == null)) {
            val i = som.dequeueInputBuffer(0)
            if (i >= 0) {
                som.queueInputBuffer(i, 0, 0, somAoAac * 1_000_000L / taxaDoSom, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                fimDoSomNaFila = true
                linha.limiteUs?.let { l ->
                    Log.i(TAG, "gravador: fim do som: ${somAoAac * 1000 / taxaDoSom} ms ao AAC, a imagem termina em " +
                        "${(l - (zeroUs ?: l)) / 1000} ms; ${comporta.cortadas * 1000 / taxaDoSom} ms de som depois da imagem cortados na comporta")
                }
            }
        }
    }

    private fun drenarSom(info: MediaCodec.BufferInfo) {
        while (true) {
            val i = som.dequeueOutputBuffer(info, 0)
            if (i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                formatoSom = som.outputFormat
                abrirMp4SePronto()
                continue
            }
            if (i < 0) return
            val b = som.getOutputBuffer(i)!!
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                b.position(info.offset).limit(info.offset + info.size)
                if (atrasoDoSom < 0) atrasoDoSom = atrasoDoEncoder()
                val pts = (info.presentationTimeUs * taxaDoSom + 500_000L) / 1_000_000L - atrasoDoSom
                // O priming do AAC fica antes do zero e cai; um pacote que não anda também; e um que
                // começa depois do último som entregue (o enchimento do fim de fluxo) também — o fim do
                // som fica a menos de um pacote (21 ms) do fim da imagem.
                val depoisDoFim = fimDoSomNaFila && pts >= somAoAac
                if (depoisDoFim) pacotesDepoisDoFim++
                if (pts >= 0 && pts > ultimoPtsDoSom && !depoisDoFim) {
                    ultimoPtsDoSom = pts
                    escrever(false, b, pts, 1024, true)
                }
            }
            som.releaseOutputBuffer(i, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                somAcabou = true
                return
            }
        }
    }

    private fun atrasoDoEncoder(): Int {
        val f = runCatching { som.outputFormat }.getOrNull()
        val d = if (f != null && f.containsKey(MediaFormat.KEY_ENCODER_DELAY)) f.getInteger(MediaFormat.KEY_ENCODER_DELAY) else -1
        val usado = if (d >= 0) d else com.quall.android.capture.dv.GravadorMp4.ATRASO_AAC
        Log.i(TAG, "gravador: atraso do AAC = $usado amostras (${if (d >= 0) "declarado pelo codificador" else "o medido no S24 na fita, não medido neste aparelho"})")
        return usado
    }

    // ---- o MP4 --------------------------------------------------------------------------------

    /** Abre quando os dois formatos chegaram (o SPS/PPS e o AudioSpecificConfig). */
    private fun abrirMp4SePronto() {
        if (mp4Aberto) return
        val fv = formatoVideo ?: return
        val fs = formatoSom ?: return
        val sps = bytesDe(fv.getByteBuffer("csd-0"))
        val pps = bytesDe(fv.getByteBuffer("csd-1"))
        val asc = bytesDe(fs.getByteBuffer("csd-0"))
        if (sps.isEmpty() && pps.isEmpty()) throw IllegalStateException("o codificador de vídeo não deu SPS/PPS (csd-0/csd-1)")
        if (asc.isEmpty()) throw IllegalStateException("o codificador de som não deu o AudioSpecificConfig (csd-0)")
        fun cor(k: String) = if (fv.containsKey(k)) fv.getInteger(k) else 0
        val padrao = cor(MediaFormat.KEY_COLOR_STANDARD).takeIf { it != 0 } ?: MediaFormat.COLOR_STANDARD_BT709
        val faixa = cor(MediaFormat.KEY_COLOR_RANGE).takeIf { it != 0 } ?: MediaFormat.COLOR_RANGE_LIMITED
        val transf = cor(MediaFormat.KEY_COLOR_TRANSFER).takeIf { it != 0 } ?: MediaFormat.COLOR_TRANSFER_SDR_VIDEO
        try {
            muxer.abrir(FormatosDaGravacao(largura, altura, sps, pps, taxaDoSom, canaisDoSom, bitrateDoSom, asc, padrao, faixa, transf))
        } catch (e: Exception) {
            // A trilha ou o `start` recusados: falha **ao abrir** (a revisão, 13e), que a tela lembra.
            falhouAoAbrir = true
            throw IllegalStateException("o MP4 não abriu (${muxer.nome}: ${e.javaClass.simpleName}: ${e.message})", e)
        }
        mp4Aberto = true
        abriuOMp4 = true
        abriu.countDown()
        Log.i(TAG, "gravador: MP4 aberto por ${muxer.nome} (cor declarada pelo codificador: padrão $padrao, faixa $faixa, transferência $transf); " +
            "${pendentesDoMp4.size} pacotes esperavam")
        val tmp = ByteBuffer.allocateDirect(1 shl 20)
        for (p in pendentesDoMp4) {
            val b = if (p.dados.size <= tmp.capacity()) tmp else ByteBuffer.allocateDirect(p.dados.size)
            b.clear(); b.put(p.dados); b.flip()
            gravarPacote(p.video, b, p.pts, p.dur, p.chave)
        }
        pendentesDoMp4.clear()
    }

    private fun escrever(ehVideo: Boolean, b: ByteBuffer, pts: Long, dur: Long, chave: Boolean) {
        if (!mp4Aberto) {
            abrirMp4SePronto()
            if (!mp4Aberto) {
                if (pendentesDoMp4.size > 900) throw IllegalStateException("o MP4 não abriu em 900 pacotes (sem o formato do som?)")
                val copia = ByteArray(b.remaining()).also { b.duplicate().get(it) }
                pendentesDoMp4 += PacotePendente(ehVideo, copia, pts, dur, chave)
                return
            }
        }
        gravarPacote(ehVideo, b, pts, dur, chave)
    }

    private fun gravarPacote(ehVideo: Boolean, b: ByteBuffer, pts: Long, dur: Long, chave: Boolean) {
        val n = b.remaining()
        // O corte duro do tamanho, **aqui**, antes de o muxer receber o pacote que passaria dele (a
        // revisão, 11): no `MediaMuxer` o estouro pode prender o `writeSampleData` em vez de falhar.
        if (bytes + n > muxer.limiteDeBytes) {
            throw IllegalStateException("o arquivo chegou a ${muxer.limiteDeBytes / 1_000_000} MB, o limite do gravador deste aparelho")
        }
        val r = if (ehVideo) muxer.video(b, pts, dur, chave) else muxer.som(b, pts, dur.toInt())
        if (r < 0) throw IllegalStateException("o muxer recusou um pacote de ${if (ehVideo) "vídeo" else "som"} ($r)")
        bytes += n
    }

    private fun fecharTudo() {
        if (!mp4Aberto && pendentesDoMp4.isNotEmpty() && erro == null) {
            erro = "o MP4 não chegou a abrir (${pendentesDoMp4.size} pacotes sem destino)" // i18n-fora: detalhe técnico do gravador (diário)
        }
        // Sempre, mesmo sem abrir: o `MediaMuxer` nasce antes e precisa ser solto.
        val r = muxer.fechar()
        if (r != null && erro == null) erro = r
        fechouLegivel = mp4Aberto && r == null
        mp4Aberto = false
        runCatching { video.stop() }
        runCatching { video.release() }
        runCatching { som.stop() }
        runCatching { som.release() }
        runCatching { superficie.release() }
        Log.i(TAG, "gravador: fechado — quadros=$quadros duracao_ms=$duracaoMs bytes=$bytes " +
            "buracos>${DivisorGl.BURACO_MS.toInt()}ms=$buracosDeVideo maior_intervalo_ms=${"%.1f".format(java.util.Locale.ROOT, maiorIntervaloMs)} " +
            "som_perdido_na_fila=$somPerdidoNaFila som_ao_aac_ms=${somAoAac * 1000 / taxaDoSom} " +
            "comporta_cortada_ms=${comporta.cortadas * 1000 / taxaDoSom} pacotes_depois_do_fim=$pacotesDepoisDoFim " +
            "${linha.linha()} ${relogio.linha()} ${muxer.linha()} pulados_pela_porta=${fila.pulados} erro=${erro?.let { Log.erroExterno(it) } ?: "nenhum"}")
    }

    /**
     * Encerra: fim de fluxo no vídeo; a thread drena, completa o som até o fim do último quadro,
     * escreve o `moov` e sai. **Chame depois de desligar a saída do divisor.** Devolve o erro, se houve.
     */
    fun parar(): String? {
        fimPedidoEm = SystemClock.elapsedRealtime()
        fimPedido = true
        runCatching { video.signalEndOfInputStream() }.onFailure {
            Log.w(TAG, "gravador: signalEndOfInputStream: ${Log.erroExterno(it.message)}")
        }
        thread.join(10_000)
        if (thread.isAlive) {
            erro = erro ?: "o gravador não terminou em 10 s" // i18n-fora: detalhe técnico do gravador (diário)
            Log.e(TAG, "gravador: ${Log.erroExterno(erro)}")
        }
        return erro
    }

    /** A thread saiu (o MP4 fechou, ou nem abriu). Falso depois de [parar]: o fd não pode ser fechado. */
    val terminou: Boolean get() = !thread.isAlive

    private fun bytesDe(b: ByteBuffer?): ByteArray {
        if (b == null) return ByteArray(0)
        val d = b.duplicate()
        d.position(0)
        return ByteArray(d.remaining()).also { d.get(it) }
    }
}

/**
 * **Onde a abertura da gravação falhou** (§14.3): o que a marca de "este aparelho não grava" guarda em
 * SharedPreferences — um código estável, e não a frase (`docs/traducao.md`, Android: a frase guardada
 * ficaria no idioma do dia em que falhou). A frase sai de [frase] na hora de mostrar.
 */
enum class EtapaDaAbertura(val codigo: String, @androidx.annotation.StringRes val frase: Int) {
    CODIFICADOR_DE_VIDEO("codificador_de_video", com.quall.android.R.string.cam_etapa_codificador_de_video),
    CODIFICADOR_DE_SOM("codificador_de_som", com.quall.android.R.string.cam_etapa_codificador_de_som),
    ARQUIVO("arquivo", com.quall.android.R.string.cam_etapa_arquivo),
    OUTRA("outra", com.quall.android.R.string.cam_etapa_outra),
    ;

    companion object {
        /** A etapa de um código guardado; `null` para o que não se reconhece (uma marca de outra versão). */
        fun deCodigo(codigo: String?): EtapaDaAbertura? = entries.firstOrNull { it.codigo == codigo }
    }
}
