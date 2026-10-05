package com.quall.bancada.sondar5

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.SystemClock
import android.util.Size
import org.json.JSONArray
import org.json.JSONObject

/**
 * **S-A1** — a fonte do carimbo das câmeras, e em que relógio o carimbo da frontal está de fato.
 *
 * 1. Lê `SENSOR_INFO_TIMESTAMP_SOURCE` (e o nível de hardware) de **todas** as câmeras que o
 *    `CameraManager` lista — frontal e traseiras — sem abrir nenhuma.
 * 2. Abre a **frontal** com uma prévia que vai para uma `SurfaceTexture` (nada na tela) e, a cada
 *    captura completa, anota o `SENSOR_TIMESTAMP` e lê `MONOTONIC` (`nanoTime`) e `BOOTTIME`
 *    (`elapsedRealtimeNanos`). O relógio do sensor é aquele em que "agora − carimbo" dá um atraso
 *    pequeno e positivo (a entrega da captura, dezenas de ms); no outro relógio a diferença é o
 *    tempo que o aparelho dormiu desde o boot.
 * 3. Mede `BOOTTIME − MONOTONIC` direto (leituras coladas, a de menor janela), que é o deslocamento
 *    a somar para levar um carimbo em `BOOTTIME` a `MONOTONIC`. **Se o aparelho não dormiu desde o
 *    boot, os dois relógios coincidem e a sonda diz que não dá para distinguir.**
 * 4. Confere se o carimbo que a `SurfaceTexture` entrega é o próprio `SENSOR_TIMESTAMP` (o divisor
 *    GL da S-A3 depende disso).
 */
class SondaA1(private val act: SondaActivity, private val r: Relato, private val segundos: Int) {

    private fun nomeDaFonte(v: Int?) = when (v) {
        CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME -> "REALTIME"
        CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN -> "UNKNOWN"
        null -> "ausente"
        else -> "outro($v)"
    }

    private fun nomeDoLado(v: Int?) = when (v) {
        CameraCharacteristics.LENS_FACING_FRONT -> "frontal"
        CameraCharacteristics.LENS_FACING_BACK -> "traseira"
        CameraCharacteristics.LENS_FACING_EXTERNAL -> "externa"
        else -> "?"
    }

    /** `BOOTTIME − MONOTONIC` em ns, pela leitura de menor janela entre 2000 tentativas. */
    private fun bootMenosMono(): Pair<Long, Long> {
        var melhor = Long.MAX_VALUE
        var janela = Long.MAX_VALUE
        repeat(2000) {
            val m1 = System.nanoTime()
            val b = SystemClock.elapsedRealtimeNanos()
            val m2 = System.nanoTime()
            if (m2 - m1 < janela) { janela = m2 - m1; melhor = b - (m1 + m2) / 2 }
        }
        return melhor to janela
    }

    fun rodar(): String {
        val gerente = act.getSystemService(CameraManager::class.java)
        val cameras = JSONArray()
        val fontes = LinkedHashMap<String, String>()
        for (id in gerente.cameraIdList) {
            val c = gerente.getCameraCharacteristics(id)
            val lado = nomeDoLado(c.get(CameraCharacteristics.LENS_FACING))
            val fonte = nomeDaFonte(c.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE))
            val nivel = c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
            val fisicas = runCatching { c.physicalCameraIds.toList() }.getOrDefault(emptyList())
            cameras.put(JSONObject().apply {
                put("id", id); put("lado", lado); put("fonte_do_carimbo", fonte)
                put("nivel_de_hardware", nivel); put("fisicas", JSONArray(fisicas))
            })
            fontes.putIfAbsent(lado, fonte)
            r.nota("câmera $id ($lado): SENSOR_INFO_TIMESTAMP_SOURCE=$fonte, nível $nivel, físicas $fisicas")
            for (f in fisicas) {
                runCatching {
                    val cf = gerente.getCameraCharacteristics(f)
                    val ff = nomeDaFonte(cf.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE))
                    cameras.put(JSONObject().apply { put("id", f); put("fisica_de", id); put("fonte_do_carimbo", ff) })
                    r.nota("  física $f de $id: fonte=$ff")
                }
            }
        }
        r.por("cameras", cameras)

        val (antes, janelaAntes) = bootMenosMono()
        val gl = NucleoGl("gl-a1")
        val previa = Sumidouro(gl, "previa")
        val cam = CameraDaSonda(act, r)
        try {
            cam.ligar(cam.previa(previa, Size(1920, 1080), anotar = true))
            Thread.sleep(1500)
            val t0 = System.nanoTime()
            Thread.sleep(segundos * 1000L)
            val t1 = System.nanoTime()
            cam.desligarTudo()
            val (depois, janelaDepois) = bootMenosMono()

            val cap = synchronized(cam.carimbosDoSensor) { cam.carimbosDoSensor.filter { it[1] in t0..t1 } }
            if (cap.size < 10) return "SEM_QUADROS (${cap.size} capturas em $segundos s)"
            val atrasoBoot = cap.map { ms(it[2] - it[0]) }
            val atrasoMono = cap.map { ms(it[1] - it[0]) }
            val rb = resumo(atrasoBoot)
            val rm = resumo(atrasoMono)
            val bmMs = ms((antes + depois) / 2)
            r.por("capturas", cap.size)
            r.por("fps", arred(cap.size / (ms(t1 - t0) / 1000.0), 2))
            r.por("boottime_menos_monotonic_ms", JSONObject().apply {
                put("antes", arred(ms(antes), 4)); put("depois", arred(ms(depois), 4))
                put("janela_da_leitura_us", arred((janelaAntes + janelaDepois) / 2 / 1e3, 3))
            })
            r.por("agora_boottime_menos_carimbo_ms", rb)
            r.por("agora_monotonic_menos_carimbo_ms", rm)

            // O carimbo que a SurfaceTexture entrega é o do sensor?
            val sensor = cap.map { it[0] }.toHashSet()
            val st = previa.entre(t0, t1)
            val iguais = st.count { it.carimboNs in sensor }
            r.por("surfacetexture", JSONObject().apply {
                put("quadros", st.size); put("carimbo_igual_ao_do_sensor", iguais)
            })
            r.nota("SurfaceTexture: $iguais de ${st.size} quadros com o carimbo igual ao SENSOR_TIMESTAMP")

            val p50b = rb.getDouble("p50")
            val p50m = rm.getDouble("p50")
            val plausivel = { v: Double -> v in 0.0..1000.0 }
            val relogio = when {
                Math.abs(bmMs) < 50.0 -> "INDISTINGUIVEL (BOOTTIME−MONOTONIC = ${fmt(bmMs, 2)} ms: o aparelho não dormiu desde o boot; deixe a tela apagar uns minutos e rode de novo)"
                plausivel(p50b) && !plausivel(p50m) -> "BOOTTIME"
                plausivel(p50m) && !plausivel(p50b) -> "MONOTONIC"
                plausivel(p50m) && plausivel(p50b) -> "AMBIGUO (os dois dão atraso entre 0 e 1 s)"
                else -> "NENHUM_DOS_DOIS"
            }
            r.por("relogio_do_carimbo_da_frontal", relogio)
            r.nota("atraso de entrega: BOOTTIME p50 ${fmt(p50b, 2)} ms, MONOTONIC p50 ${fmt(p50m, 2)} ms")
            val deslocamento = when {
                relogio == "BOOTTIME" -> "para MONOTONIC: carimbo − ${fmt(bmMs, 3)} ms"
                relogio == "MONOTONIC" -> "já em MONOTONIC"
                else -> "sem conversão provada"
            }
            val base = if (relogio.startsWith("INDISTINGUIVEL")) p50b else if (relogio == "MONOTONIC") p50m else p50b
            return "frontal=${fontes["frontal"] ?: "—"} traseira=${fontes["traseira"] ?: "—"}; " +
                "carimbo da frontal em $relogio; atraso de entrega p50 ${fmt(base, 1)} ms; " +
                "BOOTTIME−MONOTONIC ${fmt(bmMs, 3)} ms ($deslocamento); " +
                "SurfaceTexture=sensor $iguais/${st.size}"
        } finally {
            cam.fechar()
            previa.liberar()
            gl.liberar()
        }
    }
}
