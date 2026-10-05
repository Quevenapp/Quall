package com.quall.android.ui

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.LayoutInflater
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.Toast
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.quall.android.R
import com.quall.android.core.DeviceIdentity
import com.quall.android.core.Idioma
import com.quall.android.core.QuallNative
import com.quall.android.core.Resolucao
import com.quall.android.core.SeletorDeResolucao
import com.quall.android.databinding.FolhaDeAjustesBinding
import com.quall.android.mirror.MirrorBus
import com.quall.android.receive.ReceptorBus
import com.quall.android.teleprompter.Replicas

/**
 * **A folha de Ajustes** (`docs/telas-estudio.md` §6.3), a mesma nas três engrenagens (Início, Espelhar,
 * Exibir): "Ajustes" e "Pronto"; QUALIDADE DO ESPELHAMENTO (os dois cardápios e a nota de custo, que
 * saíram de Espelhar), PAREAMENTO ("Aparelhos pareados" com a contagem e "Esquecer aparelhos pareados",
 * com confirmação) e SOBRE (este aparelho, o nome na lista, a versão, o núcleo e "Licenças de terceiros").
 *
 * Criada **uma vez só** no `onCreate` de quem a abre (§11.3): a vista vive com a tela, e o
 * `BottomSheetDialog` só a mostra. Os cardápios de qualidade continuam como eram em Espelhar — um
 * `RadioButton` por linha, a escolha gravada por [Resolucao], a nota com o número que o **núcleo** dá
 * para aquela linha neste binário —, só em outro lugar.
 */
class FolhaDeAjustes(private val activity: Activity, private val eu: DeviceIdentity) {
    private val c = ContextThemeWrapper(activity, R.style.Theme_Quall_Folha)
    val b: FolhaDeAjustesBinding = FolhaDeAjustesBinding.inflate(LayoutInflater.from(c))
    private var folha: BottomSheetDialog? = null

    /** A qualidade escolhida mudou (o chip de Espelhar acompanha). */
    var aoMudarAQualidade: (() -> Unit)? = null

    /** Marcando os botões pelo salvo: os ouvintes não gravam de novo. */
    private var sincronizando = false

    /** O último estado do cardápio pela fonte ([aplicarCardapio]); ativo até a tela dizer o contrário. */
    private var cardapio = SeletorDeResolucao.estado(false)

    init {
        b.buttonProntoAjustes.setOnClickListener { folha?.dismiss() }
        b.linhaLicencas.setOnClickListener { LicencasDeTerceiros.mostrar(activity) }
        b.linhaPrivacidade.setOnClickListener { abrirSite("quall/privacidade/", "en/quall/privacy/") }
        b.linhaSuporte.setOnClickListener { abrirSite("quall/suporte/", "en/quall/support/") }
        b.linhaEsquecerPares.setOnClickListener { confirmarEsquecer() }
        b.textEsteAparelho.text = "${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE}" // i18n-fora: marca, modelo e versão do sistema
        b.textNomeNaLista.text = eu.displayName
        b.textVersao.text = runCatching {
            activity.packageManager.getPackageInfo(activity.packageName, 0).versionName
        }.getOrNull().orEmpty().ifEmpty { "—" }
        b.textNucleo.text = if (QuallNative.carregado) {
            "v${QuallNative.protocolVersion()} · ${Build.SUPPORTED_ABIS.firstOrNull().orEmpty()}"
        } else {
            activity.getString(R.string.in_nucleo_nao_carregou_curto)
        }
        popularResolucoes()
        b.switchManterTelaLigada.isChecked = TelaLigada.escolhida(activity)
        b.switchManterTelaLigada.setOnCheckedChangeListener { _, sim ->
            if (!sincronizando) TelaLigada.escolher(activity, sim)
        }
        // "Permitir controle remoto da câmera" (R9b, `docs/controle-remoto-da-camera.md`): desligada por
        // padrão, do app inteiro (a câmera comum e a R5; a folha da R5 tem a mesma opção, na mesma
        // preferência). Aqui porque é a folha das três engrenagens; o painel da câmera tem altura contada.
        b.switchControleRemoto.isChecked = com.quall.android.capture.FilmadorDaCamera.permitido(activity)
        b.switchControleRemoto.setOnCheckedChangeListener { _, sim ->
            if (sincronizando) return@setOnCheckedChangeListener
            com.quall.android.capture.FilmadorDaCamera.permitir(activity, sim)
        }
    }

    val aberta: Boolean get() = folha?.isShowing == true

    private fun abrirSite(pt: String, en: String) {
        val caminho = if (Idioma.codigo(activity) == Idioma.PT) pt else en
        try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://queven.com.br/$caminho")))
        } catch (erro: ActivityNotFoundException) {
            com.quall.android.core.LogSeguro.e("QuallAjustes", "Navegador indisponível", erro) // i18n-fora: diário técnico; o Toast usa site_nao_abriu em recursos PT/EN
            Toast.makeText(activity, R.string.site_nao_abriu, Toast.LENGTH_LONG).show()
        } catch (erro: SecurityException) {
            com.quall.android.core.LogSeguro.e("QuallAjustes", "Abertura do navegador recusada", erro)
            Toast.makeText(activity, R.string.site_nao_abriu, Toast.LENGTH_LONG).show()
        }
    }

    fun mostrar() {
        if (aberta) return
        // A outra folha (a do Exibir, a do Início) pode ter mudado a escolha: os botões seguem o salvo.
        sincronizarCardapio()
        desenharPares()
        (b.root.parent as? ViewGroup)?.removeView(b.root)
        val f = BottomSheetDialog(activity, R.style.Theme_Quall_Folha)
        f.setContentView(b.root)
        // No tablet, no máximo 600 dp de largura (no celular, a largura da tela, também deitado).
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

    // --- a qualidade (o cardápio que morava em Espelhar) ------------------------------------------

    /**
     * Um `RadioButton` com a cara do segmentado: sem bolinha, o texto no meio, e o escolhido em
     * destaque. A lógica é a do `RadioGroup` (um só marcado).
     */
    private fun segmento(rb: RadioButton) {
        rb.buttonDrawable = null
        rb.setBackgroundResource(R.drawable.segmento)
        rb.gravity = Gravity.CENTER
        rb.minHeight = c.dp(34)
        rb.textSize = 13f
        rb.typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
        rb.setTextColor(androidx.appcompat.content.res.AppCompatResources.getColorStateList(c, R.color.segmento_texto))
    }

    /**
     * Uma linha do cardápio por `RadioButton`, e **a nota que diz o custo**: a promessa do produto é
     * *combinação testada*, e não *capacidade abstrata* (`docs/fluxo-de-uso.md`) — oferecer a linha sem
     * dizer o preço é oferecer em silêncio. A escolha é gravada em [Resolucao]; o número vem do núcleo.
     */
    private fun popularResolucoes() {
        val escolhida = Resolucao.escolhida(activity)
        for (r in Resolucao.entries) {
            val rb = RadioButton(c).apply {
                id = View.generateViewId()
                text = r.rotulo
                tag = r
                isChecked = r == escolhida
                layoutParams = RadioGroup.LayoutParams(0, RadioGroup.LayoutParams.WRAP_CONTENT, 1f)
            }
            segmento(rb)
            b.radioGroupResolucao.addView(rb)
        }
        b.radioGroupResolucao.setOnCheckedChangeListener { grupo, id ->
            if (sincronizando) return@setOnCheckedChangeListener
            val r = grupo.findViewById<View>(id)?.tag as? Resolucao ?: return@setOnCheckedChangeListener
            Resolucao.escolher(activity, r)
            desenharCustoDaResolucao(r)
            aoMudarAQualidade?.invoke()
        }

        // A taxa de quadros é o segundo eixo, e fica junto porque a pessoa pensa nos dois juntos —
        // "4K a 60" é uma frase só. No núcleo eles viajam no mesmo `Alvo`.
        val fpsAtual = Resolucao.quadros(activity)
        for (fps in Resolucao.TAXAS) {
            val rb = RadioButton(c).apply {
                id = View.generateViewId()
                text = "$fps fps"
                tag = fps
                isChecked = fps == fpsAtual
                layoutParams = RadioGroup.LayoutParams(0, RadioGroup.LayoutParams.WRAP_CONTENT, 1f)
            }
            segmento(rb)
            b.radioGroupQuadros.addView(rb)
        }
        b.radioGroupQuadros.setOnCheckedChangeListener { grupo, id ->
            if (sincronizando) return@setOnCheckedChangeListener
            val fps = grupo.findViewById<View>(id)?.tag as? Int ?: return@setOnCheckedChangeListener
            Resolucao.escolherQuadros(activity, fps)
            desenharCustoDaResolucao(Resolucao.escolhida(activity))
            aoMudarAQualidade?.invoke()
        }
        desenharCustoDaResolucao(escolhida)
    }

    /**
     * O estado do cardápio pela fonte escolhida ([SeletorDeResolucao]): com o vídeo USB ele fica
     * desativado e a nota diz quem define o tamanho. Só `isEnabled` muda: nenhum botão é marcado nem
     * desmarcado, então os ouvintes não disparam e a escolha salva fica como estava.
     */
    fun aplicarCardapio(e: SeletorDeResolucao.Estado) {
        cardapio = e
        for (g in listOf(b.radioGroupResolucao, b.radioGroupQuadros)) {
            g.isEnabled = e.ativo
            for (i in 0 until g.childCount) g.getChildAt(i).isEnabled = e.ativo
        }
        if (e.nota != null) b.textResolucaoNota.text = activity.getString(e.nota)
        else desenharCustoDaResolucao(Resolucao.escolhida(activity))
    }

    /**
     * Os botões marcados pelo salvo ([Resolucao]), sem gravar de novo: as duas folhas (a da tela inicial
     * e a do Exibir) são vistas separadas, e a escolha feita numa não aparecia na outra.
     */
    private fun sincronizarCardapio() {
        val escolhida = Resolucao.escolhida(activity)
        val fps = Resolucao.quadros(activity)
        sincronizando = true
        try {
            b.switchManterTelaLigada.isChecked = TelaLigada.escolhida(activity)
            // A outra folha (ou a da R5) pode ter mudado a opção do controle remoto.
            b.switchControleRemoto.isChecked = com.quall.android.capture.FilmadorDaCamera.permitido(activity)
            for (g in listOf(b.radioGroupResolucao, b.radioGroupQuadros)) {
                for (i in 0 until g.childCount) {
                    val rb = g.getChildAt(i) as? RadioButton ?: continue
                    if ((rb.tag == escolhida || rb.tag == fps) && !rb.isChecked) g.check(rb.id)
                }
            }
        } finally {
            sincronizando = false
        }
        aplicarCardapio(cardapio)
    }

    /** A frase de custo, com o número que o **núcleo** dá para esta linha neste binário. */
    private fun desenharCustoDaResolucao(r: Resolucao) {
        // O alvo entra aqui pela mesma razão do `MirrorService`: sem ele, esta nota mostraria a taxa de
        // 1080p para as quatro linhas — a nota de custo mentindo sobre o custo. Sem o núcleo carregado a
        // chamada nativa não existe: sem nota, e a tela abre (o Aviso vermelho do Início diz o porquê).
        val fps = Resolucao.quadros(activity)
        val bps = if (!QuallNative.carregado) 0 else {
            runCatching { QuallNative.tetoDeTaxaBps(r.pedido.width, r.pedido.height, fps, r.maxFs) }.getOrDefault(0)
        }
        if (bps <= 0) {
            b.textResolucaoNota.text = ""
            return
        }
        val mbps = String.format(activity.resources.configuration.locales[0], "%.0f", bps / 1_000_000.0)
        // O limiar é o joelho agregado do rádio da bancada (§8.10, 32–47 Mbps). Acima dele a frase muda
        // de tom, porque aí o transporte deixa de ser detalhe.
        val chave = if (bps >= 30_000_000) R.string.resolucao_custo_alto else R.string.resolucao_custo
        b.textResolucaoNota.text = activity.getString(chave, activity.getString(R.string.esp_ent_pedido, r.rotulo, fps), mbps)
    }

    // --- o pareamento ------------------------------------------------------------------------------

    /** Quantos pares o salvo tem (`{"pares": {"<device_id>": {...}}}`, `pairing.rs`). */
    private fun quantosPares(): Int = eu.idsPareados().size

    private fun desenharPares() {
        val n = quantosPares()
        b.textParesContagem.text = if (n == 0) activity.getString(R.string.in_nenhum) else n.toString()
        b.linhaEsquecerPares.isEnabled = n > 0
        b.textEsquecerPares.alpha = if (n > 0) 1f else 0.4f
    }

    /**
     * "Esquecer aparelhos pareados", com confirmação. **Só sem sessão no ar**: `forgetPeers` apaga a
     * preferência, e uma sessão viva gravaria os pares de novo ao terminar
     * (`docs/telas-android-como-ios.md` §1.3, item 10) — o esquecer sairia em silêncio sem efeito.
     */
    private fun confirmarEsquecer() {
        // Qualquer sessão de pé grava os pares ao terminar: o espelhamento (e a R5 e o DVD, que passam pelo
        // mesmo serviço), o exibir, e as telas do teleprompter (a réplica em uso).
        val espelhando = MirrorBus.atual.fase.let { it == MirrorBus.Fase.ESPERANDO || it == MirrorBus.Fase.ESPELHANDO }
        val exibindo = ReceptorBus.atual.fase.let {
            it == ReceptorBus.Fase.PROCURANDO || it == ReceptorBus.Fase.CONECTANDO || it == ReceptorBus.Fase.EXIBINDO
        }
        if (espelhando || exibindo || Replicas.emUso) {
            Toast.makeText(activity, activity.getString(R.string.in_esquecer_com_sessao), Toast.LENGTH_LONG).show()
            return
        }
        MaterialAlertDialogBuilder(activity)
            .setTitle(R.string.in_esquecer_titulo)
            .setMessage(R.string.in_esquecer_mensagem)
            .setNegativeButton(R.string.cancelar, null)
            .setPositiveButton(R.string.in_esquecer) { _, _ ->
                eu.forgetPeers()
                desenharPares()
            }
            .show()
    }
}
