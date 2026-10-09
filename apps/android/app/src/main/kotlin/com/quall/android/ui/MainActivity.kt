package com.quall.android.ui

import com.quall.android.capturaUsbPossivel

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Point
import android.hardware.usb.UsbManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.TypedValue
import android.view.View
import android.widget.RadioButton
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.LinearLayoutManager
import com.quall.android.capture.CameraCaptureService
import com.quall.android.capture.CameraEnumerator
import com.quall.android.capture.dv.DonoDaPlaca
import com.quall.android.capture.dv.GravacaoBus
import com.quall.android.capture.dv.GravacaoDvService
import com.quall.android.capture.dv.PreviaDv
import com.quall.android.capture.dv.QuallDv
import com.quall.android.capture.dv.UsbDv
import com.quall.android.capture.CaptureBus
import com.quall.android.capture.PreviaDaCamera
import com.quall.android.capture.ScreenCaptureService
import com.quall.android.core.Idioma
import com.quall.android.core.DeviceIdentity
import com.quall.android.core.QuallBrowser
import com.quall.android.core.QuallNative
import com.quall.android.databinding.ActivityMainBinding
import com.quall.android.discovery.MulticastLockManager
import com.quall.android.discovery.MulticastProbe
import com.quall.android.R
import com.quall.android.capture.PreviaDoDono
import com.quall.android.mirror.EstadoDoMicrofone
import com.quall.android.mirror.GravacaoDaTelaBus
import com.quall.android.mirror.MicrofoneBus
import com.quall.android.teleprompter.DecisaoDaGravacao
import com.quall.android.mirror.MirrorBus
import com.quall.android.mirror.MirrorService
import kotlin.concurrent.thread

/**
 * Fluxo do produto, conforme `docs/fluxo-de-uso.md`:
 *
 *   **quem espelha anuncia e espera; quem exibe escolhe na lista e conecta.**
 *   **a origem é escolhida antes do PIN**, e fica fixa pela sessão.
 *
 * Do lado do emissor — que é o que este marco entrega — o fluxo é: escolher a origem (tela ou uma
 * câmera) → tocar em "Espelhar" → consentimento do sistema (só para a tela) ou permissão de
 * câmera (só na primeira vez) → tela de espera. Ela é a peça central: PIN, alias na rede, IP para
 * digitar, o que fazer do outro lado, e um Cancelar que funciona de verdade. Sem ela o usuário
 * concede gravação de tela (ou permite a câmera), vê o indicador do sistema, e não sabe se está
 * esperando ou travado.
 *
 * A seção de verificação sem rede (sidecar, teste de IDR, MulticastLock) continua embaixo. Ela
 * não faz parte do fluxo do usuário; é instrumento de bancada, e está separada por isso.
 */
class MainActivity : AppCompatActivity() {
    companion object {
        /**
         * A última mensagem de fim de espelhamento já mostrada na caixa de aviso de Espelhar: no
         * processo, e não na tela, para uma tela recriada (a volta do segundo plano) ainda mostrar a
         * que não viu, e uma já vista não voltar a cada abertura.
         */
        private var mensagemDoFimVista = ""

        private const val ESTADO_NA_ESPELHAR = "na_espelhar"

        /** A marca da caixa da placa quando ela oferece pedir a permissão (some quando a permissão vem). */
        private const val RECADO_DA_PERMISSAO = "permissao"

        /** A chave da prévia parada de Espelhar no [DonoDaPlaca] (a tela do vídeo USB tem a dela). */
        private const val DONO_DA_PREVIA = "espelhar"
    }

    private lateinit var binding: ActivityMainBinding
    private lateinit var multicastLock: MulticastLockManager
    private lateinit var deviceAdapter: DeviceListAdapter
    private lateinit var eu: DeviceIdentity
    private lateinit var telaLigada: TelaLigada

    private var pendingMode: String? = null

    /** O pedido em curso é de gravação, e não de espelhamento (o mesmo caminho de permissões). */
    private var pendingGravacao = false

    /** O pedido em curso é só a prévia parada da placa: as permissões, e nada de espelhar. */
    private var pendingPrevia = false

    /** Entre `onStart` e `onStop`: a prévia parada da placa só existe com a tela à vista. */
    private var telaVisivel = false

    /** O receptor da resposta do diálogo de permissão USB da filmadora, enquanto ele está aberto. */
    private var receptorUsb: BroadcastReceiver? = null

    /** A câmera aguardando permissão, ou a que o teste de bancada vai usar. */
    private var pendingCamera: CameraEnumerator.CameraOption? = null

    /** Consentimento de gravação de tela. Aparece a cada sessão; não há como suprimir. */
    private val screenCapturePermission = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result -> onProjectionResult(result) }

    private val notificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* prossegue de qualquer jeito: a notificação é cosmética, a captura não depende dela */ }

    /** O botão do microfone da câmera (R5, fase 2): a permissão no primeiro toque. */
    private val botaoDoMicrofone = BotaoDoMicrofone(this)

    // --- a gravação da câmera comum (§8.6 do `teleprompter-com-camera.md`) -----------------------

    private val principal = android.os.Handler(android.os.Looper.getMainLooper())

    /** A última recusa e a última parada já mostradas (cada uma uma vez). */
    private var recusaVista = 0L
    private var paradaVista = ""

    /** A orientação travada por nós enquanto grava (um arquivo só, §5.2). */
    private var orientacaoTravada = false

    /**
     * Os três controles redondos da câmera no ar (`docs/telas-estudio.md` §6.5): o microfone, o Gravar
     * da câmera comum e o parar.
     */
    private lateinit var microfoneDaCamera: MicrofoneRedondo
    private lateinit var gravarDaCamera: GravarRedondo
    private lateinit var pararDaCamera: PararRedondo

    /**
     * O Gravar da placa na tela da transmissão (§11, item 4): a placa grava e transmite junto, e o
     * "Gravar" do painel fica embaixo da tela de espera. Liga e desliga o `GravacaoDvService`, e
     * mostra o estado do [GravacaoBus]. Mora na mesma casa do Gravar da câmera (um de cada vez).
     */
    private lateinit var gravarDaPlaca: GravarRedondo

    /** A folha de Ajustes (a engrenagem do Início e de Espelhar), criada uma vez só (§11.3). */
    private lateinit var folha: FolhaDeAjustes

    /**
     * O último anúncio que a espera viu: a mensagem do serviço diz "anunciando como…" ou "sem anúncio
     * mDNS…" ao começar a esperar, e é trocada depois (a tentativa anterior, a câmera parada). A frase
     * da instrução (§6.4) segue o último visto.
     */
    private var anunciaNaRede = true

    /** O "Ouvir" da placa na tela da transmissão (§11, item 5); o da home é o `buttonOuvirPlaca`. */
    private lateinit var ouvirDaPlaca: BotaoDaPlaca

    /** A "Foto" da placa na tela da transmissão (§11, item 6); a da home é o `buttonFotoPlaca`. */
    private lateinit var fotoDaPlaca: BotaoDaPlaca

    /** A permissão do microfone para ouvir a placa (o som dela é um `AudioRecord`). */
    private val permissaoDoOuvir = registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) aplicarOuvir(true)
        else Toast.makeText(this, getString(R.string.in_ouvir_sem_permissao), Toast.LENGTH_LONG).show()
    }

    /**
     * O indicador anda de segundo em segundo enquanto a tela está à vista; e a espera acompanha a
     * câmera que começa a entregar ("Abrindo a câmera…" → o PIN), que não passa pelo `MirrorBus`.
     */
    private val tiqueDaGravacao = object : Runnable {
        override fun run() {
            desenharGravacaoDaCamera()
            if (binding.mirrorOverlay.visibility == View.VISIBLE) {
                MirrorBus.atual.takeIf { it.fase == MirrorBus.Fase.ESPERANDO || it.fase == MirrorBus.Fase.ESPELHANDO }
                    ?.let { desenharBlocoDaEspera(it) }
            }
            principal.postDelayed(this, 500)
        }
    }

    /**
     * A superfície da prévia da câmera comum pelo dono (§8.6): o divisor desenha nela. Só quem
     * ligou solta ([PreviaDoDono]); a câmera não sabe que a superfície veio ou foi.
     */
    private val previaDoDono = object : android.view.SurfaceHolder.Callback {
        override fun surfaceCreated(holder: android.view.SurfaceHolder) {
            PreviaDoDono.ligar(holder.surface, this@MainActivity, daTelaR5 = false)
        }
        override fun surfaceChanged(holder: android.view.SurfaceHolder, formato: Int, largura: Int, altura: Int) = Unit
        override fun surfaceDestroyed(holder: android.view.SurfaceHolder) {
            PreviaDoDono.soltar(this@MainActivity)
        }
    }

    private val cameraPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { concedida -> onCameraPermissionResult(concedida) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        telaLigada = TelaLigada(this) {
            MirrorBus.atual.fase.let { it == MirrorBus.Fase.ESPERANDO || it == MirrorBus.Fase.ESPELHANDO } ||
                GravacaoBus.gravando || GravacaoDaTelaBus.atual.ocupada
        }
        // **De ponta a ponta** (targetSdk 36 obriga): as barras do sistema e o recorte recuam o conteúdo
        // das três telas — sem isto "Licenças de terceiros" ficava sob a barra de navegação (a
        // conferência de 28/09 no A07). A prévia da câmera continua de ponta a ponta, só o texto recua.
        androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val r = insets.getInsets(
                androidx.core.view.WindowInsetsCompat.Type.systemBars() or
                    androidx.core.view.WindowInsetsCompat.Type.displayCutout(),
            )
            for (v in listOf(binding.modoScroll, binding.homeScroll, binding.mirrorRolagem)) {
                v.setPadding(r.left, r.top, r.right, r.bottom)
                v.clipToPadding = false
            }
            insets
        }
        // Espelhar à mostra sobrevive a uma recriação (o tema, o tamanho da letra) — a revisão de 28/09.
        naEspelhar = savedInstanceState?.getBoolean(ESTADO_NA_ESPELHAR, false) ?: false
        idiomaDaCriacao = resources.configuration.locales[0]?.toLanguageTag()

        eu = DeviceIdentity.load(this)
        multicastLock = MulticastLockManager(this)
        deviceAdapter = DeviceListAdapter(detalhado = true) { onDeviceTapped(it) }
        binding.recyclerDevices.layoutManager = LinearLayoutManager(this)
        binding.recyclerDevices.adapter = deviceAdapter

        // O Início e Espelhar, no "Estúdio de bolso" (`docs/telas-estudio.md` §6.1, §6.2). A descrição
        // técnica do aparelho e "Licenças de terceiros" foram para a folha de Ajustes.
        binding.textCoreState.text = descreverNucleo()
        binding.textCoreState.visibility = if (QuallNative.carregado) View.GONE else View.VISIBLE
        // O núcleo que não carregou é o motivo de nada funcionar: o Aviso vermelho no lugar do rodapé.
        if (!QuallNative.carregado) {
            binding.capsulaDaRede.visibility = View.GONE
            binding.textNotaDosPares.visibility = View.GONE
        }
        binding.textNomeNaRede.text = eu.displayName
        binding.textNomeDoAparelho.text = eu.displayName
        binding.cardEspelhar.setOnClickListener { mostrarEspelhar(true) }
        binding.buttonVoltarDoEspelhar.setOnClickListener { mostrarEspelhar(false) }
        onBackPressedDispatcher.addCallback(this, voltarAEscolha)
        folha = FolhaDeAjustes(this, eu).apply { aoMudarAQualidade = { aplicarEstadoDoCardapio() } }
        binding.buttonAjustesInicio.setOnClickListener { folha.mostrar() }
        desenharSeletorDeIdioma()
        binding.seletorDeIdioma.setOnClickListener {
            // No 13+ o sistema entrega a troca por `onConfigurationChanged` (abaixo), que recria. No 9–12
            // o AppCompat também pode entregar ali, na mesma chamada: [recriandoPeloIdioma] evita a
            // segunda recriação, e esta garante a primeira.
            recriandoPeloIdioma = Build.VERSION.SDK_INT < 33
            Idioma.escolher(this, if (Idioma.codigo(this) == Idioma.PT) Idioma.EN else Idioma.PT)
            if (Build.VERSION.SDK_INT < 33) recreate()
        }
        binding.buttonAjustesEspelhar.setOnClickListener { folha.mostrar() }
        binding.chipQualidade.setOnClickListener { folha.mostrar() }
        // Com um Aviso à vista, a espera mostra o ícone sem os anéis (§11.1).
        binding.avisosDaEspera.aoReorganizar = {
            binding.aneisDaEspera.comAneis = binding.avisosDaEspera.pedidos == 0
        }

        // O que já se viu de cada vídeo USB (placa ou filmadora) antes de a lista ser montada.
        UsbDv.lembrarEm(this)
        popularFontesDeCamera()
        configurarToqueSecretoDeDiagnostico()
        binding.mirrorPreviaDv.holder.addCallback(PreviaDv)
        binding.mirrorPreviaDono.holder.addCallback(previaDoDono)
        montarAjustesDaCamera()
        val noMeio = android.widget.FrameLayout.LayoutParams(
            android.widget.FrameLayout.LayoutParams.WRAP_CONTENT, android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
            android.view.Gravity.CENTER,
        )
        microfoneDaCamera = MicrofoneRedondo(this).apply {
            setOnClickListener { botaoDoMicrofone.alternar() }
            visibility = View.GONE
        }
        binding.casaDoMicrofone.addView(microfoneDaCamera, android.widget.FrameLayout.LayoutParams(noMeio))
        gravarDaCamera = GravarRedondo(this).apply {
            setOnClickListener { alternarGravacaoDaCamera() }
            // "Tentar mesmo assim" (a D1, §14.3): o toque longo no Gravar apagado esquece as falhas.
            setOnLongClickListener { tentarGravarMesmoAssim() }
            visibility = View.GONE
        }
        binding.casaDoGravar.addView(gravarDaCamera, android.widget.FrameLayout.LayoutParams(noMeio))
        gravarDaPlaca = GravarRedondo(this).apply {
            setOnClickListener { if (GravacaoBus.gravando) GravacaoDvService.parar(this@MainActivity) else comecarGravacaoDv() }
            visibility = View.GONE
        }
        binding.casaDoGravar.addView(gravarDaPlaca, android.widget.FrameLayout.LayoutParams(noMeio))
        pararDaCamera = PararRedondo(this).apply { setOnClickListener { pararEspelhamento() } }
        binding.casaDoParar.addView(pararDaCamera, android.widget.FrameLayout.LayoutParams(noMeio))
        ouvirDaPlaca = BotaoDaPlaca(this).apply {
            setOnClickListener { alternarOuvir() }
            visibility = View.GONE
            atualizar(getString(R.string.in_ouvir), descricao = getString(R.string.in_ouvir_descricao))
        }
        binding.linhaDaPlacaNoAr.addView(ouvirDaPlaca)
        binding.buttonOuvirPlaca.setOnClickListener { alternarOuvir() }
        fotoDaPlaca = BotaoDaPlaca(this).apply {
            setOnClickListener { tirarFoto() }
            visibility = View.GONE
            atualizar(getString(R.string.in_foto), descricao = getString(R.string.in_foto_descricao))
        }
        binding.linhaDaPlacaNoAr.addView(fotoDaPlaca, android.widget.LinearLayout.LayoutParams(
            android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { leftMargin = dp(8) })
        binding.buttonFotoPlaca.setOnClickListener { tirarFoto() }
        binding.gravacaoPreviaDv.holder.addCallback(PreviaDv)
        binding.placaPreviaDv.holder.addCallback(PreviaDv)
        binding.buttonGravarDv.setOnClickListener { comecarGravacaoDv() }
        binding.buttonPararGravacao.setOnClickListener { GravacaoDvService.parar(this) }
        binding.radioGroupFonte.setOnCheckedChangeListener { _, _ ->
            atualizarBotaoGravar()
            aplicarEstadoDoCardapio()
            atualizarPreviaDaPlaca()
        }
        // Um vídeo que ficou pendente de uma gravação interrompida vai para a Galeria.
        thread(name = "quall-pendentes") {
            // A consulta ao `MediaCodecList` da mensagem "não grava" (§14.3), fora da principal.
            // Embrulhado como no serviço (a revisão do código da D1, 10): um `SecurityException` do
            // `ContentResolver` aqui não pode derrubar o processo.
            runCatching {
                com.quall.android.mirror.GravacaoIndisponivel.aquecer()
                GravacaoDvService.publicarPendentes(applicationContext)
                com.quall.android.receive.GravadorRecebido.recuperarAndroid9(applicationContext)
            }.onFailure { com.quall.android.core.LogSeguro.w("QuallMirror", "pendentes: ${com.quall.android.core.LogSeguro.erroExterno(it.message)}") }
        }

        binding.buttonMirror.setOnClickListener { comecarEspelhamento() }
        binding.buttonReceive.setOnClickListener { abrirReceptor(null) }
        binding.buttonPrompter.setOnClickListener { abrirTeleprompter(PrompterActivity::class.java) }
        binding.buttonControle.setOnClickListener { abrirTeleprompter(ControleActivity::class.java) }
        binding.buttonPrompterComCamera.setOnClickListener { abrirTeleprompter(PrompterComCameraActivity::class.java) }
        // O DVD para MP4 (`docs/dvd-para-mp4.md` §2.9): a `libqualldv` só existe em arm64, e o leitor é
        // um aparelho USB. A pergunta é barata (sem carregar a `.so` na principal).
        val dvdPossivel = capturaUsbPossivel && "arm64-v8a" in Build.SUPPORTED_ABIS &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
        // A placa de captura e a filmadora (`docs/placa-de-captura-usb.md` §13): a mesma `libqualldv`. Os
        // dois ladrilhos da "CAPTURA PELO USB" aparecem juntos, com o rótulo.
        binding.secaoUsb.visibility = if (dvdPossivel) View.VISIBLE else View.GONE
        binding.cardConverterDvd.setOnClickListener { startActivity(Intent(this, ConversaoDvdActivity::class.java)) }
        binding.cardVideoUsb.setOnClickListener { startActivity(Intent(this, VideoUsbActivity::class.java)) }
        binding.buttonMirrorCancel.setOnClickListener { pararEspelhamento() }
        arrumarOrientacao()

        binding.buttonDiscover.setOnClickListener { procurarAparelhos() }
        binding.buttonCaptureScreen.setOnClickListener { startCapture(ScreenCaptureService.MODE_SIDECAR) }
        binding.buttonIdrTest.setOnClickListener { startCapture(ScreenCaptureService.MODE_IDR_TEST) }
        binding.buttonCaptureCamera.setOnClickListener { startCameraSidecarTest() }
        binding.buttonMulticastTest.setOnClickListener { runMulticastTest(withLock = true) }
        binding.buttonMulticastTestNoLock.setOnClickListener { runMulticastTest(withLock = false) }

        ensureNotificationPermission()
    }

    // --- a escolha do papel e Espelhar ---------------------------------------------------------

    /**
     * Espelhar à mostra (a segunda tela) ou a escolha do papel (a primeira). Como no iOS, a escolha
     * **não é lembrada** entre aberturas — mas com uma sessão no ar a tela de espera cobre as duas, e
     * quando ela termina a pessoa volta a Espelhar, que é de onde ela partiu.
     */
    private var naEspelhar = false

    /** O voltar do sistema em Espelhar volta à escolha (o "‹ Voltar" do iOS). */
    private val voltarAEscolha = object : androidx.activity.OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = mostrarEspelhar(false)
    }

    private fun mostrarEspelhar(sim: Boolean) {
        naEspelhar = sim
        if (binding.mirrorOverlay.visibility != View.VISIBLE) mostrarHome()
        atualizarPreviaDaPlaca()
    }

    /** A home (a escolha ou Espelhar), quando não há sessão no ar. */
    private fun mostrarHome() {
        if (idiomaPendente && !sessaoNoAr()) {
            idiomaPendente = false
            recreate()
            return
        }
        binding.modoScroll.visibility = if (naEspelhar) View.GONE else View.VISIBLE
        binding.homeScroll.visibility = if (naEspelhar) View.VISIBLE else View.GONE
        voltarAEscolha.isEnabled = naEspelhar
    }

    /** A sessão no ar cobre a home; ao terminar, volta a Espelhar. */
    private fun esconderHome() {
        naEspelhar = true
        binding.modoScroll.visibility = View.GONE
        binding.homeScroll.visibility = View.GONE
        voltarAEscolha.isEnabled = false
    }

    /**
     * O IP para a outra pessoa digitar: a linha da rede de Espelhar ("Wi-Fi · {ip}", "Cabo USB · {ip}",
     * ou "Sem rede" com o Aviso âmbar) e o rodapé do Início (a bolinha verde com rede, âmbar sem).
     */
    private fun desenharRede() {
        // Enumeração fora da principal. A mesma escolha da espera: IPv4 antes de IPv6, sem
        // confundir VPN/celular/CLAT com a rede por onde o outro aparelho consegue discar.
        thread(name = "quall-rede-da-tela") {
            val achado = com.quall.android.core.EnderecosLocais.listar().firstOrNull()
            val pares = EstadoDasTelas.paresDaVitrine ?: eu.temParesConhecidos()
            runOnUiThread { if (!isDestroyed) desenharRede(achado?.ip, achado?.interfaceNome.orEmpty(), pares) }
        }
    }

    private fun desenharRede(ip: String?, interfaceDeRede: String, pares: Boolean) {
        if (ip != null) {
            val i = interfaceDeRede.lowercase()
            val cabo = i.startsWith("rndis") || i.startsWith("usb") || i.startsWith("ncm") || i.startsWith("eth")
            val nome = when {
                i.startsWith("rndis") || i.startsWith("usb") || i.startsWith("ncm") -> getString(R.string.in_rede_cabo_usb)
                i.startsWith("eth") -> getString(R.string.in_rede_cabo)
                else -> getString(R.string.in_rede_wifi)
            }
            binding.iconeDaRede.setImageResource(if (cabo) R.drawable.ic_q_cabo else R.drawable.ic_q_wifi)
            binding.iconeDaRede.imageTintList = android.content.res.ColorStateList.valueOf(Cores.TEXTO2)
            binding.textIpNestaRede.text = android.text.SpannableString("$nome · $ip").apply {
                setSpan(android.text.style.TypefaceSpan("monospace"), nome.length + 3, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            binding.avisoSemRede.visibility = View.GONE
        } else {
            binding.iconeDaRede.setImageResource(R.drawable.ic_q_sem_rede)
            binding.iconeDaRede.imageTintList = android.content.res.ColorStateList.valueOf(Cores.TEXTO2)
            binding.textIpNestaRede.text = getString(R.string.in_sem_rede)
            binding.avisoSemRede.visibility = View.VISIBLE
        }
        binding.bolinhaDaRede.background = bolinha(if (ip != null) Cores.CONECTADO else Cores.AGUARDANDO)
        binding.bolinhaDaLinhaDeRede.background = bolinha(if (ip != null) Cores.CONECTADO else Cores.AGUARDANDO)
        binding.textIpDoRodape.text = ip ?: getString(R.string.in_sem_rede_minuscula)
        binding.capsulaDaRede.contentDescription =
            if (ip != null) getString(R.string.in_rede_descricao, eu.displayName, ip)
            else getString(R.string.in_rede_descricao_sem_rede, eu.displayName)
        binding.textNotaDosPares.text = getString(if (pares) R.string.in_nota_com_pares else R.string.in_nota_sem_pares)
    }

    /**
     * A paisagem em duas colunas (`docs/telas-estudio.md` §11.1), **só na tela baixa** ([telaBaixa], 30/09:
     * o celular deitado; o tablet deitado fica numa coluna centrada, como em pé): `ColunasDaTela` decide pela
     * configuração; aqui só os cartões do Início ficam mais baixos, para caber na altura, e a espera se
     * redesenha (os controles da câmera viram coluna na borda direita).
     */
    private fun arrumarOrientacao() {
        val paisagem = telaBaixa()
        for (cartao in listOf(binding.cardEspelhar, binding.buttonReceive)) cartao.minimumHeight = dp(if (paisagem) 124 else 150)
        // Deitado, as margens entre os blocos do Início encolhem: a altura de um celular deitado é ~340 dp.
        fun margemDeCima(v: View, dpRetrato: Int, dpPaisagem: Int) {
            (v.layoutParams as? android.view.ViewGroup.MarginLayoutParams)?.let { lp ->
                val m = dp(if (paisagem) dpPaisagem else dpRetrato)
                if (lp.topMargin != m) { lp.topMargin = m; v.layoutParams = lp }
            }
        }
        margemDeCima(binding.papeisDoInicio, 18, 4)
        margemDeCima(binding.secaoUsb, 18, 12)
        margemDeCima(binding.rodapeDoInicio, 20, 12)
        binding.colunasDoInicio.requestLayout()
        binding.colunasDoEspelhar.requestLayout()
        binding.mirrorContent.requestLayout()
        // A sessão da R5 e a do DVD são das telas delas (o mesmo filtro de `desenharEspelhamento`).
        MirrorBus.atual.takeIf {
            !it.daTelaR5 && !it.doDvd && (it.fase == MirrorBus.Fase.ESPERANDO || it.fase == MirrorBus.Fase.ESPELHANDO)
        }?.let { desenharBlocoDaEspera(it) }
    }

    /**
     * O seletor PT | EN do Início (`docs/traducao.md`, Android): o idioma em que a tela está, em
     * destaque; para o leitor de tela, um botão só ("Idioma: Português") com a ação "Mudar para inglês".
     */
    private fun desenharSeletorDeIdioma() {
        val pt = Idioma.codigo(this) == Idioma.PT
        for ((v, atual) in listOf(binding.idiomaPt to pt, binding.idiomaEn to !pt)) {
            v.setTextColor(if (atual) Cores.TEXTO else Cores.TEXTO3)
            v.typeface = android.graphics.Typeface.create(v.typeface, if (atual) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
            v.background = if (atual) androidx.core.content.ContextCompat.getDrawable(this, R.drawable.capsula_acento) else null
        }
        binding.seletorDeIdioma.contentDescription = getString(R.string.idioma_descricao)
        androidx.core.view.ViewCompat.replaceAccessibilityAction(
            binding.seletorDeIdioma,
            androidx.core.view.accessibility.AccessibilityNodeInfoCompat.AccessibilityActionCompat.ACTION_CLICK,
            getString(R.string.idioma_acao),
            null,
        )
    }

    /**
     * O idioma em que esta tela nasceu. **A troca de idioma não recria a tela sozinha** (`locale` está no
     * `configChanges` do manifesto): recriar com uma sessão no ar derruba a prévia (ver o manifesto). Sem
     * sessão, ela se recria na hora; com sessão, quando a sessão acabar ([idiomaPendente], em [mostrarHome]).
     * O seletor só aparece no Início, sem sessão — isto é para a troca pelos Ajustes do sistema (13+).
     */
    private var idiomaDaCriacao: String? = null
    private var idiomaPendente = false
    private var recriandoPeloIdioma = false

    private fun sessaoNoAr(): Boolean {
        val e = MirrorBus.atual
        return (!e.daTelaR5 && !e.doDvd && e.fase != MirrorBus.Fase.PARADO && e.fase != MirrorBus.Fase.ERRO) ||
            GravacaoBus.gravando
    }

    override fun onConfigurationChanged(novaConfiguracao: android.content.res.Configuration) {
        super.onConfigurationChanged(novaConfiguracao)
        val idioma = novaConfiguracao.locales[0]?.toLanguageTag()
        if (idiomaDaCriacao != null && idioma != idiomaDaCriacao && !recriandoPeloIdioma) {
            if (sessaoNoAr()) idiomaPendente = true else { recreate(); return }
        }
        arrumarOrientacao()
        arrumarPainelDaCamera()
    }

    // --- os ajustes da câmera (R9, `docs/controles-de-camera.md` §4) ------------------------------------

    private lateinit var painelDaCamera: PainelDaCamera
    private lateinit var marcasDoToque: MarcasDoToque
    private lateinit var gestosDaPrevia: GestosDaPrevia

    /** Os ajustes da câmera cabem nesta fonte: a câmera comum pelo dono, e não a DV nem o braço CameraX. */
    private var ajustesDaCameraPossiveis = false

    /**
     * O ícone "Ajustes da câmera" da linha do alto, o painel próprio (sem véu, §4.2) e o toque na prévia
     * (§4.4). O painel e as marcas são filhos do `mirrorOverlay`, por cima da rolagem; os toques que caem
     * fora dos botões chegam à rolagem, que os passa aos gestos sem consumir (a rolagem continua).
     */
    @android.annotation.SuppressLint("ClickableViewAccessibility")
    private fun montarAjustesDaCamera() {
        marcasDoToque = MarcasDoToque(this).apply {
            // A da pouca luz espera o cartão do PIN sair: ela cairia sobre ele, e o painel já a diz.
            fonteDaPilula = {
                MarcasDoToque.pilulaDaCamera(context, daTelaR5 = false,
                    comPoucaLuz = !binding.pinGroup.isShown && !binding.blocoParConhecido.isShown)
            }
            ficarAbaixoDaLinhaDoAlto()
        }
        painelDaCamera = PainelDaCamera(this, daTelaR5 = false) { abrirPainelDaCamera(false) }.apply { visibility = View.GONE }
        val cheio = android.widget.FrameLayout.LayoutParams(
            android.widget.FrameLayout.LayoutParams.MATCH_PARENT, android.widget.FrameLayout.LayoutParams.MATCH_PARENT)
        binding.mirrorOverlay.addView(marcasDoToque, android.widget.FrameLayout.LayoutParams(cheio))
        binding.mirrorOverlay.addView(painelDaCamera, android.widget.FrameLayout.LayoutParams(cheio))
        gestosDaPrevia = GestosDaPrevia(this, daTelaR5 = false,
            ondeEsta = { binding.mirrorPreviaDono.takeIf { ajustesDaCameraPossiveis && it.visibility == View.VISIBLE } },
            marcas = { marcasDoToque })
        binding.mirrorRolagem.setOnTouchListener { _, e ->
            gestosDaPrevia.observar(e)
            false
        }
        binding.botaoAjustesDaCamera.setOnClickListener {
            if (ajustesDaCameraPossiveis) abrirPainelDaCamera(painelDaCamera.visibility != View.VISIBLE)
            else folha.mostrar()
        }
        // O recuo das barras do sistema no lado em que o painel encosta (de ponta a ponta, targetSdk 36).
        androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(painelDaCamera) { v, insets ->
            val r = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.systemBars() or
                androidx.core.view.WindowInsetsCompat.Type.displayCutout())
            val deitado = resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
            v.setPadding(dp(12) + (if (deitado) 0 else r.left), dp(6) + (if (deitado) r.top else 0),
                dp(12) + r.right, dp(6) + r.bottom)
            insets
        }
    }

    /** O ícone abre o painel da câmera onde há controles; nas outras transmissões, os Ajustes gerais. */
    private fun mostrarIconeDosAjustes(possiveis: Boolean, emSessao: Boolean = false) {
        ajustesDaCameraPossiveis = possiveis
        val v = if (possiveis || emSessao) View.VISIBLE else View.GONE
        if (binding.botaoAjustesDaCamera.visibility != v) binding.botaoAjustesDaCamera.visibility = v
        binding.botaoAjustesDaCamera.contentDescription = getString(if (possiveis) R.string.in_ajustes_da_camera else R.string.ajustes)
        if (!possiveis && painelDaCamera.visibility == View.VISIBLE) abrirPainelDaCamera(false)
    }

    private fun abrirPainelDaCamera(abrir: Boolean) {
        painelDaCamera.visibility = if (abrir) View.VISIBLE else View.GONE
        binding.botaoAjustesDaCamera.isSelected = abrir
        com.quall.android.core.LogSeguro.i("QuallMain", "r9: painel dos ajustes da câmera ${if (abrir) "aberto" else "fechado"}") // i18n-fora: diário técnico via LogSeguro; não é texto da interface
        arrumarPainelDaCamera()
    }

    /**
     * **Onde o painel fica** (§4.2): em pé, na metade de baixo; deitado, na metade direita. A prévia vai
     * para a outra metade, inteira — a pessoa está julgando a imagem. Fechado, a prévia volta à tela toda.
     */
    private fun arrumarPainelDaCamera() {
        if (!::painelDaCamera.isInitialized) return
        val aberto = painelDaCamera.visibility == View.VISIBLE
        val deitado = resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
        val tela = resources.displayMetrics
        val lpPainel = painelDaCamera.layoutParams as android.widget.FrameLayout.LayoutParams
        val lpPrevia = binding.mirrorPreviaDono.layoutParams as android.widget.FrameLayout.LayoutParams
        val cheio = android.widget.FrameLayout.LayoutParams.MATCH_PARENT
        if (deitado) {
            lpPainel.width = tela.widthPixels / 2
            lpPainel.height = cheio
            lpPainel.gravity = android.view.Gravity.END
            lpPrevia.width = if (aberto) tela.widthPixels / 2 else cheio
            lpPrevia.height = cheio
            lpPrevia.gravity = android.view.Gravity.START
        } else {
            lpPainel.width = cheio
            lpPainel.height = tela.heightPixels / 2
            lpPainel.gravity = android.view.Gravity.BOTTOM
            lpPrevia.width = cheio
            lpPrevia.height = if (aberto) tela.heightPixels / 2 else cheio
            lpPrevia.gravity = android.view.Gravity.TOP
        }
        painelDaCamera.layoutParams = lpPainel
        binding.mirrorPreviaDono.layoutParams = lpPrevia
        androidx.core.view.ViewCompat.requestApplyInsets(painelDaCamera)
    }

    /** O chip da qualidade em Espelhar: "{resolução} · {fps}", ou "tamanho da fonte", apagado (§6.2). */
    private fun desenharChipDeQualidade() {
        val e = estadoDoCardapio()
        val texto = if (e.ativo) {
            "${e.resolucaoPara(com.quall.android.core.Resolucao.escolhida(this)).rotulo} · ${e.quadrosPara(com.quall.android.core.Resolucao.quadros(this))}"
        } else {
            getString(R.string.in_tamanho_da_fonte)
        }
        if (binding.chipQualidade.text.toString() != texto) binding.chipQualidade.text = texto
        binding.chipQualidade.alpha = if (e.ativo) 1f else 0.5f
        binding.chipQualidade.contentDescription = getString(R.string.in_qualidade_descricao, texto)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(ESTADO_NA_ESPELHAR, naEspelhar)
    }

    override fun onResume() {
        super.onResume()
        desenharRede()
        // A filmadora pode ter sido plugada depois de a tela abrir, e o `deviceName` muda a cada
        // replugue: a opção é refeita a cada volta.
        atualizarFontesDv()
        aplicarEstadoDoCardapio()
    }

    override fun onStart() {
        super.onStart()
        CaptureBus.setListener { msg ->
            binding.textStatus.text = msg
            if (msg.startsWith("ok:") || msg.startsWith("erro") || msg.contains("concluído")) { // i18n-fora: diário da bancada (CaptureBus)
                binding.animatedContent.visibility = View.GONE
            }
        }
        MirrorBus.ouvir(this) { estado -> desenharEspelhamento(estado) }
        MicrofoneBus.ouvir(this) { e -> desenharMicrofone(e) }
        gravacaoLevouAEspelhar = false
        GravacaoBus.ouvir(this) { e -> desenharGravacao(e) }
        // A primeira abertura de uma placa de captura troca o "Gravar a fita" por "Gravar" já (a
        // revisão do código da P1, 6): o tipo só se sabe depois dos descritores.
        // E o rótulo da lista vira "Placa de captura (…)" ou "Filmadora DV (…)" (§11, item 2); a
        // lista refeita chama a prévia parada no fim.
        UsbDv.ouvirTipo(this) { principal.post { atualizarFontesDv(); atualizarBotaoGravar() } }
        // A tela entrega a superfície da `PreviewView`; quem a liga ao use case `Preview` é o
        // `PreviaDaCamera`, porque a câmera é aberta pelo serviço e os dois lados nascem e morrem
        // em ordens diferentes.
        PreviaDaCamera.ligar(binding.mirrorPrevia.surfaceProvider)
        recusaVista = GravacaoDaTelaBus.atual.numeroDaRecusa
        paradaVista = GravacaoDaTelaBus.atual.mensagem
        GravacaoDaTelaBus.ouvir(this) { e -> aoMudarAGravacaoDaCamera(e) }
        principal.post(tiqueDaGravacao)
        telaVisivel = true
        atualizarPreviaDaPlaca()
    }

    override fun onStop() {
        // A prévia parada solta a placa no segundo plano (a rede e a gravação têm as posses delas).
        telaVisivel = false
        atualizarPreviaDaPlaca()
        CaptureBus.setListener(null)
        MirrorBus.ouvir(this, null)
        MicrofoneBus.ouvir(this, null)
        GravacaoBus.ouvir(this, null)
        UsbDv.ouvirTipo(this, null)
        GravacaoDaTelaBus.ouvir(this, null)
        principal.removeCallbacks(tiqueDaGravacao)
        // Solto aqui e não em `onDestroy`: `setSurfaceProvider(null)` chama `notifyInactive()`, e o
        // fluxo da tela **para de verdade** quando ninguém está olhando. Com o app em segundo
        // plano — o caso normal de quem apoia o telefone e deixa transmitindo — a câmera deixa de
        // alimentar a superfície da prévia, e quem continua consumindo quadros é só o codificador.
        // Isto é ganho da troca de 03/09: o `ImageAnalysis` de antes não conseguia parar sem
        // refazer o bind, e refazer o bind reinicia a captura que está no ar.
        PreviaDaCamera.ligar(null)
        super.onStop()
    }

    override fun onDestroy() {
        receptorUsb?.let { runCatching { unregisterReceiver(it) } }
        receptorUsb = null
        multicastLock.release()
        super.onDestroy()
    }

    private fun descreverNucleo(): String = if (QuallNative.carregado) {
        getString(R.string.in_nucleo_carregado, QuallNative.protocolVersion(), QuallNative.serviceType(), Build.SUPPORTED_ABIS.firstOrNull().orEmpty())
    } else {
        getString(R.string.in_nucleo_nao_carregou, QuallNative.erroDeCarga.toString(), Build.SUPPORTED_ABIS.firstOrNull().orEmpty())
    }

    // --- Seletor de origem --------------------------------------------------------------------

    /**
     * Enumera as câmeras do aparelho (`CameraEnumerator`, sem precisar de permissão — só abrir a
     * câmera exige) e insere uma `RadioButton` por opção, depois de "Tela". Não fixa em duas: o
     * que `CameraEnumerator` devolver é o que aparece.
     */
    private fun popularFontesDeCamera() {
        val cameras = CameraEnumerator.listar(this)
        for (opcao in cameras) {
            val rb = LadrilhoDeOrigem(this).apply {
                id = View.generateViewId()
                text = opcao.label
                tag = opcao
                icone = iconeDaOrigem(opcao)
            }
            binding.radioGroupFonte.addView(rb)
        }
        atualizarFontesDv()
        if (cameras.isEmpty()) {
            binding.textCameraNote.visibility = View.VISIBLE
            binding.textCameraNote.text = getString(R.string.in_nenhuma_camera)
        }
        aplicarEstadoDoCardapio()
    }

    /** O ícone do ladrilho de cada origem (§6.2): câmera, rosto (frontal), placa (USB) ou filmadora (DV). */
    private fun iconeDaOrigem(opcao: CameraEnumerator.CameraOption): Int = when {
        opcao.id.startsWith(UsbDv.PREFIXO_DO_ARQUIVO) -> R.drawable.ic_q_video
        opcao.id.startsWith(UsbDv.PREFIXO_DO_ID) ->
            // Pelo tipo lembrado, e não pelo rótulo (traduzido; `docs/traducao.md`).
            if (getSystemService(UsbManager::class.java)?.let { UsbDv.porId(it, opcao.id) }
                    ?.let { UsbDv.conhecido(it) } == com.quall.android.capture.dv.VideoUsb.Conhecido.FILMADORA_DV
            ) R.drawable.ic_q_video else R.drawable.ic_q_placa
        opcao.lensFacing == android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT -> R.drawable.ic_q_rosto
        else -> R.drawable.ic_q_camera
    }

    /**
     * O vídeo USB (`capture/dv/`): **a placa de captura para todos** (a P3, decisão do Pessoa Exemplo de
     * 28/09), e **a filmadora DV só com a bandeira de bancada `camera_dv`** ([VideoUsb.naLista]). Só
     * aparece com a `libqualldv.so` carregada (arm64 com o FFmpeg da DV no APK) e o aparelho plugado.
     * Antes da primeira abertura (a permissão USB) não dá para saber o que ele é: o rótulo diz "Vídeo
     * USB (…)" e o palpite é a interface de som; depois, o tipo lembrado por `vid:pid` dá "Placa de
     * captura (…)" ou "Filmadora DV (…)". O arquivo de bancada da DV, só com a bandeira.
     */
    private fun atualizarFontesDv() {
        val grupo = binding.radioGroupFonte
        // A seleção é refeita pelo id da opção, e só nela: com a filmadora e o arquivo de bancada
        // na lista, marcar todas deixaria marcada a última (a revisão do código, B6).
        val idMarcado = (grupo.findViewById<RadioButton>(grupo.checkedRadioButtonId)?.tag
            as? CameraEnumerator.CameraOption)?.id?.takeIf { it.startsWith(UsbDv.PREFIXO_DO_ID) }
        for (i in grupo.childCount - 1 downTo 0) {
            val v = grupo.getChildAt(i)
            if ((v.tag as? CameraEnumerator.CameraOption)?.id?.startsWith(UsbDv.PREFIXO_DO_ID) == true) {
                grupo.removeViewAt(i)
            }
        }
        if (!capturaUsbPossivel || !QuallDv.disponivel) { atualizarPreviaDaPlaca(); return }
        val usb = getSystemService(UsbManager::class.java) ?: return
        val chaveDv = com.quall.android.core.Bancada.cameraDv(this)
        val opcoes = UsbDv.candidatos(usb)
            .filter { d -> com.quall.android.capture.dv.VideoUsb.naLista(UsbDv.conhecido(d), UsbDv.temSom(d), chaveDv) }
            .map { d ->
                CameraEnumerator.CameraOption(id = UsbDv.PREFIXO_DO_ID + d.deviceName, label = UsbDv.rotulo(d), lensFacing = -1)
            }.toMutableList()
        val arquivo = if (chaveDv) com.quall.android.core.Bancada.cameraDvArquivo(this) else ""
        if (arquivo.isNotBlank()) {
            opcoes += CameraEnumerator.CameraOption(
                id = UsbDv.PREFIXO_DO_ARQUIVO + arquivo, label = "Filmadora DV (arquivo de bancada)", lensFacing = -1, // i18n-fora: só com a bandeira de bancada
            )
        }
        for (opcao in opcoes) {
            val rb = LadrilhoDeOrigem(this).apply {
                id = View.generateViewId()
                text = opcao.label
                tag = opcao
                icone = iconeDaOrigem(opcao)
            }
            grupo.addView(rb)
            if (opcao.id == idMarcado) rb.isChecked = true
        }
        if (idMarcado != null && opcoes.none { it.id == idMarcado }) {
            binding.textCameraNote.visibility = View.VISIBLE
            binding.textCameraNote.text = getString(R.string.in_usb_saiu)
        }
        atualizarPreviaDaPlaca()
    }

    // --- Cardápio de resolução ------------------------------------------------------------------

    /**
     * O cardápio de resolução e fps mora na folha de Ajustes desde o "Estúdio de bolso"
     * (`docs/telas-estudio.md` §6.2 e §6.3), com a nota que diz o custo ([FolhaDeAjustes]). Com o vídeo
     * USB ele fica desativado e a nota diz quem define o tamanho: a fita, ou a placa
     * (`SeletorDeResolucao`); o chip de Espelhar diz "tamanho da fonte".
     */
    private fun aplicarEstadoDoCardapio() {
        folha.aplicarCardapio(estadoDoCardapio())
        desenharChipDeQualidade()
    }

    /**
     * O estado do cardápio pela fonte escolhida: o vídeo USB o desativa; uma câmera do aparelho apaga o
     * que ela não faz (o A07 não faz 60 fps, 06/10). Os tetos são características da câmera, lidos uma
     * vez por câmera e guardados.
     */
    private fun estadoDoCardapio(): com.quall.android.core.SeletorDeResolucao.Estado {
        val opcao = fonteCameraSelecionada()?.takeIf { !it.id.startsWith(UsbDv.PREFIXO_DO_ID) }
        val tetos = opcao?.let { o -> tetosPorCamera.getOrPut(o.id) { com.quall.android.capture.CameraXSource.tetosPorResolucao(this, o.id) } }
        return com.quall.android.core.SeletorDeResolucao.estado(opcaoDvMarcada() != null, daPlaca = placaDeCapturaMarcada(),
            tetos = tetos.orEmpty(), escolhida = com.quall.android.core.Resolucao.escolhida(this),
            fps = com.quall.android.core.Resolucao.quadros(this))
    }

    private val tetosPorCamera = HashMap<String, Map<com.quall.android.core.Resolucao, Int?>>()

    private var toquesNoTitulo = 0
    private var primeiroToqueNoTituloEm = 0L

    /**
     * Sete toques no título revelam [diagnosticoSection][binding] — mesmo gesto que
     * `apps/ios/Quall/App/TelaInicial.swift` usa para a mesma finalidade: "toda opção avançada é
     * opcional e escondida" (PROMPT.md), e a lista de aparelhos + os botões de bancada não são
     * fluxo de produto (ver comentário em `activity_main.xml`). A janela de 3 s evita revelar a
     * seção com toques acidentais espalhados ao longo do uso normal do app.
     */
    private fun configurarToqueSecretoDeDiagnostico() {
        // A bancada não consegue fazer o gesto: sete `input tap` no A10s levam 8 s e a janela do
        // gesto é de 3 s. Ver `Bancada.diagnosticoVisivel`.
        if (com.quall.android.core.Bancada.diagnosticoVisivel(this)) {
            binding.diagnosticoSection.visibility = View.VISIBLE
            EstadoDasTelas.diagnosticoLigado = true
        }
        binding.textAppTitle.setOnClickListener {
            val agora = System.currentTimeMillis()
            if (agora - primeiroToqueNoTituloEm > 3_000) {
                toquesNoTitulo = 0
                primeiroToqueNoTituloEm = agora
            }
            toquesNoTitulo++
            if (toquesNoTitulo >= 7) {
                toquesNoTitulo = 0
                val ligar = binding.diagnosticoSection.visibility != View.VISIBLE
                binding.diagnosticoSection.visibility = if (ligar) View.VISIBLE else View.GONE
                // A tela de exibir abre o painel de números com ele (`docs/telas-estudio.md` §11.3).
                EstadoDasTelas.diagnosticoLigado = ligar
                // A seção mora em Espelhar: ligada, vai-se até ela (a revisão do código, 28/09).
                if (ligar) mostrarEspelhar(true)
                Toast.makeText(
                    this,
                    if (ligar) "Diagnóstico visível" else "Diagnóstico escondido", // i18n-fora: o gesto de bancada
                    Toast.LENGTH_SHORT,
                ).show()
            }
        }
    }

    /** A `CameraOption` da `RadioButton` marcada, ou `null` quando a seleção é "Tela". */
    private fun fonteCameraSelecionada(): CameraEnumerator.CameraOption? {
        val checkedId = binding.radioGroupFonte.checkedRadioButtonId
        if (checkedId == View.NO_ID) return null
        val marcado = binding.radioGroupFonte.findViewById<View>(checkedId)
        return marcado?.tag as? CameraEnumerator.CameraOption
    }

    // --- Espelhar ---------------------------------------------------------------------------

    private fun comecarEspelhamento() {
        // Um Gravar anterior que parou numa recusa não pode transformar este Espelhar em gravação,
        // nem um pedido de prévia que parou na permissão negada o engolir.
        pendingGravacao = false
        pendingPrevia = false
        if (!QuallNative.carregado) {
            Toast.makeText(this, descreverNucleo(), Toast.LENGTH_LONG).show()
            return
        }
        // O DVD no ar (`docs/dvd-para-mp4.md` §10, a revisão, 12): a sessão dele é da tela "Converter
        // DVD", e a home não a desenha; sem isto o toque em Espelhar era recusado pelo serviço em silêncio.
        if (com.quall.android.dvd.TransmissaoDvdBus.transmitindo) {
            binding.textCameraNote.setOnClickListener(null)
            binding.textCameraNote.visibility = View.VISIBLE
            binding.textCameraNote.text = getString(R.string.in_dvd_no_ar)
            return
        }
        pendingMode = null

        val opcaoCamera = fonteCameraSelecionada()
        if (opcaoCamera == null) {
            // Origem: tela. Só ela pede o consentimento do sistema.
            esconderNotaDeCamera()
            val mpm = getSystemService(MediaProjectionManager::class.java)
            screenCapturePermission.launch(mpm.createScreenCaptureIntent())
            return
        }

        // Origem: câmera. Sem consentimento por sessão do sistema — só a permissão de câmera,
        // pedida uma vez (ver docs/fluxo-de-uso.md: "a câmera pede permissão uma vez, na primeira
        // vez").
        pendingCamera = opcaoCamera
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            esconderNotaDeCamera()
            iniciarCamera(opcaoCamera)
        } else {
            binding.textCameraNote.setOnClickListener(null)
            binding.textCameraNote.visibility = View.VISIBLE
            binding.textCameraNote.text = getString(R.string.in_pedindo_permissao_camera)
            cameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    private fun esconderNotaDeCamera() {
        binding.textCameraNote.setOnClickListener(null)
        binding.textCameraNote.visibility = View.GONE
    }

    /**
     * `docs/regras-de-frente.md`/PROMPT.md, item 3 desta tarefa: "se negada, a tela precisa dizer
     * o que fazer". Duas situações distintas, dois textos distintos: negada uma vez (pode pedir
     * de novo) e negada "para sempre" (só resolve nos Ajustes do sistema).
     */
    private fun onCameraPermissionResult(concedida: Boolean) {
        val opcao = pendingCamera
        if (concedida && opcao != null) {
            esconderNotaDeCamera()
            iniciarCamera(opcao)
            return
        }
        binding.textCameraNote.visibility = View.VISIBLE
        val podePedirDeNovo = ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.CAMERA)
        if (podePedirDeNovo) {
            binding.textCameraNote.setOnClickListener(null)
            binding.textCameraNote.text = getString(R.string.in_camera_negada)
        } else {
            binding.textCameraNote.text = getString(R.string.in_camera_bloqueada)
            binding.textCameraNote.setOnClickListener { abrirAjustesDoApp() }
        }
    }

    private fun abrirAjustesDoApp() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
        }
        startActivity(intent)
    }

    /**
     * A câmera com a permissão CAMERA já dada. A filmadora DV pede ainda a permissão USB: sem CAMERA
     * o Android recusa esta sem diálogo ("Camera permission required for USB video class
     * devices", medido no S24 pelo espião), por isso ela vem depois.
     */
    private fun iniciarCamera(opcao: CameraEnumerator.CameraOption) {
        if (!opcao.id.startsWith(UsbDv.PREFIXO_DO_ID) || opcao.id.startsWith(UsbDv.PREFIXO_DO_ARQUIVO)) {
            iniciarMirrorServiceCamera(opcao)
            return
        }
        val usb = getSystemService(UsbManager::class.java)
        val dev = usb?.let { UsbDv.porId(it, opcao.id) }
        if (usb == null || dev == null) {
            binding.textCameraNote.visibility = View.VISIBLE
            binding.textCameraNote.text = getString(R.string.in_usb_nao_plugado)
            atualizarFontesDv()
            return
        }
        if (usb.hasPermission(dev)) {
            iniciarMirrorServiceCamera(opcao)
            return
        }
        val acao = "$packageName.PERMISSAO_USB_DV"
        // Um receptor só: dois toques em Espelhar antes do diálogo abririam a filmadora duas vezes
        // (a revisão do código, B5).
        receptorUsb?.let { runCatching { unregisterReceiver(it) } }
        val receptor = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                runCatching { unregisterReceiver(this) }
                if (receptorUsb === this) receptorUsb = null
                if (i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                    esconderNotaDeCamera()
                    iniciarMirrorServiceCamera(opcao)
                } else {
                    binding.textCameraNote.visibility = View.VISIBLE
                    binding.textCameraNote.text = getString(R.string.in_usb_negado, nomeDaOpcaoUsb(opcao))
                    pendingGravacao = false
                    pendingPrevia = false
                }
            }
        }
        ContextCompat.registerReceiver(this, receptor, IntentFilter(acao), ContextCompat.RECEIVER_NOT_EXPORTED)
        receptorUsb = receptor
        binding.textCameraNote.setOnClickListener(null)
        binding.textCameraNote.visibility = View.VISIBLE
        binding.textCameraNote.text = getString(R.string.in_usb_pedindo, nomeDaOpcaoUsb(opcao))
        // Explícito (setPackage) e mutável: o UsbManager acrescenta os extras.
        val pi = PendingIntent.getBroadcast(this, 0, Intent(acao).setPackage(packageName), PendingIntent.FLAG_MUTABLE)
        usb.requestPermission(dev, pi)
    }

    // --- A prévia parada da placa de captura ----------------------------------------------------

    /**
     * **A prévia da placa sem transmitir nem gravar** (`docs/placa-de-captura-usb.md` §11, item 1): com
     * a placa escolhida em "O que transmitir", a permissão USB dada e Espelhar à mostra, a imagem da
     * placa aparece embaixo da lista, para navegar no menu do videocassete. A posse é de prévia no
     * dono único ([DonoDaPlaca]): a mesma fonte serve depois à rede e à gravação, e o USB não reabre.
     * Some (e a placa é solta, se ninguém mais a tem) ao trocar de fonte, sair de Espelhar ou ir ao
     * segundo plano. Sem a permissão, a caixa oferece pedi-la.
     */
    private fun atualizarPreviaDaPlaca() {
        val opcao = opcaoDvMarcada()?.takeIf { !it.id.startsWith(UsbDv.PREFIXO_DO_ARQUIVO) }
        val placa = opcao != null && QuallDv.disponivel && placaDeCapturaMarcada()
        val usb = getSystemService(UsbManager::class.java)
        val dev = if (placa && usb != null) UsbDv.porId(usb, opcao!!.id) else null
        val permitido = dev != null && usb!!.hasPermission(dev) &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        val aMostra = telaVisivel && naEspelhar && placa && dev != null
        val quer = aMostra && permitido
        val vis = if (aMostra) View.VISIBLE else View.GONE
        if (binding.painelDaPlaca.visibility != vis) binding.painelDaPlaca.visibility = vis
        binding.placaPreviaDv.visibility = if (quer) View.VISIBLE else View.GONE
        binding.linhaDaPlaca.visibility = if (quer) View.VISIBLE else View.GONE
        // O ouvir é da tela: some junto (troca de fonte, sair de Espelhar, segundo plano).
        if (!aMostra && (ouvirPedido || DonoDaPlaca.ouvindo)) aplicarOuvir(false)
        if (aMostra && !permitido) {
            mostrarRecadoDaPlaca(getString(R.string.in_placa_toque_para_ver)) {
                val o = opcaoDvMarcada() ?: return@mostrarRecadoDaPlaca
                pendingPrevia = true
                pendingCamera = o
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                    iniciarCamera(o)
                } else {
                    cameraPermission.launch(Manifest.permission.CAMERA)
                }
            }
        } else if (!aMostra || (quer && binding.textPlaca.tag == RECADO_DA_PERMISSAO)) {
            mostrarRecadoDaPlaca(null)
        }
        DonoDaPlaca.quererPrevia(DONO_DA_PREVIA, this, if (quer) opcao!!.id else null) { motivo ->
            if (!isDestroyed) mostrarRecadoDaPlaca(getString(R.string.in_placa_previa_parou, motivo))
        }
    }

    // --- Ouvir a placa no telefone (§11, item 5) -------------------------------------------------

    private fun alternarOuvir() {
        if (DonoDaPlaca.ouvindo) { aplicarOuvir(false); return }
        // A placa lida pelo usbfs (§13.10) não passa pelo microfone: sem pergunta.
        if (DonoDaPlaca.somSemMicrofone) { aplicarOuvir(true); return }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            aplicarOuvir(true)
        } else {
            permissaoDoOuvir.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    /** O último pedido desta tela ao ouvir (o estado de fato é `DonoDaPlaca.ouvindo`, que chega depois). */
    private var ouvirPedido = false

    private fun aplicarOuvir(ligar: Boolean) {
        ouvirPedido = ligar
        DonoDaPlaca.ouvir(this, ligar) { _, porque ->
            if (isDestroyed) return@ouvir
            desenharOuvir()
            if (porque != null) Toast.makeText(this, getString(R.string.in_ouvir_falhou, porque), Toast.LENGTH_LONG).show()
        }
    }

    /** O "Ouvir" da home e o da tela da transmissão, pelo estado do dono. */
    private fun desenharOuvir() {
        val ouvindo = DonoDaPlaca.ouvindo
        val texto = getString(if (ouvindo) R.string.in_parar_de_ouvir else R.string.in_ouvir)
        if (binding.buttonOuvirPlaca.text.toString() != texto) binding.buttonOuvirPlaca.text = texto
        ouvirDaPlaca.atualizar(getString(if (ouvindo) R.string.in_ouvindo else R.string.in_ouvir), destaque = ouvindo,
            descricao = getString(if (ouvindo) R.string.in_parar_de_ouvir_descricao else R.string.in_ouvir_descricao))
    }

    // --- A foto do quadro da placa (§11, item 6) -------------------------------------------------

    /** Uma foto por vez: o toque seguido não empilha pedidos. */
    private var fotografando = false

    private fun tirarFoto() {
        if (fotografando) return
        fotografando = true
        DonoDaPlaca.foto(this) { nome, porque ->
            fotografando = false
            if (isDestroyed) return@foto
            Toast.makeText(this, if (nome != null) getString(R.string.in_foto_salva) else getString(R.string.in_foto_falhou, porque.orEmpty()),
                if (nome != null) Toast.LENGTH_SHORT else Toast.LENGTH_LONG).show()
        }
    }

    /** A caixa embaixo da prévia da placa: um recado (com toque, se houver), ou nada. */
    private fun mostrarRecadoDaPlaca(texto: String?, toque: (() -> Unit)? = null) {
        binding.textPlaca.visibility = if (texto == null) View.GONE else View.VISIBLE
        binding.textPlaca.text = texto ?: ""
        binding.textPlaca.tag = if (toque != null) RECADO_DA_PERMISSAO else null
        binding.textPlaca.setOnClickListener(if (toque != null) View.OnClickListener { toque() } else null)
    }

    // --- Gravação da filmadora DV ---------------------------------------------------------------

    private fun opcaoDvMarcada(): CameraEnumerator.CameraOption? =
        fonteCameraSelecionada()?.takeIf { it.id.startsWith(UsbDv.PREFIXO_DO_ID) }

    private fun atualizarBotaoGravar() {
        val gravando = GravacaoBus.gravando
        binding.buttonGravarDv.visibility =
            if (!gravando && opcaoDvMarcada() != null) View.VISIBLE else View.GONE
        // A placa grava pelo mesmo botão (a P4 adiantada, `docs/placa-de-captura-usb.md` §9.6), sem
        // "a fita" no nome.
        binding.buttonGravarDv.text = getString(if (placaDeCapturaMarcada()) R.string.in_gravar else R.string.in_gravar_a_fita)
    }

    /**
     * A opção marcada é uma placa de captura? Certo depois da primeira abertura (o formato está nos
     * descritores, depois da permissão: [UsbDv.tipoConhecido], lembrado por `vid:pid`); antes dela, o
     * palpite é o aparelho ter uma interface de **som** (a placa tem UAC, §1; a filmadora DV leva o
     * som dentro do DV). Decide textos e a prévia parada: a gravação e a rede seguem o formato que abrir.
     */
    private fun placaDeCapturaMarcada(): Boolean {
        val opcao = opcaoDvMarcada() ?: return false
        val usb = getSystemService(UsbManager::class.java) ?: return false
        val dev = UsbDv.porId(usb, opcao.id) ?: return false
        return UsbDv.pareceSerPlaca(dev)
    }

    /** "a placa de captura", "a filmadora" ou "o aparelho de vídeo USB", para as frases da tela. */
    private fun nomeDaOpcaoUsb(opcao: CameraEnumerator.CameraOption): String {
        val usb = getSystemService(UsbManager::class.java)
        val dev = usb?.let { UsbDv.porId(it, opcao.id) } ?: return getString(R.string.in_o_aparelho_usb)
        return if (UsbDv.pareceSerPlaca(dev)) getString(R.string.in_a_placa_de_captura) else com.quall.android.capture.dv.VideoUsb.nome(Idioma.textos(this), UsbDv.conhecido(dev))
    }

    private fun comecarGravacaoDv() {
        val opcao = opcaoDvMarcada() ?: return
        // A placa grava e transmite junto (§11, item 4: a mesma fonte, o dono único); a filmadora DV
        // continua com um dono só entre as duas.
        val noAr = MirrorBus.atual.fase.let { it == MirrorBus.Fase.ESPERANDO || it == MirrorBus.Fase.ESPELHANDO }
        if (noAr && !(MirrorBus.atual.daPlaca || placaDeCapturaMarcada())) {
            binding.textCameraNote.visibility = View.VISIBLE
            binding.textCameraNote.text = getString(R.string.in_pare_o_espelhamento)
            return
        }
        pendingGravacao = true
        pendingPrevia = false
        pendingCamera = opcao
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            iniciarCamera(opcao)
        } else {
            cameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    /** A gravação já levou esta chegada da tela a Espelhar (o "Voltar" de lá vale até a próxima). */
    private var gravacaoLevouAEspelhar = false

    private fun desenharGravacao(e: GravacaoBus.Estado) {
        telaLigada.atualizar()
        val mostrar = e.fase != GravacaoBus.Fase.NADA
        binding.painelGravacao.visibility = if (mostrar) View.VISIBLE else View.GONE
        // O painel da gravação da DV mora em Espelhar: gravando, a escolha do papel não o esconde
        // (a revisão do código, 28/09). **Uma vez por chegada** (a cada `onStart`, e quando a gravação
        // nasce): a cada tique do gravador, o "Voltar" de Espelhar não saía do lugar, e a gravação feita
        // pela tela "Placa de captura e filmadora" deixava o cartão dela fora de alcance (S24, 30/09).
        if (!mostrar) gravacaoLevouAEspelhar = false
        else if (!gravacaoLevouAEspelhar) {
            gravacaoLevouAEspelhar = true
            if (!naEspelhar) mostrarEspelhar(true)
        }
        val ativa = e.fase == GravacaoBus.Fase.GRAVANDO || e.fase == GravacaoBus.Fase.PREPARANDO
        // A placa já tem a prévia dela acima (`painelDaPlaca`, a mesma `PreviaDv`): duas superfícies
        // disputariam o desenho, e uma ficaria preta.
        binding.gravacaoPreviaDv.visibility = if (ativa && !e.daPlaca) View.VISIBLE else View.GONE
        binding.buttonPararGravacao.visibility = if (ativa) View.VISIBLE else View.GONE
        val seg = e.decorridoMs / 1000
        binding.textGravacao.text = when (e.fase) {
            GravacaoBus.Fase.PREPARANDO -> getString(R.string.in_gravacao_preparando)
            GravacaoBus.Fase.GRAVANDO -> buildString {
                append(getString(R.string.in_gravacao_gravando, e.nome)).append('\n')
                append(getString(R.string.in_gravacao_numeros, seg / 3600, seg / 60 % 60, seg % 60, e.quadros, e.bytes / 1e6))
                append(getString(R.string.in_gravacao_livre, e.espacoLivre / 1e9))
                if (e.pausada) append('\n').append(
                    getString(if (e.daPlaca) R.string.in_gravacao_placa_sem_imagem else R.string.in_gravacao_fita_parada)
                )
                e.avisoDoSom?.let { append('\n').append(getString(R.string.in_gravacao_som, it)) }
            }
            GravacaoBus.Fase.PARADA -> getString(R.string.in_gravacao_parada, e.mensagem)
            GravacaoBus.Fase.NADA -> ""
        }
        atualizarBotaoGravar()
        desenharGravacaoDaCamera()
    }

    private fun iniciarMirrorServiceCamera(opcao: CameraEnumerator.CameraOption) {
        if (pendingPrevia) {
            // As permissões eram só para a prévia parada: ela abre agora, sem espelhar.
            pendingPrevia = false
            atualizarPreviaDaPlaca()
            return
        }
        if (pendingGravacao) {
            pendingGravacao = false
            if (opcao.id.startsWith(UsbDv.PREFIXO_DO_ID)) {
                GravacaoDvService.comecar(this, opcao.id)
                return
            }
        }
        if (opcao.id.startsWith(UsbDv.PREFIXO_DO_ID) && GravacaoBus.gravando &&
            !(GravacaoBus.estado.daPlaca || placaDeCapturaMarcada())
        ) {
            binding.textCameraNote.visibility = View.VISIBLE
            binding.textCameraNote.text = getString(R.string.in_pare_a_gravacao)
            return
        }
        val intent = Intent(this, MirrorService::class.java).apply {
            putExtra(MirrorService.EXTRA_SOURCE_KIND, MirrorService.SOURCE_CAMERA)
            putExtra(MirrorService.EXTRA_CAMERA_ID, opcao.id)
            putExtra(MirrorService.EXTRA_CAMERA_LABEL, opcao.label)
        }
        ContextCompat.startForegroundService(this, intent)
    }

    /**
     * Direto ao serviço, e não por `startForegroundService(ACAO_PARAR)`: com o serviço já morto
     * aquilo o subia de novo sem `startForeground`, e o app caía por prazo (a revisão da tela R5).
     * Sem serviço vivo não há o que parar.
     */
    private fun pararEspelhamento() {
        MirrorService.pedirParada(null)
    }

    /**
     * O microfone, **só com a câmera** (a tela não tem microfone): o controle redondo
     * ([MicrofoneRedondo]), que começa desligado a cada espelhamento, e o Aviso com o porquê de não
     * ter ligado. Bloqueada nos Ajustes, o toque no Aviso abre os Ajustes do app.
     */
    private fun desenharMicrofone(e: EstadoDoMicrofone) {
        microfoneDaCamera.visibility = if (e.disponivel) View.VISIBLE else View.GONE
        microfoneDaCamera.atualizar(e, comReceptor = MirrorBus.atual.fase == MirrorBus.Fase.ESPELHANDO)
        val t = Idioma.textos(this)
        // Pelo código do motivo, e não pela palavra "Ajustes" na frase (traduzida; `docs/traducao.md`).
        val ajustes = e.pedeAjustes
        val porque = when {
            !e.disponivel -> ""
            !e.ligado && e.motivo.isNotBlank() -> getString(R.string.in_microfone_desligado_porque, e.nome(t), e.motivo(t)) +
                if (ajustes) "\n" + getString(R.string.in_toque_para_abrir_os_ajustes) else ""
            e.ligado && e.aviso.isNotBlank() -> getString(R.string.in_microfone_aviso, e.nome(t), e.aviso)
            else -> ""
        }
        binding.textMicrofone.visibility = if (porque.isEmpty()) View.GONE else View.VISIBLE
        binding.textMicrofone.text = porque
        binding.textMicrofone.setOnClickListener(if (ajustes) View.OnClickListener { abrirAjustesDoApp() } else null)
        // O botão Gravar e o indicador dizem se o som entra.
        desenharGravacaoDaCamera()
    }

    // --- a gravação da câmera comum -------------------------------------------------------------

    /**
     * **Gravar no espelhamento de câmera comum** (§8.6, decisão do Pessoa Exemplo de 24/09): a câmera sem
     * nada por cima, na Galeria (`Movies/Quall/Quall-Camera-…`), **sem precisar de receptor**. Quem
     * grava é o serviço, pelo mesmo caminho da tela R5 (`GravacaoDaTela`). **Não liga o microfone**:
     * com ele desligado o botão e o indicador dizem "sem som".
     */
    private fun alternarGravacaoDaCamera() {
        val e = GravacaoDaTelaBus.atual
        if (!e.disponivel || !e.daCameraComum) return
        val gravar = e.fase == GravacaoDaTelaBus.Fase.PARADA
        if (!gravar && e.fase != GravacaoDaTelaBus.Fase.GRAVANDO) return
        if (gravar && e.indisponivel != null) {
            // O botão apagado repete o motivo no toque (§14.3).
            com.quall.android.core.LogSeguro.i("QuallMirror", "tela inicial: gravar indisponível: ${e.indisponivel}") // i18n-fora: diário técnico; o Toast usa mensagem localizada de GravacaoIndisponivel
            Toast.makeText(this, com.quall.android.mirror.GravacaoIndisponivel.mensagem(Idioma.textos(this)), Toast.LENGTH_LONG).show()
            return
        }
        if (!MirrorService.pedirGravacao(gravar, daTelaR5 = false) && gravar) {
            Toast.makeText(this, getString(R.string.in_gravar_sem_espelhamento), Toast.LENGTH_LONG).show()
        }
    }

    /** "Tentar mesmo assim" (a revisão da D1, 12): o toque longo no botão apagado esquece as falhas guardadas. */
    private fun tentarGravarMesmoAssim(): Boolean {
        val e = GravacaoDaTelaBus.atual
        if (!e.daCameraComum || e.indisponivel == null) return false
        val gi = com.quall.android.mirror.GravacaoIndisponivel
        gi.esquecer(this)
        val novo = gi.motivo(this)
        GravacaoDaTelaBus.atualizar { it.copy(indisponivel = novo) }
        Toast.makeText(this, if (novo == null) getString(R.string.in_gravar_voltou) else getString(R.string.in_gravar_continua_sem, novo),
            Toast.LENGTH_LONG).show()
        return true
    }

    private fun aoMudarAGravacaoDaCamera(e: GravacaoDaTelaBus.Estado) {
        if (isDestroyed) return
        if (e.daCameraComum) {
            // Um arquivo só (§5.2): da abertura ao fechamento, a tela não gira. A saída de gravação do
            // divisor já tem a rotação congelada; isto trava a tela junto, para a prévia não mentir.
            travarOrientacao(e.ocupada)
            if (e.numeroDaRecusa != recusaVista && e.recusa.isNotBlank()) {
                recusaVista = e.numeroDaRecusa
                Toast.makeText(this, getString(R.string.in_nao_gravou, e.recusa), Toast.LENGTH_LONG).show()
            }
            if (e.fase == GravacaoDaTelaBus.Fase.PARADA && e.mensagem.isNotBlank() && e.mensagem != paradaVista) {
                paradaVista = e.mensagem
                Toast.makeText(this, e.mensagem, Toast.LENGTH_LONG).show()
            }
        } else {
            travarOrientacao(false)
        }
        desenharGravacaoDaCamera()
    }

    private fun travarOrientacao(travar: Boolean) {
        if (travar == orientacaoTravada) return
        orientacaoTravada = travar
        requestedOrientation = if (travar) {
            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LOCKED
        } else {
            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        com.quall.android.core.LogSeguro.i("QuallMirror", "tela inicial: orientação ${if (travar) "travada enquanto grava" else "solta"}") // i18n-fora: diário técnico via LogSeguro; não é texto da interface
    }

    /**
     * O Gravar redondo ([GravarRedondo]) e o Aviso "Gravando SEM SOM — ligue o microfone", pelo estado
     * do serviço e do microfone. Só escreve o que mudou.
     */
    private fun desenharGravacaoDaCamera() {
        telaLigada.atualizar()
        val e = GravacaoDaTelaBus.atual
        val noAr = MirrorBus.atual.fase.let { it == MirrorBus.Fase.ESPERANDO || it == MirrorBus.Fase.ESPELHANDO }
        val existe = e.disponivel && e.daCameraComum && noAr
        val mic = MicrofoneBus.atual
        val vis = if (existe) View.VISIBLE else View.GONE
        if (gravarDaCamera.visibility != vis) gravarDaCamera.visibility = vis
        if (existe) {
            gravarDaCamera.atualizar(e.fase, android.os.SystemClock.elapsedRealtime() - e.desdeMs, e.espacoLivre, mic.ligado, habilitado = true)
        }
        // O aparelho que não grava (a D1, §14.3): o Gravar apagado mas tocável (o toque repete o motivo,
        // o toque longo tenta mesmo assim), e as duas linhas da mensagem na caixa embaixo dele.
        val gi = com.quall.android.mirror.GravacaoIndisponivel
        val naoGrava = existe && e.indisponivel != null && e.fase == GravacaoDaTelaBus.Fase.PARADA
        if (naoGrava) {
            gravarDaCamera.alpha = 0.4f
            androidx.core.view.ViewCompat.setStateDescription(gravarDaCamera, getString(R.string.in_desativado, gi.texto(Idioma.textos(this))))
        } else if (androidx.core.view.ViewCompat.getStateDescription(gravarDaCamera) != null) {
            androidx.core.view.ViewCompat.setStateDescription(gravarDaCamera, null)
            gravarDaCamera.alpha = 1f
        }
        // Gravar não liga o microfone (decisão do Pessoa Exemplo, 24/09): dito por extenso, e ligar no meio grava
        // o som dali em diante.
        val texto = when {
            naoGrava -> gi.mensagem(Idioma.textos(this))
            !existe || e.fase != GravacaoDaTelaBus.Fase.GRAVANDO -> ""
            !mic.ligado -> getString(R.string.in_gravando_sem_som)
            !mic.capturando -> getString(R.string.in_gravando_microfone_abrindo)
            else -> ""
        }
        // O Aviso de informação para a mensagem de quem não grava (a do iOS), âmbar para o "sem som".
        binding.textGravacaoCamera.tipo = if (naoGrava) AvisoDaTela.Tipo.INFO else AvisoDaTela.Tipo.AMBAR
        val visTexto = if (texto.isEmpty()) View.GONE else View.VISIBLE
        if (binding.textGravacaoCamera.desejada != visTexto) binding.textGravacaoCamera.visibility = visTexto
        if (binding.textGravacaoCamera.text.toString() != texto) binding.textGravacaoCamera.text = texto
        desenharGravarDaPlaca()
        // Os três controles redondos: com a câmera (ou o vídeo USB) no ar, sempre — o parar está lá.
        val daCamera = MirrorBus.atual.let { m -> !m.daTelaR5 && !m.doDvd && !m.daTela }
        val linha = if (noAr && daCamera) View.VISIBLE else View.GONE
        // Deitado, Ouvir e Foto moram na linha do alto (ver [arrumarModoDaEspera]): a linha de baixo some.
        val linhaDaPlaca = if (ouvirDaPlaca.visibility == View.VISIBLE && ouvirDaPlaca.parent === binding.linhaDaPlacaNoAr) View.VISIBLE else View.GONE
        if (binding.linhaDaPlacaNoAr.visibility != linhaDaPlaca) binding.linhaDaPlacaNoAr.visibility = linhaDaPlaca
        if (binding.linhaDosControlesDaCamera.visibility != linha) binding.linhaDosControlesDaCamera.visibility = linha
        desenharBotaoDeBaixo()
    }

    /** O Gravar da placa na tela da transmissão: com a placa no ar, pelo estado do [GravacaoBus]. */
    private fun desenharGravarDaPlaca() {
        val m = MirrorBus.atual
        val existe = m.daPlaca && (m.fase == MirrorBus.Fase.ESPERANDO || m.fase == MirrorBus.Fase.ESPELHANDO)
        val vis = if (existe) View.VISIBLE else View.GONE
        if (gravarDaPlaca.visibility != vis) gravarDaPlaca.visibility = vis
        if (ouvirDaPlaca.visibility != vis) ouvirDaPlaca.visibility = vis
        if (fotoDaPlaca.visibility != vis) fotoDaPlaca.visibility = vis
        if (!existe) return
        desenharOuvir()
        val g = GravacaoBus.estado
        val fase = when (g.fase) {
            GravacaoBus.Fase.PREPARANDO -> GravacaoDaTelaBus.Fase.COMECANDO
            GravacaoBus.Fase.GRAVANDO -> GravacaoDaTelaBus.Fase.GRAVANDO
            else -> GravacaoDaTelaBus.Fase.PARADA
        }
        // "SEM SOM" quando o som da placa não vai ao arquivo (sem a permissão, ou o som falhou).
        gravarDaPlaca.atualizar(fase, g.decorridoMs, g.espacoLivre, microfoneLigado = g.avisoDoSom == null, habilitado = true)
    }

    /**
     * O botão de baixo. A tela: "Cancelar" (secundário) na espera, "Parar de espelhar" (perigo) no ar. A
     * câmera: o parar redondo diz "Cancelar", "Parar" ou "Parar e salvar" (a gravação).
     */
    private fun desenharBotaoDeBaixo() {
        val e = MirrorBus.atual
        val daTela = e.daTela
        // (A gravação da placa não entra: ela é do `GravacaoDvService` e segue depois de parar a
        // transmissão; o Gravar dela tem o próprio Parar.)
        val gravando = GravacaoDaTelaBus.atual.let { it.daCameraComum && it.ocupada }
        val noAr = e.fase == MirrorBus.Fase.ESPELHANDO
        when {
            gravando -> pararDaCamera.rotulo(getString(R.string.in_parar_e_salvar), getString(R.string.in_parar_e_salvar_descricao))
            noAr -> pararDaCamera.rotulo(getString(R.string.in_parar), getString(R.string.in_parar))
            else -> pararDaCamera.rotulo(getString(R.string.cancelar), getString(R.string.cancelar))
        }
        val vis = if (daTela) View.VISIBLE else View.GONE
        if (binding.buttonMirrorCancel.visibility != vis) binding.buttonMirrorCancel.visibility = vis
        val rotulo = if (noAr && daTela) getString(R.string.parar) else getString(R.string.cancelar)
        if (binding.buttonMirrorCancel.text.toString() == rotulo) return
        binding.buttonMirrorCancel.text = rotulo
        val b = binding.buttonMirrorCancel
        if (noAr && daTela) {
            b.backgroundTintList = android.content.res.ColorStateList.valueOf(Cores.comAlfa(Cores.NO_AR, 0.18f))
            b.setTextColor(Cores.PERIGO_TEXTO)
            b.setIconResource(R.drawable.ic_q_parar)
            b.iconTint = android.content.res.ColorStateList.valueOf(Cores.PERIGO_TEXTO)
            b.iconSize = dp(16)
        } else {
            b.backgroundTintList = androidx.appcompat.content.res.AppCompatResources.getColorStateList(this, R.color.botao_secundario_fundo)
            b.setTextColor(androidx.appcompat.content.res.AppCompatResources.getColorStateList(this, R.color.botao_secundario_texto))
            b.icon = null
        }
    }

    /** A tela é uma função pura do estado do serviço — nada de estado próprio aqui. */
    private fun desenharEspelhamento(estado: MirrorBus.Estado) {
        telaLigada.atualizar()
        // A sessão da R5 é da tela dela: aqui ela conta como parado, sem aviso, e a home fica onde
        // estava (a escolha do papel, de onde a R5 foi aberta). A do DVD também (a tela "Converter
        // DVD" a desenha; `docs/dvd-para-mp4.md` §9).
        val e = if (estado.daTelaR5 || estado.doDvd) MirrorBus.Estado() else estado
        // A prévia aparece **desde a espera**, e não só ao espelhar. É a mudança de 03/09: quem vai
        // transmitir a câmera acerta o enquadramento enquanto o receptor ainda não conectou, do
        // jeito que o iOS já faz (`apps/ios/Quall/App/TelaDaCamera.swift`, com a `AVCaptureSession`
        // independente da sessão do Quall). Nas duas fases a câmera está de fato aberta — o
        // `MirrorService` a abre antes do laço de espera —, então a prévia não mente sobre o
        // aparelho estar filmando. Em PARADO e ERRO não há câmera, e ali ela some.
        //
        // Alternar `visibility` e **não** o provedor de superfície: `Preview.setSurfaceProvider`
        // com provedor novo dispara `notifyReset()`, que reconfigura a sessão de captura com o
        // codificador no ar; esconder uma view não custa nada.
        // O vídeo USB (a filmadora DV e a placa) não passa pela `PreviewView`: ela ficaria preta. Dito
        // pelo campo do estado, e não pelo texto do rótulo (§11, item 2).
        val noAr = e.fase == MirrorBus.Fase.ESPERANDO || e.fase == MirrorBus.Fase.ESPELHANDO
        val daDv = e.videoUsb
        val mostrarPrevia = noAr && !e.daTela && !daDv
        // A DV tem a prévia dela, desenhada pela GPU numa SurfaceView (`PreviaDv`).
        binding.mirrorPreviaDv.visibility = if (noAr && daDv) View.VISIBLE else View.GONE
        // `TelaLigada` impede o bloqueio automático enquanto esta janela está visível. No
        // espelhamento da tela, sair para outro app volta a deixar o tempo de bloqueio com o sistema.
        //
        // Tentado em 09/09/2026 para impedir o gatilho que derruba o espelhamento de tela: ao
        // bloquear, o Android revoga a captura (`MediaProjection.onStop — o consentimento de
        // gravação terminou`) e a sessão encerra 80 ms depois, limpa. Como o token morre junto e
        // a plataforma exige gesto novo do usuário, não há volta automática — diferente da
        // câmera, que o CameraX reabre sozinho em 731 ms.
        //
        // A bandeira é inerte no caso que importa: `FLAG_KEEP_SCREEN_ON` é de **janela**, e vale
        // só enquanto a janela está visível. Quem espelha a tela vai para outro app — é o sentido
        // de espelhar a tela —, e o log confirma: `WindowStopped ... set to true`. O precedente
        // da `ReceptorActivity` funciona porque ela fica na frente o tempo todo; esta não fica.
        //
        // O caminho que sobra não é técnico do lado do emissor: é tratar bem o encerramento (a
        // mensagem já existe, em `MirrorService`) e oferecer retomada em um toque, porque o
        // consentimento novo é obrigatório e só o usuário pode dá-lo.
        // A câmera comum pelo dono (§8.6) desenha na `SurfaceView` do divisor; o braço de controle de
        // bancada (`camera_comum_pelo_camerax`), na `PreviewView` do CameraX.
        val peloDono = !com.quall.android.core.Bancada.cameraComumPeloCameraX(this)
        val visibilidadeDaPrevia = if (mostrarPrevia && !peloDono) View.VISIBLE else View.GONE
        binding.mirrorPrevia.visibility = visibilidadeDaPrevia
        val previaDoDonoVisivel = if (mostrarPrevia && peloDono) View.VISIBLE else View.GONE
        if (binding.mirrorPreviaDono.visibility != previaDoDonoVisivel) binding.mirrorPreviaDono.visibility = previaDoDonoVisivel
        binding.mirrorVeu.visibility = if (mostrarPrevia || (noAr && daDv)) View.VISIBLE else View.GONE
        // **A prévia suspensa é dita, não escondida.** Sem esta linha o usuário veria o retângulo
        // da câmera vazio e concluiria que a transmissão caiu — quando é o contrário: ela está no
        // ar, e é justamente por isso que a prévia não entra. Ver `PreviaDaCamera`.
        binding.textPreviaSuspensa.visibility =
            if (mostrarPrevia && com.quall.android.capture.PreviaDaCamera.previaSuspensa) {
                binding.mirrorPrevia.visibility = View.GONE
                binding.mirrorVeu.visibility = View.GONE
                View.VISIBLE
            } else {
                View.GONE
            }
        when (e.fase) {
            MirrorBus.Fase.PARADO, MirrorBus.Fase.ERRO -> {
                mostrarIconeDosAjustes(false)
                binding.mirrorOverlay.visibility = View.GONE
                binding.mirrorAnimated.visibility = View.GONE
                mostrarHome()
                inicioDaEspera = 0L
                anunciaNaRede = true
                // O motivo de a espera ter acabado precisa chegar ao usuário: a mensagem mais
                // importante daqui é a do Android 14+ encerrando o consentimento junto com a sessão,
                // e ela explica por que a tela voltou sozinha. Na caixa de aviso de Espelhar, como o
                // `Aviso` do iOS (`emissor.conselho`), e não num `Toast` que some.
                if (e.mensagem.isNotBlank()) {
                    binding.textStatus.text = if (e.fase == MirrorBus.Fase.ERRO) "erro: ${e.mensagem}" else e.mensagem // i18n-fora: diagnóstico de bancada (os sete toques)
                    // Uma vez por mensagem, e não "se a espera estava à vista": numa tela recriada
                    // (a volta do segundo plano) a espera nunca esteve, e o aviso se perdia (a
                    // revisão do código, 28/09). A marca mora no processo (companion).
                    if (e.mensagem != mensagemDoFimVista) {
                        mensagemDoFimVista = e.mensagem
                        binding.textCameraNote.setOnClickListener(null)
                        binding.textCameraNote.visibility = View.VISIBLE
                        binding.textCameraNote.text = e.mensagem.replaceFirstChar { it.uppercase() }
                    }
                }
            }

            MirrorBus.Fase.ESPERANDO, MirrorBus.Fase.ESPELHANDO -> {
                mensagemDoFimVista = ""
                esconderHome()
                binding.mirrorOverlay.visibility = View.VISIBLE
                // **Espelhar a tela é espelhar A TELA**, e por padrão nada é pintado por cima: a view
                // animada só existe atrás de `Bancada.conteudoAnimado` (ela dá à `VirtualDisplay` algo
                // que muda, que é o que uma corrida de taxa precisa). Com câmera ela some.
                binding.mirrorAnimated.visibility =
                    if (e.fase == MirrorBus.Fase.ESPELHANDO && e.daTela &&
                        com.quall.android.core.Bancada.conteudoAnimado(this)
                    ) View.VISIBLE else View.GONE
                desenharBlocoDaEspera(e)
            }
        }
    }

    /** O que a espera desenhou por último (ver [desenharBlocoDaEspera]). */
    private var ultimaEspera: List<Any?>? = null

    /** Quando a espera começou (para o "Abrindo a câmera…" não ficar para sempre). 0 fora dela. */
    private var inicioDaEspera = 0L

    /** O modo em que as colunas da espera foram arrumadas por último (câmera, paisagem). */
    private var modoDaEsperaArrumado: Pair<Boolean, Boolean>? = null

    /**
     * **A espera e o espelhamento no "Estúdio de bolso"** (`docs/telas-estudio.md` §6.4, §6.5, §11).
     *
     * | | a luz (pílula) | o bloco |
     * |---|---|---|
     * | câmera abrindo | ABRINDO (âmbar, com a roda) | nada ainda (o PIN só com a câmera montada) |
     * | esperando, sem pares | AGUARDANDO | a instrução, "NA PRIMEIRA VEZ, O PIN" e o letreiro, "ou pelo endereço" e o chip |
     * | esperando, com pares | AGUARDANDO | a instrução, "Aparelhos pareados entram direto.", o chip e "Aparelho novo? PIN 482 719" |
     * | enviando | NO AR | "Espelhando para" / "Enviando para" e o par — **sem PIN nem endereço** |
     *
     * A tela tem os anéis, o título "Pronto para espelhar" e o botão de baixo; a câmera tem a prévia, a
     * pílula no alto com a resolução e o nome da câmera, o bloco num cartão de vidro e os três controles
     * redondos.
     *
     * O PIN **nunca** some na espera: "há pares conhecidos" é "conheço **algum** par", não "conheço
     * **este**" (`docs/ux-m6.md`, tarefa 1). `textPin` é um `TextView` só, visível com e sem pares, com o
     * PIN no texto ("482 719") — a bancada o lê (§11.3). "Abrindo" é só para a câmera pelo dono (a DV e o
     * braço CameraX não têm o sinal), e no máximo 8 s — depois o PIN aparece de qualquer jeito.
     */
    private fun desenharBlocoDaEspera(e: MirrorBus.Estado) {
        val agora = android.os.SystemClock.elapsedRealtime()
        if (e.fase == MirrorBus.Fase.ESPERANDO) {
            if (inicioDaEspera == 0L) inicioDaEspera = agora
        } else {
            inicioDaEspera = 0L
        }
        val daTela = e.daTela
        val daDv = e.videoUsb
        val peloDono = !com.quall.android.core.Bancada.cameraComumPeloCameraX(this)
        val enviando = e.fase == MirrorBus.Fase.ESPELHANDO
        val abrindo = !daTela && !daDv && peloDono && e.fase == MirrorBus.Fase.ESPERANDO &&
            !MirrorService.cameraEntregando(1_000) && agora - inicioDaEspera < 8_000
        val espera = e.fase == MirrorBus.Fase.ESPERANDO && !abrindo
        val pares = EstadoDasTelas.paresDaVitrine ?: eu.temParesConhecidos()
        val diagnosticoAgora = binding.diagnosticoSection.visibility == View.VISIBLE
        // O anúncio que a espera viu por último (a mensagem é trocada depois; ver [anunciaNaRede]).
        // Pelo campo, e não pelo texto da mensagem: ela é traduzida (`docs/traducao.md`).
        e.anunciando?.let { anunciaNaRede = it }
        val paisagem = resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
        // A espera da tela em duas colunas só na tela baixa (o celular deitado; 30/09): no tablet deitado,
        // uma coluna, com os anéis, como em pé. A câmera no ar segue com os controles na borda em qualquer
        // paisagem.
        val baixa = telaBaixa()
        // O tique de 500 ms chama sem mudança: só redesenha quando algo do que a tela mostra mudou
        // (a revisão do código, 28/09: cada `setText` igual ainda pede layout e fala ao leitor de tela).
        val chave = listOf(e, abrindo, pares, diagnosticoAgora, eu.displayName, anunciaNaRede, paisagem, baixa)
        if (chave == ultimaEspera) return
        ultimaEspera = chave

        val camera = !daTela
        arrumarModoDaEspera(camera, paisagem)
        // O fundo: a prévia na câmera (preto atrás dela); na tela, o brilho âmbar esperando e o vermelho no ar (§2).
        binding.mirrorOverlay.setBackgroundResource(when {
            camera -> R.color.q_preto
            enviando -> R.drawable.fundo_no_ar
            else -> R.drawable.fundo_espera
        })

        // A luz de estúdio.
        val luz = when {
            abrindo -> PilulaDeEstado.Estado.ABRINDO
            enviando -> PilulaDeEstado.Estado.NO_AR
            else -> PilulaDeEstado.Estado.AGUARDANDO
        }
        binding.pilulaDoAlto.mostrar(luz)
        binding.pilulaCentral.mostrar(luz)
        binding.pilulaDoAlto.visibility = if (camera) View.VISIBLE else View.GONE
        binding.pilulaCentral.visibility = if (camera) View.GONE else View.VISIBLE
        binding.aneisDaEspera.visibility = if (!camera && !enviando && !baixa) View.VISIBLE else View.GONE
        binding.textMirrorTitle.visibility = if (!camera && !enviando) View.VISIBLE else View.GONE
        // Qual câmera está no ar (a tela não precisa: é "a tela").
        binding.textMirrorOrigem.text = if (daTela) "" else e.nomeDaCamera
        binding.textMirrorOrigem.visibility = if (camera) View.VISIBLE else View.GONE
        // O que está no ar, em mono pequeno no alto: o entregue (`core/Entrega.kt`) quando se sabe; na
        // espera da câmera, o pedido. O motivo de a entrega não ser a pedida vira Aviso de informação.
        val entregue = when {
            e.entregue.isNotBlank() -> e.entregueCurto
            camera && !daDv && e.fase == MirrorBus.Fase.ESPERANDO -> {
                val cardapio = estadoDoCardapio()
                "${cardapio.resolucaoPara(com.quall.android.core.Resolucao.escolhida(this)).rotulo} · ${cardapio.quadrosPara(com.quall.android.core.Resolucao.quadros(this))} fps"
            }
            else -> ""
        }
        binding.textEntrega.text = entregue
        binding.textEntrega.gravity = if (camera) android.view.Gravity.START else android.view.Gravity.CENTER_HORIZONTAL
        // A engrenagem continua à mão na espera e durante a transmissão, inclusive da tela.
        binding.linhaDoAlto.visibility = View.VISIBLE
        // Os ajustes da câmera (R9, §4.1): a câmera do aparelho pelo dono; nunca a `usb-dv:` (§2.2).
        mostrarIconeDosAjustes(camera && !daDv && peloDono, emSessao = true)
        val motivo = if (enviando && e.entregue.isNotBlank() && e.motivoDaEntrega.isNotBlank()) {
            // **Pedido × entregue, e por quê.** Em 10/09/2026 o usuário pediu 4K 60 na frontal do S24 e
            // recebeu 1920x1080 a 60 sem nenhuma palavra.
            getString(R.string.in_pedido_e_entregue, e.pedido, e.entregue, e.motivoDaEntrega.replaceFirstChar { it.uppercase() })
        } else {
            ""
        }
        binding.avisoDaEntrega.text = motivo
        binding.avisoDaEntrega.visibility = if (motivo.isEmpty()) View.GONE else View.VISIBLE
        binding.avisoConteudoProtegido.visibility = if (daTela && enviando) View.VISIBLE else View.GONE
        // O estado do anúncio não é aviso (o iOS não o mostra): só o que é (`mensagemDoVideoEhAviso`).
        binding.textAvisoDaTransmissao.visibility = if (mensagemDoVideoEhAviso(e)) View.VISIBLE else View.GONE
        binding.textAvisoDaTransmissao.text = e.mensagem.replaceFirstChar { it.uppercase() }

        // O bloco da espera.
        binding.textMirrorInstructions.visibility = if (espera) View.VISIBLE else View.GONE
        binding.textMirrorInstructions.text = instrucaoDaEspera(
            e.aliasNaRede.takeIf { anunciaNaRede && it.isNotBlank() }
        )
        binding.blocoParConhecido.visibility = if (espera && pares) View.VISIBLE else View.GONE
        val vEspera = if (espera) View.VISIBLE else View.GONE
        binding.pinGroup.visibility = vEspera
        binding.addressGroup.visibility = vEspera
        // A ordem: sem pares, o PIN primeiro; com pares, o endereço primeiro e o PIN embaixo.
        val pai = binding.mirrorContent
        val iPin = pai.indexOfChild(binding.pinGroup)
        val iEnd = pai.indexOfChild(binding.addressGroup)
        if (pares && iPin < iEnd) {
            pai.removeView(binding.pinGroup)
            pai.addView(binding.pinGroup, pai.indexOfChild(binding.addressGroup) + 1)
        } else if (!pares && iPin > iEnd) {
            pai.removeView(binding.pinGroup)
            pai.addView(binding.pinGroup, pai.indexOfChild(binding.addressGroup))
        }
        (binding.pinGroup.layoutParams as? android.view.ViewGroup.MarginLayoutParams)?.let { lp ->
            // Deitado com a câmera (ou a placa), recuos menores: a coluna da esquerda é baixa (o R16, 30/09).
            val topo = if (camera && paisagem) dp(if (pares) 8 else 10) else if (pares) dp(12) else dp(16)
            if (lp.topMargin != topo) { lp.topMargin = topo; binding.pinGroup.layoutParams = lp }
        }
        // Sem pares, o rótulo em cima e o letreiro; com pares, a linha curta "Aparelho novo? PIN 482 719".
        binding.pinGroup.orientation = if (pares) android.widget.LinearLayout.HORIZONTAL else android.widget.LinearLayout.VERTICAL
        binding.textPinRotulo.apply {
            text = getString(if (pares) R.string.in_aparelho_novo_pin else R.string.in_primeira_vez_pin)
            isAllCaps = !pares
            letterSpacing = if (pares) 0f else 0.08f
            setTextSize(TypedValue.COMPLEX_UNIT_SP, if (pares) 15f else 12f)
            setTextColor(if (pares) Cores.TEXTO2 else Cores.TEXTO3)
        }
        binding.textPin.emLinha = pares
        (binding.textPin.layoutParams as? android.view.ViewGroup.MarginLayoutParams)?.let { lp ->
            val (topo, esquerda) = if (pares) 0 to dp(6) else dp(10) to 0
            if (lp.topMargin != topo || lp.leftMargin != esquerda) {
                lp.topMargin = topo
                lp.leftMargin = esquerda
                binding.textPin.layoutParams = lp
            }
        }
        // Sem PIN ainda, vazio: um marcador ("——— ———") seria lido como PIN pelas ferramentas de bancada.
        binding.textPin.mostrar(e.pin)
        binding.textEnderecoRotulo.visibility = if (pares) View.GONE else View.VISIBLE
        val primeiro = e.enderecos.firstOrNull()
        binding.textMirrorAddress.text = primeiro ?: getString(R.string.in_sem_rede_minuscula)
        binding.textMirrorAddress.copiavel = primeiro != null
        binding.textMirrorAddress.setTextColor(if (primeiro == null) Cores.AGUARDANDO_TEXTO else Cores.TEXTO)
        val outros = e.enderecos.drop(1)
        binding.textOutrosEnderecos.visibility = if (outros.isEmpty()) View.GONE else View.VISIBLE
        binding.textOutrosEnderecos.text = getString(R.string.in_tambem, outros.joinToString("  ·  "))
        binding.blocoEnviando.visibility = if (enviando) View.VISIBLE else View.GONE
        binding.textEnviandoRotulo.text = getString(if (daTela) R.string.in_espelhando_para else R.string.in_enviando_para)
        binding.textEnviandoPar.text = e.par.ifBlank { getString(R.string.in_outro_aparelho) }
        // Deitado, a nota sai: a altura não comporta o bloco da espera e ela (§11.1).
        binding.textNotaDaNotificacao.visibility = if (camera && !paisagem) View.VISIBLE else View.GONE
        if (camera) microfoneDaCamera.atualizar(MicrofoneBus.atual, comReceptor = enviando)

        // Os números técnicos, só com o diagnóstico à mostra. Taxa **e** latência, sempre juntas:
        // é o par que teria denunciado, na hora, a fila que multiplicou por nove a latência do A07.
        val diagnostico = binding.diagnosticoSection.visibility == View.VISIBLE
        binding.textMirrorStats.visibility = if (diagnostico) View.VISIBLE else View.GONE
        if (diagnostico) {
            binding.textMirrorStats.text = if (enviando) buildString {
                append("pareado ${if (e.pareamentoNovo) "agora por PIN" else "retomado, sem PIN"}\n") // i18n-fora: diagnóstico de bancada (os sete toques)
                append("fps: pedido=${e.fpsPedido} obtido=${"%.1f".format(e.fpsObtido)}\n") // i18n-fora: diagnóstico de bancada (os sete toques)
                if (e.latenciaConfiavel) {
                    append("latência de encode: p50=${"%.1f".format(e.latenciaP50Ms)} ms · ") // i18n-fora: diagnóstico de bancada (os sete toques)
                    append("p95=${"%.1f".format(e.latenciaP95Ms)} ms\n") // i18n-fora: diagnóstico de bancada (os sete toques)
                } else {
                    // Medido, não presumido: em algumas câmeras o presentationTimeUs não é comparável
                    // a relógio de sistema nenhum (ver H264SurfaceEncoder).
                    append("latência de encode: não confiável nesta câmera (relógio incomparável)\n") // i18n-fora: diagnóstico de bancada (os sete toques)
                }
                append("quadros enviados: ${e.quadrosEnviados}  falhas: ${e.falhasDeEnvio}\n") // i18n-fora: diagnóstico de bancada (os sete toques)
                append("IDR no fluxo: ${e.idrsEnviados}  pedidos do receptor: ${e.pedidosDeIdr}\n") // i18n-fora: diagnóstico de bancada (os sete toques)
                if (e.estatisticasDoNucleo.isNotBlank()) append("núcleo: ${e.estatisticasDoNucleo}") // i18n-fora: diagnóstico de bancada (os sete toques)
            } else {
                // **A tentativa 1 aparece também**, desde 05/09/2026 (`docs/bancada.md` §8.33).
                "esperando um receptor · tentativa ${e.tentativa}" // i18n-fora: diagnóstico de bancada (os sete toques)
            }
        }
        desenharBotaoDeBaixo()
    }

    /**
     * A instrução da espera (§6.4): com anúncio na rede, "No outro aparelho, abra o Quall em **Exibir** e
     * escolha **{alias}** na lista, ou digite o endereço abaixo."; sem, "… e digite o endereço abaixo.".
     */
    private fun instrucaoDaEspera(nome: String?): CharSequence {
        val exibir = getString(R.string.in_exibir)
        return if (nome != null) {
            comArgumentosFortes(getString(R.string.in_instrucao_com_nome), exibir, nome)
        } else {
            comArgumentosFortes(getString(R.string.in_instrucao_sem_nome), exibir)
        }
    }

    /**
     * [formato] (`%1$s`, `%2$s`…, do recurso) com os argumentos **em negrito e na cor do texto**: a ordem
     * das palavras muda de um idioma para o outro, e os destaques vão junto.
     */
    private fun comArgumentosFortes(formato: String, vararg args: String): CharSequence {
        val t = android.text.SpannableStringBuilder()
        var i = 0
        val marca = Regex("%(\\d+)[$]s")
        for (m in marca.findAll(formato)) {
            t.append(formato, i, m.range.first)
            val arg = args[m.groupValues[1].toInt() - 1]
            val ini = t.length
            t.append(arg)
            t.setSpan(android.text.style.StyleSpan(android.graphics.Typeface.BOLD), ini, t.length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            t.setSpan(android.text.style.ForegroundColorSpan(Cores.TEXTO), ini, t.length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            i = m.range.last + 1
        }
        t.append(formato, i, formato.length)
        return t
    }

    /**
     * As colunas da espera pelo modo (§11.1): na tela, em paisagem, a pílula, o título e a instrução à
     * esquerda, e o letreiro, o chip, os avisos e o "Cancelar" à direita; na câmera, tudo à esquerda e
     * os três controles numa coluna na borda direita. O vidro (o bloco da espera sobre a prévia) só na
     * câmera. Os filhos continuam os mesmos, no mesmo pai.
     */
    private fun arrumarModoDaEspera(camera: Boolean, paisagem: Boolean) {
        val modo = camera to paisagem
        if (modo == modoDaEsperaArrumado) return
        modoDaEsperaArrumado = modo
        val c = binding.mirrorContent
        c.vidroLigado = camera
        // As duas colunas da tela só na tela baixa; as da câmera (os controles na borda) em qualquer paisagem.
        c.soNaTelaBaixa = !camera
        c.fracaoDaDireita = if (camera) 0.24f else 0.5f
        c.centralizarADireita = camera
        // No tablet: a espera da tela numa coluna de no máximo 560 dp, centrada na altura; a câmera ocupa a
        // tela como está (só o vidro ganha o teto). No celular não muda nada.
        c.limitarLargura = !camera
        c.centralizarNaAltura = !camera
        val daDireitaNaTela = setOf<View>(binding.blocoParConhecido, binding.pinGroup, binding.addressGroup,
            binding.avisosDaEspera, binding.buttonMirrorCancel)
        for (i in 0 until c.childCount) {
            val v = c.getChildAt(i)
            (v.layoutParams as? ColunasDaTela.LayoutParams)?.direita =
                if (camera) v === binding.linhaDosControlesDaCamera else v in daDireitaNaTela
        }
        // Os controles: numa linha em retrato, numa coluna em paisagem — juntos, deitado (a coluna inteira
        // tem de caber nos ~310 dp do A07 e do A10s deitados; no A10s o Cancelar saía cortado embaixo).
        val emColuna = camera && paisagem
        binding.linhaDosControlesDaCamera.orientation =
            if (emColuna) android.widget.LinearLayout.VERTICAL else android.widget.LinearLayout.HORIZONTAL
        listOf(binding.casaDoMicrofone, binding.casaDoGravar, binding.casaDoParar).forEachIndexed { i, casa ->
            casa.layoutParams = if (emColuna) {
                android.widget.LinearLayout.LayoutParams(android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                    android.widget.LinearLayout.LayoutParams.WRAP_CONTENT).apply { if (i > 0) topMargin = dp(8) }
            } else {
                android.widget.LinearLayout.LayoutParams(0, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
        }
        (binding.linhaDosControlesDaCamera.layoutParams as? android.view.ViewGroup.MarginLayoutParams)?.let { lp ->
            lp.topMargin = dp(if (emColuna) 0 else 16)
            binding.linhaDosControlesDaCamera.layoutParams = lp
        }
        (binding.addressGroup.layoutParams as? android.view.ViewGroup.MarginLayoutParams)?.let { lp ->
            lp.topMargin = dp(if (emColuna) 10 else 16)
            binding.addressGroup.layoutParams = lp
        }
        // A placa no ar, deitada: Ouvir e Foto vão para a linha do alto, ao lado do nome da fonte — na linha
        // de baixo, a coluna da esquerda passava da altura e a tela rolava no A07 (a foto de 30/09).
        val destino = if (emColuna) binding.linhaDoAlto else binding.linhaDaPlacaNoAr
        for ((i, botao) in listOf(ouvirDaPlaca, fotoDaPlaca).withIndex()) {
            if (botao.parent === destino) continue
            (botao.parent as? android.view.ViewGroup)?.removeView(botao)
            destino.addView(botao, android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { leftMargin = if (emColuna || i > 0) dp(8) else 0 })
        }
        if (emColuna) binding.linhaDaPlacaNoAr.visibility = View.GONE
        val alinhamento = if (camera) android.view.Gravity.START else android.view.Gravity.CENTER_HORIZONTAL
        binding.blocoEnviando.gravity = alinhamento
        binding.textEnviandoPar.gravity = alinhamento
        c.requestLayout()
    }

    // --- Descoberta -------------------------------------------------------------------------

    private fun procurarAparelhos() {
        if (!QuallNative.carregado) {
            binding.textStatus.text = descreverNucleo()
            return
        }
        // O lock vale para receber multicast; sem ele o Android filtra em economia de energia e a
        // varredura volta vazia sem erro nenhum.
        multicastLock.acquire()
        binding.textStatus.text = "procurando ${QuallNative.serviceType()} por 5 s (lock=${multicastLock.isHeld()})…" // i18n-fora: diagnóstico de bancada (os sete toques)
        thread(name = "quall-browse") { // i18n-fora: diagnóstico de bancada (os sete toques)
            // Este aparelho também anuncia enquanto espelha, e o anúncio sobrevive ao fim da
            // sessão (`quall_advertiser_stop` não desregistra — `docs/divida-do-nucleo.md`,
            // item 3). Sem filtrar pelo próprio `device_id`, o emissor aparece na própria lista.
            // Tocar num item abre a tela de **exibir vídeo**: quem anuncia papel (um teleprompter)
            // não entra — ver `core/Papeis.kt`.
            val achados = com.quall.android.core.Papeis.soDeVideo(
                QuallBrowser.varrer(5_000).filter { it.deviceId != eu.deviceId }
            )
            runOnUiThread {
                deviceAdapter.submit(achados)
                binding.textStatus.text =
                    "${achados.size} aparelho(s) esperando na rede (lock=${multicastLock.isHeld()})" // i18n-fora: diagnóstico de bancada (os sete toques)
            }
        }
    }

    private fun onDeviceTapped(device: QuallBrowser.Device) {
        // A lista de diagnóstico agora conecta de verdade: leva para a tela de exibir com o
        // endereço já preenchido. Quando o aparelho não anunciou endereço utilizável, dizer isso
        // é mais útil que abrir uma tela que só poderia falhar.
        val endpoint = device.endpoint
        if (endpoint == null) {
            Toast.makeText(
                this,
                "${device.displayName} — sem endereço utilizável no anúncio.", // i18n-fora: diagnóstico de bancada (os sete toques)
                Toast.LENGTH_LONG,
            ).show()
            return
        }
        abrirReceptor(endpoint)
    }

    /** Abre a tela de quem exibe, opcionalmente já com um endereço escolhido. */
    private fun abrirReceptor(endpoint: String?) {
        if (!QuallNative.carregado) {
            Toast.makeText(this, descreverNucleo(), Toast.LENGTH_LONG).show()
            return
        }
        val intent = Intent(this, ReceptorActivity::class.java)
        if (endpoint != null) intent.putExtra(ReceptorActivity.EXTRA_ENDPOINT, endpoint)
        startActivity(intent)
    }

    /** As duas telas do teleprompter (F6b). Sem núcleo não há sessão nem réplica: diz em vez de abrir. */
    private fun abrirTeleprompter(tela: Class<*>) {
        if (!QuallNative.carregado) {
            Toast.makeText(this, descreverNucleo(), Toast.LENGTH_LONG).show()
            return
        }
        startActivity(Intent(this, tela))
    }

    private fun runMulticastTest(withLock: Boolean) {
        if (withLock) multicastLock.acquire() else multicastLock.release()
        binding.textStatus.text = "Ouvindo 224.0.0.251:5353 por 10s (lock=${multicastLock.isHeld()})…" // i18n-fora: diagnóstico de bancada (os sete toques)
        thread(name = "quall-multicast-test") { // i18n-fora: diagnóstico de bancada (os sete toques)
            val result = MulticastProbe.listen(10_000)
            runOnUiThread {
                binding.textStatus.text =
                    "multicast: ${result.received} pacote(s) de ${result.fromAddresses} " + // i18n-fora: diagnóstico de bancada (os sete toques)
                        "(lock=${multicastLock.isHeld()})" // i18n-fora: diagnóstico de bancada (os sete toques)
            }
        }
    }

    // --- Verificação sem rede ----------------------------------------------------------------

    private fun startCapture(mode: String) {
        pendingMode = mode
        val mpm = getSystemService(MediaProjectionManager::class.java)
        binding.textStatus.text = "pedindo consentimento de captura de tela (aparece a cada sessão — esperado)…" // i18n-fora: diagnóstico de bancada (os sete toques)
        screenCapturePermission.launch(mpm.createScreenCaptureIntent())
    }

    /** Mesma ideia de [startCapture], para o preset `camera`: instrumento de bancada, sem rede. */
    private fun startCameraSidecarTest() {
        if (!QuallNative.carregado) {
            binding.textStatus.text = descreverNucleo()
            return
        }
        val opcao = fonteCameraSelecionada()
        if (opcao == null) {
            Toast.makeText(this, "Escolha uma câmera no seletor de origem antes de testar.", Toast.LENGTH_LONG).show() // i18n-fora: diagnóstico de bancada (os sete toques)
            return
        }
        if (opcao.id.startsWith(UsbDv.PREFIXO_DO_ID)) {
            binding.textStatus.text = "o teste de bancada de câmera é só do CameraX; a filmadora DV não entra nele" // i18n-fora: diagnóstico de bancada (os sete toques)
            return
        }
        pendingCamera = opcao
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            binding.textStatus.text = "pedindo permissão de câmera para o teste de bancada…" // i18n-fora: diagnóstico de bancada (os sete toques)
            cameraSidecarPermission.launch(Manifest.permission.CAMERA)
            return
        }
        lancarCameraSidecar(opcao)
    }

    private val cameraSidecarPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { concedida ->
        val opcao = pendingCamera
        if (concedida && opcao != null) {
            lancarCameraSidecar(opcao)
        } else {
            binding.textStatus.text = "permissão de câmera negada — não dá para rodar o teste de bancada" // i18n-fora: diagnóstico de bancada (os sete toques)
        }
    }

    private fun lancarCameraSidecar(opcao: CameraEnumerator.CameraOption) {
        binding.textStatus.text = "iniciando captura de câmera (${opcao.label})…" // i18n-fora: diagnóstico de bancada (os sete toques)
        val intent = Intent(this, CameraCaptureService::class.java).apply {
            putExtra(CameraCaptureService.EXTRA_CAMERA_ID, opcao.id)
            putExtra(CameraCaptureService.EXTRA_CAMERA_LABEL, opcao.label)
        }
        ContextCompat.startForegroundService(this, intent)
    }

    // --- Consentimento ------------------------------------------------------------------------

    private fun onProjectionResult(result: androidx.activity.result.ActivityResult) {
        if (result.resultCode != Activity.RESULT_OK || result.data == null) {
            binding.textStatus.text = "consentimento de captura negado" // i18n-fora: diagnóstico de bancada (os sete toques)
            return
        }

        val metrics = DisplayMetrics()
        val size = Point()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            size.set(bounds.width(), bounds.height())
            metrics.densityDpi = resources.displayMetrics.densityDpi
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealSize(size)
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealMetrics(metrics)
        }

        val modo = pendingMode
        if (modo == null) {
            val intent = Intent(this, MirrorService::class.java).apply {
                putExtra(MirrorService.EXTRA_SOURCE_KIND, MirrorService.SOURCE_SCREEN)
                putExtra(MirrorService.EXTRA_RESULT_CODE, result.resultCode)
                putExtra(MirrorService.EXTRA_RESULT_DATA, result.data)
                putExtra(MirrorService.EXTRA_WIDTH, size.x)
                putExtra(MirrorService.EXTRA_HEIGHT, size.y)
                putExtra(MirrorService.EXTRA_DPI, metrics.densityDpi)
            }
            ContextCompat.startForegroundService(this, intent)
            return
        }

        // Origem densa: mosaico sintético de semente fixa, para o IDR nascer no porte da tela
        // real (~60 pacotes) em vez de meia dúzia. Ver `Bancada.origemDensa`.
        binding.animatedContent.denso = com.quall.android.core.Bancada.origemDensa(this)
        // **A mesma origem vale para a view do espelhamento, e não valia.** São duas instâncias de
        // `AnimatedContentView`: `animatedContent` na tela inicial e `mirrorAnimated` dentro do
        // `mirrorOverlay`, e é a segunda que fica visível enquanto se espelha a tela. Só a
        // primeira recebia `denso`, então `origem_densa=true` ligava um mosaico que **nunca
        // chegava ao fio** — a corrida media o fundo liso de sempre e o ajuste dizia que não.
        // Instrumento que erra em silêncio custa mais que defeito (`docs/regras-de-frente.md`).
        binding.mirrorAnimated.denso = com.quall.android.core.Bancada.origemDensa(this)
        binding.animatedContent.visibility = View.VISIBLE
        val intent = Intent(this, ScreenCaptureService::class.java).apply {
            putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, result.resultCode)
            putExtra(ScreenCaptureService.EXTRA_RESULT_DATA, result.data)
            putExtra(ScreenCaptureService.EXTRA_MODE, modo)
            putExtra(ScreenCaptureService.EXTRA_WIDTH, size.x)
            putExtra(ScreenCaptureService.EXTRA_HEIGHT, size.y)
            putExtra(ScreenCaptureService.EXTRA_DPI, metrics.densityDpi)
        }
        ContextCompat.startForegroundService(this, intent)
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }
}
