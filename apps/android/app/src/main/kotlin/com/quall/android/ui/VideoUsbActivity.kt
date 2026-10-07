package com.quall.android.ui

import com.quall.android.capturaUsbPossivel

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.quall.android.core.LogSeguro as Log
import android.view.View
import android.widget.RadioButton
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.button.MaterialButton
import com.quall.android.R
import com.quall.android.capture.dv.DonoDaPlaca
import com.quall.android.capture.dv.GravacaoBus
import com.quall.android.capture.dv.GravacaoDvService
import com.quall.android.capture.dv.PainelDoVideoUsb
import com.quall.android.capture.dv.PreviaDv
import com.quall.android.capture.dv.QuallDv
import com.quall.android.capture.dv.UsbDv
import com.quall.android.capture.dv.VideoUsb
import com.quall.android.core.Idioma
import com.quall.android.core.Textos
import com.quall.android.databinding.ActivityVideoUsbBinding
import com.quall.android.mirror.EstadoDoMicrofone
import com.quall.android.mirror.MicrofoneBus
import com.quall.android.mirror.MirrorBus
import com.quall.android.mirror.MirrorService

/**
 * **"Placa de captura e filmadora"** (`docs/placa-de-captura-usb.md` §13; o cartão na tela inicial, no
 * modelo do "Converter DVD"): acha o aparelho de vídeo USB (a placa de captura MJPEG e a filmadora DV),
 * pede a permissão da câmera (o Android a exige para UVC) e a do USB, e **mostra a imagem ao vivo já**,
 * sem gravar nem transmitir — a filmadora DV também. Os botões: **Gravar** (o [GravacaoDvService]: a
 * gravação da placa, ou o "Gravar a fita"), **Transmitir** (o [MirrorService] com esta fonte, a mesma
 * sessão do Espelhar), **Ouvir** (a placa) e **Foto** (as duas).
 *
 * **Um dono só do aparelho** ([DonoDaPlaca]): a prévia desta tela é uma posse `PREVIA` (pela chave
 * [DONO]), e a gravação e a rede pegam as delas da mesma abertura USB, nunca outra. Sair da tela solta
 * a posse da prévia (em 1,5 s, pela espera do dono); gravando ou transmitindo, os serviços seguem com a
 * tela fechada ou apagada, e ao voltar a prévia volta sobre a mesma abertura.
 *
 * **O "Estúdio de bolso" e o R16 (30/09, decisão do Pessoa Exemplo)**: o cabeçalho voltar · título · engrenagem,
 * a pílula de estado (AGUARDANDO, CONECTADO, REC, NO AR), os avisos, os botões e o letreiro do PIN das
 * peças, e tudo cabendo sem rolar em pé e deitado (duas colunas, `ColunasDaTela`). As cinco opções da
 * placa (§14.4) e as notas do pé foram para a engrenagem ([FolhaDaTela]); na tela fica um chip com o
 * formato, o tamanho e os quadros. **O comportamento não mudou.**
 *
 * **A vitrine** ([EstadoDasTelas.placaDaVitrine], só o APK de depuração escreve): um aparelho de mentira
 * para os retratos sem a placa plugada — a tela não toca no USB nem no dono da placa, a prévia mostra
 * barras de cor ([QuadroDeExemplo]) e os botões não sobem serviço nenhum.
 */
class VideoUsbActivity : AppCompatActivity() {
    private lateinit var b: ActivityVideoUsbBinding
    private lateinit var telaLigada: TelaLigada
    private val principal = Handler(Looper.getMainLooper())
    private var receptorUsb: BroadcastReceiver? = null
    private var receptorDaPermissao: BroadcastReceiver? = null
    private var visivel = false

    /** O aparelho mostrado (`usb-dv:<deviceName>`), ou `null`. */
    private var idAtual: String? = null
    /** As permissões dadas e o aparelho plugado: a prévia é pedida ao dono. */
    private var pronto = false
    /** A última falha da prévia (a frase do dono), até a pessoa pedir de novo. */
    private var falhaDaPrevia: String? = null
    /** A transmissão foi pedida daqui: o fim dela (ou a recusa) é dito nesta tela. */
    private var transmissaoPedida = false
    private var fotografando = false
    /** A permissão da câmera acabou de vir: a do USB é pedida direto, e não por outro botão. */
    private var pedirUsbJa = false
    /** O que fazer depois da resposta do microfone (gravar ou transmitir seguem sem ele). */
    private var depoisDoMicrofone: (() -> Unit)? = null

    /**
     * O aparelho de mentira da vitrine de bancada (só o APK de depuração o escreve); `null` no produto.
     * Lido uma vez só, por esta tela: a próxima, aberta pelo Início, é a de verdade (a revisão, 30/09).
     */
    private val vitrine: VitrineDaPlaca? = EstadoDasTelas.placaDaVitrine.also { EstadoDasTelas.placaDaVitrine = null }

    /**
     * Os textos dos módulos puros ([PainelDoVideoUsb], [VideoUsb]) no idioma desta tela
     * (`docs/traducao.md`, Android): pedidos a cada uso; a troca de idioma recria a tela.
     */
    private val t: Textos get() = Idioma.textos(this)

    /** O nome do aparelho mostrado (a linha da pílula), ou `null` sem aparelho. */
    private var rotuloDoAparelho: String? = null

    /** A engrenagem: as opções da placa e as notas (o que não cabe na tela, R16). */
    private lateinit var ajustes: FolhaDaTela

    private val permissaoDaCamera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        // Com a câmera dada, a do USB vem em seguida, sem outro toque (o pedido é um só para a pessoa).
        if (ok) { pedirUsbJa = true; procurar() } else semCamera()
    }

    private val permissaoDoMicrofone = registerForActivityResult(ActivityResultContracts.RequestPermission()) { _ ->
        val a = depoisDoMicrofone
        depoisDoMicrofone = null
        a?.invoke()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Abaixo do Android 11 a tela nem abre (`capturaUsbPossivel`): o ladrilho já some na principal.
        if (!capturaUsbPossivel) { finish(); return }
        // O título que o TalkBack anuncia (no 9–12 o do manifesto sai no idioma do sistema).
        setTitle(R.string.placa_titulo_da_tela)
        b = ActivityVideoUsbBinding.inflate(layoutInflater)
        setContentView(b.root)
        telaLigada = TelaLigada(this) {
            GravacaoBus.gravando || MirrorBus.atual.fase.let {
                it == MirrorBus.Fase.ESPERANDO || it == MirrorBus.Fase.ESPELHANDO
            }
        }
        ViewCompat.setOnApplyWindowInsetsListener(b.root) { v, insets ->
            val r = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            v.setPadding(r.left, r.top, r.right, r.bottom)
            insets
        }
        UsbDv.lembrarEm(this)
        // Na vitrine, barras de cor no lugar da imagem (não há placa); no produto, a prévia do dono.
        val v = vitrine
        b.vuPrevia.holder.addCallback(
            if (v != null) QuadroDeExemplo(v.opcoes?.largura ?: 640, v.opcoes?.altura ?: 480) else PreviaDv
        )
        ajustes = FolhaDaTela(this).apply { aoMontar = { montarAjustes(it) } }
        b.vuRecado.sobreImagem = true
        b.vuVoltar.setOnClickListener { finish() }
        b.vuAjustes.setOnClickListener { ajustes.mostrar() }
        b.vuOpcoes.setOnClickListener { ajustes.mostrar() }
        b.vuGravar.setOnClickListener { if (!naVitrine()) alternarGravacao() }
        b.vuTransmitir.setOnClickListener { if (!naVitrine()) alternarTransmissao() }
        b.vuOuvir.setOnClickListener { if (!naVitrine()) alternarOuvir() }
        b.vuFoto.setOnClickListener { if (!naVitrine()) tirarFoto() }
        b.vuSom.setOnClickListener { if (!naVitrine()) alternarSomDaTransmissao() }
        b.vuEscolha.setOnCheckedChangeListener { g, id ->
            if (montandoEscolha) return@setOnCheckedChangeListener
            val novo = g.findViewById<RadioButton>(id)?.tag as? String ?: return@setOnCheckedChangeListener
            if (novo != idAtual) { idAtual = novo; falhaDaPrevia = null; procurar() }
        }
        aplicarOrientacao()
        if (v?.abrirAjustes == true) b.root.post { if (!isFinishing) ajustes.mostrar() }
    }

    override fun onConfigurationChanged(novaConfiguracao: Configuration) {
        super.onConfigurationChanged(novaConfiguracao)
        aplicarOrientacao()
    }

    /**
     * Deitado num celular, a transmissão fica baixa (R16): o PIN em linha (mono, sem casas) ao lado do
     * endereço. Em pé, e no tablet, o letreiro de casas em cima do endereço. As colunas da tela
     * (`ColunasDaTela`) decidem sozinhas pela configuração.
     */
    private fun aplicarOrientacao() {
        val deitado = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        // As duas colunas só na tela baixa (o celular deitado); o tablet deitado fica numa coluna centrada
        // de até 560 dp, como em pé (30/09).
        baixa = telaBaixa()
        // Na tela baixa, a imagem divide a coluna com Ouvir, Foto e a gravação: o mínimo dela desce para 100 dp.
        b.vuSecaoDaImagem.minimumHeight = dp(if (baixa) 100 else 140)
        // Deitado em qualquer altura (o celular, e o tablet numa coluna de ~700 dp de altura), o PIN em linha
        // ao lado do endereço: o letreiro de casas em cima do endereço não deixaria a imagem caber.
        b.vuLinhaDoPin.orientation = if (deitado) android.widget.LinearLayout.HORIZONTAL else android.widget.LinearLayout.VERTICAL
        (b.vuBlocoDoEndereco.layoutParams as android.widget.LinearLayout.LayoutParams).marginStart = if (deitado) dp(20) else 0
        b.vuBlocoDoEndereco.requestLayout()
        b.vuPin.emLinha = deitado
        b.vuPin.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, if (deitado) 22f else 32f)
    }

    /** A tela baixa ([telaBaixa], o celular deitado): duas colunas, e os outros endereços só na engrenagem. */
    private var baixa = false

    /** Na vitrine, os botões não fazem nada (nenhum serviço sobe): diz isso, e devolve `true`. */
    private fun naVitrine(): Boolean {
        if (vitrine == null) return false
        Toast.makeText(this, "Vitrine: nada vai ao ar.", Toast.LENGTH_SHORT).show()  // i18n-fora: bancada (a vitrine só existe no APK de depuração)
        return true
    }

    override fun onStart() {
        super.onStart()
        visivel = true
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                // O `deviceName` muda a cada replugue: a busca é refeita (e a prévia, pedida de novo).
                principal.postDelayed({ if (visivel) procurar() }, 500)
            }
        }
        receptorUsb = r
        ContextCompat.registerReceiver(this, r, IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
        GravacaoBus.ouvir(this) { desenhar() }
        MirrorBus.ouvir(this) { e -> aoMudarATransmissao(e) }
        MicrofoneBus.ouvir(this) { desenhar() }
        UsbDv.ouvirTipo(this) { principal.post { rotular() } }
        principal.post(tique)
        procurar()
    }

    override fun onStop() {
        visivel = false
        principal.removeCallbacks(tique)
        receptorUsb?.let { runCatching { unregisterReceiver(it) } }
        receptorUsb = null
        GravacaoBus.ouvir(this, null)
        MirrorBus.ouvir(this, null)
        MicrofoneBus.ouvir(this, null)
        UsbDv.ouvirTipo(this, null)
        // O ouvir é da tela (como no Espelhar); a prévia é solta pelo dono em 1,5 s. A gravação e a
        // transmissão têm as posses delas e seguem.
        if (vitrine == null) {
            if (DonoDaPlaca.ouvindo) DonoDaPlaca.ouvir(this, false) { _, _ -> }
            DonoDaPlaca.quererPrevia(DONO, this, null) { }
        }
        super.onStop()
    }

    override fun onDestroy() {
        if (!::ajustes.isInitialized) { super.onDestroy(); return }
        receptorDaPermissao?.let { runCatching { unregisterReceiver(it) } }
        receptorDaPermissao = null
        ajustes.fechar()
        super.onDestroy()
    }

    /** O tempo da gravação anda pelo `GravacaoBus` (1 s); o tique redesenha o que vem do dono. */
    private val tique = object : Runnable {
        override fun run() {
            desenhar()
            principal.postDelayed(this, 500)
        }
    }

    // ---- o aparelho ----------------------------------------------------------------------------

    /**
     * O aviso do aparelho ([tipo] diz a cor: âmbar para esperar, vermelho para o que impede, informação
     * para o que se pede) e o botão dele. Com o aparelho pronto, `aparelhoPronto` no lugar: o nome vai
     * para a linha da pílula e o aviso some.
     */
    private fun aparelho(texto: String, acao: Pair<String, () -> Unit>?, tipo: AvisoDaTela.Tipo = AvisoDaTela.Tipo.AMBAR) {
        b.vuAparelho.tipo = tipo
        b.vuAparelho.seMudou(texto)
        mudar(b.vuAparelho, true)
        if (acao == null) {
            b.vuAcaoDoAparelho.visibility = View.GONE
        } else {
            b.vuAcaoDoAparelho.visibility = View.VISIBLE
            b.vuAcaoDoAparelho.text = acao.first
            b.vuAcaoDoAparelho.setOnClickListener { acao.second() }
        }
    }

    /** O aparelho pronto: o nome na linha da pílula, sem aviso e sem botão. */
    private fun aparelhoPronto(rotulo: String) {
        rotuloDoAparelho = rotulo
        b.vuRotulo.seMudou(rotulo)
        mudar(b.vuAparelho, false)
        b.vuAcaoDoAparelho.visibility = View.GONE
    }

    private fun naoPronto() {
        pronto = false
        if (vitrine == null) DonoDaPlaca.quererPrevia(DONO, this, null) { }
        desenhar()
    }

    /** A vitrine: o aparelho de mentira no lugar da busca pelo USB (nada é aberto nem pedido). */
    private fun procurarNaVitrine(v: VitrineDaPlaca) {
        b.vuEscolha.visibility = View.GONE
        rotuloDoAparelho = v.rotulo.ifBlank { null }
        b.vuRotulo.seMudou(v.rotulo)
        falhaDaPrevia = v.falha
        if (v.pronto) {
            idAtual = UsbDv.PREFIXO_DO_ID + "vitrine"
            aparelhoPronto(v.rotulo)
            pronto = true
        } else {
            idAtual = null
            aparelho(v.mensagem.orEmpty(), v.acao?.let { it to { naVitrine(); Unit } }, v.tipoDaMensagem)
            pronto = false
        }
        desenhar()
    }

    /**
     * Acha o aparelho e anda pelas permissões: a da câmera primeiro (sem ela o Android recusa a do
     * USB para UVC sem diálogo, medido no S24), depois a do USB; com as duas, pede a prévia ao dono.
     */
    private fun procurar() {
        if (!visivel) return
        vitrine?.let { procurarNaVitrine(it); return }
        if (!QuallDv.disponivel) {
            rotuloDoAparelho = null
            b.vuRotulo.seMudou("")
            aparelho(getString(R.string.placa_sem_64_bits), null, AvisoDaTela.Tipo.VERMELHO)
            b.vuEscolha.visibility = View.GONE
            idAtual = null
            naoPronto()
            return
        }
        val usb = getSystemService(UsbManager::class.java) ?: return
        val chaveDv = com.quall.android.core.Bancada.cameraDv(this)
        val devs = UsbDv.candidatos(usb).filter { PainelDoVideoUsb.naTela(UsbDv.conhecido(it), chaveDv) }
        val candidatos = devs.map { PainelDoVideoUsb.Candidato(UsbDv.PREFIXO_DO_ID + it.deviceName, UsbDv.conhecido(it), UsbDv.temSom(it)) }
        val escolhido = PainelDoVideoUsb.escolher(candidatos, idAtual)
        mostrarEscolha(devs, escolhido?.id)
        if (escolhido == null) {
            idAtual = null
            rotuloDoAparelho = null
            b.vuRotulo.seMudou(getString(R.string.placa_nenhum_aparelho_rotulo))
            aparelho(getString(R.string.placa_nenhum_aparelho), getString(R.string.placa_procurar_de_novo) to { procurar() })
            naoPronto()
            return
        }
        if (escolhido.id != idAtual) falhaDaPrevia = null
        idAtual = escolhido.id
        val dev = devs.first { UsbDv.PREFIXO_DO_ID + it.deviceName == escolhido.id }
        rotuloDoAparelho = UsbDv.rotulo(t, dev)
        b.vuRotulo.seMudou(UsbDv.rotulo(t, dev))
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            aparelho(getString(R.string.placa_pede_camera_e_usb, UsbDv.rotulo(t, dev)),
                getString(R.string.placa_permitir_e_ver) to { permissaoDaCamera.launch(Manifest.permission.CAMERA) }, AvisoDaTela.Tipo.INFO)
            naoPronto()
            return
        }
        if (!usb.hasPermission(dev)) {
            if (pedirUsbJa) { pedirUsbJa = false; pedirPermissaoUsb(usb, dev) }
            aparelho(getString(R.string.placa_pede_usb, UsbDv.rotulo(t, dev)),
                getString(R.string.placa_permitir_usb) to { pedirPermissaoUsb(usb, dev) }, AvisoDaTela.Tipo.INFO)
            naoPronto()
            return
        }
        pedirUsbJa = false
        aparelhoPronto(UsbDv.rotulo(t, dev))
        pronto = true
        pedirPrevia(deNovo = false)
        desenhar()
    }

    /**
     * A primeira abertura diz o que o aparelho é: o "Vídeo USB (…)" vira "Placa de captura (…)" ou
     * "Filmadora DV (…)" sem refazer a busca (a prévia já está aberta).
     */
    private fun rotular() {
        if (!visivel || !pronto) return
        val usb = getSystemService(UsbManager::class.java) ?: return
        val dev = idAtual?.let { UsbDv.porId(usb, it) } ?: return
        rotuloDoAparelho = UsbDv.rotulo(t, dev)
        b.vuRotulo.seMudou(UsbDv.rotulo(t, dev))
        for (i in 0 until b.vuEscolha.childCount) {
            val rb = b.vuEscolha.getChildAt(i) as RadioButton
            (rb.tag as? String)?.let { UsbDv.porId(usb, it) }?.let { rb.text = UsbDv.rotulo(t, it) }
        }
        desenhar()
    }

    /** Com mais de um aparelho de vídeo no USB, a escolha; com um, nada. */
    private fun mostrarEscolha(devs: List<UsbDevice>, marcado: String?) {
        if (devs.size < 2) {
            b.vuEscolha.visibility = View.GONE
            if (b.vuEscolha.childCount > 0) b.vuEscolha.removeAllViews()
            return
        }
        montandoEscolha = true
        try { montarEscolha(devs, marcado) } finally { montandoEscolha = false }
    }

    /** A escolha refeita pela tela (e não pelo toque): o ouvinte da `RadioGroup` não age. */
    private var montandoEscolha = false

    private fun montarEscolha(devs: List<UsbDevice>, marcado: String?) {
        val ids = devs.map { UsbDv.PREFIXO_DO_ID + it.deviceName }
        val atuais = (0 until b.vuEscolha.childCount).map { b.vuEscolha.getChildAt(it).tag }
        b.vuEscolha.visibility = View.VISIBLE
        if (atuais != ids) {
            b.vuEscolha.removeAllViews()
            for ((d, id) in devs.zip(ids)) {
                b.vuEscolha.addView(RadioButton(this).apply {
                    this.id = View.generateViewId()
                    tag = id
                    text = UsbDv.rotulo(t, d)
                    textSize = 15f
                    setTextColor(Cores.TEXTO)
                    buttonTintList = ColorStateList.valueOf(Cores.ACENTO)
                    minHeight = dp(48)
                })
            }
        }
        for (i in 0 until b.vuEscolha.childCount) {
            val rb = b.vuEscolha.getChildAt(i) as RadioButton
            if (rb.tag == marcado && !rb.isChecked) rb.isChecked = true
        }
    }

    private fun semCamera() {
        val bloqueada = !ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.CAMERA)
        if (bloqueada) {
            aparelho(getString(R.string.placa_camera_bloqueada), getString(R.string.placa_abrir_ajustes) to {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData(Uri.fromParts("package", packageName, null)))
            }, AvisoDaTela.Tipo.VERMELHO)
        } else {
            aparelho(getString(R.string.placa_camera_negada),
                getString(R.string.placa_pedir_de_novo) to { permissaoDaCamera.launch(Manifest.permission.CAMERA) }, AvisoDaTela.Tipo.VERMELHO)
        }
        naoPronto()
    }

    private fun pedirPermissaoUsb(usb: UsbManager, d: UsbDevice) {
        val acao = "$packageName.PERMISSAO_USB_VIDEO"
        receptorDaPermissao?.let { runCatching { unregisterReceiver(it) } }
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                runCatching { unregisterReceiver(this) }
                if (receptorDaPermissao === this) receptorDaPermissao = null
                if (i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) procurar()
                else aparelho(getString(R.string.placa_sem_permissao_usb, VideoUsb.nome(t, UsbDv.conhecido(d))),
                    getString(R.string.placa_permitir_usb) to { pedirPermissaoUsb(usb, d) }, AvisoDaTela.Tipo.VERMELHO)
            }
        }
        receptorDaPermissao = r
        ContextCompat.registerReceiver(this, r, IntentFilter(acao), ContextCompat.RECEIVER_NOT_EXPORTED)
        // FLAG_MUTABLE: o sistema põe o aparelho e a resposta no Intent (como no Espelhar e no DVD).
        val pi = PendingIntent.getBroadcast(this, 4, Intent(acao).setPackage(packageName), PendingIntent.FLAG_MUTABLE)
        usb.requestPermission(d, pi)
    }

    // ---- a prévia ------------------------------------------------------------------------------

    private fun pedirPrevia(deNovo: Boolean) {
        if (vitrine != null) return
        val id = idAtual ?: return
        if (deNovo) falhaDaPrevia = null
        DonoDaPlaca.quererPrevia(DONO, this, id, aceitaDv = true, deNovo = deNovo) { motivo ->
            if (isDestroyed) return@quererPrevia
            Log.w(TAG, "a prévia parou: ${Log.erroExterno(motivo)}")
            falhaDaPrevia = motivo
            desenhar()
        }
    }

    // ---- o desenho -----------------------------------------------------------------------------

    /** O tipo do aparelho mostrado: pela fonte aberta, senão pelo lembrado por `vid:pid`. */
    private fun tipoAtual(): PainelDoVideoUsb.Tipo {
        vitrine?.let { return it.tipo }
        DonoDaPlaca.fonte?.takeIf { !it.desconectada }?.let {
            return if (it.mjpeg) PainelDoVideoUsb.Tipo.PLACA else PainelDoVideoUsb.Tipo.FILMADORA_DV
        }
        val usb = getSystemService(UsbManager::class.java) ?: return PainelDoVideoUsb.Tipo.DESCONHECIDO
        val dev = idAtual?.let { UsbDv.porId(usb, it) } ?: return PainelDoVideoUsb.Tipo.DESCONHECIDO
        return PainelDoVideoUsb.tipo(UsbDv.conhecido(dev))
    }

    private fun desenhar() {
        if (!visivel) return
        telaLigada.atualizar()
        val g = GravacaoBus.estado
        val m = MirrorBus.atual
        val tipo = tipoAtual()
        val transmissao = PainelDoVideoUsb.transmissao(m)
        val bt = PainelDoVideoUsb.botoes(t, PainelDoVideoUsb.Entrada(
            tipo = tipo, pronto = pronto, gravando = GravacaoBus.gravando, transmissao = transmissao,
            outraFonte = m.fonteRotulo, ouvindo = DonoDaPlaca.ouvindo,
        ))
        val comImagem = pronto || GravacaoBus.gravando || transmissao == PainelDoVideoUsb.Transmissao.ESTA
        desenharPilula(m, transmissao)
        desenharOpcoes(livre = !GravacaoBus.gravando && transmissao == PainelDoVideoUsb.Transmissao.NENHUMA)
        mudar(b.vuExplicacao, !comImagem)
        mudar(b.vuSecaoDaImagem, comImagem)
        // A superfície só existe com as permissões: sem elas, nada a desenhar (e o dono não abre).
        mudar(b.vuPrevia, pronto)
        val recado = falhaDaPrevia?.let { getString(R.string.placa_imagem_parou, it) }
        // Aberta e sem quadro (a tela ficava preta sem dizer por quê, §13.11): a fita parada, a placa sem sinal.
        val semImagem = if (recado == null && pronto) DonoDaPlaca.fonte?.takeIf { it.semQuadro && !it.desconectada }?.let {
            getString(if (it.mjpeg) R.string.placa_placa_sem_imagem else R.string.placa_filmadora_sem_imagem)
        } else null
        mudar(b.vuRecado, recado != null || semImagem != null)
        b.vuRecado.tipo = if (recado != null) AvisoDaTela.Tipo.VERMELHO else AvisoDaTela.Tipo.AMBAR
        texto(b.vuRecado, recado?.let { it + "\n" + getString(R.string.placa_toque_para_tentar) } ?: semImagem ?: "")
        b.vuRecado.setOnClickListener(if (recado != null) View.OnClickListener {
            if (!naVitrine()) { pedirPrevia(deNovo = true); desenhar() }
        } else null)

        mudar(b.vuBotoes, comImagem)
        mudar(b.vuBotoesDaImagem, comImagem && (bt.ouvirVisivel || bt.fotoVisivel))
        texto(b.vuGravar, bt.gravarTexto)
        b.vuGravar.isEnabled = bt.gravarHabilitado
        pintar(b.vuGravar, parar = GravacaoBus.gravando, icone = R.drawable.ic_q_gravar)
        texto(b.vuTransmitir, bt.transmitirTexto)
        b.vuTransmitir.isEnabled = bt.transmitirHabilitado
        pintar(b.vuTransmitir, parar = transmissao == PainelDoVideoUsb.Transmissao.ESTA, icone = R.drawable.ic_q_espelhar)
        mudar(b.vuOuvir, bt.ouvirVisivel)
        texto(b.vuOuvir, bt.ouvirTexto)
        mudar(b.vuFoto, bt.fotoVisivel)
        b.vuFoto.isEnabled = !fotografando
        mudar(b.vuNota, comImagem && bt.nota.isNotEmpty())
        texto(b.vuNota, bt.nota)

        val tg = PainelDoVideoUsb.textoDaGravacao(t, g)
        mudar(b.vuSecaoDaGravacao, tg.isNotEmpty())
        texto(b.vuGravacao, tg)

        val esp = PainelDoVideoUsb.espera(t, m)
        mudar(b.vuSecaoDaTransmissao, esp != null)
        if (esp != null) {
            texto(b.vuManchete, if (m.fase == MirrorBus.Fase.ESPERANDO && m.aliasNaRede.isNotBlank())
                "${m.aliasNaRede} · ${esp.manchete}" else esp.manchete)
            mudar(b.vuBlocoDoPin, esp.pin.isNotEmpty())
            b.vuPin.mostrar(esp.pin.filter { it.isDigit() })
            mudar(b.vuBlocoDoEndereco, esp.endereco.isNotEmpty())
            texto(b.vuEndereco, esp.endereco)
            b.vuEndereco.copiavel = esp.endereco.isNotEmpty() && !esp.semRede
            mudar(b.vuOutros, esp.outros.isNotEmpty() && !baixa)
            texto(b.vuOutros, esp.outros)
            mudar(b.vuPara, esp.para.isNotEmpty())
            texto(b.vuPara, esp.para)
            desenharSom(MicrofoneBus.atual)
        }
        ajustes.atualizar()
    }

    /**
     * A luz de estúdio: NO AR enviando; AGUARDANDO esperando o receptor ou sem aparelho pronto; REC
     * gravando; CONECTADO com a imagem. Gravando com a transmissão no ar, as duas (a segunda é o REC).
     */
    private fun desenharPilula(m: MirrorBus.Estado, t: PainelDoVideoUsb.Transmissao) {
        val gravando = GravacaoBus.gravando
        val e = when {
            t == PainelDoVideoUsb.Transmissao.ESTA && m.fase == MirrorBus.Fase.ESPELHANDO -> PilulaDeEstado.Estado.NO_AR
            t == PainelDoVideoUsb.Transmissao.ESTA -> PilulaDeEstado.Estado.AGUARDANDO
            gravando -> PilulaDeEstado.Estado.REC
            pronto && falhaDaPrevia == null -> PilulaDeEstado.Estado.CONECTADO
            else -> PilulaDeEstado.Estado.AGUARDANDO
        }
        b.vuPilula.mostrar(e)
        val rec = gravando && e != PilulaDeEstado.Estado.REC
        if (rec) b.vuPilulaRec.mostrar(PilulaDeEstado.Estado.REC)
        mudar(b.vuPilulaRec, rec)
    }

    /**
     * O botão de Gravar e o de Transmitir: no acento para começar, o perigo (o vermelho a 18 %, o texto
     * #FF8A80 e o quadradinho de parar) para parar o que está no ar.
     */
    private fun pintar(botao: MaterialButton, parar: Boolean, icone: Int) {
        if (botao.getTag(R.id.vuBotoes) == parar) return
        botao.setTag(R.id.vuBotoes, parar)
        botao.backgroundTintList = ContextCompat.getColorStateList(this,
            if (parar) R.color.q_perigo_fundo else R.color.botao_principal_fundo)
        val texto = ContextCompat.getColorStateList(this, if (parar) R.color.botao_perigo_texto else R.color.botao_principal_texto)
        botao.setTextColor(texto)
        botao.iconTint = texto
        botao.setIconResource(if (parar) R.drawable.ic_q_parar else icone)
    }

    /** O som da transmissão (na placa, "Som da placa", que começa ligado); o toque liga ou desliga. */
    private fun desenharSom(e: EstadoDoMicrofone) {
        val f = e.frase(Idioma.textos(this))
        mudar(b.vuSom, e.disponivel && f.isNotEmpty())
        texto(b.vuSom, getString(if (e.ligado) R.string.placa_som_tocar_para_desligar else R.string.placa_som_tocar_para_ligar, f))
        val icone = if (e.ligado) R.drawable.ic_q_mic else R.drawable.ic_q_mic_cortado
        if (b.vuSom.getTag(R.id.vuSom) != icone) {
            b.vuSom.setTag(R.id.vuSom, icone)
            b.vuSom.setCompoundDrawablesRelative(iconeTingido(icone, Cores.ACENTO_CLARO, dp(20)), null, null, null)
        }
    }

    private fun mudar(v: View, visivel: Boolean) {
        val vis = if (visivel) View.VISIBLE else View.GONE
        if (v.visibility != vis) v.visibility = vis
    }

    private fun texto(v: android.widget.TextView, t: String) {
        if (v.text.toString() != t) v.text = t
    }

    // ---- gravar --------------------------------------------------------------------------------

    private fun alternarGravacao() {
        if (GravacaoBus.gravando) { GravacaoDvService.parar(this); return }
        val id = idAtual ?: return
        // A placa que só dá o som pelo `AudioRecord` (fora do usbfs, §13.10): sem a permissão do
        // microfone, sai sem som. A pergunta vem antes (uma vez); a resposta não impede gravar.
        comMicrofoneSePlaca { GravacaoDvService.comecar(this, id) }
    }

    private fun comMicrofoneSePlaca(acao: () -> Unit) {
        if (tipoAtual() != PainelDoVideoUsb.Tipo.PLACA || DonoDaPlaca.somSemMicrofone ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        ) { acao(); return }
        depoisDoMicrofone = acao
        permissaoDoMicrofone.launch(Manifest.permission.RECORD_AUDIO)
    }

    // ---- transmitir ----------------------------------------------------------------------------

    private fun alternarTransmissao() {
        val tr = PainelDoVideoUsb.transmissao(MirrorBus.atual)
        if (tr == PainelDoVideoUsb.Transmissao.ESTA) { MirrorService.pedirParada(null); return }
        if (tr == PainelDoVideoUsb.Transmissao.OUTRA) return
        val id = idAtual ?: return
        val usb = getSystemService(UsbManager::class.java) ?: return
        val dev = UsbDv.porId(usb, id) ?: run { procurar(); return }
        comMicrofoneSePlaca {
            if (!com.quall.android.core.QuallNative.carregado) {
                Toast.makeText(this, R.string.placa_sem_nucleo, Toast.LENGTH_LONG).show()
                return@comMicrofoneSePlaca
            }
            b.vuMensagem.visibility = View.GONE
            transmissaoPedida = true
            // A mesma sessão do Espelhar com esta fonte: o `MirrorService` pega a posse da rede no dono
            // (a prévia já abriu o USB: nenhuma abertura nova).
            val i = Intent(this, MirrorService::class.java).apply {
                putExtra(MirrorService.EXTRA_SOURCE_KIND, MirrorService.SOURCE_CAMERA)
                putExtra(MirrorService.EXTRA_CAMERA_ID, id)
                putExtra(MirrorService.EXTRA_CAMERA_LABEL, UsbDv.rotulo(t, dev))
            }
            ContextCompat.startForegroundService(this, i)
        }
    }

    private var transmissaoNoAr = false

    private fun aoMudarATransmissao(e: MirrorBus.Estado) {
        val agora = PainelDoVideoUsb.transmissao(e) == PainelDoVideoUsb.Transmissao.ESTA
        // O fim da sessão (ou a recusa de abrir) pedida daqui, ou vista no ar daqui: a frase fica.
        if (!agora && (transmissaoNoAr || transmissaoPedida) &&
            (e.fase == MirrorBus.Fase.PARADO || e.fase == MirrorBus.Fase.ERRO)) {
            transmissaoPedida = false
            if (e.mensagem.isNotBlank()) {
                b.vuMensagem.visibility = View.VISIBLE
                b.vuMensagem.text = e.mensagem.replaceFirstChar { it.uppercase() }
            }
        }
        if (agora) transmissaoPedida = false
        transmissaoNoAr = agora
        desenhar()
    }

    private fun alternarSomDaTransmissao() {
        val e = MicrofoneBus.atual
        if (e.ligado) { MirrorService.pedirMicrofone(false); return }
        // O som da fita vem dentro do DV, e o da placa pelo usbfs: sem a pergunta do microfone.
        if (e.semMicrofone) { MirrorService.pedirMicrofone(true); return }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            MirrorService.pedirMicrofone(true)
        } else {
            depoisDoMicrofone = {
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    MirrorService.pedirMicrofone(true)
                }
            }
            permissaoDoMicrofone.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    // ---- o formato da placa (§14.4) ------------------------------------------------------------

    private var trocandoFormato = false

    private fun nomeDoFormato(f: String) = when (f) {
        "NV12", "YUY2" -> getString(R.string.placa_formato_sem_compressao, f)
        "MJPEG" -> getString(R.string.placa_formato_mjpeg)
        else -> f
    }

    /** O valor da linha dos quadros: a taxa, quem a faz, e o que chega de fato (vazio sem medida). */
    private fun valorDosQuadros(qps: Int, doQuall: Boolean, daPlaca: Int, chegando: String): String =
        qps.toString() + " " + (if (doQuall) getString(R.string.placa_qps_quall, daPlaca) else getString(R.string.placa_qps_nativo)) + chegando

    /** O texto do chip: formato · tamanho · quadros. */
    private fun chip(formato: String, largura: Int, altura: Int, qps: Int) =
        getString(R.string.placa_chip, formato, largura, altura, qps)

    private fun quadrosPorSegundo(intervalo: Long): String =
        if (intervalo <= 0) "?" else Math.round(10_000_000.0 / intervalo).toString()

    private fun lista(titulo: String, itens: List<String>, marcado: Int, aoEscolher: (Int) -> Unit) {
        android.app.AlertDialog.Builder(this).setTitle(titulo)
            .setSingleChoiceItems(itens.toTypedArray(), marcado) { d, i -> d.dismiss(); aoEscolher(i) }
            .setNegativeButton(R.string.cancelar, null).show()
    }

    /** Uma linha das opções da placa: o rótulo, o valor e o toque (`null`: só leitura). */
    private class OpcaoDaPlaca(val rotulo: String, val valor: String, val acao: (() -> Unit)?)

    /** As opções da placa aberta: o texto do chip (formato · tamanho · quadros) e as cinco linhas. */
    private class OpcoesDaPlaca(val chip: String, val linhas: List<OpcaoDaPlaca>, val pode: Boolean)

    private var opcoesVistas: OpcoesDaPlaca? = null

    /** O chip das opções na tela (com uma placa aberta), e a engrenagem com as linhas. */
    private fun desenharOpcoes(livre: Boolean) {
        val o = opcoesDaPlaca(livre)
        opcoesVistas = o
        mudar(b.vuOpcoes, o != null)
        if (o != null) {
            texto(b.vuOpcoes, o.chip + if (trocandoFormato) "  " + getString(R.string.placa_trocando) else "")
            b.vuOpcoes.contentDescription = getString(R.string.placa_opcoes_descricao, o.chip)
        }
    }

    /**
     * **As opções da placa, sempre listadas** (decisão do Pessoa Exemplo, 30/09): o formato, o tamanho e os
     * quadros por segundo que ela oferece, e o codec e a qualidade da gravação. Mudar as três primeiras
     * fecha e reabre a placa; com a gravação ou a transmissão no ar, as linhas ficam apagadas. Desde a
     * rodada do R16 (30/09) elas moram na engrenagem ([montarAjustes]); na tela, o chip.
     */
    private fun opcoesDaPlaca(livre: Boolean): OpcoesDaPlaca? {
        vitrine?.let { v ->
            val o = v.opcoes?.takeIf { v.pronto } ?: return null
            val q = valorDosQuadros(o.quadros, o.quadros != o.quadrosDaPlaca, o.quadrosDaPlaca,
                if (o.chegando > 0) " · " + getString(R.string.placa_chegando, o.chegando) else "")
            val toque = { naVitrine(); Unit }
            return OpcoesDaPlaca(chip(o.formato, o.largura, o.altura, o.quadros), listOf(
                OpcaoDaPlaca(getString(R.string.placa_op_formato), nomeDoFormato(o.formato), toque),
                OpcaoDaPlaca(getString(R.string.placa_op_tamanho), "${o.largura}×${o.altura}", toque),
                OpcaoDaPlaca(getString(R.string.placa_op_quadros), q, toque),
                OpcaoDaPlaca(getString(R.string.placa_op_codec), getString(com.quall.android.capture.dv.GravacaoDaPlaca.codec(this).rotulo), toque),
                OpcaoDaPlaca(getString(R.string.placa_op_qualidade), getString(com.quall.android.capture.dv.GravacaoDaPlaca.qualidade(this).rotulo), toque),
            ), pode = livre)
        }
        val f = DonoDaPlaca.fonte?.takeIf { pronto && it.mjpeg && !it.desconectada } ?: return null
        val dev = f.aparelhoUsb
        val ofertas = f.ofertas
        val pode = livre && !trocandoFormato && dev != null
        val codec = com.quall.android.capture.dv.GravacaoDaPlaca.codec(this)
        val qualidade = com.quall.android.capture.dv.GravacaoDaPlaca.qualidade(this)
        val taxa = com.quall.android.capture.dv.GravacaoDaPlaca.taxaEscolhida(
            f.larguraDoQuadro, f.alturaDoQuadro, f.quadrosPorSegundo, codec, qualidade)
        fun aplicar(p: com.quall.android.capture.dv.Preferencia) {
            if (dev == null) return
            UsbDv.preferir(dev, p)
            trocandoFormato = true
            desenhar()
            DonoDaPlaca.reabrirPrevia(this) { reabriu ->
                trocandoFormato = false
                if (!isDestroyed) {
                    if (!reabriu) Toast.makeText(this, R.string.placa_nao_abriu_com_a_escolha, Toast.LENGTH_LONG).show()
                    desenhar()
                }
            }
        }
        // O tamanho e o intervalo mais perto do que está aberto, dentro do que a lista oferece.
        fun maisPerto(lista: List<com.quall.android.capture.dv.Oferta>) = lista.minByOrNull {
            Math.abs(it.largura.toLong() * it.altura - f.larguraDoQuadro.toLong() * f.alturaDoQuadro)
        }
        fun intervaloPerto(o: com.quall.android.capture.dv.Oferta) =
            o.intervalos.minByOrNull { Math.abs(it - f.intervaloAberto) } ?: 0L
        val formatos = ofertas.map { it.formato }.distinct()
        val tamanhos = ofertas.filter { it.formato == f.formatoAberto }.sortedByDescending { it.largura.toLong() * it.altura }
        val aberta = tamanhos.firstOrNull { it.largura == f.larguraDoQuadro && it.altura == f.alturaDoQuadro }
        val taxas = com.quall.android.capture.dv.TaxasDeQuadros.cardapio(aberta?.intervalos.orEmpty())
        // "(Nativo)": a taxa que a placa manda; "(Quall)": o Quall a tira de uma taxa maior da placa,
        // soltando os quadros a mais (o pedido do Pessoa Exemplo, 30/09).
        fun nomeDaTaxa(taxa: com.quall.android.capture.dv.TaxaDeQuadros) =
            getString(R.string.placa_taxa_por_segundo, taxa.fps) + " " +
                getString(if (taxa.daPlaca) R.string.placa_qps_nativo else R.string.placa_qps_so_quall)
        val linhas = listOf(
            OpcaoDaPlaca(getString(R.string.placa_op_formato), nomeDoFormato(f.formatoAberto), if (formatos.isEmpty()) null else ({
                lista(getString(R.string.placa_op_formato), formatos.map { nomeDoFormato(it) }, formatos.indexOf(f.formatoAberto)) { i ->
                    val o = maisPerto(ofertas.filter { it.formato == formatos[i] })
                    if (o != null) aplicar(com.quall.android.capture.dv.Preferencia(formatos[i], o.largura, o.altura, intervaloPerto(o), f.fpsAlvo))
                }
            })),
            OpcaoDaPlaca(getString(R.string.placa_op_tamanho), "${f.larguraDoQuadro}×${f.alturaDoQuadro}", if (tamanhos.isEmpty()) null else ({
                lista(getString(R.string.placa_op_tamanho), tamanhos.map { "${it.largura}×${it.altura}" }, tamanhos.indexOf(aberta)) { i ->
                    val o = tamanhos[i]
                    aplicar(com.quall.android.capture.dv.Preferencia(f.formatoAberto, o.largura, o.altura, intervaloPerto(o), f.fpsAlvo))
                }
            })),
            OpcaoDaPlaca(getString(R.string.placa_op_quadros), valorDosQuadros(f.quadrosPorSegundo, f.fpsAlvo > 0, f.quadrosDaPlaca,
                // O que chega de fato (a janela de 2 s da fonte); some sem medida, e diz "nenhum" parada.
                when {
                    f.semQuadro -> " · " + getString(R.string.placa_chegando_nenhum)
                    f.quadrosChegando > 0 -> " · " + getString(R.string.placa_chegando, f.quadrosChegando)
                    else -> ""
                }), if (taxas.isEmpty() || aberta == null) null else ({
                lista(getString(R.string.placa_op_quadros), taxas.map { nomeDaTaxa(it) }, taxas.indexOfFirst { it.fps == f.quadrosPorSegundo }) { i ->
                    val t = taxas[i]
                    aplicar(com.quall.android.capture.dv.Preferencia(f.formatoAberto, aberta.largura, aberta.altura,
                        t.intervaloDaPlaca, if (t.daPlaca) 0 else t.fps))
                }
            })),
            OpcaoDaPlaca(getString(R.string.placa_op_codec), getString(codec.rotulo)) {
                val todos = com.quall.android.capture.dv.GravacaoDaPlaca.Codec.values().toList()
                lista(getString(R.string.placa_op_codec), todos.map { getString(it.rotulo) }, todos.indexOf(codec)) { i ->
                    com.quall.android.capture.dv.GravacaoDaPlaca.escolher(this, todos[i]); desenhar()
                }
            },
            OpcaoDaPlaca(getString(R.string.placa_op_qualidade), getString(R.string.placa_qualidade_e_taxa, getString(qualidade.rotulo), taxa / 1e6)) {
                val todas = com.quall.android.capture.dv.GravacaoDaPlaca.Qualidade.values().toList()
                lista(getString(R.string.placa_op_qualidade), todas.map { getString(it.rotulo) }, todas.indexOf(qualidade)) { i ->
                    com.quall.android.capture.dv.GravacaoDaPlaca.escolher(this, todas[i]); desenhar()
                }
            },
        )
        return OpcoesDaPlaca(chip(f.formatoAberto, f.larguraDoQuadro, f.alturaDoQuadro, f.quadrosPorSegundo), linhas, pode)
    }

    /**
     * **A engrenagem** (o R16, 30/09): as cinco opções da placa aberta (apagadas gravando ou
     * transmitindo, como eram na tela) e as notas que moravam no pé da tela.
     */
    private fun montarAjustes(f: FolhaDaTela) {
        f.manterTelaLigada()
        val o = opcoesVistas
        f.secao(getString(R.string.placa_secao_opcoes))
        if (o == null) {
            f.nota(getString(R.string.placa_nota_opcoes_sem_placa))
        } else {
            for ((i, l) in o.linhas.withIndex()) {
                f.linha(l.rotulo, l.valor + if (i == 0 && trocandoFormato) " " + getString(R.string.placa_trocando) else "", ativa = o.pode && l.acao != null, acao = l.acao)
            }
            f.nota(getString(if (o.pode) R.string.placa_nota_opcoes_reabre else R.string.placa_nota_opcoes_apagadas))
        }
        // Os endereços da transmissão (deitado, os outros não cabem na tela).
        val enderecos = MirrorBus.atual.takeIf { PainelDoVideoUsb.espera(t, it) != null }?.enderecos.orEmpty()
        if (enderecos.isNotEmpty()) {
            f.secao(getString(R.string.placa_secao_enderecos))
            for ((i, e) in enderecos.withIndex()) f.linha(getString(if (i == 0) R.string.placa_endereco else R.string.placa_tambem), e)
        }
        f.secao(getString(R.string.placa_secao_sobre))
        f.nota(getString(R.string.placa_nota_sobre))
    }

    // ---- ouvir e foto --------------------------------------------------------------------------

    private fun alternarOuvir() {
        if (DonoDaPlaca.ouvindo) { DonoDaPlaca.ouvir(this, false) { _, _ -> desenhar() }; return }
        val ligar = {
            DonoDaPlaca.ouvir(this, true) { _, porque ->
                if (!isDestroyed) {
                    desenhar()
                    if (porque != null) Toast.makeText(this, getString(R.string.placa_nao_deu_para_ouvir, porque), Toast.LENGTH_LONG).show()
                }
            }
        }
        // A fita (o som dentro do DV) e a placa lida pelo usbfs não passam pelo microfone: sem pergunta.
        if (DonoDaPlaca.somSemMicrofone || ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            ligar()
        } else {
            depoisDoMicrofone = {
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) ligar()
                else Toast.makeText(this, R.string.placa_ouvir_sem_microfone, Toast.LENGTH_LONG).show()
            }
            permissaoDoMicrofone.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    private fun tirarFoto() {
        if (fotografando) return
        fotografando = true
        desenhar()
        DonoDaPlaca.foto(this) { nome, porque ->
            fotografando = false
            if (isDestroyed) return@foto
            desenhar()
            Toast.makeText(this, if (nome != null) getString(R.string.placa_foto_salva) else getString(R.string.placa_foto_nao_saiu, porque),
                if (nome != null) Toast.LENGTH_SHORT else Toast.LENGTH_LONG).show()
        }
    }

    companion object {
        private const val TAG = "QuallDv"
        /** A chave desta tela no [DonoDaPlaca] (a de Espelhar é outra). */
        private const val DONO = "tela-do-video-usb"
    }
}
