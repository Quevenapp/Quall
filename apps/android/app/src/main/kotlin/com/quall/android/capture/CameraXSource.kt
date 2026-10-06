package com.quall.android.capture

import androidx.camera.video.VideoOutput
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import com.quall.android.core.LogSeguro as Log
import android.util.Size
import android.view.Surface
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.MirrorMode
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.VideoCapture
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executor

/**
 * Liga o CameraX a um id de câmera Camera2 concreto e entrega a resolução que a câmera decidiu,
 * **antes** de qualquer `MediaCodec` existir — é o que permite a [H264CameraEncoder] construir o
 * encoder já com a resolução certa, do mesmo jeito que [H264ScreenEncoder] recebe a resolução da
 * tela já resolvida pela Activity (`windowManager.currentWindowMetrics`).
 *
 * ## Por que a resolução vem da câmera, e não o contrário
 *
 * O *use case* negocia a resolução com o `CameraSelector` e só a revela quando entrega um
 * [SurfaceRequest]. Forçar uma resolução fixa de antemão arriscaria descasar do que a câmera
 * realmente entrega — e como a superfície de um `MediaCodec` tem tamanho fixo desde a criação, um
 * descasamento sairia como imagem distorcida ou cortada, não como erro. [ligarCodificador]
 * bloqueia até esse pedido chegar, lê [SurfaceRequest.getResolution] e só então devolve — a
 * chamadora cria o `MediaCodec` com esse tamanho e chama [prover].
 *
 * ## Duas fases, e por que passaram a ser duas
 *
 * Até 03/09 havia uma função só: abrir a câmera **e** pegar a superfície do codificador no mesmo
 * gesto. Isso amarrava a câmera à sessão — e como a sessão só existe depois de alguém parear, quem
 * ia transmitir a câmera **não via nada** até o receptor conectar. No iOS não é assim: a
 * `AVCaptureSession` da `TelaDaCamera` roda independente da sessão do Quall, e a pessoa acerta o
 * enquadramento **enquanto espera**. Este arquivo passou a ter o mesmo desenho:
 *
 *  1. [abrirComPrevia] binda **só** o `Preview`. A câmera abre, a `PreviewView` recebe imagem, e
 *     nenhum `MediaCodec` existe ainda. É o que a fase de espera usa.
 *  2. [ligarCodificador] põe o `VideoCapture` no ar e devolve a resolução negociada. É o que o
 *     pareamento chama. Como ele faz isso é decidido por bancada e o padrão é `rebind_junto` —
 *     desbindar os dois e subir os dois num `bindToLifecycle` só. Ver a doc de [ligarCodificador]:
 *     a alternativa (acrescentar sem `unbindAll`) parecia mais barata e mediu pior nos dois eixos.
 *
 * A ordem não é gosto: o `androidx.camera.camera2.internal.CaptureSession` dá 5 s
 * (`TIMEOUT_GET_SURFACE_IN_MS`, lido no bytecode de camera-camera2-1.4.2) para o `SurfaceRequest`
 * de um use case bindado receber `provideSurface`. Bindar o `VideoCapture` já na espera obrigaria
 * a criar e iniciar o `MediaCodec` na espera, e a câmera passaria a escrever 1080p30 numa entrada
 * de codificador que ninguém drena, por até cinco minutos, em aparelho de bateria.
 *
 * O que muda no pareamento é decidido por bancada, e **o padrão fecha e reabre a câmera**. Este
 * parágrafo dizia, até 04/09, que acrescentar o use case pagava "só" uma reconfiguração de
 * `CaptureSession` com o `CameraDevice` em OPENED, e vendia isso como o caminho barato. Medido,
 * ele é o caro: ver a doc de [ligarCodificador].
 *
 * [abrir] continua existindo, com uma fase só, e é o caminho do instrumento de bancada
 * ([CameraCaptureService]): um use case, `unbindAll` na entrada, sem prévia. Ele não pode mudar —
 * um segundo fluxo saindo da mesma câmera mudaria o que ele mede.
 *
 * ## Quem ocupa qual superfície, e por que trocou em 03/09
 *
 * Até 03/09 o codificador era alimentado pelo *use case* `Preview`, e a prévia da tela vinha por
 * fora, de um `ImageAnalysis` convertido a `Bitmap` na CPU a ~8 quadros/s. `docs/bancada.md` §8.17
 * mediu que aquilo **não** custava quadro ao codificador — mas a ~8 quadros/s a prévia anda em
 * trancos, e comparada com o DroidCam e com o iOS na mão do usuário, em trancos não serve.
 *
 * A raiz era que `Preview` tem **uma** superfície e ela estava tomada. Agora os papéis estão
 * invertidos:
 *
 *  - **[VideoCapture] alimenta o codificador.** O `VideoOutput` é nosso e tem quinze linhas
 *    ([SaidaDeVideoParaCodificador]): ele só repassa o `SurfaceRequest` para a fila abaixo. Não há
 *    `Recorder`, não há muxer, não há segundo codificador — o `SurfaceRequest` que chega tem a
 *    mesma API pública (`getResolution()`, `provideSurface()`) que o do `Preview` entregava, e por
 *    isso [H264CameraEncoder] quase não mudou.
 *  - **`Preview` alimenta a tela**, por uma `PreviewView` (ver [PreviaDaCamera]). Em modo
 *    PERFORMANCE ela é `SurfaceView`, ou seja **caminho de compositor em hardware** — a mesma
 *    classe de caminho que faz a `AVCaptureVideoPreviewLayer` do iOS ser fluida. Nenhum quadro de
 *    prévia passa por CPU deste processo.
 *
 * **Nada de OpenGL nosso entra no caminho do codificador**, e isso é condição, não detalhe: o A/B
 * de 03/09 (1624,0 quadros por corrida de 45 s com prévia contra 1632,3 sem, 0 pacote perdido e 0
 * IDR quebrado em nove corridas — `docs/bancada.md` §8.18) é a régua, e uma thread GL nossa entre a
 * câmera e o `MediaCodec` é exatamente o que ela existe para proteger. O `VideoCapture` de 1.4.2
 * tem seis gatilhos que inserem um `SurfaceProcessorNode` (cópia GL da biblioteca) no caminho, e
 * cinco deles estão desligados **por construção** aqui — ver os comentários de [ligarCodificador].
 * O sexto é *quirk* de aparelho e está fora do nosso alcance; nenhum dos quatro aparelhos da
 * bancada casa com a lista de 1.4.2.
 *
 * ## `LifecycleOwner`
 *
 * `ProcessCameraProvider.bindToLifecycle` exige um `LifecycleOwner`; um `Service` comum não é um.
 * Quem chama passa `this` de um `LifecycleService` (`MirrorService`/`CameraCaptureService`).
 *
 * **E tem de ser sempre o mesmo dono para a mesma câmera.** `LifecycleCameraRepository` guarda
 * `mActiveLifecycleOwners` como deque e `setActive` chama `suspendUseCases` no dono anterior
 * (bytecode de camera-lifecycle-1.4.2): dois donos da mesma câmera significam que o ativo suspende
 * o outro. É por isso que a prévia **não** é bindada pela Activity — as duas fases daqui usam o
 * mesmo `LifecycleOwner` e a mesma instância de [CameraSelector].
 *
 * ## O relógio do `presentationTimeUs` da câmera não é o mesmo da tela
 *
 * Achado em bancada, no A07: `encode_latency_us` para câmera saía em ~120 ms, contra ~30 ms na
 * tela, com quadros perfeitos (`sem_start_code=0`, csd colado certo) — o número era mentira, não
 * fila. `CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE` explica: quando é `UNKNOWN` (comum
 * em aparelho intermediário/de entrada), o Android documenta que o carimbo de tempo da câmera
 * **não é comparável** a nenhum outro relógio do sistema — nem a `System.nanoTime()`
 * (`CLOCK_MONOTONIC`, o que [MonotonicClock] usa e o que bate com o `presentationTimeUs` da
 * `VirtualDisplay`). Só quando é `REALTIME` o carimbo é comparável a
 * `SystemClock.elapsedRealtimeNanos()`. [timestampSourceRealtime] carrega essa distinção para
 * [H264CameraEncoder] escolher o relógio certo — ou declarar, com todas as letras, que não há um.
 *
 * **E isto agora depende do nó GL não existir.** `VideoCapture.resolveTimebase` devolve o timebase
 * da própria câmera quando não há nó — igual ao que o `Preview` dava. Se um *quirk* inserir um nó,
 * o domínio de tempo vira `Timebase.UPTIME` enquanto [H264CameraEncoder] continua escolhendo o
 * relógio por `SENSOR_INFO_TIMESTAMP_SOURCE`, e `encode_latency_us` viraria número plausível e
 * errado. É a classe de defeito que a checagem de latência comparável existe para impedir.
 */
class CameraXSource private constructor(
    private val cameraProvider: ProcessCameraProvider,
    private val lifecycleOwner: LifecycleOwner,
    /**
     * A **mesma instância** nas duas fases. A chave do `LifecycleCamera` é `cameraId` +
     * `compatibilityId`, então um seletor equivalente já bastaria; reusar a instância tira a
     * dúvida de o segundo `bindToLifecycle` cair noutro `LifecycleCamera` e virar um segundo dono.
     */
    private val selector: CameraSelector,
    private val cameraId: String,
    /** O *use case* que a tela desenha, ou `null` quando a fonte subiu sem prévia. */
    private val preview: Preview?,
    private val handlerThread: HandlerThread,
    /**
     * A resolução que o usuário escolheu, lida **uma vez** na abertura.
     *
     * Guardada na instância em vez de relida em `ligarCodificador` porque as duas fases têm de
     * concordar: a prévia é bindada na abertura e o codificador entra depois, e se a escolha
     * mudasse entre as duas o `StreamSharing` do CameraX resolveria o conflito em silêncio — que
     * é exatamente a classe de defeito que a documentação desta classe existe para impedir.
     */
    private val resolucao: com.quall.android.core.Resolucao =
        com.quall.android.core.Resolucao.PADRAO,
    /** A taxa de quadros escolhida, pela mesma razão de [resolucao]: as duas fases têm de concordar. */
    private val fpsEscolhido: Int = 30,
    /** As faixas de fps que esta câmera anuncia, lidas uma vez na abertura. */
    private val faixasDeFps: List<android.util.Range<Int>> = emptyList(),
    /**
     * `true` quando `SENSOR_INFO_TIMESTAMP_SOURCE == REALTIME`, e portanto o `presentationTimeUs`
     * dos quadros desta câmera é comparável a `SystemClock.elapsedRealtimeNanos()`. `false` para
     * `UNKNOWN` — a maioria das câmeras de aparelho de entrada/intermediário — caso em que **não
     * existe** relógio do sistema comparável ao carimbo da câmera; é limitação documentada da
     * plataforma, não algo que dê para contornar aqui.
     */
    val timestampSourceRealtime: Boolean,
    previaPersistente: Boolean,
) {
    companion object {
        /**
         * Observa o estado da câmera para saber **por que** ela caiu.
         *
         * # O que isto conserta, e o custo de não ter
         *
         * Em 09/09/2026, no S24, uma sessão de câmera morreu e o app disse apenas
         * `espelhamento morreu: IllegalStateException: Pending dequeue output buffer request
         * cancelled` — a exceção do `dequeueOutputBuffer` sendo cancelado, que é a **última**
         * consequência de uma cadeia inteira. O `CameraService` do Android tinha registrado a causa
         * com todas as letras, quatro segundos antes:
         *
         * ```
         * wouldEvictLocked: current cost=66, adding cost=100, total cost=166, max cost=100
         * CameraService::connect evicting conflicting client for camera ID 0
         * ```
         *
         * Quem chegou foi o **reconhecimento facial da Samsung** (uid 1000), quando a tela acendeu: o
         * desbloqueio por rosto abre a câmera frontal, o modelo de custo do aparelho estoura, e o
         * cliente de menor prioridade é expulso. Como o desbloqueio por rosto vem ligado de fábrica,
         * **isso acontece toda vez que alguém pega o telefone** — não é caso raro, é o gesto mais
         * comum que existe.
         *
         * O CameraX entrega esse motivo em `CameraInfo.getCameraState()`, e nós não olhávamos. A
         * diferença entre as duas frases não é cosmética: uma manda o usuário procurar defeito no
         * Quall, a outra diz o que houve e o que fazer.
         *
         * Só registra; **não** decide nada. Quem decide é o [ultimoMotivoDaCamera], lido por quem
         * trata a morte da sessão.
         */
        fun observarEstadoDaCamera(
                camera: androidx.camera.core.Camera,
                dono: LifecycleOwner,
                /** Para o motivo sair no idioma do app (`docs/traducao.md`, Android). */
                contexto: Context,
            ) {
                camera.cameraInfo.cameraState.observe(dono) { estado ->
                val erro = estado?.error
                if (erro == null) {
                    Log.i(TAG, "estado da câmera: ${estado?.type}")
                    return@observe
                }
                val motivo = motivoDoErro(com.quall.android.core.Idioma.contexto(contexto), erro.code)
                ultimoErroDaCamera = erro.code
                ultimoMotivoDaCamera = motivo
                Log.w(TAG, "estado da câmera: ${estado.type} erro=${erro.code} (${Log.erroExterno(motivo)})")
            }
        }

        /**
         * O último motivo pelo qual a câmera reclamou, em português, ou `null` se ela nunca
         * reclamou nesta execução.
         *
         * É `@Volatile` e de processo porque quem lê está noutra thread e noutra classe: o
         * tratador que transforma a exceção do encoder numa frase para o usuário. Guardar o
         * motivo aqui é o que permite trocar *"Pending dequeue output buffer request cancelled"*
         * por *"outro app tomou a câmera"*.
         */
        @Volatile
        var ultimoMotivoDaCamera: String? = null

        /**
         * O código do [androidx.camera.core.CameraState.StateError] por trás de [ultimoMotivoDaCamera]: quem
         * mostra depois de uma troca de idioma remonta a frase com [motivoDoErro].
         */
        @Volatile
        var ultimoErroDaCamera: Int? = null

        /** Traduz o código de [androidx.camera.core.CameraState.StateError] para o que houve, na língua de [c]. */
        fun motivoDoErro(c: Context, codigo: Int): String = when (codigo) {
            androidx.camera.core.CameraState.ERROR_CAMERA_IN_USE -> c.getString(com.quall.android.R.string.cam_erro_em_uso)
            androidx.camera.core.CameraState.ERROR_MAX_CAMERAS_IN_USE -> c.getString(com.quall.android.R.string.cam_erro_maximo)
            androidx.camera.core.CameraState.ERROR_CAMERA_DISABLED -> c.getString(com.quall.android.R.string.cam_erro_desativada)
            androidx.camera.core.CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED -> c.getString(com.quall.android.R.string.cam_erro_nao_perturbe)
            androidx.camera.core.CameraState.ERROR_CAMERA_FATAL_ERROR -> c.getString(com.quall.android.R.string.cam_erro_fatal)
            androidx.camera.core.CameraState.ERROR_STREAM_CONFIG -> c.getString(com.quall.android.R.string.cam_erro_fluxo)
            androidx.camera.core.CameraState.ERROR_OTHER_RECOVERABLE_ERROR -> c.getString(com.quall.android.R.string.cam_erro_recuperavel)
            else -> c.getString(com.quall.android.R.string.cam_erro_codigo, codigo)
        }

        private const val TAG = "QuallCameraSource"

        private const val TIMEOUT_PADRAO_MS = 6_000L

        /**
         * A geometria pedida aos **dois** *use cases*, e o motivo de ela ser explícita.
         *
         * Duas razões, e as duas são de bytecode de 1.4.2:
         *
         *  1. **`VideoCapture` não tem teto de resolução.** `Camera2UseCaseConfigFactory.getConfig`
         *     só insere `OPTION_MAX_RESOLUTION` para `CaptureType.PREVIEW` (e o valor é o tamanho de
         *     preview do display, ou seja ≤1080p). Para `CaptureType.VIDEO_CAPTURE` **não insere
         *     nada**. Sem seletor explícito, a estratégia padrão é "a maior disponível" — num S24
         *     isso é 4K ou mais, com o `MediaCodec` e o teto de taxa (`MirrorService`, que assume
         *     1920x1080 para a câmera) calibrados para outra coisa. Não é hipótese: é o que o
         *     padrão faz.
         *  2. **A prévia tem que mostrar a mesma proporção que sai.** Enquadrar por uma imagem e
         *     transmitir outra é o defeito 3 que o usuário achou no iOS (`docs/bancada.md` §8.15).
         *     Com o mesmo seletor nos dois use cases, os dois caem na mesma proporção e a
         *     `PreviewView` em `fitCenter` mostra o fluxo inteiro — some o recorte manual por
         *     matriz que existia na Activity.
         *
         * 1920x1080 e não o 4:3 de antes: é a geometria que o resto do projeto já assume —
         * `MirrorService` calcula o teto de taxa da câmera por 1920x1080, e `docs/bancada.md`
         * registra que 1920x1080 são 8160 macroblocos contra o `MaxFS` 8192 do nível 4.0, com
         * 0,4 % de folga.
         *
         * `FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER`: numa câmera que não tenha 1920x1080 exato,
         * pega o mais próximo acima e só então o mais próximo abaixo — nunca fica sem tamanho.
         */
        private val GEOMETRIA_PEDIDA: ResolutionSelector by lazy {
            seletorPara(com.quall.android.core.Resolucao.PADRAO.pedido)
        }

        /**
         * O seletor de uma geometria qualquer — **a escolha do usuário entra por aqui**.
         *
         * Até 07/09/2026 `GEOMETRIA_PEDIDA` era `Size(1920, 1080)` cravado, e era o único tamanho
         * que a câmera do Android sabia pedir. Com o cardápio de `docs/fluxo-de-uso.md` o tamanho
         * passa a vir de `Resolucao.escolhida`, e este método existe para que a regra de recuo —
         * a parte que custou a ser descoberta — continue sendo **uma só** para todas as linhas.
         */
        /**
         * Pede uma taxa de quadros ao builder, por `setTargetFrameRate`.
         *
         * # Por que NÃO é `Camera2Interop`
         *
         * A primeira versão desta função, escrita e instalada em 07/09/2026, usava
         * `Camera2Interop.Extender.setCaptureRequestOption(CONTROL_AE_TARGET_FPS_RANGE, ...)`.
         * Funciona — e é a escolha errada, por uma diferença que só aparece no bytecode do
         * CameraX:
         *
         * * `setTargetFrameRate` grava `UseCaseConfig.OPTION_TARGET_FRAME_RATE`, que entra em
         *   `SupportedSurfaceCombination.filterSupportedSizes` e é **clampado pelo teto de cada
         *   tamanho** (`1e9 / StreamConfigurationMap.getOutputMinFrameDuration`), antes de casar
         *   com as faixas de AE;
         * * o interop escreve direto no `CaptureRequest.Builder`, **depois** de o CameraX já ter
         *   escolhido tamanho e faixa — `applyAeFpsRange` roda antes de
         *   `applyImplementationOptionToCaptureBuilder`, então o interop sobrescreve o valor
         *   negociado e **nada clampa**.
         *
         * Por que isso importa aqui, medido no S24 em 07/09/2026: o teto de 60 fps é **por
         * tamanho**, não por câmera. `1920x1080` tem `minFrameDuration` de 16,67 ms (60 fps), e
         * `2560x1440` e `3840x2160` têm 33,33 ms (**30 fps**). A lista
         * `CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES` anuncia `[60,60]` para a câmera inteira, então
         * uma guarda contra ela — que é a que estava aqui — deixa passar um pedido de 60 para uma
         * superfície de 30. Pelo interop, esse pedido chega ao HAL sem clamp, e o que ele faz
         * **não está provado**.
         *
         * Com `setTargetFrameRate` o CameraX resolve isso sozinho: pedir 4K a 60 **não** devolve 4K
         * a 30 — devolve o **maior tamanho que atende a taxa**, 1920x1080 a 60. Este comentário
         * dizia o contrário até 10/09/2026, quando o campo desmentiu (S24, frontal, `docs/bancada.md`
         * §8.69) e a revisão adversarial daquele dia apontou os dois comentários se contradizendo.
         * **A guarda deixa de ser necessária, e a conferência passa a ser a que sempre vale — o que
         * chegou do outro lado**, que agora a tela diz à pessoa (`core/Entrega.kt`).
         *
         * # O que ele NÃO resolve
         *
         * A faixa é **da sessão**, e não do use case: o CameraX intersecta o pedido de todos e
         * aplica o mesmo `expectedFrameRateRange` a todos os `StreamSpec`. Um `Preview` limitado a
         * 1080p e um `VideoCapture` em 4K dão `min(60, 30) = 30` para os dois. Por isso o pedido é
         * feito nos **dois** builders, com o mesmo valor: pedir a um só é o caso que degrada em
         * silêncio.
         *
         * # E os controles de câmera
         *
         * O veto é sobre fps; os controles do R9 vão pelo `Camera2CameraControl` na sessão viva, com
         * as chaves desta tabela (a do `docs/controles-de-camera.md` §4.5, em
         * `RegrasDosControles.plano`).
         */
        private fun <T> pedirQuadros(
            builder: androidx.camera.core.ExtendableBuilder<T>,
            fps: Int,
            faixas: List<android.util.Range<Int>>,
        ) {
            val alvo = faixaDoAutomatico(faixas, fps)
            when (builder) {
                is Preview.Builder -> builder.setTargetFrameRate(alvo)
                is VideoCapture.Builder<*> -> builder.setTargetFrameRate(alvo)
                else -> Log.w(TAG, "não sei pedir fps a ${builder.javaClass.simpleName}")
            }
        }

        /**
         * **A faixa pedida: até [fps], descendo até onde a câmera deixa o automático alongar a
         * exposição** (`RegrasDosControles.pisoDoAutomatico`). Pedida **sempre**, inclusive a 30: sem
         * pedido, o modelo de gravação do HAL fixa `[30,30]`, e o AE fica preso a 33 ms numa sala
         * escura (medido no tablet em 06/10). A exposição manual não é afetada: com `AE_MODE OFF` vale
         * o `SENSOR_FRAME_DURATION` do plano, que é 1/fps.
         */
        fun faixaDoAutomatico(faixas: List<android.util.Range<Int>>, fps: Int): android.util.Range<Int> {
            val pares = faixas.map { it.lower to it.upper }
            // Um fps que nenhuma faixa alcança (60 no A07) virava `[60,60]` e o CameraX recuava para a fixa.
            val teto = RegrasDosControles.tetoAlcancavel(pares, fps)
            return android.util.Range(RegrasDosControles.pisoDoAutomatico(pares, teto), teto)
        }

        /**
         * As faixas de fps que esta câmera anuncia. **Relato, não guarda** — ver [pedirQuadros].
         *
         * Continua sendo lida e registrada porque é o que permite ler o log e entender por que a
         * taxa negociada foi a que foi; mas ela é **por câmera**, e o teto que decide é **por
         * tamanho**, então decidir por ela seria decidir pela tabela errada.
         */
        fun faixasDeQuadros(context: Context, cameraId: String): List<android.util.Range<Int>> {
            val cm = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager ?: return emptyList()
            val chars = runCatching { cm.getCameraCharacteristics(cameraId) }.getOrNull() ?: return emptyList()
            return chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.toList().orEmpty()
        }

        /**
         * **O que esta câmera declara sobre um tamanho**: se ela o oferece, e a quantos quadros por
         * segundo. É o fato que deixa a tela dizer *"esta câmera não oferece 4K"* ou *"faz 4K só até
         * 30 fps"* em vez de um silêncio que parece erro do Quall (`core/Entrega.kt`).
         *
         * Pergunta ao Camera2 pelo formato `PRIVATE`, que é o das superfícies de câmera — a mesma
         * tabela de onde o CameraX tira o teto por tamanho (`1e9 / getOutputMinFrameDuration`, ver
         * [pedirQuadros]). Sem características legíveis, a resposta é "oferece, fps desconhecido",
         * que leva a frase a dizer que o motivo não foi identificado — nunca a inventar um.
         */
        fun capacidadeNoTamanho(
            context: Context,
            cameraId: String,
            tamanho: Size,
        ): com.quall.android.core.Entrega.Camera {
            val desconhecida = com.quall.android.core.Entrega.Camera(true, null)
            val cm = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
                ?: return desconhecida
            val chars = runCatching { cm.getCameraCharacteristics(cameraId) }.getOrNull()
                ?: return desconhecida
            val mapa = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?: return desconhecida
            val formato = android.graphics.ImageFormat.PRIVATE
            val tamanhos = runCatching { mapa.getOutputSizes(formato)?.toList() }.getOrNull().orEmpty()
            val oferece = tamanhos.any { it.width == tamanho.width && it.height == tamanho.height }
            if (!oferece) return com.quall.android.core.Entrega.Camera(false, null)
            val duracaoNs = runCatching { mapa.getOutputMinFrameDuration(formato, tamanho) }.getOrNull()
            val fps = duracaoNs?.takeIf { it > 0 }
                ?.let { kotlin.math.round(1_000_000_000.0 / it).toInt() }
            return com.quall.android.core.Entrega.Camera(true, fps)
        }

        /**
         * **O fps máximo de cada resolução do cardápio nesta câmera** (`SeletorDeResolucao`): o menor
         * entre o teto do tamanho ([capacidadeNoTamanho]) e o maior teto das faixas de AE ([faixasDeQuadros]);
         * `null` quando a câmera não oferece o tamanho. Uma resolução sem nada legível fica de fora do
         * mapa, que quer dizer "não se sabe" e mantém o botão disponível.
         */
        fun tetosPorResolucao(context: Context, cameraId: String): Map<com.quall.android.core.Resolucao, Int?> {
            val maiorFaixa = faixasDeQuadros(context, cameraId).maxOfOrNull { it.upper }
            val tetos = LinkedHashMap<com.quall.android.core.Resolucao, Int?>()
            for (r in com.quall.android.core.Resolucao.entries) {
                val c = capacidadeNoTamanho(context, cameraId, r.pedido)
                if (!c.ofereceOTamanhoPedido) {
                    tetos[r] = null
                    continue
                }
                val teto = listOfNotNull(c.quadrosNoTamanhoPedido, maiorFaixa).minOrNull() ?: continue
                tetos[r] = teto
            }
            return tetos
        }

        // **As duas APIs internas do CameraX que o Quall usa de propósito** (`@RestrictTo`, do grupo
        // `androidx.camera`). Não há equivalente público no 1.4.2 (fixado no `build.gradle.kts`):
        //  - `VideoCapture.Builder.setResolutionSelector`: o `VideoCapture` público só aceita o
        //    `QualitySelector` do `Recorder`, e aqui a saída é o `SaidaDeVideoParaCodificador`, que
        //    pede o tamanho exato do codificador;
        //  - `SurfaceRequest.expectedFrameRate`: a taxa que a sessão de captura vai entregar, que o
        //    `KEY_FRAME_RATE` só ecoa (achado da revisão adversarial de 10/09).
        // Ficam aqui, num lugar só e com o aviso do lint calado com motivo. Ao subir o CameraX, conferir
        // as duas antes de qualquer outra coisa.

        /** `setResolutionSelector` no construtor do `VideoCapture` (ver o comentário acima). */
        @SuppressLint("RestrictedApi")
        fun <T : VideoOutput> VideoCapture.Builder<T>.comSeletor(seletor: ResolutionSelector): VideoCapture.Builder<T> =
            setResolutionSelector(seletor)

        /** O topo da faixa de quadros que a sessão negociou, ou null (ver o comentário acima). */
        @SuppressLint("RestrictedApi")
        fun quadrosDoPedido(req: SurfaceRequest): Int? =
            runCatching { req.expectedFrameRate }.getOrNull()?.upper?.takeIf { it > 0 }

        fun seletorPara(tamanho: Size): ResolutionSelector =
            ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                .setResolutionStrategy(
                    ResolutionStrategy(
                        tamanho,
                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                    ),
                )
                .build()

        /**
         * A mesma geometria de [GEOMETRIA_PEDIDA], mas com `FALLBACK_RULE_NONE`.
         *
         * A intenção era instrumento: com a regra de recuo normal o CameraX degrada em silêncio, e
         * "pedi 1080p e vieram 720p" não distingue *o aparelho não tem* de *o CameraX preferiu
         * outro*. Esperava-se que a regra estrita fizesse a distinção sair como exceção.
         *
         * **Não faz.** Na única corrida deste braço (A10s, 04/09) o CameraX **não recusou**: ele
         * desbindou os dois use cases e subiu um `StreamSharing` no lugar — o caminho de stream
         * compartilhado, que é **cópia GL da biblioteca no caminho do codificador**, exatamente o
         * que a régua do §8.18 existe para impedir. Oito linhas de `StreamSharing` nessa corrida e
         * **zero** em todas as outras trinta.
         *
         * Duas consequências, e as duas importam:
         *
         *  - Este braço **não responde** se 1080p cabe na combinação incremental. A pergunta
         *    continua aberta.
         *  - Com nó no caminho, `VideoCapture.resolveTimebase` devolve `Timebase.UPTIME` enquanto
         *    [H264CameraEncoder] escolhe o relógio por `SENSOR_INFO_TIMESTAMP_SOURCE` (ver a doc
         *    desta classe): **nenhum `encode_latency_us` deste braço é comparável** aos outros.
         *
         * Fica como instrumento de diagnóstico, e nunca como candidato a produto.
         */
        private val GEOMETRIA_ESTRITA: ResolutionSelector by lazy {
            ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                .setResolutionStrategy(
                    ResolutionStrategy(Size(1920, 1080), ResolutionStrategy.FALLBACK_RULE_NONE),
                )
                .build()
        }

        /**
         * Bloqueia até o CameraX entregar o pedido de superfície para [cameraId], ou até
         * [timeoutMs] — **um use case só, sem prévia**.
         *
         * É o caminho do instrumento de bancada ([CameraCaptureService]), e ele não muda: quem mede
         * o caminho de mídia não pode ganhar um segundo fluxo saindo da mesma câmera sem que o
         * número medido mude de significado. Aqui a fonte inteira pertence ao codificador — quando
         * ele solta ([soltarCodificador]), a câmera fecha.
         *
         * Chame de uma thread de trabalho — nunca da thread de interface.
         */
        fun abrir(
            context: Context,
            lifecycleOwner: LifecycleOwner,
            cameraId: String,
            timeoutMs: Long = TIMEOUT_PADRAO_MS,
        ): CameraXSource {
            val base = preparar(context, cameraId, timeoutMs)
            val fonte = CameraXSource(
                cameraProvider = base.provider,
                lifecycleOwner = lifecycleOwner,
                selector = base.selector,
                cameraId = cameraId,
                preview = null,
                handlerThread = base.handlerThread,
                timestampSourceRealtime = base.timestampSourceRealtime,
                previaPersistente = false,
            )
            try {
                // **Explícito, e não pelo padrão.** Esta fonte nasce sem prévia, então o
                // `previaViva` já a levaria ao caminho de um use case só — mas herdar o padrão de
                // produto deixaria o que o instrumento mede dependendo de uma decisão de produto
                // tomada noutro arquivo. Ver a doc de [ligarCodificador].
                fonte.ligarCodificador(timeoutMs, estrategia = "incremental")
            } catch (e: Throwable) {
                // `parar()` faz o que a versão de uma fase fazia à mão no caminho de erro: solta a
                // prévia (aqui não há), desbinda tudo e encerra a HandlerThread.
                fonte.parar()
                throw e
            }
            return fonte
        }

        /**
         * Abre a câmera com **só** o *use case* da tela, sem `MediaCodec` nenhum no caminho — é a
         * prévia que aparece na fase ESPERANDO, antes de qualquer receptor parear.
         *
         * Não espera `SurfaceRequest`: a superfície do `Preview` vem da `PreviewView` da Activity
         * (ver [PreviaDaCamera]), não de nós. Devolve assim que o bind responde, para que o PIN da
         * tela de espera não fique esperando câmera.
         *
         * Chame de uma thread de trabalho — o bind é postado na principal e esta função espera por
         * ele.
         */
        fun abrirComPrevia(
            context: Context,
            lifecycleOwner: LifecycleOwner,
            cameraId: String,
            timeoutMs: Long = TIMEOUT_PADRAO_MS,
        ): CameraXSource {
            val base = preparar(context, cameraId, timeoutMs)
            // **A geometria é a que o usuário escolheu**, e não mais um literal. Ver
            // `core/Resolucao.kt` e `docs/fluxo-de-uso.md`. Sem escolha vale 1080p, que é o que
            // esta linha pedia antes do cardápio.
            val escolhida = com.quall.android.core.Resolucao.escolhida(context)
            val fps = com.quall.android.core.Resolucao.quadros(context)
            val faixas = faixasDeQuadros(context, cameraId)
            Log.i(TAG, "resolução escolhida: ${escolhida.rotulo} (${escolhida.pedido}) a $fps fps; " +
                "faixas anunciadas: $faixas")
            val previewBuilder = Preview.Builder().setResolutionSelector(seletorPara(escolhida.pedido))
            pedirQuadros(previewBuilder, fps, faixas)
            val preview = previewBuilder.build()

            val main = Handler(Looper.getMainLooper())
            var falhaBind: Throwable? = null
            val bindLatch = CountDownLatch(1)
            main.post {
                try {
                    // Defensivo, e só nesta primeira abertura do ciclo: um `ProcessCameraProvider`
                    // é singleton por processo, e um ciclo anterior pode ter deixado algo ligado
                    // se a limpeza não rodou. O bind da **segunda** fase ([ligarCodificador]) não
                    // pode repetir isto — lá o `unbindAll` fecharia a prévia que já está no ar.
                    base.provider.unbindAll()
                    val cam = base.provider.bindToLifecycle(lifecycleOwner, base.selector, preview)
                    observarEstadoDaCamera(cam, lifecycleOwner, context)
                    // Na thread principal, como o CameraX exige: liga o use case da tela ao
                    // provedor que a Activity tiver registrado. Sem Activity visível o `Preview`
                    // fica sem provedor e `notifyInactive` mantém o fluxo da tela parado.
                    PreviaDaCamera.usarPreview(preview)
                } catch (e: Throwable) {
                    falhaBind = e
                } finally {
                    bindLatch.countDown()
                }
            }
            // **Desbindar nos dois caminhos de erro, e não só encerrar a thread.** `abrir` já faz
            // isso pelo `fonte.parar()` do seu `catch`; aqui não havia `CameraXSource` construído
            // ainda, então a limpeza tem de ser à mão. Sem ela o bind sobrevive ao erro e a câmera
            // fica aberta sem dono — o aparelho esquenta, o LED fica aceso, e o próximo `abrir`
            // encontra a câmera ocupada por ninguém.
            fun limparBindDaPrevia() {
                val pronto = CountDownLatch(1)
                main.post {
                    runCatching { PreviaDaCamera.usarPreview(null) }
                    runCatching { base.provider.unbindAll() }
                    pronto.countDown()
                }
                pronto.await(2, TimeUnit.SECONDS)
                base.handlerThread.quitSafely()
            }
            if (!bindLatch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                limparBindDaPrevia()
                throw IllegalStateException("bindToLifecycle da prévia não respondeu em ${timeoutMs}ms")
            }
            falhaBind?.let {
                limparBindDaPrevia()
                throw IllegalStateException("bindToLifecycle da prévia falhou: ${it.message}", it)
            }

            // Este log é a prova pedida no protocolo: ele tem de sair **antes** da primeira linha
            // de sessão de pé do `QuallMirror`. Se sair depois, a prévia voltou a depender do
            // pareamento e a mudança de 03/09 se desfez.
            Log.i(TAG, "câmera $cameraId aberta só com prévia — ainda sem receptor, sem MediaCodec")

            return CameraXSource(
                cameraProvider = base.provider,
                lifecycleOwner = lifecycleOwner,
                selector = base.selector,
                cameraId = cameraId,
                preview = preview,
                handlerThread = base.handlerThread,
                resolucao = escolhida,
                fpsEscolhido = fps,
                faixasDeFps = faixas,
                timestampSourceRealtime = base.timestampSourceRealtime,
                previaPersistente = true,
            )
        }

        /** O que as duas aberturas têm em comum: provider, seletor, thread e o domínio do relógio. */
        @androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
        private fun preparar(context: Context, cameraId: String, timeoutMs: Long): Base {
            val provider = ProcessCameraProvider.getInstance(context).get(timeoutMs, TimeUnit.MILLISECONDS)

            val selector = CameraSelector.Builder()
                .addCameraFilter { infos ->
                    infos.filter { Camera2CameraInfo.from(it).cameraId == cameraId }.toMutableList()
                }
                .build()

            val cm = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            val realtime = runCatching {
                cm?.getCameraCharacteristics(cameraId)
                    ?.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE) ==
                    CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME
            }.getOrDefault(false)

            // O nível de hardware decide quais COMBINAÇÕES de superfícies o aparelho garante, e é
            // por isso que ele entra no log ao lado da resolução: LEGACY garante duas superfícies
            // PRIV só até o tamanho de *preview*; LIMITED garante PREVIEW+RECORD. Sem esta linha,
            // "por que 720p aqui e 1080p ali" não tem como ser respondido pelo próprio log.
            val nivel = runCatching {
                when (cm?.getCameraCharacteristics(cameraId)
                    ?.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "LEGACY"
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "LIMITED"
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "FULL"
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "LEVEL_3"
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "EXTERNAL"
                    else -> "?"
                }
            }.getOrDefault("?")
            Log.i(TAG, "câmera $cameraId: nível de hardware=$nivel")

            return Base(
                provider = provider,
                selector = selector,
                handlerThread = HandlerThread("quall-camera-source").also { it.start() },
                timestampSourceRealtime = realtime,
            )
        }

        private class Base(
            val provider: ProcessCameraProvider,
            val selector: CameraSelector,
            val handlerThread: HandlerThread,
            val timestampSourceRealtime: Boolean,
        )
    }

    private val handler = Handler(handlerThread.looper)
    private val executor = Executor { handler.post(it) }

    // Capacidade 1, não `SynchronousQueue`: achado no A07 em bancada — `offer()` sem prazo de uma
    // `SynchronousQueue` só entrega se **já houver** alguém bloqueado em `poll()` naquele instante
    // exato; como o `onSurfaceRequested` do CameraX chega depois de a câmera abrir de verdade (a
    // sessão de captura leva um tanto), e não instantaneamente após `bindToLifecycle`, a corrida
    // quase sempre perdia e o pedido se perdia em silêncio — o sintoma era "a câmera não entregou
    // pedido de superfície" mesmo com o bind tendo funcionado. Uma fila com espaço para 1 elemento
    // não depende de rendez-vous: `offer()` sempre aceita, `poll(timeout)` sempre encontra o que já
    // estiver lá.
    private val fila = ArrayBlockingQueue<SurfaceRequest>(1)

    /**
     * `true` enquanto existir um `Preview` bindado que **sobrevive ao codificador**.
     *
     * Separa os dois donos possíveis da câmera: no instrumento de bancada a fonte inteira é do
     * codificador e some com ele; no espelhamento a fonte é do serviço — a prévia nasce na espera,
     * atravessa a sessão e continua depois dela, porque a pessoa volta a esperar outro receptor
     * ainda enquadrando. Vira `false` se o bind incremental do codificador for recusado e a prévia
     * tiver de cair para a transmissão sobreviver.
     */
    @Volatile private var previaViva: Boolean = previaPersistente
    val temPrevia: Boolean get() = previaViva

    @Volatile private var videoCapture: VideoCapture<SaidaDeVideoParaCodificador>? = null
    @Volatile private var pedidoDoCodificador: SurfaceRequest? = null

    /**
     * A superfície de entrada do `MediaCodec` que já foi entregue ao CameraX.
     *
     * Guardada para poder ser entregue **de novo**. Ver [aoPedirSuperficie]: quando a câmera é
     * reaberta — e ela é, sozinha, depois de uma expulsão —, o CameraX recria a sessão de captura
     * e emite um `SurfaceRequest` NOVO. Sem esta referência não há o que responder a ele.
     */
    @Volatile private var superficieDoCodificador: Surface? = null

    /**
     * A última resolução negociada. **Não** é zerada ao desbindar o codificador, e isso não é
     * descuido: `CameraCaptureService` lê [resolution] *depois* de `enc.run(...)` — ou seja depois
     * de o encoder já ter soltado a fonte — para escrever o cabeçalho do sidecar. Zerar aqui
     * faria o instrumento de bancada estourar no fim de toda captura. O que diz se há codificador
     * bindado **agora** é [videoCapture], e é ele que decide se [ligarCodificador] tem trabalho a
     * fazer.
     */
    @Volatile private var resolucaoNegociada: Size? = null

    @Volatile private var parado = false

    /**
     * A resolução que a câmera negociou com o *use case* do codificador. Só existe depois de
     * [ligarCodificador] — antes disso não há `SurfaceRequest`, e devolver um palpite aqui é
     * exatamente o descasamento silencioso que a doc da classe explica.
     */
    val resolution: Size
        get() = resolucaoNegociada ?: throw IllegalStateException(
            "a resolução da câmera $cameraId só existe depois de ligarCodificador()"
        )

    /**
     * O teto da faixa de fps que a câmera negociou com o codificador (`SurfaceRequest
     * .getExpectedFrameRate`). `null` antes de [ligarCodificador] ou quando o CameraX não informa.
     */
    @Volatile
    var quadrosNegociados: Int? = null
        private set

    /**
     * Acrescenta o *use case* do codificador à câmera já aberta e devolve a resolução negociada.
     * Bloqueia até o `SurfaceRequest` chegar, ou até [timeoutMs]. Idempotente.
     *
     * ## `rebind_junto` é o padrão, e é a medida que decidiu — não o raciocínio
     *
     * Este bloco dizia, até 04/09, que acrescentar o use case **sem `unbindAll`** era o desenho
     * certo: o que se queria era `Camera2CameraImpl.tryAttachUseCases` → `resetCaptureSession(false)`
     * → `openCaptureSession()` com o `CameraDevice` em OPENED, e não um ciclo completo de câmera.
     * O raciocínio era plausível e **as duas conclusões que ele sustentava estavam erradas**.
     *
     * Dezoito corridas, três aparelhos, o mesmo APK, os dois braços alternados
     * (`docs/bancada.md` §8.20):
     *
     *  - **Resolução.** No A10s e no A07 o bind incremental entrega 1280x720 ao codificador e o
     *    bind conjunto entrega 1920x1080, 3 de 3 em cada. No Tablet os dois entregam 1080p.
     *  - **Primeira imagem.** O bind conjunto é 172 a 214 ms **mais rápido** nos três aparelhos,
     *    sem sobreposição de faixas. A reconfiguração "barata" custava mais que refazer.
     *
     * O mecanismo **não está fechado**, e isto fica escrito de propósito: o nível de hardware não
     * explica (o A10s é FULL e degrada, o Tablet é LIMITED e não degrada), e o levantamento de
     * bytecode que perseguiu a tabela de combinações garantidas terminou dizendo que faltava um
     * termo. O que está fechado é o **fato**, em três aparelhos, e o fato é que este caminho é
     * melhor nos dois eixos.
     *
     * ## O preço, medido e não suposto: um ciclo completo de câmera
     *
     * `unbindAll` com o único `LifecycleCamera` daquela câmera **fecha o `CameraDevice`**. Nas
     * nove corridas do braço, nos três aparelhos, o log traz sempre `Closing camera` →
     * `CameraDevice.onClosed` → `Opening camera` → `CameraDevice.onOpened`, em **150 a 340 ms**;
     * nas nove do braço incremental, nunca. E o que o usuário vê é **mais** que isso: a prévia
     * fica sem imagem (`Preview stream state` IDLE → STREAMING) por 279 a 531 ms, contra zero
     * ocorrências de IDLE nas nove do braço incremental.
     *
     * *(Se o indicador de privacidade do sistema pisca junto, ninguém mediu — e no A10s, que é
     * Android 11, ele nem existe. Fica como NÃO SEI, não como preço declarado.)*
     *
     * **E mesmo pagando esse ciclo o total cai 172 a 214 ms.** É o que o número diz: reconfigurar
     * a `CaptureSession` com a prévia no ar custava mais do que fechar a câmera e abrir de novo.
     * Contra-intuitivo, medido nos dois sentidos, e é o motivo de esta doc não ter mais o
     * parágrafo que dizia que o `CameraDevice` ficava em OPENED — ele não fica.
     *
     * A resolução da prévia também cai, de 1920x1080 para 1280x720 no A10s e no A07 — que é
     * exatamente o arranjo que a §8.18 mediu. A prévia é a tela do próprio aparelho; o
     * codificador é o que sai na rede.
     *
     * `incremental` continua disponível por [com.quall.android.core.Bancada.bindDaCamera] como
     * **braço de medição**, não como alternativa de produto.
     *
     * Chame de uma thread de trabalho — nunca da principal.
     */
    fun ligarCodificador(
        timeoutMs: Long = TIMEOUT_PADRAO_MS,
        estrategia: String = "rebind_junto",
    ): Size {
        // Idempotência por *use case bindado*, e não pela resolução guardada — ver
        // [resolucaoNegociada]: ela sobrevive ao desbind de propósito.
        if (videoCapture != null) return resolution
        check(!parado) { "a câmera $cameraId já foi parada" }

        // O use case do CODIFICADOR. Três decisões, e cada uma desliga um gatilho de nó OpenGL do
        // `VideoCapture` (`isCreateNodeNeeded`, seis condições em OU):
        //
        //  - **`setMirrorMode(MIRROR_MODE_OFF)`** desliga `shouldMirror`. Sem isto a câmera
        //    frontal ligaria espelhamento por padrão, e espelhar é transformação — o CameraX
        //    resolve transformação inserindo um `SurfaceProcessorNode`, que é cópia GL da
        //    biblioteca **no caminho do codificador**. Quem emite câmera frontal vai ver a si
        //    mesmo não espelhado; é o preço, e é o lado certo de pagar.
        //  - **`setResolutionSelector`** fixa a geometria (ver [GEOMETRIA_PEDIDA]).
        //  - **nenhum `CameraEffect`, nenhum `setSurfaceProcessingForceEnabled`**: são os
        //    outros dois gatilhos que dependem de nós, e nós simplesmente não os chamamos.
        //
        // Os dois que sobram: `shouldCrop` (só liga com ViewPort — ver o bind abaixo) e
        // `shouldEnableSurfaceProcessingByQuirk`, que é de aparelho.
        val vcBuilder = VideoCapture.Builder(SaidaDeVideoParaCodificador { req -> aoPedirSuperficie(req) })
            .setMirrorMode(MirrorMode.MIRROR_MODE_OFF)
            .comSeletor(
                if (estrategia == "incremental_estrito") {
                    GEOMETRIA_ESTRITA
                } else {
                    seletorPara(resolucao.pedido)
                },
            )
        // **A taxa é pedida aqui e no `Preview`, e nos dois pelo mesmo motivo.** O bind é
        // conjunto; um use case pedindo 60 e o outro calado é o tipo de descasamento que já fez o
        // CameraX subir um `StreamSharing` sozinho neste app (ver o comentário de
        // [GEOMETRIA_ESTRITA]). A 30 também se pede: o "padrão do CameraX" era o `[30,30]` do HAL, que
        // escurece a imagem em pouca luz ([faixaDoAutomatico]).
        pedirQuadros(vcBuilder, fpsEscolhido, faixasDeFps)
        // **A taxa negociada é relatada, e não presumida.** O CameraX clampa o pedido pelo teto
        // do tamanho escolhido e pela interseção com os outros use cases, sem avisar; sem esta
        // linha, "pedi 60" e "estão saindo 60" seriam a mesma frase no log — e no S24 elas não
        // são: 1080p faz 60, 2K e 4K fazem 30. Ver o cabeçalho de `pedirQuadros`.
        val vc = vcBuilder
            .build()

        val main = Handler(Looper.getMainLooper())
        var falhaBind: Throwable? = null
        val bindLatch = CountDownLatch(1)
        main.post {
            try {
                // **Esvaziar a fila antes de cada bind não é higiene: é o que separa "transmite"
                // de "não transmite".** A fila tem capacidade 1 e o `VideoOutput` usa `offer`, que
                // numa fila cheia DESCARTA em silêncio e devolve false. Um pedido velho parado
                // aqui faria o `poll` lá embaixo entregar ao codificador uma superfície morta — o
                // sintoma seria imagem nenhuma no receptor com log de bind normal, a cara de
                // defeito de rede que esta bancada já gastou um dia perseguindo.
                fila.clear()
                // **`when` e não `if (estrategia == "rebind_junto")`.** Com a comparação positiva,
                // um valor desconhecido escorreria para o braço incremental — que é o pior dos
                // dois pela medida — enquanto o parâmetro declara `rebind_junto` como padrão. A
                // guarda de `Bancada.bindDaCamera` já filtra, mas rede de segurança em um lugar só
                // é rede de segurança que some quando alguém chama de outro lugar.
                val incremental = estrategia == "incremental" || estrategia == "incremental_estrito"
                // **A prévia sai da sessão de captura, e o motivo é o gesto mais comum que existe.**
                //
                // Medido no S24 em 09/09/2026, com as linhas do próprio CameraX: sair do app e
                // voltar reanexa o use case da prévia — a `SurfaceView` da tela morre ao sair e
                // renasce ao voltar — e o CameraX responde com
                // `Resetting Capture Session` → `Releasing session in state OPENED` →
                // `Opening capture session`, 280 ms. **O codificador está na mesma sessão**: ele
                // para junto e volta junto, e quando volta sai uma enxurrada. O receptor mediu:
                // `janela_do_enlace ms=509 pacotes=8572 perdidos=4365 (50,92%)` — contra 400 a
                // 1 000 pacotes das janelas vizinhas. Os IDR que ele pede para se curar nascem
                // dentro dessa enxurrada e chegam quebrados; a tela fica **verde**, no Windows e no
                // macOS.
                //
                // A guarda de `PreviaDaCamera` não segurava isso: ela recusa aplicar o *provedor*
                // novo (por isso a tela mostra "Transmissão em andamento"), mas o *use case*
                // continuava anexado, e é o use case que reconfigura a sessão.
                //
                // **O preço, dito com todas as letras: não há prévia na tela do próprio aparelho
                // enquanto ele transmite.** É o que a mensagem do app já promete desde 08/09; a
                // diferença é que agora ela é verdade desde o começo da sessão, e não só depois da
                // primeira ida ao segundo plano.
                if (previaViva && estrategia == "so_codificador") {
                    val p = checkNotNull(preview) { "previaViva sem Preview — estado impossível" }
                    runCatching { PreviaDaCamera.soltar(p) }
                    cameraProvider.unbindAll()
                    fila.clear()
                    cameraProvider.bindToLifecycle(lifecycleOwner, selector, vc)
                    previaViva = false
                    Log.i(
                        TAG,
                        "prévia fora da sessão de captura: com ela dentro, voltar ao app refaz a " +
                            "sessão e o codificador para junto (ver bancada.md §8.65)",
                    )
                } else if (previaViva && !incremental) {
                    // Desbinda os dois e sobe os dois no MESMO `bindToLifecycle` — o bind que a
                    // §8.18 mediu, e que a §8.20 mediu de novo dando 1920x1080 e primeira imagem
                    // 172 a 214 ms mais rápida em três aparelhos.
                    // `previaViva` só nasce de `previaPersistente`, que só é `true` em
                    // `abrirComPrevia`, que sempre constrói com `preview` não-nulo — e `preview` é
                    // `val`. O `checkNotNull` diz isso em vez de um ramo que nunca roda.
                    val p = checkNotNull(preview) { "previaViva sem Preview — estado impossível" }
                    cameraProvider.unbindAll()
                    try {
                        cameraProvider.bindToLifecycle(lifecycleOwner, selector, p, vc)
                    } catch (e: Throwable) {
                        // **O mesmo recuo do caminho incremental, e pela mesma razão**: quem
                        // decide se Preview+VideoCapture cabe é o HAL, não a tabela de combinações
                        // garantidas. Sem este bloco, um HAL que recusasse a combinação trocaria
                        // "esta câmera transmite sem prévia" por "esta câmera não transmite" — e
                        // a primeira versão desta mudança tinha exatamente esse defeito.
                        Log.w(TAG, "bind conjunto recusado; a prévia cai e a transmissão fica", e)
                        runCatching { p?.let { PreviaDaCamera.soltar(it) } }
                        cameraProvider.unbindAll()
                        fila.clear()
                        cameraProvider.bindToLifecycle(lifecycleOwner, selector, vc)
                        previaViva = false
                    }
                } else if (previaViva) {
                    try {
                        // `bindToLifecycle(owner, selector, vararg useCases)`, e **nunca** a
                        // sobrecarga de `UseCaseGroup`/`ViewPort`. Um `ViewPort` define crop rect,
                        // crop rect é `shouldCrop`, e `shouldCrop` é o quarto gatilho de nó OpenGL
                        // do `VideoCapture` — acrescentar um `ViewPort` aqui põe uma cópia GL no
                        // caminho do codificador e derruba a régua do §8.18 sem erro visível.
                        cameraProvider.bindToLifecycle(lifecycleOwner, selector, vc)
                    } catch (e: Throwable) {
                        // A combinação de superfícies é decidida pelo aparelho, e o recuo aqui é a
                        // diferença entre "esta câmera transmite sem prévia" e "esta câmera não
                        // transmite". Preview+VideoCapture é PRIV+PRIV, que a tabela de
                        // combinações garantidas da Camera2 cobre desde o nível LEGACY — mas quem
                        // decide é o HAL, não a tabela.
                        Log.w(TAG, "bind incremental do VideoCapture recusado; a prévia cai e a transmissão fica", e)
                        runCatching { preview?.let { PreviaDaCamera.soltar(it) } }
                        cameraProvider.unbindAll()
                        fila.clear()
                        cameraProvider.bindToLifecycle(lifecycleOwner, selector, vc)
                        previaViva = false
                    }
                } else {
                    // Caminho do instrumento de bancada: desbinda tudo e sobe um use case só.
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(lifecycleOwner, selector, vc)
                }
            } catch (e: Throwable) {
                falhaBind = e
            } finally {
                bindLatch.countDown()
            }
        }
        if (!bindLatch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
            throw IllegalStateException("bindToLifecycle do codificador não respondeu em ${timeoutMs}ms")
        }
        falhaBind?.let {
            throw IllegalStateException("bindToLifecycle do codificador falhou: ${it.message}", it)
        }

        val request = try {
            fila.poll(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: InterruptedException) {
            null
        } ?: run {
            // Só o use case do codificador sai; a prévia, se existir, continua no ar — quem decide
            // desistir da câmera inteira é quem chamou.
            main.post { runCatching { cameraProvider.unbind(vc) } }
            throw IllegalStateException(
                "a câmera $cameraId não entregou pedido de superfície em ${timeoutMs}ms",
            )
        }

        videoCapture = vc
        pedidoDoCodificador = request
        resolucaoNegociada = request.resolution
        // **A taxa que a câmera negociou**, e não a que o codificador ecoou. O `KEY_FRAME_RATE` do
        // formato de entrada só repete o que foi configurado; quem sabe o que a sessão de captura
        // vai entregar é o `SurfaceRequest` (achado da revisão adversarial de 10/09/2026). A faixa
        // é da sessão inteira, intersectada com a da prévia — ver [pedirQuadros].
        quadrosNegociados = quadrosDoPedido(request)

        // A resolução negociada entra no log de propósito: ela mudou de use case em 03/09, e é o
        // primeiro número que um A/B novo tem que conferir contra o braço anterior.
        Log.i(
            TAG,
            "câmera $cameraId: resolução negociada ${request.resolution.width}x${request.resolution.height}, " +
                "timestamp_source=${if (timestampSourceRealtime) "REALTIME" else "UNKNOWN (não comparável a outro relógio do sistema)"}, " +
                "fps_negociado=${quadrosNegociados ?: "?"}, prévia=$previaViva, bind=$estrategia, " +
                // A resolução da PRÉVIA na mesma linha, porque as duas coexistem na mesma corrida
                // e no A10s podem ser o mesmo número — ler o log pelo valor, e não pela origem da
                // linha, já confundiu quem escreveu a §8.19.
                "prévia_em=${preview?.resolutionInfo?.resolution?.let { "${it.width}x${it.height}" } ?: "—"}",
        )
        return request.resolution
    }

    /** Entrega a superfície de entrada do encoder ao CameraX. Chame uma vez, depois de [ligarCodificador]. */
    fun prover(surface: Surface) {
        val pedido = pedidoDoCodificador
            ?: throw IllegalStateException("prover() sem pedido de superfície — ligarCodificador() não rodou")
        // **Guardada para ser entregue de novo.** Ver [aoPedirSuperficie].
        superficieDoCodificador = surface
        // A partir daqui, ligar um provedor de prévia novo derrubaria isto. Ver
        // `PreviaDaCamera.transmissaoComecou`.
        PreviaDaCamera.transmissaoComecou()
        pedido.provideSurface(surface, executor) { result ->
            Log.i(TAG, "SurfaceRequest liberado: código ${result.resultCode}")
        }
    }

    /**
     * Atende um `SurfaceRequest` do `VideoCapture`.
     *
     * # Por que isto existe, e o que acontecia sem ele
     *
     * Até 09/09/2026 o `VideoOutput` fazia só `fila.offer(req)`, e quem lia a fila era
     * [ligarCodificador] — **uma vez, na abertura**. Isso bastava enquanto o CameraX pedia a
     * superfície uma vez só. Ele não pede.
     *
     * Medido no S24 neste dia: o reconhecimento facial da Samsung expulsou o Quall da câmera duas
     * vezes ao acender a tela, e **o CameraX reabriu sozinho as duas** — `erro=2` seguido de
     * `OPEN` em 731 ms e depois em 780 ms. Só que ao reabrir ele recria a sessão de captura,
     * devolve a superfície antiga (`SurfaceRequest liberado: código 0`, que é
     * `RESULT_SURFACE_USED_SUCCESSFULLY`) e emite um pedido **novo**. Esse pedido caía numa
     * `ArrayBlockingQueue` de capacidade 1 que ninguém mais lia.
     *
     * O resultado é o pior tipo de defeito: **câmera aberta, encoder vivo, e nada ligando os
     * dois.** A sessão morreu 7,5 s depois de a câmera já estar de volta, com a exceção aparecendo
     * onde ela é consequência — o `dequeueOutputBuffer` cancelado.
     *
     * # A conferência de geometria não é higiene
     *
     * Entregar a superfície do encoder para um pedido de outro tamanho seria alimentar um encoder
     * de 1920x1080 com quadro de outra geometria. `willNotProvideSurface` é a resposta honesta:
     * diz ao CameraX que não vamos atender, em vez de atender errado.
     */
    private fun aoPedirSuperficie(pedido: SurfaceRequest) {
        val jaEntregue = superficieDoCodificador
        if (jaEntregue == null) {
            // Primeira vez: quem espera é `ligarCodificador`, que ainda vai ler a fila.
            fila.offer(pedido)
            return
        }
        val esperada = resolucaoNegociada
        if (esperada != null && pedido.resolution != esperada) {
            Log.w(TAG, "pedido de superfície em ${pedido.resolution}, mas o encoder está em " +
                "$esperada — recusando em vez de entregar quadro do tamanho errado")
            pedido.willNotProvideSurface()
            return
        }
        Log.i(TAG, "pedido de superfície novo (${pedido.resolution}) — a câmera reabriu; " +
            "entregando a mesma superfície do encoder")
        pedidoDoCodificador = pedido
        pedido.provideSurface(jaEntregue, executor) { result ->
            Log.i(TAG, "SurfaceRequest (reentrega) liberado: código ${result.resultCode}")
        }
    }

    /**
     * Tira **só** o *use case* do codificador, voltando ao estado prévia-só. A câmera continua
     * aberta e a `PreviewView` continua recebendo imagem. Idempotente.
     *
     * Chame de uma thread de trabalho — espera o `unbind` na thread principal.
     */
    fun desligarCodificador() {
        val vc = videoCapture ?: return
        videoCapture = null
        pedidoDoCodificador = null
        val main = Handler(Looper.getMainLooper())
        val latch = CountDownLatch(1)
        main.post {
            runCatching { cameraProvider.unbind(vc) }
                .onFailure { Log.w(TAG, "unbind do VideoCapture falhou", it) }
            latch.countDown()
        }
        runCatching { latch.await(2, TimeUnit.SECONDS) }
    }

    /**
     * "O codificador terminou com esta fonte" — chamada por [H264CameraEncoder.pararFonte], e é
     * ela que carrega a diferença entre os dois donos possíveis da câmera.
     *
     * Com prévia persistente (espelhamento) só o *use case* do codificador sai: a pessoa continua
     * vendo o enquadramento enquanto o serviço volta a esperar outro receptor, que é o desenho que
     * o iOS já tem. Sem ela (instrumento de bancada) a fonte inteira acaba junto — que é
     * exatamente o que este caminho fazia antes de existirem duas fases.
     */
    fun soltarCodificador() {
        if (previaViva) desligarCodificador() else parar()
    }

    fun parar() {
        if (parado) return
        parado = true
        videoCapture = null
        pedidoDoCodificador = null
        superficieDoCodificador = null
        previaViva = false
        // A sessão saiu do ar: a prévia volta a poder ser ligada.
        PreviaDaCamera.transmissaoTerminou()
        val main = Handler(Looper.getMainLooper())
        val latch = CountDownLatch(1)
        main.post {
            // Antes do `unbindAll`, e na thread principal: solta a superfície da tela enquanto o
            // use case ainda está bindado. A câmera fechou, e quem estiver desenhando apaga a
            // imagem em vez de congelar a última — uma prévia congelada diria que o aparelho ainda
            // está filmando.
            runCatching { preview?.let { PreviaDaCamera.soltar(it) } }
            runCatching { cameraProvider.unbindAll() }
                .onFailure { Log.w(TAG, "unbindAll falhou", it) }
            latch.countDown()
        }
        runCatching { latch.await(2, TimeUnit.SECONDS) }
        handlerThread.quitSafely()
    }
}
