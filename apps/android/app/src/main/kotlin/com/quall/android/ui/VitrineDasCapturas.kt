package com.quall.android.ui

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.SurfaceHolder
import com.quall.android.capture.dv.PainelDoVideoUsb
import com.quall.android.dvd.DiscoDvd

/**
 * **O aparelho de vídeo USB de mentira** da tela da placa (`VideoUsbActivity`), escrito só pela vitrine
 * de bancada do APK de depuração ([EstadoDasTelas.placaDaVitrine]; `docs/telas-estudio.md` §9 e a emenda
 * de 30/09 da §11). O resto do estado (a gravação, a transmissão, o som) a vitrine põe nos barramentos de
 * sempre (`GravacaoBus`, `MirrorBus`, `MicrofoneBus`).
 *
 * - [rotulo]: o nome do aparelho, como o `UsbDv.rotulo` o diria; vazio sem aparelho.
 * - [pronto]: as permissões dadas e o aparelho plugado (a imagem aparece).
 * - [mensagem], [tipoDaMensagem], [acao]: o aviso do aparelho quando não está pronto (sem aparelho, sem
 *   permissão), e o rótulo do botão dele.
 * - [falha]: a imagem que parou ("A imagem parou: …", o motivo como o dono da placa o diria).
 * - [opcoes]: a placa aberta, com o formato, o tamanho e os quadros (as linhas da engrenagem).
 * - [abrirAjustes]: a folha da engrenagem já aberta (o retrato das opções).
 */
data class VitrineDaPlaca(
    val rotulo: String,
    val tipo: PainelDoVideoUsb.Tipo,
    val pronto: Boolean,
    val mensagem: String? = null,
    val tipoDaMensagem: AvisoDaTela.Tipo = AvisoDaTela.Tipo.AMBAR,
    val acao: String? = null,
    val falha: String? = null,
    val opcoes: Opcoes? = null,
    val abrirAjustes: Boolean = false,
) {
    /** O que a fonte aberta diria: o formato, o tamanho, os quadros pedidos e os da placa, e os que chegam. */
    data class Opcoes(
        val formato: String,
        val largura: Int,
        val altura: Int,
        val quadros: Int,
        val quadrosDaPlaca: Int,
        val chegando: Double,
    )
}

/**
 * **O leitor de DVD de mentira** da tela do DVD (`ConversaoDvdActivity`), escrito só pela vitrine
 * ([EstadoDasTelas.dvdDaVitrine]). A conversão e a transmissão a vitrine põe nos barramentos de sempre
 * (`ConversaoDvdBus`, `TransmissaoDvdBus`, `MirrorBus`).
 *
 * - [leitor], [tipoDoLeitor], [acao]: a frase do leitor como a tela a diria, o tipo do aviso (`null`: a
 *   linha curta ao lado da pílula, sem aviso) e o rótulo do botão dele;
 * - [disco]: o disco lido (os títulos para escolher), ou `null`;
 * - [mensagem], [mensagemPublicada]: a frase do fim (a conversão que terminou, a recusa).
 */
data class VitrineDoDvd(
    val leitor: String,
    val tipoDoLeitor: AvisoDaTela.Tipo?,
    val acao: String? = null,
    val disco: DiscoDvd? = null,
    val mensagem: String? = null,
    val mensagemPublicada: Boolean = false,
)

/**
 * **Um quadro de exemplo** na superfície da prévia, só na vitrine: as barras de cor (75 %, a ordem do
 * SMPTE) encaixadas na proporção da fonte, com as faixas pretas que o `RenderizadorDv` deixaria. Desenhado
 * pela CPU (`lockCanvas`), uma vez por tamanho: não há câmera nem placa.
 */
class QuadroDeExemplo(private val largura: Int, private val altura: Int) : SurfaceHolder.Callback {
    private val tinta = Paint()
    private val barras = intArrayOf(
        Color.rgb(191, 191, 191), Color.rgb(191, 191, 0), Color.rgb(0, 191, 191), Color.rgb(0, 191, 0),
        Color.rgb(191, 0, 191), Color.rgb(191, 0, 0), Color.rgb(0, 0, 191),
    )

    override fun surfaceCreated(holder: SurfaceHolder) = desenhar(holder)
    override fun surfaceChanged(holder: SurfaceHolder, formato: Int, w: Int, h: Int) = desenhar(holder)
    override fun surfaceDestroyed(holder: SurfaceHolder) = Unit

    private fun desenhar(holder: SurfaceHolder) {
        val c: Canvas = runCatching { holder.lockCanvas() }.getOrNull() ?: return
        try {
            c.drawColor(Color.BLACK)
            val w = c.width.toFloat()
            val h = c.height.toFloat()
            // A imagem encaixada (o aspecto da fonte), centrada.
            val aspecto = largura.toFloat() / altura
            val (iw, ih) = if (w / h > aspecto) (h * aspecto) to h else w to (w / aspecto)
            val x0 = (w - iw) / 2
            val y0 = (h - ih) / 2
            val alto = ih * 0.75f
            val passo = iw / barras.size
            for ((i, cor) in barras.withIndex()) {
                tinta.color = cor
                c.drawRect(x0 + i * passo, y0, x0 + (i + 1) * passo, y0 + alto, tinta)
            }
            // A faixa de baixo: o degradê de cinza, do preto ao branco.
            val n = 16
            val p = iw / n
            for (i in 0 until n) {
                val v = 16 + i * (235 - 16) / (n - 1)
                tinta.color = Color.rgb(v, v, v)
                c.drawRect(x0 + i * p, y0 + alto, x0 + (i + 1) * p, y0 + ih, tinta)
            }
        } finally {
            runCatching { holder.unlockCanvasAndPost(c) }
        }
    }
}
