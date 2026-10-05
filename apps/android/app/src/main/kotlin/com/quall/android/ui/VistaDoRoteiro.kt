package com.quall.android.ui

import android.content.Context
import com.quall.android.R
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.text.LineBreaker
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.AttributeSet
import com.quall.android.core.LogSeguro as Log
import android.util.TypedValue
import android.view.Choreographer
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import com.quall.android.teleprompter.Ancora
import com.quall.android.teleprompter.Diagramacao
import com.quall.android.teleprompter.Enquadramento
import com.quall.android.teleprompter.GiroDoTexto
import com.quall.android.teleprompter.Percurso
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.abs

/**
 * **O texto do prompter**, rolando.
 *
 * ## Por que uma vista própria, e não um `TextView` num `ScrollView`
 *
 * Rolar devagar é o caso normal de um teleprompter — uma linha por segundo numa fonte de 48 sp são
 * ~130 px/s, ~2 px por quadro. Aqui a posição é calculada em ponto flutuante **a partir do tempo do
 * quadro** do `Choreographer` (e não de um passo fixo por quadro, nem do `scrollBy` inteiro de um
 * `ScrollView`): **velocidade constante**, e um quadro atrasado anda o que atrasou, sem a leitura
 * desacelerar quando o aparelho soluça. O texto é desenhado com `translate` em ponto flutuante.
 *
 * **O que não está provado**: se o compositor desenha o texto em fração de pixel na vertical ou o
 * prende à grade de pixels (o HWUI costuma prender glifos numa translação pura). Se prende, a 2,2
 * px por quadro o texto anda 2, 2, 2, 3 — como qualquer lista rolando no Android. A cadência dos
 * quadros foi medida (`dumpsys gfxinfo`, no relato da F6b); a posição do glifo na tela, não.
 *
 * `Layout.draw` desenha só as linhas que caem no recorte (`getLineRangeForDraw`), então um roteiro
 * de 128 KiB custa, por quadro, o mesmo que um de uma página.
 *
 * ## O espelho é desta vista, e só dela
 *
 * `canvas.scale(-1, 1)` em torno do centro: inverte o texto na horizontal, para ler no reflexo do
 * vidro. Não encosta em vídeo nenhum nem no `MIRROR_MODE` da câmera (§3 do contrato); a marca da
 * linha de leitura é simétrica e fica igual nos dois sentidos.
 *
 * ## O layout de um roteiro grande é montado fora da thread da tela
 *
 * Um roteiro de 100 KB numa fonte grande são milhares de linhas; montar o `StaticLayout` leva
 * dezenas a centenas de ms num aparelho de 1,79 GB. Texto curto monta na hora; o grande monta numa
 * thread própria e entra quando fica pronto — o velho continua rolando até lá.
 *
 * ## O mesmo roteiro diagramado de novo prende a leitura ao caractere
 *
 * Girar a tela, trocar a fonte ou a margem refaz o layout com o mesmo texto. A posição é fração do
 * percurso (§3), e a mesma fração num layout novo cai noutra frase; na troca, a vista acha o
 * caractere que estava na linha de leitura e recalcula a fração que o põe lá ([Ancora]).
 */
class VistaDoRoteiro @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs), Choreographer.FrameCallback {

    /** A posição mudou por conta desta vista (rolando, ou arrastada): é o relato do prompter. */
    var aoAndar: ((Double) -> Unit)? = null

    /** Um toque simples no texto (a tela mostra ou esconde os botões). */
    var aoTocar: (() -> Unit)? = null

    /**
     * A linha de leitura arrastada pelas setas (ou pela faixa): a fração (0..1) a cada movimento, e
     * `soltou` quando o dedo sai. Quem ouve limita os envios; a vista desenha o valor na hora.
     */
    var aoMoverLinha: ((fracao: Double, soltou: Boolean) -> Unit)? = null

    // --- o que o estado manda --------------------------------------------------------------

    private var texto: String = ""
    private var fonteSp: Double = 48.0
    private var margem: Double = 0.1
    private var linhaDeLeitura: Double = 0.3
    private var espelho: Boolean = false

    /** Linhas por segundo (§3). */
    var velocidade: Double = 1.0

    /**
     * "Segurar para rolar" (§12.5): com [rolando], anda **para trás** na mesma velocidade e para no
     * começo — sem mexer em `rolando`, que é do estado.
     */
    var paraTras: Boolean = false

    /** Fração do percurso, 0..1. Quem manda é esta vista; o estado só a acerta num salto. */
    var posicao: Double = 0.0
        private set

    var rolando: Boolean = false
        set(v) {
            if (field == v) return
            field = v
            ultimoQuadroNs = 0L
            val c = Choreographer.getInstance()
            c.removeFrameCallback(this)
            if (v && isAttachedToWindow) c.postFrameCallback(this)
        }

    /** O texto que aparece quando não há roteiro. */
    var semRoteiro: String = context.getString(R.string.tp_sem_roteiro_curto)

    /**
     * Quantos quartos de volta (horários, 0..3) **o texto** gira dentro desta vista — só quando o
     * sistema recusa a orientação pedida (tela grande no Android 16; [GiroDoTexto]). Tudo o que é
     * do texto vive no quadro girado: o diagrama (a largura dele vira a altura da vista com 1 ou 3
     * quartos), a linha de leitura e as setas, o arrasto, a margem, o espelho (horizontal em relação
     * ao texto) e a âncora. Barra, avisos e painel, que não são desta vista, seguem o aparelho.
     */
    var quartosDeGiro: Int = 0
        set(v) {
            val q = ((v % 4) + 4) % 4
            if (field == q) return
            val larguraAntes = larguraDoTexto()
            field = q
            // Com a largura do quadro nova, é o mesmo roteiro diagramado de novo: a âncora vale.
            if (larguraDoTexto() != larguraAntes) remontar() else invalidate()
        }

    /** O quadro do texto: a vista, ou ela deitada quando o texto gira 1 ou 3 quartos. */
    private fun larguraDoTexto(): Int = if (quartosDeGiro % 2 == 0) width else height
    private fun alturaDoTexto(): Int = if (quartosDeGiro % 2 == 0) height else width

    // --- o layout --------------------------------------------------------------------------

    private class Montado(
        val layout: StaticLayout,
        val alturaDaLinha: Double,
        val centroDaPrimeira: Double,
        val percurso: Double,
        val largura: Int,
        val fontePx: Float,
        val texto: String,
        /** Onde a coluna começa (px do quadro do texto): o enquadramento e a margem. */
        val inicioDaColuna: Float = 0f,
    )

    private var montado: Montado? = null

    /** Lida também pela thread do montador: um diagrama que já tem sucessor nem começa. */
    @Volatile private var geracao = 0
    private var ultimoQuadroNs = 0L

    // A linha de leitura do iOS (`VistaDoRoteiro.desenharMarcador`, pedido do Pessoa Exemplo de 28/09): dois
    // triângulos de 12 pt nas bordas, amarelo a 85 %, e um fio de 1 pt entre eles, amarelo a 25 %.
    private val marca = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(217, 255, 214, 10) }
    private val fio = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(64, 255, 214, 10)
        strokeWidth = resources.displayMetrics.density
    }
    private val tintaVazia = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(150, 255, 255, 255) }

    private val gestos = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean = true

        override fun onSingleTapUp(e: MotionEvent): Boolean {
            aoTocar?.invoke()
            return true
        }

        /** Arrastar na vertical move o texto (e é relato, como rolar). */
        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, dx: Float, dy: Float): Boolean {
            val m = montado ?: return false
            if (m.percurso <= 0.0) return false
            val nova = (posicao + dy / m.percurso).coerceIn(0.0, 1.0)
            if (nova != posicao) {
                posicao = nova
                aoAndar?.invoke(nova)
                invalidate()
            }
            return true
        }
    })

    // --- arrastar a linha de leitura ---------------------------------------------------------
    //
    // Pedido do usuário (14/09): "as duas setas laranjas que definem a linha de leitura precisam ser
    // móveis para regular na linha do campo de visão da câmera para os olhos". Só a faixa da linha
    // e as setas pegam o gesto — um toque no resto do texto continua sendo toque (mostrar a barra)
    // ou arrasto do texto. As setas são pequenas e o aparelho fica deitado sob o vidro, alcançado
    // pela lateral: a área de toque delas é bem maior que o desenho. O arrasto é na vertical e em
    // coordenadas desta vista, então vale igual em paisagem, paisagem invertida e com o espelho
    // (que é horizontal).

    private val densidade = resources.displayMetrics.density
    private val folgaDoToque = ViewConfiguration.get(context).scaledTouchSlop
    private var pegouALinha = false
    private var arrastandoLinha = false
    private var yNoToque = 0f
    private var linhaNoToque = 0.0
    private val tintaDoRotulo = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK }
    private val fundoDoRotulo = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(235, 255, 140, 0) }

    private fun alturaDaFaixa(): Float = (montado?.alturaDaLinha ?: 60.0).toFloat()

    /** A faixa inteira; e as setas, com 72 dp da borda para dentro e ±40 dp em volta da linha (no quadro do texto). */
    private fun naAreaDaLinha(x: Float, y: Float): Boolean {
        val dy = abs(y - (alturaDoTexto() * linhaDeLeitura).toFloat())
        val meiaFaixa = alturaDaFaixa() / 2f
        if (dy <= meiaFaixa) return true
        val lateral = AREA_DA_SETA_DP * densidade
        return dy <= maxOf(meiaFaixa, MEIA_ALTURA_DA_SETA_DP * densidade) && (x <= lateral || x >= larguraDoTexto() - lateral)
    }

    /**
     * O toque chega em coordenadas da vista; com o texto girado, ele passa para o quadro do texto
     * antes de tudo — e o arrasto das setas e do texto seguem o dedo na vista girada.
     */
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (quartosDeGiro == 0) return tratarToque(event)
        val p = GiroDoTexto.daVistaParaOTexto(quartosDeGiro, width.toFloat(), height.toFloat(), event.x, event.y)
        val noTexto = MotionEvent.obtain(event)
        noTexto.setLocation(p[0], p[1])
        return try {
            tratarToque(noTexto)
        } finally {
            noTexto.recycle()
        }
    }

    private fun tratarToque(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            // A laranja vence: a faixa e as setas da linha de leitura; fora delas, as bordas do
            // enquadramento (a seta azul e a guia, a borda inteira); e o resto é do texto.
            val naLinha = aoMoverLinha != null && naAreaDaLinha(event.x, event.y)
            setaPega = 0
            talvezSeta = false
            arrastandoSeta = false
            if (!naLinha && aoMoverEnquadramento != null) {
                bordaNoToque(event.x, event.y)?.let { (lado, naSeta) ->
                    setaPega = lado
                    talvezSeta = !naSeta // na guia, só um arrasto horizontal é da borda
                }
            }
            xNoToque = event.x
            enquadramentoNoToque = enquadramento()
            pegouALinha = setaPega == 0 && naLinha
            arrastandoLinha = false
            yNoToque = event.y
            linhaNoToque = linhaDeLeitura
        }
        if (setaPega != 0) return tratarSetaDoEnquadramento(event)
        if (!pegouALinha) return gestos.onTouchEvent(event) || super.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                if (!arrastandoLinha && abs(event.y - yNoToque) > folgaDoToque) {
                    arrastandoLinha = true
                    parent?.requestDisallowInterceptTouchEvent(true)
                }
                if (arrastandoLinha) moverLinha(event.y, soltou = false)
            }
            MotionEvent.ACTION_UP -> {
                // Sem arrastar é toque, como no resto do texto.
                if (arrastandoLinha) moverLinha(event.y, soltou = true) else aoTocar?.invoke()
                pegouALinha = false
                arrastandoLinha = false
                invalidate()
            }
            MotionEvent.ACTION_CANCEL -> {
                if (arrastandoLinha) aoMoverLinha?.invoke(linhaDeLeitura, true)
                pegouALinha = false
                arrastandoLinha = false
                invalidate()
            }
        }
        return true
    }

    // --- "Enquadramento": as duas setas laterais -----------------------------------------------
    //
    // `docs/teleprompter-ajustes-locais.md` §2: duas marcas no alto das bordas da coluna, cada uma
    // arrastável sozinha na horizontal; o texto fica **centralizado** entre elas (§3). Ajuste local:
    // quem guarda é a tela ([aoMoverEnquadramento]); a vista só desenha, arrasta e diagrama. Elas
    // vivem no quadro do texto sem espelho — com o espelho ligado, espelham junto com o texto.

    /** O enquadramento arrastado: o formato (retrato ou paisagem), o novo, e se o dedo soltou. */
    var aoMoverEnquadramento: ((formato: String, enquadramento: Enquadramento, soltou: Boolean) -> Unit)? = null

    /** A coluna do texto mudou de largura (px): quem calcula a fonte automática ouve isto. */
    var aoMudarColuna: ((larguraPx: Int) -> Unit)? = null

    private val enquadramentos = mutableMapOf(
        Enquadramento.RETRATO to Enquadramento.INTEIRO,
        Enquadramento.PAISAGEM to Enquadramento.INTEIRO,
    )
    private var setaPega = 0 // −1 a da esquerda do texto, +1 a da direita (sem espelho)
    private var talvezSeta = false // pegou pela guia: ainda não se sabe se é a borda (horizontal) ou o texto (vertical)
    private var arrastandoSeta = false
    private var xNoToque = 0f
    private var enquadramentoNoToque = Enquadramento.INTEIRO
    private var ultimaColunaAvisada = -1
    private val tintaDoEnquadramento = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(240, 64, 170, 255) }
    private val guiaDoEnquadramento = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(150, 64, 170, 255)
        strokeWidth = 1.5f * resources.displayMetrics.density
    }

    // A área da vista que nada cobre — nem o aviso laranja no alto, nem a barra de botões embaixo —,
    // dita pela tela ([definirAreaLivre]). As setas azuis e as guias moram só nela.
    private var livreTopoNaVista = 0f
    private var livreBaixoNaVista = Float.MAX_VALUE

    /** As guias verticais das bordas aparecem com a barra de botões à mostra (e durante o arrasto). */
    private var guiasVisiveis = false

    /**
     * **A borda desta vista que fica do lado da lente** — só na tela R5 ([com.quall.android.ui.PrompterComCameraActivity]);
     * `null` no prompter comum. As marcas das bordas vão para a ponta do texto longe dela
     * ([Enquadramento.marcasNoPe]): no alto, ficavam junto da frontal (visto no A07, 24/09).
     */
    var ladoDaLente: com.quall.android.teleprompter.Divisao.Lado? = null
        set(v) {
            if (field == v) return
            field = v
            invalidate()
        }

    /** As marcas no pé do quadro do texto (e não no alto): ver [ladoDaLente]. */
    private fun marcasNoPe(): Boolean {
        val l = ladoDaLente ?: return false
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return false
        val (x, y) = when (l) {
            com.quall.android.teleprompter.Divisao.Lado.TOPO -> w / 2 to 0f
            com.quall.android.teleprompter.Divisao.Lado.BAIXO -> w / 2 to h
            com.quall.android.teleprompter.Divisao.Lado.ESQUERDA -> 0f to h / 2
            com.quall.android.teleprompter.Divisao.Lado.DIREITA -> w to h / 2
        }
        val p = GiroDoTexto.daVistaParaOTexto(quartosDeGiro, w, h, x, y)
        return Enquadramento.marcasNoPe(p[1], alturaDoTexto().toFloat())
    }

    /** O que cobre a vista agora: o aviso até `topo`, a barra a partir de `baixo` (px da vista). */
    fun definirAreaLivre(topo: Float, baixo: Float, guias: Boolean) {
        if (topo == livreTopoNaVista && baixo == livreBaixoNaVista && guias == guiasVisiveis) return
        livreTopoNaVista = topo
        livreBaixoNaVista = baixo
        guiasVisiveis = guias
        invalidate()
    }

    /** A área livre no quadro do texto (que pode estar girado: o aviso e a barra são do aparelho). */
    private fun areaLivreNoTexto(): RectF {
        val w = width.toFloat()
        val h = height.toFloat()
        val t = livreTopoNaVista.coerceIn(0f, h)
        val b = livreBaixoNaVista.coerceIn(t, h)
        val a = GiroDoTexto.daVistaParaOTexto(quartosDeGiro, w, h, 0f, t)
        val c = GiroDoTexto.daVistaParaOTexto(quartosDeGiro, w, h, w, b)
        return RectF(minOf(a[0], c[0]), minOf(a[1], c[1]), maxOf(a[0], c[0]), maxOf(a[1], c[1]))
    }

    /**
     * Uma borda do enquadramento como se desenha: a guia e a seta, as duas presas dentro da área
     * livre. [base] é o lado largo da seta, colado à ponta do texto; a ponta aponta para dentro —
     * para baixo com as marcas no alto, para cima com elas no pé.
     */
    private class Borda(val xGuia: Float, val centroDaSeta: Float, val meia: Float, val base: Float, val noPe: Boolean) {
        val esquerdaDaSeta get() = centroDaSeta - meia
        val direitaDaSeta get() = centroDaSeta + meia
        // 16 × 13 pt, a marca do iOS (`EnquadramentoDoTexto.marca`): meia largura 8, profundidade 13.
        val pontaDaSeta get() = if (noPe) base - meia * 1.625f else base + meia * 1.625f

        /** O toque na altura da seta, com [folga]: da ponta até a borda do texto. */
        fun naAltura(y: Float, folga: Float): Boolean =
            if (noPe) y >= pontaDaSeta - folga else y <= pontaDaSeta + folga
    }

    /** O tamanho das setas laranja da linha de leitura: as azuis são as mesmas, deitadas. */
    /** A meia largura da seta azul: 8 dp (a marca do iOS tem 16 × 13). */
    private fun meiaSeta() = 8f * densidade

    private fun borda(lado: Int, livre: RectF): Borda {
        val lw = larguraDoTexto().toFloat()
        val e = enquadramento()
        val fracao = (if (lado < 0) e.esquerda else e.direita).toFloat()
        // A marca na tela: com o espelho, espelhada (a da esquerda na tela é a da direita no vidro).
        val x = if (espelho) lw - fracao * lw else fracao * lw
        val s = meiaSeta()
        val largura = livre.right - livre.left
        val centro = if (largura > 2 * s) x.coerceIn(livre.left + s, livre.right - s) else (livre.left + livre.right) / 2
        val noPe = marcasNoPe()
        val base = if (noPe) livre.bottom - 6f * densidade else livre.top + 6f * densidade
        return Borda(x.coerceIn(livre.left + 1f, livre.right - 1f), centro, s, base, noPe)
    }

    /** Os dois guardados (retrato e paisagem); vale o do formato do quadro do texto. */
    fun definirEnquadramentos(retrato: Enquadramento, paisagem: Enquadramento) {
        enquadramentos[Enquadramento.RETRATO] = retrato
        enquadramentos[Enquadramento.PAISAGEM] = paisagem
        remontar()
    }

    fun formatoDoQuadro(): String = Enquadramento.formato(larguraDoTexto(), alturaDoTexto())
    fun enquadramento(): Enquadramento = enquadramentos[formatoDoQuadro()] ?: Enquadramento.INTEIRO

    /** A largura da coluna do último diagrama pedido (px) — a da fonte automática. */
    var larguraDaColuna: Int = 0
        private set

    /**
     * Qual borda o toque pegou, e se foi na seta: a seta (com 16 dp de folga em volta) ou a guia —
     * a borda inteira, 24 dp de cada lado, de alto a baixo da área livre. A mais perto vence.
     */
    private fun bordaNoToque(x: Float, y: Float): Pair<Int, Boolean>? {
        val livre = areaLivreNoTexto()
        if (y < livre.top || y > livre.bottom) return null
        val folga = FOLGA_DA_SETA_AZUL_DP * densidade
        val faixa = FAIXA_DA_GUIA_DP * densidade
        var melhor: Pair<Int, Boolean>? = null
        var distancia = Float.MAX_VALUE
        for (lado in intArrayOf(-1, 1)) {
            val b = borda(lado, livre)
            val naSeta = x >= b.esquerdaDaSeta - folga && x <= b.direitaDaSeta + folga && b.naAltura(y, folga)
            val naGuia = abs(x - b.xGuia) <= faixa
            if (!naSeta && !naGuia) continue
            val d = minOf(abs(x - b.xGuia), abs(x - b.centroDaSeta))
            if (d < distancia) {
                distancia = d
                melhor = lado to naSeta
            }
        }
        return melhor
    }

    private fun tratarSetaDoEnquadramento(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            // Pego pela guia: o detector do texto também vê o toque, para ficar com ele se o
            // arrasto for vertical (a guia larga não pode roubar o arrasto do texto).
            MotionEvent.ACTION_DOWN -> if (talvezSeta) gestos.onTouchEvent(event)
            MotionEvent.ACTION_MOVE -> {
                if (!arrastandoSeta) {
                    val dx = abs(event.x - xNoToque)
                    val dy = abs(event.y - yNoToque)
                    if (maxOf(dx, dy) > folgaDoToque) {
                        if (dx > dy) {
                            arrastandoSeta = true
                            if (talvezSeta) cancelarGestos(event)
                            talvezSeta = false
                            parent?.requestDisallowInterceptTouchEvent(true)
                        } else if (talvezSeta) {
                            setaPega = 0
                            talvezSeta = false
                            return gestos.onTouchEvent(event)
                        }
                    }
                }
                if (arrastandoSeta) moverSeta(event.x, soltou = false)
            }
            MotionEvent.ACTION_UP -> {
                when {
                    arrastandoSeta -> moverSeta(event.x, soltou = true)
                    talvezSeta -> gestos.onTouchEvent(event) // um toque na guia: o de sempre (a barra)
                    else -> aoTocar?.invoke()
                }
                setaPega = 0
                talvezSeta = false
                arrastandoSeta = false
                invalidate()
            }
            MotionEvent.ACTION_CANCEL -> {
                if (arrastandoSeta) aoMoverEnquadramento?.invoke(formatoDoQuadro(), enquadramento(), true)
                if (talvezSeta) gestos.onTouchEvent(event)
                setaPega = 0
                talvezSeta = false
                arrastandoSeta = false
                invalidate()
            }
        }
        return true
    }

    private fun cancelarGestos(event: MotionEvent) {
        val c = MotionEvent.obtain(event)
        c.action = MotionEvent.ACTION_CANCEL
        gestos.onTouchEvent(c)
        c.recycle()
    }

    /** A borda anda o que o dedo andou (com o espelho, ao contrário no quadro do texto). */
    private fun moverSeta(x: Float, soltou: Boolean) {
        val lw = larguraDoTexto()
        if (lw <= 0) return
        val andou = (x - xNoToque).toDouble() / lw
        val delta = if (espelho) -andou else andou
        val novo = if (setaPega < 0) enquadramentoNoToque.comEsquerda(enquadramentoNoToque.esquerda + delta)
        else enquadramentoNoToque.comDireita(enquadramentoNoToque.direita + delta)
        val formato = formatoDoQuadro()
        if (novo != enquadramentos[formato]) {
            enquadramentos[formato] = novo
            remontar() // a coluna nova; a âncora segura a leitura
        }
        invalidate()
        aoMoverEnquadramento?.invoke(formato, novo, soltou)
    }

    /**
     * A linha anda o que o dedo andou (o ponto pego fica sob o dedo, sem saltar para ele), presa em
     * 0..1 e na resolução do núcleo (décimo de milésimo).
     */
    private fun moverLinha(y: Float, soltou: Boolean) {
        val altura = alturaDoTexto()
        if (altura <= 0) return
        val nova = ((linhaNoToque * altura + (y - yNoToque)) / altura).coerceIn(0.0, 1.0)
        linhaDeLeitura = Math.round(nova * 10_000) / 10_000.0
        invalidate()
        aoMoverLinha?.invoke(linhaDeLeitura, soltou)
    }

    /** Aplica o que o estado manda; remonta o layout só se o texto, a fonte ou a margem mudaram. */
    fun aplicar(texto: String, fonteSp: Double, margem: Double, linhaDeLeitura: Double, espelho: Boolean) {
        val remontar = texto != this.texto || fonteSp != this.fonteSp || margem != this.margem
        this.texto = texto
        this.fonteSp = fonteSp
        this.margem = margem
        // Durante o arrasto quem manda na linha é o dedo: o estado chega atrasado (os envios são
        // limitados) e a faria voltar a cada edição que chega do outro lado.
        if (!arrastandoLinha) this.linhaDeLeitura = linhaDeLeitura
        this.espelho = espelho
        if (remontar) remontar() else invalidate()
    }

    /** Vai para uma posição (salto, ou "início"). Não relata: quem saltou já sabe. */
    fun irPara(fracao: Double) {
        posicao = fracao.coerceIn(0.0, 1.0)
        ultimoQuadroNs = 0L
        invalidate()
    }

    /** A fonte do sistema mudou (tamanho da letra nos ajustes): o sp muda de pixels. */
    fun configuracaoMudou() = remontar()

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // A largura que conta é a do quadro do texto (a altura da vista, com o texto girado 1 ou 3 quartos).
        val antes = if (quartosDeGiro % 2 == 0) oldw else oldh
        if (larguraDoTexto() != antes) remontar() else invalidate()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (rolando) {
            ultimoQuadroNs = 0L
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    override fun onDetachedFromWindow() {
        Choreographer.getInstance().removeFrameCallback(this)
        super.onDetachedFromWindow()
    }

    private fun remontar() {
        val w = larguraDoTexto()
        if (w <= 0) return
        // A coluna: entre as setas do enquadramento, e dentro dela a margem sincronizada.
        val (inicio, larg) = enquadramento().coluna(w, margem)
        val largura = larg.toInt().coerceAtLeast(1)
        val x0 = inicio.toFloat()
        larguraDaColuna = largura
        if (largura != ultimaColunaAvisada) {
            ultimaColunaAvisada = largura
            aoMudarColuna?.invoke(largura)
        }
        val px = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, fonteSp.toFloat(), resources.displayMetrics)
        val t = texto
        val g = ++geracao
        if (t.length <= MONTAR_NA_HORA_ATE) {
            trocar(montar(t, px, largura, x0))
        } else {
            MONTADOR.execute {
                // Arrastando uma seta, os pedidos se empilham: só o mais novo é diagramado.
                if (g != geracao) return@execute
                val m = montar(t, px, largura, x0)
                post {
                    if (g == geracao) trocar(m)
                }
            }
        }
    }

    /** O layout novo entra; o velho rolou até agora (no caso do grande, montado fora da thread). */
    private fun trocar(novo: Montado) {
        val velho = montado
        montado = novo
        if (velho != null && velho.texto == novo.texto && novo.texto.isNotEmpty()) diagramouDeNovo(velho, novo)
        invalidate()
    }

    /**
     * O **mesmo** roteiro diagramado de novo: girou, a fonte ou a margem mudou. **A leitura fica
     * presa ao caractere** que estava na linha de leitura ([Ancora]): a fração é recalculada no
     * layout novo e relatada, como se o texto tivesse sido arrastado até lá. Guardar só a fração
     * punha outra frase na linha de leitura — medido no A07 com roteiros de 100 KB, na rotação, na
     * fonte e na margem: de 8 a 346 linhas (`apps/android/README.md`, rodada 11).
     *
     * O registro diz as duas coisas — onde a fração sozinha poria a leitura, e onde ela ficou —, em
     * posições de caractere, nunca o texto (o registro do teleprompter só leva resumos de roteiro).
     */
    private fun diagramouDeNovo(velho: Montado, novo: Montado) {
        val antes = DiagramacaoDoLayout(velho.layout)
        val depois = DiagramacaoDoLayout(novo.layout)
        val p = posicao
        val marca = Ancora.marcar(antes, p)
        val nova = Ancora.reposicionar(depois, marca)
        val andadas = Ancora.linhasAndadasSemAncora(antes, depois, p)
        val amostras = listOf(0.25, 0.5, 0.75).joinToString("/") { "%+d".format(Ancora.linhasAndadasSemAncora(antes, depois, it)) }
        fun linha(m: Montado, l: Int) = "linha $l [${m.layout.getLineStart(l)},${m.layout.getLineEnd(l)})"
        Log.i(TAG, String.format(
            Locale.ROOT,
            "roteiro: diagramado de novo — texto de %d→%d px, %d→%d linhas, fonte %.1f→%.1f px | " +
                "antes na leitura (posição %.4f): %s | só a fração poria a %s (%+d linhas; em 25/50/75 %%: %s) | " +
                "ancorada no caractere %d: posição %.4f, %s",
            velho.largura, novo.largura, velho.layout.lineCount, novo.layout.lineCount, velho.fontePx, novo.fontePx,
            p, linha(velho, Ancora.linhaNaLeitura(antes, p)), linha(novo, Ancora.linhaNaLeitura(depois, p)), andadas, amostras,
            marca.caractere, nova, linha(novo, Ancora.linhaNaLeitura(depois, nova)),
        ))
        if (nova != posicao) {
            posicao = nova
            aoAndar?.invoke(nova)
        }
    }

    /** O `StaticLayout` visto pela [Ancora]: pixels do texto, o topo dele = 0. */
    private class DiagramacaoDoLayout(private val l: StaticLayout) : Diagramacao {
        override val linhas get() = l.lineCount
        override fun centro(linha: Int) = (l.getLineTop(linha) + l.getLineBottom(linha)) / 2.0
        override fun altura(linha: Int) = (l.getLineBottom(linha) - l.getLineTop(linha)).toDouble()
        override fun linhaNaAltura(y: Double) = l.getLineForVertical(y.toInt())
        override fun inicio(linha: Int) = l.getLineStart(linha)
        override fun linhaDoCaractere(caractere: Int) = l.getLineForOffset(caractere)
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!rolando || !isAttachedToWindow) {
            ultimoQuadroNs = 0L
            return
        }
        val m = montado
        if (ultimoQuadroNs != 0L && m != null) {
            val dt = Percurso.dtLimitado((frameTimeNanos - ultimoQuadroNs) / 1e9)
            val nova = if (paraTras) Percurso.recuar(posicao, velocidade, m.alturaDaLinha, m.percurso, dt)
            else Percurso.avancar(posicao, velocidade, m.alturaDaLinha, m.percurso, dt)
            if (nova != posicao) {
                posicao = nova
                aoAndar?.invoke(nova)
                invalidate()
            }
        }
        ultimoQuadroNs = frameTimeNanos
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Color.BLACK)
        // Com o texto girado, tudo o que segue é desenhado no quadro dele (ver [GiroDoTexto]).
        canvas.save()
        when (quartosDeGiro) {
            1 -> { canvas.translate(width.toFloat(), 0f); canvas.rotate(90f) }
            2 -> { canvas.translate(width.toFloat(), height.toFloat()); canvas.rotate(180f) }
            3 -> { canvas.translate(0f, height.toFloat()); canvas.rotate(270f) }
        }
        desenharNoQuadroDoTexto(canvas)
        canvas.restore()
    }

    private fun desenharNoQuadroDoTexto(canvas: Canvas) {
        val w = larguraDoTexto().toFloat()
        val h = alturaDoTexto().toFloat()
        val yLeitura = (h * linhaDeLeitura).toFloat()
        val m = montado

        canvas.save()
        if (espelho) canvas.scale(-1f, 1f, w / 2f, 0f)
        if (m != null && texto.isNotEmpty()) {
            val topo = Percurso.topoDoTexto(yLeitura.toDouble(), m.centroDaPrimeira, m.percurso, posicao)
            canvas.translate(m.inicioDaColuna, topo.toFloat())
            m.layout.draw(canvas)
        } else {
            tintaVazia.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 22f, resources.displayMetrics)
            val larg = tintaVazia.measureText(semRoteiro)
            canvas.drawText(semRoteiro, (w - larg) / 2f, yLeitura, tintaVazia)
        }
        canvas.restore()

        // A linha de leitura, como a do iOS: dois triângulos de 12 dp nas bordas e um fio entre eles,
        // simétricos — valem igual com o espelho ligado ou não. A área de toque continua a da faixa
        // e das setas ([naAreaDaLinha]); só o desenho ficou fino.
        val lado = 12f * densidade
        canvas.drawLine(lado, yLeitura, w - lado, yLeitura, fio)
        val esquerda = Path().apply { moveTo(0f, yLeitura - lado / 2f); lineTo(lado, yLeitura); lineTo(0f, yLeitura + lado / 2f); close() }
        val direita = Path().apply { moveTo(w, yLeitura - lado / 2f); lineTo(w - lado, yLeitura); lineTo(w, yLeitura + lado / 2f); close() }
        canvas.drawPath(esquerda, marca)
        canvas.drawPath(direita, marca)

        // As bordas do enquadramento (pedido do usuário no A10s, 14/09: "não encontrei as setas de
        // centralização, apenas da linha" — elas estavam cortadas no canto e pequenas). A seta azul,
        // do tamanho das laranja, apontando para dentro no alto de cada borda — no pé, longe da
        // lente, na tela R5 ([ladoDaLente]) —, **inteira à vista**: o
        // desenho recua para dentro da área livre, a posição não. A guia fina, de alto a baixo, com a
        // barra à mostra e durante o arrasto. As duas só na área livre — nem sob o aviso nem sob a barra.
        if (aoMoverEnquadramento != null) {
            val livre = areaLivreNoTexto()
            val bordas = listOf(borda(-1, livre), borda(1, livre))
            if (guiasVisiveis || arrastandoSeta) {
                for (b in bordas) canvas.drawLine(b.xGuia, livre.top, b.xGuia, livre.bottom, guiaDoEnquadramento)
            }
            for (b in bordas) {
                canvas.drawPath(Path().apply {
                    moveTo(b.esquerdaDaSeta, b.base); lineTo(b.direitaDaSeta, b.base); lineTo(b.centroDaSeta, b.pontaDaSeta); close()
                }, tintaDoEnquadramento)
            }
        }

        // Arrastando, o valor em % — fora do espelho (é da tela, não do roteiro), acima da faixa
        // ou abaixo dela quando não cabe em cima.
        if (arrastandoLinha) {
            tintaDoRotulo.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 18f, resources.displayMetrics)
            val rotulo = context.getString(R.string.tp_linha_de_leitura_valor, linhaDeLeitura * 100)
            val larg = tintaDoRotulo.measureText(rotulo)
            val alt = tintaDoRotulo.fontSpacing
            val pad = 8f * densidade
            val altura = alturaDaFaixa()
            val emCima = yLeitura - altura / 2f - pad
            val base = if (emCima - alt - pad > 0f) emCima - pad else yLeitura + altura / 2f + pad + alt
            val x0 = (w - larg) / 2f
            canvas.drawRoundRect(x0 - pad, base - alt, x0 + larg + pad, base + pad / 2f, pad, pad, fundoDoRotulo)
            canvas.drawText(rotulo, x0, base - pad / 4f, tintaDoRotulo)
        }
    }

    companion object {
        private const val TAG = "QuallTeleprompter"

        /** A área de toque de cada seta, da borda para dentro (o desenho tem ~28 dp). */
        private const val AREA_DA_SETA_DP = 72f

        /** Metade da altura da área de toque das setas, em volta da linha (o desenho tem ~21 dp). */
        private const val MEIA_ALTURA_DA_SETA_DP = 40f

        /** Até aqui o layout monta na thread da tela (uma página ou duas). */
        private const val MONTAR_NA_HORA_ATE = 4_000

        /** A folga do toque em volta de cada seta azul (o desenho é o das laranja, deitado). */
        private const val FOLGA_DA_SETA_AZUL_DP = 16f

        /** De cada lado da guia de uma borda, até onde o toque a pega — de alto a baixo. */
        private const val FAIXA_DA_GUIA_DP = 24f

        /** Uma thread só, para os layouts saírem em ordem; a geração descarta os velhos. */
        private val MONTADOR = Executors.newSingleThreadExecutor { r -> Thread(r, "quall-roteiro-layout").apply { isDaemon = true } }

        /**
         * **O motor de quebra de linha do prompter** — o desta vista e o da fonte automática, que
         * precisa quebrar exatamente igual. Linhas **centralizadas** na coluna (§3 dos ajustes locais:
         * "Alinhamento — centralizado", fixo); quebra simples e sem hifenização: é o que monta rápido
         * com milhares de linhas, e hífen no meio da palavra atrapalha quem lê em voz alta.
         */
        internal fun diagramar(texto: CharSequence, px: Float, largura: Int): StaticLayout {
            val tinta = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                textSize = px
            }
            return StaticLayout.Builder.obtain(texto, 0, texto.length, tinta, largura.coerceAtLeast(1))
                .setAlignment(Layout.Alignment.ALIGN_CENTER)
                .setIncludePad(false)
                .setBreakStrategy(LineBreaker.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                .build()
        }

        private fun montar(texto: String, px: Float, largura: Int, inicioDaColuna: Float): Montado {
            val layout = diagramar(texto, px, largura)
            val tinta = layout.paint
            val n = layout.lineCount
            val centro = { i: Int -> (layout.getLineTop(i) + layout.getLineBottom(i)) / 2.0 }
            val primeira = if (n > 0) centro(0) else 0.0
            val ultima = if (n > 0) centro(n - 1) else 0.0
            return Montado(
                layout = layout,
                alturaDaLinha = tinta.fontSpacing.toDouble(),
                centroDaPrimeira = primeira,
                percurso = (ultima - primeira).coerceAtLeast(0.0),
                largura = largura,
                fontePx = px,
                texto = texto,
                inicioDaColuna = inicioDaColuna,
            )
        }
    }
}
