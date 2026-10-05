package com.quall.android.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import com.quall.android.teleprompter.Divisao

/**
 * A tela R5 dividida: **texto | prévia | faixa**, e a borda arrastável entre o texto e a prévia. A
 * conta é de [Divisao.comFaixa] (a do iOS); aqui só se mede, posiciona e arrasta.
 *
 * - A [faixa] (avisos, estado, barra) é medida primeiro, na largura que ela terá, e a altura entra na
 *   conta: **só a prévia** a absorve, e a linha de leitura do texto não se move quando um aviso
 *   aparece. Deitado num celular, com o texto empilhado em cima (o automático desde 30/09), a faixa
 *   é uma coluna ao lado da prévia, na banda de baixo.
 * - **A posição da borda é por formato** ([Divisao.formato]: em pé, deitado empilhado, lado a lado):
 *   a divisão pergunta a guardada ([fracaoGuardada]) quando o formato muda, no `onMeasure` — é ali
 *   que ela sabe a largura e a altura de fato, e não na rotação dita pelo sistema (30/09).
 * - **Esconder a prévia** ([previaEscondida]) é `visibility` do painel dela: a superfície morre, o
 *   divisor para de desenhar nela, e a câmera e a transmissão seguem (`docs/teleprompter-com-camera.md`
 *   §2.5, G2). O texto fica com tudo menos a faixa.
 * - **A borda** é uma zona de 44 dp **inteira do lado da prévia** ([Divisao.zona]), que nunca entra no
 *   texto — as setas azuis do enquadramento moram na ponta do texto que encosta na prévia, e a zona
 *   centrada na linha roubava o arrasto delas (bancada de 27/09, iPad). O desenho é o do iOS: uma
 *   faixa escura que esmaece a partir da linha, um fio de 1 dp na linha e o pegador no meio da zona.
 */
@SuppressLint("ViewConstructor")
class DivisaoDaTela(
    contexto: Context,
    val texto: View,
    val camera: View,
    val faixa: View,
) : ViewGroup(contexto) {

    /** Chamado a cada passo do arrasto; `soltou` no fim, que é quando se guarda. */
    var aoArrastar: ((fracao: Double, soltou: Boolean) -> Unit)? = null

    var lado: Divisao.Lado = Divisao.Lado.TOPO
        set(v) { if (field != v) { field = v; requestLayout() } }

    private var fracao: Double = Divisao.PADRAO

    /** A fração do texto no formato de agora (a conta ainda a limita pelo teto desta tela). */
    var fracaoDoTexto: Double
        get() = fracao
        set(v) {
            val f = Divisao.limitar(v)
            if (fracao != f) { fracao = f; requestLayout() }
        }

    /**
     * A fração guardada de cada formato ([Divisao.formato]); quem usa a lê das preferências. Lida de
     * novo quando o formato muda (girou, ou o lado do texto mudou).
     */
    var fracaoGuardada: (formato: String) -> Double = { Divisao.PADRAO }
        set(v) {
            field = v
            formatoDaFracao = null
            requestLayout()
        }

    /** O formato da última conta: a chave em que a borda arrastada se guarda. */
    var formato: String = "retrato"
        private set
    private var formatoDaFracao: String? = null

    var previaEscondida: Boolean = false
        set(v) {
            if (field == v) return
            field = v
            camera.visibility = if (v) View.GONE else View.VISIBLE
            requestLayout()
        }

    /** A zona da borda some com a tela cheia ou com um problema na câmera (o botão dele cairia nela). */
    var bordaPermitida: Boolean = true
        set(v) { if (field != v) { field = v; requestLayout() } }

    private val densidade = contexto.resources.displayMetrics.density

    /** As medidas do iOS, em dp. */
    private val medidas = Divisao.medidas(densidade)

    /** A última conta feita (para a tela saber onde ficou cada coisa). */
    var partes: Divisao.Partes? = null
        private set

    private var arrastandoDe: Double? = null

    private val borda = object : View(contexto) {
        private val fio = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x59FFFFFF } // branco 35 %
        private val pegador = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xE6FFFFFF.toInt() // branco 90 %
            setShadowLayer(2 * densidade, 0f, 0f, 0x99000000.toInt())
        }
        private val sombra = Paint()
        private val r = RectF()
        private var baseDoArrasto = 0.0
        private var formatoDoToque: String? = null
        private var x0 = 0f
        private var y0 = 0f

        init {
            setLayerType(LAYER_TYPE_SOFTWARE, null) // a sombra do pegador
            contentDescription = context.getString(com.quall.android.R.string.r5_borda_descricao)
            isFocusable = true
            // Fora do modo de toque, o realce padrão pintava a zona inteira, uma faixa cinza de 44 dp sobre
            // a prévia (a foto de 30/09). Ela continua focável para o leitor de tela e o teclado.
            defaultFocusHighlightEnabled = false
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        }

        override fun onDraw(canvas: Canvas) {
            val p = partes ?: return
            val ponta = p.ponta ?: return
            val w = width.toFloat()
            val h = height.toFloat()
            val empilhado = ponta == Divisao.Lado.TOPO || ponta == Divisao.Lado.BAIXO
            // A faixa escura que esmaece a partir da linha: o desenho é a área de toque.
            val (x0g, y0g, x1g, y1g) = when (ponta) {
                Divisao.Lado.TOPO -> listOf(0f, 0f, 0f, h)
                Divisao.Lado.BAIXO -> listOf(0f, h, 0f, 0f)
                Divisao.Lado.ESQUERDA -> listOf(0f, 0f, w, 0f)
                Divisao.Lado.DIREITA -> listOf(w, 0f, 0f, 0f)
            }
            sombra.shader = LinearGradient(x0g, y0g, x1g, y1g, 0x59000000, 0x00000000, Shader.TileMode.CLAMP)
            canvas.drawRect(0f, 0f, w, h, sombra)
            // O fio, na linha (a ponta da zona que encosta no texto).
            val fino = maxOf(1f, densidade)
            when (ponta) {
                Divisao.Lado.TOPO -> canvas.drawRect(0f, 0f, w, fino, fio)
                Divisao.Lado.BAIXO -> canvas.drawRect(0f, h - fino, w, h, fio)
                Divisao.Lado.ESQUERDA -> canvas.drawRect(0f, 0f, fino, h, fio)
                Divisao.Lado.DIREITA -> canvas.drawRect(w - fino, 0f, w, h, fio)
            }
            // O pegador, no meio da zona: 64 × 6 dp.
            val comprido = 64 * densidade
            val grosso = 6 * densidade
            if (empilhado) r.set(w / 2 - comprido / 2, h / 2 - grosso / 2, w / 2 + comprido / 2, h / 2 + grosso / 2)
            else r.set(w / 2 - grosso / 2, h / 2 - comprido / 2, w / 2 + grosso / 2, h / 2 + comprido / 2)
            canvas.drawRoundRect(r, grosso / 2, grosso / 2, pegador)
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            val pai = this@DivisaoDaTela
            val p = partes ?: return false
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    parent?.requestDisallowInterceptTouchEvent(true)
                    baseDoArrasto = p.fracao
                    x0 = e.rawX
                    y0 = e.rawY
                    arrastandoDe = baseDoArrasto
                    formatoDoToque = pai.formato
                }
                // Girou no meio do arrasto (o formato mudou): o arrasto acaba ali, sem guardar a fração de
                // um formato na chave do outro (a revisão do ramo, 30/09).
                MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP -> if (pai.formato != formatoDoToque) {
                    arrastandoDe = null
                    if (e.actionMasked == MotionEvent.ACTION_UP) pai.requestLayout()
                    return true
                }
            }
            when (e.actionMasked) {
                MotionEvent.ACTION_MOVE -> {
                    // Até o teto desta tela, e não só até o limite guardado: além dele a borda
                    // "grudaria" e voltaria com uma faixa morta (a revisão do código, 28/09).
                    val f = minOf(p.teto, Divisao.fracaoArrastada(pai.lado, baseDoArrasto, e.rawX - x0, e.rawY - y0, p.eixo))
                    arrastandoDe = f
                    pai.requestLayout()
                    pai.aoArrastar?.invoke(f, false)
                }
                MotionEvent.ACTION_UP -> {
                    arrastandoDe?.let { pai.fracaoDoTexto = it; pai.aoArrastar?.invoke(it, true) }
                    arrastandoDe = null
                    pai.requestLayout()
                }
                MotionEvent.ACTION_CANCEL -> {
                    // O sistema tomou o gesto (o voltar pela borda): a borda volta onde estava.
                    arrastandoDe = null
                    pai.requestLayout()
                }
            }
            return true
        }

        // A acessibilidade: o valor em % e o ajuste de 5 em 5 (o `accessibilityAdjustableAction` do iOS).
        override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
            super.onInitializeAccessibilityNodeInfo(info)
            val f = partes?.fracao ?: fracaoDoTexto
            androidx.core.view.accessibility.AccessibilityNodeInfoCompat.wrap(info).stateDescription = context.getString(com.quall.android.R.string.r5_borda_estado, f * 100)
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD)
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD)
        }

        override fun performAccessibilityAction(acao: Int, args: Bundle?): Boolean {
            val passo = when (acao) {
                AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> 0.05
                AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> -0.05
                else -> return super.performAccessibilityAction(acao, args)
            }
            val f = Divisao.limitar((partes?.fracao ?: fracaoDoTexto) + passo)
            this@DivisaoDaTela.fracaoDoTexto = f
            aoArrastar?.invoke(f, true)
            return true
        }
    }

    init {
        addView(texto)
        addView(camera)
        addView(borda)
        addView(faixa)
    }

    private fun conta(w: Int, h: Int, alturaDaFaixa: Int) = Divisao.comFaixa(
        w, h, lado, arrastandoDe ?: fracaoDoTexto, alturaDaFaixa, previaEscondida, medidas,
    )

    /**
     * O `padding` desta vista é o recorte da tela (a frontal) que a tela R5 lhe dá: a conta roda na
     * área de dentro, e o texto nunca fica sob o furo da câmera — como a área segura do iOS, que põe o
     * texto logo abaixo do entalhe do iPhone X.
     */
    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(larguraSpec), MeasureSpec.getSize(alturaSpec))
        val w = (measuredWidth - paddingLeft - paddingRight).coerceAtLeast(0)
        val h = (measuredHeight - paddingTop - paddingBottom).coerceAtLeast(0)
        // O formato pela medida de fato: girou (ou o lado mudou), a borda volta à guardada dele.
        val f = Divisao.formato(lado, w, h)
        formato = f
        if (f != formatoDaFracao) {
            formatoDaFracao = f
            fracao = Divisao.limitar(fracaoGuardada(f))
        }
        // A faixa primeiro, na largura que ela vai ter (que não depende da altura dela).
        // Na altura, no máximo a sobra (o que o texto deixa): a faixa nunca passa por cima dele.
        val p0 = conta(w, h, 0)
        val sobra = if (!previaEscondida && Divisao.empilhado(lado)) p0.previa.altura else h
        faixa.measure(
            MeasureSpec.makeMeasureSpec(p0.faixa.largura.coerceAtLeast(0), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(sobra.coerceAtLeast(0), MeasureSpec.AT_MOST),
        )
        val hF = if (faixa.visibility == View.GONE) 0 else faixa.measuredHeight
        val p = conta(w, h, hF)
        partes = p
        fun medir(v: View, r: Divisao.Retangulo) {
            if (v.visibility == View.GONE) return
            v.measure(
                MeasureSpec.makeMeasureSpec(r.largura.coerceAtLeast(0), MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(r.altura.coerceAtLeast(0), MeasureSpec.EXACTLY),
            )
        }
        medir(texto, p.texto)
        medir(camera, p.previa)
        val z = p.zona
        borda.visibility = if (z != null && bordaPermitida) View.VISIBLE else View.GONE
        if (z != null) medir(borda, z)
    }

    override fun onLayout(mudou: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val p = partes ?: return
        val x = paddingLeft
        val y = paddingTop
        fun por(v: View, q: Divisao.Retangulo) {
            if (v.visibility != View.GONE) v.layout(x + q.esquerda, y + q.topo, x + q.direita, y + q.baixo)
        }
        por(texto, p.texto)
        por(camera, p.previa)
        p.zona?.let { por(borda, it) }
        por(faixa, p.faixa)
        borda.invalidate()
    }
}
