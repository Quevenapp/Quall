package com.quall.android.capture

import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.ColorSpaceTransform
import android.hardware.camera2.params.RggbChannelVector
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import com.quall.android.core.Idioma
import com.quall.android.core.Textos
import java.util.Locale
import kotlin.math.roundToInt

/**
 * **O que a câmera disse ter usado**, quadro a quadro (`docs/controles-de-camera.md` §3.6): o
 * `CaptureCallback` da sessão, instalado no `VideoCapture.Builder` pelo
 * `Camera2Interop.Extender.setSessionCaptureCallback` antes do bind (§6). Roda na thread da câmera a
 * cada quadro; só copia meia dúzia de campos para variáveis voláteis, que a tela e o [ControlesDaCamera]
 * leem quando querem.
 */
class LeitorDoResultado : CameraCaptureSession.CaptureCallback() {
    @Volatile var iso: Int? = null; private set
    @Volatile var exposicaoNs: Long? = null; private set
    @Volatile var duracaoDoQuadroNs: Long? = null; private set
    /** `COLOR_CORRECTION_GAINS` do resultado, RGGB. */
    @Volatile var ganhos: List<Double>? = null; private set
    @Volatile var focoDioptrias: Float? = null; private set
    @Volatile var abertura: Float? = null; private set
    @Volatile var estadoAe: Int? = null; private set
    @Volatile var estadoAwb: Int? = null; private set
    @Volatile var resultados = 0L; private set

    /** O AE / AWB passou por `CONVERGED` ou `LOCKED` desde a última [reiniciarConvergencia]. */
    @Volatile var aeConvergiu = false; private set
    @Volatile var awbConvergiu = false; private set

    fun reiniciarConvergencia() {
        aeConvergiu = false
        awbConvergiu = false
    }

    override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
        resultados++
        result.get(CaptureResult.SENSOR_SENSITIVITY)?.let { iso = it }
        result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let { exposicaoNs = it }
        result.get(CaptureResult.SENSOR_FRAME_DURATION)?.let { duracaoDoQuadroNs = it }
        result.get(CaptureResult.COLOR_CORRECTION_GAINS)?.let {
            ganhos = listOf(it.red.toDouble(), it.greenEven.toDouble(), it.greenOdd.toDouble(), it.blue.toDouble())
        }
        result.get(CaptureResult.LENS_FOCUS_DISTANCE)?.let { focoDioptrias = it }
        result.get(CaptureResult.LENS_APERTURE)?.let { abertura = it }
        val ae = result.get(CaptureResult.CONTROL_AE_STATE)
        val awb = result.get(CaptureResult.CONTROL_AWB_STATE)
        estadoAe = ae
        estadoAwb = awb
        if (ae == Camera2Valores.ESTADO_3A_CONVERGED || ae == Camera2Valores.ESTADO_3A_LOCKED) aeConvergiu = true
        if (awb == Camera2Valores.ESTADO_3A_CONVERGED || awb == Camera2Valores.ESTADO_3A_LOCKED) awbConvergiu = true
    }
}

/**
 * **Os controles de câmera do R9 no Android** (`docs/controles-de-camera.md`), pendurados no
 * [DonoDaCaptura] — o único caminho de produto; o `CameraXSource` é braço de bancada e fica fora.
 *
 * - **O registro** ([AjusteDaCamera]) vive em SharedPreferences `quall-camera-ajustes`, chave = o
 *   `cameraId`, valor = o JSON. A frontal tem um registro só, que vale para a câmera comum e para a R5.
 * - **As capacidades** são lidas uma vez por `Camera2CameraInfo` ([CapacidadesDaCamera]).
 * - **Um estado único reenvia tudo** (§6): `setCaptureRequestOptions` troca o conjunto inteiro
 *   (bytecode do 1.4.2), então cada envio leva o [RegrasDosControles.plano] inteiro. O EV vai à parte,
 *   pelo `setExposureCompensationIndex` do CameraX, e o toque pelo `startFocusAndMetering`.
 * - **Reaplica** na abertura ([aoAbrir], depois do bind) e no pedido de superfície novo depois de uma
 *   expulsão ([aoReabrir]; ali o CameraX perde o EV e o toque, e o interop não). Na abertura o
 *   `setCaptureRequestOptions` é chamado **sempre**, mesmo vazio (§2.2).
 * - **Devolve a câmera como encontrou** no fechar ([aoFechar]): `clearCaptureRequestOptions`, porque o
 *   CameraX guarda o interop por câmera durante o processo, e o que a R5 deixasse vazaria para o
 *   espelhamento comum.
 *
 * Tudo roda na thread principal (as chamadas do CameraX são assíncronas e devolvem futuros); o
 * [LeitorDoResultado] escreve da thread da câmera em variáveis voláteis.
 */
@androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
class ControlesDaCamera(
    contexto: Context,
    val cameraId: String,
    private val camera: Camera,
    val leitor: LeitorDoResultado,
    /** O fps negociado da sessão (`quadrosNegociados`, ou o pedido): o teto do obturador (§3.1). */
    private val fps: () -> Int,
    /** As características do `CameraManager`, só para as `availableCaptureRequestKeys`. */
    caracteristicas: CameraCharacteristics?,
) {
    companion object {
        private const val TAG = "QuallControles"
        const val PREFERENCIAS = "quall-camera-ajustes"

        /** O denominador das frações da matriz de correção (`ColorSpaceTransform` é de racionais). */
        private const val DENOMINADOR = 10_000

        /** Lê o registro guardado de [cameraId] ("meus ajustes"), ou o padrão. */
        fun lerRegistro(c: Context, cameraId: String): AjusteDaCamera =
            AjusteDaCamera.deJson(prefs(c).getString(cameraId, null)) ?: AjusteDaCamera()

        private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFERENCIAS, Context.MODE_PRIVATE)

        /** As capacidades da câmera, lidas por `Camera2CameraInfo` (e as chaves de pedido do `CameraManager`). */
        fun lerCapacidades(camera: Camera, chars: CameraCharacteristics?): CapacidadesDaCamera {
            val info = Camera2CameraInfo.from(camera.cameraInfo)
            fun <T> c(k: CameraCharacteristics.Key<T>): T? = runCatching { info.getCameraCharacteristic(k) }.getOrNull()
            val capas = c(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toSet().orEmpty()
            val iso = c(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
            val exp = c(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
            val ev = camera.cameraInfo.exposureState
            val passo = ev.exposureCompensationStep
            val afs = c(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)?.toSet().orEmpty()
            val focoMin = c(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
            val calib = c(CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION)
            val chavesDePedido = runCatching { chars?.availableCaptureRequestKeys?.map { it.name }?.toSet() }.getOrNull().orEmpty()
            val chavesDeResultado = runCatching { chars?.availableCaptureResultKeys?.map { it.name }?.toSet() }.getOrNull().orEmpty()
            fun matriz(t: ColorSpaceTransform?): DoubleArray? = t?.let { m ->
                DoubleArray(9) { k -> m.getElement(k % 3, k / 3).toDouble() }
            }
            val calibracao = KelvinDng.Calibracao.de(
                c(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT1),
                matriz(c(CameraCharacteristics.SENSOR_COLOR_TRANSFORM1)),
                matriz(c(CameraCharacteristics.SENSOR_FORWARD_MATRIX1)),
                c(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT2)?.toInt(),
                matriz(c(CameraCharacteristics.SENSOR_COLOR_TRANSFORM2)),
                matriz(c(CameraCharacteristics.SENSOR_FORWARD_MATRIX2)),
            )
            return CapacidadesDaCamera(
                manualSensor = CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR in capas,
                manualPosProcessamento = CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING in capas,
                leSensor = CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_READ_SENSOR_SETTINGS in capas,
                isoMin = iso?.lower ?: 0,
                isoMax = iso?.upper ?: 0,
                isoMaxAnalogico = c(CameraCharacteristics.SENSOR_MAX_ANALOG_SENSITIVITY),
                exposicaoMinNs = exp?.lower ?: 0L,
                exposicaoMaxNs = exp?.upper ?: 0L,
                evIndiceMin = if (ev.isExposureCompensationSupported) ev.exposureCompensationRange.lower else 0,
                evIndiceMax = if (ev.isExposureCompensationSupported) ev.exposureCompensationRange.upper else 0,
                evPassoNum = passo.numerator.coerceAtLeast(0),
                evPassoDen = passo.denominator.coerceAtLeast(1),
                modosDeBalanco = c(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)?.toSet().orEmpty(),
                modosAntiCintilacao = c(CameraCharacteristics.CONTROL_AE_AVAILABLE_ANTIBANDING_MODES)?.toSet().orEmpty(),
                travaAe = c(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true,
                travaAwb = c(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true,
                temAf = focoMin > 0f && afs.any { it != CameraCharacteristics.CONTROL_AF_MODE_OFF && it != CameraCharacteristics.CONTROL_AF_MODE_EDOF },
                focoMinimoDioptrias = focoMin,
                focoNaRequisicao = CaptureRequest.LENS_FOCUS_DISTANCE.name in chavesDePedido,
                focoLido = CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_READ_SENSOR_SETTINGS in capas &&
                    CaptureResult.LENS_FOCUS_DISTANCE.name in chavesDeResultado,
                focoCalibrado = calib == CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_APPROXIMATE ||
                    calib == CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_CALIBRATED,
                abertura = c(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)?.firstOrNull(),
                calibracao = calibracao,
                regioesAe = c(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0,
                regioesAf = c(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0,
                regioesAwb = c(CameraCharacteristics.CONTROL_MAX_REGIONS_AWB) ?: 0,
            )
        }
    }

    private val app = contexto.applicationContext
    private val principal = Handler(Looper.getMainLooper())
    private val interop = Camera2CameraControl.from(camera.cameraControl)

    val capacidades: CapacidadesDaCamera = lerCapacidades(camera, caracteristicas)

    /**
     * O registro que vale agora (a tela mostra o aplicado, em [planoAtual]). **Abre no automático**
     * ([RegrasDosControles.MeusAjustes]): o guardado não é reaplicado, fica em [meusAjustes].
     */
    @Volatile var ajuste: AjusteDaCamera = RegrasDosControles.MeusAjustes.naAbertura()
        private set

    /** O último manual guardado desta câmera ("Usar meus ajustes"), ou `null`. */
    @Volatile var meusAjustes: AjusteDaCamera? = lerRegistro(app, cameraId).takeUnless { it.ehPadrao }
        private set

    /** O painel oferece "Usar meus ajustes"? */
    val ofereceMeusAjustes: Boolean get() = RegrasDosControles.MeusAjustes.ofereceMeusAjustes(meusAjustes, ajuste)

    /** "Usar meus ajustes": o último manual volta pelo mesmo caminho de um gesto do painel. */
    fun usarMeusAjustes() {
        val lembrado = meusAjustes ?: return
        editar("usar meus ajustes") { lembrado } // i18n-fora: motivo do diário
    }

    /** O último plano enviado: o que de fato foi à câmera, já cortado. */
    @Volatile var planoAtual: RegrasDosControles.Plano? = null
        private set

    /**
     * As travas da pílula do toque longo à vista (§4.4), ou `null` sem pílula. O dado, e não a frase: a
     * frase sai no idioma de quem desenha ([pilula]; `docs/traducao.md`, Android).
     */
    @Volatile var travasDaPilula: RegrasDosControles.TravasDoToque? = null
        private set
    private var travasDoToque: RegrasDosControles.TravasDoToque? = null

    /** A pílula do toque longo à vista, no idioma do app agora, ou `null`. */
    val pilula: String? get() = travasDaPilula?.let { RegrasDosControles.pilulaDoToqueLongo(textos(), it) }

    /** "Travado de novo depois de medir a cena." à vista, por 3 s (§2.1), e até quando. */
    @Volatile var avisoTravadoDeNovo = false
        private set
    @Volatile private var avisoAte = 0L

    /** O aviso de [avisoTravadoDeNovo] na língua de [t], senão o da pouca luz, ou `null`. */
    fun aviso(t: Textos): String? = if (avisoTravadoDeNovo) RegrasDosControles.textoTravadoDeNovo(t) else poucaLuz(t)

    /**
     * O fps a que a pouca luz levou o automático, enquanto o [vigiaPoucaLuz] estiver aceso (§3.1), ou
     * `null`. A faixa variável é pedida pelo [DonoDaCaptura] (`RegrasDosControles.pisoDoAutomatico`).
     */
    @Volatile var fpsDaPoucaLuz: Int? = null
        private set
    private val vigiaPoucaLuz = RegrasDosControles.VigiaDaPoucaLuz()

    /** "Pouca luz: 15 fps…" na língua de [t], ou `null` com luz bastante ou exposição manual. */
    fun poucaLuz(t: Textos = textos()): String? = fpsDaPoucaLuz?.let { RegrasDosControles.textoDaPoucaLuz(t, it, fps(), capacidades.exposicaoManual) }

    /** Os textos no idioma escolhido, pedidos na hora (o usuário pode trocar de idioma com a câmera aberta). */
    private fun textos(): Textos = Idioma.textos(Idioma.contexto(app))

    @Volatile private var fechado = false
    private var aberturaEm = 0L
    private var focoNoCentroFeito = false
    private var chavesEnviadas: Map<RegrasDosControles.Chave, Any>? = null
    private val cadencia = RegrasDosControles.Cadencia()
    private var envioAgendado = false
    private var esperandoConvergir = false
    private val vigiaIso = RegrasDosControles.VigiaDaDivergencia()
    private val vigiaObturador = RegrasDosControles.VigiaDaDivergencia()
    private val vigiaKelvin = RegrasDosControles.VigiaDaDivergencia()

    init {
        Log.i(TAG, "r9: câmera $cameraId: ${resumoDasCapacidades()}; abre no automático; " +
            "meus ajustes ${meusAjustes?.paraJson() ?: "nenhum"}") // i18n-fora: diário
    }

    fun resumoDasCapacidades(): String = with(capacidades) {
        "manual_sensor=$manualSensor pos_processamento=$manualPosProcessamento le_sensor=$leSensor " +
            "iso=$isoMin..$isoMax (analógico até ${isoMaxAnalogico ?: "?"}) exposicao=${exposicaoMinNs}..${exposicaoMaxNs}ns " + // i18n-fora: diário (o resumo das capacidades)
            "ev=$evIndiceMin..$evIndiceMax passo=$evPassoNum/$evPassoDen awb=${modosDeBalanco.sorted()} " +
            "anti=${modosAntiCintilacao.sorted()} trava_ae=$travaAe trava_awb=$travaAwb af=$temAf " +
            "foco_min=${focoMinimoDioptrias}dpt foco_manual=$focoManual foco_lido=$focoLido calibrado=$focoCalibrado " +
            "kelvin=$kelvin (calibração ${if (calibracao != null) "${calibracao.temperatura1.toInt()}/${calibracao.temperatura2.toInt()} K" else "ausente"}) " + // i18n-fora: diário (o resumo das capacidades)
            "regioes=$regioesAe/$regioesAf/$regioesAwb"
    }

    // --- o ciclo da câmera -------------------------------------------------------------------------

    /** A câmera abriu (depois do bind): aplica o registro inteiro, com o interop **sempre**. */
    fun aoAbrir() = principal.post {
        if (fechado) return@post
        aberturaEm = SystemClock.elapsedRealtime()
        leitor.reiniciarConvergencia()
        focoNoCentroFeito = false
        chavesEnviadas = null
        enviar("abertura", sempre = true)
        // O controle remoto (R9b): as capacidades e o registro ao filmador, e o tique do lido.
        FilmadorDaCamera.cameraAbriu(app, this)
        principal.removeCallbacks(tiqueRemoto)
        principal.post(tiqueRemoto)
    }

    /**
     * Um pedido de superfície novo depois de uma expulsão (o desbloqueio por rosto do S24): o CameraX
     * reabriu a câmera, perdeu o EV e o ponto de toque, e manteve o interop. Reaplica tudo, e a trava
     * sem manual espera o 3A de novo.
     */
    fun aoReabrir() = principal.post {
        if (fechado) return@post
        aberturaEm = SystemClock.elapsedRealtime()
        leitor.reiniciarConvergencia()
        focoNoCentroFeito = false
        travasDoToque = null
        travasDaPilula = null
        chavesEnviadas = null
        enviar("reabertura", sempre = true)
    }

    /** Antes do `unbind`, na principal: devolve a câmera como encontrou (§2.2). */
    fun aoFechar() {
        fechado = true
        principal.removeCallbacksAndMessages(null)
        // A gravação adiada de um ajuste remoto não se perde no fechar (R9b, §6).
        if (gravacaoPendente) guardar()
        FilmadorDaCamera.cameraFechou(this)
        runCatching { interop.clearCaptureRequestOptions() }.onFailure { Log.w(TAG, "r9: clearCaptureRequestOptions: ${Log.erroExterno(it.message)}") }
        Log.i(TAG, "r9: câmera $cameraId fechada; interop limpo")
    }

    /** O fps negociado agora (a escala do obturador da tela, §3.1). */
    fun fpsAgora(): Int = fps()

    // --- o que a tela pede -------------------------------------------------------------------------

    /** Muda o registro, guarda e envia (agrupado a 15 por segundo; o último valor vence). Na principal. */
    fun editar(motivo: String, f: (AjusteDaCamera) -> AjusteDaCamera) {
        val antes = ajuste
        val novo = f(antes)
        if (novo == antes) return
        ajuste = novo
        // Desligar uma trava pelo painel também tira a pílula (§4.4).
        if ((antes.travaExposicao && !novo.travaExposicao) || (antes.foco == AjusteDaCamera.Foco.TRAVADO && novo.foco != AjusteDaCamera.Foco.TRAVADO)) {
            travasDaPilula = null
            travasDoToque = null
        }
        registroMudou()
        pedirEnvio(motivo)
    }

    /**
     * O registro mudou: guarda, e marca para os receptores (R9b). A mudança **daqui** sai no próximo
     * [enviar], no ritmo da [cadencia] (15 por segundo): um deslizante arrastado não vira um estado inteiro
     * para cada receptor a cada `onProgressChanged`. A que veio **de fora** grava adiada, e quem a aplicou
     * responde ao núcleo com o `n` do pedido. Qualquer mudança cancela a trava pendente do toque longo,
     * que reescreveria as travas por cima dela.
     */
    private fun registroMudou() {
        cancelarTravaDoToque()
        if (deFora) {
            guardarAdiado()
        } else {
            guardar()
            localPorPublicar = true
        }
    }

    /** Há mudança daqui ainda não publicada aos receptores (sai no próximo [enviar]). */
    private var localPorPublicar = false

    /** O segundo passo do toque longo, à espera de a câmera convergir. */
    private var travaDoToque: Runnable? = null

    private fun cancelarTravaDoToque() {
        travaDoToque?.let { principal.removeCallbacks(it) }
        travaDoToque = null
    }

    /** Publica já a mudança daqui que esperava a cadência (antes de um pedido remoto, que vem depois dela). */
    private fun publicarLocal() {
        if (!localPorPublicar) return
        localPorPublicar = false
        FilmadorDaCamera.mudouAqui(this)
    }

    /** Liga ou desliga a trava de exposição, gravando o ISO e o tempo lidos agora (§2.1). */
    fun travarExposicao(ligar: Boolean) = editar("trava de exposição") { a -> // i18n-fora: motivo do diário
        if (ligar) RegrasDosControles.comValoresDaTrava(a.copy(travaExposicao = true, travaIso = null, travaObturadorNs = null),
            isoLido(), exposicaoLida(), null, null)
        else a.copy(travaExposicao = false, travaIso = null, travaObturadorNs = null)
    }

    /** Liga ou desliga a trava de balanço, gravando os ganhos lidos agora (com `MANUAL_POST_PROCESSING`). */
    fun travarBalanco(ligar: Boolean) = editar("trava de balanço") { a -> // i18n-fora: motivo do diário
        if (ligar) RegrasDosControles.comValoresDaTrava(a.copy(travaBalanco = true, travaGanhos = null), null, null,
            leitor.ganhos.takeIf { capacidades.manualPosProcessamento }, null)
        else a.copy(travaBalanco = false, travaGanhos = null)
    }

    /** O foco: auto, travado (com a posição lida) ou manual (partindo da lida). */
    fun focar(modo: AjusteDaCamera.Foco) = editar("foco") { a ->
        val lida = posicaoLida()
        when (modo) {
            AjusteDaCamera.Foco.AUTO -> a.copy(foco = modo)
            AjusteDaCamera.Foco.TRAVADO -> a.copy(foco = modo, focoPosicao = lida)
            AjusteDaCamera.Foco.MANUAL -> a.copy(foco = modo, focoPosicao = a.focoPosicao ?: lida ?: 0.0)
        }
    }.also { if (modo == AjusteDaCamera.Foco.TRAVADO) focoNoCentroFeito = false }

    /** "Passar para Manual": ISO e obturador partem dos valores lidos neste instante (§4.3). */
    fun passarParaManual() = editar("passar para manual") { a ->
        RegrasDosControles.passarParaManual(a, isoLido(), exposicaoLida(), capacidades, fps())
    }

    /** O balanço: Kelvin parte do estimado agora (§2); os presets e o auto, direto. */
    fun balancear(b: AjusteDaCamera.Balanco) = editar("balanço") { a -> // i18n-fora: motivo do diário
        if (b == AjusteDaCamera.Balanco.KELVIN) {
            a.copy(balanco = b, kelvin = a.kelvin ?: kelvinLido()?.let { EscalasDaCamera.cortarKelvin(it) } ?: 5500,
                travaBalanco = false, travaGanhos = null)
        } else {
            a.copy(balanco = b, travaBalanco = if (b == AjusteDaCamera.Balanco.AUTO) a.travaBalanco else false,
                travaGanhos = if (b == AjusteDaCamera.Balanco.AUTO) a.travaGanhos else null)
        }
    }

    /** "Restaurar automático": o registro volta ao padrão, e o ponto do toque ao centro (§4.3, §4.4). */
    fun restaurar() {
        ajuste = AjusteDaCamera()
        travasDaPilula = null
        travasDoToque = null
        registroMudou()
        runCatching { camera.cameraControl.cancelFocusAndMetering() }
        focoNoCentroFeito = false
        pedirEnvio("restaurar automático") // i18n-fora: motivo do diário
    }

    /** Troca o registro inteiro (a porta de bancada do roteiro de prova). */
    fun substituir(novo: AjusteDaCamera, motivo: String) = editar(motivo) { novo }

    /**
     * **O toque na prévia** (§4.4), com o ponto já no referencial do buffer ([CaminhoDoToque]).
     * Devolve `false` quando nada se mede (os dois em manual): a tela não mostra o quadrado.
     */
    fun tocar(bx: Double, by: Double, longo: Boolean): Boolean {
        if (fechado) return false
        cancelarTravaDoToque()
        var a = ajuste
        // Um toque simples depois do longo desfaz as duas travas; o longo também parte destravado.
        travasDoToque?.let { a = RegrasDosControles.aposToqueSimplesQueDestrava(a, it) }
        travasDoToque = null
        travasDaPilula = null
        val travas = if (longo) RegrasDosControles.travasDoToqueLongo(a, capacidades) else null
        if (travas != null) {
            if (travas.exposicao) a = a.copy(travaExposicao = false, travaIso = null, travaObturadorNs = null)
            if (travas.foco) a = a.copy(foco = AjusteDaCamera.Foco.AUTO)
        }
        val medidas = RegrasDosControles.medidasDoToque(a, capacidades)
        if (a != ajuste) {
            ajuste = a
            registroMudou()
            enviar("toque", sempre = false)
        }
        if (medidas.isEmpty()) return false
        var flags = 0
        if (RegrasDosControles.Medida.AF in medidas) flags = flags or FocusMeteringAction.FLAG_AF
        if (RegrasDosControles.Medida.AE in medidas) flags = flags or FocusMeteringAction.FLAG_AE
        if (RegrasDosControles.Medida.AWB in medidas) flags = flags or FocusMeteringAction.FLAG_AWB
        val ponto = SurfaceOrientedMeteringPointFactory(1f, 1f).createPoint(bx.toFloat(), by.toFloat())
        // Sem o cancelamento automático: o padrão do CameraX volta ao centro em 5 s.
        val acao = FocusMeteringAction.Builder(ponto, flags).disableAutoCancel().build()
        leitor.reiniciarConvergencia()
        val futuro = runCatching { camera.cameraControl.startFocusAndMetering(acao) }.getOrNull()
        Log.i(TAG, String.format(Locale.ROOT, "r9: toque %s em (%.3f, %.3f) do buffer, medidas %s",
            if (longo) "longo" else "simples", bx, by, medidas))
        if (travas?.alguma == true) {
            // A trava depois de convergir no ponto novo, com os valores lidos (§2.1).
            focoNoCentroFeito = true
            val inicio = SystemClock.elapsedRealtime()
            val travar = object : Runnable {
                override fun run() {
                    if (fechado || travaDoToque !== this) return
                    val pronto = futuro?.isDone != false && (leitor.aeConvergiu || !travas.exposicao)
                    if (!pronto && SystemClock.elapsedRealtime() - inicio < RegrasDosControles.ESPERA_DO_3A_MS) {
                        principal.postDelayed(this, 100)
                        return
                    }
                    travaDoToque = null
                    val comTravas = RegrasDosControles.aposToqueLongo(ajuste, travas)
                    ajuste = RegrasDosControles.comValoresDaTrava(comTravas, isoLido(), exposicaoLida(), null, posicaoLida())
                    travasDoToque = travas
                    travasDaPilula = travas.takeIf { it.alguma }
                    guardar()
                    // As travas do toque longo são de quem tocou (contrato §4): saem como mudança daqui,
                    // com dono, e não como escrita da casca — um reenvio velho de um receptor não as desfaz.
                    localPorPublicar = true
                    enviar("toque longo", sempre = false)
                }
            }
            travaDoToque = travar
            principal.postDelayed(travar, 100)
        }
        return true
    }

    // --- a leitura de volta (§3.6) -----------------------------------------------------------------

    data class Leitura(val linha: String, val divergencia: String?)

    fun isoLido(): Int? = leitor.iso.takeIf { capacidades.leSensor }
    fun exposicaoLida(): Long? = leitor.exposicaoNs.takeIf { capacidades.leSensor }
    /** A posição do foco lida, só onde ela é de confiar ([CapacidadesDaCamera.focoLido]). */
    fun posicaoLida(): Double? = leitor.focoDioptrias?.takeIf { capacidades.focoLido }
        ?.let { EscalasDaCamera.posicaoDoFoco(it, capacidades.focoMinimoDioptrias) }
    fun kelvinLido(): Int? {
        val cal = capacidades.calibracao ?: return null
        val g = leitor.ganhos ?: return null
        return KelvinDng.kelvinDosGanhos(cal, g.toDoubleArray())?.let { (it / 100.0).roundToInt() * 100 }
    }

    /** A linha do alto do painel e, nos modos manuais e no Kelvin, a divergência que já dura 2 s. */
    fun leitura(t: Textos = textos()): Leitura {
        val iso = isoLido()
        val exp = exposicaoLida()
        val k = kelvinLido()
        val linha = EscalasDaCamera.linhaDeLeitura(t, iso, exp, k, leitor.abertura ?: capacidades.abertura)
        val p = planoAtual
        val agora = SystemClock.elapsedRealtime()
        var div: String? = null
        val divergentes = ArrayList<String>(3)
        val pedidoIso = p?.isoAplicado
        if (vigiaIso.observar(agora, pedidoIso != null && iso != null && RegrasDosControles.divergeEmStops(pedidoIso.toDouble(), iso.toDouble()))) {
            div = EscalasDaCamera.textoDaDivergencia(t, EscalasDaCamera.textoDoIso(iso!!), EscalasDaCamera.textoDoIso(pedidoIso!!))
            divergentes.add("iso")
        }
        val pedidoObt = p?.obturadorAplicadoNs
        if (vigiaObturador.observar(agora, pedidoObt != null && exp != null && RegrasDosControles.divergeEmStops(pedidoObt.toDouble(), exp.toDouble()))) {
            if (div == null) div = EscalasDaCamera.textoDaDivergencia(t, EscalasDaCamera.textoDoObturador(t, exp!!), EscalasDaCamera.textoDoObturador(t, pedidoObt!!))
            divergentes.add("obturadorNs")
        }
        val pedidoK = p?.kelvinAplicado
        if (vigiaKelvin.observar(agora, pedidoK != null && k != null && RegrasDosControles.divergeEmKelvin(pedidoK, k))) {
            if (div == null) div = EscalasDaCamera.textoDaDivergencia(t, EscalasDaCamera.textoDoKelvin(k!!), EscalasDaCamera.textoDoKelvin(pedidoK!!))
            divergentes.add("kelvin")
        }
        ultimosDivergentes = divergentes
        if (avisoTravadoDeNovo && agora > avisoAte) avisoTravadoDeNovo = false
        val auto = ajuste.exposicao == AjusteDaCamera.Exposicao.AUTO
        val antes = fpsDaPoucaLuz
        fpsDaPoucaLuz = vigiaPoucaLuz.observar(agora, auto, leitor.duracaoDoQuadroNs ?: leitor.exposicaoNs, fps())
        if ((antes == null) != (fpsDaPoucaLuz == null)) {
            Log.i(TAG, "r9: pouca luz ${if (fpsDaPoucaLuz != null) "acesa: ${fpsDaPoucaLuz} fps" else "apagada"}; " +
                "quadro=${leitor.duracaoDoQuadroNs}ns exposicao=${leitor.exposicaoNs}ns iso=${leitor.iso}") // i18n-fora: diário
        }
        return Leitura(linha, div)
    }

    /** Os campos da última [leitura] em que a divergência já dura 2 s (o `divergentes` do lido, R9b). */
    @Volatile private var ultimosDivergentes: List<String> = emptyList()

    // --- o controle remoto (R9b, `docs/controle-remoto-da-camera.md`) --------------------------------

    /** O resultado de um pedido remoto: o registro que ficou valendo, ou o código da recusa. */
    sealed class ResultadoRemoto {
        data class Aplicado(val registro: String) : ResultadoRemoto()
        data class Recusado(val motivo: String) : ResultadoRemoto()
    }

    /** O que está sendo aplicado veio de um receptor: não avisa o filmador de "mudança local". */
    private var deFora = false
    private var gravacaoPendente = false
    private val gravar = Runnable {
        gravacaoPendente = false
        guardar()
    }

    /** As capacidades do contrato §3.2, com o teto do obturador do fps de agora. */
    fun capacidadesRemotas(): String = CapacidadesRemotas.json(capacidades, fps(), nomeDaCamera)

    /** O nome da câmera para os receptores ("Frontal", "Traseira"), posto pelo [DonoDaCaptura]. */
    @Volatile var nomeDaCamera: String? = null

    /**
     * O tique do lido (R9b, §3.3): 4 por segundo, enquanto a câmera está aberta. A [leitura] também
     * alimenta os vigias da divergência, os mesmos da linha do painel.
     */
    private val tiqueRemoto = object : Runnable {
        override fun run() {
            if (fechado) return
            leitura()
            val lido = RegrasDoPedidoRemoto.lidoJson(isoLido(), exposicaoLida(), kelvinLido(),
                leitor.abertura ?: capacidades.abertura, posicaoLida(), ultimosDivergentes)
            FilmadorDaCamera.tique(this@ControlesDaCamera, lido)
            principal.postDelayed(this, RegrasDosControles.INTERVALO_DA_LEITURA_MS)
        }
    }

    /**
     * **Um pedido de um receptor** (contrato §6), na principal — a fila serial de tudo o que muda o
     * registro. O toque é convertido **antes** de qualquer mudança (um toque na tarja recusa o pedido
     * inteiro com `fora_da_imagem`, sem aplicar metade); depois, o ajuste na ordem do §6
     * ([RegrasDoPedidoRemoto]), e o toque por último. A gravação vai adiada 500 ms (um deslizante remoto
     * a 15 por segundo não vira 15 trocas de arquivo por segundo).
     */
    fun aplicarPedidoRemoto(p: PedidoRemoto, saida: FilmadorDaCamera.SaidaDaRede?): ResultadoRemoto {
        if (fechado) return ResultadoRemoto.Recusado("nao_aplicado")
        val ponto = p.toque?.let { t ->
            val s = saida ?: return ResultadoRemoto.Recusado("nao_aplicado")
            when (val r = tocarPelaRede?.invoke(t.x, t.y, s)) {
                null -> return ResultadoRemoto.Recusado("nao_aplicado")
                PontoDaRede.ForaDaImagem -> return ResultadoRemoto.Recusado("fora_da_imagem")
                is PontoDaRede.NoBuffer -> r
            }
        }
        // A mudança daqui que esperava a cadência veio antes deste pedido: sai antes, com o dono dela.
        publicarLocal()
        val lidos = RegrasDoPedidoRemoto.Lidos(isoLido(), exposicaoLida(), leitor.ganhos, posicaoLida(), kelvinLido())
        val novo = RegrasDoPedidoRemoto.aplicar(ajuste, p, lidos, capacidades, fps())
            ?: return ResultadoRemoto.Recusado("nao_aplicado")
        val antes = ajuste
        deFora = true
        try {
            if (p.restaurar) restaurar()
            if (novo != ajuste) editar("pedido remoto ${p.n}") { novo } // i18n-fora: motivo do diário
            // Os efeitos das ações do painel que o registro sozinho não traz: o foco travado sem manual
            // refaz o AF no centro, e uma trava ligada junto com a troca de modo espera a câmera convergir.
            if (novo.foco == AjusteDaCamera.Foco.TRAVADO && antes.foco != AjusteDaCamera.Foco.TRAVADO) focoNoCentroFeito = false
            if ((novo.travaExposicao && novo.travaIso == null && !antes.travaExposicao) ||
                (novo.travaBalanco && novo.travaGanhos == null && !antes.travaBalanco)) {
                leitor.reiniciarConvergencia()
                aberturaEm = SystemClock.elapsedRealtime()
            }
            ponto?.let { tocar(it.x, it.y, p.toque!!.longo) }
        } finally {
            deFora = false
        }
        Log.i(TAG, "r9b: pedido ${p.n} restaurar=${p.restaurar} toque=${p.toque}; registro ${ajuste.paraJson()}")
        return ResultadoRemoto.Aplicado(ajuste.paraJson())
    }

    /** Onde cai um toque da rede: no buffer (normalizado), ou numa tarja. */
    sealed class PontoDaRede {
        data class NoBuffer(val x: Double, val y: Double) : PontoDaRede()
        object ForaDaImagem : PontoDaRede()
    }

    /**
     * Do quadro da rede ao buffer da câmera: o [DonoDaCaptura] sabe a geometria (a matriz da câmera, a
     * rotação). `null` = ainda sem quadro.
     */
    @Volatile var tocarPelaRede: ((Double, Double, FilmadorDaCamera.SaidaDaRede) -> PontoDaRede?)? = null

    private fun guardarAdiado() {
        gravacaoPendente = true
        principal.removeCallbacks(gravar)
        principal.postDelayed(gravar, 500)
    }

    // --- o envio -----------------------------------------------------------------------------------

    /** Grava só um registro diferente do padrão: voltar ao automático não apaga "meus ajustes". */
    private fun guardar() {
        val a = RegrasDosControles.MeusAjustes.aGravar(ajuste) ?: return
        meusAjustes = a
        prefs(app).edit().putString(cameraId, a.paraJson()).apply()
    }

    private fun pedirEnvio(motivo: String) {
        if (envioAgendado || fechado) return
        val atraso = cadencia.atraso(SystemClock.elapsedRealtime())
        envioAgendado = true
        principal.postDelayed({
            envioAgendado = false
            enviar(motivo, sempre = false)
        }, atraso)
    }

    private fun momento(): RegrasDosControles.Momento {
        val passou = SystemClock.elapsedRealtime() - aberturaEm >= RegrasDosControles.ESPERA_DO_3A_MS
        return RegrasDosControles.Momento(fps(), aeConvergiu = leitor.aeConvergiu || passou, awbConvergiu = leitor.awbConvergiu || passou)
    }

    /**
     * Envia o plano do registro de agora. O interop só é reenviado quando muda (cada chamada reenvia
     * o pedido repetido), salvo com [sempre] (a abertura).
     */
    private fun enviar(motivo: String, sempre: Boolean) {
        if (fechado) return
        cadencia.enviou(SystemClock.elapsedRealtime())
        publicarLocal()
        val anterior = planoAtual
        val p = RegrasDosControles.plano(ajuste, capacidades, momento())
        planoAtual = p
        if (sempre || p.chaves != chavesEnviadas) {
            val b = CaptureRequestOptions.Builder()
            for ((k, v) in p.chaves) opcao(b, k, v)
            runCatching { interop.setCaptureRequestOptions(b.build()) }
                .onFailure { Log.w(TAG, "r9: setCaptureRequestOptions: ${Log.erroExterno(it.message)}") }
            chavesEnviadas = p.chaves
        }
        p.indiceDoEv?.let { i ->
            if (camera.cameraInfo.exposureState.exposureCompensationIndex != i) {
                runCatching { camera.cameraControl.setExposureCompensationIndex(i) }
            }
        }
        if (p.travarFocoNoCentro && !focoNoCentroFeito) {
            // A trava de foco sem MANUAL_SENSOR: um AF no centro, sem cancelamento (§4.5).
            focoNoCentroFeito = true
            val centro = SurfaceOrientedMeteringPointFactory(1f, 1f).createPoint(0.5f, 0.5f)
            runCatching {
                camera.cameraControl.startFocusAndMetering(
                    FocusMeteringAction.Builder(centro, FocusMeteringAction.FLAG_AF).disableAutoCancel().build())
            }
        }
        // A trava sem manual que esperava o 3A foi agora: a tela diz por 3 s.
        if ((anterior?.esperandoAe == true && !p.esperandoAe) || (anterior?.esperandoAwb == true && !p.esperandoAwb)) {
            avisoTravadoDeNovo = true
            avisoAte = SystemClock.elapsedRealtime() + 3_000
        }
        if ((p.esperandoAe || p.esperandoAwb) && !esperandoConvergir) {
            esperandoConvergir = true
            principal.postDelayed(object : Runnable {
                override fun run() {
                    val m = momento()
                    if (fechado) return
                    if ((planoAtual?.esperandoAe == true && !m.aeConvergiu) || (planoAtual?.esperandoAwb == true && !m.awbConvergiu)) {
                        principal.postDelayed(this, 100)
                        return
                    }
                    esperandoConvergir = false
                    enviar("o 3A convergiu", sempre = false)
                }
            }, 100)
        }
        Log.i(TAG, "r9: aplicado ($motivo) na câmera $cameraId a ${fps()} fps: interop ${descrever(p.chaves)}, " +
            "ev_indice=${p.indiceDoEv ?: "-"}, foco_no_centro=${p.travarFocoNoCentro}, " +
            "esperando_ae=${p.esperandoAe} esperando_awb=${p.esperandoAwb}; registro ${ajuste.paraJson()}")
        // A leitura de volta 1 s depois, para o diário (o roteiro de prova a lê).
        principal.postDelayed({ if (!fechado) Log.i(TAG, "r9: lido depois de aplicar ($motivo): ${descreverLeitura()}") }, 1_000)
    }

    fun descreverLeitura(): String {
        val l = leitor
        return String.format(Locale.ROOT, "iso=%s exposicao_ns=%s quadro_ns=%s ganhos=%s foco_dpt=%s kelvin=%s ae=%s awb=%s ev_indice=%d",
            l.iso, l.exposicaoNs, l.duracaoDoQuadroNs,
            l.ganhos?.joinToString(",") { String.format(Locale.ROOT, "%.4f", it) }, l.focoDioptrias, kelvinLido(),
            l.estadoAe, l.estadoAwb, camera.cameraInfo.exposureState.exposureCompensationIndex)
    }

    private fun descrever(chaves: Map<RegrasDosControles.Chave, Any>): String =
        if (chaves.isEmpty()) "{}" else chaves.entries.joinToString(", ", "{", "}") { (k, v) ->
            val txt = when (v) {
                is List<*> -> v.joinToString(",", "[", "]") { String.format(Locale.ROOT, "%.4f", it as Double) }
                else -> v.toString()
            }
            "${k.name.lowercase()}=$txt"
        }

    private fun opcao(b: CaptureRequestOptions.Builder, k: RegrasDosControles.Chave, v: Any) {
        when (k) {
            RegrasDosControles.Chave.CONTROL_AE_MODE -> b.setCaptureRequestOption(CaptureRequest.CONTROL_AE_MODE, v as Int)
            RegrasDosControles.Chave.SENSOR_SENSITIVITY -> b.setCaptureRequestOption(CaptureRequest.SENSOR_SENSITIVITY, v as Int)
            RegrasDosControles.Chave.SENSOR_EXPOSURE_TIME -> b.setCaptureRequestOption(CaptureRequest.SENSOR_EXPOSURE_TIME, v as Long)
            RegrasDosControles.Chave.SENSOR_FRAME_DURATION -> b.setCaptureRequestOption(CaptureRequest.SENSOR_FRAME_DURATION, v as Long)
            RegrasDosControles.Chave.CONTROL_AE_LOCK -> b.setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, v as Boolean)
            RegrasDosControles.Chave.CONTROL_AE_ANTIBANDING_MODE -> b.setCaptureRequestOption(CaptureRequest.CONTROL_AE_ANTIBANDING_MODE, v as Int)
            RegrasDosControles.Chave.CONTROL_AWB_MODE -> b.setCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE, v as Int)
            RegrasDosControles.Chave.COLOR_CORRECTION_MODE -> b.setCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_MODE, v as Int)
            RegrasDosControles.Chave.COLOR_CORRECTION_GAINS -> {
                @Suppress("UNCHECKED_CAST") val g = v as List<Double>
                b.setCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_GAINS,
                    RggbChannelVector(g[0].toFloat(), g[1].toFloat(), g[2].toFloat(), g[3].toFloat()))
            }
            RegrasDosControles.Chave.COLOR_CORRECTION_TRANSFORM -> {
                @Suppress("UNCHECKED_CAST") val m = v as List<Double>
                val elementos = IntArray(18)
                for (i in 0 until 9) {
                    elementos[2 * i] = Math.round(m[i] * DENOMINADOR).toInt()
                    elementos[2 * i + 1] = DENOMINADOR
                }
                b.setCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_TRANSFORM, ColorSpaceTransform(elementos))
            }
            RegrasDosControles.Chave.CONTROL_AWB_LOCK -> b.setCaptureRequestOption(CaptureRequest.CONTROL_AWB_LOCK, v as Boolean)
            RegrasDosControles.Chave.CONTROL_AF_MODE -> b.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, v as Int)
            RegrasDosControles.Chave.LENS_FOCUS_DISTANCE -> b.setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, v as Float)
        }
    }
}
