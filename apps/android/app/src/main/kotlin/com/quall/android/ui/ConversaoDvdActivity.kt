package com.quall.android.ui

import com.quall.android.capturaUsbPossivel

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import com.quall.android.core.LogSeguro as Log
import android.util.TypedValue
import android.view.View
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.databinding.ActivityConversaoDvdBinding
import com.quall.android.dvd.ConversaoDvdBus
import com.quall.android.dvd.ConversaoDvdService
import com.quall.android.dvd.DiscoDvd
import com.quall.android.dvd.FaixaDeSom
import com.quall.android.dvd.Frase
import com.quall.android.dvd.FrasesDoDvd
import com.quall.android.dvd.LeitorDeDisco
import com.quall.android.dvd.LeitorParou
import com.quall.android.dvd.RecusaDoDisco
import com.quall.android.dvd.SessaoDoDvd
import com.quall.android.dvd.AssistirAqui
import com.quall.android.dvd.PreviaDoDvd
import com.quall.android.dvd.TituloDoDvd
import com.quall.android.dvd.TransmissaoDvdBus
import com.quall.android.mirror.MirrorBus
import com.quall.android.mirror.MirrorService
import kotlin.concurrent.thread

/**
 * **"Converter DVD"** (`docs/dvd-para-mp4.md` §2.1, a D4; o cartão na tela inicial, §2.9): o leitor
 * encontrado ou não (e o carregador no hub quando ele não aparece), a permissão USB, o disco (o
 * volume, os títulos com a duração, o aspecto, o sistema e as faixas de som; o mais longo marcado),
 * o Converter, e o progresso com o tempo que falta e o Cancelar. As recusas com as frases do §2.1.
 *
 * A conversão é do [ConversaoDvdService]: a tela pode fechar no meio, e ao voltar mostra o
 * progresso pelo [ConversaoDvdBus]. O leitor aberto aqui vai para o serviço no Converter
 * ([SessaoDoDvd]); saindo sem converter, a tela o fecha.
 *
 * **Transmitir** (§9, a T3): o mesmo leitor vai ao [MirrorService] com o DVD como fonte; a tela mostra
 * o PIN e o endereço (como o Espelhar), para quem vai, o tempo do título, Pausar, −30 s, +30 s e
 * Parar, pelo `MirrorBus` e pelo [TransmissaoDvdBus]. Converter e Transmitir não rodam juntos: o
 * leitor é um só.
 *
 * **O "Estúdio de bolso" e o R16 (30/09, decisão do Pessoa Exemplo)**: o cabeçalho voltar · título · engrenagem,
 * a pílula de estado (AGUARDANDO, ABRINDO lendo o disco, CONECTADO com o disco, CONVERTENDO, NO AR) com a
 * linha do leitor, os avisos, os botões e o letreiro do PIN das peças, e tudo cabendo sem rolar em pé e
 * deitado (duas colunas). Os títulos moram numa caixa com teto (rolam dentro dela); o som da transmissão
 * virou um chip; as notas do pé foram para a engrenagem ([FolhaDaTela]). **O comportamento não mudou**:
 * sem receptor o filme espera; o som do disco vai na trilha do sistema.
 *
 * **A vitrine** ([EstadoDasTelas.dvdDaVitrine], só o APK de depuração escreve): um leitor de mentira para
 * os retratos sem o leitor plugado — a tela não toca no USB nem na sessão do disco, a prévia mostra barras
 * de cor e os botões não sobem serviço nenhum.
 */
class ConversaoDvdActivity : AppCompatActivity() {
    private lateinit var b: ActivityConversaoDvdBinding
    private var receptorUsb: BroadcastReceiver? = null
    private var receptorDaPermissao: BroadcastReceiver? = null
    private var discoMostrado: DiscoDvd? = null
    private var estavaNoAr = false
    private var estavaTransmitindo = false

    /** O leitor é de um serviço (a conversão ou a transmissão): a tela não lê nem procura. */
    private val ocupado: Boolean get() = ConversaoDvdBus.convertendo || TransmissaoDvdBus.transmitindo

    /**
     * O leitor de mentira da vitrine de bancada (só o APK de depuração o escreve); `null` no produto. Lido
     * uma vez só, por esta tela: a próxima, aberta pelo Início, é a de verdade (a revisão, 30/09).
     */
    private val vitrine: VitrineDoDvd? = EstadoDasTelas.dvdDaVitrine.also { EstadoDasTelas.dvdDaVitrine = null }

    /** A faixa de som escolhida para a transmissão e o Assistir aqui (a primeira por padrão). */
    private var faixaEscolhida = 0

    /** O que o "ler de novo" da linha do leitor faz agora (o botão redondo ao lado da pílula). */
    private var acaoDaLinha: (() -> Unit)? = null

    /** A engrenagem: as notas que moravam no pé da tela (o R16). */
    private lateinit var ajustes: FolhaDaTela
    private lateinit var telaLigada: TelaLigada

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Abaixo do Android 11 a tela nem abre (`capturaUsbPossivel`): o ladrilho já some na principal.
        if (!capturaUsbPossivel) { finish(); return }
        setTitle(R.string.dvd_titulo_da_tela)
        b = ActivityConversaoDvdBinding.inflate(layoutInflater)
        setContentView(b.root)
        telaLigada = TelaLigada(this) {
            (TransmissaoDvdBus.transmitindo && !TransmissaoDvdBus.estado.local) || TransmissaoDvdBus.estado.gravando
        }
        ViewCompat.setOnApplyWindowInsetsListener(b.root) { v, insets ->
            val r = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            v.setPadding(r.left, r.top, r.right, r.bottom)
            insets
        }
        ajustes = FolhaDaTela(this).apply { aoMontar = { montarAjustes(it) } }
        b.dvdVoltar.setOnClickListener { finish() }
        b.dvdAjustes.setOnClickListener { ajustes.mostrar() }
        b.dvdLerDeNovo.setOnClickListener { if (!naVitrine()) acaoDaLinha?.invoke() }
        b.dvdFaixas.setOnClickListener { escolherFaixa() }
        b.dvdConverter.setOnClickListener { if (!naVitrine()) converter() }
        b.dvdCancelar.setOnClickListener { if (!naVitrine()) ConversaoDvdService.parar(this) }
        b.dvdTransmitir.setOnClickListener { if (!naVitrine()) transmitir() }
        b.dvdTitulos.setOnCheckedChangeListener { _, _ -> mostrarFaixas() }
        b.dvdTxPausar.setOnClickListener {
            if (naVitrine()) return@setOnClickListener
            val t = TransmissaoDvdBus.controle ?: return@setOnClickListener
            val e = TransmissaoDvdBus.estado
            // No fim do título o botão diz "Do começo": um toque recomeça (a revisão, 7), e não pausa.
            t.pausar(if (e.fimDoTitulo) false else !e.pausado)
        }
        b.dvdTxVoltar30.setOnClickListener { if (!naVitrine()) TransmissaoDvdBus.controle?.pular(-30 * 90_000L) }
        b.dvdTxAvancar30.setOnClickListener { if (!naVitrine()) TransmissaoDvdBus.controle?.pular(30 * 90_000L) }
        b.dvdTxGravar.setOnClickListener {
            if (naVitrine()) return@setOnClickListener
            val t = TransmissaoDvdBus.controle ?: return@setOnClickListener
            b.dvdTxGravar.isEnabled = false
            t.gravar(!TransmissaoDvdBus.estado.gravando)
        }
        b.dvdTxParar.setOnClickListener {
            if (naVitrine()) return@setOnClickListener
            b.dvdTxParar.isEnabled = false
            if (TransmissaoDvdBus.estado.local) AssistirAqui.parar() else MirrorService.pedirParada(null)
        }
        // A prévia e o Ouvir (o pedido do Pessoa Exemplo, 29/09): ver e ouvir no próprio aparelho. Na vitrine, as
        // barras de cor (não há disco).
        b.dvdTxPrevia.holder.addCallback(if (vitrine != null) QuadroDeExemplo(854, 480) else PreviaDoDvd)
        b.dvdAssistir.setOnClickListener { if (!naVitrine()) assistir() }
        b.dvdTxOuvir.setOnClickListener {
            if (naVitrine()) return@setOnClickListener
            val t = TransmissaoDvdBus.controle ?: return@setOnClickListener
            val ligar = !TransmissaoDvdBus.estado.ouvindo
            thread(name = "quall-dvd-ouvir-botao") { t.ouvir(ligar) }
        }
        b.dvdTxTransmitirDaqui.setOnClickListener { if (!naVitrine()) transmitirDaqui() }
        aplicarOrientacao()
    }

    override fun onConfigurationChanged(novaConfiguracao: Configuration) {
        super.onConfigurationChanged(novaConfiguracao)
        aplicarOrientacao()
        // O "também: …" depende de estar deitado, e a transmissão parada (sem receptor) não publica nada.
        if (TransmissaoDvdBus.transmitindo) desenharTransmissao()
    }

    /**
     * Deitado num celular, a tela é baixa (R16): os títulos com teto de duas linhas, e o PIN em linha
     * (mono, sem casas) ao lado do endereço. Em pé, e no tablet, três linhas e o letreiro de casas. As
     * colunas (`ColunasDaTela`) decidem sozinhas pela configuração.
     */
    private fun aplicarOrientacao() {
        val deitado = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        // As duas colunas e os encolhimentos só na tela baixa (o celular deitado); o tablet deitado fica numa
        // coluna centrada de até 560 dp, como em pé (30/09).
        baixa = telaBaixa()
        b.dvdCaixaDosTitulos.teto = dp(if (baixa) 116 else 172)
        b.dvdTxQuadro.minimumHeight = dp(if (baixa) 100 else 140)
        // Na tela baixa, a nota dos botões do disco fica só na engrenagem.
        b.dvdLegendaDoDisco.visibility = if (baixa) View.GONE else View.VISIBLE
        // Deitado em qualquer altura (o tablet também), o PIN em linha ao lado do endereço.
        b.dvdTxLinhaDoPin.orientation = if (deitado) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
        (b.dvdTxEndereco.layoutParams as LinearLayout.LayoutParams).marginStart = if (deitado) dp(16) else 0
        b.dvdTxEndereco.requestLayout()
        b.dvdTxPin.emLinha = deitado
        b.dvdTxPin.setTextSize(TypedValue.COMPLEX_UNIT_SP, if (deitado) 22f else 32f)
    }

    /** A tela baixa ([telaBaixa], o celular deitado): duas colunas, e os outros endereços só na engrenagem. */
    private var baixa = false

    /** Na vitrine, os botões não fazem nada (nenhum serviço sobe): diz isso, e devolve `true`. */
    private fun naVitrine(): Boolean {
        if (vitrine == null) return false
        Toast.makeText(this, "Vitrine: nada acontece com o disco.", Toast.LENGTH_SHORT).show() // i18n-fora: bancada (a vitrine só existe no APK de depuração)
        return true
    }

    /** A engrenagem (o R16, 30/09): as notas que moravam no pé da tela e embaixo dos botões. */
    private fun montarAjustes(f: FolhaDaTela) {
        f.manterTelaLigada()
        f.secao(getString(R.string.dvd_ajustes_secao_leitor))
        f.nota(getString(R.string.dvd_ajustes_nota_leitor))
        f.secao(getString(R.string.dvd_ajustes_secao_converter))
        f.nota(getString(R.string.dvd_ajustes_nota_converter))
        f.nota(getString(R.string.dvd_ajustes_nota_sem_receptor))
        // Os endereços da transmissão (deitado, os outros não cabem na tela).
        val enderecos = MirrorBus.atual.takeIf { it.doDvd && TransmissaoDvdBus.transmitindo && !TransmissaoDvdBus.estado.local }
            ?.enderecos.orEmpty()
        if (enderecos.isNotEmpty()) {
            f.secao(getString(R.string.dvd_ajustes_secao_enderecos))
            for ((i, e) in enderecos.withIndex()) {
                f.linha(getString(if (i == 0) R.string.dvd_ajustes_endereco else R.string.dvd_ajustes_tambem), e)
            }
        }
        f.secao(getString(R.string.dvd_ajustes_secao_discos))
        f.nota(getString(R.string.dvd_ajustes_nota_discos))
    }

    override fun onStart() {
        super.onStart()
        // O leitor plugado ou tirado com a tela aberta: procura de novo.
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                // Na vitrine, o leitor é de mentira: o USB de verdade não mexe na tela.
                if (ocupado || vitrine != null) return
                val d: UsbDevice? = if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    else @Suppress("DEPRECATION") i.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                // O leitor que saiu do USB (a falta de energia, medida no A07 em 29/09) leva a sessão junto: a
                // conexão velha não serve mais, e a tela não pode oferecer o Converter com ela.
                if (i.action == UsbManager.ACTION_USB_DEVICE_DETACHED && d != null &&
                    d.deviceName == SessaoDoDvd.leitor?.dispositivo?.deviceName) {
                    Log.w(TAG, "o leitor saiu do USB (${d.deviceName})")
                    SessaoDoDvd.fecharQuandoSair()
                    // Sem o leitor, nada de Converter com o disco da conexão velha (medido 29/09: o botão ficou e
                    // o toque deu "o leitor não está aberto").
                    b.dvdSecaoDoDisco.visibility = View.GONE
                    leitor(texto(FrasesDoDvd.LEITOR_PAROU), getString(R.string.dvd_procurar_de_novo) to { procurar() }, AvisoDaTela.Tipo.VERMELHO)
                }
                b.root.postDelayed({ if (!isDestroyed && !ocupado) procurar() }, 500)
            }
        }
        receptorUsb = r
        val filtro = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        ContextCompat.registerReceiver(this, r, filtro, ContextCompat.RECEIVER_NOT_EXPORTED)
        ConversaoDvdBus.ouvir { e -> desenhar(e) }
        TransmissaoDvdBus.ouvir(this) { desenharTransmissao() }
        MirrorBus.ouvir(this) { desenharTransmissao() }
        vitrine?.let { mostrarVitrine(it); return }
        if (!ConversaoDvdService.disponivel) {
            leitor(getString(R.string.dvd_nao_converte_64_bits), null, AvisoDaTela.Tipo.VERMELHO)
            return
        }
        if (!ocupado) procurar()
    }

    /** A vitrine: o leitor e o disco de mentira no lugar da busca pelo USB (nada é aberto nem lido). */
    private fun mostrarVitrine(v: VitrineDoDvd) {
        val acao = v.acao?.let { it to { naVitrine(); Unit } }
        if (!ocupado) {
            leitor(v.leitor, acao, v.tipoDoLeitor)
            v.disco?.let { mostrarDisco(it) }
        }
        v.mensagem?.let {
            b.dvdMensagem.tipo = if (v.mensagemPublicada) AvisoDaTela.Tipo.INFO else AvisoDaTela.Tipo.VERMELHO
            b.dvdMensagem.visibility = View.VISIBLE
            b.dvdMensagem.text = it
        }
        desenharPilula()
    }

    /**
     * **O disco girando enquanto a tela o mostra** (medido no A07, 29/09): com o disco lido e 5 min sem
     * acesso, o leitor desacelera; no Converter ele acelera de novo, e o pico do motor derrubou o USB (o
     * leitor desconectou e voltou com outro endereço). Uma leitura curta a cada 45 s, com a tela à mostra e
     * sem conversão, mantém o disco girando. A trava da [SessaoDoDvd] impede cruzar com outra leitura.
     */
    private var girandoN = 0L

    /**
     * **A cada 20 s**, e não 45 (medido em 29/09 com a fonte de 2 A, duas vezes): o hp GTB0N desliga o motor ~45 s
     * depois do último acesso, e a leitura que chegava aos 45 s o religava — a partida do motor derrubava o leitor.
     * Antes dos 45 s o motor nem para.
     */
    private val INTERVALO_DE_MANUTENCAO_MS = 20_000L

    private val manterGirando = object : Runnable {
        override fun run() {
            val l = SessaoDoDvd.leitor
            if (vitrine == null && l != null && SessaoDoDvd.disco != null && !ocupado && SessaoDoDvd.comecarLeitura()) {
                // Um setor diferente a cada vez (o mesmo volta do cache do leitor sem girar o disco), mas **perto**:
                // passos de 2048 setores (4 MB) a partir do começo, onde a cabeça ficou depois do IFO. Medido em
                // 29/09 com a fonte de 2 A: o salto para um setor distante derrubou o leitor (o pico do motor da
                // cabeça); com a fonte do Mac, os saltos longos passavam.
                val lba = 2_048L + (girandoN++ % 64L) * 2_048L
                thread(name = "quall-dvd-girando") {
                    try {
                        val r = runCatching { l.ler(lba, 1) }
                        Log.i(TAG, "disco girando: setor $lba ${if (r.isSuccess) "lido" else "falhou: ${Log.erroExterno(r.exceptionOrNull())}"}")
                    } finally { SessaoDoDvd.terminarLeitura() }
                }
            }
            b.root.postDelayed(this, INTERVALO_DE_MANUTENCAO_MS)
        }
    }

    override fun onResume() {
        super.onResume()
        b.root.postDelayed(manterGirando, INTERVALO_DE_MANUTENCAO_MS)
    }

    override fun onPause() {
        b.root.removeCallbacks(manterGirando)
        super.onPause()
    }

    override fun onStop() {
        // O Assistir aqui é da tela: saiu de vista, para (o leitor fica com a tela).
        if (vitrine == null && AssistirAqui.noAr && !isChangingConfigurations) AssistirAqui.parar()
        ConversaoDvdBus.ouvir(null)
        TransmissaoDvdBus.ouvir(this, null)
        MirrorBus.ouvir(this, null)
        receptorUsb?.let { runCatching { unregisterReceiver(it) } }
        receptorUsb = null
        super.onStop()
    }

    override fun onDestroy() {
        if (!::ajustes.isInitialized) { super.onDestroy(); return }
        receptorDaPermissao?.let { runCatching { unregisterReceiver(it) } }
        receptorDaPermissao = null
        // Sem conversão, o leitor não fica preso a uma tela que saiu.
        if (vitrine == null && isFinishing && !ocupado) SessaoDoDvd.fecharSeLivre()
        ajustes.fechar()
        super.onDestroy()
    }

    // ---- o leitor ------------------------------------------------------------------------------

    private val PRAZO_PARA_ACORDAR_MS = 120_000L

    // ---- a etapa da abertura, com o tempo passado (o Pessoa Exemplo, 29/09: "ficou travado em conferindo o leitor") ----
    /** A etapa (a chave do texto, montado a cada tique no idioma da tela), ou `null` fora da abertura. */
    @Volatile private var etapaAtual: Int? = null
    private var inicioDasEtapas = 0L
    private val relogioDasEtapas = object : Runnable {
        override fun run() {
            val e = etapaAtual ?: return
            val s = (android.os.SystemClock.elapsedRealtime() - inicioDasEtapas) / 1000
            b.dvdLeitor.text = getString(R.string.dvd_etapa_com_tempo, getString(e), s)
            b.root.postDelayed(this, 1_000)
        }
    }

    private fun comecarEtapas(primeira: Int) {
        etapaAtual = primeira
        inicioDasEtapas = android.os.SystemClock.elapsedRealtime()
        b.dvdProgressoDoLeitor.visibility = View.VISIBLE
        b.root.removeCallbacks(relogioDasEtapas)
        relogioDasEtapas.run()
        desenharPilula()
    }

    /** Da thread da leitura: a etapa nova aparece no próximo tique. */
    private fun etapa(e: Int) { etapaAtual = e }

    /** Uma [Frase] do disco no idioma desta tela. */
    private fun texto(f: Frase): String = f.em(Idioma.textos(this))

    /**
     * O leitor. Com [tipo] (âmbar para esperar, vermelho para recusa e erro, informação para o que se pede
     * ou se lê), o aviso com o botão da [acao] embaixo. Sem tipo, a linha curta ao lado da pílula ("Leitor:
     * …", "Transmitindo o DVD"), e a ação vira o botão redondo de ler de novo. [abrindo]: o "Conferindo o
     * leitor e lendo o disco…", que mantém as etapas correndo (era a comparação com a frase, que em inglês
     * não valia).
     */
    private fun leitor(
        texto: String, acao: Pair<String, () -> Unit>?, tipo: AvisoDaTela.Tipo? = AvisoDaTela.Tipo.INFO,
        abrindo: Boolean = false,
    ) {
        if (!abrindo) {
            etapaAtual = null
            b.root.removeCallbacks(relogioDasEtapas)
            b.dvdProgressoDoLeitor.visibility = View.GONE
        }
        if (tipo == null) {
            b.dvdRotulo.text = texto
            b.dvdLeitor.visibility = View.GONE
            b.dvdAcaoDoLeitor.visibility = View.GONE
            acaoDaLinha = acao?.second
            b.dvdLerDeNovo.visibility = if (acao == null) View.GONE else View.VISIBLE
            acao?.let { b.dvdLerDeNovo.contentDescription = it.first }
        } else {
            b.dvdRotulo.text = ""
            acaoDaLinha = null
            b.dvdLerDeNovo.visibility = View.GONE
            b.dvdLeitor.tipo = tipo
            b.dvdLeitor.text = texto
            b.dvdLeitor.visibility = View.VISIBLE
            if (acao == null) {
                b.dvdAcaoDoLeitor.visibility = View.GONE
            } else {
                b.dvdAcaoDoLeitor.visibility = View.VISIBLE
                b.dvdAcaoDoLeitor.text = acao.first
                b.dvdAcaoDoLeitor.setOnClickListener { acao.second() }
            }
        }
        desenharPilula()
    }

    /**
     * A luz de estúdio: NO AR enviando; AGUARDANDO esperando o receptor, sem leitor ou depois de um erro;
     * ABRINDO lendo o disco (ou preparando o título); CONVERTENDO; CONECTADO com o disco lido (ou tocando
     * aqui).
     */
    private fun desenharPilula() {
        val t = TransmissaoDvdBus.estado
        val m = MirrorBus.atual.takeIf { it.doDvd }
        val e = when {
            ConversaoDvdBus.convertendo -> PilulaDeEstado.Estado.CONVERTENDO
            TransmissaoDvdBus.transmitindo && t.fase == TransmissaoDvdBus.Fase.PREPARANDO -> PilulaDeEstado.Estado.ABRINDO
            TransmissaoDvdBus.transmitindo && t.local -> PilulaDeEstado.Estado.CONECTADO
            TransmissaoDvdBus.transmitindo && m?.fase == MirrorBus.Fase.ESPELHANDO -> PilulaDeEstado.Estado.NO_AR
            TransmissaoDvdBus.transmitindo -> PilulaDeEstado.Estado.AGUARDANDO
            etapaAtual != null -> PilulaDeEstado.Estado.ABRINDO
            b.dvdSecaoDoDisco.visibility == View.VISIBLE -> PilulaDeEstado.Estado.CONECTADO
            else -> PilulaDeEstado.Estado.AGUARDANDO
        }
        b.dvdPilula.mostrar(e)
        // Sem disco nem nada no ar, a explicação; com eles, a tela já diz.
        val vazia = b.dvdSecaoDoDisco.visibility != View.VISIBLE && !TransmissaoDvdBus.transmitindo && !ConversaoDvdBus.convertendo
        b.dvdExplicacao.visibility = if (vazia) View.VISIBLE else View.GONE
        ajustes.atualizar()
    }

    private fun procurar() {
        if (vitrine != null) return
        if (SessaoDoDvd.lendo) return
        val usb = getSystemService(UsbManager::class.java) ?: return
        val pendrive = LeitorDeDisco.umPendriveMontado(this)
        val candidatos = LeitorDeDisco.candidatos(usb, pendrive)
        if (candidatos.isEmpty()) {
            SessaoDoDvd.fecharSeLivre()
            b.dvdSecaoDoDisco.visibility = View.GONE
            val aviso = if (pendrive && LeitorDeDisco.algumArmazenamento(usb)) {
                getString(R.string.dvd_pendrive_montado)
            } else texto(FrasesDoDvd.SEM_LEITOR)
            leitor(aviso, getString(R.string.dvd_procurar_de_novo) to { procurar() }, AvisoDaTela.Tipo.AMBAR)
            return
        }
        val permitidos = candidatos.filter { usb.hasPermission(it) }
        if (permitidos.isEmpty()) {
            val d = candidatos.first()
            leitor(getString(R.string.dvd_leitor_encontrado, nomeDe(d)),
                getString(R.string.dvd_permitir_acesso) to { pedirPermissao(usb, d) })
            return
        }
        val ja = SessaoDoDvd.disco
        val aberto = SessaoDoDvd.leitor
        if (ja != null && aberto != null && permitidos.any { it.deviceName == aberto.dispositivo.deviceName }) {
            leitor(getString(R.string.dvd_leitor_nome, nomeDe(aberto.dispositivo)),
                getString(R.string.dvd_ler_de_novo) to { lerDisco(usb, permitidos, forcar = true) }, null)
            mostrarDisco(ja)
            return
        }
        lerDisco(usb, permitidos, forcar = false)
    }

    private fun nomeDe(d: UsbDevice) =
        listOfNotNull(d.manufacturerName, d.productName).joinToString(" ").ifBlank { d.deviceName }

    private fun pedirPermissao(usb: UsbManager, d: UsbDevice) {
        val acao = "$packageName.PERMISSAO_USB_DVD"
        receptorDaPermissao?.let { runCatching { unregisterReceiver(it) } }
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                runCatching { unregisterReceiver(this) }
                receptorDaPermissao = null
                if (i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) procurar()
                else leitor(getString(R.string.dvd_sem_permissao),
                    getString(R.string.dvd_permitir_acesso) to { pedirPermissao(usb, d) }, AvisoDaTela.Tipo.VERMELHO)
            }
        }
        receptorDaPermissao = r
        ContextCompat.registerReceiver(this, r, IntentFilter(acao), ContextCompat.RECEIVER_NOT_EXPORTED)
        // FLAG_MUTABLE: o sistema põe o aparelho e a resposta no Intent (como na DV, `MainActivity`).
        val pi = PendingIntent.getBroadcast(this, 3, Intent(acao).setPackage(packageName), PendingIntent.FLAG_MUTABLE)
        usb.requestPermission(d, pi)
    }

    /**
     * Confere os [candidatos] em ordem (a revisão do código, 7): abre, pergunta o INQUIRY, e o que
     * não é leitor de CD/DVD (tipo ≠ 5: o pendrive, o disco) é solto na hora e o próximo é tentado.
     * A trava de leitura é da [SessaoDoDvd] (a revisão, 11): o serviço não pega o leitor no meio.
     */
    private fun lerDisco(usb: UsbManager, candidatos: List<UsbDevice>, forcar: Boolean, desde: Long = 0L) {
        if (vitrine != null) return
        if (!SessaoDoDvd.comecarLeitura()) return
        val inicio = if (desde == 0L) android.os.SystemClock.elapsedRealtime() else desde
        b.dvdSecaoDoDisco.visibility = View.GONE
        b.dvdMensagem.visibility = View.GONE
        if (desde == 0L) {
            leitor(getString(R.string.dvd_conferindo_o_leitor), null, abrindo = true)
            comecarEtapas(R.string.dvd_etapa_acordando)
        } else etapa(R.string.dvd_etapa_acordando)
        thread(name = "quall-dvd-disco") {
            var repetir = false
            // O resultado: a frase, o disco lido, e se é espera (âmbar: ponha um disco, ou ele não ficou
            // pronto) — antes a tela decidia pelo começo da frase ("Leitor: "), que em inglês não valia.
            val (frase, disco, espera) = try {
                if (forcar) SessaoDoDvd.fecharSeLivre()
                var l: LeitorDeDisco? = null
                var quem = ""
                val naoLeitores = ArrayList<String>()
                for (d in candidatos) {
                    val c = SessaoDoDvd.abrir(usb, d)
                    val q = c.quem() ?: nomeDe(d)
                    if (c.tipo >= 0 && c.tipo != 5) {
                        // Um pendrive ou um disco (tipo 0): não é leitor, e fica solto de novo.
                        naoLeitores += q
                        SessaoDoDvd.fecharSeLivre()
                        continue
                    }
                    l = c
                    quem = q
                    break
                }
                if (l == null) {
                    val nomes = naoLeitores.reduce { a, c -> getString(R.string.dvd_lista_e, a, c) }
                    throw RecusaDoDisco(Frase(R.string.dvd_nao_e_leitor, nomes), "$nomes não é um leitor de DVD")
                }
                etapa(R.string.dvd_etapa_esperando_girar)
                when (l.esperarPronto()) {
                    LeitorDeDisco.Pronto.SEM_DISCO -> Resultado(Frase(R.string.dvd_leitor_sem_disco, quem), null, espera = true)
                    LeitorDeDisco.Pronto.NAO_FICOU_PRONTO ->
                        Resultado(Frase(R.string.dvd_leitor_nao_ficou_pronto, quem), null, espera = true)
                    LeitorDeDisco.Pronto.PRONTO -> {
                        etapa(R.string.dvd_etapa_lendo_indice)
                        l.conferir()
                        val disco = DiscoDvd.ler(l, l.setoresDoDisco())
                        SessaoDoDvd.guardar(disco)
                        Log.i(TAG, "disco \"${disco.volume}\" (${disco.sistema}): ${disco.titulos.size} título(s); " +
                            disco.titulos.joinToString { "${it.numero}: ${minutos(it.duracao90k)} ${it.recusa ?: ""}" })
                        Resultado(Frase(R.string.dvd_leitor_nome, quem), disco, espera = false)
                    }
                }
            } catch (e: RecusaDoDisco) {
                Log.w(TAG, "disco recusado: ${Log.erroExterno(e.message)}")
                SessaoDoDvd.fecharSeLivre()
                Resultado(e.recusa, null, espera = false)
            } catch (e: LeitorParou) {
                val passou = android.os.SystemClock.elapsedRealtime() - inicio
                Log.w(TAG, "leitor: ${Log.erroExterno(e.message)}${if (passou < PRAZO_PARA_ACORDAR_MS) " — reabrindo (${passou / 1000} s)" else ""}")
                SessaoDoDvd.fecharSeLivre()
                // **A primeira abertura depois de o sistema ter segurado o leitor** (medido no A07, 29/09, três
                // vezes): o driver de armazenamento do Android pega o leitor de volta quando o Quall o solta, e
                // tomado de novo no meio de um comando dele o bulk-only sai de passo; a segunda abertura, 2 s
                // depois, lê. **E às vezes ele fica 30–60 s sem responder** depois de tomado (medido 18:50–18:55):
                // reabrindo a cada falha até 2 min, sem pedir nada à pessoa (a barra mostra o tempo).
                repetir = passou < PRAZO_PARA_ACORDAR_MS
                Resultado(FrasesDoDvd.LEITOR_PAROU, null, espera = false)
            } catch (e: Exception) {
                Log.w(TAG, "ler o disco: ${e.javaClass.simpleName}: ${Log.erroExterno(e.message)}")
                SessaoDoDvd.fecharSeLivre()
                Resultado(Frase(R.string.dvd_disco_nao_lido, Frase.cru(e.message ?: e.javaClass.simpleName)), null, espera = false)
            } finally {
                SessaoDoDvd.terminarLeitura()
            }
            if (repetir) {
                Thread.sleep(2_000)
                runOnUiThread {
                    if (isDestroyed) return@runOnUiThread
                    // Os candidatos de novo: o leitor que saiu do USB volta com outro endereço.
                    val lista = LeitorDeDisco.candidatos(usb, LeitorDeDisco.umPendriveMontado(this)).filter { usb.hasPermission(it) }
                    if (lista.isEmpty()) procurar() else lerDisco(usb, lista, forcar = true, desde = inicio)
                }
                return@thread
            }
            runOnUiThread {
                if (isDestroyed) return@runOnUiThread
                // O disco lido: a linha curta ao lado da pílula. Sem ele: "Leitor: …" (ponha um disco, ou
                // ele não ficou pronto) é espera, âmbar; a recusa, o leitor que parou e o erro, vermelho.
                val tipo = when {
                    disco != null -> null
                    espera -> AvisoDaTela.Tipo.AMBAR
                    else -> AvisoDaTela.Tipo.VERMELHO
                }
                leitor(texto(frase), getString(if (disco != null) R.string.dvd_ler_de_novo else R.string.dvd_tentar_de_novo) to {
                    val u = getSystemService(UsbManager::class.java)
                    val lista = u?.let { LeitorDeDisco.candidatos(it, LeitorDeDisco.umPendriveMontado(this)).filter { d -> u.hasPermission(d) } }
                    if (u != null && !lista.isNullOrEmpty()) lerDisco(u, lista, forcar = true) else procurar()
                }, tipo)
                if (disco != null) mostrarDisco(disco)
            }
        }
    }

    /** O que a leitura do disco devolve à tela: a frase, o disco (ou `null`) e se é espera (o aviso âmbar). */
    private data class Resultado(val frase: Frase, val disco: DiscoDvd?, val espera: Boolean)

    // ---- o disco -------------------------------------------------------------------------------

    private fun mostrarDisco(d: DiscoDvd) {
        discoMostrado = d
        b.dvdSecaoDoDisco.visibility = View.VISIBLE
        b.dvdVolume.text = d.volume.ifBlank { getString(R.string.dvd_sem_nome) }
        b.dvdTitulos.removeAllViews()
        val padrao = d.padrao
        for (t in d.titulos) {
            val rb = RadioButton(this).apply {
                id = View.generateViewId()
                tag = t.numero
                text = estilizar(descrever(t))
                contentDescription = descrever(t)
                isEnabled = t.recusa == null
                textSize = 15f
                setTextColor(Cores.TEXTO)
                buttonTintList = ColorStateList.valueOf(Cores.ACENTO)
                minHeight = dp(48)
                setPadding(paddingLeft, dp(6), paddingRight, dp(6))
            }
            b.dvdTitulos.addView(rb)
            if (t == padrao) rb.isChecked = true
        }
        if (d.titulos.isEmpty()) {
            b.dvdTitulos.addView(android.widget.TextView(this).apply {
                text = getString(R.string.dvd_sem_titulos)
                setTextColor(Cores.TEXTO2)
                setPadding(dp(10), dp(12), dp(10), dp(12))
            })
        }
        b.dvdConverter.isEnabled = padrao != null && !ocupado
        b.dvdTransmitir.isEnabled = padrao != null && !ocupado
        b.dvdAssistir.isEnabled = padrao != null && !ocupado
        mostrarFaixas()
        desenharPilula()
    }

    /** A primeira linha do título em `texto`, as outras (o som, os avisos) em `texto2`, um pouco menores. */
    private fun estilizar(descricao: String): CharSequence {
        val quebra = descricao.indexOf('\n')
        if (quebra < 0) return descricao
        return SpannableStringBuilder(descricao).apply {
            setSpan(ForegroundColorSpan(Cores.TEXTO2), quebra, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(RelativeSizeSpan(0.87f), quebra, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    /** O título marcado na lista, ou `null`. */
    private fun tituloMarcado(): TituloDoDvd? {
        val id = b.dvdTitulos.checkedRadioButtonId
        val numero = b.dvdTitulos.findViewById<RadioButton>(id)?.tag as? Int ?: return null
        return discoMostrado?.titulos?.firstOrNull { it.numero == numero }
    }

    /**
     * A escolha do som da transmissão, só com mais de uma faixa (a primeira marcada, a cada título). Era
     * uma lista de botões; desde o R16 (30/09) é um chip, e o toque abre a lista ([escolherFaixa]).
     */
    private fun mostrarFaixas() {
        val faixas = tituloMarcado()?.faixasConvertiveis.orEmpty()
        faixaEscolhida = 0
        val varias = faixas.size > 1
        b.dvdFaixas.visibility = if (varias) View.VISIBLE else View.GONE
        if (varias) desenharFaixa(faixas)
    }

    private fun desenharFaixa(faixas: List<FaixaDeSom>) {
        val f = faixas.getOrNull(faixaEscolhida) ?: return
        b.dvdFaixas.text = getString(R.string.dvd_som_da_transmissao_chip, faixa(f))
        b.dvdFaixas.contentDescription = getString(R.string.dvd_som_da_transmissao_descricao, faixa(f))
    }

    private fun escolherFaixa() {
        val faixas = tituloMarcado()?.faixasConvertiveis.orEmpty()
        if (faixas.size < 2) return
        android.app.AlertDialog.Builder(this).setTitle(R.string.dvd_som_da_transmissao)
            .setSingleChoiceItems(faixas.map { faixa(it) }.toTypedArray(), faixaEscolhida) { d, i ->
                d.dismiss()
                faixaEscolhida = i
                desenharFaixa(faixas)
            }
            .setNegativeButton(R.string.cancelar, null).show()
    }

    /** Assistir aqui: o título no próprio aparelho, sem rede ([AssistirAqui]). */
    private fun assistir() {
        val t = tituloMarcado() ?: return
        if (ocupado) return
        val faixa = faixaEscolhida
        b.dvdMensagem.visibility = View.GONE
        b.dvdAssistir.isEnabled = false
        AssistirAqui.comecar(this, t.numero, faixa)
    }

    /** Assistindo aqui, o Transmitir para o Assistir e começa o Espelhar do mesmo ponto do título. */
    private fun transmitirDaqui() {
        val c = TransmissaoDvdBus.controle ?: return
        val numero = c.titulo.numero
        val faixa = c.faixaDaRede
        b.dvdTxTransmitirDaqui.isEnabled = false
        AssistirAqui.parar { posicao ->
            if (isDestroyed) return@parar
            val t = discoMostrado?.titulos?.firstOrNull { it.numero == numero } ?: return@parar
            iniciarTransmissao(t, faixa, posicao)
        }
    }

    private fun transmitir() {
        val t = tituloMarcado() ?: return
        if (ocupado) return
        val faixa = faixaEscolhida
        iniciarTransmissao(t, faixa, 0)
    }

    private fun iniciarTransmissao(t: TituloDoDvd, faixa: Int, inicio90k: Long) {
        b.dvdMensagem.visibility = View.GONE
        b.dvdTransmitir.isEnabled = false
        b.dvdConverter.isEnabled = false
        // Na hora, antes de o serviço publicar: a tela já não lê o disco nem oferece o Converter.
        TransmissaoDvdBus.publicar(TransmissaoDvdBus.Estado(
            fase = TransmissaoDvdBus.Fase.PREPARANDO, volume = discoMostrado?.volume.orEmpty(), titulo = t.numero,
            duracao90k = t.duracao90k,
        ))
        val i = Intent(this, MirrorService::class.java)
            .putExtra(MirrorService.EXTRA_SOURCE_KIND, MirrorService.SOURCE_DVD)
            .putExtra(MirrorService.EXTRA_DVD_TITULO, t.numero)
            .putExtra(MirrorService.EXTRA_DVD_FAIXA, faixa)
            .putExtra(MirrorService.EXTRA_DVD_INICIO, inicio90k)
        runCatching { ContextCompat.startForegroundService(this, i) }.onFailure { e ->
            TransmissaoDvdBus.publicar(TransmissaoDvdBus.Estado(fase = TransmissaoDvdBus.Fase.PARADA,
                mensagem = getString(R.string.dvd_transmissao_nao_comecou, e.message ?: e.javaClass.simpleName)))

        }
    }

    // ---- a transmissão -------------------------------------------------------------------------

    /** A transmissão na tela: o PIN e o endereço (do `MirrorBus`), o tempo do título e os controles. */
    private fun desenharTransmissao() {
        telaLigada.atualizar()
        val t = TransmissaoDvdBus.estado
        val m = MirrorBus.atual.takeIf { it.doDvd }
        val noAr = TransmissaoDvdBus.transmitindo
        b.dvdSecaoDaTransmissao.visibility = if (noAr) View.VISIBLE else View.GONE
        b.dvdTxQuadro.visibility = if (noAr) View.VISIBLE else View.GONE
        if (noAr) {
            b.dvdSecaoDoDisco.visibility = View.GONE
            b.dvdSecaoDoProgresso.visibility = View.GONE
            b.dvdMensagem.visibility = View.GONE
            b.dvdTxParar.isEnabled = true
            b.dvdTxRotulo.text = getString(if (t.local) R.string.dvd_rotulo_assistindo_aqui else R.string.dvd_rotulo_transmissao)
            b.dvdTxParar.text = getString(R.string.dvd_parar)
            b.dvdTxParar.contentDescription = getString(if (t.local) R.string.dvd_parar else R.string.dvd_parar_a_transmissao)
            b.dvdTxTransmitirDaqui.visibility = if (t.local) View.VISIBLE else View.GONE
            b.dvdTxTransmitirDaqui.isEnabled = t.local && TransmissaoDvdBus.controle != null
            b.dvdTxOuvir.isEnabled = TransmissaoDvdBus.controle?.temSom == true || vitrine != null
            // Rótulos curtos (a linha tem três botões; deitado, ~120 dp cada): "Parar de ouvir" e "Parar a
            // gravação" saíam cortados ("■ Parar a", a foto de 30/09). A frase inteira fica na acessibilidade.
            b.dvdTxOuvir.text = getString(if (t.ouvindo) R.string.dvd_parar_som else R.string.dvd_ouvir)
            b.dvdTxOuvir.contentDescription = getString(if (t.ouvindo) R.string.dvd_parar_de_ouvir else R.string.dvd_ouvir)
            // A linha ao lado da pílula diz o que toca; a nota do pé, o que vale enquanto isso (o filme que
            // espera, o leitor que é um só).
            leitor(getString(if (t.local) R.string.dvd_tocando_aqui_sem_rede else R.string.dvd_transmitindo), null, null)
            b.dvdTxLegenda.text = getString(if (t.local) R.string.dvd_legenda_local else R.string.dvd_legenda_rede)
            val volume = t.volume.ifBlank { getString(R.string.dvd_sem_nome) }
            b.dvdTxTitulo.text = if (t.som.isNotEmpty()) getString(R.string.dvd_tx_titulo_com_som, volume, t.titulo, t.som)
                else getString(R.string.dvd_tx_titulo, volume, t.titulo)
            val esperando = m == null || m.fase != MirrorBus.Fase.ESPELHANDO
            val comPin = !t.local && esperando && !m?.pin.isNullOrEmpty()
            b.dvdTxLinhaDoPin.visibility = if (comPin) View.VISIBLE else View.GONE
            b.dvdTxPin.mostrar(m?.pin.orEmpty())
            val enderecos = m?.enderecos.orEmpty()
            b.dvdTxEndereco.text = enderecos.firstOrNull() ?: getString(R.string.dvd_sem_rede)
            b.dvdTxEndereco.copiavel = enderecos.isNotEmpty()
            val outros = if (comPin && !baixa && enderecos.size > 1) {
                getString(R.string.dvd_tambem_enderecos, enderecos.drop(1).joinToString("  ·  "))
            } else ""
            b.dvdTxOutros.text = outros
            b.dvdTxOutros.visibility = if (outros.isEmpty()) View.GONE else View.VISIBLE
            b.dvdTxEstado.text = when {
                t.local -> comAndamento(getString(if (t.fase == TransmissaoDvdBus.Fase.PREPARANDO) R.string.dvd_conferindo_o_disco
                    else R.string.dvd_tocando_aqui), t)
                m == null || m.fase == MirrorBus.Fase.PARADO ->
                    getString(if (t.fase == TransmissaoDvdBus.Fase.PREPARANDO) R.string.dvd_conferindo_o_disco else R.string.dvd_preparando)
                m.fase == MirrorBus.Fase.ERRO -> m.mensagem
                m.fase == MirrorBus.Fase.ESPELHANDO -> comAndamento(getString(R.string.dvd_enviando_para, m.par), t)
                else -> getString(R.string.dvd_esperando_receptor) +
                    if (m.tentativa > 1 && m.mensagem.isNotEmpty()) "\n${m.mensagem}" else ""
            }
            b.dvdTxTempo.text = "${relogio(t.posicao90k)} / ${relogio(t.duracao90k)}"
            b.dvdTxBarra.progress = if (t.duracao90k > 0) (t.posicao90k * 1000 / t.duracao90k).toInt() else 0
            // Na vitrine, os controles à mostra como no ar (o toque diz que nada acontece).
            val controla = TransmissaoDvdBus.controle != null || vitrine != null
            b.dvdTxPausar.isEnabled = controla
            b.dvdTxVoltar30.isEnabled = controla
            b.dvdTxAvancar30.isEnabled = controla
            // A gravação (a T4): o tempo gravado e o tamanho, como nas câmeras; o fim diz onde ficou.
            b.dvdTxGravar.isEnabled = controla
            b.dvdTxGravar.text = getString(if (t.gravando) R.string.dvd_gravacao else R.string.dvd_gravar)
            b.dvdTxGravar.contentDescription = getString(if (t.gravando) R.string.dvd_parar_a_gravacao else R.string.dvd_gravar)
            b.dvdTxGravar.setIconResource(if (t.gravando) com.quall.android.R.drawable.ic_q_parar else com.quall.android.R.drawable.ic_q_gravar)
            val linha = when {
                t.gravando -> getString(if (t.pausado) R.string.dvd_gravando_pausada else R.string.dvd_gravando,
                    relogio(t.gravacao90k), t.gravacaoBytes / 1_000_000.0)
                else -> t.gravacaoMensagem
            }
            b.dvdTxGravacao.visibility = if (linha.isEmpty()) View.GONE else View.VISIBLE
            b.dvdTxGravacao.text = linha
            b.dvdTxGravacao.setTextColor(if (t.gravando) Cores.PERIGO_TEXTO else Cores.TEXTO2)
            b.dvdTxPausar.text = getString(when {
                t.fimDoTitulo -> R.string.dvd_do_comeco
                t.pausado -> R.string.dvd_continuar
                else -> R.string.dvd_pausar
            })
        } else if (estavaTransmitindo) {
            // A transmissão terminou: o leitor voltou (e fechou, como depois do Converter).
            // A frase do fim, e onde ficou a gravação (a T4), se houve.
            val fim = listOf(t.mensagem, t.gravacaoMensagem).filter { it.isNotEmpty() }.joinToString("\n")
            if (fim.isNotEmpty()) {
                // A frase do fim é a recusa, o leitor que parou, a que não começou: vermelho. Só o onde
                // ficou a gravação, informação.
                b.dvdMensagem.tipo = if (t.mensagem.isNotEmpty()) AvisoDaTela.Tipo.VERMELHO else AvisoDaTela.Tipo.INFO
                b.dvdMensagem.visibility = View.VISIBLE
                b.dvdMensagem.text = fim
            }
            // O Assistir aqui devolve o leitor sem fechar: o disco lido volta à tela.
            val disco = if (t.local) SessaoDoDvd.disco.takeIf { SessaoDoDvd.leitor != null && !SessaoDoDvd.doServico } else null
            if (disco != null) {
                leitor(getString(R.string.dvd_leitor_nome, SessaoDoDvd.leitor?.dispositivo?.let { nomeDe(it) } ?: ""),
                    getString(R.string.dvd_ler_de_novo) to { procurar() }, null)
                mostrarDisco(disco)
            } else {
                discoMostrado = null
                b.dvdSecaoDoDisco.visibility = View.GONE
                leitor(getString(if (t.local) R.string.dvd_parou else R.string.dvd_transmissao_terminou),
                    getString(R.string.dvd_ler_de_novo) to { procurar() })
            }
        }
        estavaTransmitindo = noAr
        desenharPilula()
    }

    /** O estado com o que acontece agora no título (pulando, fim do título, pausado), se algo. */
    private fun comAndamento(base: String, t: TransmissaoDvdBus.Estado): String = when {
        t.pulando -> getString(R.string.dvd_andamento_pulando, base)
        t.fimDoTitulo -> getString(R.string.dvd_andamento_fim_do_titulo, base)
        t.pausado -> getString(R.string.dvd_andamento_pausado, base)
        else -> base
    }

    /** 90 kHz em "h:mm:ss" ou "m:ss" (dígitos, iguais nos dois idiomas). */
    private fun relogio(t90k: Long): String {
        val s = (t90k / 90_000).coerceAtLeast(0)
        return if (s >= 3600) "%d:%02d:%02d".format(java.util.Locale.ROOT, s / 3600, s / 60 % 60, s % 60)
        else "%d:%02d".format(java.util.Locale.ROOT, s / 60, s % 60)
    }

    private fun descrever(t: TituloDoDvd): String {
        val partes = ArrayList<String>()
        partes += getString(R.string.dvd_titulo_numero, t.numero, minutos(t.duracao90k))
        partes += if (t.aspecto169) "16:9" else "4:3"
        partes += if (t.pal) "PAL" else "NTSC"
        val som = t.faixas.joinToString(", ") { faixa(it) }
        val linhas = arrayListOf(partes.joinToString(" · "),
            if (som.isEmpty()) getString(R.string.dvd_titulo_sem_som) else getString(R.string.dvd_titulo_som, som))
        t.avisoDeSom?.let { linhas += getString(R.string.dvd_aviso_sem_som, texto(it)) }
        t.recusa?.let { linhas += texto(it) }
        return linhas.joinToString("\n")
    }

    private fun faixa(f: FaixaDeSom): String {
        val idioma = IDIOMAS[f.idioma]?.let { getString(it) } ?: f.idioma ?: getString(R.string.dvd_sem_idioma)
        val canais = when (f.canais) {
            1 -> getString(R.string.dvd_canais_mono)
            2 -> getString(R.string.dvd_canais_estereo)
            6 -> "5.1"
            else -> getString(R.string.dvd_canais_n, f.canais)
        }
        return getString(if (f.convertivel) R.string.dvd_faixa else R.string.dvd_faixa_nao_converte, idioma, f.formato, canais)
    }

    private fun minutos(t90k: Long): String {
        val min = (t90k / 90_000 + 30) / 60
        return if (min >= 60) getString(R.string.dvd_duracao_h_min, min / 60, min % 60) else getString(R.string.dvd_tempo_min, min)
    }

    private fun converter() {
        val id = b.dvdTitulos.checkedRadioButtonId
        val numero = b.dvdTitulos.findViewById<RadioButton>(id)?.tag as? Int ?: return
        b.dvdMensagem.visibility = View.GONE
        b.dvdConverter.isEnabled = false
        ConversaoDvdService.comecar(this, numero)
    }

    // ---- a conversão ---------------------------------------------------------------------------

    private fun desenhar(e: ConversaoDvdBus.Estado) {
        val noAr = e.fase == ConversaoDvdBus.Fase.PREPARANDO || e.fase == ConversaoDvdBus.Fase.CONVERTENDO
        b.dvdSecaoDoProgresso.visibility = if (noAr) View.VISIBLE else View.GONE
        b.dvdConverter.isEnabled = !noAr && discoMostrado?.padrao != null && !TransmissaoDvdBus.transmitindo
        b.dvdTransmitir.isEnabled = !noAr && discoMostrado?.padrao != null && !TransmissaoDvdBus.transmitindo
        if (noAr) {
            b.dvdSecaoDoDisco.visibility = View.GONE
            b.dvdMensagem.visibility = View.GONE
            b.dvdNomeDoArquivo.text = if (e.nome.isNotEmpty()) e.nome else getString(R.string.dvd_preparando)
            b.dvdBarra.progress = (e.fracao * 1000).toInt()
            val pct = (e.fracao * 100).toInt()
            // As partes da linha, separadas por " · ": a porcentagem, o tempo convertido, o que falta e os
            // setores pulados.
            val partes = arrayListOf(getString(R.string.dvd_progresso_porcentagem, pct))
            if (e.duracao90k > 0) partes += getString(R.string.dvd_progresso_de, minutos(e.tempo90k), minutos(e.duracao90k))
            if (e.restanteMs >= 0) partes += getString(R.string.dvd_progresso_falta, tempo(e.restanteMs))
            if (e.setoresPulados > 0) {
                partes += if (e.setoresPulados == 1L) getString(R.string.dvd_progresso_pulado_um)
                    else getString(R.string.dvd_progresso_pulados, e.setoresPulados)
            }
            b.dvdProgresso.text = if (e.fase == ConversaoDvdBus.Fase.PREPARANDO) getString(R.string.dvd_lendo_o_comeco)
            else partes.joinToString(" · ")
            leitor(getString(R.string.dvd_convertendo), null, null)
        } else if (e.fase == ConversaoDvdBus.Fase.PARADA && (e.fim != null || e.mensagem.isNotEmpty())) {
            // Publicado na Galeria: informação; a recusa, o erro e o cancelado: vermelho. A frase sem idioma
            // (`fim`) é montada agora; quem só publicou texto (a vitrine) fica com ele.
            b.dvdMensagem.tipo = if (e.publicado) AvisoDaTela.Tipo.INFO else AvisoDaTela.Tipo.VERMELHO
            b.dvdMensagem.visibility = View.VISIBLE
            b.dvdMensagem.text = e.fim?.let { texto(it) } ?: e.mensagem
            if (estavaNoAr) {
                // O serviço devolveu o leitor (e fechou): o disco é lido de novo quando a pessoa pedir.
                discoMostrado = null
                b.dvdSecaoDoDisco.visibility = View.GONE
                leitor(getString(R.string.dvd_conversao_terminou), getString(R.string.dvd_converter_outro) to { procurar() })
            }
        }
        estavaNoAr = noAr
        desenharPilula()
    }

    private fun tempo(ms: Long): String {
        val min = (ms + 59_999) / 60_000
        return if (min >= 60) getString(R.string.dvd_tempo_h_min, min / 60, min % 60) else getString(R.string.dvd_tempo_min, min)
    }

    companion object {
        private const val TAG = "QuallDvd"
        /** O nome do idioma da faixa (o código do IFO), no idioma da tela. */
        private val IDIOMAS = mapOf(
            "pt" to R.string.dvd_idioma_pt, "en" to R.string.dvd_idioma_en, "es" to R.string.dvd_idioma_es,
            "fr" to R.string.dvd_idioma_fr, "de" to R.string.dvd_idioma_de, "it" to R.string.dvd_idioma_it,
            "ja" to R.string.dvd_idioma_ja, "zh" to R.string.dvd_idioma_zh, "ko" to R.string.dvd_idioma_ko,
            "ru" to R.string.dvd_idioma_ru, "nl" to R.string.dvd_idioma_nl, "pl" to R.string.dvd_idioma_pl,
        )
    }

}
