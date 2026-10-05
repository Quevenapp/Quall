package com.quall.android.ui

import android.content.Context
import com.quall.android.core.LogSeguro as Log
import android.view.LayoutInflater
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.core.QuallNative
import com.quall.android.databinding.ItemRoteiroGuardadoBinding
import com.quall.android.databinding.RoteirosGuardadosBinding
import com.quall.android.teleprompter.CaixaDaPergunta
import com.quall.android.teleprompter.EstadoDoTeleprompter
import com.quall.android.teleprompter.EstadoDoTeleprompter.CopiaDoTexto
import com.quall.android.teleprompter.ReplicaDoTeleprompter
import com.quall.android.teleprompter.RoteirosGuardados
import com.quall.android.teleprompter.Resumo

/**
 * **"Roteiros guardados"** na tela do controle (§11.5 e §11.7): as cópias do salvo deste aparelho, a
 * mais nova primeiro — de onde veio, a hora, o tamanho e a prévia —, com "Ver", "Usar este" (com
 * confirmação, `set_text`) e "Apagar" (com confirmação, `forget_text_copy`). Abre mesmo sem conexão.
 */
internal class TelaDosRoteiros(
    private val contexto: Context,
    private val v: RoteirosGuardadosBinding,
    private val replica: ReplicaDoTeleprompter,
    /** Grava o salvo (fora da thread da tela): depois de usar e de apagar. */
    private val salvar: () -> Unit,
) {
    companion object {
        private const val TAG = "QuallTeleprompter"
    }

    private var mostradas: List<CopiaDoTexto>? = null
    private val palavrasPorResumo = HashMap<String, Int>()

    /** Os textos da lista, no idioma da tela. */
    private val t = Idioma.textos(contexto)

    val aberta: Boolean get() = v.root.visibility == View.VISIBLE

    init {
        v.buttonFecharRoteiros.setOnClickListener { fechar() }
    }

    fun abrir() {
        mostradas = null
        v.root.visibility = View.VISIBLE
        replica.estado()?.let { desenhar(it) }
        Log.i(TAG, "controle: roteiros guardados — aberto, ${replica.estado()?.copiasDoTexto?.size ?: 0} cópia(s)")
    }

    fun fechar() {
        v.root.visibility = View.GONE
    }

    /** A cada desenho da tela: refaz a lista só quando ela mudou. */
    fun desenhar(e: EstadoDoTeleprompter) {
        if (!aberta) return
        val copias = e.copiasDoTexto
        if (copias == mostradas) return
        mostradas = copias
        v.textRoteirosVazio.visibility = if (copias.isEmpty()) View.VISIBLE else View.GONE
        v.listaDeRoteiros.removeAllViews()
        val agora = System.currentTimeMillis()
        val inflador = LayoutInflater.from(contexto)
        for (c in copias) {
            val item = ItemRoteiroGuardadoBinding.inflate(inflador, v.listaDeRoteiros, false)
            item.textRoteiroOrigem.text = RoteirosGuardados.origem(c, t)
            item.textRoteiroQuando.text = RoteirosGuardados.quando(c.quandoMs, agora, t) + " · " + CaixaDaPergunta.palavras(palavras(c), t)
            item.textRoteiroPrevia.text = c.previa.trimEnd() + if (c.previa.toByteArray(Charsets.UTF_8).size < c.bytes) "…" else ""
            item.buttonVerRoteiro.setOnClickListener { ver(c) }
            item.buttonUsarRoteiro.setOnClickListener { usar(c) }
            item.buttonApagarRoteiro.setOnClickListener { apagar(c) }
            v.listaDeRoteiros.addView(item.root)
        }
    }

    private fun palavras(c: CopiaDoTexto): Int =
        palavrasPorResumo[c.resumo] ?: (replica.copiaDoTexto(c.resumo)?.let(CaixaDaPergunta::contar) ?: 0).also {
            palavrasPorResumo[c.resumo] = it
        }

    private fun ver(c: CopiaDoTexto) {
        val texto = replica.copiaDoTexto(c.resumo)
        if (texto == null) {
            sumiu()
            return
        }
        Log.i(TAG, "controle: roteiros guardados — ver (${texto.toByteArray(Charsets.UTF_8).size} B)")
        AlertDialog.Builder(contexto)
            .setTitle(RoteirosGuardados.origem(c, t))
            .setMessage(texto)
            .setPositiveButton(contexto.getString(R.string.tp_fechar), null)
            .show()
            .comOsTextosLiterais()
    }

    private fun usar(c: CopiaDoTexto) {
        AlertDialog.Builder(contexto)
            .setMessage(R.string.tp_confirma_usar)
            .setPositiveButton(R.string.tp_usar) { _, _ ->
                val texto = replica.copiaDoTexto(c.resumo)
                if (texto == null) {
                    sumiu()
                    return@setPositiveButton
                }
                val st = replica.definirTexto(texto)
                Log.i(TAG, "controle: roteiros guardados — usar → set_text ${QuallNative.Status.nome(st)}")
                if (st == QuallNative.Status.OK) salvar()
                else Toast.makeText(contexto, contexto.getString(R.string.tp_nao_deu_para_usar, QuallNative.Status.nome(st)), Toast.LENGTH_LONG).show()
            }
            .setNegativeButton(R.string.cancelar, null)
            .show()
            .comOsTextosLiterais()
    }

    private fun apagar(c: CopiaDoTexto) {
        AlertDialog.Builder(contexto)
            .setMessage(R.string.tp_confirma_apagar)
            .setPositiveButton(R.string.tp_apagar) { _, _ ->
                val st = replica.esquecerCopiaDoTexto(c.resumo)
                Log.i(TAG, "controle: roteiros guardados — apagar → ${QuallNative.Status.nome(st)}")
                if (st == QuallNative.Status.OK) salvar()
                replica.estado()?.let { desenhar(it) }
            }
            .setNegativeButton(R.string.cancelar, null)
            .show()
            .comOsTextosLiterais()
    }

    /**
     * Os botões da caixa de confirmação com o texto como está ("Usar", "Cancelar"), e não em
     * maiúsculas como o tema os poria: os textos são literais, os mesmos nas quatro telas.
     */
    private fun AlertDialog.comOsTextosLiterais(): AlertDialog {
        for (b in intArrayOf(AlertDialog.BUTTON_POSITIVE, AlertDialog.BUTTON_NEGATIVE)) getButton(b)?.isAllCaps = false
        return this
    }

    private fun sumiu() {
        Toast.makeText(contexto, R.string.tp_roteiro_sumiu, Toast.LENGTH_SHORT).show()
        replica.estado()?.let { desenhar(it) }
    }
}
