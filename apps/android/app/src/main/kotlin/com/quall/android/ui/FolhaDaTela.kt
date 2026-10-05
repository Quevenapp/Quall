package com.quall.android.ui

import android.app.Activity
import android.graphics.Typeface
import android.util.TypedValue
import android.view.ContextThemeWrapper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.switchmaterial.SwitchMaterial
import com.quall.android.R

/**
 * **A folha da engrenagem das telas de captura** — a placa (`VideoUsbActivity`) e o DVD
 * (`ConversaoDvdActivity`), que entraram no "Estúdio de bolso" e no R16 em 30/09 (decisão do Pessoa Exemplo; a
 * emenda da §11 de `docs/telas-estudio.md`). O que não cabe na tela sem rolar vem para cá: as opções
 * avançadas da placa, os números e as notas que moravam no pé das duas telas.
 *
 * O molde é o da folha de Ajustes (§6.3): "Ajustes" e "Pronto", rótulos de seção e grupos (`#1C1C24`,
 * cantos de 14) com linhas de título e valor. O corpo é **da tela**: [aoMontar] diz o que vai nele, e a
 * folha o refaz a cada [atualizar] com ela aberta — só o texto quando as linhas são as mesmas (o tique de
 * 0,5 s da placa não troca as vistas debaixo do dedo), e tudo quando elas mudam.
 */
class FolhaDaTela(private val activity: Activity) {
    private val c = ContextThemeWrapper(activity, R.style.Theme_Quall_Folha)
    private val inflar = LayoutInflater.from(c)
    private val raiz: View = inflar.inflate(R.layout.folha_da_tela, null, false)
    private val corpo: LinearLayout = raiz.findViewById(R.id.folhaCorpo)
    private var folha: BottomSheetDialog? = null

    /** Monta o corpo: chame [secao], [linha] e [nota] na ordem em que devem aparecer. */
    var aoMontar: ((FolhaDaTela) -> Unit)? = null

    val aberta: Boolean get() = folha?.isShowing == true

    init {
        raiz.findViewById<View>(R.id.folhaPronto).setOnClickListener { fechar() }
    }

    fun mostrar() {
        if (aberta) return
        montar()
        (raiz.parent as? ViewGroup)?.removeView(raiz)
        val f = BottomSheetDialog(activity, R.style.Theme_Quall_Folha)
        f.setContentView(raiz)
        // No tablet, no máximo 600 dp de largura, como a folha de Ajustes.
        if (activity.resources.configuration.smallestScreenWidthDp >= 600) f.behavior.maxWidth = c.dp(600)
        f.behavior.state = BottomSheetBehavior.STATE_EXPANDED
        f.behavior.skipCollapsed = true
        f.show()
        folha = f
    }

    fun fechar() {
        folha?.dismiss()
        folha = null
    }

    /** O estado mudou: com a folha aberta, o corpo acompanha. */
    fun atualizar() {
        if (aberta) montar()
    }

    // --- o plano do corpo --------------------------------------------------------------------------

    private sealed class Item {
        data class Secao(val rotulo: String) : Item()
        data class Linha(val titulo: String, val valor: String, val ativa: Boolean, val acao: (() -> Unit)?) : Item()
        data class Nota(val texto: String) : Item()
        data class Interruptor(val titulo: String, val ligado: Boolean, val mudar: (Boolean) -> Unit) : Item()
    }

    private var plano = ArrayList<Item>()
    private var anterior: List<Item> = emptyList()
    private val vistas = ArrayList<View>()

    fun secao(rotulo: String) { plano += Item.Secao(rotulo) }

    /** Uma linha do grupo: [acao] `null` é só leitura (sem seta); [ativa] falso, apagada e sem toque. */
    fun linha(titulo: String, valor: String, ativa: Boolean = true, acao: (() -> Unit)? = null) {
        plano += Item.Linha(titulo, valor, ativa, acao)
    }

    /** Um parágrafo dentro do grupo (`texto2`, 13). */
    fun nota(texto: String) { plano += Item.Nota(texto) }

    /** A escolha persistida da janela, compartilhada com o prompter e as outras capturas. */
    fun manterTelaLigada() {
        secao(c.getString(R.string.aj_tela))
        plano += Item.Interruptor(c.getString(R.string.aj_manter_tela_ligada), TelaLigada.escolhida(activity)) {
            TelaLigada.escolher(activity, it)
        }
        nota(c.getString(R.string.aj_manter_tela_ligada_nota))
    }

    private fun mesmaForma(a: Item, b: Item) = when {
        a is Item.Secao && b is Item.Secao -> a.rotulo == b.rotulo
        a is Item.Linha && b is Item.Linha -> a.titulo == b.titulo
        a is Item.Nota && b is Item.Nota -> true
        a is Item.Interruptor && b is Item.Interruptor -> a.titulo == b.titulo
        else -> false
    }

    private fun montar() {
        plano = ArrayList()
        aoMontar?.invoke(this)
        val novo = plano.toList()
        if (novo.size == anterior.size && vistas.size == novo.size && novo.indices.all { mesmaForma(novo[it], anterior[it]) }) {
            novo.forEachIndexed { i, item -> preencher(vistas[i], item) }
        } else {
            refazer(novo)
        }
        anterior = novo
    }

    /** Tudo de novo: as seções viram rótulo + grupo; as linhas e as notas entram no grupo da vez. */
    private fun refazer(itens: List<Item>) {
        corpo.removeAllViews()
        vistas.clear()
        var grupo: LinearLayout? = null
        var primeiraDoGrupo = true
        for (item in itens) {
            if (item is Item.Secao) {
                val rotulo = TextView(c, null, 0, R.style.RotuloDeSecao).apply { setPadding(c.dp(4), 0, 0, 0) }
                corpo.addView(rotulo, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    topMargin = c.dp(if (corpo.childCount == 0) 8 else 18)
                })
                val g = LinearLayout(c).apply {
                    orientation = LinearLayout.VERTICAL
                    setBackgroundResource(R.drawable.grupo_da_folha)
                }
                corpo.addView(g, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    topMargin = c.dp(8)
                })
                grupo = g
                primeiraDoGrupo = true
                vistas += rotulo
                preencher(rotulo, item)
                continue
            }
            val g = grupo ?: LinearLayout(c).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundResource(R.drawable.grupo_da_folha)
                corpo.addView(this, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    topMargin = c.dp(8)
                })
            }.also { grupo = it; primeiraDoGrupo = true }
            if (!primeiraDoGrupo) {
                g.addView(View(c).apply { setBackgroundResource(R.color.q_fio) },
                    LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, c.dp(1)).apply { marginStart = c.dp(14) })
            }
            primeiraDoGrupo = false
            val v = when (item) {
                is Item.Linha -> inflar.inflate(R.layout.linha_da_folha_da_tela, g, false)
                is Item.Interruptor -> SwitchMaterial(c).apply {
                    setTextColor(Cores.TEXTO)
                    textSize = 15f
                    setPadding(c.dp(14), c.dp(8), c.dp(14), c.dp(8))
                }
                else -> TextView(c).apply {
                    setTextColor(Cores.TEXTO2)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    setLineSpacing(0f, 1.1f)
                    setPadding(c.dp(14), c.dp(12), c.dp(14), c.dp(12))
                }
            }
            g.addView(v)
            vistas += v
            preencher(v, item)
        }
    }

    private fun preencher(v: View, item: Item) {
        when (item) {
            is Item.Secao -> (v as TextView).seMudou(item.rotulo)
            is Item.Nota -> (v as TextView).seMudou(item.texto)
            is Item.Interruptor -> (v as SwitchMaterial).apply {
                setOnCheckedChangeListener(null)
                seMudou(item.titulo)
                contentDescription = item.titulo
                isChecked = item.ligado
                setOnCheckedChangeListener { _, ligada -> item.mudar(ligada) }
            }
            is Item.Linha -> {
                v.findViewById<TextView>(R.id.linhaTitulo).seMudou(item.titulo)
                v.findViewById<TextView>(R.id.linhaValor).apply {
                    seMudou(item.valor)
                    typeface = if (item.valor.any { it.isDigit() }) Typeface.MONOSPACE else Typeface.DEFAULT
                }
                v.findViewById<ImageView>(R.id.linhaSeta).visibility = if (item.acao != null) View.VISIBLE else View.GONE
                val toca = item.ativa && item.acao != null
                v.alpha = if (item.ativa) 1f else 0.4f
                v.isClickable = toca
                v.isFocusable = toca
                v.setOnClickListener(if (toca) View.OnClickListener { item.acao?.invoke() } else null)
                if (!toca) v.isClickable = false
                v.contentDescription = "${item.titulo}: ${item.valor}"
            }
        }
    }
}
