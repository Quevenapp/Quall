package com.quall.android.ui

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.TextPaint
import android.text.TextUtils
import android.util.AttributeSet
import android.util.TypedValue
import android.view.ActionMode
import android.view.Gravity
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.RadioGroup
import android.widget.TextView
import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.appcompat.content.res.AppCompatResources
import androidx.appcompat.widget.AppCompatEditText
import androidx.appcompat.widget.AppCompatRadioButton
import androidx.appcompat.widget.AppCompatTextView
import androidx.core.content.withStyledAttributes
import com.quall.android.R
import com.quall.android.teleprompter.RepeticaoDoBotao
import kotlin.math.hypot

// ================================================================================================
// **As peças do "Estúdio de bolso"** (`docs/telas-estudio.md` §2–§4): as cores (tokens com os mesmos
// nomes nas quatro plataformas), e as peças que as telas usam — a pílula de estado, o letreiro do PIN
// (mostrar e digitar), o chip de endereço que copia, o aviso e a pilha de avisos, o ladrilho de origem e
// a grade dele, os anéis da espera, o ponto que pulsa e a lista com teto. Os botões, os textos, os
// campos, o ladrilho fixo e o botão redondo são estilos (`res/values/estilos.xml`); a marca é um
// vetor (`res/drawable/marca_quall.xml`).
//
// Ficam aqui também as peças de antes, no modelo do iOS (`docs/telas-android-como-ios.md`): o botão de
// ícone da barra, o botão que repete enquanto pressionado, a linha dos avisos e o chip de sessão da
// tela R5 e do prompter. Programáticas de propósito: o estado muda a cada tique.
//
// As vistas só desenham valores simples; quem adapta o estado do `MirrorBus`/`ReceptorBus` a elas é a
// Activity.
// ================================================================================================

/** As cores. Os tokens da §2 primeiro; depois as do iOS no escuro que as telas do teleprompter usam. */
object Cores {
    // --- os tokens do "Estúdio de bolso" (§2) ---
    const val FUNDO = 0xFF0B0B0F.toInt()
    const val SUPERFICIE = 0xFF16161D.toInt()
    const val SUPERFICIE_ALTA = 0xFF20202A.toInt()

    /** Os grupos da folha de Ajustes. */
    const val GRUPO = 0xFF1C1C24.toInt()

    /** O fundo da folha de baixo. */
    const val FOLHA = 0xFF121218.toInt()

    /** Branco a 8 %: a borda de 1 dp dos cartões. */
    const val CONTORNO = 0x14FFFFFF

    /** Branco a 10 %: a borda dos campos e das casas do PIN. */
    const val CONTORNO_CAMPO = 0x1AFFFFFF
    const val TEXTO = 0xFFF5F5F7.toInt()
    const val TEXTO2 = 0xFFA1A1AE.toInt()

    /** Rótulo de seção e legenda: nunca mais claro que isto em letra pequena. */
    const val TEXTO3 = 0xFF8B8B99.toInt()

    /** O violeta Quall: fundo do botão principal e do cartão Espelhar (texto branco, 4,7:1). */
    const val ACENTO = 0xFF6A5AF9.toInt()

    /** Ícone e texto violeta sobre o escuro (7,9:1). */
    const val ACENTO_CLARO = 0xFFA99FFF.toInt()

    /** O acento a 16 %: o fundo do ícone dos cartões e do item escolhido. */
    const val ACENTO_FUNDO = 0x296A5AF9
    const val NO_AR = 0xFFFF453A.toInt()

    /** O fundo da pílula NO AR / REC (texto branco, 4,9:1). */
    const val NO_AR_CHEIO = 0xFFD93025.toInt()
    const val AGUARDANDO = 0xFFFFB340.toInt()
    const val AGUARDANDO_TEXTO = 0xFFFFC870.toInt()
    const val CONECTADO = 0xFF32D74B.toInt()
    const val CONECTADO_TEXTO = 0xFF6BE07F.toInt()
    const val PERIGO_TEXTO = 0xFFFF8A80.toInt()

    // --- as cores do iOS no escuro (as `Color.red/.orange/...`), nos estados do teleprompter ---
    const val VERMELHO = 0xFFFF453A.toInt()
    const val LARANJA = 0xFFFF9F0A.toInt()
    const val VERDE = 0xFF30D158.toInt()
    const val AMARELO = 0xFFFFD60A.toInt()
    const val CINZA = 0xFF8E8E93.toInt()
    const val BRANCO = 0xFFFFFFFF.toInt()

    /** `Color.white.opacity(0.14)`: o fundo dos botões da barra. */
    const val FUNDO_DO_BOTAO = 0x24FFFFFF

    /** A cápsula da barra do prompter: a superfície (§6.8). */
    const val FUNDO_DA_BARRA = SUPERFICIE

    /** O chip de sessão: a superfície alta (§6.8). */
    const val FUNDO_DO_CHIP = SUPERFICIE_ALTA

    /** A letra pequena do estado. */
    const val TEXTO_SECUNDARIO = TEXTO2

    /** A cor com [alfa] (0..1). */
    fun comAlfa(cor: Int, alfa: Float): Int = Color.argb((alfa * 255).toInt(), Color.red(cor), Color.green(cor), Color.blue(cor))
}

fun Context.dp(v: Float): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

/**
 * Abaixo desta altura, a tela deitada é **baixa** (dp). É o mesmo número da R5
 * (`Divisao.Medidas.alturaDaTelaBaixa`) e do iOS.
 */
const val ALTURA_DA_TELA_BAIXA_DP = 540

/**
 * **A tela baixa** (30/09, o pedido do Pessoa Exemplo: "ficou bom o ipad centralizado, falta arrumar o tablet"):
 * deitada **e** com menos de [ALTURA_DA_TELA_BAIXA_DP] de altura — o celular deitado (o A07 tem 384 dp de
 * altura, o A10s 411). Só ela vira duas colunas (`ColunasDaTela`) e encolhe os blocos para caber. O tablet
 * deitado (o SM-X230 tem 800 dp) fica numa coluna só, centrada, de até 560 dp, como em pé e como o iPad
 * deitado. Decide a altura (`screenHeightDp`), não a largura nem o `smallestScreenWidthDp`.
 */
fun Context.telaBaixa(): Boolean {
    val c = resources.configuration
    return c.orientation == Configuration.ORIENTATION_LANDSCAPE && c.screenHeightDp in 1 until ALTURA_DA_TELA_BAIXA_DP
}
fun Context.dp(v: Int): Int = dp(v.toFloat())

/** Um fundo de cantos arredondados, como o `.cornerRadius` do SwiftUI. */
fun fundoArredondado(cor: Int, raioPx: Float): GradientDrawable = GradientDrawable().apply {
    setColor(cor)
    cornerRadius = raioPx
}

/**
 * **O botão de ícone da barra** (o `botao(simbolo:rotulo:)` do iOS): só o ícone, branco, numa caixa de
 * 44 dp de altura com fundo branco 14 % e cantos de 10 dp. O rótulo vai para a acessibilidade.
 */
class BotaoDeIcone(contexto: Context, @DrawableRes icone: Int, rotulo: String) : FrameLayout(contexto) {
    val imagem = ImageView(contexto).apply {
        setImageResource(icone)
        imageTintList = ColorStateList.valueOf(Cores.BRANCO)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private var fundo = Cores.FUNDO_DO_BOTAO

    init {
        minimumHeight = contexto.dp(44)
        background = fundoArredondado(fundo, contexto.dp(10).toFloat())
        addView(imagem, LayoutParams(contexto.dp(24), contexto.dp(24), Gravity.CENTER))
        contentDescription = rotulo
        isClickable = true
        isFocusable = true
    }

    fun trocar(@DrawableRes icone: Int, rotulo: String) {
        imagem.setImageResource(icone)
        if (contentDescription != rotulo) contentDescription = rotulo
    }

    fun pintar(cor: Int) {
        if (cor == fundo) return
        fundo = cor
        background = fundoArredondado(cor, context.dp(10).toFloat())
    }

    override fun setEnabled(enabled: Boolean) {
        super.setEnabled(enabled)
        alpha = if (enabled) 1f else 0.45f
    }
}

/**
 * **Um botão que repete enquanto pressionado** (`BotaoQueRepete` do iOS, com o ritmo de
 * [RepeticaoDoBotao]): um toque é um passo, ao soltar; segurando, os passos vêm sozinhos, o primeiro
 * em 0,4 s e os seguintes cada vez mais depressa, até soltar. Um dedo que anda mais de 10 dp desiste
 * (é rolagem, não aperto) sem dar passo nenhum — a revisão de 27/09 do iOS viu o passo no toque mudar
 * a velocidade do prompter numa rolagem. Para a acessibilidade é um botão comum: um passo por clique.
 */
@SuppressLint("ClickableViewAccessibility")
fun repetirEnquantoPressionado(v: View, passo: () -> Unit) {
    val principal = Handler(Looper.getMainLooper())
    val folga = v.context.dp(RepeticaoDoBotao.FOLGA_DP)
    var comecou = false
    var desistiu = false
    var repetiu = false
    var vez = 0
    var x0 = 0f
    var y0 = 0f
    fun agendar(v0: Int, n: Int) {
        val espera = RepeticaoDoBotao.intervalo(n) ?: return
        principal.postAtTime({
            if (!comecou || desistiu || vez != v0) return@postAtTime
            repetiu = true
            passo()
            agendar(v0, n + 1)
        }, v, SystemClock.uptimeMillis() + (espera * 1000).toLong())
    }
    fun encerrar() {
        comecou = false
        vez++
        principal.removeCallbacksAndMessages(v)
        v.alpha = if (v.isEnabled) 1f else 0.45f
    }
    v.setOnTouchListener { vista, e ->
        if (!vista.isEnabled) return@setOnTouchListener false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                comecou = true
                desistiu = false
                repetiu = false
                vez++
                x0 = e.rawX
                y0 = e.rawY
                vista.alpha = 0.6f
                agendar(vez, 1)
                true
            }
            MotionEvent.ACTION_MOVE -> {
                if (comecou && !desistiu && hypot(e.rawX - x0, e.rawY - y0) > folga) {
                    desistiu = true
                    vez++
                    vista.alpha = 1f
                    // Rolagem: devolve o gesto a quem rola (a folha de Ajustes).
                    vista.parent?.requestDisallowInterceptTouchEvent(false)
                }
                true
            }
            MotionEvent.ACTION_UP -> {
                val deuPasso = comecou && !desistiu && !repetiu
                encerrar()
                if (deuPasso) passo()
                true
            }
            MotionEvent.ACTION_CANCEL -> {
                encerrar()
                true
            }
            else -> false
        }
    }
    // O VoiceOver do Android (TalkBack) clica: um passo.
    v.setOnClickListener { passo() }
    v.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
        override fun onViewAttachedToWindow(x: View) = Unit
        override fun onViewDetachedFromWindow(x: View) = encerrar()
    })
}

/**
 * Um aviso da faixa: o texto, a cor (o fundo a 85 %) e o ícone. [curto], quando há, é o que vai na
 * linha recolhida (a forma `compacto` de `Avisos`); aberta, vale o [texto] inteiro.
 */
data class Aviso(val texto: String, val cor: Int, @DrawableRes val icone: Int, val curto: String? = null)

/** Uma ação que aparece com os avisos abertos ("Abrir os Ajustes (microfone)"). */
data class AcaoDoAviso(val rotulo: String, val acao: () -> Unit)

/**
 * **A linha dos avisos** da faixa (`FaixaDaTelaComCamera.linhaDosAvisos` do iOS): recolhida, o mais
 * grave numa linha — ícone, texto com reticências, "+N" e ▾ — com o fundo da cor dele; um toque abre
 * todos, um por cartão, e as ações; ela se recolhe sozinha em 10 s (um toque novo adia).
 */
class LinhaDosAvisos(contexto: Context) : LinearLayout(contexto) {
    private var avisos: List<Aviso> = emptyList()
    private var acoes: List<AcaoDoAviso> = emptyList()
    private var aberta = false
    private var vezDoRecolher = 0
    private val principal = Handler(Looper.getMainLooper())
    private var desenhado = ""

    /** Chamado quando a altura pode ter mudado (abrir, recolher, avisos novos). */
    var aoMudar: (() -> Unit)? = null

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER_VERTICAL
        // 48 dp de área de toque na linha recolhida (o desenho dela tem ~30).
        minimumHeight = contexto.dp(48)
        setPadding(contexto.dp(8), 0, contexto.dp(8), 0)
        setOnClickListener { alternar() }
        visibility = GONE
    }

    fun mostrar(novos: List<Aviso>, novasAcoes: List<AcaoDoAviso> = emptyList()) {
        if (novos.isEmpty()) aberta = false
        avisos = novos
        acoes = novasAcoes
        val chave = (if (aberta) "A|" else "R|") + novos.joinToString("¦") { "${it.cor}|${it.texto}" } +
            "|" + novasAcoes.joinToString("¦") { it.rotulo }
        if (chave == desenhado) return
        desenhado = chave
        desenhar()
        aoMudar?.invoke()
    }

    private fun alternar() {
        aberta = !aberta
        desenhado = ""
        mostrar(avisos, acoes)
        if (!aberta) return
        vezDoRecolher++
        val v = vezDoRecolher
        principal.postDelayed({
            if (v == vezDoRecolher && aberta) alternar()
        }, 10_000)
    }

    private fun desenhar() {
        removeAllViews()
        if (avisos.isEmpty()) {
            visibility = GONE
            return
        }
        visibility = VISIBLE
        val d = context.dp(1).toFloat()
        if (!aberta) {
            val a = avisos[0]
            val linha = linhaDeAviso(a, umaLinha = true)
            if (avisos.size > 1) {
                linha.addView(TextView(context).apply {
                    text = "+${avisos.size - 1}"
                    setTextColor(Cores.BRANCO)
                    setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    setPadding(context.dp(6), 0, context.dp(4), 0)
                })
            }
            linha.addView(ImageView(context).apply {
                setImageResource(R.drawable.ic_q_seta_baixo)
                imageTintList = ColorStateList.valueOf(Cores.BRANCO)
            }, LayoutParams(context.dp(18), context.dp(18)))
            addView(linha)
            contentDescription = a.texto + (if (avisos.size > 1) context.getString(R.string.in_avisos_mais, avisos.size - 1) else "") +
                context.getString(R.string.in_avisos_toque_para_ler)
        } else {
            // Aberta, a lista rola dentro de uma altura máxima ([onMeasure]): muitos avisos numa tela
            // baixa não empurram a faixa para cima do texto (a revisão do código, 28/09).
            val lista = LinearLayout(context).apply {
                orientation = VERTICAL
                setOnClickListener { alternar() }
            }
            addView(android.widget.ScrollView(context).apply { addView(lista) },
                LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            for ((i, a) in avisos.withIndex()) {
                lista.addView(linhaDeAviso(a, umaLinha = false), LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                    if (i > 0) topMargin = (6 * d).toInt()
                })
            }
            for (acao in acoes) {
                lista.addView(TextView(context).apply {
                    text = acao.rotulo
                    setTextColor(Cores.ACENTO_CLARO)
                    setTypeface(typeface, Typeface.BOLD)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    setPadding(0, context.dp(8), 0, context.dp(4))
                    setOnClickListener { acao.acao() }
                })
            }
            contentDescription = context.getString(R.string.in_avisos_toque_para_recolher)
        }
    }

    private fun linhaDeAviso(a0: Aviso, umaLinha: Boolean): LinearLayout = LinearLayout(context).apply {
        val a = if (umaLinha && a0.curto != null) a0.copy(texto = a0.curto) else a0
        orientation = HORIZONTAL
        gravity = if (umaLinha) Gravity.CENTER_VERTICAL else Gravity.TOP
        background = fundoArredondado(Cores.comAlfa(a.cor, 0.85f), context.dp(8).toFloat())
        setPadding(context.dp(10), context.dp(6), context.dp(10), context.dp(6))
        addView(ImageView(context).apply {
            setImageResource(a.icone)
            imageTintList = ColorStateList.valueOf(Cores.BRANCO)
        }, LayoutParams(context.dp(16), context.dp(16)).apply { rightMargin = context.dp(8); if (!umaLinha) topMargin = context.dp(1) })
        addView(TextView(context).apply {
            text = a.texto
            setTextColor(Cores.BRANCO)
            setTypeface(typeface, Typeface.BOLD)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            if (umaLinha) {
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
        }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        // O toque é da linha inteira (abrir/recolher).
        isClickable = false
    }

    /** Aberta, no máximo um terço da tela; o resto rola. */
    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        if (!aberta) return super.onMeasure(larguraSpec, alturaSpec)
        val teto = resources.displayMetrics.heightPixels / 3
        val pedido = MeasureSpec.getSize(alturaSpec)
        val limite = if (MeasureSpec.getMode(alturaSpec) == MeasureSpec.UNSPECIFIED) teto else minOf(teto, pedido)
        super.onMeasure(larguraSpec, MeasureSpec.makeMeasureSpec(limite, MeasureSpec.AT_MOST))
    }

    override fun onDetachedFromWindow() {
        principal.removeCallbacksAndMessages(null)
        super.onDetachedFromWindow()
    }
}

/**
 * **O chip de uma sessão** (o `chip` do iOS): a bolinha da cor do estado, o título e o PIN em mono
 * ("Texto 123 456"), o estado em letra pequena embaixo, e o ícone de letra grande — o toque abre o
 * endereço e o PIN em letra grande.
 *
 * **Estreito** (30/09: a R5 deitada num celular põe a faixa numa coluna de 340 dp, e os dois chips ficam
 * com ~75 dp cada, ao lado do microfone e do Gravar): sem caber o título e o PIN numa linha, o chip
 * guarda o que importa para quem vai conectar — o PIN sozinho em cima, e "Texto · estado" embaixo —, sem
 * o ícone de letra grande. Decide pela largura que recebe, na medida.
 */
class ChipDeSessao(contexto: Context, private val titulo: String) : LinearLayout(contexto) {
    private val bolinha = View(contexto)
    private val textoTitulo = TextView(contexto)
    private val textoPin = TextView(contexto)
    private val textoEstado = TextView(contexto)
    private val iconeGrande = ImageView(contexto)
    private var desenhado = ""
    private var estado = ""
    private var estreito = false
    /** A medida do PIN na letra de sempre (12, mono negrito), qualquer que seja a forma de agora. */
    private val medidaDoPin = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 12f, contexto.resources.displayMetrics)
    }

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        // 48 dp de área de toque, com o desenho de 36 do iOS: o fundo recua 6 dp em cima e embaixo.
        minimumHeight = contexto.dp(48)
        background = android.graphics.drawable.InsetDrawable(
            fundoArredondado(Cores.FUNDO_DO_CHIP, contexto.dp(9).toFloat()), 0, contexto.dp(6), 0, contexto.dp(6))
        setPadding(contexto.dp(8), contexto.dp(10), contexto.dp(8), contexto.dp(10))
        addView(bolinha, LayoutParams(contexto.dp(8), contexto.dp(8)).apply { rightMargin = contexto.dp(6) })
        val coluna = LinearLayout(contexto).apply { orientation = VERTICAL }
        val linha = LinearLayout(contexto).apply { orientation = HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        textoTitulo.apply {
            text = titulo
            setTextColor(Cores.BRANCO)
            setTypeface(typeface, Typeface.BOLD)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            maxLines = 1
        }
        textoPin.apply {
            setTextColor(Cores.BRANCO)
            setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            maxLines = 1
            setPadding(contexto.dp(4), 0, 0, 0)
        }
        textoEstado.apply {
            setTextColor(Cores.TEXTO_SECUNDARIO)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        linha.addView(textoTitulo)
        linha.addView(textoPin)
        coluna.addView(linha)
        coluna.addView(textoEstado)
        addView(coluna, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        addView(iconeGrande.apply {
            setImageResource(R.drawable.ic_q_letra_grande)
            imageTintList = ColorStateList.valueOf(Cores.BRANCO)
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LayoutParams(contexto.dp(16), contexto.dp(16)))
        isClickable = true
        isFocusable = true
    }

    fun atualizar(cor: Int, pin: String, estado: String) {
        val chave = "$cor|$pin|$estado"
        if (chave == desenhado) return
        desenhado = chave
        this.estado = estado
        bolinha.background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(cor) }
        textoPin.text = pinEspacado(pin).ifEmpty { "—" }
        escreverEstado()
        contentDescription = context.getString(R.string.in_chip_de_sessao_descricao, titulo, estado, pin.toCharArray().joinToString(" "))
    }

    private fun escreverEstado() {
        val t = if (estreito) "$titulo · $estado" else estado
        if (textoEstado.text.toString() != t) textoEstado.text = t
    }

    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        if (MeasureSpec.getMode(larguraSpec) != MeasureSpec.UNSPECIFIED) {
            // A forma larga inteira: os recuos, a bolinha, o título, o PIN e o ícone de letra grande.
            val c = context
            val precisa = c.dp(8) * 2 + c.dp(14) + c.dp(4) + c.dp(16) +
                textoTitulo.paint.measureText(titulo) + medidaDoPin.measureText(textoPin.text.toString())
            ficarEstreito(MeasureSpec.getSize(larguraSpec) < precisa)
        }
        super.onMeasure(larguraSpec, alturaSpec)
    }

    private fun ficarEstreito(e: Boolean) {
        if (e == estreito) return
        estreito = e
        val c = context
        textoTitulo.visibility = if (e) GONE else VISIBLE
        iconeGrande.visibility = if (e) GONE else VISIBLE
        textoPin.setPadding(if (e) 0 else c.dp(4), 0, 0, 0)
        textoPin.setTextSize(TypedValue.COMPLEX_UNIT_SP, if (e) 11f else 12f)
        setPadding(c.dp(if (e) 6 else 8), c.dp(10), c.dp(if (e) 6 else 8), c.dp(10))
        (bolinha.layoutParams as LayoutParams).rightMargin = c.dp(if (e) 4 else 6)
        escreverEstado()
    }
}

/**
 * **Uma faixa de aviso** empilhada (`AvisosDoTeleprompter.faixa` do iOS): o ícone, o texto inteiro em
 * branco semibold, o fundo da cor a 85 % e cantos de 10.
 */
fun faixaDeAviso(contexto: Context, a: Aviso): View = LinearLayout(contexto).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.TOP
    background = fundoArredondado(Cores.comAlfa(a.cor, 0.85f), contexto.dp(10).toFloat())
    setPadding(contexto.dp(12), contexto.dp(8), contexto.dp(12), contexto.dp(8))
    addView(ImageView(contexto).apply {
        setImageResource(a.icone)
        imageTintList = ColorStateList.valueOf(Cores.BRANCO)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }, LinearLayout.LayoutParams(contexto.dp(18), contexto.dp(18)).apply { rightMargin = contexto.dp(8); topMargin = contexto.dp(1) })
    addView(TextView(contexto).apply {
        text = a.texto
        setTextColor(Cores.BRANCO)
        setTypeface(typeface, Typeface.BOLD)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
    }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
}

/**
 * A mensagem do `MirrorBus` na espera é aviso? A do anúncio ("anunciando como X em _quall._tcp",
 * "sem anúncio mDNS…") e a da "última recusa" são estado, e o iOS não as mostra (a conferência de
 * 28/09 no A07): ficam no diário. O resto (a tentativa anterior que falhou, a câmera parada, o
 * controlador de taxa) é aviso. Decidido pelo campo [com.quall.android.mirror.MirrorBus.Estado.mensagemEhAnuncio],
 * e não pelo começo da frase: ela é traduzida (`docs/traducao.md`).
 */
fun mensagemDoVideoEhAviso(e: com.quall.android.mirror.MirrorBus.Estado): Boolean =
    e.mensagem.isNotBlank() && !e.mensagemEhAnuncio

/** "123456" → "123 456", como o iOS; outro tamanho, como veio; vazio, vazio. */
fun pinEspacado(pin: String): String = if (pin.length == 6) pin.substring(0, 3) + " " + pin.substring(3) else pin

/** Um spinner branco, o `ProgressView().tint(.white)` do iOS. */
fun spinnerBranco(contexto: Context): ProgressBar = ProgressBar(contexto).apply {
    isIndeterminate = true
    indeterminateTintList = ColorStateList.valueOf(Cores.BRANCO)
}

// ================================================================================================
// As peças novas do "Estúdio de bolso" (§4 e §11)
// ================================================================================================

/** Um círculo cheio de [cor]. */
fun bolinha(cor: Int): GradientDrawable = GradientDrawable().apply {
    shape = GradientDrawable.OVAL
    setColor(cor)
}

/** Um ícone `ic_q_*` tingido e no tamanho [ladoPx] (para as vistas que desenham o próprio ícone). */
fun Context.iconeTingido(@DrawableRes icone: Int, cor: Int, ladoPx: Int): Drawable? =
    AppCompatResources.getDrawable(this, icone)?.mutate()?.apply {
        setTint(cor)
        setBounds(0, 0, ladoPx, ladoPx)
    }

/**
 * **A pílula de estado** (§4), a luz de estúdio: altura 28, cápsula, a bolinha de 8 e a palavra em 12
 * bold caixa alta espaçada. NO AR / REC: o vermelho cheio com texto e bolinha brancos. AGUARDANDO: o
 * âmbar a 16 % com o texto #FFC870. ABRINDO: o mesmo âmbar, com a roda no lugar da bolinha. CONECTADO: o
 * verde a 14 % com o texto #6BE07F.
 */
class PilulaDeEstado @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : LinearLayout(contexto, atributos) {

    /** [CONVERTENDO] (30/09, a tela do DVD): o vermelho do REC — um arquivo sendo gravado. */
    enum class Estado(@androidx.annotation.StringRes val palavra: Int) {
        NO_AR(R.string.in_pilula_no_ar), REC(R.string.in_pilula_rec), AGUARDANDO(R.string.in_pilula_aguardando),
        ABRINDO(R.string.in_pilula_abrindo), CONECTADO(R.string.in_pilula_conectado),
        CONVERTENDO(R.string.in_pilula_convertendo),
    }

    private val ponto = View(contexto)
    private val roda = ProgressBar(contexto).apply { isIndeterminate = true }
    private val palavra = TextView(contexto)

    var estado: Estado? = null
        private set

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = contexto.dp(28)
        setPadding(contexto.dp(12), 0, contexto.dp(12), 0)
        addView(ponto, LayoutParams(contexto.dp(8), contexto.dp(8)))
        addView(roda, LayoutParams(contexto.dp(12), contexto.dp(12)))
        palavra.apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setTypeface(Typeface.DEFAULT, Typeface.BOLD)
            letterSpacing = 0.1f
            maxLines = 1
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        addView(palavra, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
            leftMargin = contexto.dp(8)
        })
        mostrar(Estado.AGUARDANDO)
    }

    fun mostrar(e: Estado) {
        if (e == estado) return
        estado = e
        val fundo: Int
        val texto: Int
        val cor: Int
        when (e) {
            Estado.NO_AR, Estado.REC, Estado.CONVERTENDO -> {
                fundo = Cores.NO_AR_CHEIO; texto = Cores.BRANCO; cor = Cores.BRANCO
            }
            Estado.AGUARDANDO, Estado.ABRINDO -> {
                fundo = Cores.comAlfa(Cores.AGUARDANDO, 0.16f); texto = Cores.AGUARDANDO_TEXTO; cor = Cores.AGUARDANDO
            }
            Estado.CONECTADO -> {
                fundo = Cores.comAlfa(Cores.CONECTADO, 0.14f); texto = Cores.CONECTADO_TEXTO; cor = Cores.CONECTADO
            }
        }
        background = fundoArredondado(fundo, context.dp(14).toFloat())
        palavra.setTextColor(texto)
        val p = context.getString(e.palavra)
        palavra.text = p
        ponto.background = bolinha(cor)
        ponto.visibility = if (e == Estado.ABRINDO) GONE else VISIBLE
        roda.visibility = if (e == Estado.ABRINDO) VISIBLE else GONE
        roda.indeterminateTintList = ColorStateList.valueOf(cor)
        contentDescription = p.lowercase(context.resources.configuration.locales[0])
    }
}

/**
 * O desenho das seis casas do PIN (§4, "Letreiro do PIN"), comum ao letreiro que mostra e ao campo que
 * recebe: casas de 44 × 60, cantos de 12, a superfície com a borda branca a 10 %, o dígito em mono bold;
 * 7 de espaço entre as casas e 10 a mais entre os dois grupos de três. As medidas são em sp, e não em
 * dp: as casas crescem com o tamanho da letra do sistema (§11.1). Numa largura que não cabe, as casas
 * estreitam (a altura fica).
 */
internal class CasasDoPin(vista: View, digitoSp: Float) {
    private val m = vista.resources.displayMetrics
    private fun sp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v, m)
    private val d = m.density
    private val casaL = sp(44f)
    private val alturaDaCasa = sp(60f)
    private val vao = sp(7f)
    private val entreGrupos = sp(10f)
    private val raio = 12 * d
    private val retangulo = RectF()
    private val fundo = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Cores.SUPERFICIE }
    private val borda = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = d
        color = Cores.CONTORNO_CAMPO
    }
    private val bordaDaVez = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2 * d
        color = Cores.ACENTO
    }
    private val tamanhoDoDigito = sp(digitoSp)
    private val tinta = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        color = Cores.TEXTO
        textAlign = Paint.Align.CENTER
    }

    val larguraNatural: Float get() = 6 * casaL + 5 * vao + entreGrupos
    val altura: Int get() = alturaDaCasa.toInt()

    /** As seis casas a partir de ([x0], [y0]), na largura [largura]; [daVez] (0..5) ganha a borda no acento. */
    fun desenhar(c: Canvas, x0: Float, y0: Float, largura: Float, digitos: String, daVez: Int) {
        val escala = (largura / larguraNatural).coerceAtMost(1f)
        val l = casaL * escala
        val meia = bordaDaVez.strokeWidth / 2
        tinta.textSize = tamanhoDoDigito * escala.coerceAtLeast(0.7f)
        var x = x0 + (largura - larguraNatural * escala) / 2
        for (i in 0 until 6) {
            if (i == 3) x += entreGrupos * escala
            retangulo.set(x + meia, y0 + meia, x + l - meia, y0 + alturaDaCasa - meia)
            c.drawRoundRect(retangulo, raio, raio, fundo)
            c.drawRoundRect(retangulo, raio, raio, if (i == daVez) bordaDaVez else borda)
            digitos.getOrNull(i)?.let { ch ->
                val base = retangulo.centerY() - (tinta.descent() + tinta.ascent()) / 2
                c.drawText(ch.toString(), retangulo.centerX(), base, tinta)
            }
            x += l + vao * escala
        }
    }
}

/**
 * **O letreiro do PIN** (§4, §11.3): seis casas de 44 × 60 em dois grupos de três, o dígito mono bold. É
 * **um `TextView` só**, sempre à vista na espera, e o **texto** dele é o PIN com o espaço no meio
 * ("482 719", ou vazio antes de o PIN existir) — `aa-corrida.py`, `emissor_android.py` e
 * `prova-android-para-ios.py` leem `textPin`, tiram o espaço e exigem seis dígitos; `laco-de-audio.py`
 * procura `\d{3}\s?\d{3}` na árvore. As casas são o desenho dele (`onDraw`). A acessibilidade diz
 * "PIN 4 8 2 7 1 9".
 *
 * [emLinha]: a forma curta de quem já tem pares (a vista ao lado diz "Aparelho novo? PIN", §6.4): o
 * mesmo texto, em mono `texto2`, sem casas.
 */
class LetreiroDoPin @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : AppCompatTextView(contexto, atributos) {
    private val casas = CasasDoPin(this, 32f)

    var emLinha: Boolean = false
        set(v) {
            if (field == v) return
            field = v
            aplicarForma()
        }

    init {
        contexto.withStyledAttributes(atributos, R.styleable.LetreiroDoPin) {
            emLinha = getBoolean(R.styleable.LetreiroDoPin_emLinha, false)
        }
        maxLines = 1
        aplicarForma()
    }

    private fun aplicarForma() {
        if (emLinha) {
            setTextColor(Cores.TEXTO2)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            typeface = Typeface.MONOSPACE
        } else {
            setTextColor(Cores.TEXTO)
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        }
        requestLayout()
        invalidate()
    }

    /** O PIN a mostrar (vazio antes de ele existir: nenhum marcador, que a bancada leria como PIN). */
    fun mostrar(pin: String) {
        val t = pinEspacado(pin)
        if (text.toString() != t) {
            text = t
            // O modo de casas mede/desenha sem o Layout do TextView. setText sozinho
            // pode não invalidar esse desenho; o próximo frame deve mostrar o PIN novo.
            invalidate()
        }
        contentDescription = if (pin.isEmpty()) "PIN" else "PIN " + pin.toCharArray().joinToString(" ") // i18n-fora: PIN é igual nos dois idiomas
    }

    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        if (emLinha) return super.onMeasure(larguraSpec, alturaSpec)
        val natural = casas.larguraNatural.toInt() + paddingLeft + paddingRight
        setMeasuredDimension(
            resolveSize(natural, larguraSpec),
            resolveSize(casas.altura + paddingTop + paddingBottom, alturaSpec),
        )
    }

    override fun onDraw(canvas: Canvas) {
        if (emLinha) return super.onDraw(canvas)
        val largura = (width - paddingLeft - paddingRight).toFloat()
        casas.desenhar(canvas, paddingLeft.toFloat(), paddingTop.toFloat(), largura,
            text.toString().filterNot { it.isWhitespace() }, daVez = -1)
    }
}

/**
 * **As casas para digitar o PIN** (§4, Exibir e Controlar; §11.3): as mesmas seis casas do letreiro, com
 * a casa da vez em borda 2 no acento. É um `EditText` de verdade, visível, com os limites cobrindo as
 * seis casas — `aparelho.py` toca no centro de `editPin`, apaga com DEL e digita — e as casas são o
 * desenho dele: nenhuma outra vista por cima pega o toque. O cursor fica sempre no fim; sem seleção.
 */
class CampoDoPin @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : AppCompatEditText(contexto, atributos) {
    private val casas = CasasDoPin(this, 30f)

    init {
        // Sem o fundo do `EditText` e sem o recuo que ele deixaria: os limites são as seis casas.
        background = null
        setPadding(0, 0, 0, 0)
        isCursorVisible = false
        isLongClickable = false
        customSelectionActionModeCallback = object : ActionMode.Callback {
            override fun onCreateActionMode(modo: ActionMode?, menu: Menu?) = false
            override fun onPrepareActionMode(modo: ActionMode?, menu: Menu?) = false
            override fun onActionItemClicked(modo: ActionMode?, item: MenuItem?) = false
            override fun onDestroyActionMode(modo: ActionMode?) = Unit
        }
    }

    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        val natural = casas.larguraNatural.toInt() + paddingLeft + paddingRight
        setMeasuredDimension(
            resolveSize(natural, larguraSpec),
            resolveSize(casas.altura + paddingTop + paddingBottom, alturaSpec),
        )
    }

    override fun onDraw(canvas: Canvas) {
        val digitos = text?.toString().orEmpty()
        val largura = (width - paddingLeft - paddingRight).toFloat()
        casas.desenhar(canvas, paddingLeft.toFloat(), paddingTop.toFloat(), largura, digitos,
            daVez = if (isFocused) digitos.length.coerceAtMost(5) else -1)
    }

    override fun onSelectionChanged(inicio: Int, fim: Int) {
        super.onSelectionChanged(inicio, fim)
        val t = text ?: return
        if (inicio != t.length || fim != t.length) setSelection(t.length)
    }

    override fun onTextChanged(texto: CharSequence?, inicio: Int, antes: Int, depois: Int) {
        super.onTextChanged(texto, inicio, antes, depois)
        invalidate()
    }

    override fun onFocusChanged(foco: Boolean, direcao: Int, antes: Rect?) {
        super.onFocusChanged(foco, direcao, antes)
        invalidate()
    }
}

/**
 * **O chip de endereço** (§4, §11.3): a cápsula de 40, a superfície com o contorno, o endereço em mono 15
 * e o ícone de copiar no `acentoClaro` (um `compoundDrawable`); tocar copia e diz "Copiado" num Toast. O
 * texto é só o `IP:porta` (ou "sem rede") — a bancada o lê (`textMirrorAddress`). A acessibilidade diz
 * "Copiar o endereço {endereço}". [copiavel] falso ("sem rede"): sem ícone e sem toque.
 */
class ChipDeEndereco @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : AppCompatTextView(contexto, atributos) {

    var copiavel: Boolean = true
        set(v) {
            // Sem mudança, nada: as telas da placa e do DVD atribuem a cada desenho, e o ícone novo pedia
            // o relayout da tela inteira (a revisão do ramo, 30/09).
            if (field == v) return
            field = v
            aplicarIcone()
        }

    init {
        setBackgroundResource(R.drawable.capsula)
        typeface = Typeface.MONOSPACE
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        setTextColor(Cores.TEXTO)
        gravity = Gravity.CENTER_VERTICAL
        minHeight = contexto.dp(40)
        setPadding(contexto.dp(16), 0, contexto.dp(14), 0)
        maxLines = 1
        compoundDrawablePadding = contexto.dp(10)
        setOnClickListener { copiar() }
        aplicarIcone()
    }

    private fun aplicarIcone() {
        val icone = if (copiavel) context.iconeTingido(R.drawable.ic_q_copiar, Cores.ACENTO_CLARO, context.dp(16)) else null
        setCompoundDrawablesRelative(null, null, icone, null)
        isClickable = copiavel
        isFocusable = copiavel
        descrever()
    }

    override fun onTextChanged(texto: CharSequence?, inicio: Int, antes: Int, depois: Int) {
        super.onTextChanged(texto, inicio, antes, depois)
        descrever()
    }

    /** Chamado também de dentro do construtor do `TextView` (o primeiro `setText`), com [copiavel] ainda falso. */
    private fun descrever() {
        contentDescription = if (copiavel) context.getString(R.string.in_copiar_endereco, text ?: "") else null
    }

    /** Copia o endereço para a área de transferência. */
    fun copiar() {
        if (!copiavel) return
        val t = text?.toString().orEmpty().trim()
        if (t.isEmpty()) return
        val area = context.getSystemService(ClipboardManager::class.java) ?: return
        area.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.in_endereco_do_quall), t))
        Toast.makeText(context, context.getString(R.string.in_copiado), Toast.LENGTH_SHORT).show()
    }
}

/**
 * **O aviso** (§4): cantos de 14, o ícone e o texto em 13. Âmbar (#FFB340 a 12 % / texto #FFC870),
 * vermelho (a 16 % / #FF8A80) ou informação (a superfície / `texto2`, ícone `acentoClaro`).
 *
 * Dentro de uma [PilhaDeAvisos], a visibilidade pedida pelo estado ([desejada]) e a de fato se separam:
 * a pilha mostra no máximo N e recolhe o resto num "+N". Quem desenha continua escrevendo
 * `visibility` como sempre.
 */
class AvisoDaTela @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : AppCompatTextView(contexto, atributos) {

    enum class Tipo { AMBAR, VERMELHO, INFO }

    var tipo: Tipo = Tipo.AMBAR
        set(v) {
            if (field == v && pintado) return
            field = v
            pintar()
        }
    private var pintado = false

    /**
     * **Sobre a imagem** (30/09: o "A imagem parou…" por cima das barras de cor da placa tinha o texto
     * vermelho sobre a caixa vermelha translúcida, ilegível): a superfície opaca, a borda e o ícone na cor
     * do caso, e o texto claro.
     */
    var sobreImagem: Boolean = false
        set(v) {
            if (field == v) return
            field = v
            pintar()
        }

    /** A visibilidade que o estado pede; a pilha decide a de fato. */
    var desejada: Int = visibility
        private set
    private var aplicando = false

    init {
        contexto.withStyledAttributes(atributos, R.styleable.AvisoDaTela) {
            tipo = Tipo.entries[getInt(R.styleable.AvisoDaTela_tipoDoAviso, 0).coerceIn(0, 2)]
        }
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setLineSpacing(0f, 1.1f)
        setPadding(contexto.dp(12), contexto.dp(10), contexto.dp(12), contexto.dp(10))
        compoundDrawablePadding = contexto.dp(10)
        gravity = Gravity.CENTER_VERTICAL or Gravity.START
        pintar()
    }

    private fun pintar() {
        val fundo: Int
        val texto: Int
        val icone: Int
        val corDoIcone: Int
        when (tipo) {
            Tipo.AMBAR -> {
                fundo = R.drawable.aviso_ambar; texto = Cores.AGUARDANDO_TEXTO; icone = R.drawable.ic_q_aviso; corDoIcone = Cores.AGUARDANDO
            }
            Tipo.VERMELHO -> {
                fundo = R.drawable.aviso_vermelho; texto = Cores.PERIGO_TEXTO; icone = R.drawable.ic_q_aviso; corDoIcone = Cores.PERIGO_TEXTO
            }
            Tipo.INFO -> {
                fundo = R.drawable.aviso_info; texto = Cores.TEXTO2; icone = R.drawable.ic_q_info; corDoIcone = Cores.ACENTO_CLARO
            }
        }
        if (sobreImagem) {
            background = GradientDrawable().apply {
                setColor(Cores.SUPERFICIE)
                cornerRadius = context.dp(14).toFloat()
                setStroke(context.dp(1), Cores.comAlfa(corDoIcone, 0.7f))
            }
            setTextColor(Cores.TEXTO)
        } else {
            setBackgroundResource(fundo)
            setTextColor(texto)
        }
        setCompoundDrawablesRelative(context.iconeTingido(icone, corDoIcone, context.dp(18)), null, null, null)
        pintado = true
    }

    override fun setVisibility(v: Int) {
        if (aplicando) {
            super.setVisibility(v)
            return
        }
        desejada = v
        val pilha = parent as? PilhaDeAvisos
        if (pilha == null) super.setVisibility(v) else pilha.reorganizar()
    }

    /** Só a pilha chama: a visibilidade de fato, sem mexer na pedida. */
    internal fun aplicar(v: Int) {
        if (super.getVisibility() == v) return
        aplicando = true
        super.setVisibility(v)
        aplicando = false
    }
}

/**
 * **A pilha de avisos**: os [AvisoDaTela] um embaixo do outro, com 8 de espaço, no máximo [aVista] à
 * vista; o resto fica recolhido numa linha "+N avisos" que abre e fecha (§6.5 e §11.1: dois na câmera no
 * ar, um nos formulários).
 */
class PilhaDeAvisos @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : LinearLayout(contexto, atributos) {
    var aVista: Int = Int.MAX_VALUE
        set(v) {
            field = v
            reorganizar()
        }
    private var aberta = false
    private val mais = TextView(contexto).apply {
        setTextColor(Cores.ACENTO_CLARO)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setPadding(contexto.dp(4), contexto.dp(4), contexto.dp(4), contexto.dp(4))
        minHeight = contexto.dp(32)
        gravity = Gravity.CENTER_VERTICAL
        visibility = GONE
        setOnClickListener {
            aberta = !aberta
            reorganizar()
        }
    }

    /** Quantos avisos o estado pede agora (à vista ou recolhidos). */
    val pedidos: Int get() = (0 until childCount).count { (getChildAt(it) as? AvisoDaTela)?.desejada == VISIBLE }

    init {
        orientation = VERTICAL
        contexto.withStyledAttributes(atributos, R.styleable.PilhaDeAvisos) {
            aVista = getInt(R.styleable.PilhaDeAvisos_avisosAVista, Int.MAX_VALUE)
        }
        dividerDrawable = GradientDrawable().apply {
            setColor(Color.TRANSPARENT)
            setSize(0, contexto.dp(8))
        }
        showDividers = SHOW_DIVIDER_MIDDLE
    }

    override fun onFinishInflate() {
        super.onFinishInflate()
        addView(mais, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        reorganizar()
    }

    /** Chamado quando um aviso pede para aparecer ou sumir. */
    var aoReorganizar: (() -> Unit)? = null

    fun reorganizar() {
        val avisos = (0 until childCount).map { getChildAt(it) }.filterIsInstance<AvisoDaTela>()
        val querem = avisos.count { it.desejada == VISIBLE }
        if (querem <= aVista) aberta = false
        val limite = if (aberta) Int.MAX_VALUE else aVista
        var mostrados = 0
        for (a in avisos) {
            val ver = a.desejada == VISIBLE && mostrados < limite
            if (ver) mostrados++
            a.aplicar(if (ver) VISIBLE else if (a.desejada == VISIBLE) GONE else a.desejada)
        }
        val escondidos = querem - mostrados
        // Só o que mudou: reescrever o mesmo texto ainda dispara evento de acessibilidade, e a bancada
        // lê a espera por `uiautomator`, que precisa da tela ociosa (`Textos.kt`).
        mais.seMudou(when {
            aberta -> context.getString(R.string.in_recolher_os_avisos)
            escondidos == 1 -> context.getString(R.string.in_mais_um_aviso)
            else -> context.getString(R.string.in_mais_avisos, escondidos)
        })
        val vMais = if (querem > aVista) VISIBLE else GONE
        if (mais.visibility != vMais) mais.visibility = vMais
        val vPilha = if (querem > 0) VISIBLE else GONE
        if (visibility != vPilha) visibility = vPilha
        aoReorganizar?.invoke()
    }
}

/**
 * **O ladrilho de origem** (§4, §6.2, §11.3): o `RadioButton` de cada origem de Espelhar — filho direto
 * de `radioGroupFonte`, com a origem no `tag`, como sempre —, desenhado como ladrilho: cantos de 18, a
 * superfície com o contorno, o ícone num quadrado de 32 no alto e o nome embaixo. Escolhido: o acento a
 * 14 %, a borda de 2 no acento e o selo redondo com ✓ no canto.
 */
class LadrilhoDeOrigem @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : AppCompatRadioButton(contexto, atributos) {
    private val d = contexto.resources.displayMetrics.density
    private val caixa = RectF()
    private val tinta = Paint(Paint.ANTI_ALIAS_FLAG)
    private val marca: Drawable? = contexto.iconeTingido(R.drawable.ic_q_check, Cores.BRANCO, (13 * d).toInt())
    private var desenhoDoIcone: Drawable? = contexto.iconeTingido(R.drawable.ic_q_celular, Cores.ACENTO_CLARO, (18 * d).toInt())

    @DrawableRes
    var icone: Int = R.drawable.ic_q_celular
        set(v) {
            field = v
            desenhoDoIcone = context.iconeTingido(v, Cores.ACENTO_CLARO, (18 * d).toInt())
            invalidate()
        }

    init {
        buttonDrawable = null
        setBackgroundResource(R.drawable.ladrilho_de_escolha)
        setTextColor(Cores.TEXTO)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.START or Gravity.BOTTOM
        minHeight = (84 * d).toInt()
        val p = (12 * d).toInt()
        setPadding(p, p + (32 * d).toInt() + (8 * d).toInt(), p, p)
        maxLines = 2
        ellipsize = TextUtils.TruncateAt.END
    }

    override fun setChecked(marcado: Boolean) {
        super.setChecked(marcado)
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val x = 12 * d
        val y = 12 * d
        caixa.set(x, y, x + 32 * d, y + 32 * d)
        tinta.color = if (isChecked) Cores.comAlfa(Cores.ACENTO, 0.30f) else Cores.ACENTO_FUNDO
        canvas.drawRoundRect(caixa, 10 * d, 10 * d, tinta)
        desenhoDoIcone?.let { ic ->
            ic.setTint(if (isChecked) 0xFFE0DBFF.toInt() else Cores.ACENTO_CLARO)
            canvas.save()
            canvas.translate(x + 7 * d, y + 7 * d)
            ic.draw(canvas)
            canvas.restore()
        }
        super.onDraw(canvas)
        if (isChecked) {
            val cx = width - 10 * d - 11 * d
            val cy = 10 * d + 11 * d
            tinta.color = Cores.ACENTO
            canvas.drawCircle(cx, cy, 11 * d, tinta)
            marca?.let { m ->
                canvas.save()
                canvas.translate(cx - 6.5f * d, cy - 6.5f * d)
                m.draw(canvas)
                canvas.restore()
            }
        }
    }
}

/**
 * **A grade das origens** (§6.2, §11.3): o `RadioGroup` de Espelhar, com os [LadrilhoDeOrigem] (filhos
 * diretos) em duas colunas de mesma largura e, em cada linha, a mesma altura. Só o arranjo muda; a
 * escolha é a do `RadioGroup`.
 */
class GradeDeOrigens @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : RadioGroup(contexto, atributos) {
    private val vao = contexto.dp(8)

    private fun visiveis(): List<View> = (0 until childCount).map { getChildAt(it) }.filter { it.visibility != GONE }

    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        val largura = MeasureSpec.getSize(larguraSpec)
        val coluna = ((largura - paddingLeft - paddingRight - vao) / 2).coerceAtLeast(0)
        val exata = MeasureSpec.makeMeasureSpec(coluna, MeasureSpec.EXACTLY)
        var altura = paddingTop + paddingBottom
        visiveis().chunked(2).forEachIndexed { i, par ->
            var linha = 0
            for (v in par) {
                v.measure(exata, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
                linha = maxOf(linha, v.measuredHeight)
            }
            for (v in par) v.measure(exata, MeasureSpec.makeMeasureSpec(linha, MeasureSpec.EXACTLY))
            altura += linha + if (i > 0) vao else 0
        }
        setMeasuredDimension(largura, resolveSize(altura, alturaSpec))
    }

    override fun onLayout(mudou: Boolean, esq: Int, topo: Int, dir: Int, base: Int) {
        var y = paddingTop
        for (par in visiveis().chunked(2)) {
            var x = paddingLeft
            var linha = 0
            for (v in par) {
                v.layout(x, y, x + v.measuredWidth, y + v.measuredHeight)
                x += v.measuredWidth + vao
                linha = maxOf(linha, v.measuredHeight)
            }
            y += linha + vao
        }
    }
}

/**
 * **A caixa com teto** (30/09, a lista de títulos do DVD): tão alta quanto o conteúdo, até o [teto]; o que
 * passa dele rola **dentro** dela, e a tela não (o R16, como a lista "NA REDE AGORA" do Exibir). O teto
 * muda com a orientação (a tela o troca em `onConfigurationChanged`).
 */
class CaixaComTeto @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : androidx.core.widget.NestedScrollView(contexto, atributos) {
    var teto: Int = contexto.dp(172)
        set(v) {
            if (field == v) return
            field = v
            requestLayout()
        }

    init {
        contexto.withStyledAttributes(atributos, R.styleable.CaixaComTeto) {
            teto = getDimensionPixelSize(R.styleable.CaixaComTeto_tetoDaAltura, teto)
        }
        isFillViewport = false
        // Fora do modo de toque, o realce padrão velava a caixa inteira (não é um controle; os títulos são).
        defaultFocusHighlightEnabled = false
    }

    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        val dada = MeasureSpec.getSize(alturaSpec)
        val limite = if (MeasureSpec.getMode(alturaSpec) == MeasureSpec.UNSPECIFIED) teto else minOf(teto, dada)
        super.onMeasure(larguraSpec, MeasureSpec.makeMeasureSpec(limite, MeasureSpec.AT_MOST))
    }
}

/**
 * **As colunas da tela** (§11.1): em retrato, os filhos se empilham na ordem do XML, e o primeiro com
 * `app:noPe` desce até o pé (o espaço que sobra entra antes dele — o `Space` de peso 1 de antes); em
 * paisagem, duas colunas, cada filho na sua (`app:coluna`), a da direita com [fracaoDaDireita] da largura.
 * Decide pela configuração (`onConfigurationChanged` das telas com `configChanges`), sem `layout-land`
 * e sem reinflar: os filhos continuam os mesmos, com os mesmos ids, no mesmo pai.
 *
 * Os filhos com `app:noVidro` ficam, com [vidroLigado], sobre o cartão de vidro escuro (preto a 85 %,
 * cantos de 22, §6.5 e §11.1) — o bloco da espera sobre a prévia da câmera.
 *
 * **Duas colunas só na tela baixa** (30/09, [telaBaixa]: deitada e com menos de 540 dp de altura, o
 * celular deitado). O tablet deitado fica numa coluna só, como em pé e como o iPad deitado. Com
 * [soNaTelaBaixa] falso (a câmera no ar, com os controles na borda direita), duas colunas em qualquer
 * paisagem, como antes.
 *
 * **Tela larga** (`smallestScreenWidthDp >= 600`, o tablet; o celular deitado passa de 600 dp de largura
 * e não entra): com [limitarLargura], uma coluna de no máximo 560 dp (em pé e, desde 30/09, deitado), e as
 * duas com no máximo 520 dp cada quando houver duas, o conjunto centrado na horizontal; com
 * [centralizarNaAltura], centrado também na altura quando sobra (e aí o `noPe` não desce). O vidro fica com
 * no máximo 560 dp, centrado na coluna. No celular nada disto muda.
 *
 * **O filho que estica** (`app:estica`, 30/09; a prévia da placa e a do DVD, que entraram no R16): fica com
 * a altura que sobra na coluna dele, no mínimo o `minHeight` e no máximo `app:proporcaoMaxima` × a largura
 * (a imagem 4:3 não precisa de mais). Só com a altura dada (o `fillViewport` da rolagem mede de novo com
 * ela quando o conteúdo cabe); sem ela, o mínimo — e aí a tela rola, como antes.
 */
class ColunasDaTela @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : ViewGroup(contexto, atributos) {

    class LayoutParams : MarginLayoutParams {
        var direita = false
        var noPe = false
        var noVidro = false
        var gravidade = Gravity.START
        /** Fica com a altura que sobra na coluna (no mínimo o `minHeight`; no máximo [proporcaoMaxima] × a largura). */
        var estica = false
        var proporcaoMaxima = 0f

        constructor(c: Context, a: AttributeSet?) : super(c, a) {
            c.withStyledAttributes(a, R.styleable.ColunasDaTela_Layout) {
                direita = getInt(R.styleable.ColunasDaTela_Layout_coluna, 0) == 1
                noPe = getBoolean(R.styleable.ColunasDaTela_Layout_noPe, false)
                noVidro = getBoolean(R.styleable.ColunasDaTela_Layout_noVidro, false)
                estica = getBoolean(R.styleable.ColunasDaTela_Layout_estica, false)
                proporcaoMaxima = getFloat(R.styleable.ColunasDaTela_Layout_proporcaoMaxima, 0f)
                gravidade = getInt(R.styleable.ColunasDaTela_Layout_android_layout_gravity, Gravity.START)
            }
        }

        constructor(largura: Int, altura: Int) : super(largura, altura)
        constructor(p: ViewGroup.LayoutParams) : super(p)
    }

    var fracaoDaDireita = 0.5f
        set(v) {
            if (field == v) return
            field = v
            requestLayout()
        }

    var vidroLigado = false
        set(v) {
            if (field == v) return
            field = v
            requestLayout()
            invalidate()
        }

    /** A coluna da direita centrada na altura, em paisagem (sem filho `noPe` nela). */
    var centralizarADireita = false

    /** Na tela larga, o teto de largura das colunas (desligado na câmera no ar, que ocupa a tela). */
    var limitarLargura = true
        set(v) {
            if (field == v) return
            field = v
            requestLayout()
        }

    /** Na tela larga, o conteúdo centrado também na altura quando sobra (o Início, a espera, o Exibir). */
    var centralizarNaAltura = false
        set(v) {
            if (field == v) return
            field = v
            requestLayout()
        }

    /**
     * Duas colunas: só na tela baixa ([telaBaixa]); com [soNaTelaBaixa] falso, em qualquer paisagem (a
     * câmera no ar, cuja coluna da direita é a dos controles).
     */
    var soNaTelaBaixa = true
        set(v) {
            if (field == v) return
            field = v
            requestLayout()
        }

    val paisagem: Boolean get() = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE &&
        (!soNaTelaBaixa || context.telaBaixa())

    /** O tablet (e não o celular deitado): a largura menor da tela passa de 600 dp. */
    val telaLarga: Boolean get() = resources.configuration.smallestScreenWidthDp >= 600

    private val vao = contexto.dp(24)
    private val folgaDoVidro = contexto.dp(16)
    private val folgaVerticalDoVidro = contexto.dp(14)
    private val tetoDaColuna = contexto.dp(560)
    private val tetoDeCadaColuna = contexto.dp(520)
    private val vidro: Drawable? = AppCompatResources.getDrawable(contexto, R.drawable.cartao_de_vidro)
    private val retanguloDoVidro = Rect()

    init {
        contexto.withStyledAttributes(atributos, R.styleable.ColunasDaTela) {
            fracaoDaDireita = getFloat(R.styleable.ColunasDaTela_fracaoDaDireita, 0.5f)
            centralizarNaAltura = getBoolean(R.styleable.ColunasDaTela_centralizarNaAltura, false)
        }
    }

    override fun generateLayoutParams(a: AttributeSet?): ViewGroup.LayoutParams = LayoutParams(context, a)
    override fun generateDefaultLayoutParams(): ViewGroup.LayoutParams = LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    override fun generateLayoutParams(p: ViewGroup.LayoutParams?): ViewGroup.LayoutParams = LayoutParams(p ?: generateDefaultLayoutParams())
    override fun checkLayoutParams(p: ViewGroup.LayoutParams?) = p is LayoutParams
    override fun shouldDelayChildPressedState() = false

    private fun lp(v: View) = v.layoutParams as LayoutParams
    private fun visiveis() = (0 until childCount).map { getChildAt(it) }.filter { it.visibility != GONE }
    private fun noVidro(v: View) = vidroLigado && lp(v).noVidro

    /** A largura do vidro numa coluna de [largura]: a coluna toda; na tela larga, no máximo 560 dp. */
    private fun larguraDoVidro(largura: Int) = if (telaLarga) minOf(largura, tetoDaColuna) else largura

    /** Uma coluna: os filhos, onde ela começa e a largura. */
    private class Coluna(val filhos: List<View>, val x: Int, val largura: Int)

    /** As colunas (uma em retrato; duas em paisagem), já com o teto e o centramento da tela larga. */
    private fun arranjo(largura: Int): List<Coluna> {
        val total = (largura - paddingLeft - paddingRight).coerceAtLeast(0)
        val limitar = telaLarga && limitarLargura
        val todos = visiveis()
        val esquerda = if (paisagem) todos.filter { !lp(it).direita } else todos
        val direita = if (paisagem) todos.filter { lp(it).direita } else emptyList()
        if (esquerda.isEmpty() || direita.isEmpty()) {
            val w = if (limitar) minOf(total, tetoDaColuna) else total
            return listOf(Coluna(esquerda.ifEmpty { direita }, paddingLeft + (total - w) / 2, w))
        }
        var wD = ((total - vao) * fracaoDaDireita).toInt()
        var wE = total - vao - wD
        if (limitar) {
            wD = minOf(wD, tetoDeCadaColuna)
            wE = minOf(wE, tetoDeCadaColuna)
        }
        val xE = paddingLeft + (total - (wE + vao + wD)) / 2
        return listOf(Coluna(esquerda, xE, wE), Coluna(direita, xE + wE + vao, wD))
    }

    private fun medir(v: View, largura: Int) {
        val p = lp(v)
        val base = if (noVidro(v)) larguraDoVidro(largura) - 2 * folgaDoVidro else largura
        val disponivel = (base - p.leftMargin - p.rightMargin).coerceAtLeast(0)
        val w = when (p.width) {
            ViewGroup.LayoutParams.MATCH_PARENT -> MeasureSpec.makeMeasureSpec(disponivel, MeasureSpec.EXACTLY)
            ViewGroup.LayoutParams.WRAP_CONTENT -> MeasureSpec.makeMeasureSpec(disponivel, MeasureSpec.AT_MOST)
            else -> MeasureSpec.makeMeasureSpec(minOf(p.width, disponivel), MeasureSpec.EXACTLY)
        }
        val h = if (p.height >= 0) MeasureSpec.makeMeasureSpec(p.height, MeasureSpec.EXACTLY)
            else MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
        v.measure(w, h)
    }

    /**
     * O primeiro filho com `estica` da coluna fica com o que sobra da [dada] (a altura de dentro), entre o
     * `minHeight` dele e o teto da proporção; sem altura dada ([dada] < 0), com o mínimo.
     */
    private fun esticar(coluna: Coluna, dada: Int) {
        val v = coluna.filhos.firstOrNull { lp(it).estica } ?: return
        val p = lp(v)
        val minimo = v.minimumHeight
        val teto = if (p.proporcaoMaxima > 0f) (v.measuredWidth * p.proporcaoMaxima).toInt() else Int.MAX_VALUE
        val outros = altura(coluna.filhos) - v.measuredHeight
        val h = (if (dada >= 0) dada - outros else minimo).coerceAtMost(teto).coerceAtLeast(minimo)
        v.measure(
            MeasureSpec.makeMeasureSpec(v.measuredWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY),
        )
    }

    /** A altura de uma coluna já medida, com as folgas do vidro. */
    private fun altura(coluna: List<View>): Int {
        var total = 0
        var antes = false
        for (v in coluna) {
            val p = lp(v)
            val dentro = noVidro(v)
            if (dentro != antes) total += folgaVerticalDoVidro
            antes = dentro
            total += v.measuredHeight + p.topMargin + p.bottomMargin
        }
        if (antes) total += folgaVerticalDoVidro
        return total
    }

    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        val largura = MeasureSpec.getSize(larguraSpec)
        val colunas = arranjo(largura)
        for (c in colunas) c.filhos.forEach { medir(it, c.largura) }
        val dada = if (MeasureSpec.getMode(alturaSpec) == MeasureSpec.EXACTLY) {
            MeasureSpec.getSize(alturaSpec) - paddingTop - paddingBottom
        } else -1
        for (c in colunas) esticar(c, dada)
        val precisa = paddingTop + paddingBottom + (colunas.maxOfOrNull { altura(it.filhos) } ?: 0)
        val altura = if (MeasureSpec.getMode(alturaSpec) == MeasureSpec.EXACTLY) {
            maxOf(MeasureSpec.getSize(alturaSpec), precisa)
        } else {
            precisa
        }
        setMeasuredDimension(largura, altura)
    }

    override fun onLayout(mudou: Boolean, esq: Int, topo: Int, dir: Int, base: Int) {
        val colunas = arranjo(width)
        val alto = paddingTop
        val pe = height - paddingBottom
        val noMeio = telaLarga && centralizarNaAltura
        colunas.forEachIndexed { i, c ->
            posicionar(c, alto, pe, centralizar = noMeio || (i == 1 && centralizarADireita), ignorarPe = noMeio)
        }
    }

    private fun posicionar(coluna: Coluna, alto: Int, pe: Int, centralizar: Boolean, ignorarPe: Boolean) {
        val filhos = coluna.filhos
        val sobra = ((pe - alto) - altura(filhos)).coerceAtLeast(0)
        val temPe = !ignorarPe && filhos.any { lp(it).noPe }
        var y = alto + if (centralizar && !temPe) sobra / 2 else 0
        var usouASobra = !temPe
        var antes = false
        val larguraDoVidro = larguraDoVidro(coluna.largura)
        val xDoVidro = coluna.x + (coluna.largura - larguraDoVidro) / 2
        for (v in filhos) {
            val p = lp(v)
            if (!usouASobra && p.noPe) {
                y += sobra
                usouASobra = true
            }
            val dentro = noVidro(v)
            if (dentro != antes) y += folgaVerticalDoVidro
            antes = dentro
            y += p.topMargin
            val areaX = (if (dentro) xDoVidro + folgaDoVidro else coluna.x) + p.leftMargin
            val areaL = (if (dentro) larguraDoVidro - 2 * folgaDoVidro else coluna.largura) - p.leftMargin - p.rightMargin
            val w = v.measuredWidth
            val g = Gravity.getAbsoluteGravity(p.gravidade, layoutDirection) and Gravity.HORIZONTAL_GRAVITY_MASK
            val x = when (g) {
                Gravity.CENTER_HORIZONTAL -> areaX + (areaL - w) / 2
                Gravity.RIGHT -> areaX + areaL - w
                else -> areaX
            }
            v.layout(x, y, x + w, y + v.measuredHeight)
            y += v.measuredHeight + p.bottomMargin
        }
    }

    override fun dispatchDraw(canvas: Canvas) {
        val fundo = vidro
        if (vidroLigado && fundo != null) {
            // O cartão fica atrás dos filhos `noVidro`: na largura do vidro da coluna deles; na altura, a
            // folga em cima e embaixo.
            for (c in arranjo(width)) {
                var achou = false
                retanguloDoVidro.setEmpty()
                for (v in c.filhos) {
                    if (!lp(v).noVidro) continue
                    if (!achou) retanguloDoVidro.set(v.left, v.top, v.right, v.bottom) else retanguloDoVidro.union(v.left, v.top, v.right, v.bottom)
                    achou = true
                }
                if (!achou) continue
                val l = larguraDoVidro(c.largura)
                val x = c.x + (c.largura - l) / 2
                fundo.setBounds(x, retanguloDoVidro.top - folgaVerticalDoVidro, x + l, retanguloDoVidro.bottom + folgaVerticalDoVidro)
                fundo.draw(canvas)
            }
        }
        super.dispatchDraw(canvas)
    }
}

/**
 * Uma animação que respira sem parar enquanto a vista está à vista — e que não anda com "remover
 * animações" ligado (`ValueAnimator.areAnimatorsEnabled()`, o "reduzir movimento" do Android).
 */
private class Respiracao(private val vista: View, duracaoMs: Long) {
    var fase = 0f
        private set
    private val animador = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = duracaoMs
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener {
            fase = it.animatedValue as Float
            vista.invalidate()
        }
    }

    fun visivel(sim: Boolean) {
        if (sim && ValueAnimator.areAnimatorsEnabled()) {
            if (!animador.isStarted) animador.start()
        } else {
            animador.cancel()
            fase = 0f
        }
    }

    /** 0 → 1 → 0 ao longo de uma volta. */
    val onda: Float get() = 0.5f - 0.5f * kotlin.math.cos(2 * Math.PI * fase).toFloat()
}

/**
 * **Os anéis da espera** (§6.4): o ícone de espelhar num círculo âmbar a 16 %, com dois anéis âmbar em
 * volta que pulsam devagar (2 s), parados com "remover animações". [comAneis] falso: só o círculo e o
 * ícone, menor (§11.1: com um Aviso à vista, o ícone fica sem os anéis).
 */
class AneisDaEspera @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : View(contexto, atributos) {
    private val d = contexto.resources.displayMetrics.density
    private val respiracao = Respiracao(this, 2_000)
    private val miolo = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Cores.comAlfa(Cores.AGUARDANDO, 0.16f) }
    private val anel = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * d
        color = Cores.AGUARDANDO
    }
    private val icone = contexto.iconeTingido(R.drawable.ic_q_espelhar, Cores.AGUARDANDO_TEXTO, (28 * d).toInt())

    var comAneis = true
        set(v) {
            if (field == v) return
            field = v
            respiracao.visivel(isShown && v)
            requestLayout()
            invalidate()
        }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        val lado = ((if (comAneis) 124 else 60) * d).toInt()
        setMeasuredDimension(resolveSize(lado, larguraSpec), resolveSize(lado, alturaSpec))
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        if (comAneis) {
            val onda = respiracao.onda
            anel.alpha = (255 * (0.18f + 0.12f * onda)).toInt()
            canvas.drawCircle(cx, cy, (61.25f - 2f * (1 - onda)) * d, anel)
            anel.alpha = (255 * (0.32f + 0.16f * onda)).toInt()
            canvas.drawCircle(cx, cy, (44.25f - 1.5f * (1 - onda)) * d, anel)
        }
        canvas.drawCircle(cx, cy, 30 * d, miolo)
        icone?.let {
            canvas.save()
            canvas.translate(cx - 14 * d, cy - 14 * d)
            it.draw(canvas)
            canvas.restore()
        }
    }

    override fun onVisibilityAggregated(visivel: Boolean) {
        super.onVisibilityAggregated(visivel)
        respiracao.visivel(visivel && comAneis)
    }

    override fun onDetachedFromWindow() {
        respiracao.visivel(false)
        super.onDetachedFromWindow()
    }
}

/** **O ponto que pulsa** do "procurando" (§6.6): a bolinha violeta com o halo que respira. */
class PontoQuePulsa @JvmOverloads constructor(
    contexto: Context,
    atributos: AttributeSet? = null,
) : View(contexto, atributos) {
    private val d = contexto.resources.displayMetrics.density
    private val respiracao = Respiracao(this, 1_400)
    private val tinta = Paint(Paint.ANTI_ALIAS_FLAG)

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
        val lado = (14 * d).toInt()
        setMeasuredDimension(resolveSize(lado, larguraSpec), resolveSize(lado, alturaSpec))
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        tinta.color = Cores.comAlfa(0xFF8B7DFF.toInt(), 0.25f * (0.4f + 0.6f * respiracao.onda))
        canvas.drawCircle(cx, cy, 7 * d, tinta)
        tinta.color = 0xFF8B7DFF.toInt()
        canvas.drawCircle(cx, cy, 3 * d, tinta)
    }

    override fun onVisibilityAggregated(visivel: Boolean) {
        super.onVisibilityAggregated(visivel)
        respiracao.visivel(visivel)
    }

    override fun onDetachedFromWindow() {
        respiracao.visivel(false)
        super.onDetachedFromWindow()
    }
}
