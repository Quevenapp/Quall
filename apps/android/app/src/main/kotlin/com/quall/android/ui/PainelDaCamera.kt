package com.quall.android.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.TypedValue
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import com.google.android.material.switchmaterial.SwitchMaterial
import com.quall.android.R
import com.quall.android.capture.AjusteDaCamera
import com.quall.android.capture.AjusteDaCamera.Balanco
import com.quall.android.capture.AjusteDaCamera.Exposicao
import com.quall.android.capture.AjusteDaCamera.Foco
import com.quall.android.capture.ControlesDaCamera
import com.quall.android.capture.EscalasDaCamera
import com.quall.android.capture.RegrasDosControles
import com.quall.android.capture.RegrasDosControles.Controle
import com.quall.android.core.Idioma
import com.quall.android.core.Textos
import com.quall.android.mirror.MirrorService
import java.util.Locale

/**
 * **O painel "Ajustes da câmera"** (R9, `docs/controles-de-camera.md` §4.2–§4.3) no Android: uma vista
 * própria por cima da tela, na mesma janela, **sem véu e sem diálogo** — não é a `folhaEscura` nem um
 * `BottomSheetDialog`, que escurecem a prévia, abrem inteiros num arrasto e fecham no toque de fora. Fora
 * do painel a prévia fica sem escurecimento nenhum, porque a pessoa está julgando a exposição; tocar nela
 * com o painel aberto é um toque na prévia (§4.4).
 *
 * - **Não rola onde cabe.** Os quatro grupos são abas no alto: "Exposição", "ISO e obturador", "Balanço"
 *   e "Foco". Cada aba cabe sem rolar no A10s (720×1520, 280 dpi: 411 × 868 dp). As alturas são fixas e
 *   somadas em [ALTURA_MAXIMA_DP]: o cromo (leitura, abas, aviso e o pé) tem 148 dp e a aba mais alta, a
 *   Exposição, 222 dp — 370 dp, contra os ~386 dp da metade de baixo do A10s em pé, descontada a barra
 *   de navegação, e os ~387 dp da altura dele deitado, descontada a barra de status.
 * - **Onde não cabe** (a R5 no celular deitado: a metade do texto do A10s tem 360 px, ~206 dp), **só o
 *   corpo rola**: a linha do alto (a leitura e o "Pronto") e as abas ficam fixas, sempre à vista, e
 *   "Restaurar automático" fica no fim da rolagem. Decisão da sessão principal de 01/10, depois da prova
 *   no A10s, em que o "Pronto" rolava junto e saía da tela. A rolagem é uma `ScrollView` com
 *   `fillViewport`: onde o corpo cabe, ela não rola e as medidas são as de antes.
 * - **O texto tem tamanho fixo** (em dp, sem a escala de fonte do sistema), porque o espaço é contado.
 * - O alto mostra a **linha de leitura** (§3.6, no máximo 4 vezes por segundo); o pé, **"Restaurar
 *   automático"**.
 *
 * O painel não guarda estado da câmera: a cada tique ele pergunta à [FonteDoPainel] e desenha o que ela
 * diz — os [ControlesDaCamera] do dono aberto ([MirrorService.controlesDaCamera]), ou, no receptor (R9b,
 * `docs/controle-remoto-da-camera.md` §12), a câmera do outro lado, desenhada **das capacidades que
 * chegaram** ([OfertaDoPainel.deRemota]). Sem câmera (a câmera ainda abrindo), os controles ficam
 * apagados; a câmera do outro lado que não permite controle remoto deixa tudo apagado com os valores.
 */
@SuppressLint("ViewConstructor")
class PainelDaCamera(
    contexto: Context,
    /**
     * De onde vem o que se mostra: a câmera deste aparelho, ou a do outro lado (R9b, [FonteDoPainel]).
     * `null` = ainda sem câmera (os controles ficam apagados). A mesma instância enquanto a câmera for a
     * mesma: trocar de fonte refaz o corpo.
     */
    private val fonteAgora: () -> FonteDoPainel?,
    /** A opção da tela deste aparelho: não aparece no painel da câmera do outro lado. */
    private val comAjusteDeTela: Boolean = false,
    private val aoFecharPeloPronto: () -> Unit,
) : LinearLayout(contexto) {

    /**
     * O painel da câmera **deste** aparelho: a tela R5 (os controles do dono da R5) ou a câmera comum.
     */
    constructor(contexto: Context, daTelaR5: Boolean, aoFecharPeloPronto: () -> Unit) :
        this(contexto, fonteLocal(daTelaR5), comAjusteDeTela = !daTelaR5, aoFecharPeloPronto = aoFecharPeloPronto)

    companion object {
        /** A soma das alturas fixas da aba mais alta com o cromo (ver a doc da classe). */
        const val ALTURA_MAXIMA_DP = 370

        /** A fonte dos controles do dono aberto: a mesma enquanto o dono for o mesmo. */
        private fun fonteLocal(daTelaR5: Boolean): () -> FonteDoPainel? {
            var ultima: FonteDoPainel.Local? = null
            return {
                val c = MirrorService.controlesDaCamera(daTelaR5)
                if (c == null) null else ultima?.takeIf { it.c === c } ?: FonteDoPainel.Local(c).also { ultima = it }
            }
        }

        /** Os nomes das abas (o roteiro de bancada `prova-r9-controles.py` procura os de português). */
        val ABAS = listOf(R.string.cam_aba_exposicao, R.string.cam_aba_iso_e_obturador, R.string.cam_aba_balanco, R.string.cam_aba_foco)
    }

    private fun dp(v: Int): Int = context.dp(v)

    /** O texto de [id] no idioma da tela (o painel vive numa Activity: o AppCompat já aplica a escolha). */
    private fun s(id: Int, vararg a: Any): String = if (a.isEmpty()) context.getString(id) else context.getString(id, *a)

    /** Os textos para os módulos puros ([RegrasDosControles], [EscalasDaCamera]), pedidos na hora. */
    private val t: Textos get() = Idioma.textos(context)

    private val principal = Handler(Looper.getMainLooper())
    private var sincronizandoTela = false
    private val manterTelaLigada = if (comAjusteDeTela) SwitchMaterial(contexto).apply {
        text = s(R.string.aj_manter_tela_ligada)
        contentDescription = text
        setTextColor(Cores.TEXTO)
        setTextSize(TypedValue.COMPLEX_UNIT_DIP, 14f)
        isChecked = TelaLigada.escolhida(contexto)
        setOnCheckedChangeListener { _, ligada ->
            if (!sincronizandoTela) TelaLigada.escolher(contexto, ligada)
        }
    } else null
    private var aba = 0
    private val leituraTxt = texto("", 12f, Cores.TEXTO2).apply {
        typeface = Typeface.MONOSPACE
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }
    private val avisoTxt = texto("", 12f, Cores.AGUARDANDO_TEXTO).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }
    private val linhaDasAbas = LinearLayout(contexto).apply { orientation = HORIZONTAL }
    private val corpo = LinearLayout(contexto).apply { orientation = VERTICAL }
    private val restaurar = texto(s(R.string.cam_restaurar_automatico), 14f, Cores.ACENTO_CLARO, negrito = true).apply {
        gravity = Gravity.CENTER
        isClickable = true
        isFocusable = true
        background = fundoArredondado(Cores.SUPERFICIE_ALTA, dp(10).toFloat())
    }

    /** "Usar meus ajustes" (07/10): a câmera abre no automático e lembra o último manual. */
    private val meusAjustes = texto(s(R.string.cam_usar_meus_ajustes), 14f, Cores.ACENTO_CLARO, negrito = true).apply {
        gravity = Gravity.CENTER
        isClickable = true
        isFocusable = true
        background = fundoArredondado(Cores.SUPERFICIE_ALTA, dp(10).toFloat())
        visibility = GONE
    }

    /** A rolagem do corpo (só rola onde o painel não cabe). */
    private val rolagem: android.widget.ScrollView

    /** O que, se mudar, refaz o corpo da aba (os deslizantes não: refazer no meio do arrasto o soltaria). */
    private var chaveDoCorpo: List<Any?>? = null
    /** Os atualizadores dos valores à vista (o texto dos deslizantes, a posição deles fora do arrasto). */
    private val atualizadores = ArrayList<(FonteDoPainel) -> Unit>()
    private var segurando = false

    private val tique = object : Runnable {
        override fun run() {
            atualizar()
            principal.postDelayed(this, RegrasDosControles.INTERVALO_DA_LEITURA_MS)
        }
    }

    init {
        orientation = VERTICAL
        // Opaco: o fundo da tela (`Cores.FUNDO`), e só ele — nada de véu na prévia (§4.2).
        setBackgroundColor(Cores.FUNDO)
        isClickable = true // os toques nos vãos do painel não passam para a prévia embaixo
        setPadding(dp(12), dp(MedidasDoPainel.RECUO_VERTICAL_DP), dp(12), dp(MedidasDoPainel.RECUO_VERTICAL_DP))
        // 1. a leitura de volta e o "Pronto"
        val alto = LinearLayout(contexto).apply { orientation = HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        alto.addView(leituraTxt, LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        alto.addView(texto(s(R.string.cam_pronto), 15f, Cores.ACENTO_CLARO, negrito = true).apply {
            gravity = Gravity.CENTER
            setPadding(dp(12), 0, dp(4), 0)
            isClickable = true
            isFocusable = true
            contentDescription = s(R.string.cam_pronto)
            setOnClickListener { aoFecharPeloPronto() }
        }, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(MedidasDoPainel.ALTO_DP)))
        addView(alto, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(MedidasDoPainel.ALTO_DP)))
        // 2. as abas
        ABAS.forEachIndexed { i, nome ->
            linhaDasAbas.addView(texto(s(nome), 13f, Cores.TEXTO2, negrito = true).apply {
                gravity = Gravity.CENTER
                maxLines = 2
                isClickable = true
                isFocusable = true
                setOnClickListener { escolherAba(i) }
            }, LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply { if (i > 0) leftMargin = dp(4) })
        }
        addView(linhaDasAbas, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(MedidasDoPainel.ABAS_DP)).apply {
            topMargin = dp(MedidasDoPainel.MARGEM_DAS_ABAS_DP)
        })
        // 3. o corpo da aba (preenche), o aviso e o pé — os três dentro da rolagem, que só rola quando
        // não cabem (ver a doc da classe). Com `fillViewport`, o corpo de peso 1 preenche a sobra; sem
        // espaço, o `LinearLayout` mede o corpo pelo conteúdo, e a `ScrollView` rola.
        val conteudo = LinearLayout(contexto).apply { orientation = VERTICAL }
        conteudo.addView(corpo, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f).apply { topMargin = dp(6) })
        conteudo.addView(avisoTxt, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(16)))
        restaurar.setOnClickListener { fonteAgora()?.takeIf { it.vivo }?.restaurar(); atualizar() }
        meusAjustes.setOnClickListener { fonteAgora()?.takeIf { it.vivo }?.usarMeusAjustes(); atualizar() }
        // "Restaurar automático" e "Usar meus ajustes" lado a lado; sem lembrança, o primeiro ocupa a linha.
        val linhaDoPe = LinearLayout(contexto).apply { orientation = HORIZONTAL }
        linhaDoPe.addView(restaurar, LayoutParams(0, dp(36), 1f))
        linhaDoPe.addView(meusAjustes, LayoutParams(0, dp(36), 1f).apply { leftMargin = dp(8) })
        conteudo.addView(linhaDoPe, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(36)).apply { topMargin = dp(4) })
        // A câmera comum tem esta opção à mão. Na R5 ela fica nos Ajustes do prompter.
        // O acréscimo fica na rolagem: a leitura, as abas e o Pronto continuam fixos no alto.
        manterTelaLigada?.let {
            conteudo.addView(it, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            conteudo.addView(texto(s(R.string.aj_manter_tela_ligada_nota), 12f, Cores.TEXTO2),
                LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        rolagem = android.widget.ScrollView(contexto).apply {
            isFillViewport = true
            overScrollMode = OVER_SCROLL_NEVER
            addView(conteudo, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        addView(rolagem, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        pintarAbas()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        principal.removeCallbacks(tique)
        principal.post(tique)
    }

    override fun onDetachedFromWindow() {
        principal.removeCallbacks(tique)
        super.onDetachedFromWindow()
    }

    override fun onVisibilityChanged(changedView: View, visibility: Int) {
        super.onVisibilityChanged(changedView, visibility)
        principal.removeCallbacks(tique)
        if (isShown) principal.post(tique)
    }

    fun escolherAba(i: Int) {
        aba = i.coerceIn(0, ABAS.size - 1)
        pintarAbas()
        rolagem.scrollTo(0, 0)
        chaveDoCorpo = null
        atualizar()
    }

    private fun pintarAbas() {
        for (i in 0 until linhaDasAbas.childCount) {
            val t = linhaDasAbas.getChildAt(i) as TextView
            val sim = i == aba
            t.setTextColor(if (sim) Cores.ACENTO_CLARO else Cores.TEXTO2)
            t.background = fundoArredondado(if (sim) Cores.ACENTO_FUNDO else Cores.SUPERFICIE, dp(10).toFloat())
            t.isSelected = sim
            t.contentDescription = if (sim) s(R.string.cam_aba_escolhida, s(ABAS[i])) else s(ABAS[i])
        }
    }

    /** O tique: a leitura, o aviso, e o corpo (refeito só quando o que ele mostra muda de forma). */
    fun atualizar() {
        if (!isShown) return
        manterTelaLigada?.let {
            sincronizandoTela = true
            it.isChecked = TelaLigada.escolhida(context)
            sincronizandoTela = false
        }
        val c = fonteAgora()
        if (c == null) {
            mudarTexto(leituraTxt, s(R.string.cam_ainda_nao_abriu))
            mudarTexto(avisoTxt, "")
            restaurar.isEnabled = false
            restaurar.alpha = 0.4f
            meusAjustes.visibility = GONE
            if (chaveDoCorpo != listOf<Any?>("sem")) {
                chaveDoCorpo = listOf("sem")
                corpo.removeAllViews()
                atualizadores.clear()
            }
            return
        }
        restaurar.isEnabled = c.vivo
        restaurar.alpha = if (c.vivo) 1f else 0.4f
        meusAjustes.visibility = if (c.vivo && c.ofereceMeusAjustes) VISIBLE else GONE
        val textos = t
        val (linha, aviso) = c.leitura(textos)
        mudarTexto(leituraTxt, linha)
        mudarTexto(avisoTxt, aviso ?: "")
        val a = c.ajuste
        val oferta = c.oferta(textos)
        val chave = listOf(c, oferta, c.vivo, aba, a.exposicao, a.travaExposicao, a.antiCintilacao, a.balanco, a.travaBalanco, a.foco)
        if (chave != chaveDoCorpo) {
            chaveDoCorpo = chave
            montarCorpo(c, oferta)
        }
        if (!segurando) for (f in atualizadores) f(c)
    }

    /**
     * Só troca o texto que mudou: cada `setText` manda um evento de conteúdo à acessibilidade, e uma vista
     * que muda a cada 250 ms à toa não deixa o `uiautomator dump` achar a tela parada.
     */
    private fun mudarTexto(t: TextView, novo: String) {
        if (t.text.toString() != novo) t.text = novo
    }

    // --- as abas ------------------------------------------------------------------------------------

    private fun montarCorpo(c: FonteDoPainel, o: OfertaDoPainel) {
        corpo.removeAllViews()
        atualizadores.clear()
        when (aba) {
            0 -> abaExposicao(c, o)
            1 -> abaIsoEObturador(c, o)
            2 -> abaBalanco(c, o)
            else -> abaFoco(c, o)
        }
        // A câmera do outro lado que não permite controle remoto (R9b): os valores à vista, tudo apagado.
        if (!c.vivo) apagar(corpo)
    }

    /** Apaga [v] e tudo dentro dele: nada responde ao toque, e o que se vê fica a 40 %. */
    private fun apagar(v: View) {
        v.isEnabled = false
        v.isClickable = false
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) apagar(v.getChildAt(i))
        } else {
            v.alpha = minOf(v.alpha, 0.4f)
        }
    }

    /** Exposição: Auto/Manual (36) · EV (20 + 32 + 16) · Travar (40) · Anti-cintilação (18 + 36), com 3 vãos de 8 = 222 dp. */
    private fun abaExposicao(c: FonteDoPainel, o: OfertaDoPainel) {
        val a = c.ajuste
        corpo.addView(segmentado(listOf(s(R.string.cam_auto), s(R.string.cam_manual)), if (a.exposicao == Exposicao.AUTO) 0 else 1,
            habilitado = { i -> i == 0 || o.exposicaoManual }) { i ->
            if (i == 0) c.exposicaoAuto()
            else {
                c.passarParaManual()
                escolherAba(1)
            }
        }, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(36)))
        if (a.exposicao == Exposicao.MANUAL) {
            vao()
            linha(o.limiteDaAbaIsoEObturador ?: s(R.string.cam_iso_na_aba_ao_lado))
            return
        }
        vao()
        // O EV, só com Auto; apagado com a trava (§3.3).
        val evLivre = o.ev && !a.travaExposicao
        val evs = o.evs
        deslizanteComTitulo(o.tituloDoEv(t), (evs.size - 1).coerceAtLeast(0), evLivre,
            posicao = { k -> indiceMaisPertoLinear(evs, k.ajuste.ev) },
            valor = { i -> evs.getOrNull(i)?.let { o.textoDoEv(t, it) } ?: "" },
        ) { i -> evs.getOrNull(i)?.let { c.ev(it) } }
        linha(when {
            !o.ev -> o.limite(Controle.EV)
            a.travaExposicao -> EscalasDaCamera.evComTrava(t)
            else -> null
        } ?: "")
        vao()
        interruptor(s(R.string.cam_travar_exposicao), a.travaExposicao, o.limite(Controle.TRAVA_EXPOSICAO), o.travaExposicao) { c.travarExposicao(it) }
        vao()
        corpo.addView(texto(s(R.string.cam_anti_cintilacao), 13f, Cores.TEXTO, negrito = true), LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(18)))
        val limiteAnti = o.limite(Controle.ANTI_CINTILACAO)
        val opcoes = listOf(AjusteDaCamera.AntiCintilacao.AUTO, AjusteDaCamera.AntiCintilacao.HZ50,
            AjusteDaCamera.AntiCintilacao.HZ60, AjusteDaCamera.AntiCintilacao.DESLIGADA)
        corpo.addView(segmentado(listOf(s(R.string.cam_auto), "50 Hz", "60 Hz", s(R.string.cam_anti_desligada)), opcoes.indexOf(a.antiCintilacao),
            habilitado = { i -> limiteAnti == null && opcoes[i] in o.antiCintilacao }) { i ->
            c.antiCintilacao(opcoes[i])
        }, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(36)))
        limiteAnti?.let { linha(it) }
    }

    /** ISO e obturador: só com Manual. Com Auto, a frase e "Passar para Manual" (§4.3). */
    private fun abaIsoEObturador(c: FonteDoPainel, o: OfertaDoPainel) {
        val a = c.ajuste
        if (!o.exposicaoManual) (o.limiteDaAbaIsoEObturador ?: "").let {
            // Um grupo em que nada se aplica vira uma linha só (§3.5).
            linha(it)
            return
        }
        if (a.exposicao != Exposicao.MANUAL) {
            corpo.addView(texto(s(R.string.cam_passe_para_manual), 14f, Cores.TEXTO2))
            vao()
            corpo.addView(texto(s(R.string.cam_passar_para_manual), 15f, Cores.BRANCO, negrito = true).apply {
                gravity = Gravity.CENTER
                isClickable = true
                isFocusable = true
                background = fundoArredondado(Cores.ACENTO, dp(12).toFloat())
                setOnClickListener { c.passarParaManual() }
            }, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(44)))
            return
        }
        val isos = o.isos
        deslizanteComTitulo(o.tituloDoIso(t), (isos.size - 1).coerceAtLeast(0), isos.isNotEmpty(),
            posicao = { k -> if (isos.isEmpty()) 0 else indiceMaisPerto(isos.map { it.toDouble() }, (k.isoAplicado ?: k.ajuste.iso ?: isos.first()).toDouble()) },
            valor = { i ->
                isos.getOrNull(i)?.let { iso ->
                    o.textoDoIso(iso) + if (EscalasDaCamera.ganhoDigital(iso, o.isoAnalogicoMax)) " · ${EscalasDaCamera.marcaDoGanhoDigital(t)}" else ""
                } ?: ""
            },
        ) { i -> isos.getOrNull(i)?.let { c.iso(it) } }
        vao()
        val fracoes = o.fracoes
        val rede = EscalasDaCamera.redeDaSugestao(a.antiCintilacao, Locale.getDefault().country)
        val comPonto = EscalasDaCamera.fracoesSemCintilacao(rede)
        deslizanteComTitulo(s(R.string.cam_obturador), (fracoes.size - 1).coerceAtLeast(0), fracoes.isNotEmpty(),
            posicao = { k ->
                val ns = k.obturadorAplicadoNs ?: k.ajuste.obturadorNs ?: k.obturadorPadraoNs
                fracoes.indexOf(EscalasDaCamera.degrauMaisPerto(fracoes, ns)).coerceAtLeast(0)
            },
            valor = { i -> fracoes.getOrNull(i)?.let { n -> "1/$n s" + if (n in comPonto) " •" else "" } ?: "" },
        ) { i -> fracoes.getOrNull(i)?.let { n -> c.obturador(EscalasDaCamera.nsDaFracao(n)) } }
        // É legenda, não trava (§3.1).
        linha(rede?.let { "• " + EscalasDaCamera.legendaDaCintilacao(t, it) } ?: "")
    }

    /** Balanço: a grade 2 × 3 (§4.2), o Kelvin de 100 em 100, e "Travar balanço" só com Auto. */
    private fun abaBalanco(c: FonteDoPainel, o: OfertaDoPainel) {
        val a = c.ajuste
        val grade = listOf(Balanco.AUTO to s(R.string.cam_auto), Balanco.INCANDESCENTE to s(R.string.cam_balanco_incandescente),
            Balanco.FLUORESCENTE to s(R.string.cam_balanco_fluorescente), Balanco.LUZ_DO_DIA to s(R.string.cam_balanco_luz_do_dia),
            Balanco.NUBLADO to s(R.string.cam_balanco_nublado), Balanco.KELVIN to "Kelvin")
        for (linhaDaGrade in 0..1) {
            val l = LinearLayout(context).apply { orientation = HORIZONTAL }
            for (col in 0..2) {
                val (b, nome) = grade[linhaDaGrade * 3 + col]
                val pode = b in o.balancos
                l.addView(opcao(nome, a.balanco == b, pode) { c.balancear(b) },
                    LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply { if (col > 0) leftMargin = dp(6) })
            }
            corpo.addView(l, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(38)).apply { if (linhaDaGrade > 0) topMargin = dp(6) })
        }
        // O texto do §3.5 embaixo da grade, para o que estiver apagado.
        val limites = listOfNotNull(o.limite(Controle.PRESETS), o.limite(Controle.KELVIN)).distinct()
        if (limites.isNotEmpty()) linha(limites.joinToString(" "), linhas = 2)
        vao()
        when (a.balanco) {
            Balanco.KELVIN -> {
                val passo = o.kelvinPasso
                val passos = ((o.kelvinMax - o.kelvinMin) / passo).coerceAtLeast(0)
                deslizanteComTitulo(s(R.string.cam_temperatura), passos, o.kelvin,
                    posicao = { k -> ((k.ajuste.kelvin ?: 5500) - o.kelvinMin) / passo },
                    valor = { i -> EscalasDaCamera.textoDoKelvin(o.kelvinMin + i * passo) },
                ) { i -> c.kelvin(o.kelvinMin + i * passo) }
            }
            // "Com balanco = kelvin, a trava de balanço não se aplica. Ela some da tela." (§3.4); com preset também.
            Balanco.AUTO -> interruptor(s(R.string.cam_travar_balanco), a.travaBalanco, o.limite(Controle.TRAVA_BALANCO), o.travaBalanco) {
                c.travarBalanco(it)
            }
            else -> Unit
        }
    }

    /** Foco: Auto, Travado e Manual; "Perto ↔ Longe" de 0,01 em 0,01; a nota do toque. */
    private fun abaFoco(c: FonteDoPainel, o: OfertaDoPainel) {
        val a = c.ajuste
        if (o.focos.isEmpty()) {
            linha(o.limiteDoFoco ?: "")
            if (!o.toque) linha(o.limite(Controle.TOQUE) ?: "", linhas = 2)
            else linha(s(R.string.cam_nota_do_toque))
            return
        }
        val modos = listOf(Foco.AUTO, Foco.TRAVADO, Foco.MANUAL)
        corpo.addView(segmentado(listOf(s(R.string.cam_auto), s(R.string.cam_foco_travado), s(R.string.cam_manual)), modos.indexOf(a.foco),
            habilitado = { i -> modos[i] in o.focos }) { i -> c.focar(modos[i]) },
            LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(36)))
        o.limite(Controle.FOCO_MANUAL)?.let { linha(it, linhas = 2) }
        vao()
        if (a.foco == Foco.MANUAL && o.focoManual) {
            val dioptrias = o.dioptriasDoFoco
            // A escala vai de Perto (à esquerda, focoPosicao 1) a Longe (à direita, 0).
            deslizanteComTitulo(s(R.string.cam_perto_longe), 100, true,
                posicao = { k -> 100 - Math.round((k.ajuste.focoPosicao ?: 0.0) * 100).toInt() },
                valor = { i ->
                    if (dioptrias != null) EscalasDaCamera.textoDoFocoEmMetros(t, EscalasDaCamera.dioptriasDoFoco((100 - i) / 100.0, dioptrias))
                    else ""
                },
            ) { i -> c.focoPosicao(EscalasDaCamera.cortarFoco((100 - i) / 100.0)) }
            vao()
        }
        if (o.toque) linha(s(R.string.cam_nota_do_toque)) else linha(o.limite(Controle.TOQUE) ?: "", linhas = 2)
    }

    // --- as peças -----------------------------------------------------------------------------------

    private fun texto(t: String, dpTam: Float, cor: Int, negrito: Boolean = false) = TextView(context).apply {
        text = t
        setTextColor(cor)
        // Tamanho fixo, sem a escala de fonte do sistema: o espaço do painel é contado (§4.2).
        setTextSize(TypedValue.COMPLEX_UNIT_DIP, dpTam)
        if (negrito) setTypeface(typeface, Typeface.BOLD)
        includeFontPadding = false
    }

    private fun vao() = corpo.addView(View(context), LayoutParams(1, dp(8)))

    /** Uma linha de legenda (16 dp; 30 com duas linhas): o limite do §3.5, a nota, a legenda. */
    private fun linha(t: String, linhas: Int = 1) {
        corpo.addView(texto(t, 12f, Cores.TEXTO3).apply {
            maxLines = linhas
            ellipsize = TextUtils.TruncateAt.END
            gravity = Gravity.CENTER_VERTICAL
        }, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(if (linhas > 1) 30 else 16)))
    }

    private fun opcao(nome: String, escolhida: Boolean, habilitada: Boolean, acao: () -> Unit) = texto(nome, 13f,
        if (escolhida) Cores.ACENTO_CLARO else Cores.TEXTO, negrito = escolhida).apply {
        gravity = Gravity.CENTER
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        background = fundoArredondado(if (escolhida) Cores.ACENTO_FUNDO else Cores.SUPERFICIE, dp(10).toFloat())
        isEnabled = habilitada
        alpha = if (habilitada) 1f else 0.4f
        isClickable = habilitada
        isSelected = escolhida
        contentDescription = if (escolhida) s(R.string.cam_opcao_escolhida, nome) else nome
        if (habilitada) setOnClickListener { acao() }
    }

    /** O segmentado (§4): as opções lado a lado, a escolhida em `acentoFundo`. */
    private fun segmentado(nomes: List<String>, escolhida: Int, habilitado: (Int) -> Boolean, acao: (Int) -> Unit): View {
        val l = LinearLayout(context).apply { orientation = HORIZONTAL }
        nomes.forEachIndexed { i, n ->
            l.addView(opcao(n, i == escolhida, habilitado(i)) { if (i != escolhida) acao(i) },
                LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply { if (i > 0) leftMargin = dp(4) })
        }
        return l
    }

    /** "Título ……… valor" (20 dp) e o deslizante por degrau embaixo (32 dp). */
    private fun deslizanteComTitulo(
        titulo: String, maximo: Int, habilitado: Boolean,
        posicao: (FonteDoPainel) -> Int, valor: (Int) -> String, definir: (Int) -> Unit,
    ) {
        val cab = LinearLayout(context).apply { orientation = HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        cab.addView(texto(titulo, 13f, Cores.TEXTO, negrito = true), LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val v = texto("", 13f, Cores.TEXTO2).apply { typeface = Typeface.MONOSPACE }
        cab.addView(v)
        corpo.addView(cab, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(20)))
        val s = SeekBar(context).apply {
            max = maximo.coerceAtLeast(0)
            isEnabled = habilitado
            alpha = if (habilitado) 1f else 0.4f
            progressTintList = ColorStateList.valueOf(Cores.ACENTO)
            thumbTintList = ColorStateList.valueOf(Cores.ACENTO)
            contentDescription = titulo
        }
        s.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(b: SeekBar, p: Int, doUsuario: Boolean) {
                v.text = valor(p)
                // O último valor vence; os envios à câmera são agrupados a 15 por segundo (§2.2).
                if (doUsuario) definir(p)
            }
            override fun onStartTrackingTouch(b: SeekBar) { segurando = true }
            override fun onStopTrackingTouch(b: SeekBar) { segurando = false; definir(b.progress) }
        })
        corpo.addView(s, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(32)))
        atualizadores += { k ->
            val p = posicao(k).coerceIn(0, s.max)
            if (s.progress != p) s.progress = p
            mudarTexto(v, valor(s.progress))
        }
    }

    /**
     * O interruptor (40 dp), e embaixo o limite do §3.5 quando a câmera não oferece. [oferecido] falso apaga
     * mesmo sem frase (a câmera do outro lado que não disse por quê).
     */
    private fun interruptor(titulo: String, ligado: Boolean, limite: String?, oferecido: Boolean = limite == null, mudar: (Boolean) -> Unit) {
        val l = LinearLayout(context).apply { orientation = HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        l.addView(texto(titulo, 14f, Cores.TEXTO, negrito = true), LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val s = SwitchMaterial(context).apply {
            isChecked = ligado
            isEnabled = limite == null && oferecido
            contentDescription = titulo
            thumbTintList = ColorStateList.valueOf(if (ligado) Cores.ACENTO_CLARO else Cores.TEXTO2)
            trackTintList = ColorStateList.valueOf(if (ligado) Cores.ACENTO else Cores.SUPERFICIE_ALTA)
            setOnCheckedChangeListener { _, v -> mudar(v) }
        }
        l.addView(s)
        l.alpha = if (limite == null && oferecido) 1f else 0.4f
        corpo.addView(l, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(40)))
        limite?.let { linha(it, linhas = 2) }
    }

    private fun indiceMaisPerto(escala: List<Double>, v: Double): Int =
        escala.indices.minByOrNull { Math.abs(Math.log(escala[it] / v.coerceAtLeast(1e-9))) } ?: 0

    /** O degrau mais perto numa escala linear (o EV, o brilho). */
    private fun indiceMaisPertoLinear(escala: List<Double>, v: Double): Int =
        escala.indices.minByOrNull { Math.abs(escala[it] - v) } ?: 0
}

/**
 * **As medidas fixas do painel**, puras para o teste: o que fica sempre à vista no alto (a linha da
 * leitura com o "Pronto", e as abas) e quanto sobra para o corpo, que rola quando não cabe. Com
 * qualquer altura de pelo menos [ALTURA_MINIMA_DP], o cromo fixo cabe e sobra corpo: as abas e o
 * "Pronto" nunca saem da vista por falta de altura (o `LinearLayout` não encolhe filho de altura fixa,
 * e eles são os primeiros).
 */
object MedidasDoPainel {
    const val RECUO_VERTICAL_DP = 6
    const val ALTO_DP = 36
    const val ABAS_DP = 40
    const val MARGEM_DAS_ABAS_DP = 4

    /** O cromo fixo do alto, com os dois recuos: 92 dp. */
    const val CROMO_FIXO_DP = 2 * RECUO_VERTICAL_DP + ALTO_DP + MARGEM_DAS_ABAS_DP + ABAS_DP

    /** A menor altura em que o painel ainda é usável (a R5 no celular deitado tem ~206 dp). */
    const val ALTURA_MINIMA_DP = 150

    /** A altura da rolagem do corpo num painel de [alturaDp]. */
    fun corpoDp(alturaDp: Int): Int = (alturaDp - CROMO_FIXO_DP).coerceAtLeast(0)
}

/**
 * **O toque na prévia** (§4.4): um quadrado de 64 dp por 1,5 s onde o dedo tocou, e a pílula do toque
 * longo ("Exposição e foco travados") no alto, enquanto a trava dele valer. Uma vista transparente por
 * cima da prévia, que não recebe toque.
 */
class MarcasDoToque(contexto: Context) : FrameLayout(contexto) {
    private val principal = Handler(Looper.getMainLooper())
    private val tinta = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = context.dp(2).toFloat()
        color = Cores.AGUARDANDO
    }
    private var quadrado: Pair<Float, Float>? = null
    private val pilula = TextView(contexto).apply {
        setTextColor(Cores.BRANCO)
        setTextSize(TypedValue.COMPLEX_UNIT_DIP, 12f)
        setTypeface(typeface, Typeface.BOLD)
        setPadding(context.dp(12), context.dp(5), context.dp(12), context.dp(5))
        background = fundoArredondado(Cores.comAlfa(0xFF000000.toInt(), 0.85f), context.dp(14).toFloat())
        // A da pouca luz é uma frase inteira: quebra em duas linhas em vez de cruzar a prévia.
        maxWidth = context.dp(440)
        gravity = Gravity.CENTER
        visibility = GONE
    }

    /** De onde vem a pílula (os controles do dono); lida a cada 250 ms enquanto a vista está na janela. */
    var fonteDaPilula: (() -> String?)? = null

    companion object {
        /**
         * A pílula da câmera do dono da tela [daTelaR5]: **"Controlado por <aparelho>"** enquanto um pedido
         * remoto acabou de ser aplicado (R9b, contrato §6: `controlado_por`, por 4 s), e senão a do toque
         * longo (§4.4), e senão a da pouca luz (§3.1), se [comPoucaLuz]. Sem dono aberto, nenhuma.
         */
        fun pilulaDaCamera(contexto: Context, daTelaR5: Boolean, comPoucaLuz: Boolean = true): String? {
            val c = MirrorService.controlesDaCamera(daTelaR5) ?: return null
            com.quall.android.capture.FilmadorDaCamera.controladoPor()?.let {
                return contexto.getString(R.string.cam_controlado_por, it)
            }
            return c.pilula ?: c.poucaLuz().takeIf { comPoucaLuz }
        }
    }

    private val tique = object : Runnable {
        override fun run() {
            mostrarPilula(fonteDaPilula?.invoke())
            postDelayed(this, RegrasDosControles.INTERVALO_DA_LEITURA_MS)
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        removeCallbacks(tique)
        post(tique)
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(tique)
        super.onDetachedFromWindow()
    }

    init {
        setWillNotDraw(false)
        isClickable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        addView(pilula, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = context.dp(12) })
    }

    /**
     * Na tela da câmera, a vista cobre a tela inteira: a pílula desce para baixo da barra de status e da
     * linha do alto (status, câmera e engrenagem). Sem isto, a da pouca luz, de duas linhas, caía entre o
     * relógio e o Wi-Fi e depois sobre o nome da câmera (tablet, 06/10). Na R5 a vista é a moldura da
     * prévia, e a pílula fica onde sempre esteve.
     */
    fun ficarAbaixoDaLinhaDoAlto() {
        androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val topo = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.systemBars() or
                androidx.core.view.WindowInsetsCompat.Type.displayCutout()).top
            (pilula.layoutParams as LayoutParams).topMargin = context.dp(64) + topo
            pilula.requestLayout()
            insets
        }
        androidx.core.view.ViewCompat.requestApplyInsets(this)
    }

    /** O quadrado em ([x], [y]) desta vista, por 1,5 s. */
    fun mostrarQuadrado(x: Float, y: Float) {
        quadrado = x to y
        invalidate()
        principal.removeCallbacksAndMessages(null)
        principal.postDelayed({ quadrado = null; invalidate() }, 1_500)
    }

    fun mostrarPilula(texto: String?) {
        if (texto == null) {
            pilula.visibility = GONE
            return
        }
        if (pilula.text != texto) {
            pilula.text = texto
            pilula.contentDescription = texto
        }
        pilula.visibility = VISIBLE
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val (x, y) = quadrado ?: return
        val m = context.dp(32).toFloat()
        canvas.drawRect(x - m, y - m, x + m, y + m, tinta)
    }
}

/**
 * Os gestos da prévia para o R9 (§4.4): o toque simples e o longo, entregues ao serviço com o ponto
 * em pixels da `SurfaceView` da prévia. [ondeEsta] devolve a prévia, ou `null` quando o toque não vale
 * (a prévia escondida, a R5 com "Toque para mostrar" por cima).
 */
class GestosDaPrevia(
    contexto: Context,
    private val daTelaR5: Boolean,
    private val ondeEsta: () -> View?,
    private val marcas: () -> MarcasDoToque?,
) {
    private val detector = GestureDetector(contexto, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean = true
        override fun onSingleTapUp(e: MotionEvent): Boolean = tocar(e, longo = false)
        override fun onLongPress(e: MotionEvent) {
            tocar(e, longo = true)
        }
    })

    /** Para o `OnTouchListener`: não consome, para a rolagem continuar funcionando. */
    fun observar(e: MotionEvent) {
        detector.onTouchEvent(e)
    }

    private fun tocar(e: MotionEvent, longo: Boolean): Boolean {
        val previa = ondeEsta() ?: return false
        val onde = IntArray(2)
        previa.getLocationOnScreen(onde)
        val x = e.rawX - onde[0]
        val y = e.rawY - onde[1]
        if (x < 0 || y < 0 || x > previa.width || y > previa.height) return false
        val mediu = MirrorService.tocarNaPrevia(daTelaR5, x, y, previa.width, previa.height, longo)
        if (mediu) {
            marcas()?.let { m ->
                val om = IntArray(2)
                m.getLocationOnScreen(om)
                m.mostrarQuadrado(e.rawX - om[0], e.rawY - om[1])
            }
        }
        return mediu
    }
}
