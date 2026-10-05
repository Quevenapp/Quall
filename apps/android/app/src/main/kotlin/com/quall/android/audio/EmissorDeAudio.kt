package com.quall.android.audio

import com.quall.android.core.LogSeguro as Log
import com.quall.android.capture.MonotonicClock
import com.quall.android.core.QuallNative
import java.nio.ByteBuffer

/**
 * **Manda o som junto com a tela.** A outra metade do áudio no Android.
 *
 * Fonte → `quall_audio_encoder_encode` → `quall_track_send_audio`. Roda numa thread própria; o
 * laço do `MediaCodec` de vídeo não espera por ela.
 *
 * ## A thread é separada, e o handle da track atravessa — com uma condição
 *
 * O emissor de vídeo tem o laço dele, que bloqueia até 25 ms esperando saída do encoder. Áudio
 * pendurado nesse ritmo engasgaria: 20 ms de som é um prazo, não uma meta. Então há uma thread.
 *
 * O Windows resolveu isso passando **pacotes prontos** por um canal e deixando a thread da sessão
 * chamar `enviar_audio`, para que nenhum handle do núcleo saísse da thread dona
 * (`apps/windows/src/audio.rs`). Aqui o handle atravessa, e a diferença é que a fronteira C **é**
 * a barreira: `quall_track_send_audio` é seguro de várias threads (o que não é seguro de várias
 * threads é o **encoder**, cujo estado é preditivo — e ele só é tocado aqui dentro). O que esta
 * classe garante é que a track não seja liberada enquanto o laço roda: [parar] espera a thread
 * sair, e quem chama libera depois.
 *
 * ## Um quadro por chamada, sempre
 *
 * O pacotizador da libdatachannel não fragmenta: uma mensagem entra, um pacote RTP sai. Dois
 * quadros de Opus concatenados numa chamada viram um pacote que o outro lado decodifica errado,
 * **sem erro nenhum no caminho** — para o RTP é só um payload maior (`docs/audio.md` §6).
 *
 * ## O relógio é o mesmo do vídeo, e o carimbo é da captura, não do envio
 *
 * `timestamp_us` está em `MONOTONIC`, o mesmo relógio que carimba o quadro de vídeo (o da câmera
 * passa por [com.quall.android.capture.RelogioDoPts]). Duas bases de tempo diferentes nas duas
 * tracks da mesma sessão fariam o alinhamento do receptor ser uma conta sobre dois relógios que não
 * têm relação nenhuma (`docs/som-no-receptor.md` §5.1).
 *
 * **O carimbo é a hora da captura, em tempo de mídia** ([RelogioDoSom], §19.3). Até 21/09/2026 ele
 * era `MonotonicClock.micros()` **no envio**, depois do encode: na captura do próprio app o
 * `AudioRecord` guarda até 160 ms, e o som saía carimbado atrasado por tudo isso. Agora a fonte diz
 * a hora da primeira amostra do quadro ([FonteDeAudio.instanteDoQuadroUs]); o tom sintético, que
 * não tem captura, usa a vaga do quadro no acumulador. O carimbo anda um quadro por vez e reancora
 * quando a hora da fonte se afasta mais de 40 ms.
 *
 * ## E a origem nunca é escolhida aqui
 *
 * A origem é uma [FonteDeAudio] que o chamador abre. Até 24/09/2026 este parágrafo dizia que ele
 * **nunca** abria o microfone; a regra caiu para todo emissor de câmera (`docs/teleprompter-com-camera.md`
 * §4.1): com a câmera, a fonte pode ser o [MicrofoneCru], na espécie `MICROPHONE`, e só com o botão
 * ligado. Esta classe continua sem caminho para `MediaRecorder.AudioSource`: quem abre o microfone é
 * o `MirrorService`, e a bancada troca a fonte pelo tom (`docs/audio.md` §8, a regra que fica).
 */
class EmissorDeAudio(
    private val track: Long,
    private val kind: Int,
    private val fonte: FonteDeAudio,
    private val preset: PresetDeAudio,
    private val prova: ProvaDoSom = ProvaDoSom(),
    /**
     * Chamado da thread do emissor, uma vez, quando o laço sai **por conta própria** (a fonte parou
     * de entregar, o encoder não nasceu) — e não quando [parar] foi pedido. Com o motivo.
     */
    private val aoSairSozinho: ((String) -> Unit)? = null,
) {
    /**
     * Os braços **de bancada** da prova do §19.3, lidos de `Bancada` pelo chamador. Todos desligados
     * em produto.
     */
    data class ProvaDoSom(
        /** O controle antigo: o carimbo é a hora do envio, depois do encode. */
        val carimboNoEnvio: Boolean = false,
        /** O controle da reancoragem: tempo de mídia puro desde a primeira âncora. */
        val semReancorar: Boolean = false,
        /**
         * Uma lacuna de tantos ms na fonte, uma vez, [lacunaAosMs] depois do primeiro quadro: o laço
         * para, e o acumulador religa quando volta (a retomada, sem mexer em nada do aparelho).
         */
        val lacunaMs: Long = 0,
        val lacunaAosMs: Long = 10_000,
        /** O controle da disciplina da deriva (§19.6): a razão fica em 1. */
        val semDisciplina: Boolean = false,
        /** O dispositivo de mentira do teste de bancada ([TomRitmado]), em ppm; 0 desliga. */
        val ppmNoSom: Int = 0,
    ) {
        fun linha(): String =
            "carimbo_no_envio=$carimboNoEnvio sem_reancorar=$semReancorar lacuna_ms=$lacunaMs " +
                "sem_disciplina=$semDisciplina ppm_no_som=$ppmNoSom"
    }

    companion object {
        private const val TAG = "QuallAudio"

        /** Teto de um pacote de áudio: `MAX_AMOSTRA` da fronteira. */
        private const val MAX_PACOTE = 4096
    }

    @Volatile private var pararPedido = false
    private var thread: Thread? = null

    @Volatile var quadrosEnviados = 0L; private set
    @Volatile var bytesEnviados = 0L; private set
    @Volatile var errosDeCodificacao = 0L; private set
    @Volatile var errosDeEnvio = 0L; private set
    @Volatile var quadrosSemFonte = 0L; private set
    private var semFonteSeguidos = 0
    /** Quadros que a fonte entregou sem hora: carimbados pela vaga do acumulador. */
    @Volatile var quadrosSemHora = 0L; private set
    @Volatile var motivoDaSaida = ""; private set

    private val relogio = RelogioDoSom(preset.quadroMs * 1000L, reancorar = !prova.semReancorar)
    private var proximoResumoEm = 3_000L

    /**
     * **A fonte ritmada pelo dispositivo** (a captura; o [TomRitmado] da bancada) passa pela linha
     * com a disciplina da deriva (§19.6): o conteúdo é reamostrado para o carimbo seguir o host. A
     * hora vem só da fonte, nunca da vaga (M2). O tom de produto não tem deriva nenhuma (a vaga já é
     * hora do host) e segue pelo [relogio].
     */
    private val linhaRitmada: LinhaDoSomRitmado? =
        if (fonte.ritmadaPeloDispositivo) {
            LinhaDoSomRitmado(preset.taxaHz, preset.canais, preset.amostrasPorCanal, disciplina = !prova.semDisciplina)
        } else null

    fun iniciar(): Boolean {
        if (kind != QuallNative.TrackKind.SYSTEM_AUDIO && kind != QuallNative.TrackKind.MICROPHONE) {
            motivoDaSaida = "espécie $kind não é de áudio" // i18n-fora: detalhe técnico do diário
            return false
        }
        val t = Thread({ rodar() }, "quall-audio-emissor")
        t.isDaemon = true
        thread = t
        t.start()
        return true
    }

    /**
     * Pede a saída e espera até 2 s. Devolve `true` quando a thread saiu — só então quem chamou pode
     * liberar a track, que o laço toca com `quall_track_send_audio`. `false` é para **vazar** a
     * track, e não para liberá-la embaixo de uma thread viva.
     */
    fun parar(): Boolean {
        pararPedido = true
        val t = thread ?: return true
        t.join(500)
        if (t.isAlive) {
            // Preso na leitura (a revisão, M2): destrava a fonte de fora — senão o microfone ficava
            // aberto com a thread — e espera o resto do prazo.
            Log.w(TAG, "o laço do som não saiu em 500 ms — interrompendo a fonte (${fonte.nome})")
            fonte.interromper()
            t.join(1_500)
        }
        return !t.isAlive
    }

    /** O laço está rodando (não saiu, nem por pedido nem sozinho). */
    val vivo: Boolean get() = thread?.isAlive == true

    private fun rodar() {
        val encoder = QuallNative.audioEncoderNew(kind, QuallNative.AudioCodec.DEFAULT)
        if (encoder == 0L) {
            motivoDaSaida = "audioEncoderNew: ${QuallNative.lastError()}"
            Log.e(TAG, "audioEncoderNew status=${QuallNative.lastStatus()}: ${Log.erroExterno(motivoDaSaida)}")
            fonte.fechar()
            if (!pararPedido) aoSairSozinho?.invoke(motivoDaSaida)
            return
        }
        Log.i(TAG, "emissor de áudio: ${preset.linha()} origem=${fonte.nome} prova=[${prova.linha()}]")

        val pcm = ShortArray(preset.amostrasPorQuadro)
        val pacote = ByteBuffer.allocateDirect(MAX_PACOTE)
        // Cadência por **acumulador** no tom, e não por `sleep` fixo: um `sleep(20)` acumula o erro
        // de cada volta e o fluxo escorrega alguns por cento, que do outro lado vira um jitter
        // buffer subalimentado depois de alguns minutos. Na captura, pela leitura (M6).
        val quadroUs = preset.quadroMs * 1000L
        // O ritmo: o acumulador no tom; a própria leitura na captura, que bloqueia no ritmo do
        // dispositivo ([RitmoDoEmissor], M6 da crítica da disciplina da deriva).
        val ritmo = RitmoDoEmissor(quadroUs, fonte.ritmadaPeloDispositivo, MonotonicClock.micros())
        val inicioUs = ritmo.vagaUs
        var lacunaFeita = prova.lacunaMs <= 0

        try {
            while (!pararPedido) {
                if (!lacunaFeita && MonotonicClock.micros() - inicioUs >= prova.lacunaAosMs * 1000L) {
                    // **Bancada**: a fonte para por `lacunaMs` e volta — a retomada que a
                    // reancoragem existe para pegar. Ver [ProvaDoSom].
                    lacunaFeita = true
                    Log.i(TAG, "prova: lacuna de ${prova.lacunaMs} ms na fonte, agora")
                    Thread.sleep(prova.lacunaMs)
                }
                // A vaga deste quadro no acumulador: a hora dele quando a fonte não sabe dizer.
                val vagaUs = ritmo.vagaUs
                val amostras = fonte.proximoQuadro(pcm)
                if (amostras <= 0) {
                    quadrosSemFonte++
                    semFonteSeguidos++
                    // **Seguidos**, e não no total (a revisão, menor): 500 falhas espalhadas por uma
                    // hora de microfone não são "a origem parou".
                    if (semFonteSeguidos > 500) {
                        motivoDaSaida = "a origem de áudio parou de entregar quadros" // i18n-fora: detalhe técnico do diário
                        break
                    }
                    Thread.sleep(5)
                    continue
                }
                semFonteSeguidos = 0
                val linha = linhaRitmada
                if (linha != null) {
                    // A fonte ritmada: a hora é só a dela (M2), e a linha devolve os quadros de
                    // saída já carimbados.
                    val horaDaFonte = fonte.instanteDoQuadroUs()
                    if (horaDaFonte == null) quadrosSemHora++
                    val degrausAntes = linha.degraus
                    val pelaVagaAntes = linha.pelaVaga
                    val trocasAntes = linha.trocasParaOPar
                    // A vaga é o recuo (a revisão do código, D): sem par nenhum em 1 s, a hora dela
                    // ancora e segue até o par aparecer, e a captura não fica muda.
                    for ((quadro, carimbo) in linha.quadro(pcm, amostras, horaDaFonte, vagaUs)) {
                        enviar(encoder, quadro, quadro.size, carimbo, pacote)
                    }
                    if (linha.pelaVaga && !pelaVagaAntes) {
                        Log.w(TAG, "som: o getTimestamp não deu par em 1 s; o carimbo vai pela hora da vaga até o par aparecer")
                    }
                    if (linha.trocasParaOPar != trocasAntes) {
                        Log.i(TAG, "som: o par apareceu depois de ${linha.quadrosPelaVaga} quadro(s) pela vaga; a fase foi corrigida (ε %.1f ms)".format(java.util.Locale.ROOT, linha.epsUs / 1000))
                    }
                    if (linha.degraus != degrausAntes) {
                        Log.i(TAG, "degrau no carimbo do som: ${linha.lacunas} lacuna(s), ${linha.disc.socorros} socorro(s)")
                    }
                } else {
                    val hora = fonte.instanteDoQuadroUs() ?: vagaUs.also { quadrosSemHora++ }
                    // **Antes do encode**: se ele falhar, o quadro ocupou os 20 ms dele assim mesmo,
                    // e a linha do tempo anda (crítica 3, miúdo).
                    val reancoragensAntes = relogio.reancoragens
                    val carimbo = relogio.carimbar(hora)
                    if (relogio.reancoragens != reancoragensAntes) {
                        Log.i(TAG, "carimbo do som reancorado: salto de ${(relogio.desvioUs) / 1000} ms " +
                            "(${relogio.reancoragens} reancoragem(ns))")
                    }
                    enviar(encoder, pcm, amostras * preset.canais, carimbo, pacote)
                }
                // Uma linha por minuto de som (L5). Pelo contador, e não pelo resto: uma volta sem
                // quadro de saída (a linha ritmada pode dar zero ou dois) repetia a linha.
                if (quadrosEnviados >= proximoResumoEm) {
                    proximoResumoEm = quadrosEnviados + 3_000
                    if (quadrosEnviados > 0) Log.i(TAG, "som: ${resumoDaDisciplina()}")
                }

                val esperaUs = ritmo.depoisDoQuadro(MonotonicClock.micros())
                if (esperaUs > 0) {
                    Thread.sleep(esperaUs / 1000, ((esperaUs % 1000) * 1000).toInt())
                }
            }
        } catch (e: InterruptedException) {
            motivoDaSaida = "interrompido"
        } finally {
            QuallNative.audioEncoderFree(encoder)
            fonte.fechar()
            val sozinho = !pararPedido
            if (motivoDaSaida.isBlank()) motivoDaSaida = "parado pela casca"
            Log.i(TAG, "emissão de áudio encerrada: ${resumo()}")
            if (sozinho) runCatching { aoSairSozinho?.invoke(motivoDaSaida) }
        }
    }

    /**
     * Um quadro: o encode e o envio. Sem `continue` numa falha de encode: o quadro que não saiu
     * ocupou a vaga dele, e o ritmo segue (antes o `continue` pulava o acumulador, e o quadro
     * seguinte saía na mesma vaga).
     */
    private fun enviar(encoder: Long, quadro: ShortArray, total: Int, carimbo: Long, pacote: ByteBuffer) {
        val n = QuallNative.audioEncoderEncode(encoder, quadro, total, pacote)
        if (n <= 0) {
            errosDeCodificacao++
            if (errosDeCodificacao == 1L) {
                Log.e(TAG, "audioEncoderEncode: ${Log.erroExterno(QuallNative.lastError())}")
            }
            return
        }
        val timestampUs = if (prova.carimboNoEnvio) MonotonicClock.micros() else carimbo
        val st = QuallNative.trackSendAudio(track, pacote, 0, n, timestampUs)
        if (st != QuallNative.Status.OK) {
            // Descartar e seguir, como o vídeo: enfileirar para tentar de novo é exatamente o que
            // não se faz com mídia ao vivo.
            errosDeEnvio++
            if (errosDeEnvio == 1L) {
                Log.w(TAG, "trackSendAudio: ${QuallNative.Status.nome(st)} — descartando e seguindo")
            }
        } else {
            quadrosEnviados++
            bytesEnviados += n
        }
    }

    /** A disciplina da deriva, para o diário (L5): `f`, o ajuste, ε e os degraus. */
    fun resumoDaDisciplina(): String {
        val l = linhaRitmada ?: return "disciplina=[sem fonte ritmada]"
        return ("disciplina=[f_ppm=%.2f ajuste_ppm=%.2f eps_us=%.0f degraus=%d lacunas=%d socorros=%d picos=%d " +
            "sem_hora=%d rajada_sem_hora=%d pela_vaga=%d trocas_para_o_par=%d cortadas=%d ligada=%s]").format(
            java.util.Locale.ROOT, l.disc.fPpm, l.sinc.u * 1e6, l.epsUs, l.degraus, l.lacunas,
            l.disc.socorros, l.picosIgnorados, l.semHora, l.maiorRajadaSemHora, l.quadrosPelaVaga,
            l.trocasParaOPar, l.amostrasCortadas, l.disc.ligada,
        )
    }

    fun resumo(): String =
        "enviados=$quadrosEnviados bytes=$bytesEnviados " +
            "erros_codec=$errosDeCodificacao erros_envio=$errosDeEnvio sem_fonte=$quadrosSemFonte " +
            "sem_hora=$quadrosSemHora relogio_do_som=[${relogio.linha()}] ${resumoDaDisciplina()} prova=[${prova.linha()}] " +
            "origem=${fonte.nome} preset=[${preset.linha()}]"
}
