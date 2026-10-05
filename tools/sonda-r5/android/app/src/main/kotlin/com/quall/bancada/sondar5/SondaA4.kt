package com.quall.bancada.sondar5

import android.util.Size
import androidx.camera.core.Preview
import androidx.camera.video.VideoCapture
import org.json.JSONArray
import org.json.JSONObject

/**
 * **S-A4** — o corte da câmera ao ligar (e ao desligar) o codificador, nos três braços do §2.1:
 *
 *  - `rebind_junto`: o do produto hoje (`CameraXSource.ligarCodificador`): com a prévia no ar,
 *    `unbindAll` + `bindToLifecycle(prévia, vc)` no mesmo passo; desliga com `unbind(vc)`;
 *  - `incremental`: `bindToLifecycle(vc)` com a prévia no ar; desliga com `unbind(vc)`;
 *  - `sempre_no_ar`: prévia e `VideoCapture` bindados desde o começo, o `VideoCapture` numa
 *    `SurfaceTexture` (o divisor); ligar é criar o codificador e começar a desenhar nele, e
 *    desligar é parar de desenhar — **sem tocar na câmera**.
 *
 * Nos dois primeiros o `VideoCapture` recebe a superfície de entrada de um `MediaCodec` direto,
 * como no produto. Os braços se alternam a cada repetição (a ordem da bancada, §8.20).
 *
 * Cada rodada: câmera fechada, 1 s; abre (prévia só, ou prévia + vc no `sempre_no_ar`); 2,5 s de
 * regime; **ligar** em t0; 4 s; **desligar** em t1; 3 s. Da prévia (um sorvedouro, nada na tela)
 * sai o **maior buraco entre quadros** em [t0 − 0,3 s, t0 + 4 s] e em [t1, t1 + 3 s], e quantos
 * buracos passam de 100 ms; do codificador, o tempo de t0 ao primeiro pacote; da câmera, os
 * eventos no intervalo (`CameraDevice.onClosed`/`onOpened`, `CameraState`, o `CameraManager`).
 */
class SondaA4(
    private val act: SondaActivity,
    private val r: Relato,
    private val braco: String,
    private val repeticoes: Int,
) {
    private val resolucao = Size(1920, 1080)

    private class Buraco(val maiorMs: Double, val acimaDe100: Int, val quadros: Int)

    private fun buraco(previa: Sumidouro, t0: Long, t1: Long): Buraco {
        // Inclui o último quadro antes de t0: um buraco que começa antes da ação conta inteiro.
        val todos = previa.copia().map { it.chegadaNs }
        val antes = todos.lastOrNull { it < t0 }
        val dentro = todos.filter { it in t0..t1 }
        val serie = (listOfNotNull(antes) + dentro + listOf(t1))
        val gaps = serie.zipWithNext().map { (a, b) -> ms(b - a) }
        return Buraco(gaps.maxOrNull() ?: ms(t1 - t0), gaps.count { it > 100.0 }, dentro.size)
    }

    /** Quantas vezes a câmera fechou: pelo `CameraDevice.onClosed` ou, na falta, pelo `CameraManager`. */
    private fun fechamentos(ev: List<CameraDaSonda.Evento>): Int = maxOf(
        ev.count { it.texto.startsWith("CameraDevice.onClosed") },
        ev.count { it.texto.startsWith("gerente:") && it.texto.endsWith("livre") },
    )

    private fun rodada(cam: CameraDaSonda, previa: Sumidouro, glDiv: NucleoGl, qual: String, i: Int): JSONObject {
        val o = JSONObject().apply { put("braco", qual); put("repeticao", i) }
        cam.desligarTudo()
        Thread.sleep(1000)
        var resPrevia: Size? = null
        val p: Preview = cam.previa(previa, resolucao, anotar = true) { resPrevia = it }
        var cod: Codificador? = null
        val todosOsCods = java.util.concurrent.CopyOnWriteArrayList<Codificador>()
        var resVc: Size? = null
        var timebase = "?"
        var vc: VideoCapture<SaidaDaSonda>? = null
        var fonte: Sumidouro? = null
        var divisor: Divisor? = null
        var saida: Divisor.Saida? = null
        try {
            if (qual == "sempre_no_ar") {
                val f = Sumidouro(glDiv, "divisor"); fonte = f
                divisor = Divisor(glDiv, f)
                vc = cam.captura(resolucao) { req, tb ->
                    resVc = req.resolution; timebase = tb
                    f.ajustar(req.resolution)
                    req.provideSurface(f.surface, act.mainExecutor) { }
                }
                cam.ligar(p, vc)
            } else {
                vc = cam.captura(resolucao) { req, tb ->
                    resVc = req.resolution; timebase = tb
                    val c = Codificador("a4", req.resolution.width, req.resolution.height, 8_000_000)
                    cod = c; todosOsCods += c
                    req.provideSurface(c.entrada, act.mainExecutor) { }
                }
                cam.ligar(p)
            }
            Thread.sleep(2500)

            // ---- ligar
            val t0 = System.nanoTime()
            when (qual) {
                "rebind_junto" -> cam.religarJunto(p, vc)
                "incremental" -> cam.ligar(vc)
                else -> {
                    val rv = resVc ?: error("o VideoCapture do sempre_no_ar não pediu superfície")
                    val c = Codificador("a4", rv.width, rv.height, 8_000_000)
                    cod = c; todosOsCods += c
                    saida = divisor!!.ligar("rede", c, carimbar = true)
                }
            }
            val tBind = System.nanoTime()
            Thread.sleep(4000)
            val t0fim = System.nanoTime()

            // ---- desligar
            val t1 = System.nanoTime()
            if (qual == "sempre_no_ar") divisor!!.desligar(saida!!) else cam.desligar(vc)
            val tSolta = System.nanoTime()
            Thread.sleep(3000)
            val t1fim = System.nanoTime()

            val bl = buraco(previa, t0 - 300_000_000L, t0fim)
            val bd = buraco(previa, t1, t1fim)
            val eventosLigar = cam.eventosEntre(t0, t0fim)
            val fechou = fechamentos(eventosLigar)
            val primeiro = cod?.primeiraSaidaNs?.takeIf { it > 0 }?.let { ms(it - t0) }
            o.put("resolucao_previa", resPrevia?.let { "${it.width}x${it.height}" })
            o.put("resolucao_codificador", resVc?.let { "${it.width}x${it.height}" })
            o.put("timebase", timebase)
            o.put("ligar_chamada_ms", arred(ms(tBind - t0), 1))
            o.put("ligar_primeiro_pacote_ms", primeiro?.let { arred(it, 1) })
            o.put("ligar_pacotes_em_4s", cod?.ptsUs()?.size ?: 0)
            o.put("ligar_maior_buraco_da_previa_ms", arred(bl.maiorMs, 1))
            o.put("ligar_buracos_acima_de_100ms", bl.acimaDe100)
            o.put("ligar_quadros_da_previa", bl.quadros)
            o.put("ligar_camera_fechou", fechou)
            o.put("ligar_eventos", cam.eventosJson(t0, t0fim))
            o.put("desligar_chamada_ms", arred(ms(tSolta - t1), 1))
            o.put("desligar_maior_buraco_da_previa_ms", arred(bd.maiorMs, 1))
            o.put("desligar_buracos_acima_de_100ms", bd.acimaDe100)
            o.put("desligar_camera_fechou", fechamentos(cam.eventosEntre(t1, t1fim)))
            o.put("pedidos_de_superficie_do_codificador", todosOsCods.size)
            o.put("desligar_eventos", cam.eventosJson(t1, t1fim))
            r.nota("$qual #$i: ligar buraco ${fmt(bl.maiorMs)} ms (fechou $fechou), 1º pacote ${fmt(primeiro)} ms; " +
                "desligar buraco ${fmt(bd.maiorMs)} ms; prévia ${o.opt("resolucao_previa")}, codificador ${o.opt("resolucao_codificador")}")
            return o
        } finally {
            runCatching { cam.desligarTudo() }
            Thread.sleep(300)
            todosOsCods.forEach { it.liberar() }
            fonte?.liberar()
        }
    }

    fun rodar(): String {
        val bracos = when (braco) {
            "todos" -> listOf("rebind_junto", "incremental", "sempre_no_ar")
            "rebind_junto", "incremental", "sempre_no_ar" -> listOf(braco)
            else -> return "BRACO_DESCONHECIDO ($braco)"
        }
        val glPrev = NucleoGl("gl-previa")
        val glDiv = NucleoGl("gl-divisor")
        val previa = Sumidouro(glPrev, "previa")
        val cam = CameraDaSonda(act, r)
        val rodadas = JSONArray()
        val porBraco = LinkedHashMap<String, MutableList<JSONObject>>()
        try {
            for (i in 1..repeticoes) {
                for (b in bracos) {
                    val o = runCatching { rodada(cam, previa, glDiv, b, i) }.getOrElse {
                        r.nota("$b #$i falhou: ${it.javaClass.simpleName}: ${it.message}")
                        JSONObject().apply { put("braco", b); put("repeticao", i); put("falha", "${it.javaClass.simpleName}: ${it.message}") }
                    }
                    rodadas.put(o)
                    porBraco.getOrPut(b) { mutableListOf() }.add(o)
                }
            }
        } finally {
            cam.fechar()
            previa.liberar()
            glPrev.liberar(); glDiv.liberar()
        }
        r.por("rodadas", rodadas)
        val sumario = JSONObject()
        val partes = porBraco.map { (b, l) ->
            val ok = l.filter { !it.has("falha") }
            val bur = ok.map { it.getDouble("ligar_maior_buraco_da_previa_ms") }
            val burD = ok.map { it.getDouble("desligar_maior_buraco_da_previa_ms") }
            val prim = ok.mapNotNull { if (it.isNull("ligar_primeiro_pacote_ms")) null else it.getDouble("ligar_primeiro_pacote_ms") }
            val fech = ok.count { it.getInt("ligar_camera_fechou") > 0 }
            sumario.put(b, JSONObject().apply {
                put("rodadas", l.size); put("falhas", l.size - ok.size)
                put("ligar_maior_buraco_ms", resumo(bur)); put("desligar_maior_buraco_ms", resumo(burD))
                put("ligar_primeiro_pacote_ms", resumo(prim)); put("ligar_camera_fechou_em", fech)
            })
            val pb = percentil(bur.sorted(), 50.0)
            "$b: buraco ao ligar p50 ${fmt(pb, 0)} ms (máx ${fmt(bur.maxOrNull(), 0)}), câmera fechou $fech/${ok.size}, " +
                "1º pacote p50 ${fmt(percentil(prim.sorted(), 50.0), 0)} ms, buraco ao desligar p50 ${fmt(percentil(burD.sorted(), 50.0), 0)} ms" +
                (if (ok.size < l.size) ", ${l.size - ok.size} falha(s)" else "")
        }
        r.por("sumario", sumario)
        return partes.joinToString(" | ")
    }
}
