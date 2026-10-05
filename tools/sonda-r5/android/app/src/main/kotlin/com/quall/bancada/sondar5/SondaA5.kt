package com.quall.bancada.sondar5

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.IBinder
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * O serviço da S-A5. Sobe em primeiro plano com o tipo que a sonda mandar e, quando ela pede,
 * chama `startForeground` **de novo** com outro tipo. Guarda o que aconteceu em [Resultado].
 */
class ServicoDaSondaA5 : Service() {
    object Resultado {
        @Volatile var primeiro: String = "não chamado"
        @Volatile var tipoDepoisDoPrimeiro: Int = -1
        var subiu = CountDownLatch(1)
        @Volatile var instancia: ServicoDaSondaA5? = null
        fun zerar() { primeiro = "não chamado"; tipoDepoisDoPrimeiro = -1; subiu = CountDownLatch(1); instancia = null }
    }

    private fun notificacao(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("sonda", "Sonda R5", NotificationManager.IMPORTANCE_LOW))
        return Notification.Builder(this, "sonda")
            .setContentTitle("Sonda R5 (S-A5)")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val tipo = intent?.getIntExtra("tipo", ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
            ?: ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        Resultado.instancia = this
        Resultado.primeiro = try {
            startForeground(1, notificacao(), tipo)
            Resultado.tipoDepoisDoPrimeiro = foregroundServiceType
            "ACEITO"
        } catch (t: Throwable) {
            "RECUSADO ${t.javaClass.simpleName}: ${t.message}"
        }
        Resultado.subiu.countDown()
        return START_NOT_STICKY
    }

    /** O segundo `startForeground`, com [tipo]. Devolve "ACEITO" ou a exceção. */
    fun acrescentar(tipo: Int): Pair<String, Int> = try {
        startForeground(1, notificacao(), tipo)
        "ACEITO" to foregroundServiceType
    } catch (t: Throwable) {
        "RECUSADO ${t.javaClass.simpleName}: ${t.message}" to foregroundServiceType
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

/**
 * **S-A5** — `startForeground` acrescentando o tipo `microphone` com o app visível (§4.4).
 *
 * Braços (`--es braco`):
 *
 *  - `acrescentar` (padrão): o serviço sobe com `camera`; 1 s depois, com a Activity na frente,
 *    chama `startForeground` de novo com `camera|microphone`;
 *  - `desde_o_inicio`: o recuo do desenho — sobe já com `camera|microphone`.
 *
 * Depois, 2 s de `AudioRecord` (fonte `MIC`) **só contando amostras**: quantas vieram e quantas
 * não são zero (um app sem o tipo `microphone` em segundo plano recebe silêncio digital). Nada do
 * som é guardado. Com `--ez fundo true`, a Activity vai para trás (`moveTaskToBack`) antes dos 2 s,
 * o que prova se o tipo vale de fato; **o padrão é ficar visível**, como o pedido da fase 0.
 */
class SondaA5(
    private val act: SondaActivity,
    private val r: Relato,
    private val braco: String,
    private val fundo: Boolean,
) {
    private fun nomeDoTipo(t: Int): String {
        if (t < 0) return "?"
        val n = mutableListOf<String>()
        if (t and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA != 0) n += "camera"
        if (t and ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE != 0) n += "microphone"
        val resto = t and (ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE).inv()
        if (resto != 0) n += "0x${Integer.toHexString(resto)}"
        return if (n.isEmpty()) "nenhum" else n.joinToString("|")
    }

    @SuppressLint("MissingPermission")
    private fun contar(segundos: Int): JSONObject {
        val taxa = 48_000
        val min = AudioRecord.getMinBufferSize(taxa, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val ar = AudioRecord(MediaRecorder.AudioSource.MIC, taxa, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, maxOf(min, taxa / 5))
        val o = JSONObject()
        try {
            o.put("estado", ar.state)
            if (ar.state != AudioRecord.STATE_INITIALIZED) { o.put("erro", "AudioRecord não inicializou"); return o }
            val buf = ShortArray(taxa / 50)
            var total = 0L
            var naoZero = 0L
            var erros = 0
            ar.startRecording()
            o.put("gravando", ar.recordingState == AudioRecord.RECORDSTATE_RECORDING)
            val fim = System.nanoTime() + segundos * 1_000_000_000L
            while (System.nanoTime() < fim) {
                val n = ar.read(buf, 0, buf.size)
                if (n < 0) { erros++; if (erros > 20) break; continue }
                total += n
                for (k in 0 until n) if (buf[k].toInt() != 0) naoZero++
            }
            ar.stop()
            o.put("amostras", total); o.put("amostras_nao_zero", naoZero); o.put("erros_de_leitura", erros)
            o.put("esperadas", taxa.toLong() * segundos)
        } finally {
            ar.release()
        }
        return o
    }

    fun rodar(): String {
        val CAM = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        val MIC = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        ServicoDaSondaA5.Resultado.zerar()
        val primeiro = if (braco == "desde_o_inicio") CAM or MIC else CAM
        val intent = Intent(act, ServicoDaSondaA5::class.java).putExtra("tipo", primeiro)
        try {
            act.startForegroundService(intent)
            if (!ServicoDaSondaA5.Resultado.subiu.await(8, TimeUnit.SECONDS)) return "SERVICO_NAO_SUBIU"
            val p = ServicoDaSondaA5.Resultado.primeiro
            val t1 = ServicoDaSondaA5.Resultado.tipoDepoisDoPrimeiro
            r.por("primeiro_startForeground", JSONObject().apply { put("pedido", nomeDoTipo(primeiro)); put("resultado", p); put("tipo_em_vigor", nomeDoTipo(t1)) })
            r.nota("1º startForeground(${nomeDoTipo(primeiro)}): $p; em vigor ${nomeDoTipo(t1)}")
            if (!p.startsWith("ACEITO")) return "PRIMEIRO_RECUSADO ($p)"

            var segundo = "não se aplica"
            var t2 = t1
            if (braco != "desde_o_inicio") {
                Thread.sleep(1000)
                val s = ServicoDaSondaA5.Resultado.instancia ?: return "SEM_INSTANCIA"
                val (res, tipo) = act.naPrincipal { s.acrescentar(CAM or MIC) }
                segundo = res; t2 = tipo
                r.por("segundo_startForeground", JSONObject().apply { put("pedido", nomeDoTipo(CAM or MIC)); put("resultado", res); put("tipo_em_vigor", nomeDoTipo(tipo)) })
                r.nota("2º startForeground(camera|microphone) com a Activity visível: $res; em vigor ${nomeDoTipo(tipo)}")
            }

            if (fundo) {
                act.naPrincipal { act.moveTaskToBack(true) }
                Thread.sleep(1500)
                r.nota("Activity mandada para trás antes da contagem")
            }
            val c = contar(2)
            r.por("contagem_2s", c)
            r.por("visivel_na_contagem", !fundo)
            r.nota("2 s de MIC: ${c.optLong("amostras")} amostras, ${c.optLong("amostras_nao_zero")} não zero")
            val tem = t2 >= 0 && (t2 and MIC) != 0
            val veredito = when {
                braco != "desde_o_inicio" && !segundo.startsWith("ACEITO") -> "RECUSA ao acrescentar microphone ($segundo)"
                tem -> "ACEITA: em vigor ${nomeDoTipo(t2)}"
                else -> "ACEITO_SEM_EFEITO: startForeground não reclamou, mas o tipo em vigor é ${nomeDoTipo(t2)}"
            }
            return "$veredito; braço $braco; 2 s de MIC ${if (fundo) "em segundo plano" else "visível"}: " +
                "${c.optLong("amostras")} amostras, ${c.optLong("amostras_nao_zero")} não zero"
        } finally {
            runCatching { act.stopService(intent) }
            if (fundo) runCatching {
                act.startActivity(Intent(act, SondaActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
            }
        }
    }
}
