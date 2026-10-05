package com.quall.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View

/**
 * Conteúdo em movimento contínuo, mostrado em tela cheia durante os testes de captura.
 *
 * A `VirtualDisplay` que alimenta o `MediaCodec` só produz um novo buffer quando o compositor
 * tem algo novo para desenhar — uma tela parada (como os textos e botões normais do app) gera
 * pouquíssimos quadros por segundo, o que é comportamento correto de captura de tela, mas rende
 * poucas amostras para medir latência/CPU sob carga sustentada. Esta view existe só para dar ao
 * encoder conteúdo mudando a `target_fps` pedida, sem depender de simular a tela do sistema.
 */
class AnimatedContentView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val paintBg = Paint().apply { color = Color.rgb(20, 22, 46) }
    private val paintBall = Paint().apply { color = Color.rgb(123, 213, 245); isAntiAlias = true }
    private val paintText = Paint().apply {
        color = Color.WHITE
        textSize = 56f
        isAntiAlias = true
    }

    private val startNanos = System.nanoTime()

    /**
     * Mosaico **denso e estático** por baixo da bola, em vez do fundo liso. Ver
     * `Bancada.origemDensa`.
     *
     * O fundo liso comprime quase a zero: o IDR da origem animada padrão tem meia dúzia de
     * pacotes, e a pergunta de `docs/idr-pequeno.md` é sobre IDR de ~60 — o regime da tela real,
     * onde o quadro de recuperação atravessa o joelho de `docs/idr-que-sobrevive.md` e é
     * truncado. Sem uma origem desse porte não há "antes" para comparar com o "depois".
     *
     * Detalhe espacial alto, movimento baixo: é o regime de uma tela de celular parada — IDR
     * grande, quadro P pequeno. E é **sintético e reproduzível** (semente fixa), que é o que
     * `docs/regras-de-frente.md` exige de qualquer origem que vire número aqui.
     */
    var denso: Boolean = false

    private var mosaico: android.graphics.Bitmap? = null
    private val paintMosaico = Paint()

    /**
     * Desenha o mosaico num bitmap do tamanho da view, uma vez. Gerador congruencial de semente
     * fixa (os multiplicadores são os de `java.util.Random`), para que dois braços da mesma
     * medição vejam **exatamente** os mesmos pixels — o "mesma origem" que o antes/depois exige.
     */
    private fun mosaicoDe(w: Int, h: Int): android.graphics.Bitmap {
        val existente = mosaico
        if (existente != null && existente.width == w && existente.height == h) return existente
        existente?.recycle()
        val bmp = android.graphics.Bitmap.createBitmap(w, h, android.graphics.Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val p = Paint()
        var semente = 0x5DEECE66DL
        fun proximo(n: Int): Int {
            semente = (semente * 0x5DEECE66DL + 0xB) and ((1L shl 48) - 1)
            return ((semente ushr 16) % n).toInt()
        }
        // Blocos de 8 px: fino o bastante para não comprimir, grosso o bastante para o desenho
        // caber num piscar em qualquer aparelho da bancada.
        val lado = 8
        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                p.color = Color.rgb(proximo(256), proximo(256), proximo(256))
                c.drawRect(x.toFloat(), y.toFloat(), (x + lado).toFloat(), (y + lado).toFloat(), p)
                x += lado
            }
            y += lado
        }
        mosaico = bmp
        return bmp
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (denso && width > 0 && height > 0) {
            canvas.drawBitmap(mosaicoDe(width, height), 0f, 0f, paintMosaico)
        } else {
            canvas.drawRect(0f, 0f, w, h, paintBg)
        }

        val elapsedMs = (System.nanoTime() - startNanos) / 1_000_000.0
        val t = (elapsedMs % 3000.0) / 3000.0
        val radius = 60f
        val cx = radius + (t * (w - 2 * radius)).toFloat()
        val cy = h / 2f + (Math.sin(elapsedMs / 250.0) * (h / 4)).toFloat()
        canvas.drawCircle(cx, cy, radius, paintBall)

        canvas.drawText("QUALL — captura em teste", 40f, 120f, paintText) // i18n-fora: conteúdo de bancada (Bancada.conteudoAnimado)
        canvas.drawText("t=${"%.0f".format(elapsedMs)} ms", 40f, 190f, paintText)

        // Redesenha no próximo vsync: é o que garante conteúdo mudando continuamente, e portanto
        // quadros contínuos saindo da VirtualDisplay para o encoder.
        postInvalidateOnAnimation()
    }
}
