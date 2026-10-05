package com.quall.android.capture

import com.quall.android.aceleradoPorHardware

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import com.quall.android.EncodePreset
import java.nio.Buffer
import java.nio.ByteBuffer
import java.util.concurrent.Executor

/**
 * MediaCodec por superfície de entrada → Annex-B → [FrameSink], comum à tela e à câmera.
 *
 * Extraído de um `H264ScreenEncoder` que só sabia de `MediaProjection`, nesta rodada em que a
 * câmera passou a alimentar o mesmo caminho de encode que a tela já usava. A única coisa que muda
 * entre as duas fontes é **quem produz quadros na superfície de entrada** — a leitura de saída
 * (drenar o `MediaCodec`, decidir "é IDR?" pelo bitstream, colar SPS/PPS, conferir start code,
 * contar estatística) é idêntica, e é justamente aí que moravam quase todos os defeitos achados
 * no M2 (offset do OMX legado, csd perdido do segundo IDR em diante, fila por não respeitar
 * `target_fps`). Duplicar esse código para a câmera seria arriscar reintroduzir cada um deles
 * numa segunda cópia — por isso ele mora aqui uma vez só, e [H264ScreenEncoder]/[H264CameraEncoder]
 * só implementam [iniciarFonte]/[pararFonte].
 *
 * Decisões amarradas ao contrato do projeto (não deste arquivo):
 *  - **H.264 baseline**: `KEY_PROFILE = AVCProfileBaseline`.
 *  - **Faixa de cor limitada**: `KEY_COLOR_RANGE = COLOR_RANGE_LIMITED` — decisão do projeto em
 *    `docs/contrato-sidecar.md`. Vale para os dois presets: nada aqui distingue tela de câmera.
 *  - **GOP curto**: `KEY_I_FRAME_INTERVAL`, em segundos.
 *  - **Sem filas**: `KEY_LATENCY = 1` (API 30+, o piso do A10s) e dreno imediato de cada saída.
 *  - **`target_fps` respeitado na entrada**: `KEY_MAX_FPS_TO_ENCODER` manda a fonte nativa da
 *    superfície (`GraphicBufferSource`) **descartar** o excesso que o produtor entrega acima da
 *    taxa pedida — a `VirtualDisplay` na taxa de atualização da tela (60 Hz no A10s, 90 Hz no
 *    A07), a câmera na taxa que o sensor/AE escolher. Sem isso, medido na bancada com a tela: o
 *    A07 pedindo 30 fps entregava 67 e a latência p50 ia a 251,7 ms, com o `.h264` saindo
 *    perfeito — a fila represada só aparece na latência, nunca no arquivo. Por isso o relatório
 *    de qualquer captura desta classe reporta **fps obtido ao lado da latência**, sempre.
 *
 * ## Todo IDR leva SPS e PPS
 *
 * O buffer de saída do `MediaCodec` de vídeo já vem em **Annex-B**, e o `csd` (SPS/PPS) chega uma
 * única vez, num buffer marcado `BUFFER_FLAG_CODEC_CONFIG`, antes do primeiro quadro. Ele é
 * guardado em [csd] e prefixado em **todo** IDR que não o traga por conta própria (decidido lendo
 * os tipos de NAL do buffer, não confiando na flag da API) — sem isso, só o primeiro IDR da sessão
 * levaria parâmetro, e quem entrasse no meio ficaria sem imagem: o defeito que
 * `docs/contrato-track.md` existe para evitar.
 *
 * ## O pedido de IDR não é esquecido antes de ser confirmado
 *
 * `quall_track_take_idr_request` **consome** a bandeira do núcleo assim que lida — se o quadro que
 * carregava o pedido for descartado, ou a chamada de forçar não pegar, o pedido some sem que
 * ninguém saiba (dívida 15 de `docs/divida-do-nucleo.md`). Por isso [idrDevido] só cai quando
 * [drainOne] vê, **no bitstream**, um NAL IDR de fato saindo — nunca no instante em que o pedido é
 * repassado ao codec via `PARAMETER_KEY_REQUEST_SYNC_FRAME`.
 */
abstract class H264SurfaceEncoder(
    private val sink: FrameSink,
    protected val width: Int,
    protected val height: Int,
    protected val targetFps: Int = 30,
    private val bitrateBps: Int = 6_000_000,
    private val gopSeconds: Float = 2f,
    @Suppress("unused") protected val preset: EncodePreset = EncodePreset.SCREEN,
    /**
     * Guardar um [FrameRecord] por quadro. Ligado no modo sidecar, que precisa da lista inteira
     * para escrever o `.json`. **Desligado ao espelhar**: uma sessão de meia hora a 30 fps são
     * 54 mil registros que ninguém lê, num aparelho de 1,79 GB.
     */
    private val colecionarQuadros: Boolean = false,
    /**
     * A fonte **declara** que `presentationTimeUs` é comparável a [nowMicrosParaLatencia]?
     *
     * Existe **além** do teto numérico [LATENCIA_IMPLAUSIVEL_ACIMA_DE_US], não no lugar dele —
     * achado em bancada nos dois aparelhos que o M4 exige prova. No A07, a câmera declara
     * `SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME` e mesmo assim o delta saiu em ~2,94 **horas** (pego
     * pelo teto numérico). No A10s, a câmera declara `UNKNOWN` — que a documentação do Android
     * define como **não comparável a relógio de sistema nenhum**, sem meio-termo — e o delta saiu
     * em ~103 ms: um número **plausível**, que o teto numérico sozinho deixaria passar, mas que a
     * própria plataforma diz que não significa nada. As duas descobertas juntas mostram que nem a
     * promessa da API (REALTIME) nem a plausibilidade do número sozinhos bastam; a resposta
     * honesta usa os dois. É parâmetro de construtor, e não `open val` sobrescrito por
     * subclasse, de propósito: uma propriedade `open` lida durante a inicialização da
     * superclasse veria o campo da subclasse (`cameraSource`) ainda não atribuído — o clássico
     * problema de chamada virtual no construtor.
     */
    private val latenciaComparavel: Boolean = true,
    /**
     * Período do **refresh intra gradual**, em quadros. `0` desliga (o padrão, e o
     * comportamento histórico deste arquivo).
     *
     * Com N > 0 o encoder deixa de consertar a imagem com um IDR inteiro e passa a renovar uma
     * faixa de macroblocos a cada quadro, fechando a imagem em N quadros. É
     * `MediaFormat.KEY_INTRA_REFRESH_PERIOD`, API 21+, portanto disponível no piso da bancada.
     *
     * **Por que isto existe**, e não é sintonia fina: `docs/idr-que-sobrevive.md` mediu a curva
     * de sobrevivência com instrumento de UDP puro. Unidade de acesso de até 35 pacotes quebra
     * 1,00 %; de 40 pacotes para cima, 10,37 %. O mecanismo dos 10 % é **truncamento de cauda** —
     * uma fila que satura e joga fora o resto da rajada — e ele não existe abaixo do joelho. Um
     * IDR de tela real a 720x1520 tem ~60 pacotes e sai colado. O refresh intra é o único item
     * da lista de consertos que **faz o objeto grande deixar de existir** em vez de tentar
     * fazê-lo sobreviver.
     *
     * Não toca o SDP: refresh intra é macrobloco intra dentro de fatia P, e cabe inteiro em
     * Constrained Baseline 4.0 (`profile-level-id=42e028`). Nada aqui pede `fmtp` novo.
     *
     * **E o valor devolvido pela API não vale nada.** `MediaFormat.setInteger` com chave que o
     * encoder não conhece não derruba o `configure()` — ele ignora, calado. Quem diz se o botão
     * funcionou é a contagem de IDR e a distribuição de tamanho de quadro no `.h264` que saiu
     * (`tools/fatias.py`), nunca este parâmetro.
     */
    private val refreshIntraQuadros: Int = 0,
    /**
     * Chaves **de fornecedor** a pedir ao codec, `nome -> valor inteiro`. Vazio é o padrão.
     *
     * O Android **não tem chave padrão de tamanho de fatia**: `MediaFormat` não expõe nada
     * equivalente a `kVTCompressionPropertyKey_MaxH264SliceBytes` (VideoToolbox) ou a
     * `AVEncSliceControlSize` (Media Foundation). O que existe é chave de fornecedor, com nome
     * diferente por SoC (`vendor.qti-ext-enc-slice.spacing` na Qualcomm, e nada documentado na
     * MediaTek). Por isso a lista é um mapa aberto, alimentado pela bancada, e não uma chave
     * fixa neste arquivo: cada aparelho responde a um nome diferente, ou a nenhum.
     *
     * [parametrosDeFornecedor] enumera, quando a API permite, o que este codec de fato aceita.
     */
    /**
     * Modo de taxa do `MediaCodec` — `KEY_BITRATE_MODE`.
     *
     * **Existe porque o alvo não estava sendo respeitado, e a medida é de campo.** Em 08/09/2026,
     * no S24 a 1080p60, a sessão fechou com `bitrate_pedido=13500000 bitrate_obtido=16881469` —
     * **25 % acima**, confirmado pela outra ponta (152.385.509 bytes em 72,3 s = 16,86 Mbps).
     * A causa é ausência: até então nenhuma chave de modo era escrita, e o padrão do AVC é VBR,
     * que trata `KEY_BIT_RATE` como **média** e estoura em cena complexa.
     *
     * Isso não é detalhe de qualidade: a arquitetura inteira de controle de taxa deste projeto
     * (`quall_core::taxa`) baixa o **alvo** quando mede perda. Se o encoder entrega 25 % a mais
     * do que o alvo, a autoridade do controlador é diluída na mesma proporção, e toda conta de
     * "cabe no rádio" desta bancada foi feita com o número pedido em vez do entregue.
     *
     * [MODO_TAXA_AUTOMATICO] é o produto: CBR quando o encoder declara suportar, e nada escrito
     * quando não declara — nunca um modo imposto às cegas. Os outros valores existem para a
     * bancada varrer os braços **no mesmo binário**, por `Bancada.modoDeTaxa`; ver a doc de
     * [com.quall.android.core.Bancada].
     *
     * O que foi pedido e o que o codec **aceitou** vão os dois para o log depois do `configure`:
     * `setInteger` com chave não reconhecida não derruba nada, ele ignora em silêncio — e este
     * repositório já pagou por confiar no que foi escrito em vez do que foi lido de volta.
     */
    private val modoDeTaxa: Int = MODO_TAXA_AUTOMATICO,
    private val chavesDeFornecedor: Map<String, Int> = emptyMap(),
    /**
     * Período da **janela do fio**, em milissegundos. `0` desliga (o padrão, e o comportamento
     * histórico deste arquivo).
     *
     * Com N > 0 o laço de dreno emite, a cada N ms, uma linha com **bytes e quadros que saíram
     * do encoder naquela janela** e o bitrate que estava em vigor. É o instrumento que responde
     * à única pergunta que importa sobre [definirBitrate]: *o botão move o que sai?*
     *
     * Ele existe aqui, e não no chamador, porque o chamador só vê quadro; quem sabe quantos bytes
     * saíram e quando é este laço. E ele mede **bytes do encoder**, não bytes de RTP: o
     * pacotizador acrescenta cabeçalho por fragmento, então a taxa no ar é um pouco maior. O
     * número de RTP no fio vem do **receptor** (`packets_seen + packets_lost_for_real`), e os
     * dois juntos é que fecham a conta. Nenhum dos dois sozinho é "o fio".
     */
    private val janelaDoFioMs: Long = 0,
) {
    companion object {
        private const val TAG = "QuallH264Encoder"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC

        /** Decide pela capacidade do encoder: CBR se ele declarar, nada se não declarar. */
        const val MODO_TAXA_AUTOMATICO = -1

        /** Não escreve `KEY_BITRATE_MODE` nenhuma — o comportamento anterior a 08/09/2026. */
        const val MODO_TAXA_NAO_ESCREVER = -2

        /** Janela de latências mantida para os percentis quando não se coleciona tudo. */
        private const val JANELA_LATENCIA = 900 // 30 s a 30 fps

        /** Últimos IDRs lembrados para o relatório. O bitstream do receptor é a prova real. */
        private const val JANELA_IDR = 64

        /**
         * Teto de plausibilidade para `nowMicrosParaLatencia() - presentationTimeUs`.
         *
         * Existe porque medido em bancada (A07, câmera traseira, `c2.mtk.avc.encoder`): mesmo com
         * `SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME` declarado — o caso em que a Android documenta
         * que o carimbo **é** comparável a `SystemClock.elapsedRealtimeNanos()` — o delta medido
         * saiu em **~2,94 horas**, não milissegundos. `achieved_fps` no mesmo teste deu 29,8, e
         * `sem_start_code`/`idrs_com_csd_colado` saíram corretos: os quadros estavam certos, só a
         * comparação de relógios estava errada. Não investiguei a causa exata no driver — a
         * correção proporcional aqui não é "escolher o relógio certo" (já tentei, e o aparelho
         * não honra o que declara), é **nunca reportar um número implausível como se fosse
         * medida**. 2 s é generoso o bastante para nunca podar uma amostra real (nenhuma medida
         * séria de encode em hardware desta bancada passou de 300 ms) e apertado o bastante para
         * pegar discrepâncias de relógio de qualquer magnitude vistas até aqui.
         */
        private const val LATENCIA_IMPLAUSIVEL_ACIMA_DE_US = 2_000_000L
    }

    data class Result(
        val frameCount: Int,
        val encoderName: String,
        val encoderIsHardware: Boolean,
        /** Índices de quadro (0-based, só quadros de imagem) em que saiu um NAL IDR. */
        val idrFrameNumbers: List<Int>,
        /** Registros por quadro — vazio quando não se coleciona tudo. */
        val frames: List<FrameRecord>,
        /**
         * fps **obtido**, do primeiro ao último `timestamp_us` — nunca o `targetFps` pedido.
         * Existe para o relatório denunciar fila na hora: "pedi 30, obtive 67" ao lado de 251 ms
         * é o par que teria pego o defeito original antes de uma verificação separada.
         */
        val achievedFps: Double,
        val encodeLatencyP50Us: Long,
        val encodeLatencyP95Us: Long,
        /**
         * `false` quando pelo menos uma amostra de latência saiu fora de
         * [LATENCIA_IMPLAUSIVEL_ACIMA_DE_US] e foi descartada dos percentis — sinal de que
         * `presentationTimeUs` desta fonte não é comparável a [nowMicrosParaLatencia] neste
         * aparelho. `encodeLatencyP50Us`/`P95Us` continuam existindo mas não devem ser exibidos
         * como medida quando isto é `false`; ver a doc de [LATENCIA_IMPLAUSIVEL_ACIMA_DE_US].
         */
        val latenciaConfiavel: Boolean,
        /** Quadros cujo primeiro byte não era start code Annex-B. Tem de ser zero. */
        val quadrosSemStartCode: Int,
        /** IDRs que precisaram receber SPS/PPS colado na frente. */
        val idrsComParametrosColados: Int,
        /**
         * Bytes que saíram do encoder na sessão inteira, já com o SPS/PPS colado onde foi colado.
         * É o numerador do bitrate **obtido**; o pedido está em [bitrateFinalBps].
         */
        val bytesDeSaida: Long,
        /** Último bitrate que foi ao codec. Igual ao do `configure()` quando ninguém mexeu. */
        val bitrateFinalBps: Int,
        /** Quantas vezes `PARAMETER_KEY_VIDEO_BITRATE` foi chamado. Zero em produto. */
        val trocasDeBitrate: Int,
    )

    private lateinit var codec: MediaCodec
    private lateinit var inputSurface: Surface

    /** Uma thread só para os callbacks da fonte (VirtualDisplay ou CameraX) desta captura. */
    private lateinit var fonteThread: HandlerThread

    protected lateinit var fonteHandler: Handler
        private set

    protected val fonteExecutor: Executor
        get() = Executor { fonteHandler.post(it) }

    @Volatile private var stopRequested = false

    /** Pedido do receptor ainda não confirmado no bitstream. Ver a doc da classe. */
    @Volatile private var idrDevido = false

    /** Já repassamos [idrDevido] ao codec via `setParameters`? Evita chamar de novo a cada volta. */
    @Volatile private var idrJaSolicitadoAoCodec = false

    /**
     * Bitrate **pedido**, em bits por segundo. Escrito por [definirBitrate] de qualquer thread,
     * lido pelo laço de dreno.
     *
     * Começa em [bitrateBps] — o valor que foi para o `configure()` — para que a primeira volta
     * do laço não chame `setParameters` sem necessidade.
     */
    @Volatile private var bitratePedidoBps: Int = bitrateBps

    /** Último valor que de fato foi ao codec. Diferente de [bitratePedidoBps] quer dizer "aplicar". */
    private var bitrateAplicadoBps: Int = bitrateBps

    /** Quantas vezes `setParameters(PARAMETER_KEY_VIDEO_BITRATE)` foi chamado nesta sessão. */
    private var trocasDeBitrate = 0

    /** Bytes de saída acumulados na janela do fio corrente. Ver [janelaDoFioMs]. */
    private var bytesDaJanela = 0L
    private var quadrosDaJanela = 0
    private var fimDaJanela = 0L

    /** Bytes de saída da sessão inteira — o denominador do bitrate médio obtido. */
    private var bytesDeSaida = 0L

    /** SPS/PPS válidos para a sessão inteira. Vive até o encoder mandar um `csd` novo. */
    private var csd: ByteArray? = null
    private var csdEmMontagem: ByteArray? = null

    /** Buffer direto reaproveitado para os quadros que precisam de SPS/PPS colado na frente. */
    private var scratch: ByteBuffer? = null

    private val frames = ArrayList<FrameRecord>()
    private val latencias = ArrayDeque<Long>()
    private val idrFrameNumbers = ArrayDeque<Int>()
    private var frameNumber = 0
    private var idrTotal = 0
    private var primeiroTimestampUs = -1L
    private var ultimoTimestampUs = -1L
    private var quadrosSemStartCode = 0
    private var idrsComParametrosColados = 0

    /** `false` assim que uma amostra sair de [LATENCIA_IMPLAUSIVEL_ACIMA_DE_US]. Ver [Result]. */
    @Volatile private var latenciaConfiavel = latenciaComparavel

    /**
     * Corrigir o relógio do `presentationTimeUs` para `MONOTONIC` pelo [RelogioDoPts]. Produto:
     * ligado. `false` só na bancada (`prova_pts_cru`), para o controle da prova do §19.4 — e mesmo
     * assim a classe e o `m` são medidos e vão para o diário. Lido em [run]; escrever antes dele.
     */
    @Volatile var corrigirRelogioDoPts: Boolean = true

    /**
     * **O relógio do carimbo do vídeo, medido no primeiro quadro** (`docs/som-no-receptor.md`
     * §19.4). O som sai em `MONOTONIC`; o PTS da câmera sai no relógio que o aparelho quiser. Ver
     * [RelogioDoPts].
     */
    private var relogioDoPts = RelogioDoPts()

    /** A linha do [RelogioDoPts] desta captura, para o diário da sessão. */
    fun relogioDoPtsLinha(): String = relogioDoPts.linha()

    /**
     * Prepara e inicia a fonte de quadros sobre [inputSurface]. Chamada depois de `codec.start()`,
     * na mesma thread que chamou [run] — implementações que precisem de `Looper` usam
     * [fonteHandler]/[fonteExecutor], já preparados nesta altura.
     */
    protected abstract fun iniciarFonte(inputSurface: Surface)

    /**
     * Encerra a fonte de quadros. Chamada pelo menos uma vez, antes de
     * `codec.signalEndOfInputStream()` — pode ser chamada de novo na limpeza final; precisa ser
     * idempotente.
     */
    protected abstract fun pararFonte()

    /**
     * "Agora", no mesmo domínio de relógio que o `presentationTimeUs` que esta fonte carimba nos
     * buffers de entrada — é o que torna `nowMicrosParaLatencia() - presentationTimeUs` uma
     * latência de verdade, e não a diferença entre dois relógios que não têm relação.
     *
     * O padrão ([MonotonicClock], `System.nanoTime()`/`CLOCK_MONOTONIC`) é certo para
     * [H264ScreenEncoder]: é o mesmo domínio que o `BufferQueue` da `VirtualDisplay` usa
     * (`systemTime(CLOCK_MONOTONIC)` do lado nativo). **Não é** necessariamente certo para
     * câmera — ver a doc de [CameraXSource] — e [H264CameraEncoder] sobrescreve quando precisa.
     */
    protected open fun nowMicrosParaLatencia(): Long = MonotonicClock.micros()

    /**
     * Um quadro saiu do codificador com este carimbo **cru** (o da fonte, antes do [RelogioDoPts]).
     * Na thread de dreno. O [H264DivisorEncoder] conta com isto os quadros em trânsito
     * ([FilaDoCodificador], `docs/teleprompter-com-camera.md` §14.11).
     */
    protected open fun aoSairQuadro(ptsCruUs: Long) {}

    // O relato de 5 s da saída (§14.11, a revisão, 3): a idade do quadro na saída (o `m` por quadro:
    // `MONOTONIC` de agora − o carimbo já no relógio do som) e o tempo do `aoQuadro` (o envio ao
    // núcleo, na thread de dreno). Só da thread de dreno.
    private val idadesNaSaida = ArrayList<Long>(200)
    private val enviosNaJanela = ArrayList<Long>(200)
    private var fimDoRelatoDaSaida = 0L

    /**
     * A fonte **declara** que o PTS é `BOOTTIME` (a câmera com `SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME`).
     * Só desempata a zona ambígua do [RelogioDoPts] (o aparelho que quase não dormiu), onde a medida
     * não distingue os dois relógios e o microfone junto da câmera não aceita o erro. A tela: `false`.
     */
    protected open val ptsDeclaradoBoottime: Boolean get() = false

    /**
     * O padrão de cor declarado ao codec (`KEY_COLOR_STANDARD`). BT.709 para a tela e as câmeras
     * do aparelho; a filmadora DV é BT.601 (`H264DvEncoder`). Lido só em [buildFormat], dentro de
     * [run], quando a subclasse já está inteira.
     */
    protected open val padraoDeCor: Int = MediaFormat.COLOR_STANDARD_BT709

    /**
     * Pedir ao codec que descarte na entrada o que passar de [targetFps]
     * (`KEY_MAX_FPS_TO_ENCODER`). A DV já chega a 29,97 e não liga: com a folga de ~2 ms do
     * descarte, o carimbo do USB (que anda de 4 em 4 ms) derrubaria quadro bom.
     */
    protected open val limitarFpsNaEntrada: Boolean = true

    /**
     * Roda a captura, bloqueando a thread chamadora (espera-se uma thread de fundo).
     *
     * `durationMs <= 0` significa **até [stop]** — o caso do espelhamento, que não tem prazo. A
     * contagem usa [SystemClock.elapsedRealtime], monotônico.
     */
    fun run(durationMs: Long): Result {
        // **O codec nasce antes do formato**, e não depois. Até 08/09/2026 a ordem era a
        // inversa, e por isso `buildFormat` não tinha como perguntar nada ao encoder — decidir
        // modo de taxa exige saber o que este encoder declara suportar.
        relogioDoPts = RelogioDoPts(corrigir = corrigirRelogioDoPts, declaradoBoottime = ptsDeclaradoBoottime)
        codec = MediaCodec.createEncoderByType(MIME)
        val codecInfo: MediaCodecInfo = codec.codecInfo
        val encoderName = codecInfo.name
        val encoderIsHardware = codecInfo.aceleradoPorHardware
        val format = buildFormat(codecInfo)

        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        // **O que o codec aceitou, e não o que nós pedimos.** `setInteger` com chave que o
        // encoder não reconhece é ignorado em silêncio; `getInputFormat()` depois do `configure`
        // é a única testemunha do que de fato valeu.
        val aceito = runCatching { codec.inputFormat }.getOrNull()
        Log.i(TAG, "encoder=$encoderName hw=$encoderIsHardware " +
            "modo_de_taxa pedido=${format.pedidoDeModo()} aceito=${aceito.leInt(MediaFormat.KEY_BITRATE_MODE)} " +
            "bitrate pedido=$bitrateBps aceito=${aceito.leInt(MediaFormat.KEY_BIT_RATE)} " +
            "fps pedido=$targetFps aceito=${aceito.leInt(MediaFormat.KEY_FRAME_RATE)}")
        registrarBotoes()
        inputSurface = codec.createInputSurface()
        codec.start()

        // Achado no A10s (Android 11): registrar callback/criar superfície com handler `null`
        // tenta usar o Looper da thread chamadora, e a thread de captura não tem um. Uma
        // HandlerThread própria resolve nos dois produtores (VirtualDisplay e CameraX).
        fonteThread = HandlerThread("quall-encoder-fonte").also { it.start() }
        fonteHandler = Handler(fonteThread.looper)

        val bufferInfo = MediaCodec.BufferInfo()
        val semPrazo = durationMs <= 0
        val prazo = if (semPrazo) Long.MAX_VALUE else SystemClock.elapsedRealtime() + durationMs
        var sawEos = false
        var eosSignaled = false

        try {
            // **Dentro do `try`** (a revisão da tela R5, M2): uma fonte que falha ao iniciar tem de
            // soltar o codec, a thread da fonte e o sink pelo mesmo `finally` de sempre. Fora dele,
            // a exceção vazava os três.
            iniciarFonte(inputSurface)

            while (!sawEos) {
                // O pedido de IDR do receptor é lido a cada volta, e não só quando um quadro sai:
                // com a fonte parada podem passar centenas de milissegundos sem quadro nenhum, e o
                // receptor estaria sem imagem esse tempo todo. `dequeueOutputBuffer` abaixo tem
                // 10 ms de prazo, então esta leitura acontece pelo menos a cada 10 ms.
                if (sink.querIdr()) {
                    idrDevido = true
                    idrJaSolicitadoAoCodec = false
                }

                val expirou = !semPrazo && SystemClock.elapsedRealtime() >= prazo
                if (!eosSignaled && (stopRequested || expirou || sink.desistiu())) {
                    // Para de alimentar o encoder e sinaliza fim de fluxo; o dreno continua até
                    // ver END_OF_STREAM, para não perder os últimos quadros já em trânsito.
                    pararFonte()
                    codec.signalEndOfInputStream()
                    eosSignaled = true
                }

                if (idrDevido && !idrJaSolicitadoAoCodec) {
                    val params = Bundle()
                    params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                    codec.setParameters(params)
                    idrJaSolicitadoAoCodec = true
                    Log.i(TAG, "IDR pedido via PARAMETER_KEY_REQUEST_SYNC_FRAME em frame=$frameNumber")
                }

                // O bitrate novo entra aqui, na mesma thread e no mesmo ponto do pedido de IDR.
                // Ver [definirBitrate].
                val pedido = bitratePedidoBps
                if (pedido != bitrateAplicadoBps) {
                    val params = Bundle()
                    params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, pedido)
                    codec.setParameters(params)
                    Log.i(
                        TAG,
                        "bitrate: $bitrateAplicadoBps -> $pedido bps via " +
                            "PARAMETER_KEY_VIDEO_BITRATE em frame=$frameNumber " +
                            "(o retorno não é prova; a prova é a janela do fio)",
                    )
                    bitrateAplicadoBps = pedido
                    trocasDeBitrate++
                }

                if (janelaDoFioMs > 0) {
                    val agora = SystemClock.elapsedRealtime()
                    if (fimDaJanela == 0L) {
                        fimDaJanela = agora + janelaDoFioMs
                    } else if (agora >= fimDaJanela) {
                        // A janela real, e não a nominal: o laço acorda a cada ~10 ms, então a
                        // janela fechada tem `janelaDoFioMs` mais um resto. Dividir pelo nominal
                        // daria um bitrate sistematicamente alto — a mesma família de erro do
                        // denominador que custou uma conclusão invertida em 31/08/2026.
                        val duracao = janelaDoFioMs + (agora - fimDaJanela)
                        val kbps = bytesDaJanela * 8.0 / duracao
                        Log.i(
                            TAG,
                            "janela_do_fio ms=$duracao bytes=$bytesDaJanela " +
                                "quadros=$quadrosDaJanela kbps=${"%.1f".format(kbps)} " +
                                "bitrate_pedido=$bitrateAplicadoBps",
                        )
                        bytesDaJanela = 0L
                        quadrosDaJanela = 0
                        fimDaJanela = agora + janelaDoFioMs
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000L)
                when {
                    outIndex >= 0 -> {
                        drainOne(outIndex, bufferInfo)
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            sawEos = true
                        }
                    }
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        Log.i(TAG, "formato de saída: ${codec.outputFormat}")
                    }
                    // INFO_TRY_AGAIN_LATER: nada a fazer, volta ao topo do laço.
                }
            }
        } finally {
            runCatching { pararFonte() }
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { sink.fechar() }
            runCatching { fonteThread.quitSafely() }
        }

        val achievedFps = if (frameNumber >= 2 && ultimoTimestampUs > primeiroTimestampUs) {
            (frameNumber - 1) * 1_000_000.0 / (ultimoTimestampUs - primeiroTimestampUs)
        } else 0.0
        val ordenadas = latencias.sorted()
        val p50 = percentile(ordenadas, 0.50)
        val p95 = percentile(ordenadas, 0.95)
        Log.i(
            TAG,
            "preset=${preset.json} target_fps=$targetFps achieved_fps=${"%.1f".format(achievedFps)} " +
                "encode_latency_us p50=$p50 p95=$p95 confiavel=$latenciaConfiavel (frames=$frameNumber " +
                "sem_start_code=$quadrosSemStartCode idr_com_csd_colado=$idrsComParametrosColados) " +
                relogioDoPts.linha(),
        )

        return Result(
            frameCount = frameNumber,
            encoderName = encoderName,
            encoderIsHardware = encoderIsHardware,
            idrFrameNumbers = idrFrameNumbers.toList(),
            frames = frames,
            achievedFps = achievedFps,
            encodeLatencyP50Us = p50,
            encodeLatencyP95Us = p95,
            latenciaConfiavel = latenciaConfiavel,
            quadrosSemStartCode = quadrosSemStartCode,
            idrsComParametrosColados = idrsComParametrosColados,
            bytesDeSaida = bytesDeSaida,
            bitrateFinalBps = bitrateAplicadoBps,
            trocasDeBitrate = trocasDeBitrate,
        )
    }

    /**
     * Fotografia dos contadores enquanto a captura roda, para a tela mostrar **taxa obtida ao
     * lado da latência** o tempo todo, e não só no relatório final. Foi a ausência desse par que
     * escondeu, por uma rodada inteira, a fila que multiplicou a latência do A07 por nove.
     */
    data class Instantaneo(
        val quadros: Int,
        val fpsObtido: Double,
        val p50Us: Long,
        val p95Us: Long,
        /** Ver [Result.latenciaConfiavel]. */
        val latenciaConfiavel: Boolean,
        val idrs: Int,
    )

    private val estatLock = Any()

    fun instantaneo(): Instantaneo = synchronized(estatLock) {
        val fps = if (frameNumber >= 2 && ultimoTimestampUs > primeiroTimestampUs) {
            (frameNumber - 1) * 1_000_000.0 / (ultimoTimestampUs - primeiroTimestampUs)
        } else 0.0
        val ordenadas = latencias.sorted()
        Instantaneo(
            quadros = frameNumber,
            fpsObtido = fps,
            p50Us = percentile(ordenadas, 0.50),
            p95Us = percentile(ordenadas, 0.95),
            latenciaConfiavel = latenciaConfiavel,
            idrs = idrTotal,
        )
    }

    private fun percentile(sortedValues: List<Long>, p: Double): Long {
        if (sortedValues.isEmpty()) return 0L
        val idx = (p * (sortedValues.size - 1)).toInt().coerceIn(0, sortedValues.size - 1)
        return sortedValues[idx]
    }

    /** Pede um IDR fora do ciclo normal do GOP. Chamada de qualquer thread. */
    fun requestSyncFrame() {
        idrDevido = true
        idrJaSolicitadoAoCodec = false
    }

    fun stop() {
        stopRequested = true
    }

    /**
     * Pede um bitrate novo ao codec **em voo**, sem recriar nada. Pode ser chamada de qualquer
     * thread; quem aplica é o laço de dreno, no mesmo ponto em que aplica o pedido de IDR.
     *
     * # Por que o pedido não é aplicado aqui
     *
     * `MediaCodec.setParameters` não é documentado como seguro para chamada concorrente com o
     * laço de `dequeueOutputBuffer`, e este arquivo já tinha resolvido o mesmo problema para o
     * pedido de IDR: quem toca no codec é uma thread só. O preço é latência de até uma volta do
     * laço — **10 ms**, o prazo do `dequeueOutputBuffer` — e isso é rápido o bastante para
     * qualquer política de taxa: a rajada mais curta que esta bancada mede dura centenas de ms.
     *
     * # E o retorno não vale nada
     *
     * `setParameters` não devolve se o codec honrou. Esta bancada já viu **seis** vezes uma API
     * de codec aceitar e não fazer, e uma vez honrar como outra coisa (`KEY_INTRA_REFRESH_PERIOD`
     * virando período de quadro-chave no A10s, 31/08/2026). Quem diz se o botão funcionou é
     * [janelaDoFioMs] — bytes por segundo saindo do encoder — e o `packets_seen` do receptor.
     * Nunca esta chamada.
     */
    fun definirBitrate(bps: Int) {
        bitratePedidoBps = bps.coerceAtLeast(1)
    }

    /** O que [definirBitrate] pediu por último. Não é o que o codec está fazendo. */
    fun bitratePedido(): Int = bitratePedidoBps

    private fun drainOne(index: Int, info: MediaCodec.BufferInfo) {
        val nowMicros = nowMicrosParaLatencia()
        // As duas horas do [RelogioDoPts], lidas juntas e no mesmo ponto em que a latência é lida.
        val monotonicUs = MonotonicClock.micros()
        val boottimeUs = SystemClock.elapsedRealtimeNanos() / 1000L
        val buf = codec.getOutputBuffer(index)
        if (buf == null || info.size <= 0) {
            codec.releaseOutputBuffer(index, false)
            return
        }

        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
            // SPS/PPS. Não é quadro no sentido do contrato (`ffprobe -count_frames` não conta
            // parâmetro). Fica guardado para valer pela sessão inteira, não só para o próximo IDR.
            val bytes = ByteArray(info.size)
            fatiar(buf, info.offset, info.size).get(bytes)
            csdEmMontagem = csdEmMontagem?.plus(bytes) ?: bytes
            codec.releaseOutputBuffer(index, false)
            return
        }

        csdEmMontagem?.let {
            csd = it
            csdEmMontagem = null
            Log.i(TAG, "csd (SPS/PPS) de ${it.size} bytes guardado para toda a sessão")
        }

        val tipos = AnnexB.nalTypes(buf, info.offset, info.size)
        val nalIdr = tipos.contains(AnnexB.NAL_IDR)
        val temParametros = tipos.contains(AnnexB.NAL_SPS)
        val flagKeyFrame = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        if (flagKeyFrame != nalIdr) {
            // Exatamente o tipo de divergência que enganou o Windows no M1: o retorno da API
            // dizendo uma coisa e o bitstream dizendo outra. Registrado, não escondido — e a
            // fonte de verdade é o bitstream.
            Log.w(TAG, "frame=$frameNumber: BUFFER_FLAG_KEY_FRAME=$flagKeyFrame mas NAL IDR=$nalIdr")
        }

        if (nalIdr && idrDevido) {
            // Confirmado no bitstream, não no retorno de `setParameters`: só agora o pedido do
            // receptor está de fato atendido. Ver a doc da classe.
            idrDevido = false
            idrJaSolicitadoAoCodec = false
            Log.i(TAG, "IDR devido confirmado no bitstream em frame=$frameNumber")
        }

        val prefixo = if (nalIdr && !temParametros) csd else null
        val (saida, deslocamento, tamanho) = if (prefixo != null) {
            idrsComParametrosColados++
            (montarComPrefixo(prefixo, buf, info.offset, info.size))
        } else if (buf.isDirect) {
            Triple(buf, info.offset, info.size)
        } else {
            // Nenhum encoder da bancada cai aqui (buffer de `MediaCodec` é direto), mas o caminho
            // do JNI exige buffer direto e falhar por isso em campo seria absurdo.
            montarComPrefixo(ByteArray(0), buf, info.offset, info.size)
        }

        if (!AnnexB.comecaComStartCode(saida, deslocamento, tamanho)) {
            quadrosSemStartCode++
            if (quadrosSemStartCode <= 3) {
                Log.e(
                    TAG,
                    "frame=$frameNumber não começa com start code Annex-B " +
                        "(offset=$deslocamento size=$tamanho) — deslocamento errado?",
                )
            }
        }

        // O tamanho contado é o que **vai para a track**, com o SPS/PPS colado quando foi colado:
        // é esse o objeto que o pacotizador fragmenta. Contar `info.size` deixaria de fora os
        // bytes de parâmetro que atravessam o ar em todo IDR.
        bytesDaJanela += tamanho
        bytesDeSaida += tamanho
        quadrosDaJanela++

        // **O carimbo que vai para a track é o PTS no relógio do som** (`MONOTONIC`), e não o PTS
        // cru: ver [RelogioDoPts]. A latência e o fps logo abaixo continuam sobre o PTS cru, que é
        // o que eles sempre mediram.
        val primeiro = relogioDoPts.classe == null
        val carimboUs = relogioDoPts.quadro(info.presentationTimeUs, monotonicUs, boottimeUs)
        if (primeiro) Log.i(TAG, "primeiro quadro: ${relogioDoPts.linha()}")
        val antesDoEnvio = System.nanoTime()
        sink.aoQuadro(saida, deslocamento, tamanho, carimboUs, nalIdr)
        enviosNaJanela.add(System.nanoTime() - antesDoEnvio)
        idadesNaSaida.add(monotonicUs - carimboUs)
        codec.releaseOutputBuffer(index, false)
        aoSairQuadro(info.presentationTimeUs)
        relatarSaida()

        // `deltaUs` cru é o que vai para o registro do sidecar (`encode_latency_us` do contrato:
        // é campo obrigatório, e o formato não tem como marcar "não confiável" — quem lê o .json
        // sabe interpretar). Para os percentis que viram número no relatório humano, uma amostra
        // conta como plausível só se a fonte **declara** relógio comparável (latenciaComparavel)
        // **e** o delta cai dentro de LATENCIA_IMPLAUSIVEL_ACIMA_DE_US — nenhum dos dois sozinho
        // basta (ver a doc do parâmetro do construtor).
        val deltaUs = nowMicros - info.presentationTimeUs
        val encodeLatencyUs = deltaUs.coerceAtLeast(0)
        val amostraPlausivel = latenciaComparavel && deltaUs in 0..LATENCIA_IMPLAUSIVEL_ACIMA_DE_US
        synchronized(estatLock) {
            if (primeiroTimestampUs < 0) primeiroTimestampUs = info.presentationTimeUs
            ultimoTimestampUs = info.presentationTimeUs

            if (colecionarQuadros) {
                frames.add(
                    FrameRecord(
                        number = frameNumber,
                        timestampUs = info.presentationTimeUs,
                        bytes = tamanho,
                        idr = nalIdr,
                        encodeLatencyUs = encodeLatencyUs,
                    )
                )
            }
            if (amostraPlausivel) {
                latencias.addLast(encodeLatencyUs)
                if (!colecionarQuadros && latencias.size > JANELA_LATENCIA) latencias.removeFirst()
            } else {
                if (latenciaConfiavel) {
                    Log.w(
                        TAG,
                        "encode_latency_us implausível (${deltaUs}us) em frame=$frameNumber — " +
                            "presentationTimeUs desta fonte não parece comparável a " +
                            "nowMicrosParaLatencia() neste aparelho; latência deixa de ser reportada",
                    )
                }
                latenciaConfiavel = false
            }
            if (nalIdr) {
                idrTotal++
                idrFrameNumbers.addLast(frameNumber)
                if (idrFrameNumbers.size > JANELA_IDR) idrFrameNumbers.removeFirst()
            }
            frameNumber++
        }
    }

    /** Copia `prefixo` + a fatia do buffer para o [scratch] direto, que é reaproveitado. */
    private fun montarComPrefixo(
        prefixo: ByteArray,
        buf: ByteBuffer,
        offset: Int,
        size: Int,
    ): Triple<ByteBuffer, Int, Int> {
        val total = prefixo.size + size
        var alvo = scratch
        if (alvo == null || alvo.capacity() < total) {
            // Cresce em dobro para não realocar a cada quadro grande; o IDR é o maior quadro e a
            // resolução não muda no meio da sessão, então isto estabiliza na primeira volta.
            val novo = ByteBuffer.allocateDirect(maxOf(total, (alvo?.capacity() ?: 0) * 2, 256 * 1024))
            scratch = novo
            alvo = novo
        }
        (alvo as Buffer).clear()
        if (prefixo.isNotEmpty()) alvo.put(prefixo)
        alvo.put(fatiar(buf, offset, size))
        return Triple(alvo, 0, total)
    }

    /** Lê uma chave inteira de um formato que pode ser nulo, sem lançar. `null` = ausente. */
    private fun MediaFormat?.leInt(chave: String): String =
        this?.let { f -> runCatching { f.getInteger(chave) }.getOrNull()?.toString() } ?: "ausente"

    /** O que este formato pediu de modo de taxa, para o log. */
    private fun MediaFormat.pedidoDeModo(): String =
        runCatching { getInteger(MediaFormat.KEY_BITRATE_MODE) }.getOrNull()?.toString() ?: "nao_escrito"

    /**
     * Escreve `KEY_BITRATE_MODE`, **perguntando antes se este encoder o suporta**.
     *
     * `MediaCodecInfo.EncoderCapabilities.isBitrateModeSupported` é a única fonte: impor um modo
     * que o encoder não declara é escrever uma chave que ele ignora, e o log sairia dizendo que
     * pediu CBR num aparelho que segue em VBR. Quando não há suporte, **nada é escrito** e o
     * comportamento é o de antes — degradar em silêncio para o padrão é melhor que mentir.
     */
    private fun aplicarModoDeTaxa(format: MediaFormat, codecInfo: MediaCodecInfo) {
        if (modoDeTaxa == MODO_TAXA_NAO_ESCREVER) return
        val caps = runCatching {
            codecInfo.getCapabilitiesForType(MIME).encoderCapabilities
        }.getOrNull()
        if (caps == null) {
            Log.w(TAG, "encoder não expôs EncoderCapabilities — modo de taxa não escrito")
            return
        }
        val desejado = if (modoDeTaxa == MODO_TAXA_AUTOMATICO) {
            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
        } else {
            modoDeTaxa
        }
        if (caps.isBitrateModeSupported(desejado)) {
            format.setInteger(MediaFormat.KEY_BITRATE_MODE, desejado)
        } else {
            Log.w(TAG, "encoder não suporta modo de taxa $desejado — nada escrito, segue no padrão")
        }
    }

    /** A cada 5 s: a idade na saída e o envio, p50/máx. */
    private fun relatarSaida() {
        val agora = SystemClock.elapsedRealtime()
        if (fimDoRelatoDaSaida == 0L) { fimDoRelatoDaSaida = agora + 5_000; return }
        if (agora < fimDoRelatoDaSaida) return
        fimDoRelatoDaSaida = agora + 5_000
        idadesNaSaida.sort()
        enviosNaJanela.sort()
        fun ms(v: Long, div: Double) = String.format(java.util.Locale.ROOT, "%.1f", v / div)
        if (idadesNaSaida.isNotEmpty()) {
            Log.i(TAG, "saída 5 s: quadros=${idadesNaSaida.size} " +
                "idade_na_saida_ms p50/max=${ms(idadesNaSaida[idadesNaSaida.size / 2], 1e3)}/${ms(idadesNaSaida.last(), 1e3)} " +
                "envio_ms p50/max=${ms(enviosNaJanela[enviosNaJanela.size / 2], 1e6)}/${ms(enviosNaJanela.last(), 1e6)} " +
                "(relogio ${relogioDoPts.classe ?: "-"})")
        }
        idadesNaSaida.clear()
        enviosNaJanela.clear()
    }

    private fun buildFormat(codecInfo: MediaCodecInfo): MediaFormat {
        val format = MediaFormat.createVideoFormat(MIME, width, height)
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, targetFps)
        aplicarModoDeTaxa(format, codecInfo)
        format.setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, gopSeconds)
        format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
        // Faixa de cor limitada: decisão de contrato-sidecar.md, para os dois presets. `setInteger`
        // com chave que o encoder não reconhece não derruba o `configure()` — ele ignora. Por isso
        // o header do sidecar declara o que foi *pedido*; o que saiu, só o ffprobe confirma.
        format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
        format.setInteger(MediaFormat.KEY_COLOR_STANDARD, padraoDeCor)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            // "Sem filas": menor número de buffers em trânsito. Chave a partir da API 30, que por
            // coincidência é o piso da bancada (A10s).
            format.setInteger(MediaFormat.KEY_LATENCY, 1)
        }
        // Descarta na fonte da superfície de entrada (nativo, sem cópia) o excesso que o produtor
        // entrega acima da taxa pedida. Ver o comentário da classe.
        if (limitarFpsNaEntrada) format.setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, targetFps.toFloat())
        if (refreshIntraQuadros > 0) {
            // API 21+. Ver a doc do parâmetro: quem confirma é `tools/fatias.py` no `.h264`.
            format.setInteger(MediaFormat.KEY_INTRA_REFRESH_PERIOD, refreshIntraQuadros)
        }
        for ((chave, valor) in chavesDeFornecedor) {
            format.setInteger(chave, valor)
        }
        return format
    }

    /**
     * Nomes dos parâmetros de fornecedor que **este** codec declara aceitar, ou `null` quando a
     * plataforma não sabe responder.
     *
     * `MediaCodec.getSupportedVendorParameters` só existe da API 31 em diante. O A10s é API 30,
     * o piso da bancada: lá a resposta é `null`, e "não sei" é o que se registra — não "não
     * tem". Confundir os dois é como se conclui que um botão não existe porque ninguém achou o
     * interruptor.
     */
    private fun parametrosDeFornecedor(): List<String>? =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            runCatching { codec.getSupportedVendorParameters() }.getOrNull()
        } else {
            null
        }

    /**
     * Registra, uma vez por sessão, o que foi **pedido** e o que o codec **devolveu** no formato
     * de entrada — que é o mais perto de uma confirmação que a API oferece, e ainda assim não é
     * prova (ver `docs/regras-de-frente.md`, "Verifique no fluxo, não no retorno da API").
     */
    private fun registrarBotoes() {
        val fornecedor = parametrosDeFornecedor()
        val relacionados = fornecedor?.filter {
            val n = it.lowercase()
            "slice" in n || "refresh" in n || "intra" in n || "ltr" in n
        }
        Log.i(
            TAG,
            "botões pedidos: refresh_intra_quadros=$refreshIntraQuadros " +
                "fornecedor=$chavesDeFornecedor · " +
                "parâmetros de fornecedor deste codec: " +
                (if (fornecedor == null) "não sei (API < 31)"
                 else "${fornecedor.size} no total, relacionados a fatia/refresh: $relacionados"),
        )
        // A lista inteira, uma vez por sessão. Nome de chave de fornecedor não está documentado
        // em lugar nenhum: a única fonte é o próprio codec, e uma chave que não existe é
        // silenciosamente ignorada — o modo de falha que este projeto já viu cinco vezes.
        fornecedor?.chunked(8)?.forEachIndexed { i, bloco ->
            Log.i(TAG, "fornecedor[$i]: ${bloco.joinToString(" ")}")
        }
        val entrada = runCatching { codec.inputFormat }.getOrNull()
        val eco = buildString {
            append("intra-refresh-period=")
            append(
                if (entrada != null && entrada.containsKey(MediaFormat.KEY_INTRA_REFRESH_PERIOD))
                    entrada.getInteger(MediaFormat.KEY_INTRA_REFRESH_PERIOD).toString()
                else "ausente",
            )
            for (chave in chavesDeFornecedor.keys) {
                append(" · ").append(chave).append('=')
                append(
                    if (entrada != null && entrada.containsKey(chave))
                        entrada.getInteger(chave).toString()
                    else "ausente",
                )
            }
        }
        Log.i(TAG, "eco do codec no formato de entrada: $eco (o bitstream é a prova, não isto)")
    }
}
