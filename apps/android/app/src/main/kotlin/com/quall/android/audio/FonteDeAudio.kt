package com.quall.android.audio

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Process
import com.quall.android.core.LogSeguro as Log
import kotlin.math.PI
import kotlin.math.sin

/**
 * De onde vem o PCM que o emissor codifica. **Três origens**, e cada uma com a regra dela.
 *
 * ## A regra, reescrita em 24/09/2026 (e não apagada)
 *
 * Até a fase 2 do R5 este comentário dizia que nenhuma implementação daqui abria o microfone, e que
 * a regra não se negociava. **O Pessoa Exemplo a revogou para todo emissor de câmera** (24/09,
 * `docs/teleprompter-com-camera.md` §4.1 e §12): a câmera transmite com o som do microfone, atrás
 * de um botão que começa desligado. Ficam, e continuam valendo:
 *
 * - **a bancada é sintética** (`docs/audio.md` §8, primeira metade): toda prova de áudio usa
 *   [TomSintetico] ou [TomRitmado]; o microfone real só entra com o sim do Pessoa Exemplo **por corrida**
 *   (a claquete física capta a sala), e nunca o microfone do MacBook;
 * - **o microfone só se abre pela câmera**: [MicrofoneCru] é a única classe daqui que abre
 *   `MediaRecorder.AudioSource.MIC`, e só o [com.quall.android.mirror.MirrorService] a cria, e só
 *   com uma sessão de câmera no ar e o botão ligado — e, desde a placa de captura
 *   (`docs/placa-de-captura-usb.md` §11), o `DonoDaPlaca`, com a entrada USB **da placa** pedida
 *   (a linha da RCA, não a cápsula do telefone). A tela continua sem microfone: o som dela é
 *   [CapturaDoProprioApp], que por construção não alcança cápsula nenhuma e sai **restrita ao
 *   próprio app**;
 * - **ler a permissão não é pedi-la** (`docs/regras-de-frente.md`): quem pede `RECORD_AUDIO` é a
 *   Activity, no toque do botão; aqui só se lê, e a falta vira `null`, sem exceção.
 */
interface FonteDeAudio {
    /** Nome curto para o relatório dizer de onde saiu o som. */
    val nome: String

    /**
     * Enche `pcm` com um quadro intercalado. Devolve amostras **por canal**, ou `0` quando ainda
     * não há um quadro inteiro. **Bloqueia** até haver, ou até o prazo do implementador.
     */
    fun proximoQuadro(pcm: ShortArray): Int

    /**
     * A hora da primeira amostra do quadro que [proximoQuadro] acabou de entregar, em µs de
     * `MONOTONIC` (o relógio do vídeo), ou `null` quando a fonte não sabe
     * (`docs/som-no-receptor.md` §19.3). O [EmissorDeAudio] carimba a partir dela; sem ela, a
     * partir da vaga do quadro no acumulador dele.
     */
    fun instanteDoQuadroUs(): Long? = null

    /**
     * `true` quando [proximoQuadro] bloqueia no ritmo do dispositivo (a captura): aí quem dá o
     * ritmo do laço é a leitura, e o emissor não dorme até a vaga do host ([RitmoDoEmissor]).
     */
    val ritmadaPeloDispositivo: Boolean get() = false

    /**
     * Destrava uma leitura bloqueada, **de outra thread** (a revisão, M2): o emissor que não sai no
     * prazo está preso no `read`, e com ele o microfone continuava aberto. Não libera nada — quem
     * libera é [fechar], na thread do laço. Padrão: nada (o tom não bloqueia).
     */
    fun interromper() {}

    fun fechar()
}

/**
 * O tom de quatro notas do `quall-probe`, gerado aqui.
 *
 * **Não tem hora de captura** ([instanteDoQuadroUs] é `null`): a hora de um quadro sintético é a
 * vaga dele no acumulador do emissor, que é quem dá o ritmo. **A origem de bancada, e a única que não
 * pede permissão nenhuma.**
 *
 * As notas são 400, 500, 800 e 1000 Hz, 25 quadros (0,5 s) cada, amplitude 0,5 do fundo de
 * escala — os mesmos números de `crates/quall-probe/src/audio.rs`, e eles não são gosto:
 *
 * - **cada nota tem número inteiro de ciclos num quadro de 20 ms a 8 kHz**, o que faz a onda
 *   emendar sem salto de fase entre quadros. Sem isso haveria um estalo a cada 20 ms, e alguém
 *   gastaria uma tarde procurando esse estalo na rede;
 * - **a nota troca**, e a troca é o que mantém o VAD do SILK acordado. Um tom estacionário faz a
 *   atividade de fala decair e o **LBRR some no meio do fluxo, sem aviso**, com `useinbandfec=1`
 *   no SDP o tempo todo (`docs/audio.md` §11);
 * - a fase sai do índice **absoluto** da amostra, e não é reiniciada por quadro.
 *
 * Isto **não bloqueia**: quem dá o ritmo é o laço do emissor, que dorme entre quadros.
 */
class TomSintetico(
    private val taxaHz: Int,
    private val canais: Int,
    private val amostrasPorCanal: Int,
) : FonteDeAudio {

    override val nome = "tom sintético (4 notas)" // i18n-fora: nome da origem no diário (bancada)

    private var indice = 0L

    override fun proximoQuadro(pcm: ShortArray): Int {
        val nota = NOTAS[((indice / QUADROS_POR_NOTA) % NOTAS.size).toInt()]
        val amostrasPorCiclo = taxaHz.toDouble() / nota
        val base = indice * amostrasPorCanal
        for (i in 0 until amostrasPorCanal) {
            val fase = 2.0 * PI * (base + i).toDouble() / amostrasPorCiclo
            val a = (sin(fase) * AMPLITUDE * Short.MAX_VALUE).toInt().toShort()
            for (c in 0 until canais) {
                pcm[i * canais + c] = a
            }
        }
        indice++
        return amostrasPorCanal
    }

    override fun fechar() {}

    companion object {
        val NOTAS = intArrayOf(400, 500, 800, 1000)
        const val QUADROS_POR_NOTA = 25L
        const val AMPLITUDE = 0.5
    }
}

/**
 * **Bancada** (`som-no-receptor.md` §19.6.6, teste 12): o tom como uma fonte **ritmada por um
 * dispositivo de mentira** que anda `ppm` mais depressa que o host. Cada quadro fica pronto em
 * `(n + 1) · 20 ms / (1 + ppm)` do host, a leitura bloqueia até lá (como o `AudioRecord.read`), e a
 * hora da primeira amostra é exata. É o que faz a disciplina da deriva rodar de verdade na bancada:
 * no controle (sem disciplina), o envio vai no ritmo do dispositivo de mentira e o carimbo se afasta
 * do host `ppm × 60 ms` por minuto; com ela, o conteúdo é reamostrado e o carimbo fica no host.
 *
 * Só com `prova_ppm_no_som` (`Bancada`); nunca em produto.
 */
class TomRitmado(
    private val taxaHz: Int,
    canais: Int,
    private val amostrasPorCanal: Int,
    private val ppm: Double,
    private val relogioUs: () -> Long = { com.quall.android.capture.MonotonicClock.micros() },
    private val dormirUs: (Long) -> Unit = { Thread.sleep(it / 1000, ((it % 1000) * 1000).toInt()) },
) : FonteDeAudio {

    override val nome = "tom sintético ritmado a %+.0f ppm (bancada)".format(java.util.Locale.ROOT, ppm) // i18n-fora: nome da origem no diário (bancada)
    private val tom = TomSintetico(taxaHz, canais, amostrasPorCanal)
    private var inicioUs: Long? = null
    private var n = 0L
    private var instante: Long? = null
    private val duracaoUs = amostrasPorCanal * 1e6 / taxaHz / (1 + ppm * 1e-6)

    override val ritmadaPeloDispositivo: Boolean get() = true

    override fun proximoQuadro(pcm: ShortArray): Int {
        val ini = inicioUs ?: relogioUs().also { inicioUs = it }
        val pronto = ini + ((n + 1) * duracaoUs).toLong()
        val espera = pronto - relogioUs()
        if (espera > 0) dormirUs(espera)
        instante = ini + (n * duracaoUs).toLong()
        n++
        return tom.proximoQuadro(pcm)
    }

    override fun instanteDoQuadroUs(): Long? = instante

    override fun fechar() {}
}

/**
 * O som que o **próprio app** está tocando, por `AudioPlaybackCapture`.
 *
 * ## O que esta API é, e o que ela não é
 *
 * `AudioPlaybackCaptureConfiguration` (API 29+) captura o áudio que outros apps estão
 * **reproduzindo**. Ela **não abre microfone** — não há caminho dela para a cápsula. Mas o Android
 * a coloca atrás da permissão `RECORD_AUDIO` assim mesmo, e isso tem duas consequências que
 * precisam estar escritas:
 *
 * 1. **é um diálogo de tempo de execução que só o usuário toca.** Nenhum agente concede;
 * 2. **ela também exige um `MediaProjection` vivo** — o mesmo consentimento de gravação de tela,
 *    outro diálogo.
 *
 * ## E ela sai restrita ao próprio app, de propósito
 *
 * `addMatchingUid(Process.myUid())` limita a captura ao **UID deste app**. A regra da casa manda:
 * *"captura de sistema só sob escopo do próprio app quando for para bancada"*. Sem esse filtro, o
 * que entraria no fluxo seria a mistura do aparelho inteiro — o vídeo que o usuário deixou aberto,
 * a mensagem de voz que chegou —, e isso atravessaria a rede e poderia acabar num `.wav`.
 *
 * Um `addMatchingUsage(USAGE_MEDIA)` sem o filtro de UID é o desenho "de produto" que o Android
 * espera, e **não é o que está aqui**. Trocá-lo é decisão de produto com consequência de
 * privacidade, e não cabe a esta frente tomá-la sozinha: está anotado no README como o passo que
 * falta.
 *
 * ## Ela não é dimensionada por números escritos aqui
 *
 * Taxa, canais e amostras por quadro vêm do preset do núcleo. Se o mixador do aparelho entregar
 * outra taxa, o `AudioRecord` reamostra por conta própria — o que esta classe **não** faz é
 * inventar uma conversão de canais: ela pede exatamente o que o preset pede.
 */
class CapturaDoProprioApp private constructor(
    gravador: AudioRecord,
    canais: Int,
    amostrasPorCanal: Int,
) : CapturaPorAudioRecord(gravador, canais, amostrasPorCanal) {

    override val nome = "AudioPlaybackCapture (só o UID deste app)" // i18n-fora: nome da origem no diário

    companion object {
        private const val TAG = "QuallAudio"

        /**
         * Abre a captura. Devolve `null` — **sem lançar** — quando falta permissão, quando o
         * Android é anterior ao 10, ou quando o `AudioRecord` não inicializa.
         *
         * O chamador trata `null` caindo para o tom sintético ou desligando a track de áudio; o
         * que ele não faz é pedir permissão, porque **quem pede é a Activity**, e o motivo está
         * em `docs/regras-de-frente.md` ("ler o estado de uma permissão não é pedi-la").
         */
        @SuppressLint("MissingPermission")
        fun abrir(
            projecao: MediaProjection,
            taxaHz: Int,
            canais: Int,
            amostrasPorCanal: Int,
        ): CapturaDoProprioApp? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                Log.w(TAG, "AudioPlaybackCapture precisa de Android 10; este é ${Build.VERSION.SDK_INT}")
                return null
            }
            return runCatching {
                val config = AudioPlaybackCaptureConfiguration.Builder(projecao)
                    // **O filtro que a regra da casa exige.** Ver a doc da classe.
                    .addMatchingUid(Process.myUid())
                    .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                    .addMatchingUsage(AudioAttributes.USAGE_GAME)
                    .build()
                val mascara = if (canais >= 2) {
                    AudioFormat.CHANNEL_IN_STEREO
                } else {
                    AudioFormat.CHANNEL_IN_MONO
                }
                val minimo = AudioRecord.getMinBufferSize(
                    taxaHz, mascara, AudioFormat.ENCODING_PCM_16BIT
                )
                val tamanho = maxOf(minimo, amostrasPorCanal * canais * 2 * 8)
                val r = AudioRecord.Builder()
                    .setAudioPlaybackCaptureConfig(config)
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(taxaHz)
                            .setChannelMask(mascara)
                            .build()
                    )
                    .setBufferSizeInBytes(tamanho)
                    .build()
                if (r.state != AudioRecord.STATE_INITIALIZED) {
                    Log.e(TAG, "AudioRecord não inicializou (state=${r.state})")
                    r.release()
                    return null
                }
                r.startRecording()
                Log.i(TAG, "AudioPlaybackCapture aberto: ${taxaHz}Hz ${canais}ch buffer=${tamanho}B")
                CapturaDoProprioApp(r, canais, amostrasPorCanal)
            }.getOrElse {
                // `SecurityException` aqui é `RECORD_AUDIO` faltando, e é o caso esperado num
                // aparelho onde ninguém tocou o diálogo. Não é defeito; é estado.
                Log.w(TAG, "AudioPlaybackCapture não abriu: ${it.javaClass.simpleName}: ${Log.erroExterno(it.message)}")
                null
            }
        }
    }
}

/**
 * **A leitura de um `AudioRecord` com a hora da captura**, comum às duas capturas de verdade
 * ([CapturaDoProprioApp] e [MicrofoneCru]): um quadro inteiro por chamada, bloqueando no ritmo do
 * dispositivo, e a hora da primeira amostra dele pelo par (posição, hora) de
 * `AudioRecord.getTimestamp(…, TIMEBASE_MONOTONIC)` — **a hora da captura, e não a da leitura**
 * (`docs/som-no-receptor.md` §19.3): o `AudioRecord` guarda dezenas de milissegundos, e o quadro que
 * sai agora foi capturado antes disso.
 */
abstract class CapturaPorAudioRecord(
    private val gravador: AudioRecord,
    private val canais: Int,
    private val amostrasPorCanal: Int,
) : FonteDeAudio {

    @Volatile private var parado = false
    private var liberado = false

    /** De onde o sistema está lendo de fato (`getRoutedDevice`), ou `null` antes de saber. */
    val dispositivoRoteado: android.media.AudioDeviceInfo? get() = runCatching { gravador.routedDevice }.getOrNull()

    /** Amostras por canal já lidas antes do quadro corrente: o índice da primeira dele. */
    private var quadrosLidos = 0L
    private val par = AudioTimestamp()
    private var instante: Long? = null

    /** Quadros sem par do `getTimestamp` (o dispositivo ainda não tinha um). */
    var semHora = 0L
        private set

    override fun proximoQuadro(pcm: ShortArray): Int {
        if (parado) return 0
        val querido = amostrasPorCanal * canais
        var lidas = 0
        while (lidas < querido) {
            val n = gravador.read(pcm, lidas, querido - lidas, AudioRecord.READ_BLOCKING)
            if (n <= 0) {
                Log.w("QuallAudio", "AudioRecord.read devolveu $n")
                instante = null
                return 0
            }
            lidas += n
        }
        // O par (posição, hora) é do próprio dispositivo, em `MONOTONIC` — o relógio do vídeo; a
        // hora da primeira amostra deste quadro sai dele pela taxa.
        instante = if (gravador.getTimestamp(par, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
            HoraDaCaptura.instanteUs(quadrosLidos, par.framePosition, par.nanoTime, gravador.sampleRate)
        } else {
            semHora++
            null
        }
        quadrosLidos += amostrasPorCanal
        return amostrasPorCanal
    }

    override fun instanteDoQuadroUs(): Long? = instante

    /** O `read` bloqueia até o dispositivo ter um quadro: é ele quem dá o ritmo. */
    override val ritmadaPeloDispositivo: Boolean get() = true

    /** `stop` de fora faz o `read` bloqueado voltar; o `release` continua com [fechar]. */
    override fun interromper() {
        parado = true
        runCatching { gravador.stop() }
    }

    override fun fechar() {
        if (liberado) return
        liberado = true
        parado = true
        runCatching { gravador.stop() }
        gravador.release()
    }
}

/**
 * **O microfone, cru** — o som da câmera (`docs/teleprompter-com-camera.md` §4, fase 2 do R5).
 *
 * ## "Cru, como filmadora" (Pessoa Exemplo, 24/09)
 *
 * Sem supressor de ruído, sem cancelamento de eco, sem ganho automático. A fonte é
 * `MediaRecorder.AudioSource.MIC`, e não `UNPROCESSED`: **o S24 não tem `UNPROCESSED`** (a S-A6
 * refeita, §8.2), e `CAMCORDER` aplica o tratamento do fabricante. No `MIC` do S24 o NS e o AEC já
 * vêm desligados e o AGC não existe (S-A6); **os três são desligados explicitamente aqui assim
 * mesmo**, se o aparelho os oferece na sessão desta gravação, porque outro aparelho pode vir com
 * eles ligados. O que se achou e o que ficou vão para o diário ([efeitos]).
 *
 * ## Quem abre, e quando
 *
 * Só o `MirrorService`, com uma sessão de câmera no ar e o botão ligado; o botão desligado **fecha**
 * (`stop` + `release`), e não cala por software — o indicador do sistema diz a verdade (§4.2). A
 * permissão é pedida pela Activity; aqui ela só falta, e a falta é `null`.
 *
 * Taxa, canais e quadro vêm do preset da espécie `MICROPHONE` do núcleo (Opus mono 48 kHz, 20 ms).
 *
 * ## A entrada, escolhida explicitamente (`docs/placa-de-captura-usb.md` §8 e §11, item 3)
 *
 * Medido no S24 com a placa de captura plugada: o `MIC` sem preferência lia **da placa** (a entrada
 * USB vem antes do microfone embutido na regra do sistema). Por isso quem abre diz a entrada
 * ([abrir] com `preferido`): a câmera comum e a R5 pedem o `TYPE_BUILTIN_MIC`, e o som da placa pede
 * a entrada USB dela (`DonoDaPlaca`). O mesmo `MicrofoneCru` serve aos dois: é uma linha crua,
 * sem NS/AEC/AGC, com o mesmo detector de silêncio digital (a frase é de quem abre).
 */
class MicrofoneCru private constructor(
    gravador: AudioRecord,
    private val canais: Int,
    amostrasPorCanal: Int,
    /** Os efeitos do sistema nesta sessão de gravação: o que existia e como ficou. */
    val efeitos: String,
    /**
     * Os objetos dos efeitos desligados, **vivos até fechar**. Soltá-los logo depois de desligar
     * devolveria o controle do efeito a quem o criou (a configuração de pré-processamento do
     * aparelho), e o estado dele deixaria de ser nosso — hipótese sobre o `AudioFlinger`, não
     * medida; segurar custa nada.
     */
    private val objetosDosEfeitos: List<AudioEffect>,
    /** Entrou (`true`) ou saiu (`false`) do silêncio digital. Da thread do laço do som. */
    private val aoSilencioDigital: ((Boolean) -> Unit)?,
    override val nome: String,
    /** O palpite do diário para o silêncio digital ("outro app com o microfone?"). */
    private val porqueDoSilencio: String,
) : CapturaPorAudioRecord(gravador, canais, amostrasPorCanal) {

    private var zerosSeguidos = 0
    private var emSilencio = false

    /**
     * **O microfone "ocupado" do Android 10+ não falha: grava zeros** (a revisão, menor). Quando
     * outro app tem prioridade de captura (uma chamada, o assistente), o `startRecording` volta bem e
     * o `read` entrega silêncio digital — amostras exatamente zero, que uma cápsula de verdade nunca
     * dá (há sempre ruído). Três segundos disso viram aviso na tela, e a volta do som o tira.
     */
    override fun proximoQuadro(pcm: ShortArray): Int {
        val n = super.proximoQuadro(pcm)
        if (n <= 0) return n
        var zero = true
        for (i in 0 until n * canais) if (pcm[i].toInt() != 0) { zero = false; break }
        if (zero) {
            zerosSeguidos++
            if (!emSilencio && zerosSeguidos >= QUADROS_DE_SILENCIO) {
                emSilencio = true
                Log.w(TAG, "$nome: ${zerosSeguidos} quadros seguidos de silêncio digital — $porqueDoSilencio")
                runCatching { aoSilencioDigital?.invoke(true) }
            }
        } else {
            zerosSeguidos = 0
            if (emSilencio) {
                emSilencio = false
                Log.i(TAG, "$nome: o som voltou depois do silêncio digital")
                runCatching { aoSilencioDigital?.invoke(false) }
            }
        }
        return n
    }

    override fun fechar() {
        super.fechar()
        objetosDosEfeitos.forEach { runCatching { it.release() } }
    }

    companion object {
        private const val TAG = "QuallAudio"

        /** 3 s de quadros de 20 ms. */
        private const val QUADROS_DE_SILENCIO = 150

        /**
         * Abre o microfone. Devolve `null` — **sem lançar** — quando falta `RECORD_AUDIO` ou quando
         * o `AudioRecord` não inicializa; [falha] recebe o porquê tipado (a tela monta a frase no
         * idioma dela, [FalhaDoMicrofone.frase]); [motivo], a frase de antes, em português (legado do
         * `MirrorService` e da `DonoDaPlaca`, até passarem a [falha]; `docs/traducao.md`, Android).
         */
        @SuppressLint("MissingPermission")
        fun abrir(
            taxaHz: Int,
            canais: Int,
            amostrasPorCanal: Int,
            motivo: (String) -> Unit = {},
            aoSilencioDigital: ((Boolean) -> Unit)? = null,
            /** A entrada pedida ao sistema (`setPreferredDevice`); `null` deixa a regra do sistema. */
            preferido: android.media.AudioDeviceInfo? = null,
            nome: String = "microfone (MIC, cru)",
            porqueDoSilencio: String = "outro app com o microfone?",
            falha: (FalhaDoMicrofone) -> Unit = {},
        ): MicrofoneCru? {
            var gravador: AudioRecord? = null
            var objetos: List<AudioEffect> = emptyList()
            try {
                val mascara = if (canais >= 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
                val minimo = AudioRecord.getMinBufferSize(taxaHz, mascara, AudioFormat.ENCODING_PCM_16BIT)
                // Oito quadros de folga, como a captura do próprio app: o laço lê no ritmo do
                // dispositivo, e a folga só segura um soluço do escalonador.
                val tamanho = maxOf(minimo, amostrasPorCanal * canais * 2 * 8)
                val r = AudioRecord.Builder()
                    .setAudioSource(MediaRecorder.AudioSource.MIC)
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(taxaHz)
                            .setChannelMask(mascara)
                            .build()
                    )
                    .setBufferSizeInBytes(tamanho)
                    .build()
                gravador = r
                // Antes do `startRecording`: a entrada vale desde a abertura da captura.
                if (preferido != null && !r.setPreferredDevice(preferido)) {
                    Log.w(TAG, "$nome: o sistema recusou a entrada pedida (tipo ${preferido.type})")
                }
                if (r.state != AudioRecord.STATE_INITIALIZED) {
                    Log.e(TAG, "microfone: o AudioRecord não inicializou (state=${r.state})")
                    falha(FalhaDoMicrofone.RECUSOU)
                    motivo("o microfone não abriu (o aparelho recusou a gravação)") // i18n-fora: legado, ver falha
                    r.release()
                    return null
                }
                val (efeitos, objs) = desligarEfeitos(r.audioSessionId)
                objetos = objs
                r.startRecording()
                if (r.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                    // Outro app com o microfone, num Android anterior ao 10 (do 10 em diante ele
                    // grava silêncio em vez de falhar: ver [proximoQuadro]).
                    Log.w(TAG, "microfone: startRecording não gravou (recordingState=${r.recordingState})")
                    falha(FalhaDoMicrofone.OCUPADO)
                    motivo("o microfone está ocupado por outro app") // i18n-fora: legado, ver falha
                    objetos.forEach { runCatching { it.release() } }
                    r.release()
                    return null
                }
                Log.i(TAG, "$nome aberto: MIC ${taxaHz}Hz ${canais}ch buffer=${tamanho}B efeitos=[$efeitos] " +
                    "pedida=${preferido?.let { "tipo ${it.type}" } ?: "a do sistema"}")
                return MicrofoneCru(r, canais, amostrasPorCanal, efeitos, objetos, aoSilencioDigital, nome, porqueDoSilencio)
            } catch (t: Throwable) {
                // `SecurityException` aqui é `RECORD_AUDIO` faltando: estado, não defeito.
                Log.w(TAG, "microfone não abriu: ${t.javaClass.simpleName}: ${Log.erroExterno(t.message)}")
                falha(if (t is SecurityException) FalhaDoMicrofone.SEM_PERMISSAO else FalhaDoMicrofone.NAO_ABRIU)
                motivo(if (t is SecurityException) "sem permissão de microfone" else "o microfone não abriu: ${t.message}") // i18n-fora: legado, ver falha
                objetos.forEach { runCatching { it.release() } }
                runCatching { gravador?.release() }
                return null
            }
        }

        /**
         * Os três efeitos desligados, **se existirem** nesta sessão (`create` devolve `null` quando o
         * aparelho não tem o efeito). Devolve a linha do diário — `NS=ligado->desligado
         * AEC=desligado AGC=indisponível` — e os objetos, que ficam vivos até o microfone fechar.
         */
        private fun desligarEfeitos(sessao: Int): Pair<String, List<AudioEffect>> {
            val vivos = mutableListOf<AudioEffect>()
            fun um(nome: String, disponivel: Boolean, criar: () -> AudioEffect?): String {
                if (!disponivel) return "$nome=indisponível" // i18n-fora: diário
                val e = runCatching { criar() }.getOrNull() ?: return "$nome=indisponível" // i18n-fora: diário
                vivos += e
                return try {
                    val antes = e.enabled
                    if (antes) e.enabled = false
                    val depois = e.enabled
                    "$nome=${if (antes) "ligado->" else ""}${if (depois) "LIGADO(recusou desligar)" else "desligado"}"
                } catch (t: Throwable) {
                    "$nome=erro(${t.javaClass.simpleName})"
                }
            }
            val linha = listOf(
                um("NS", NoiseSuppressor.isAvailable()) { NoiseSuppressor.create(sessao) },
                um("AEC", AcousticEchoCanceler.isAvailable()) { AcousticEchoCanceler.create(sessao) },
                um("AGC", AutomaticGainControl.isAvailable()) { AutomaticGainControl.create(sessao) },
            ).joinToString(" ")
            return linha to vivos
        }
    }
}

/**
 * **Por que o microfone não abriu** ([MicrofoneCru.abrir]), tipado: quem mostra monta a frase no idioma
 * dele com [frase] (`docs/traducao.md`, Android), e decide pelo código, sem procurar palavra na frase.
 */
enum class FalhaDoMicrofone(@androidx.annotation.StringRes val frase: Int) {
    /** O `AudioRecord` não inicializou: o aparelho recusou a gravação. */
    RECUSOU(com.quall.android.R.string.cam_falha_mic_recusou),
    /** O `startRecording` não gravou: outro app com o microfone (antes do Android 10). */
    OCUPADO(com.quall.android.R.string.cam_falha_mic_ocupado),
    /** `SecurityException`: falta `RECORD_AUDIO`. */
    SEM_PERMISSAO(com.quall.android.R.string.cam_mic_motivo_sem_permissao),
    /** Outra exceção ao abrir (o detalhe fica no diário). */
    NAO_ABRIU(com.quall.android.R.string.cam_falha_mic_nao_abriu),
}
