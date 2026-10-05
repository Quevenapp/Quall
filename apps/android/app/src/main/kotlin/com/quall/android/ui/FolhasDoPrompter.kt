package com.quall.android.ui

import android.app.Activity
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.view.ContextThemeWrapper
import androidx.core.widget.NestedScrollView
import android.widget.TextView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.button.MaterialButton
import com.google.android.material.slider.Slider
import com.google.android.material.switchmaterial.SwitchMaterial
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.teleprompter.Divisao
import com.quall.android.teleprompter.EstadoDoTeleprompter
import com.quall.android.teleprompter.Orientacao

// ================================================================================================
// As folhas do prompter, no modelo das `.sheet` do iOS (`docs/telas-android-como-ios.md` §1.3 e §6):
// a folha de Ajustes (`FolhaDeAjustes`) e a do endereço em letra grande (`FolhaDoEndereco`,
// `FolhaDoEnderecoDaCamera`). No Android, `BottomSheetDialog` do Material, **sempre escura** (o iOS
// força `.dark` nas telas do prompter) e sem trazer de volta as barras do sistema que a tela imersiva
// escondeu.
// ================================================================================================

/**
 * Uma folha de baixo escura que não devolve as barras do sistema à tela imersiva. [metade]: abre na
 * metade da altura (a de Ajustes: o texto atrás continua à vista, com as guias do enquadramento, e um
 * arrasto a abre inteira); senão, inteira.
 */
fun folhaEscura(activity: Activity, conteudo: View, metade: Boolean = false, aoFechar: () -> Unit = {}): BottomSheetDialog {
    val f = BottomSheetDialog(activity, R.style.Theme_Quall_Folha)
    f.setContentView(conteudo)
    if (metade) {
        f.behavior.peekHeight = (activity.resources.displayMetrics.heightPixels * 0.55f).toInt()
        f.behavior.state = BottomSheetBehavior.STATE_COLLAPSED
    } else {
        f.behavior.state = BottomSheetBehavior.STATE_EXPANDED
        f.behavior.skipCollapsed = true
    }
    f.setOnShowListener {
        f.window?.let { w ->
            WindowCompat.setDecorFitsSystemWindows(w, false)
            WindowInsetsControllerCompat(w, w.decorView).apply {
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsetsCompat.Type.systemBars())
            }
        }
    }
    f.setOnDismissListener { aoFechar() }
    return f
}

internal fun Context.texto(t: String, sp: Float, cor: Int = Cores.BRANCO, negrito: Boolean = false): TextView =
    TextView(this).apply {
        text = t
        setTextColor(cor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        if (negrito) setTypeface(typeface, Typeface.BOLD)
    }

internal fun Context.botaoContornado(rotulo: String, icone: Int? = null, acao: () -> Unit): MaterialButton =
    MaterialButton(this, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
        text = rotulo
        isAllCaps = false
        setTextColor(Cores.ACENTO_CLARO)
        strokeColor = ColorStateList.valueOf(Cores.comAlfa(Cores.BRANCO, 0.25f))
        if (icone != null) {
            setIconResource(icone)
            iconTint = ColorStateList.valueOf(Cores.ACENTO_CLARO)
            iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
        }
        setOnClickListener { acao() }
    }

/**
 * **O endereço e o PIN em letra grande** (`FolhaDoEndereco` / `FolhaDoEnderecoDaCamera` do iOS): para
 * quem vai controlar ou receber ler de longe e digitar. Era a folha do QR até 24/09, quando o QR
 * saiu por decisão do Pessoa Exemplo.
 */
fun mostrarFolhaDoEndereco(
    activity: Activity,
    titulo: String,
    instrucao: String,
    endereco: String?,
    pin: String,
    aoFechar: () -> Unit = {},
): BottomSheetDialog {
    val c = ContextThemeWrapper(activity, R.style.Theme_Quall_Folha)
    val raiz = LinearLayout(c).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setBackgroundColor(Cores.FOLHA)
        setPadding(c.dp(24), c.dp(24), c.dp(24), c.dp(24))
    }
    raiz.addView(c.texto(titulo, 20f, negrito = true).apply { gravity = Gravity.CENTER })
    raiz.addView(c.texto(instrucao, 13f, Cores.CINZA).apply {
        gravity = Gravity.CENTER
        setPadding(0, c.dp(18), 0, c.dp(6))
    })
    fun grande(t: String, cor: Int, negrito: Boolean) = TextView(c).apply {
        text = t
        setTextColor(cor)
        typeface = Typeface.create(Typeface.MONOSPACE, if (negrito) Typeface.BOLD else Typeface.NORMAL)
        gravity = Gravity.CENTER
        maxLines = 1
        setAutoSizeTextTypeUniformWithConfiguration(12, 40, 1, TypedValue.COMPLEX_UNIT_SP)
    }
    raiz.addView(grande(endereco ?: c.getString(R.string.tp_sem_rede), if (endereco == null) Cores.LARANJA else Cores.BRANCO, false),
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, c.dp(56)))
    raiz.addView(grande(c.getString(R.string.tp_pin_rotulo, pin), Cores.BRANCO, true).apply {
        contentDescription = c.getString(R.string.tp_pin_rotulo, pin.toCharArray().joinToString(" "))
    }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, c.dp(56)))
    lateinit var f: BottomSheetDialog
    raiz.addView(c.botaoContornado(c.getString(R.string.tp_fechar)) { f.dismiss() }, LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = c.dp(18) })
    f = folhaEscura(activity, raiz, aoFechar = aoFechar)
    f.show()
    return f
}

/**
 * O que os controles do texto leem e mudam (`ControlesDoTexto` do iOS): a folha de Ajustes do
 * prompter e o painel do controle remoto usam os mesmos.
 */
interface ControlesDoTextoAlvo {
    fun estadoAgora(): EstadoDoTeleprompter
    fun definirVelocidade(v: Double)
    fun definirFonte(v: Double)
    fun definirMargem(v: Double)
    fun definirLinhaDeLeitura(v: Double)
    fun definirEspelho(ligado: Boolean)

    /** A fonte automática do prompter ligada: a fonte à mão fica travada (só o prompter tem). */
    fun fonteAutomaticaLigada(): Boolean = false
}

/** O que a folha de Ajustes lê e muda no prompter (a tela implementa). */
interface AjustesDoPrompter : ControlesDoTextoAlvo {
    fun voltarAoComeco()
    fun orientacaoAgora(): Orientacao
    fun escolherOrientacao(o: Orientacao)

    /** Gravando, a orientação fica travada (um arquivo só, §5.2): o menu desabilita e diz por quê. */
    fun orientacaoTravada(): Boolean
    fun definirFonteAutomatica(ligada: Boolean)
    fun larguraInteira()
}

/** A seção que só a tela com câmera tem (`SecaoDaTelaComCamera` do iOS). */
interface AjustesDaCamera {
    fun previaEspelhada(): Boolean
    fun espelharPrevia(ligado: Boolean)
    fun ladoDoTexto(): Divisao.Escolha
    fun escolherLado(e: Divisao.Escolha)
}

/**
 * **As peças dos ajustes** (as linhas "Título ……… valor", o interruptor com legenda, o menu, o
 * deslizante e os botões − e +), montadas num [LinearLayout] e refeitas por [atualizar] quando o
 * estado muda. [corDoTexto]: branco na folha escura do prompter; a cor do tema no controle remoto.
 *
 * Os deslizantes da velocidade saem **ao vivo** (não refaz o layout, e é a que se ajusta ouvindo a
 * pessoa); fonte, margem e linha de leitura saem **ao soltar** — cada uma refaz o layout do roteiro
 * inteiro (até 128 KiB) no prompter, e um arrasto não pode pedir dezenas de layouts. Um valor que
 * chega do outro lado aparece, salvo no deslizante que o dedo está segurando.
 */
class MontadorDeAjustes(val c: Context, private val corDoTexto: Int) {
    private val atualizadores = mutableListOf<() -> Unit>()

    fun atualizar() {
        for (a in atualizadores) a()
    }

    fun texto(t: String, sp: Float, cor: Int = corDoTexto, negrito: Boolean = false): TextView = c.texto(t, sp, cor, negrito)

    fun espaco(corpo: LinearLayout) = corpo.addView(View(c), LinearLayout.LayoutParams(1, c.dp(18)))

    fun interruptor(corpo: LinearLayout, titulo: String, legenda: () -> String, ligado: () -> Boolean, mudar: (Boolean) -> Unit) {
        espaco(corpo)
        val linha = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val coluna = LinearLayout(c).apply { orientation = LinearLayout.VERTICAL }
        coluna.addView(texto(titulo, 15f, negrito = true))
        val leg = texto(legenda(), 12f, Cores.CINZA)
        coluna.addView(leg)
        linha.addView(coluna, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val s = SwitchMaterial(c).apply {
            isChecked = ligado()
            contentDescription = titulo
        }
        var mexendo = false
        // Depois de mudar, tudo se refaz: ligar a fonte automática trava a fonte à mão e muda a
        // legenda na hora (a revisão do código, 28/09).
        s.setOnCheckedChangeListener { _, v -> if (!mexendo) { mudar(v); atualizar() } }
        linha.addView(s)
        corpo.addView(linha)
        atualizadores += {
            mexendo = true
            if (s.isChecked != ligado()) s.isChecked = ligado()
            mexendo = false
            leg.text = legenda()
        }
    }

    /** Um "Picker(.menu)": o título à esquerda, o valor com ▾ à direita, e o menu no toque. */
    fun <T> seletor(
        corpo: LinearLayout,
        titulo: String,
        legenda: () -> String,
        opcoes: List<T>,
        nome: (T) -> String,
        atual: () -> T,
        habilitado: () -> Boolean = { true },
        escolher: (T) -> Unit,
    ) {
        espaco(corpo)
        val linha = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        linha.addView(texto(titulo, 15f, negrito = true), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val valor = texto(nome(atual()) + "  ▾", 15f, Cores.ACENTO_CLARO).apply {
            setPadding(c.dp(8), c.dp(8), 0, c.dp(8))
            contentDescription = "$titulo: ${nome(atual())}"
        }
        valor.setOnClickListener {
            val m = PopupMenu(c, valor)
            opcoes.forEachIndexed { i, o -> m.menu.add(0, i, i, nome(o)).apply { isCheckable = true; isChecked = o == atual() } }
            m.setOnMenuItemClickListener { item ->
                escolher(opcoes[item.itemId])
                valor.text = nome(atual()) + "  ▾"
                valor.contentDescription = "$titulo: ${nome(atual())}"
                true
            }
            m.show()
        }
        linha.addView(valor)
        corpo.addView(linha)
        val leg = texto(legenda(), 12f, Cores.CINZA)
        corpo.addView(leg)
        val refazer = {
            valor.text = nome(atual()) + "  ▾"
            valor.isEnabled = habilitado()
            valor.alpha = if (habilitado()) 1f else 0.45f
            leg.text = legenda()
        }
        refazer()
        atualizadores += refazer
    }

    /** "Título ……… valor", e o controle embaixo (`ControlesDoTexto.linha` do iOS). */
    fun linhaDeAjuste(corpo: LinearLayout, titulo: String, valor: () -> String, controle: View) {
        espaco(corpo)
        val cab = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL }
        cab.addView(texto(titulo, 15f, negrito = true), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val v = texto(valor(), 15f, Cores.CINZA).apply { typeface = Typeface.MONOSPACE }
        cab.addView(v)
        corpo.addView(cab)
        corpo.addView(controle)
        atualizadores += { v.text = valor() }
    }

    /** Um botão pequeno de − ou + (o `BotaoPequeno` do iOS). */
    fun pequeno(icone: Int?, rotulo: String, texto: String? = null): View {
        val v: View = if (icone != null) {
            ImageView(c).apply {
                setImageResource(icone)
                imageTintList = ColorStateList.valueOf(corDoTexto)
                scaleType = ImageView.ScaleType.CENTER
            }
        } else {
            texto(texto ?: "", 15f, negrito = true).apply { gravity = Gravity.CENTER }
        }
        // 48 × 48 dp de área de toque, com o desenho de 36 × 32 do iOS (o fundo recua).
        v.background = android.graphics.drawable.InsetDrawable(
            fundoArredondado(Cores.comAlfa(Cores.CINZA, 0.18f), c.dp(8).toFloat()), c.dp(6), c.dp(8), c.dp(6), c.dp(8))
        v.contentDescription = rotulo
        v.isClickable = true
        return v
    }

    /**
     * Um deslizante contínuo (sem `stepSize`: o do Material recusa valor fora do passo com exceção, e
     * o ponto flutuante da réplica não cai sempre no passo), com o degrau aplicado na hora de mandar.
     */
    fun deslizante(de: Double, ate: Double, degrau: Double, rotulo: String, aoVivo: Boolean, atual: () -> Double, definir: (Double) -> Unit): Slider {
        val s = Slider(c)
        s.valueFrom = de.toFloat()
        s.valueTo = ate.toFloat()
        s.value = atual().coerceIn(de, ate).toFloat()
        s.contentDescription = rotulo
        s.isTickVisible = false
        s.trackActiveTintList = ColorStateList.valueOf(Cores.ACENTO)
        s.thumbTintList = ColorStateList.valueOf(Cores.ACENTO)
        s.labelBehavior = com.google.android.material.slider.LabelFormatter.LABEL_GONE
        var segurando = false
        fun noDegrau(v: Float) = (Math.round((v - de) / degrau) * degrau + de).coerceIn(de, ate)
        s.addOnChangeListener { _, v, doDedo -> if (doDedo && aoVivo) definir(noDegrau(v)) }
        s.addOnSliderTouchListener(object : Slider.OnSliderTouchListener {
            override fun onStartTrackingTouch(sl: Slider) { segurando = true }
            override fun onStopTrackingTouch(sl: Slider) {
                segurando = false
                definir(noDegrau(sl.value))
            }
        })
        atualizadores += {
            if (!segurando) {
                val v = atual().coerceIn(de, ate).toFloat()
                if (s.value != v) s.value = v
            }
        }
        return s
    }

    /**
     * **Os controles do texto** (`ControlesDoTexto` do iOS): velocidade com − e + que repetem e o
     * deslizante ao vivo; fonte com A− e A+ (travada com a fonte automática); margem; linha de
     * leitura; e o espelho.
     */
    fun controlesDoTexto(corpo: LinearLayout, alvo: ControlesDoTextoAlvo) {
        val e = { alvo.estadoAgora() }
        val vel = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val menos = pequeno(R.drawable.ic_q_menos, c.getString(R.string.tp_mais_devagar))
        val mais = pequeno(R.drawable.ic_q_mais, c.getString(R.string.tp_mais_depressa))
        repetirEnquantoPressionado(menos) { alvo.definirVelocidade(e().velocidade - 0.1) }
        repetirEnquantoPressionado(mais) { alvo.definirVelocidade(e().velocidade + 0.1) }
        vel.addView(menos, LinearLayout.LayoutParams(c.dp(48), c.dp(48)))
        vel.addView(deslizante(0.05, 8.0, 0.05, c.getString(R.string.tp_velocidade), aoVivo = true, { e().velocidade }) { alvo.definirVelocidade(it) },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        vel.addView(mais, LinearLayout.LayoutParams(c.dp(48), c.dp(48)))
        linhaDeAjuste(corpo, c.getString(R.string.tp_velocidade), { c.getString(R.string.tp_linhas_por_s, e().velocidade) }, vel)

        val fonte = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val aMenos = pequeno(null, c.getString(R.string.tp_fonte_menor), "A−")
        val aMais = pequeno(null, c.getString(R.string.tp_fonte_maior), "A+")
        aMenos.setOnClickListener { alvo.definirFonte(e().fonte - 4) }
        aMais.setOnClickListener { alvo.definirFonte(e().fonte + 4) }
        val sFonte = deslizante(16.0, 200.0, 2.0, c.getString(R.string.tp_fonte), aoVivo = false, { e().fonte }) { alvo.definirFonte(it) }
        fonte.addView(aMenos, LinearLayout.LayoutParams(c.dp(48), c.dp(48)))
        fonte.addView(sFonte, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        fonte.addView(aMais, LinearLayout.LayoutParams(c.dp(48), c.dp(48)))
        val travarFonte = {
            val travada = alvo.fonteAutomaticaLigada()
            for (v in listOf(aMenos, aMais, sFonte)) v.isEnabled = !travada
            fonte.alpha = if (travada) 0.45f else 1f
        }
        travarFonte()
        atualizadores += travarFonte
        linhaDeAjuste(corpo, c.getString(R.string.tp_fonte), {
            c.getString(if (alvo.fonteAutomaticaLigada()) R.string.tp_fonte_sp_automatica else R.string.tp_fonte_sp, e().fonte)
        }, fonte)

        val margem = c.getString(R.string.tp_margem)
        linhaDeAjuste(corpo, margem, { c.getString(R.string.tp_margem_valor, e().margem * 100) },
            deslizante(0.0, 0.45, 0.01, margem, aoVivo = false, { e().margem }) { alvo.definirMargem(it) })
        val linha = c.getString(R.string.tp_linha_de_leitura)
        linhaDeAjuste(corpo, linha, { c.getString(R.string.tp_linha_valor, e().linhaDeLeitura * 100) },
            deslizante(0.0, 1.0, 0.01, linha, aoVivo = false, { e().linhaDeLeitura }) { alvo.definirLinhaDeLeitura(it) })
        interruptor(corpo, c.getString(R.string.tp_espelho), { c.getString(R.string.tp_espelho_legenda) },
            { e().espelho }, { alvo.definirEspelho(it) })
    }
}

/**
 * **A folha de Ajustes** do prompter (`FolhaDeAjustes` do iOS), na mesma ordem: "Voltar ao começo";
 * a seção da câmera (só na R5); a orientação; a fonte automática e o enquadramento; e os controles do
 * texto ([MontadorDeAjustes.controlesDoTexto]).
 */
class FolhaDeAjustesDoPrompter(
    private val activity: Activity,
    private val prompter: AjustesDoPrompter,
    private val camera: AjustesDaCamera?,
    private val aoFechar: () -> Unit,
) {
    /** O tema escuro da folha também nos controles (o interruptor, o deslizante, o menu). */
    private val c: Context = ContextThemeWrapper(activity, R.style.Theme_Quall_Folha)
    private val m = MontadorDeAjustes(c, Cores.BRANCO)

    /** Os nomes das opções que vêm dos módulos puros (o lado do texto), no idioma da tela. */
    private val t = Idioma.textos(activity)
    private lateinit var folha: BottomSheetDialog

    val aberta: Boolean get() = ::folha.isInitialized && folha.isShowing

    fun mostrar() {
        val corpo = LinearLayout(c).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(c.dp(20), c.dp(8), c.dp(20), c.dp(28))
        }
        // O alto da folha: o título e "Pronto" (a barra de navegação do iOS).
        val alto = FrameLayout(c).apply { setPadding(0, c.dp(8), 0, c.dp(12)) }
        alto.addView(c.texto(c.getString(R.string.tp_ajustes_do_texto), 17f, negrito = true), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        alto.addView(c.texto(c.getString(R.string.tp_pronto), 17f, Cores.ACENTO_CLARO, negrito = true).apply {
            setPadding(c.dp(12), c.dp(8), 0, c.dp(8))
            setOnClickListener { folha.dismiss() }
        }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.END or Gravity.CENTER_VERTICAL))
        val tudo = LinearLayout(c).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Cores.FOLHA)
        }
        tudo.addView(alto, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            leftMargin = c.dp(20); rightMargin = c.dp(20)
        })

        corpo.addView(c.botaoContornado(c.getString(R.string.tp_voltar_ao_comeco), R.drawable.ic_q_inicio) { prompter.voltarAoComeco() },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        if (camera != null) secaoDaCamera(corpo, camera)
        secaoDaOrientacao(corpo)
        secaoDosAjustesLocais(corpo)
        m.controlesDoTexto(corpo, prompter)

        // `NestedScrollView`: a folha de baixo só rola por dentro com rolagem aninhada.
        val rolagem = NestedScrollView(c).apply { addView(corpo) }
        tudo.addView(rolagem)
        folha = folhaEscura(activity, tudo, metade = true, aoFechar = aoFechar)
        folha.show()
    }

    fun fechar() {
        if (aberta) folha.dismiss()
    }

    /** O estado mudou (daqui ou do controle): a folha acompanha. */
    fun atualizar() {
        if (aberta) m.atualizar()
    }

    private fun secaoDaCamera(corpo: LinearLayout, cam: AjustesDaCamera) {
        m.interruptor(corpo, c.getString(R.string.r5_previa_como_espelho),
            { c.getString(R.string.r5_previa_legenda) },
            { cam.previaEspelhada() }, { cam.espelharPrevia(it) })
        // O automático desde 30/09 (o pedido do Pessoa Exemplo): o texto em cima, empilhado, também deitado;
        // embaixo só de ponta-cabeça. À esquerda e à direita ficam para quem quiser.
        m.seletor(corpo, c.getString(R.string.r5_lado_do_texto),
            { c.getString(R.string.r5_lado_legenda) },
            Divisao.Escolha.entries, { it.nome(t) }, { cam.ladoDoTexto() }) { cam.escolherLado(it) }
        // O controle remoto da câmera (R9b): a mesma opção da folha de Ajustes do app, à mão aqui — sair
        // da R5 para ligá-la fecharia a câmera dela.
        m.interruptor(corpo, c.getString(R.string.aj_permitir_controle_remoto),
            { c.getString(R.string.aj_permitir_controle_remoto_nota) },
            { com.quall.android.capture.FilmadorDaCamera.permitido(activity) },
            { com.quall.android.capture.FilmadorDaCamera.permitir(activity, it) })
    }

    private fun secaoDaOrientacao(corpo: LinearLayout) {
        m.seletor(corpo, c.getString(R.string.tp_orientacao),
            {
                c.getString(R.string.tp_orientacao_legenda) +
                    if (prompter.orientacaoTravada()) " " + c.getString(R.string.tp_orientacao_travada_legenda) else ""
            },
            Orientacao.entries, { c.getString(it.rotulo) }, { prompter.orientacaoAgora() },
            habilitado = { !prompter.orientacaoTravada() }) { prompter.escolherOrientacao(it) }
    }

    private fun secaoDosAjustesLocais(corpo: LinearLayout) {
        m.interruptor(corpo, c.getString(R.string.aj_manter_tela_ligada),
            { c.getString(R.string.aj_manter_tela_ligada_nota) },
            { TelaLigada.escolhida(activity) }, { TelaLigada.escolher(activity, it) })
        m.interruptor(corpo, c.getString(R.string.tp_fonte_automatica), {
            if (prompter.fonteAutomaticaLigada()) {
                c.getString(R.string.tp_fonte_automatica_agora, prompter.estadoAgora().fonte)
            } else {
                c.getString(R.string.tp_fonte_automatica_legenda)
            }
        }, { prompter.fonteAutomaticaLigada() }, { prompter.definirFonteAutomatica(it) })
        m.espaco(corpo)
        val linha = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val coluna = LinearLayout(c).apply { orientation = LinearLayout.VERTICAL }
        coluna.addView(c.texto(c.getString(R.string.tp_enquadramento), 15f, negrito = true))
        coluna.addView(c.texto(c.getString(R.string.tp_enquadramento_legenda), 12f, Cores.CINZA))
        linha.addView(coluna, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        linha.addView(c.botaoContornado(c.getString(R.string.tp_largura_inteira)) { prompter.larguraInteira() })
        corpo.addView(linha)
    }
}
