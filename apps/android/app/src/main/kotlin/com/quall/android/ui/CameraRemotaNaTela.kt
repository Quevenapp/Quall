package com.quall.android.ui

import android.annotation.SuppressLint
import android.app.Activity
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import com.quall.android.core.LogSeguro as Log
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.quall.android.capture.RegrasDosControles
import com.quall.android.core.QuallNative
import com.quall.android.receive.CameraRemotaBus
import com.quall.android.receive.EstadoDaCameraRemota

/**
 * **Os ajustes da câmera do outro lado, na tela de Exibir** (R9b, `docs/controle-remoto-da-camera.md`
 * §12): o ícone de engrenagem na barra do vídeo (a mesma engrenagem do R9 no filmador), o [PainelDaCamera]
 * desenhado das capacidades que chegaram ([FonteDoPainel.Remota]) e o toque na imagem para focar e medir.
 *
 * - **O ícone** aparece com a situação `pronto` ou `nao_permitido` (esta, com tudo apagado e "O aparelho
 *   não permite controle remoto da câmera"); em `esperando`, `sem_resposta` e `sem_camera`, não.
 * - **O painel** fica numa metade e o vídeo na outra, inteiro (R9 §4.2, como no filmador): em pé, o painel
 *   embaixo; deitado, à direita. Quem ajusta precisa julgar a imagem inteira. Uma troca de revisão das
 *   capacidades (o teto do obturador que segue o fps) passa por `esperando` por um instante: o painel
 *   aberto fica, apagado, em vez de fechar no meio do arrasto. Fecha em `sem_resposta` e `sem_camera`.
 * - **O toque na imagem**, só com o painel aberto e o filmador oferecendo `toque`: a `SurfaceView` já tem o
 *   tamanho exato do vídeo ([ReceptorActivity] encaixa a proporção), então o ponto no quadro decodificado
 *   é `x / largura`, `y / altura`. Com o painel fechado o toque segue sendo o de sempre (sair da tela
 *   cheia).
 */
@SuppressLint("ClickableViewAccessibility")
class CameraRemotaNaTela(
    private val activity: Activity,
    private val raiz: FrameLayout,
    private val video: View,
    private val superficie: View,
    private val botao: View,
    private val emTelaCheia: () -> Boolean,
) {
    private val principal = Handler(Looper.getMainLooper())
    private val fonte = FonteDoPainel.Remota { CameraRemotaBus.estado }
    private val painel = PainelDaCamera(activity, {
        fonte.takeIf { CameraRemotaBus.estado.let { it.capacidades != null && it.ajuste != null } }
    }) { abrir(false) }.apply { visibility = View.GONE }
    private val marcas = MarcasDoToque(activity)
    private var aberto = false

    private val tique = object : Runnable {
        override fun run() {
            atualizar()
            principal.postDelayed(this, RegrasDosControles.INTERVALO_DA_LEITURA_MS)
        }
    }

    private val gestos = GestureDetector(activity, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean = true
        override fun onSingleTapUp(e: MotionEvent): Boolean = tocar(e, longo = false)
        override fun onLongPress(e: MotionEvent) {
            tocar(e, longo = true)
        }
    })

    init {
        raiz.addView(painel, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        (video as? FrameLayout)?.addView(marcas, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        botao.visibility = View.GONE
        botao.setOnClickListener { abrir(!aberto) }
        superficie.setOnTouchListener { _, e ->
            if (!aberto) return@setOnTouchListener false
            gestos.onTouchEvent(e)
            true
        }
        // O recuo das barras do sistema no lado em que o painel encosta (de ponta a ponta, targetSdk 36).
        ViewCompat.setOnApplyWindowInsetsListener(painel) { v, insets ->
            val r = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val deitado = activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
            v.setPadding(activity.dp(12) + (if (deitado) 0 else r.left), activity.dp(6) + (if (deitado) r.top else 0),
                activity.dp(12) + r.right, activity.dp(6) + r.bottom)
            insets
        }
    }

    /** Liga o tique (no `onStart` da tela). */
    fun comecar() {
        principal.removeCallbacks(tique)
        principal.post(tique)
    }

    /** Para o tique (no `onStop`). */
    fun parar() {
        principal.removeCallbacks(tique)
    }

    private fun atualizar() {
        val e = CameraRemotaBus.estado
        val visivel = video.visibility == View.VISIBLE && !emTelaCheia()
        val mostra = e.mostraControles && visivel
        val v = if (mostra || (aberto && visivel)) View.VISIBLE else View.GONE
        if (botao.visibility != v) botao.visibility = v
        if (aberto && (!visivel || e.capacidades == null || e.ajuste == null ||
                e.situacao == EstadoDaCameraRemota.SEM_RESPOSTA || e.situacao == EstadoDaCameraRemota.SEM_CAMERA)) {
            abrir(false)
        }
    }

    /** Abre ou fecha o painel; o vídeo vai para a outra metade (ou volta à tela toda). */
    fun abrir(sim: Boolean) {
        if (sim == aberto) return
        aberto = sim
        painel.visibility = if (sim) View.VISIBLE else View.GONE
        botao.isSelected = sim
        Log.i("QuallReceptor", "r9b: painel da câmera do outro lado ${if (sim) "aberto" else "fechado"} (${CameraRemotaBus.estado.situacao})")
        arrumar()
    }

    /** Em pé, o painel embaixo e o vídeo em cima; deitado, o painel à direita (R9 §4.2). */
    fun arrumar() {
        val deitado = activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val tela = activity.resources.displayMetrics
        val cheio = FrameLayout.LayoutParams.MATCH_PARENT
        val lpPainel = painel.layoutParams as FrameLayout.LayoutParams
        val lpVideo = video.layoutParams as FrameLayout.LayoutParams
        if (deitado) {
            lpPainel.width = tela.widthPixels / 2
            lpPainel.height = cheio
            lpPainel.gravity = Gravity.END
            lpVideo.width = if (aberto) tela.widthPixels / 2 else cheio
            lpVideo.height = cheio
            lpVideo.gravity = Gravity.START
        } else {
            lpPainel.width = cheio
            lpPainel.height = tela.heightPixels / 2
            lpPainel.gravity = Gravity.BOTTOM
            lpVideo.width = cheio
            lpVideo.height = if (aberto) tela.heightPixels / 2 else cheio
            lpVideo.gravity = Gravity.TOP
        }
        painel.layoutParams = lpPainel
        video.layoutParams = lpVideo
        ViewCompat.requestApplyInsets(painel)
    }

    /** O toque na imagem: o ponto no quadro decodificado (0 a 1), ao filmador. */
    private fun tocar(e: MotionEvent, longo: Boolean): Boolean {
        val est = CameraRemotaBus.estado
        if (!est.vivo || superficie.width <= 0 || superficie.height <= 0) return false
        val x = e.x / superficie.width
        val y = e.y / superficie.height
        if (x !in 0f..1f || y !in 0f..1f) return false
        val st = CameraRemotaBus.tocar(x.toDouble(), y.toDouble(), longo)
        Log.i("QuallReceptor", "r9b: toque ${if (longo) "longo" else "simples"} em (%.3f, %.3f) do quadro: %s".format(
            java.util.Locale.ROOT, x, y, QuallNative.Status.nome(st)))
        if (st == QuallNative.Status.OK) {
            val om = IntArray(2)
            val os = IntArray(2)
            marcas.getLocationOnScreen(om)
            superficie.getLocationOnScreen(os)
            marcas.mostrarQuadrado(e.x + os[0] - om[0], e.y + os[1] - om[1])
        }
        return st == QuallNative.Status.OK
    }
}
