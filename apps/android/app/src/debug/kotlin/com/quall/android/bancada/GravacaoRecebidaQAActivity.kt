package com.quall.android.bancada

import android.app.Activity
import android.media.MediaExtractor
import android.os.Bundle
import com.quall.android.audio.PresetDeAudio
import com.quall.android.capture.AnnexB
import com.quall.android.receive.GravacaoRecebidaBus
import com.quall.android.receive.GravadorRecebido
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.math.sin

/** Offline native mux/AAC probe. Only synthetic H264 fixtures; absent from release. */
class GravacaoRecebidaQAActivity : Activity() {
    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        val modo = intent.getStringExtra("modo") ?: "audio"
        val arquivo = intent.getStringExtra("entrada") ?: "sintetico.h264"
        thread(name = "quall-receptor-qa") {
            val dir = getExternalFilesDir("receiver-qa")!!
            dir.mkdirs()
            val report = JSONObject().put("modo", modo)
            runCatching {
                val dados = File(dir, arquivo).readBytes()
                val starts = AnnexB.nalStarts(dados, dados.size)
                val aud = starts.filter { (dados[it].toInt() and 31) == 9 }.map { if (it >= 4 && dados[it - 4] == 0.toByte()) it - 4 else it - 3 }
                require(aud.isNotEmpty())
                val quadros = aud.mapIndexed { i, p -> dados.copyOfRange(p, aud.getOrNull(i + 1) ?: dados.size) }
                val i = AtomicInteger(0)
                var seq = 0L
                var maxCopias = 0
                var maxGravadores = 0
                val bloqueado = CountDownLatch(1)
                val liberar = CountDownLatch(1)
                val comSom = modo != "video"
                val taxa = if (modo == "pcmu") 8000 else 48000
                val preset = if (comSom) PresetDeAudio("probe", taxa, 1, 20, taxa / 50, 32000, false, 0, false, 111, "") else null
                lateinit var g: GravadorRecebido
                g = GravadorRecebido(applicationContext, 0L, 0L, { 0L }, preset) { destino, meta, espera ->
                    val n = i.get()
                    if (n >= quadros.size || (modo == "disconnect" && n >= 45) ||
                        (modo == "static" && n >= 1)) {
                        if (espera > 0) Thread.sleep(2)
                        -1
                    } else {
                        if (modo == "overlap" && n == 1) { bloqueado.countDown(); check(liberar.await(5, TimeUnit.SECONDS)) }
                        if (n % 30 == 0) {
                            val vivos = Thread.getAllStackTraces().keys.filter { it.isAlive }
                            maxCopias = maxOf(maxCopias, vivos.count { it.name == "quall-copia-crua" })
                            maxGravadores = maxOf(maxGravadores, vivos.count { it.name == "quall-gravacao-recebida" })
                        }
                        // A complete reference frame missing from the transport must freeze until IDR.
                        val indice = if (modo == "loss" && n == 40) { i.incrementAndGet(); 41 } else n
                        val frame = quadros[indice]
                        destino.clear(); destino.put(frame)
                        meta[0] = indice * 1_000_000L / 30
                        meta[1] = if (AnnexB.containsIdr(frame, frame.size)) 1 else 0
                        meta[2] = indice.toLong() + 1
                        meta[3] = 0; meta[4] = 0; meta[5] = 0
                        if (comSom && modo != "silent") {
                            while (seq * 20_000 <= meta[0] + 20_000) {
                                val pcm = ShortArray(taxa / 50) { j -> (sin(2 * Math.PI * 440 * (seq * taxa / 50 + j) / taxa) * 8000).toInt().toShort() }
                                g.som(pcm, pcm.size, seq, seq * 20_000, taxa, 1); seq++
                            }
                        }
                        i.incrementAndGet()
                        Thread.sleep(5)
                        frame.size
                    }
                }
                check(g.iniciar())
                val limite = android.os.SystemClock.elapsedRealtime() + 20_000
                val alvo = when (modo) { "disconnect" -> 45; "static" -> 1; "overlap" -> 1; else -> quadros.size }
                while (i.get() < alvo && !g.terminou() && android.os.SystemClock.elapsedRealtime() < limite) Thread.sleep(10)
                if (modo == "static") Thread.sleep(15_500)
                if (modo == "overlap") {
                    check(bloqueado.await(5, TimeUnit.SECONDS))
                    g.pedirParada()
                    val nova = GravadorRecebido(applicationContext, 0, 0, { 0 }, preset)
                    val recusada = !nova.iniciar()
                    report.put("refusedWhileClosing", recusada)
                    liberar.countDown()
                    check(recusada)
                }
                val pararEm = android.os.SystemClock.elapsedRealtime()
                g.parar()
                report.put("stopMs", android.os.SystemClock.elapsedRealtime() - pararEm)
                val e = GravacaoRecebidaBus.atual
                if (modo == "overlap") {
                    val token = Any()
                    val livre = GravacaoRecebidaBus.tentarIniciar(token)
                    report.put("leaseFreedAfterClose", livre)
                    if (livre) GravacaoRecebidaBus.concluir(token, e)
                    check(livre)
                }
                report.put("peakJournalWriters", maxCopias).put("peakRecorderWorkers", maxGravadores)
                report.put("fase", e.fase.name).put("erro", e.detalhe).put("uri", e.uri?.toString()).put("nome", e.nome).put("framesOffered", i.get()).put("parts", e.parte)
                e.uri?.let { uri ->
                    contentResolver.openInputStream(uri)!!.use { entrada -> File(dir, "resultado-$modo.mp4").outputStream().use { entrada.copyTo(it) } }
                    val x = MediaExtractor()
                    try {
                        x.setDataSource(this, uri, null)
                        val trilhas = JSONArray()
                        for (t in 0 until x.trackCount) {
                            val f = x.getTrackFormat(t)
                            x.selectTrack(t)
                            var amostras = 0; var anterior = -1L; var primeiro = -1L; var monotono = true
                            val bytes = ByteBuffer.allocate(4 * 1024 * 1024)
                            while (x.readSampleData(bytes, 0) >= 0) {
                                val tempo = x.sampleTime
                                if (primeiro < 0) primeiro = tempo
                                if (tempo <= anterior) monotono = false
                                anterior = tempo; amostras++
                                x.advance()
                            }
                            x.unselectTrack(t); x.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                            trilhas.put(JSONObject().put("format", f.toString()).put("samples", amostras).put("firstUs", primeiro).put("lastUs", anterior).put("monotonic", monotono))
                        }
                        report.put("tracks", trilhas)
                    } finally { x.release() }
                }
            }.onFailure { report.put("probeError", it.toString()) }
            File(dir, "resultado-$modo.json").writeText(report.toString(2))
            android.util.Log.i("QuallReceiverQA", report.toString())
            runOnUiThread { finish() }
        }
    }
}
