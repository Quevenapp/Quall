package com.quall.android.capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.lifecycle.LifecycleService
import com.quall.android.EncodePreset
import com.quall.android.R
import kotlin.concurrent.thread

/**
 * Instrumento de bancada para o preset `camera` — o mesmo papel que [ScreenCaptureService] no
 * modo sidecar tem para `screen`: captura por [DURATION_MS] e grava `.h264`+`.json`
 * (`docs/contrato-sidecar.md`), sem tocar em rede. Existe para provar CameraX → MediaCodec →
 * Annex-B com `ffprobe` e `tools/valida-sidecar.py` — a mesma disciplina que validou a tela no
 * M1/M2, antes de confiar na captura pela track.
 *
 * `LifecycleService`, não `Service`: `ProcessCameraProvider.bindToLifecycle` (dentro de
 * [CameraXSource]) exige um `LifecycleOwner`, e um `Service` comum não é um.
 */
class CameraCaptureService : LifecycleService() {
    companion object {
        private const val TAG = "QuallCameraCapture" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        const val EXTRA_CAMERA_ID = "camera_id" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        const val EXTRA_CAMERA_LABEL = "camera_label" // i18n-fora: instrumento de bancada (seção de diagnóstico)

        private const val TARGET_FPS = 30
        private const val BITRATE_BPS = 6_000_000
        private const val GOP_SECONDS = 2f
        private const val DURATION_MS = 8_000L

        private const val CHANNEL_ID = "quall-capture" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        private const val NOTIF_ID = 3
    }

    private var encoder: H264CameraEncoder? = null

    override fun onBind(intent: Intent): IBinder? {
        super.onBind(intent)
        return null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForegroundCompat()

        val cameraId = intent.getStringExtra(EXTRA_CAMERA_ID)
        val label = intent.getStringExtra(EXTRA_CAMERA_LABEL) ?: "câmera" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        if (cameraId == null) {
            CaptureBus.publish("erro: sem id de câmera") // i18n-fora: instrumento de bancada (seção de diagnóstico)
            stopSelf()
            return START_NOT_STICKY
        }

        thread(name = "quall-camera-capture") { runCapture(cameraId, label) } // i18n-fora: instrumento de bancada (seção de diagnóstico)
        return START_NOT_STICKY
    }

    private fun runCapture(cameraId: String, label: String) {
        val outDir = getExternalFilesDir(null) ?: filesDir
        outDir.mkdirs()
        try {
            CaptureBus.publish("abrindo câmera $label ($cameraId)…") // i18n-fora: instrumento de bancada (seção de diagnóstico)
            val src = CameraXSource.abrir(this, this, cameraId)
            CaptureBus.publish(
                "capturando ${DURATION_MS / 1000}s a ${src.resolution.width}x${src.resolution.height} (preset camera)…" // i18n-fora: instrumento de bancada (seção de diagnóstico)
            )

            val h264File = java.io.File(outDir, "captura_camera.h264") // i18n-fora: instrumento de bancada (seção de diagnóstico)
            val sink = SidecarFrameSink(h264File)
            val enc = H264CameraEncoder(
                cameraSource = src,
                sink = sink,
                targetFps = TARGET_FPS,
                bitrateBps = BITRATE_BPS,
                gopSeconds = GOP_SECONDS,
                colecionarQuadros = true,
            )
            encoder = enc
            val result = enc.run(DURATION_MS)

            val header = CaptureSidecarHeader(
                width = src.resolution.width,
                height = src.resolution.height,
                targetFps = TARGET_FPS,
                preset = EncodePreset.CAMERA.json,
                // Era "Preview -> MediaCodec" até 03/09. O use case que ocupa a superfície da
                // câmera trocou (ver `CameraXSource`), e `docs/contrato-sidecar.md` manda este
                // campo dizer o nome real da API que capturou — não o nome de ontem.
                captureApi = "CameraX (VideoCapture -> MediaCodec)", // i18n-fora: instrumento de bancada (seção de diagnóstico)
                encoder = result.encoderName,
                encoderIsHardware = result.encoderIsHardware,
                targetBitrateBps = BITRATE_BPS,
                gopFrames = Math.round(TARGET_FPS * GOP_SECONDS),
                colorRange = "limited", // i18n-fora: instrumento de bancada (seção de diagnóstico)
                videoFile = "captura_camera.h264", // i18n-fora: instrumento de bancada (seção de diagnóstico)
            )
            java.io.File(outDir, "captura_camera.json") // i18n-fora: instrumento de bancada (seção de diagnóstico)
                .writeText(CaptureSidecar(header, result.frames).toJson())

            // `latenciaConfiavel` é medido (H264SurfaceEncoder descarta amostra implausível e se
            // declara não confiável), não presumido do `timestamp_source` que a câmera declara —
            // achado em bancada no A07: mesmo com REALTIME declarado, o delta medido saiu em
            // ~2,94 **horas**, não milissegundos. `timestampSourceRealtime` ainda entra no aviso
            // como contexto, mas quem decide se o número aparece é a medida, não a promessa da
            // API.
            val latenciaTexto = if (result.latenciaConfiavel) {
                "latência de encode: p50=${result.encodeLatencyP50Us / 1000.0}ms " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "p95=${result.encodeLatencyP95Us / 1000.0}ms" // i18n-fora: instrumento de bancada (seção de diagnóstico)
            } else {
                "latência de encode: NÃO CONFIÁVEL nesta câmera (timestamp_source declarado=" + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "${if (src.timestampSourceRealtime) "REALTIME" else "UNKNOWN"}, mas o delta " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "medido contra presentationTimeUs saiu fora do plausível — não é fila nem " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "encode lento, é relógio incomparável; ver H264SurfaceEncoder)" // i18n-fora: instrumento de bancada (seção de diagnóstico)
            }
            CaptureBus.publish(
                "ok: ${result.frameCount} quadros, encoder=${result.encoderName} " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "hw=${result.encoderIsHardware}, IDRs em ${result.idrFrameNumbers}\n" + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "fps: pedido=$TARGET_FPS obtido=${"%.1f".format(result.achievedFps)} · " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "$latenciaTexto\n" + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "IDR com SPS/PPS colado: ${result.idrsComParametrosColados} · " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "sem start code: ${result.quadrosSemStartCode}\n" + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                    "arquivo: ${h264File.absolutePath}" // i18n-fora: instrumento de bancada (seção de diagnóstico)
            )
        } catch (e: Exception) {
            com.quall.android.core.LogSeguro.e(TAG, "captura de câmera falhou", e) // i18n-fora: instrumento de bancada (seção de diagnóstico)
            CaptureBus.publish("erro na captura de câmera: ${e.javaClass.simpleName}: ${e.message}") // i18n-fora: instrumento de bancada (seção de diagnóstico)
        } finally {
            encoder = null
            stopSelf()
        }
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.notification_channel_capture),
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
        }
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText("Capturando câmera…") // i18n-fora: instrumento de bancada (seção de diagnóstico)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    override fun onDestroy() {
        encoder?.stop()
        super.onDestroy()
    }
}
