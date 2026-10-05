package com.quall.bancada.sondar5

import android.util.Size
import androidx.camera.core.UseCase
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * **S-A2** — o CameraX 1.4.2 (o mesmo de `apps/android`) aceita dois `VideoCapture` no mesmo bind?
 *
 * Dois braços, na frontal, cada um com use cases novos e sorvedouros novos:
 *
 *  - `dois_videocapture`: `bindToLifecycle(vc1, vc2)`;
 *  - `previa_e_dois_videocapture`: `bindToLifecycle(prévia, vc1, vc2)` — o caso do produto.
 *
 * "Aceita" só vale se **os dois** `VideoCapture` recebem quadros em 3 s. De cada um sai a
 * resolução negociada e o timebase: `UPTIME` denuncia um nó GL do CameraX no caminho (por exemplo,
 * o `StreamSharing`), e com ele o carimbo deixa de ser o do sensor.
 */
class SondaA2(private val act: SondaActivity, private val r: Relato) {

    private fun tentar(cam: CameraDaSonda, gl: NucleoGl, braco: String, comPrevia: Boolean): String {
        val pedidos = ConcurrentHashMap<String, String>()
        val s1 = Sumidouro(gl, "vc1")
        val s2 = Sumidouro(gl, "vc2")
        val sp = Sumidouro(gl, "previa")
        fun vc(nome: String, s: Sumidouro) = cam.captura(Size(1920, 1080)) { req, tb ->
            pedidos[nome] = "${req.resolution.width}x${req.resolution.height} timebase=$tb"
            r.nota("$braco: $nome pediu superfície ${pedidos[nome]}")
            s.ajustar(req.resolution)
            req.provideSurface(s.surface, act.mainExecutor) { }
        }
        val ucs = mutableListOf<UseCase>()
        if (comPrevia) ucs += cam.previa(sp, Size(1920, 1080), anotar = false)
        ucs += vc("vc1", s1)
        ucs += vc("vc2", s2)
        val o = JSONObject()
        try {
            try {
                cam.ligar(*ucs.toTypedArray())
            } catch (e: Throwable) {
                val causa = generateSequence(e) { it.cause }.last()
                val msg = "${e.javaClass.simpleName}: ${e.message}" +
                    (if (causa !== e) " (causa ${causa.javaClass.simpleName}: ${causa.message})" else "")
                o.put("resultado", "RECUSA"); o.put("erro", msg)
                r.por(braco, o)
                r.nota("$braco: bind recusado — $msg")
                return "RECUSA ($msg)"
            }
            Thread.sleep(1000)
            val t0 = System.nanoTime()
            Thread.sleep(3000)
            val t1 = System.nanoTime()
            val n1 = s1.entre(t0, t1).size
            val n2 = s2.entre(t0, t1).size
            val np = sp.entre(t0, t1).size
            o.put("quadros_vc1_3s", n1); o.put("quadros_vc2_3s", n2)
            if (comPrevia) o.put("quadros_previa_3s", np)
            o.put("pedidos", JSONObject(pedidos as Map<*, *>))
            val uptime = pedidos.values.any { it.contains("UPTIME") }
            val res = when {
                n1 > 0 && n2 > 0 -> "ACEITA"
                else -> "ACEITA_SEM_QUADROS"
            }
            o.put("resultado", res)
            r.por(braco, o)
            val desc = "$res (vc1 $n1, vc2 $n2" + (if (comPrevia) ", prévia $np" else "") +
                " quadros em 3 s; ${pedidos["vc1"] ?: "vc1 sem pedido"}; ${pedidos["vc2"] ?: "vc2 sem pedido"}" +
                (if (uptime) "; nó GL do CameraX no caminho" else "") + ")"
            r.nota("$braco: $desc")
            return desc
        } finally {
            runCatching { cam.desligarTudo() }
            Thread.sleep(800)
            s1.liberar(); s2.liberar(); sp.liberar()
        }
    }

    fun rodar(): String {
        val gl = NucleoGl("gl-a2")
        val cam = CameraDaSonda(act, r)
        try {
            val a = tentar(cam, gl, "dois_videocapture", comPrevia = false)
            val b = tentar(cam, gl, "previa_e_dois_videocapture", comPrevia = true)
            return "dois VideoCapture: $a | prévia + dois VideoCapture: $b"
        } finally {
            cam.fechar()
            gl.liberar()
        }
    }
}
