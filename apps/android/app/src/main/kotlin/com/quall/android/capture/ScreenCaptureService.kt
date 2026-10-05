package com.quall.android.capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import com.quall.android.core.LogSeguro as Log
import androidx.core.app.NotificationCompat
import com.quall.android.EncodePreset
import com.quall.android.R
import kotlin.concurrent.thread

/**
 * Foreground service `mediaProjection` — exigido pelo Android para hospedar a captura de tela
 * (ver `docs/bancada.md`/PROMPT.md: o diálogo de consentimento aparece a cada sessão e não há
 * como suprimir; é comportamento esperado, não bug a contornar).
 *
 * Dois modos, escolhidos pelo `EXTRA_MODE`:
 *  - [MODE_SIDECAR]: a primeira entrega do M2 — captura por [DURATION_SIDECAR_MS] e grava
 *    `.h264`+`.json` no formato de `docs/contrato-sidecar.md`, sem tocar em rede.
 *  - [MODE_IDR_TEST]: GOP deliberadamente longo (sem IDR natural na janela) e um pedido de
 *    sync-frame no meio, para medir se o MediaCodec honra `PARAMETER_KEY_REQUEST_SYNC_FRAME` de
 *    verdade — o achado do M1 foi que o Media Foundation do Windows devolve `S_OK` e ignora.
 */
class ScreenCaptureService : Service() {
    companion object {
        private const val TAG = "QuallCaptureService" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        const val EXTRA_RESULT_CODE = "result_code" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        const val EXTRA_RESULT_DATA = "result_data" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        const val EXTRA_MODE = "mode" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        const val EXTRA_WIDTH = "width" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        const val EXTRA_HEIGHT = "height" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        const val EXTRA_DPI = "dpi" // i18n-fora: instrumento de bancada (seção de diagnóstico)

        const val MODE_SIDECAR = "sidecar" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        const val MODE_IDR_TEST = "idr_test" // i18n-fora: instrumento de bancada (seção de diagnóstico)

        private const val TARGET_FPS = 30
        private const val BITRATE_BPS = 6_000_000

        private const val DURATION_SIDECAR_MS = 8_000L
        private const val DURATION_IDR_TEST_MS = 12_000L
        private const val IDR_TEST_REQUEST_AT_MS = 3_000L
        // GOP de 20s garante que, numa janela de 12s, o único jeito de aparecer um segundo IDR é
        // o pedido explícito — não o ciclo normal do encoder.
        private const val IDR_TEST_GOP_SECONDS = 20f

        private const val CHANNEL_ID = "quall-capture" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        private const val NOTIF_ID = 1
    }

    private var encoder: H264ScreenEncoder? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForegroundCompat()

        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val resultData: Intent? = intent.getParcelableExtra(EXTRA_RESULT_DATA)
        val mode = intent.getStringExtra(EXTRA_MODE) ?: MODE_SIDECAR
        val width = intent.getIntExtra(EXTRA_WIDTH, 1080)
        val height = intent.getIntExtra(EXTRA_HEIGHT, 1920)
        val dpi = intent.getIntExtra(EXTRA_DPI, 320)

        if (resultData == null) {
            CaptureBus.publish("erro: sem dados de consentimento do MediaProjection") // i18n-fora: instrumento de bancada (seção de diagnóstico)
            stopSelf()
            return START_NOT_STICKY
        }

        thread(name = "quall-capture") { // i18n-fora: instrumento de bancada (seção de diagnóstico)
            runCapture(resultCode, resultData, mode, width, height, dpi)
        }

        return START_NOT_STICKY
    }

    private fun runCapture(resultCode: Int, resultData: Intent, mode: String, width: Int, height: Int, dpi: Int) {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val projection: MediaProjection = try {
            mpm.getMediaProjection(resultCode, resultData)
                ?: throw IllegalStateException("getMediaProjection devolveu null") // i18n-fora: instrumento de bancada (seção de diagnóstico)
        } catch (e: Exception) {
            Log.e(TAG, "getMediaProjection recusado", e) // i18n-fora: instrumento de bancada (seção de diagnóstico)
            CaptureBus.publish("erro: MediaProjection recusado (${e.message})") // i18n-fora: instrumento de bancada (seção de diagnóstico)
            stopSelf()
            return
        }

        val outDir = getExternalFilesDir(null) ?: filesDir
        outDir.mkdirs()

        try {
            when (mode) {
                MODE_IDR_TEST -> runIdrTest(projection, outDir, width, height, dpi)
                else -> runSidecarCapture(projection, outDir, width, height, dpi)
            }
        } catch (e: Exception) {
            Log.e(TAG, "captura falhou", e) // i18n-fora: instrumento de bancada (seção de diagnóstico)
            CaptureBus.publish("erro na captura: ${e.message}") // i18n-fora: instrumento de bancada (seção de diagnóstico)
        } finally {
            runCatching { projection.stop() }
            stopSelf()
        }
    }

    /**
     * Roda o encoder gravando num `.h264` e escreve o `.json` do contrato ao lado.
     *
     * O `.json` é montado aqui, e não dentro do encoder, porque `encoder`/`encoder_is_hardware`
     * do cabeçalho só existem depois que o codec foi criado — e porque o encoder passou a servir
     * também à track, onde não há sidecar nenhum.
     */
    private fun gravarComSidecar(
        projection: MediaProjection,
        outDir: java.io.File,
        width: Int,
        height: Int,
        dpi: Int,
        duracaoMs: Long,
        gopSeconds: Float,
        h264Name: String,
        jsonName: String,
        aoComecar: ((H264ScreenEncoder) -> Unit)? = null,
    ): H264SurfaceEncoder.Result {
        val h264File = java.io.File(outDir, h264Name)
        val sink = SidecarFrameSink(h264File)
        // Os botões do encoder vêm da preferência de bancada, e não de constante: o A/B honesto é
        // o mesmo APK, no mesmo aparelho, na mesma janela. Ver `Bancada.refreshIntraQuadros`.
        val refresh = com.quall.android.core.Bancada.refreshIntraQuadros(this)
        val fornecedor = com.quall.android.core.Bancada.chavesDeFornecedor(this)
        val enc = H264ScreenEncoder(
            mediaProjection = projection,
            sink = sink,
            width = width,
            height = height,
            densityDpi = dpi,
            targetFps = TARGET_FPS,
            bitrateBps = BITRATE_BPS,
            gopSeconds = gopSeconds,
            colecionarQuadros = true,
            refreshIntraQuadros = refresh,
            chavesDeFornecedor = fornecedor,
        )
        encoder = enc
        aoComecar?.invoke(enc)
        val result = enc.run(duracaoMs)

        val header = CaptureSidecarHeader(
            width = width,
            height = height,
            targetFps = TARGET_FPS,
            preset = EncodePreset.SCREEN.json,
            captureApi = "MediaProjection", // i18n-fora: instrumento de bancada (seção de diagnóstico)
            encoder = result.encoderName,
            encoderIsHardware = result.encoderIsHardware,
            targetBitrateBps = BITRATE_BPS,
            gopFrames = Math.round(TARGET_FPS * gopSeconds),
            colorRange = "limited", // i18n-fora: instrumento de bancada (seção de diagnóstico)
            videoFile = h264Name,
        )
        java.io.File(outDir, jsonName).writeText(CaptureSidecar(header, result.frames).toJson())
        return result
    }

    private fun runSidecarCapture(projection: MediaProjection, outDir: java.io.File, width: Int, height: Int, dpi: Int) {
        CaptureBus.publish("capturando ${DURATION_SIDECAR_MS / 1000}s (preset screen)…") // i18n-fora: instrumento de bancada (seção de diagnóstico)
        val result = gravarComSidecar(
            projection, outDir, width, height, dpi,
            duracaoMs = DURATION_SIDECAR_MS,
            gopSeconds = 2f,
            h264Name = "captura.h264", // i18n-fora: instrumento de bancada (seção de diagnóstico)
            jsonName = "captura.json", // i18n-fora: instrumento de bancada (seção de diagnóstico)
        )
        CaptureBus.publish(
            "ok: ${result.frameCount} quadros, encoder=${result.encoderName} " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                "hw=${result.encoderIsHardware}, IDRs em ${result.idrFrameNumbers}\n" + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                // fps obtida ao lado da latência sempre — é o par que denuncia fila (ver
                // H264ScreenEncoder.kt e docs/bancada.md/regras-de-frente.md).
                "fps: pedido=$TARGET_FPS obtido=${"%.1f".format(result.achievedFps)} · " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                "latência de encode: p50=${result.encodeLatencyP50Us / 1000.0}ms " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                "p95=${result.encodeLatencyP95Us / 1000.0}ms\n" + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                "IDR com SPS/PPS colado: ${result.idrsComParametrosColados} · " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                "sem start code: ${result.quadrosSemStartCode}\n" + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                "arquivo: ${java.io.File(outDir, "captura.h264").absolutePath}" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        )
    }

    private fun runIdrTest(projection: MediaProjection, outDir: java.io.File, width: Int, height: Int, dpi: Int) {
        CaptureBus.publish("teste de IDR: ${DURATION_IDR_TEST_MS / 1000}s, GOP=${IDR_TEST_GOP_SECONDS.toInt()}s, pedido em ${IDR_TEST_REQUEST_AT_MS}ms…") // i18n-fora: instrumento de bancada (seção de diagnóstico)
        val result = gravarComSidecar(
            projection, outDir, width, height, dpi,
            duracaoMs = DURATION_IDR_TEST_MS,
            gopSeconds = IDR_TEST_GOP_SECONDS,
            h264Name = "idr_teste.h264", // i18n-fora: instrumento de bancada (seção de diagnóstico)
            jsonName = "idr_teste.json", // i18n-fora: instrumento de bancada (seção de diagnóstico)
        ) { enc ->
            thread(name = "quall-idr-request") { // i18n-fora: instrumento de bancada (seção de diagnóstico)
                Thread.sleep(IDR_TEST_REQUEST_AT_MS)
                enc.requestSyncFrame()
            }
        }
        val honored = result.idrFrameNumbers.size > 1
        CaptureBus.publish(
            "teste de IDR concluído: ${result.frameCount} quadros, IDRs em ${result.idrFrameNumbers} " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                "(fps obtido=${"%.1f".format(result.achievedFps)}, latência p50=${result.encodeLatencyP50Us / 1000.0}ms) — " + // i18n-fora: instrumento de bancada (seção de diagnóstico)
                if (honored) "MediaCodec HONROU o pedido (mais de 1 IDR sem GOP natural no meio)" // i18n-fora: instrumento de bancada (seção de diagnóstico)
                else "MediaCodec NÃO gerou IDR extra — pedido pode ter sido ignorado" // i18n-fora: instrumento de bancada (seção de diagnóstico)
        )
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.notification_channel_capture),
                NotificationManager.IMPORTANCE_LOW,
            )
            nm.createNotificationChannel(channel)
        }
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText("Capturando tela…") // i18n-fora: instrumento de bancada (seção de diagnóstico)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    override fun onDestroy() {
        encoder?.stop()
        super.onDestroy()
    }
}
