package com.quall.bancada.sondar5

import android.util.Size
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * **S-A3** — o divisor GL do desenho (§2.1, braço a).
 *
 * A frontal com **um** `VideoCapture` bindado junto da prévia (as duas em sorvedouros, nada na
 * tela). A superfície do `VideoCapture` é uma `SurfaceTexture` nossa; cada quadro dela é desenhado
 * em **duas** superfícies de `MediaCodec`:
 *
 *  - `gravacao`: na resolução que o `VideoCapture` negociou (pedida 1920x1080), 12 Mbit/s;
 *  - `rede`: escalada no GL para 720 linhas (1280x720 a partir de 1080p), 4 Mbit/s.
 *
 * Dois braços, um depois do outro, cada um com metade dos [segundos] e codificadores novos:
 *
 *  - `com_carimbo`: cada troca leva `eglPresentationTimeANDROID(carimbo da SurfaceTexture)`;
 *  - `sem_carimbo`: o codificador carimba sozinho.
 *
 * Para cada saída: quantos PTS de saída são **exatamente** um carimbo da câmera (±1 µs), a
 * distância do PTS ao carimbo da câmera e à hora da troca (`MONOTONIC`), PTS que não crescem, o fps
 * e o custo GL por quadro. E, uma vez, se o carimbo da `SurfaceTexture` é o `SENSOR_TIMESTAMP`.
 * A saída dos codificadores é contada e descartada.
 */
class SondaA3(
    private val act: SondaActivity,
    private val r: Relato,
    private val segundos: Int,
    private val braco: String,
) {
    private fun maisPerto(ordenado: LongArray, v: Long): Long {
        var i = java.util.Arrays.binarySearch(ordenado, v)
        if (i >= 0) return ordenado[i]
        i = -i - 1
        val a = if (i > 0) ordenado[i - 1] else null
        val b = if (i < ordenado.size) ordenado[i] else null
        return when {
            a == null -> b!!
            b == null -> a
            v - a <= b - v -> a
            else -> b
        }
    }

    private fun analisar(s: Divisor.Saida, dur: Double): Pair<JSONObject, String> {
        val trocas = synchronized(s) { ArrayList(s.trocas) }
        val custo = synchronized(s) { s.custoNs.map { ms(it) } }
        val pts = s.cod.ptsUs()
        val o = JSONObject()
        o.put("tamanho", "${s.cod.largura}x${s.cod.altura}")
        o.put("carimbar", s.carimbar)
        o.put("quadros_desenhados", trocas.size)
        o.put("pacotes_de_saida", pts.size)
        o.put("quadros_chave", s.cod.chaves)
        o.put("fps_de_saida", arred(pts.size / dur, 2))
        o.put("falhas_do_eglPresentationTimeANDROID", s.falhasDoCarimbo)
        o.put("falhas_da_troca", s.falhasDaTroca)
        o.put("custo_gl_ms", resumo(custo))
        if (pts.isEmpty() || trocas.isEmpty()) return o to "${s.nome}: sem saída"
        val cameraUs = trocas.map { it[0] / 1000 }.sorted().toLongArray()
        val trocaUs = trocas.map { it[1] / 1000 }.sorted().toLongArray()
        val conjunto = cameraUs.toHashSet()
        val iguais = pts.count { it in conjunto || (it - 1) in conjunto || (it + 1) in conjunto }
        val naoCrescem = pts.zipWithNext().count { (a, b) -> b <= a }
        val aCamera = pts.map { (it - maisPerto(cameraUs, it)) / 1000.0 }
        val aTroca = pts.map { (it - maisPerto(trocaUs, it)) / 1000.0 }
        o.put("pts_igual_ao_carimbo_da_camera", iguais)
        o.put("pts_que_nao_crescem", naoCrescem)
        o.put("pts_menos_carimbo_da_camera_mais_perto_ms", resumo(aCamera))
        o.put("pts_menos_hora_da_troca_mais_perto_ms", resumo(aTroca))
        // Sem o carimbo, a distância ao carimbo da câmera mais perto é o resto de um deslocamento
        // grande módulo o período do quadro; o deslocamento de verdade é o da troca do mesmo quadro.
        if (trocas.size == pts.size) {
            val desl = trocas.indices.map { (pts[it] * 1000 - trocas[it][0]) / 1e6 }
            o.put("pts_menos_carimbo_do_mesmo_indice_ms", resumo(desl))
        }
        val pct = 100.0 * iguais / pts.size
        val txt = "${s.nome} ${s.cod.largura}x${s.cod.altura}: PTS=câmera ${fmt(pct, 1)} % ($iguais/${pts.size}), " +
            "|PTS−troca| p50 ${fmt(Math.abs(resumo(aTroca).getDouble("p50")), 2)} ms, ${fmt(pts.size / dur, 1)} fps"
        return o to txt
    }

    private fun rodarBraco(
        nome: String, carimbar: Boolean, divisor: Divisor, grav: Size, rede: Size, dur: Int,
    ): String {
        val cg = Codificador("gravacao", grav.width, grav.height, 12_000_000)
        val cr = Codificador("rede", rede.width, rede.height, 4_000_000)
        val sg = divisor.ligar("gravacao", cg, carimbar)
        val sr = divisor.ligar("rede", cr, carimbar)
        val t0 = System.nanoTime()
        Thread.sleep(dur * 1000L)
        divisor.desligar(sg)
        divisor.desligar(sr)
        val d = ms(System.nanoTime() - t0) / 1000.0
        Thread.sleep(300)
        cg.liberar(); cr.liberar()
        val (og, tg) = analisar(sg, d)
        val (oRede, tr) = analisar(sr, d)
        r.por(nome, JSONObject().apply { put("gravacao", og); put("rede", oRede); put("segundos", arred(d, 2)) })
        r.nota("$nome: $tg; $tr")
        return "$nome: $tg; $tr"
    }

    fun rodar(): String {
        val glDiv = NucleoGl("gl-divisor")
        val glPrev = NucleoGl("gl-previa")
        val fonte = Sumidouro(glDiv, "camera")
        val previa = Sumidouro(glPrev, "previa")
        val divisor = Divisor(glDiv, fonte)
        val cam = CameraDaSonda(act, r)
        var resVc: Size? = null
        var timebase = "?"
        val pediu = CountDownLatch(1)
        try {
            val vc = cam.captura(Size(1920, 1080)) { req, tb ->
                resVc = req.resolution; timebase = tb
                r.nota("VideoCapture pediu superfície ${req.resolution.width}x${req.resolution.height}, timebase $tb")
                fonte.ajustar(req.resolution)
                req.provideSurface(fonte.surface, act.mainExecutor) { }
                pediu.countDown()
            }
            cam.ligar(cam.previa(previa, Size(1920, 1080), anotar = true), vc)
            if (!pediu.await(8, TimeUnit.SECONDS)) return "SEM_SUPERFICIE (o VideoCapture não pediu superfície em 8 s)"
            Thread.sleep(1500)
            val grav = resVc!!
            // A rede: 720 linhas no lado menor, largura proporcional, múltiplos de 16.
            val menor = minOf(grav.width, grav.height)
            val escala = if (menor > 720) 720.0 / menor else 1.0
            fun m16(v: Double) = (Math.round(v / 16.0) * 16).toInt().coerceAtLeast(16)
            val rede = Size(m16(grav.width * escala), m16(grav.height * escala))
            r.por("timebase_do_videocapture", timebase)
            r.por("resolucao_gravacao", "${grav.width}x${grav.height}")
            r.por("resolucao_rede", "${rede.width}x${rede.height}")

            val bracos = when (braco) {
                "com_carimbo" -> listOf("com_carimbo" to true)
                "sem_carimbo" -> listOf("sem_carimbo" to false)
                else -> listOf("com_carimbo" to true, "sem_carimbo" to false)
            }
            val dur = maxOf(5, segundos / bracos.size)
            val tInicio = System.nanoTime()
            val partes = bracos.map { (n, c) -> rodarBraco(n, c, divisor, grav, rede, dur).also { Thread.sleep(700) } }
            val tFim = System.nanoTime()

            // O carimbo da SurfaceTexture do VideoCapture é o SENSOR_TIMESTAMP?
            val sensor = synchronized(cam.carimbosDoSensor) { cam.carimbosDoSensor.map { it[0] }.toHashSet() }
            val qs = fonte.entre(tInicio, tFim)
            val iguais = qs.count { it.carimboNs in sensor }
            r.por("surfacetexture_igual_ao_sensor", JSONObject().apply { put("quadros", qs.size); put("iguais", iguais) })
            r.por("quadros_da_camera", qs.size)
            r.por("fps_da_camera", arred(qs.size / (ms(tFim - tInicio) / 1000.0), 2))
            return "timebase $timebase; ${grav.width}x${grav.height} + ${rede.width}x${rede.height}; " +
                partes.joinToString(" | ") + " | SurfaceTexture=sensor $iguais/${qs.size}"
        } finally {
            cam.fechar()
            fonte.liberar(); previa.liberar()
            glDiv.liberar(); glPrev.liberar()
        }
    }
}
