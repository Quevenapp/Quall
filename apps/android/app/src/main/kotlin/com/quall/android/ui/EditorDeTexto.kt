package com.quall.android.ui

import android.content.ClipboardManager
import android.content.Context
import android.text.Editable
import android.text.TextWatcher
import com.quall.android.core.LogSeguro as Log
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.core.QuallNative
import com.quall.android.databinding.EditorDeTextoBinding
import com.quall.android.teleprompter.Ajustes
import com.quall.android.teleprompter.EdicaoDoTexto
import com.quall.android.teleprompter.Resumo

/**
 * O editor do roteiro na tela — o mesmo no prompter e no controle.
 *
 * A regra do texto que chega enquanto se edita mora em [EdicaoDoTexto] (pura, com teste); aqui só
 * se liga essa regra aos botões. O `set_text` sai **só no Confirmar** (§6), pelo `confirmar` que a
 * tela passa — que devolve o `QuallStatus` do núcleo: acima de 128 KiB é `INVALID`, o editor fica
 * aberto, como estava, e diz por quê.
 *
 * Nada que a pessoa digitou se perde sem ela escolher: o texto que chega pergunta
 * ([EdicaoDoTexto]), o gesto de voltar pergunta ([voltar]), e "Colar um roteiro" com a área de
 * transferência vazia não esvazia o rascunho.
 */
class EditorDeTexto(
    private val b: EditorDeTextoBinding,
    private val contexto: Context,
    private val tetoBytes: Long,
    /** Manda o texto ao núcleo; devolve o `QuallStatus`. */
    private val confirmar: (String) -> Int,
    /** O editor fechou (a tela volta a mostrar o que escondeu). */
    private val aoFechar: () -> Unit,
) {
    private val edicao = EdicaoDoTexto()

    /** O tamanho do roteiro ("12,3 KB de 128 KB") no idioma da tela. */
    private val t = Idioma.textos(contexto)

    val aberto: Boolean get() = edicao.aberta

    init {
        b.buttonEditorCancelar.setOnClickListener { cancelar() }
        b.buttonEditorLimpar.setOnClickListener { b.editRoteiro.setText("") }
        b.buttonEditorColar.setOnClickListener { colar() }
        b.buttonEditorConfirmar.setOnClickListener { confirmarTocado() }
        b.buttonUsarONovo.setOnClickListener {
            edicao.aceitarONovo()?.let { b.editRoteiro.setText(it) }
            b.painelConflito.visibility = View.GONE
        }
        b.buttonManterOMeu.setOnClickListener {
            edicao.manterOMeu()
            b.painelConflito.visibility = View.GONE
        }
        b.editRoteiro.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) = desenharTamanho()
        })
    }

    /**
     * Abre com o texto atual da réplica. `colarLogo`: o botão "Colar um roteiro" do controle — o
     * rascunho vira o que está na área de transferência, **se houver**; vazia, o rascunho fica o
     * texto atual (esvaziar primeiro deixava o roteiro a um "Confirmar" de ser apagado nos dois
     * lados — achado da revisão de 13/09).
     */
    fun abrir(atual: String, colarLogo: Boolean = false) {
        b.editRoteiro.setText(edicao.abrir(atual))
        b.painelConflito.visibility = View.GONE
        b.root.visibility = View.VISIBLE
        if (colarLogo) {
            val t = textoDaAreaDeTransferencia()
            if (t.isNullOrEmpty()) {
                Toast.makeText(contexto, R.string.tp_area_vazia_colar, Toast.LENGTH_LONG).show()
            } else {
                b.editRoteiro.setText(t)
            }
        }
        b.editRoteiro.requestFocus()
        desenharTamanho()
    }

    /** Chegou um texto do outro lado (bit `_TEXT`). A regra: [EdicaoDoTexto.chegou]. */
    fun chegou(novo: String) {
        when (edicao.chegou(novo, b.editRoteiro.text.toString())) {
            EdicaoDoTexto.Reacao.NADA -> Unit
            EdicaoDoTexto.Reacao.TROCAR_O_RASCUNHO -> {
                b.editRoteiro.setText(novo)
                Toast.makeText(contexto, R.string.tp_roteiro_mudou_no_editor, Toast.LENGTH_SHORT).show()
            }
            EdicaoDoTexto.Reacao.PERGUNTAR -> {
                b.painelConflito.visibility = View.VISIBLE
                Log.i(TAG, "editor: chegou um roteiro novo com o rascunho mexido — perguntando")
            }
        }
    }

    /**
     * O gesto de voltar. Sem nada digitado, fecha; com o rascunho mexido, **pergunta** — voltar na
     * borda da tela sai sem querer no meio da digitação (achado da revisão de 13/09).
     */
    fun voltar() {
        if (!edicao.temRascunho(b.editRoteiro.text.toString())) {
            cancelar()
            return
        }
        AlertDialog.Builder(contexto)
            .setMessage(R.string.tp_descartar_pergunta)
            .setPositiveButton(R.string.tp_descartar) { _, _ -> cancelar() }
            .setNegativeButton(R.string.tp_continuar_editando, null)
            .show()
    }

    /** Descarta o rascunho e fecha: a tela mostra o texto da réplica. */
    fun cancelar() {
        edicao.cancelar()
        fecharATela()
    }

    private fun textoDaAreaDeTransferencia(): String? {
        val cm = contexto.getSystemService(ClipboardManager::class.java) ?: return null
        val clip = cm.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).coerceToText(contexto)?.toString()
    }

    private fun colar() {
        val t = textoDaAreaDeTransferencia()
        if (t.isNullOrEmpty()) {
            Toast.makeText(contexto, R.string.tp_area_vazia, Toast.LENGTH_SHORT).show()
            return
        }
        val e = b.editRoteiro
        val ini = e.selectionStart.coerceAtLeast(0)
        val fim = e.selectionEnd.coerceAtLeast(0)
        e.text.replace(minOf(ini, fim), maxOf(ini, fim), t)
    }

    private fun confirmarTocado() {
        val rascunho = b.editRoteiro.text.toString()
        if (rascunho.contains(Char(0))) {
            Toast.makeText(contexto, R.string.tp_caractere_nulo, Toast.LENGTH_LONG).show()
            return
        }
        val bytes = rascunho.toByteArray(Charsets.UTF_8).size.toLong()
        if (bytes > tetoBytes) {
            Toast.makeText(contexto, contexto.getString(R.string.tp_passou_do_limite, Ajustes.tamanhoDoRoteiro(bytes, tetoBytes, t)), Toast.LENGTH_LONG).show()
            return
        }
        // Pergunta o que mandaria **sem fechar**: se o núcleo recusar, o editor fica como estava —
        // inclusive a pergunta de um texto que chegou, que a primeira versão perdia.
        val mandar = edicao.aMandar(rascunho)
        if (mandar != null) {
            val st = confirmar(mandar)
            if (st != QuallNative.Status.OK) {
                Toast.makeText(contexto, contexto.getString(R.string.tp_nucleo_recusou, QuallNative.Status.nome(st)), Toast.LENGTH_LONG).show()
                return
            }
            Log.i(TAG, "editor: roteiro confirmado — ${mandar.toByteArray(Charsets.UTF_8).size} bytes, resumo ${Resumo.de(mandar)}")
        }
        edicao.confirmar(rascunho)
        fecharATela()
    }

    private fun fecharATela() {
        b.painelConflito.visibility = View.GONE
        b.root.visibility = View.GONE
        contexto.getSystemService(InputMethodManager::class.java)
            ?.hideSoftInputFromWindow(b.editRoteiro.windowToken, 0)
        aoFechar()
    }

    private fun desenharTamanho() {
        val bytes = b.editRoteiro.text.toString().toByteArray(Charsets.UTF_8).size.toLong()
        val tamanho = Ajustes.tamanhoDoRoteiro(bytes, tetoBytes, t)
        b.textEditorTamanho.text = if (bytes > tetoBytes) contexto.getString(R.string.tp_acima_do_limite, tamanho) else tamanho
    }

    companion object {
        private const val TAG = "QuallTeleprompter"
    }
}
