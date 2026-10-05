package com.quall.bancada.sondar5

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.camera.lifecycle.ProcessCameraProvider
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * A casca das sondas. Recebe a sonda por extra e roda numa thread de trabalho:
 *
 *     am start -n com.quall.bancada.sondar5/.SondaActivity --es sonda S-A1 [--ei segundos 20] …
 *
 * (`A1` sem o `S-` também vale.) A tela só mostra o andamento em texto: **nenhuma sonda desenha a
 * imagem da câmera**, e nenhuma guarda imagem ou som. É `ComponentActivity` porque o
 * `bindToLifecycle` do CameraX pede um `LifecycleOwner`.
 *
 * Cada sonda tem um teto de tempo ([limiteEmSegundos]). Estourou, o vigia fecha o relato com
 * `TEMPO_ESGOTADO`, solta a câmera e **mata o processo** — uma sonda presa não pode deixar a
 * câmera ou o microfone abertos.
 */
class SondaActivity : ComponentActivity() {
    private lateinit var texto: TextView
    private val principal = Handler(Looper.getMainLooper())
    @Volatile private var rodando = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        texto = TextView(this).apply {
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(32, 32, 32, 32)
            text = "Sonda R5: esperando `--es sonda`"
        }
        setContentView(texto)
        comecar(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        comecar(intent)
    }

    fun mostrar(t: String) = principal.post { texto.text = t }

    /** Roda [bloco] na thread principal e espera o fim (o CameraX exige a principal no bind). */
    fun <T> naPrincipal(bloco: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return bloco()
        var r: Result<T>? = null
        val l = CountDownLatch(1)
        principal.post { r = runCatching(bloco); l.countDown() }
        check(l.await(15, TimeUnit.SECONDS)) { "a thread principal não respondeu em 15 s" }
        return r!!.getOrThrow()
    }

    private fun limiteEmSegundos(id: String, i: Intent, segundos: Int): Int = when (id) {
        "S-A1" -> segundos + 30
        "S-A2" -> 60
        "S-A3" -> segundos + 60
        "S-A4" -> {
            val braços = if ((i.getStringExtra("braco") ?: "todos") == "todos") 3 else 1
            i.getIntExtra("repeticoes", 3) * braços * 16 + 30
        }
        "S-A5" -> 45
        "S-A6" -> 4 * segundos + 60
        else -> 10
    }

    private fun comecar(i: Intent?) {
        val bruto = i?.getStringExtra("sonda") ?: return
        val id = "S-" + bruto.trim().uppercase().removePrefix("S-")
        if (rodando) { mostrar("já há uma sonda rodando"); return }
        val precisa = when (id) {
            "S-A5", "S-A6" -> listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
            else -> listOf(Manifest.permission.CAMERA)
        }
        val faltam = precisa.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (faltam.isNotEmpty()) {
            // Ler não é pedir (docs/regras-de-frente.md): o roteiro instala com `-g`; se não
            // concedeu, a sonda **pede** e o Pessoa Exemplo toca no diálogo.
            requestPermissions(faltam.toTypedArray(), 1)
            mostrar("faltam permissões: $faltam — conceda e rode de novo")
            val r = Relato(this, id); r.nota("sem permissão: $faltam"); r.fechar("SEM_PERMISSAO")
            return
        }
        rodando = true
        val segundosPedidos = i.getIntExtra("segundos", 0)
        val segundos = if (segundosPedidos > 0) segundosPedidos else when (id) {
            "S-A1" -> 10
            "S-A3" -> 60
            "S-A6" -> 30
            else -> 0
        }
        val r = Relato(this, id)
        r.por("extras", i.extras?.keySet()?.associateWith { i.extras?.get(it)?.toString() }?.let { org.json.JSONObject(it) })
        val limite = limiteEmSegundos(id, i, segundos)
        r.nota("começou; teto de $limite s")
        val trabalho = thread(name = "sonda-$id") {
            mostrar("rodando $id…")
            val veredito = try {
                when (id) {
                    "S-A1" -> SondaA1(this, r, segundos).rodar()
                    "S-A2" -> SondaA2(this, r).rodar()
                    "S-A3" -> SondaA3(this, r, segundos, i.getStringExtra("braco") ?: "ambos").rodar()
                    "S-A4" -> SondaA4(this, r, i.getStringExtra("braco") ?: "todos",
                        i.getIntExtra("repeticoes", 3)).rodar()
                    "S-A5" -> SondaA5(this, r, i.getStringExtra("braco") ?: "acrescentar",
                        i.getBooleanExtra("fundo", false)).rodar()
                    "S-A6" -> SondaA6(this, r, segundos, i.getIntExtra("hz", 1000)).rodar()
                    else -> { r.nota("sonda desconhecida: $bruto"); "DESCONHECIDA" }
                }
            } catch (t: Throwable) {
                r.nota("falhou: ${t.javaClass.name}: ${t.message}"); android.util.Log.e("SondaR5", "pilha", t)
                "FALHOU ${t.javaClass.simpleName}: ${t.message}"
            }
            r.fechar(veredito)
            mostrar("$id: $veredito")
            rodando = false
        }
        thread(name = "vigia-$id", isDaemon = true) {
            trabalho.join(limite * 1000L)
            if (trabalho.isAlive && r.fechar("TEMPO_ESGOTADO (teto de $limite s)")) {
                mostrar("$id: tempo esgotado")
                // Solta a câmera antes de morrer; o microfone morre com o processo.
                runCatching {
                    naPrincipal { ProcessCameraProvider.getInstance(this).get(2, TimeUnit.SECONDS).unbindAll() }
                }
                Thread.sleep(500)
                Process.killProcess(Process.myPid())
            }
        }
    }
}
