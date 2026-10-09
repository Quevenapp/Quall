package com.quall.android.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import com.quall.android.core.LogSeguro as Log
import com.quall.android.core.QuallNative
import java.nio.ByteBuffer

/**
 * **Toca o som que chegou.** A metade que faltava do receptor Android.
 *
 * `quall_track_on_audio` → caixa de slots em C → decodificador da fronteira → `AudioTrack`.
 * Roda numa thread própria, criada por [iniciar]; a sessão receptora não espera por ela.
 *
 * ## Quem dá o ritmo é o `AudioTrack`, não um relógio nosso
 *
 * O jitter buffer do núcleo entrega **um slot de 20 ms por pacote que chega**, sempre e sem
 * buraco — as ordens `FRAME`, `FEC` e `SILENCE` cobrem os três casos, e é por isso que a saída
 * dele tem cadência de tempo real por construção. Do lado de cá, `AudioTrack.write` em
 * `WRITE_BLOCKING` segura a thread até caber. As duas coisas juntas dão o relógio: não há
 * `sleep`, não há acumulador de tempo, e não há nada aqui reimplementando cadência — que é
 * exatamente o que `docs/audio.md` §4 tirou das cascas ao trazer o buffer para o núcleo.
 *
 * ## As três ordens têm três respostas, e é por isso que o decodificador é o da fronteira
 *
 * | ordem | o que se faz |
 * |---|---|
 * | `FRAME` | `opus_decode` normal |
 * | `FEC` | `opus_decode(decode_fec=1)` sobre o pacote *N+1*, **e só se `fec_has_lbrr == 1`** |
 * | `SILENCE` | ocultação de perda (PLC) do próprio decoder |
 *
 * O `MediaCodec` do Android decodifica Opus e **não tem as duas últimas**. Com ele, o socorro que
 * o buffer oferece atravessaria a rede para ser jogado fora, e o buraco viraria zeros — que é um
 * estalo, não silêncio. Por isso o caminho é `quall_audio_decoder_*`, que já linka a libopus
 * dentro da `libquall.so` por causa do encoder e não custa um byte a mais de binário.
 *
 * ## `fec_has_lbrr` é tri-estado, e o `-1` **não** autoriza pedir socorro
 *
 * `1` sim, `0` não, `-1` não sei. Sem LBRR, `opus_decode` com `decode_fec=1` cai na ocultação de
 * perda **em silêncio e devolve sucesso** — quem não conferir conta como "curado por FEC" um
 * quadro que o decoder inventou. Aqui só o `1` vira `decode_fec`; `0` e `-1` caem no PLC, e os
 * três casos são contados separados para que o relatório não confunda os dois motivos.
 *
 * ## Nada disto abre o microfone
 *
 * Esta classe **só reproduz**. Não há `AudioRecord`, não há `MediaRecorder.AudioSource`, e a
 * permissão `RECORD_AUDIO` não é tocada em lugar nenhum deste arquivo.
 */
class ReprodutorDeAudio(
    private val track: Long,
    private val kind: Int,
    /** Caminho de um `.wav` de bancada, ou vazio. Ver [EscritorDeWav] — a origem manda. */
    private val gravarEm: String = "",
) {
    companion object {
        private const val TAG = "QuallAudio"

        /** Prazo de cada espera na caixa. Curto: é o que faz o desligamento ser rápido. */
        private const val ESPERA_POR_SLOT_MS = 60

        /** Teto de um payload de áudio. `MAX_AMOSTRA` da fronteira. */
        private const val MAX_PAYLOAD = 4096

        /**
         * Sem nenhum slot por este tempo, a track morreu. O laço sai e o `AudioTrack` fecha.
         *
         * 5 s: o dobro do silêncio que uma queda de transporte produz antes de o detector de
         * eventos da sessão acusar, e menos que os 10 s que o vídeo usa — áudio parado é audível
         * na hora, e segurar o `AudioTrack` aberto por dez segundos mudos é pior que fechá-lo.
         */
        private const val SILENCIO_ATE_DESISTIR_MS = 5_000L
    }

    @Volatile
    private var pararPedido = false

    private var thread: Thread? = null

    // --- o que a bancada lê --------------------------------------------------------------

    @Volatile var preset: PresetDeAudio? = null; private set
    @Volatile var codecNegociado = QuallNative.AudioCodec.DEFAULT; private set
    @Volatile var slotsRecebidos = 0L; private set
    @Volatile var slotsDescartadosNaCaixa = 0L; private set
    @Volatile var quadrosTocados = 0L; private set
    @Volatile var curadosPorFec = 0L; private set
    @Volatile var socorroSemLbrr = 0L; private set
    @Volatile var socorroSemResposta = 0L; private set
    @Volatile var ocultacoesDePerda = 0L; private set
    @Volatile var errosDeDecodificacao = 0L; private set
    @Volatile var subconsumos = 0L; private set
    @Volatile var motivoDaSaida = ""; private set
    @Volatile var analise: AnalisadorDeTom? = null; private set
    @Volatile var amostrasNoWav = 0L; private set

    /** Do registro do tratador ao primeiro quadro **escrito no `AudioTrack`**, em ms. */
    @Volatile var primeiroSomMs = 0.0; private set

    /** Received PCM before output volume, no local capture. Callback must copy without waiting. */
    @Volatile var aoPcmRecebido: ((ShortArray, Int, Long, Long, Int, Int) -> Unit)? = null

    fun iniciar(): Boolean {
        val codec = QuallNative.trackAudioCodec(track)
        if (codec == QuallNative.AudioCodec.DEFAULT) {
            // "Não sei" não é "então é Opus". Ver a doc de `trackAudioCodec`: adivinhar aqui
            // decodificaria G.711 com o relógio numa escala 6× errada, e sairia som.
            Log.e(TAG, "a track de áudio não declarou codec: ${Log.erroExterno(QuallNative.lastError())}")
            motivoDaSaida = "a track de áudio chegou sem codec no rtpmap" // i18n-fora: detalhe técnico do diário
            return false
        }
        codecNegociado = codec
        val p = PresetDeAudio.de(kind, codec)
        if (p == null) {
            Log.e(TAG, "não consegui ler o preset de áudio (kind=$kind codec=$codec)")
            motivoDaSaida = "não consegui ler o preset de áudio do núcleo" // i18n-fora: detalhe técnico do diário
            return false
        }
        preset = p
        Log.i(TAG, "track de áudio: ${p.linha()} fmtp='${p.fmtp}'")

        val t = Thread({ rodar(p) }, "quall-audio")
        t.isDaemon = true
        thread = t
        t.start()
        return true
    }

    fun parar() {
        pararPedido = true
        thread?.join(2_000)
    }

    // -------------------------------------------------------------------------------------

    private fun rodar(p: PresetDeAudio) {
        val caixa = QuallNative.audioBoxNew()
        if (caixa == 0L) {
            motivoDaSaida = "não consegui criar a caixa de slots (memória?)" // i18n-fora: detalhe técnico do diário
            Log.e(TAG, motivoDaSaida)
            return
        }
        // O decodificador **antes** do registro: se ele falhar, nada foi armado e não há barreira
        // a cumprir para liberar a caixa.
        val decoder = if (codecNegociado == QuallNative.AudioCodec.PCMU) {
            0L // µ-law é tabela de consulta; a fronteira recusa de propósito. Ver `UlawG711`.
        } else {
            QuallNative.audioDecoderNew(kind, codecNegociado).also {
                if (it == 0L) Log.e(TAG, "audioDecoderNew: ${Log.erroExterno(QuallNative.lastError())}")
            }
        }
        if (decoder == 0L && codecNegociado != QuallNative.AudioCodec.PCMU) {
            QuallNative.audioBoxFree(caixa)
            motivoDaSaida = "não consegui criar o decodificador de Opus" // i18n-fora: detalhe técnico do diário
            return
        }

        val saida = abrirAudioTrack(p)
        if (saida == null) {
            if (decoder != 0L) QuallNative.audioDecoderFree(decoder)
            QuallNative.audioBoxFree(caixa)
            motivoDaSaida = "não consegui abrir o AudioTrack" // i18n-fora: detalhe técnico do diário
            Log.e(TAG, motivoDaSaida)
            return
        }

        val st = QuallNative.trackOnAudio(track, caixa)
        if (st != QuallNative.Status.OK) {
            saida.release()
            if (decoder != 0L) QuallNative.audioDecoderFree(decoder)
            QuallNative.audioBoxFree(caixa)
            motivoDaSaida = "quall_track_on_audio recusou: ${QuallNative.Status.nome(st)}"
            Log.e(TAG, motivoDaSaida)
            return
        }

        val wav = if (gravarEm.isNotBlank()) {
            EscritorDeWav.criar(gravarEm, p.taxaHz, p.canais).also {
                Log.i(TAG, if (it != null) "gravando em $gravarEm (origem sintética)" else
                    "não consegui abrir $gravarEm para gravar")
            }
        } else null

        try {
            laco(caixa, decoder, saida, p, wav)
        } finally {
            // 1. Desligar **com barreira**. O desligamento escoa os slots retidos — que chegam à
            //    caixa desta thread, e por isso a drenagem abaixo acontece depois.
            val stDesligar = QuallNative.trackOnAudio(track, 0L)
            val liberavel = stDesligar == QuallNative.Status.OK
            if (!liberavel) {
                Log.e(TAG, "desregistro do áudio voltou ${QuallNative.Status.nome(stDesligar)} — não libero a caixa")
            } else {
                // 2. Os últimos ~40 ms, que o escoamento acabou de pôr na caixa. Sem isto eles
                //    sumiriam de toda sessão, e apareceriam numa tabela como dois quadros a menos
                //    sem ninguém saber de onde vieram.
                drenar(caixa, decoder, saida, p, wav)
            }
            runCatching { saida.stop() }
            saida.release()
            if (decoder != 0L) QuallNative.audioDecoderFree(decoder)
            if (liberavel) {
                QuallNative.audioBoxFree(caixa)
            } else {
                Log.e(TAG, "caixa de slots vazada de propósito (alguns KiB) — ver a doc da classe")
            }
            amostrasNoWav = wav?.finalizar() ?: 0L
            Log.i(TAG, "reprodução encerrada: ${resumo()}")
        }
    }

    /**
     * O `AudioTrack`, dimensionado pelo preset **e pelo mínimo do aparelho**.
     *
     * `USAGE_MEDIA` + `CONTENT_TYPE_MUSIC` porque o que chega é o som de uma tela espelhada. Não
     * é `VOICE_COMMUNICATION`: isso ligaria o processamento de voz do aparelho (AEC, AGC) sobre
     * um fluxo que não é chamada, e o que sairia do alto-falante deixaria de ser o que atravessou
     * a rede — a medição perderia o sentido.
     */
    private fun abrirAudioTrack(p: PresetDeAudio): AudioTrack? = runCatching {
        val mascara = if (p.canais >= 2) {
            AudioFormat.CHANNEL_OUT_STEREO
        } else {
            AudioFormat.CHANNEL_OUT_MONO
        }
        val minimo = AudioTrack.getMinBufferSize(p.taxaHz, mascara, AudioFormat.ENCODING_PCM_16BIT)
        if (minimo <= 0) {
            Log.e(TAG, "getMinBufferSize devolveu $minimo para ${p.taxaHz}Hz ${p.canais}ch")
            return null
        }
        // Quatro quadros de folga sobre o mínimo do aparelho: o suficiente para o
        // `WRITE_BLOCKING` não virar sincronização fina demais, e pouco o bastante para não
        // acrescentar latência que o jitter buffer já pagou. Ver `docs/audio.md` §4.
        val bytesPorQuadro = p.amostrasPorQuadro * 2
        val tamanho = maxOf(minimo, bytesPorQuadro * 4)
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(p.taxaHz)
                    .setChannelMask(mascara)
                    .build()
            )
            .setBufferSizeInBytes(tamanho)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            Log.e(TAG, "AudioTrack não inicializou (state=${t.state})")
            t.release()
            return null
        }
        Log.i(TAG, "AudioTrack: ${p.taxaHz}Hz ${p.canais}ch buffer=${tamanho}B (min=$minimo)")
        t.play()
        t
    }.getOrElse {
        Log.e(TAG, "AudioTrack falhou", it)
        null
    }

    private fun laco(
        caixa: Long,
        decoder: Long,
        saida: AudioTrack,
        p: PresetDeAudio,
        wav: EscritorDeWav?,
    ) {
        val payload = ByteBuffer.allocateDirect(MAX_PAYLOAD)
        val bytesDoPayload = ByteArray(MAX_PAYLOAD)
        val meta = LongArray(6)
        val pcm = ShortArray(p.amostrasPorQuadro)
        val analisador = AnalisadorDeTom(p.taxaHz, p.canais)
        analise = analisador

        val comeco = System.nanoTime()
        var ultimoSlot = comeco
        var ultimoRelato = comeco

        while (!pararPedido) {
            val n = QuallNative.audioBoxTake(caixa, payload, meta, ESPERA_POR_SLOT_MS)
            val agora = System.nanoTime()
            if (n == -1) {
                if ((agora - ultimoSlot) / 1_000_000L > SILENCIO_ATE_DESISTIR_MS) {
                    motivoDaSaida = "${SILENCIO_ATE_DESISTIR_MS / 1000} s sem nenhum slot de áudio" // i18n-fora: detalhe técnico do diário
                    break
                }
                continue
            }
            if (n < -1) {
                errosDeDecodificacao++
                continue
            }
            ultimoSlot = agora
            slotsRecebidos = meta[4]
            slotsDescartadosNaCaixa = meta[5]

            val amostras = decodificar(decoder, meta, payload, bytesDoPayload, n, pcm, p)
            if (amostras <= 0) {
                errosDeDecodificacao++
                continue
            }
            val total = amostras * p.canais
            analisador.analisar(pcm, amostras)
            wav?.escrever(pcm, total)
            aoPcmRecebido?.invoke(pcm, amostras, meta[1], meta[2], p.taxaHz, p.canais)

            val escritos = saida.write(pcm, 0, total, AudioTrack.WRITE_BLOCKING)
            if (escritos < 0) {
                motivoDaSaida = "AudioTrack.write devolveu $escritos"
                Log.e(TAG, motivoDaSaida)
                break
            }
            if (escritos < total) subconsumos++
            quadrosTocados++
            if (quadrosTocados == 1L) {
                primeiroSomMs = (agora - comeco) / 1_000_000.0
            }

            if ((agora - ultimoRelato) > 2_000_000_000L) {
                ultimoRelato = agora
                Log.i(TAG, "áudio: ${resumo()}")
            }
        }
        if (motivoDaSaida.isBlank() && pararPedido) motivoDaSaida = "parado pela casca"
    }

    /** O escoamento do desligamento: o que ficou na caixa, sem esperar por mais nada. */
    private fun drenar(
        caixa: Long,
        decoder: Long,
        saida: AudioTrack,
        p: PresetDeAudio,
        wav: EscritorDeWav?,
    ) {
        val payload = ByteBuffer.allocateDirect(MAX_PAYLOAD)
        val bytesDoPayload = ByteArray(MAX_PAYLOAD)
        val meta = LongArray(6)
        val pcm = ShortArray(p.amostrasPorQuadro)
        var escoados = 0
        while (escoados < 64) {
            val n = QuallNative.audioBoxTake(caixa, payload, meta, 0)
            if (n < 0) break
            escoados++
            slotsRecebidos = meta[4]
            slotsDescartadosNaCaixa = meta[5]
            val amostras = decodificar(decoder, meta, payload, bytesDoPayload, n, pcm, p)
            if (amostras <= 0) continue
            analise?.analisar(pcm, amostras)
            wav?.escrever(pcm, amostras * p.canais)
            aoPcmRecebido?.invoke(pcm, amostras, meta[1], meta[2], p.taxaHz, p.canais)
            saida.write(pcm, 0, amostras * p.canais, AudioTrack.WRITE_BLOCKING)
            quadrosTocados++
        }
        if (escoados > 0) Log.i(TAG, "escoados $escoados slot(s) no desligamento")
    }

    /**
     * As três ordens, e a resposta de cada uma. Devolve amostras **por canal**, ou `-1`.
     *
     * `meta[0]` é a ordem e `meta[3]` é `fec_has_lbrr`. O `-1` do LBRR **não** autoriza
     * `decode_fec`: ele diz "não consegui perguntar", e agir sobre ele seria decidir com uma
     * resposta inventada.
     */
    private fun decodificar(
        decoder: Long,
        meta: LongArray,
        payload: ByteBuffer,
        bytesDoPayload: ByteArray,
        n: Int,
        pcm: ShortArray,
        p: PresetDeAudio,
    ): Int {
        val ordem = meta[0].toInt()
        val temLbrr = meta[3].toInt()

        if (decoder == 0L) {
            // PCMU: uma amostra por byte, e o buraco vira silêncio de verdade — não zeros de
            // µ-law, que são o valor mais negativo possível. Ver `UlawG711`.
            return when (ordem) {
                QuallNative.AudioOrder.FRAME -> {
                    payload.position(0)
                    payload.get(bytesDoPayload, 0, n)
                    UlawG711.decodificar(bytesDoPayload, n, pcm)
                }
                else -> {
                    // G.711 não tem LBRR nenhum, e o núcleo já não oferece `FEC` num fluxo de
                    // PCMU (`fec_disponivel` é preset **e** codec Opus). Se chegar, é silêncio.
                    ocultacoesDePerda++
                    java.util.Arrays.fill(pcm, 0, p.amostrasPorQuadro, 0)
                    p.amostrasPorCanal
                }
            }
        }

        return when (ordem) {
            QuallNative.AudioOrder.FRAME ->
                QuallNative.audioDecoderDecode(decoder, payload, 0, n, false, pcm)

            QuallNative.AudioOrder.FEC -> {
                if (temLbrr == 1) {
                    val r = QuallNative.audioDecoderDecode(decoder, payload, 0, n, true, pcm)
                    if (r > 0) curadosPorFec++
                    r
                } else {
                    // Sem LBRR (ou sem saber), `decode_fec` cairia na ocultação de perda em
                    // silêncio e devolveria sucesso — e a casca contaria como cura. Então se
                    // chama a ocultação **pelo nome**, e se conta no contador certo.
                    if (temLbrr == 0) socorroSemLbrr++ else socorroSemResposta++
                    ocultacoesDePerda++
                    QuallNative.audioDecoderDecode(decoder, null, 0, 0, false, pcm)
                }
            }

            else -> {
                ocultacoesDePerda++
                QuallNative.audioDecoderDecode(decoder, null, 0, 0, false, pcm)
            }
        }
    }

    fun resumo(): String {
        val a = analise
        return "slots=$slotsRecebidos tocados=$quadrosTocados " +
            "descartados_na_caixa=$slotsDescartadosNaCaixa " +
            "fec_curou=$curadosPorFec fec_sem_lbrr=$socorroSemLbrr fec_sem_resposta=$socorroSemResposta " +
            "plc=$ocultacoesDePerda erros=$errosDeDecodificacao subconsumos=$subconsumos " +
            "primeiro_som=${"%.1f".format(primeiroSomMs)}ms " +
            "preset=[${preset?.linha() ?: "?"}] " +
            "tom=[${a?.linha() ?: "não analisado"}] " +
            "tom_verde=${a?.passou() ?: false}"
    }
}
