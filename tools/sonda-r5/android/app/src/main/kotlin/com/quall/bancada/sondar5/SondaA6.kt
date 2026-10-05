package com.quall.bancada.sondar5

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * **S-A6** — `MIC` × `CAMCORDER`: o nível de um tom em degraus tocado por **outro aparelho**, e os
 * efeitos (NS, AEC, AGC) que cada fonte traz ligados por padrão.
 *
 * O outro aparelho toca em laço o arquivo de `gera-degraus.py` (tom de [hz], 2 s de silêncio e seis
 * degraus de 3 s, de 0 a −30 dB em passos de −6 dB, cada um seguido de 1 s de silêncio: um ciclo de
 * 26 s). Não há sincronia entre os dois: cada fonte grava [segundos] (padrão 30, mais de um ciclo),
 * primeiro `MIC`, depois `CAMCORDER`, e os degraus são achados no próprio sinal.
 *
 * A cada 100 ms sai o RMS de banda larga e o nível do tom por Goertzel, os dois em dBFS (seno de
 * fundo de escala: tom = 0 dBFS, RMS = −3 dBFS). Degrau = trecho de ≥ 1,5 s com o tom mais de
 * 10 dB acima do piso e dentro de ±1,5 dB da própria mediana. O passo entre degraus vizinhos
 * mostra o tratamento: −6 dB é linear; passo menor é compressão (AGC). **Só números: nenhuma
 * amostra é guardada.**
 */
class SondaA6(
    private val act: SondaActivity,
    private val r: Relato,
    private val segundos: Int,
    private val hz: Int,
) {
    private val taxa = 48_000
    private val janela = taxa / 10

    private fun db(v: Double) = if (v <= 1e-12) -240.0 else 20 * log10(v)

    private fun goertzel(x: ShortArray, n: Int): Double {
        val k = 2 * cos(2 * Math.PI * hz / taxa)
        var s1 = 0.0; var s2 = 0.0
        for (i in 0 until n) {
            val s = x[i] / 32768.0 + k * s1 - s2
            s2 = s1; s1 = s
        }
        val pot = s1 * s1 + s2 * s2 - k * s1 * s2
        return 2 * sqrt(maxOf(pot, 0.0)) / n
    }

    private fun efeitos(sessao: Int): JSONObject {
        val o = JSONObject()
        fun um(nome: String, disponivel: Boolean, criar: () -> android.media.audiofx.AudioEffect?) {
            val e = JSONObject().put("disponivel", disponivel)
            if (disponivel) {
                val ef = runCatching { criar() }.getOrNull()
                if (ef == null) e.put("ligado_por_padrao", "não criou") else {
                    e.put("ligado_por_padrao", runCatching { ef.enabled }.getOrNull())
                    runCatching { ef.release() }
                }
            }
            o.put(nome, e)
        }
        um("NoiseSuppressor", NoiseSuppressor.isAvailable()) { NoiseSuppressor.create(sessao) }
        um("AcousticEchoCanceler", AcousticEchoCanceler.isAvailable()) { AcousticEchoCanceler.create(sessao) }
        um("AutomaticGainControl", AutomaticGainControl.isAvailable()) { AutomaticGainControl.create(sessao) }
        return o
    }

    @SuppressLint("MissingPermission")
    private fun medir(fonte: Int, nome: String): JSONObject {
        val min = AudioRecord.getMinBufferSize(taxa, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val ar = AudioRecord(fonte, taxa, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, taxa / 2))
        val o = JSONObject().put("fonte", nome)
        try {
            if (ar.state != AudioRecord.STATE_INITIALIZED) return o.put("erro", "AudioRecord não inicializou")
            o.put("taxa", ar.sampleRate)
            o.put("efeitos", efeitos(ar.audioSessionId))
            val buf = ShortArray(janela)
            val rms = ArrayList<Double>()
            val tom = ArrayList<Double>()
            var cortes = 0L
            ar.startRecording()
            runCatching {
                o.put("microfones", JSONArray().apply {
                    ar.activeMicrophones.forEach { m -> put("${m.description} tipo ${m.type} local ${m.location}") }
                })
                o.put("dispositivo", ar.routedDevice?.let { "${it.productName} tipo ${it.type}" })
            }
            val fim = System.nanoTime() + segundos * 1_000_000_000L
            while (System.nanoTime() < fim) {
                var lidos = 0
                while (lidos < janela) {
                    val n = ar.read(buf, lidos, janela - lidos)
                    if (n <= 0) break
                    lidos += n
                }
                if (lidos < janela) break
                var soma = 0.0
                for (i in 0 until janela) {
                    val v = buf[i] / 32768.0
                    soma += v * v
                    if (buf[i] == Short.MAX_VALUE || buf[i] == Short.MIN_VALUE) cortes++
                }
                rms += arred(db(sqrt(soma / janela)), 2)
                tom += arred(db(goertzel(buf, janela)), 2)
            }
            ar.stop()
            o.put("janelas_de_100ms", rms.size)
            o.put("amostras_no_limite", cortes)
            o.put("rms_dbfs", JSONArray(rms))
            o.put("tom_dbfs", JSONArray(tom))
            o.put("degraus", degraus(tom))
        } finally {
            ar.release()
        }
        return o
    }

    /** Os degraus achados na série do tom, em ordem de tempo. */
    private fun degraus(tom: List<Double>): JSONObject {
        val o = JSONObject()
        if (tom.size < 20) return o.put("erro", "série curta")
        val piso = percentil(tom.sorted(), 10.0)!!
        o.put("piso_do_tom_dbfs", arred(piso, 2))
        val achados = ArrayList<Pair<Int, Double>>() // (início, mediana)
        var i = 0
        while (i < tom.size) {
            if (tom[i] < piso + 10) { i++; continue }
            var j = i
            val trecho = ArrayList<Double>()
            while (j < tom.size && tom[j] >= piso + 10) {
                trecho += tom[j]
                val med = percentil(trecho.sorted(), 50.0)!!
                if (trecho.size > 3 && Math.abs(tom[j] - med) > 1.5) { trecho.removeAt(trecho.size - 1); break }
                j++
            }
            if (trecho.size >= 15) {
                // Tira as bordas (a subida e a descida do tom) antes da mediana.
                val miolo = if (trecho.size > 6) trecho.subList(2, trecho.size - 2) else trecho
                achados += i to percentil(miolo.sorted(), 50.0)!!
            }
            i = maxOf(j, i + 1)
        }
        val lista = JSONArray()
        achados.forEach { (ini, med) -> lista.put(JSONObject().put("inicio_s", arred(ini / 10.0, 1)).put("tom_dbfs", arred(med, 2))) }
        o.put("lista", lista)
        val passos = achados.zipWithNext().map { (a, b) -> b.second - a.second }
        o.put("passos_db", JSONArray(passos.map { arred(it, 2) }))
        // O passo típico entre degraus descendentes (o sinal toca de 0 a −30 dB).
        val desc = passos.filter { it < -1.0 }
        percentil(desc.sorted(), 50.0)?.let { o.put("passo_descendente_p50_db", arred(it, 2)) }
        if (achados.isNotEmpty()) o.put("faixa_db", arred(achados.maxOf { it.second } - achados.minOf { it.second }, 2))
        return o
    }

    private fun resumoDaFonte(o: JSONObject): String {
        if (o.has("erro")) return "${o.getString("fonte")}: ${o.getString("erro")}"
        val d = o.getJSONObject("degraus")
        val ef = o.getJSONObject("efeitos")
        val ligados = listOf("NoiseSuppressor" to "NS", "AcousticEchoCanceler" to "AEC", "AutomaticGainControl" to "AGC")
            .joinToString(" ") { (k, s) ->
                val e = ef.getJSONObject(k)
                "$s=" + when {
                    !e.getBoolean("disponivel") -> "indisp"
                    e.opt("ligado_por_padrao") == true -> "ligado"
                    e.opt("ligado_por_padrao") == false -> "desligado"
                    else -> "?"
                }
            }
        val n = d.optJSONArray("lista")?.length() ?: 0
        return "${o.getString("fonte")}: $n degraus, passo p50 ${fmt(d.optDouble("passo_descendente_p50_db").takeIf { !it.isNaN() }, 1)} dB, " +
            "faixa ${fmt(d.optDouble("faixa_db").takeIf { !it.isNaN() }, 1)} dB, piso ${fmt(d.optDouble("piso_do_tom_dbfs").takeIf { !it.isNaN() }, 1)} dBFS; $ligados"
    }

    fun rodar(): String {
        r.por("hz", hz); r.por("segundos_por_fonte", segundos)
        // UNPROCESSED é o "som cru" decidido pelo Pessoa Exemplo (24/09); VOICE_RECOGNITION é o controle
        // que o Android também promete sem processamento. Aparelho sem UNPROCESSED cai no fallback
        // do HAL: o relato diz se a propriedade de suporte está ligada.
        val suporte = (act.getSystemService(android.media.AudioManager::class.java))
            ?.getProperty(android.media.AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED)
        r.nota("PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED=$suporte"); r.por("suporte_unprocessed", suporte ?: "null")
        val fontes = listOf(
            MediaRecorder.AudioSource.MIC to "MIC",
            MediaRecorder.AudioSource.CAMCORDER to "CAMCORDER",
            MediaRecorder.AudioSource.UNPROCESSED to "UNPROCESSED",
            MediaRecorder.AudioSource.VOICE_RECOGNITION to "VOICE_RECOGNITION",
        )
        val resumos = ArrayList<String>()
        for ((f, nome) in fontes) {
            val m = medir(f, nome)
            r.por(nome, m)
            r.nota(resumoDaFonte(m))
            resumos += resumoDaFonte(m)
            Thread.sleep(500)
        }
        return resumos.joinToString(" | ") + " (passo ideal −6,0 dB; menor em módulo = compressão; UNPROCESSED suportado=$suporte)"
    }
}
