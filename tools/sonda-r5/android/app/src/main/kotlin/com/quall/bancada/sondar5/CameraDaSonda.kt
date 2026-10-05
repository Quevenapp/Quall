package com.quall.bancada.sondar5

import android.annotation.SuppressLint
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Size
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.MirrorMode
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.UseCase
import androidx.camera.core.impl.ConstantObservable
import androidx.camera.core.impl.Observable
import androidx.camera.core.impl.Timebase
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.MediaSpec
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoOutput
import org.json.JSONArray
import java.util.concurrent.TimeUnit

/**
 * O `VideoOutput` da sonda: entrega o pedido de superfície a quem chamou, **com o timebase** que o
 * `VideoCapture` declara. `UPTIME` quer dizer que o CameraX pôs um nó GL dele no caminho (o
 * carimbo deixa de ser o do sensor); `REALTIME` é o carimbo da câmera passando direto.
 *
 * O `getMediaSpec` é o mesmo remendo de `apps/android/.../SaidaDeVideoParaCodificador.kt`: sem
 * ele o `bindToLifecycle` de 1.4.2 estoura com "Unable to update target resolution by null
 * MediaSpec".
 */
class SaidaDaSonda(private val aoPedir: (SurfaceRequest, String) -> Unit) : VideoOutput {
    override fun onSurfaceRequested(request: SurfaceRequest) = aoPedir(request, "nao_informado")

    @SuppressLint("RestrictedApi")
    override fun onSurfaceRequested(request: SurfaceRequest, timebase: Timebase) = aoPedir(request, timebase.name)

    @SuppressLint("RestrictedApi")
    override fun getMediaSpec(): Observable<MediaSpec> = ConstantObservable.withValue(MediaSpec.builder().build())
}

fun seletorPara(s: Size): ResolutionSelector = ResolutionSelector.Builder()
    .setResolutionStrategy(ResolutionStrategy(s, ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
    .build()

/**
 * A câmera **frontal** pelo CameraX 1.4.2, com o dono de ciclo de vida sendo a Activity. Anota,
 * com hora (`nanoTime`), tudo o que diz se a câmera fechou: o `CameraDevice` (pelo interop), o
 * `CameraState` do CameraX e a disponibilidade vista pelo `CameraManager`.
 */
@OptIn(ExperimentalCamera2Interop::class)
class CameraDaSonda(private val act: SondaActivity, private val r: Relato) {
    val provedor: ProcessCameraProvider = ProcessCameraProvider.getInstance(act).get(10, TimeUnit.SECONDS)
    val seletor: CameraSelector = CameraSelector.DEFAULT_FRONT_CAMERA
    @Volatile var cameraId: String? = null; private set

    class Evento(val ns: Long, val texto: String)
    private val eventos = ArrayList<Evento>()
    private val observados = HashSet<Any>()

    /** (SENSOR_TIMESTAMP, `nanoTime`, `elapsedRealtimeNanos`) de cada captura completa. */
    val carimbosDoSensor = ArrayList<LongArray>()

    private val threadDoGerente = HandlerThread("gerente-da-camera").apply { start() }
    private val gerente = act.getSystemService(CameraManager::class.java)
    private val disponibilidade = object : CameraManager.AvailabilityCallback() {
        override fun onCameraAvailable(id: String) { if (id == cameraId) evento("gerente: câmera $id livre") }
        override fun onCameraUnavailable(id: String) { if (id == cameraId) evento("gerente: câmera $id ocupada") }
    }

    init {
        gerente.registerAvailabilityCallback(disponibilidade, Handler(threadDoGerente.looper))
        // O id da frontal que o CameraX escolhe, antes de abrir (os eventos filtram por ele).
        cameraId = runCatching {
            provedor.availableCameraInfos.firstOrNull { seletor.filter(listOf(it)).isNotEmpty() }
                ?.let { Camera2CameraInfo.from(it).cameraId }
        }.getOrNull()
        r.nota("frontal do CameraX: id $cameraId")
    }

    fun evento(t: String) {
        synchronized(eventos) { eventos.add(Evento(System.nanoTime(), t)) }
        r.nota(t)
    }

    fun eventosEntre(t0: Long, t1: Long): List<Evento> = synchronized(eventos) { eventos.filter { it.ns in t0..t1 } }

    fun eventosJson(t0: Long, t1: Long, origem: Long = t0): JSONArray = JSONArray().apply {
        eventosEntre(t0, t1).forEach { put("+${fmt(ms(it.ns - origem), 1)} ms ${it.texto}") }
    }

    private val capturas = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(s: CameraCaptureSession, req: CaptureRequest, res: TotalCaptureResult) {
            val ts = res.get(CaptureResult.SENSOR_TIMESTAMP) ?: return
            val m = System.nanoTime()
            val b = SystemClock.elapsedRealtimeNanos()
            synchronized(carimbosDoSensor) { carimbosDoSensor.add(longArrayOf(ts, m, b)) }
        }
    }

    private val dispositivo = object : CameraDevice.StateCallback() {
        override fun onOpened(c: CameraDevice) = evento("CameraDevice.onOpened ${c.id}")
        override fun onClosed(c: CameraDevice) = evento("CameraDevice.onClosed ${c.id}")
        override fun onDisconnected(c: CameraDevice) = evento("CameraDevice.onDisconnected ${c.id}")
        override fun onError(c: CameraDevice, erro: Int) = evento("CameraDevice.onError ${c.id} $erro")
    }

    /** Um `Preview` cuja superfície é o [sumidouro]. Com [anotar], leva os callbacks do interop. */
    fun previa(sumidouro: Sumidouro, resolucao: Size?, anotar: Boolean, aoPedir: ((Size) -> Unit)? = null): Preview {
        val b = Preview.Builder()
        resolucao?.let { b.setResolutionSelector(seletorPara(it)) }
        if (anotar) {
            Camera2Interop.Extender(b)
                .setSessionCaptureCallback(capturas)
                .setDeviceStateCallback(dispositivo)
        }
        val p = b.build()
        // `setSurfaceProvider` exige a thread principal (Threads.checkMainThread).
        act.naPrincipal {
            p.setSurfaceProvider(act.mainExecutor) { req ->
                evento("prévia pediu superfície ${req.resolution.width}x${req.resolution.height}")
                aoPedir?.invoke(req.resolution)
                sumidouro.ajustar(req.resolution)
                req.provideSurface(sumidouro.surface, act.mainExecutor) { res ->
                    evento("prévia soltou a superfície (resultado ${res.resultCode})")
                }
            }
        }
        return p
    }

    fun captura(resolucao: Size, aoPedir: (SurfaceRequest, String) -> Unit): VideoCapture<SaidaDaSonda> =
        VideoCapture.Builder(SaidaDaSonda(aoPedir))
            .setMirrorMode(MirrorMode.MIRROR_MODE_OFF)
            .setResolutionSelector(seletorPara(resolucao))
            .build()

    fun ligar(vararg uc: UseCase): Camera = act.naPrincipal {
        provedor.bindToLifecycle(act, seletor, *uc).also { observar(it) }
    }

    /** O `rebind_junto` do produto: `unbindAll` e o bind conjunto no mesmo passo da principal. */
    fun religarJunto(vararg uc: UseCase): Camera = act.naPrincipal {
        provedor.unbindAll()
        provedor.bindToLifecycle(act, seletor, *uc).also { observar(it) }
    }

    fun desligar(uc: UseCase) = act.naPrincipal { provedor.unbind(uc) }
    fun desligarTudo() = act.naPrincipal { provedor.unbindAll() }

    private fun observar(c: Camera) {
        val id = runCatching { Camera2CameraInfo.from(c.cameraInfo).cameraId }.getOrNull()
        if (id != null && id != cameraId) { cameraId = id; r.nota("câmera ligada: id $id") }
        val ld = c.cameraInfo.cameraState
        if (observados.add(ld)) {
            ld.observe(act) { st ->
                evento("CameraState ${st.type}" + (st.error?.let { " erro ${it.code}" } ?: ""))
            }
        }
    }

    fun fechar() {
        runCatching { desligarTudo() }
        runCatching { gerente.unregisterAvailabilityCallback(disponibilidade) }
        threadDoGerente.quitSafely()
    }
}
