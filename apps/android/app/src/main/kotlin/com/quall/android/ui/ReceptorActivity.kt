package com.quall.android.ui

import android.content.pm.ActivityInfo
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import com.quall.android.core.LogSeguro as Log
import android.view.SurfaceHolder
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.recyclerview.widget.LinearLayoutManager
import com.quall.android.core.Bancada
import com.quall.android.core.DeviceIdentity
import com.quall.android.core.Idioma
import com.quall.android.core.QuallBrowser
import com.quall.android.core.QuallNative
import com.quall.android.R
import com.quall.android.databinding.ActivityReceptorBinding
import com.quall.android.discovery.MulticastLockManager
import com.quall.android.receive.FraseDoAviso
import com.quall.android.receive.GravacaoRecebidaBus
import com.quall.android.receive.ReceptorBus
import com.quall.android.receive.ReceptorSessao
import kotlin.concurrent.thread
import kotlin.math.min

/**
 * A tela de quem **exibe** — o outro lado de `MirrorService`, e o que faltava para o fluxo de
 * `docs/fluxo-de-uso.md` fechar dentro do Android: **ver aparelhos, escolher, parear, exibir**.
 *
 * ## Por que uma Activity separada
 *
 * Ao contrário da tela de espera do emissor (que é overlay dentro da `MainActivity`, porque
 * compartilha estado com ela), exibir tem ciclo de vida próprio e uma exigência que a tela
 * inicial não tem: **a `Surface` precisa existir antes de a sessão subir e não pode sumir
 * enquanto ela dura**. Separar deixa isso explícito, e `configChanges` mantém a `Surface` viva
 * numa rotação em vez de matar a sessão junto.
 *
 * ## Sem foreground service, e isso é decisão, não esquecimento
 *
 * Receber não pede permissão especial nenhuma (não há `MediaProjection`, não há câmera) e só faz
 * sentido com a tela ligada e o app na frente — quem exibe está olhando. Um serviço em primeiro
 * plano acrescentaria um tipo a declarar (Android 14+ exige um) e um ciclo de vida a mais para
 * errar, sem comprar nada. O que a tela realmente precisa é não apagar: `FLAG_KEEP_SCREEN_ON`.
 */
class ReceptorActivity : AppCompatActivity() {

    companion object {
        /** Endereço pré-preenchido — usado quando se chega aqui tocando num item da lista. */
        const val EXTRA_ENDPOINT = "endpoint"

        /** O mesmo da `ReceptorSessao`: um `logcat -s QuallReceptor` pega a sessão e a tela. */
        private const val TAG = "QuallReceptor"

        /** O último endereço conectado daqui ("Usar o último", §6.6): só da tela, neste aparelho. */
        private const val PREFS_DA_TELA = "quall-telas"
        private const val CHAVE_ULTIMO_ENDERECO = "ultimo_endereco_exibir"
    }

    private lateinit var binding: ActivityReceptorBinding
    private lateinit var eu: DeviceIdentity
    private lateinit var multicastLock: MulticastLockManager
    private lateinit var deviceAdapter: DeviceListAdapter

    @Volatile private var sessao: ReceptorSessao? = null
    private var surfacePronta = false

    /** Preenchido quando o usuário toca em Conectar antes de a `Surface` existir. */
    private var conexaoPendente: Pair<String, String?>? = null

    // --- tela cheia ---------------------------------------------------------------------
    //
    // Tudo aqui só é tocado na thread principal: `desenhar` chega pelo `Handler(mainLooper)` do
    // `ReceptorBus`.

    /** Em tela cheia agora: sem barras do sistema, sem painel de números, sem botões. */
    private var telaCheia = false

    /**
     * A entrada **automática** já aconteceu nesta sessão. Sem isto, sair com o gesto de voltar
     * seria desfeito pela próxima atualização do painel — que chega a cada 500 ms.
     */
    private var telaCheiaAutomaticaFeita = false

    /** O último tamanho de vídeo que o `ReceptorBus` disse, para refazer a proporção numa rotação. */
    private var larguraDoVideo = 0
    private var alturaDoVideo = 0

    /** Só ligado em tela cheia: o gesto de voltar sai dela em vez de fechar a tela de exibir. */
    private val voltarDaTelaCheia = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = sairDaTelaCheia()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityReceptorBinding.inflate(layoutInflater)
        setContentView(binding.root)
        // O título que o TalkBack anuncia, no idioma escolhido (o do manifesto vem no do sistema no 9–12).
        setTitle(R.string.exibir_titulo)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Uma recriação (modo escuro que liga ao anoitecer, fonte, idioma — o `configChanges` não
        // cobre esses) não pode herdar a orientação travada por uma tela cheia que já não existe.
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED

        eu = DeviceIdentity.load(this)
        multicastLock = MulticastLockManager(this)
        // "Este aparelho aparece como … · núcleo vN" e a nota do PIN foram para a folha de Ajustes › Sobre
        // (`docs/telas-estudio.md` §6.6), aberta pela engrenagem daqui como pelas do Início e de Espelhar.
        folha = FolhaDeAjustes(this, eu)
        binding.buttonAjustesExibir.setOnClickListener { folha.mostrar() }

        deviceAdapter = DeviceListAdapter(pareados = { eu.idsPareados() }) { device ->
            val endpoint = device.endpoint
            if (endpoint == null) {
                Toast.makeText(this, getString(R.string.rx_sem_endereco_anunciado, device.displayName), Toast.LENGTH_LONG).show()
            } else {
                binding.editEndereco.setText(endpoint)
                mensagem("", erro = false)
                Log.i(TAG, "escolhido na lista")
            }
        }
        binding.recyclerReceptorDevices.layoutManager = LinearLayoutManager(this)
        binding.recyclerReceptorDevices.adapter = deviceAdapter

        intent?.getStringExtra(EXTRA_ENDPOINT)?.let { binding.editEndereco.setText(it) }
        desenharUltimoEndereco()
        binding.chipUsarOUltimo.setOnClickListener {
            ultimoEndereco()?.let { binding.editEndereco.setText(it); binding.editEndereco.setSelection(it.length) }
            desenharUltimoEndereco()
        }
        // O painel de números e o "Pedir IDR" na barra: com o diagnóstico ligado ou a bancada ativa (a
        // bancada lê `textReceptorStats` e calibra `buttonPedirIdr`; §11.3). No produto, fechado.
        val deBancada = EstadoDasTelas.diagnosticoLigado || Bancada.diagnosticoVisivel(this) || Bancada.ativa(this)
        painelAberto = deBancada
        binding.buttonPedirIdr.visibility = if (deBancada) View.VISIBLE else View.GONE
        binding.buttonInfoVideo.setOnClickListener {
            painelAberto = !painelAberto
            aplicarPainel()
        }
        aplicarPainel()
        arrumarOrientacao()
        // Os ajustes da câmera do outro lado (R9b): a engrenagem na barra do vídeo e o painel do R9.
        cameraRemota = CameraRemotaNaTela(this, binding.root, binding.videoContainer, binding.surfaceVideo,
            binding.buttonAjustesDaCameraRemota) { telaCheia }

        binding.surfaceVideo.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                surfacePronta = true
                conexaoPendente?.let { (endpoint, pin) ->
                    conexaoPendente = null
                    iniciar(endpoint, pin)
                }
            }

            override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) = Unit

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                // A `Surface` some quando a Activity vai para trás. Continuar decodificando para
                // uma superfície morta é gastar bateria para desenhar em lugar nenhum — e o
                // emissor fica 30 s achando que tem público (`quall.h`, o detector de queda).
                surfacePronta = false
                pararRecepcao()
            }
        })

        // Sem isto, a barra de tarefas do tablet cobre os botões e o toque nunca chega ao app —
        // medido no SM-X230, onde "Pedir IDR" simplesmente não respondia. O pé fica acima do inset + 16 dp
        // (o `paddingTop` de 16 do contêiner, §11.3).
        // Deitado, a barra de navegação fica do lado (à direita no A07) e cobria o Parar (a foto de 30/09):
        // os lados também recuam, a partir do recuo de desenho guardado uma vez (o listener roda de novo a
        // cada giro, e somar ao padding de agora acumularia).
        val esquerdaDaBarra = binding.receptorControles.paddingLeft
        val direitaDaBarra = binding.receptorControles.paddingRight
        ViewCompat.setOnApplyWindowInsetsListener(binding.receptorControles) { view, insets ->
            val barras = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(esquerdaDaBarra + barras.left, view.paddingTop, direitaDaBarra + barras.right,
                barras.bottom + view.paddingTop)
            insets
        }
        // O formulário de ponta a ponta (targetSdk 36): recua das barras do sistema e do recorte, e do
        // teclado aberto (para rolar até o Conectar); sem isto o cabeçalho ficava sob a barra de status.
        ViewCompat.setOnApplyWindowInsetsListener(binding.escolhaScroll) { v, insets ->
            val r = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val teclado = insets.getInsets(WindowInsetsCompat.Type.ime())
            v.setPadding(r.left, r.top, r.right, maxOf(r.bottom, teclado.bottom))
            (v as android.view.ViewGroup).clipToPadding = false
            insets
        }
        // O painel de números no alto do vídeo recua da barra de status e do recorte: sem isto a primeira
        // linha saía debaixo do relógio (a foto do A07 de 30/09).
        ViewCompat.setOnApplyWindowInsetsListener(binding.textReceptorStats) { v, insets ->
            val topo = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()).top
            val margens = v.layoutParams as android.view.ViewGroup.MarginLayoutParams
            if (margens.topMargin != topo + dp(12)) {
                margens.topMargin = topo + dp(12)
                v.layoutParams = margens
            }
            insets
        }

        binding.buttonProcurar.setOnClickListener { procurar() }
        binding.buttonConectar.setOnClickListener { conectarTocado() }
        binding.buttonPararRecepcao.setOnClickListener { pararTocado() }
        binding.buttonPedirIdr.setOnClickListener {
            sessao?.pedirIdrAgora()
            Toast.makeText(this, getString(R.string.rx_idr_pedido), Toast.LENGTH_SHORT).show()
        }
        val prefsGravacao = getSharedPreferences("quall-gravacao-recebida", MODE_PRIVATE)
        ultimaGravacaoMostrada = prefsGravacao.getString("uri", null)?.let(android.net.Uri::parse)
        binding.buttonUltimaGravacao.setOnClickListener {
            val uri = prefsGravacao.getString("uri", null)?.let(android.net.Uri::parse)
            if (uri != null) compartilharGravacao(uri, prefsGravacao.getString("nome", "Quall.mp4").orEmpty())
        }
        binding.buttonGravarRecepcao.setOnClickListener {
            val gravacao = GravacaoRecebidaBus.atual
            sessao?.gravarRecepcao(!gravacao.ocupada)
        }
        binding.buttonTelaCheia.setOnClickListener { entrarEmTelaCheia(automatica = false) }
        onBackPressedDispatcher.addCallback(this, voltarDaTelaCheia)
        // Como no iOS: na tela cheia, um toque em qualquer ponto sai (o voltar também).
        binding.videoContainer.setOnClickListener { if (telaCheia) sairDaTelaCheia() }
        binding.buttonVoltarDoReceptor.setOnClickListener { finish() }
        // A procura na rede começa sozinha ao abrir (§6.6), menos com a bancada ativa (§11.3): as corridas
        // de medição não podem mudar de condição com 5 s de mDNS no começo, e `bancada-prefs.sh` sempre
        // cria o arquivo. O botão redondo de atualizar procura de novo.
        if (QuallNative.carregado && !Bancada.ativa(this)) procurar()

        // Rotação, barras que somem ou voltam, tela cheia: toda mudança de tamanho do contêiner
        // refaz a proporção **na hora**. Antes disto só a próxima atualização do painel refazia,
        // e por até 500 ms a imagem ficava no tamanho da janela velha.
        binding.videoContainer.addOnLayoutChangeListener { _, esq, topo, dir, base, esqAntes, topoAntes, dirAntes, baseAntes ->
            if (dir - esq != dirAntes - esqAntes || base - topo != baseAntes - topoAntes) {
                // No próximo giro, e não dentro do passe de layout: mudar `layoutParams` aqui dentro
                // é o "requestLayout() improperly called" que o Android avisa.
                binding.videoContainer.post { ajustarProporcao(larguraDoVideo, alturaDoVideo) }
            }
        }
    }

    /** O painel da câmera do outro lado (R9b). */
    private lateinit var cameraRemota: CameraRemotaNaTela

    override fun onStart() {
        super.onStart()
        cameraRemota.comecar()
        ReceptorBus.setListener { estado -> desenhar(estado) }
        GravacaoRecebidaBus.setListener { estado -> desenharGravacao(estado) }
    }

    override fun onStop() {
        cameraRemota.parar()
        sessao?.gravarRecepcao(false)
        GravacaoRecebidaBus.setListener(null)
        ReceptorBus.setListener(null)
        super.onStop()
    }

    override fun onDestroy() {
        fechando = true
        pararRecepcao()
        multicastLock.release()
        super.onDestroy()
    }

    // --- escolher -----------------------------------------------------------------------

    private fun procurar() {
        if (!QuallNative.carregado) {
            mensagem(getString(R.string.rx_nucleo_nao_carregou, QuallNative.erroDeCarga.toString()), erro = true)
            return
        }
        multicastLock.acquire()
        // "procurando" (a bolinha violeta que pulsa) no lugar da frase de antes; o botão fica desligado
        // enquanto a procura de 5 s anda. O lock é solto no fim de cada procura, e a procura para se a
        // tela fechar no meio (`fechando`).
        binding.linhaProcurando.visibility = View.VISIBLE
        binding.buttonProcurar.isEnabled = false
        binding.buttonProcurar.alpha = 0.4f
        binding.textListaVazia.visibility = View.GONE
        thread(name = "quall-receptor-browse") {
            // Filtra o próprio aparelho: `quall_advertiser_stop` não desregistra (dívida 3), e
            // depois de espelhar uma vez este aparelho continua no ar para a própria lista. E
            // esconde quem anuncia papel: um teleprompter não é tela para exibir (`core/Papeis.kt`).
            val comLock: Boolean
            val achados = try {
                com.quall.android.core.Papeis.soDeVideo(
                    QuallBrowser.varrer(5_000) { fechando }.filter { it.deviceId != eu.deviceId }
                )
            } finally {
                comLock = multicastLock.isHeld()
                multicastLock.release()
            }
            if (fechando) return@thread
            runOnUiThread {
                deviceAdapter.submit(achados)
                binding.linhaProcurando.visibility = View.GONE
                binding.buttonProcurar.isEnabled = true
                binding.buttonProcurar.alpha = 1f
                binding.textListaVazia.text = getString(R.string.lista_vazia_nota)
                binding.textListaVazia.visibility = if (achados.isEmpty()) View.VISIBLE else View.GONE
                Log.i(TAG, "${achados.size} aparelho(s) anunciando (lock=$comLock)")
            }
        }
    }

    private fun conectarTocado() {
        val endpoint = binding.editEndereco.text.toString().trim()
        if (endpoint.isEmpty()) {
            mensagem(getString(R.string.rx_digite_o_endereco), erro = true)
            return
        }
        val pinDigitado = binding.editPin.text.toString().trim()
        val pin = when {
            pinDigitado.isNotEmpty() -> pinDigitado
            // Sem PIN digitado só faz sentido quando há pareamento salvo; caso contrário o núcleo
            // recusaria e a mensagem sairia técnica em vez de dizer o que fazer.
            eu.temParesConhecidos() -> null
            else -> {
                mensagem(getString(R.string.rx_digite_o_pin), erro = true)
                return
            }
        }

        // A entrada já foi validada; o teclado do formulário não deve cobrir o vídeo.
        getSystemService(InputMethodManager::class.java)
            ?.hideSoftInputFromWindow(binding.root.windowToken, 0)
        currentFocus?.clearFocus()
        binding.escolhaScroll.visibility = View.GONE
        binding.videoContainer.visibility = View.VISIBLE
        // "Conectando em…" na linha de estado, e não no painel de números (que só tem números, §11.3).
        linhaDeEstado(getString(R.string.rx_conectando_em, endpoint))
        binding.textParDoVideo.text = endpoint
        binding.textReceptorStats.text = ""
        binding.pontoDeAcusacao.visibility = View.GONE
        aplicarPainel()
        if (surfacePronta) {
            iniciar(endpoint, pin)
        } else {
            // A `Surface` só nasce depois de a view aparecer. Guardar o pedido é mais simples (e
            // mais honesto) que criar o decodificador sem destino e esperar dar certo.
            conexaoPendente = endpoint to pin
        }
    }

    private fun iniciar(endpoint: String, pin: String?) {
        if (sessao != null) return
        telaCheiaAutomaticaFeita = false
        // O tamanho da sessão anterior não serve para esta: um "Tela cheia" tocado antes do primeiro
        // quadro travaria a orientação do vídeo **velho** (achado da revisão de 10/09).
        larguraDoVideo = 0
        alturaDoVideo = 0
        val s = ReceptorSessao(
            eu = eu,
            endpoint = endpoint,
            pin = pin,
            surface = binding.surfaceVideo.holder.surface,
            pedirIdrNaPerda = Bancada.pedirIdrNaPerda(this),
            intervaloMinimoIdrMs = Bancada.intervaloMinimoIdrMs(this),
            pisoDoPrimeiroPedidoMs = Bancada.pisoDoPrimeiroPedidoMs(this),
            supressaoPorCausa = Bancada.supressaoPorCausa(this),
            pedirIdrNaCaixa = Bancada.pedirIdrNaCaixa(this),
            calmariaDaCaixaMs = Bancada.calmariaDaCaixaMs(this),
            solucoDoLacoMs = Bancada.solucoDoLacoMs(this),
            solucoACadaMs = Bancada.solucoACadaMs(this),
            congelarNaRuptura = Bancada.congelarNaRuptura(this),
            profundidadeDoAnel = Bancada.profundidadeDoAnel(this),
            prenderEm = Bancada.prenderEm(this),
            gravarAudioEm = Bancada.gravarAudioEm(this),
            janelaDoEnlaceMs = Bancada.janelaDoEnlaceMs(this),
            // O contêiner externo do app: `/sdcard/Android/data/com.quall.android/files`, que o
            // `adb pull` alcança sem `run-as` e sem root — inclusive num APK de release. Ver
            // `ReceptorSessao.arquivarRelato` para o que entra no arquivo, e o que nunca entra.
            relatoEm = getExternalFilesDir(null)?.absolutePath.orEmpty(),
            // Os pixels de verdade do painel: é por eles que a tela estendida do Mac escolhe o
            // formato do monitor que cria para este aparelho.
            telaDoAparelho = painelFisico(),
            contextoDeGravacao = applicationContext,
        )
        sessao = s
        thread(name = "quall-receptor") {
            try {
                s.rodar()
            } finally {
                if (sessao === s) sessao = null
            }
        }
    }

    private fun pararRecepcao() {
        sessao?.parar()
    }

    /**
     * O "Parar" da barra: para a sessão, e cancela também a conexão que ainda espera a `Surface`
     * (`conexaoPendente`) — antes, sem sessão, o toque não fazia nada (§11.3). Sem sessão, volta ao
     * formulário na hora.
     */
    private fun pararTocado() {
        if (sessao != null) {
            pararRecepcao()
            return
        }
        conexaoPendente = null
        voltarAoFormulario()
    }

    /** A parte de desenho da volta ao formulário (a do `PARADO`, sem a mensagem). */
    private fun voltarAoFormulario() {
        sairDaTelaCheia()
        binding.videoContainer.visibility = View.GONE
        binding.escolhaScroll.visibility = View.VISIBLE
        linhaDeEstado("")
    }

    // --- a apresentação ---------------------------------------------------------------------

    private lateinit var folha: FolhaDeAjustes

    /** O painel de números à mostra (o ⓘ abre e fecha; começa aberto com o diagnóstico ou a bancada). */
    private var painelAberto = false

    /** A tela está fechando: a procura na rede em curso para (ver `QuallBrowser.varrer`). */
    @Volatile
    private var fechando = false

    /** O painel de números, pelo ⓘ e pela tela cheia (que esconde tudo). */
    private fun aplicarPainel() {
        // Vazio (o "conectando"), some: uma caixa escura sem número no alto do vídeo não diz nada.
        val vis = if (painelAberto && !telaCheia && binding.textReceptorStats.text.isNotEmpty()) View.VISIBLE else View.GONE
        if (binding.textReceptorStats.visibility != vis) binding.textReceptorStats.visibility = vis
        binding.buttonInfoVideo.contentDescription =
            getString(if (painelAberto) R.string.rx_esconder_numeros else R.string.rx_mostrar_numeros)
        binding.buttonInfoVideo.imageTintList = android.content.res.ColorStateList.valueOf(
            if (painelAberto) Cores.ACENTO_CLARO else Cores.TEXTO,
        )
    }

    /**
     * A frase do serviço para a linha de estado e o formulário, montada **na hora de desenhar**, no idioma
     * da tela (`docs/traducao.md`, Android): a sessão publica o [ReceptorBus.Aviso], e [FraseDoAviso]
     * o põe em palavras. Até 02/10/2026 a sessão publicava a frase em português e esta função comparava
     * `startsWith("esperando a track")`, o que em inglês calaria sem erro.
     */
    private fun fraseDoServico(e: ReceptorBus.Estado): String = FraseDoAviso.de(Idioma.textos(this), e)

    /** A linha de estado no pé do vídeo ("Conectando em…", a frase do serviço); vazia, some. */
    private fun linhaDeEstado(texto: String) {
        if (binding.textReceptorEstado.text.toString() != texto) binding.textReceptorEstado.text = texto
        binding.textReceptorEstado.visibility = if (texto.isEmpty()) View.GONE else View.VISIBLE
    }

    /** "Usar o último · {endereço}": o último endereço conectado daqui, guardado neste aparelho. */
    private fun ultimoEndereco(): String? =
        getSharedPreferences(PREFS_DA_TELA, MODE_PRIVATE).getString(CHAVE_ULTIMO_ENDERECO, null)?.takeIf { it.isNotBlank() }

    private fun guardarUltimoEndereco(endpoint: String) {
        getSharedPreferences(PREFS_DA_TELA, MODE_PRIVATE).edit().putString(CHAVE_ULTIMO_ENDERECO, endpoint).apply()
        desenharUltimoEndereco()
    }

    private fun desenharUltimoEndereco() {
        val ultimo = ultimoEndereco()
        val mostrar = ultimo != null && ultimo != binding.editEndereco.text.toString().trim()
        binding.chipUsarOUltimo.visibility = if (mostrar) View.VISIBLE else View.GONE
        if (mostrar) binding.chipUsarOUltimo.text = getString(R.string.rx_usar_o_ultimo, ultimo)
    }

    /**
     * A paisagem em duas colunas (§11.1): o endereço à esquerda, o PIN e o Conectar à direita. O título e
     * a explicação saem da paisagem (o cabeçalho já diz "Exibir"), e a lista fica com uma linha e meia:
     * a altura de um celular deitado não comporta o resto. **Só na tela baixa** ([telaBaixa], 30/09): o
     * tablet deitado fica numa coluna centrada, inteira, como em pé.
     */
    private fun arrumarOrientacao() {
        val paisagem = telaBaixa()
        val v = if (paisagem) View.GONE else View.VISIBLE
        binding.textTituloExibir.visibility = v
        binding.textSubtituloExibir.visibility = v
        binding.caixaDaLista.layoutParams = binding.caixaDaLista.layoutParams.apply {
            height = dp(if (paisagem) 80 else 144)
        }
        binding.colunasDoExibir.requestLayout()
    }

    override fun onConfigurationChanged(novaConfiguracao: android.content.res.Configuration) {
        super.onConfigurationChanged(novaConfiguracao)
        arrumarOrientacao()
        cameraRemota.arrumar()
    }

    // --- desenhar -----------------------------------------------------------------------

    private var ultimaGravacaoMostrada: android.net.Uri? = null
    private var ultimoErroGravacao: GravacaoRecebidaBus.Estado? = null

    private fun compartilharGravacao(uri: android.net.Uri, nome: String) {
        val enviar = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
            type = "video/mp4"; putExtra(android.content.Intent.EXTRA_STREAM, uri)
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = android.content.ClipData.newRawUri(nome, uri)
        }
        runCatching { startActivity(android.content.Intent.createChooser(enviar, getString(R.string.rx_gravacao_compartilhar))) }
            .onFailure { Toast.makeText(this, getString(R.string.rx_gravacao_falhou), Toast.LENGTH_LONG).show() }
    }

    private fun desenharGravacao(e: GravacaoRecebidaBus.Estado) {
        binding.buttonUltimaGravacao.visibility = if (getSharedPreferences("quall-gravacao-recebida", MODE_PRIVATE).contains("uri")) View.VISIBLE else View.GONE
        val pode = ReceptorBus.atual.fase == ReceptorBus.Fase.EXIBINDO && ReceptorBus.atual.largura > 0
        binding.buttonGravarRecepcao.isEnabled = (pode || e.ocupada) && e.fase != GravacaoRecebidaBus.Fase.SALVANDO
        val parando = e.ocupada
        binding.buttonGravarRecepcao.text = if (parando) "■" else "●"
        binding.buttonGravarRecepcao.contentDescription = getString(if (parando) R.string.rx_parar_gravacao else R.string.rx_gravar)
        val texto = when (e.fase) {
            GravacaoRecebidaBus.Fase.ESPERANDO_IDR -> getString(R.string.rx_gravacao_idr)
            GravacaoRecebidaBus.Fase.GRAVANDO -> getString(R.string.rx_gravacao_tempo, e.segundos / 60, e.segundos % 60, e.parte)
            GravacaoRecebidaBus.Fase.SALVANDO -> getString(R.string.rx_gravacao_salvando)
            else -> ""
        }
        binding.textGravacaoRecebida.text = texto
        binding.textGravacaoRecebida.visibility = if (texto.isBlank()) View.GONE else View.VISIBLE
        if (!e.ocupada && (e.uri != null || e.fase == GravacaoRecebidaBus.Fase.ERRO) && !isFinishing) {
            if (e.uri != null && e.uri != ultimaGravacaoMostrada) {
                ultimaGravacaoMostrada = e.uri
                androidx.appcompat.app.AlertDialog.Builder(this)
                    .setMessage(getString(R.string.rx_gravacao_salva, e.nome) +
                        (if (Build.VERSION.SDK_INT < 29) "\n" + getString(R.string.rx_gravacao_guardar_copia) else "") +
                        if (e.fase == GravacaoRecebidaBus.Fase.ERRO) "\n" + getString(R.string.rx_gravacao_falhou) else "")
                    .setPositiveButton(R.string.rx_gravacao_compartilhar) { _, _ ->
                        compartilharGravacao(e.uri, e.nome)
                    }.setNegativeButton(android.R.string.ok, null).show()
            } else if (e.fase == GravacaoRecebidaBus.Fase.ERRO && e.uri == null && ultimoErroGravacao !== e) {
                ultimoErroGravacao = e
                val mensagem = when (e.detalhe) {
                    "espaco" -> R.string.rx_gravacao_espaco
                    "tamanho" -> R.string.rx_gravacao_limite
                    else -> R.string.rx_gravacao_falhou
                }
                Toast.makeText(this, getString(mensagem), Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun desenhar(e: ReceptorBus.Estado) {
        desenharGravacao(GravacaoRecebidaBus.atual)
        when (e.fase) {
            ReceptorBus.Fase.PARADO, ReceptorBus.Fase.ERRO -> {
                sairDaTelaCheia()
                binding.videoContainer.visibility = View.GONE
                binding.escolhaScroll.visibility = View.VISIBLE
                // **O campo do PIN é limpo ao voltar para a escolha, e isso devolve a retomada
                // silenciosa que o núcleo já implementa.**
                //
                // `conectarTocado` dá precedência ao que está digitado
                // (`pinDigitado.isNotEmpty() -> pinDigitado`), e até 09/09/2026 o campo só era
                // limpo no ramo PRECISA_DE_PIN — nunca depois de parear com sucesso nem quando a
                // sessão caía. Um PIN velho parado ali transforma uma reconexão em **pareamento
                // novo**: `pairing.rs` manda Hello quando há PIN, o emissor sorteia outro a cada
                // consentimento, os dois não conferem, e os dois aparelhos acusam problema de
                // pareamento com o pareamento salvo intacto — que funcionaria em silêncio se o
                // campo estivesse vazio.
                binding.editPin.setText("")
                linhaDeEstado("")
                desenharUltimoEndereco()
                // A mensagem fica no formulário (o Aviso vermelho no erro), como no iOS: sem `Toast`.
                val frase = fraseDoServico(e)
                if (frase.isNotBlank()) mensagem(frase, erro = e.fase == ReceptorBus.Fase.ERRO)
            }

            ReceptorBus.Fase.CONECTANDO, ReceptorBus.Fase.PROCURANDO -> {
                // "Conectando em…" e a frase do serviço na linha de estado, sempre à mostra (§11.3).
                val frase = fraseDoServico(e)
                linhaDeEstado(getString(R.string.rx_conectando_em, e.endpoint) +
                    if (frase.isNotBlank()) "\n" + frase else "")
                binding.textParDoVideo.text = e.endpoint
            }

            // Não é falha, é convite a recomeçar (dívida 22): o par esqueceu este aparelho. Volta
            // para a tela de escolha com o endereço preservado e o PIN vazio e em foco — o
            // usuário só precisa ler seis dígitos da tela do outro aparelho e digitar.
            ReceptorBus.Fase.PRECISA_DE_PIN -> {
                sairDaTelaCheia()
                binding.videoContainer.visibility = View.GONE
                binding.escolhaScroll.visibility = View.VISIBLE
                if (e.endpoint.isNotBlank()) binding.editEndereco.setText(e.endpoint)
                binding.editPin.setText("")
                binding.editPin.requestFocus()
                linhaDeEstado("")
                mensagem(fraseDoServico(e), erro = true)
            }

            ReceptorBus.Fase.EXIBINDO -> {
                binding.escolhaScroll.visibility = View.GONE
                binding.videoContainer.visibility = View.VISIBLE
                // Sem nome do par, "emissor" no idioma da tela (a sessão publica vazio).
                val par = e.par.ifBlank { getString(R.string.rx_par_sem_nome) }
                binding.textParDoVideo.text = par
                linhaDeEstado(fraseDoServico(e))
                // "Usar o último": só o endereço que chegou à imagem (e não o de uma tentativa que falhou).
                if (e.endpoint.isNotBlank() && e.endpoint != ultimoEndereco()) guardarUltimoEndereco(e.endpoint)
                // Uma acusação da linha da imagem põe o ponto âmbar no ⓘ (§6.6).
                binding.pontoDeAcusacao.visibility = if (e.suspeitos > 0) View.VISIBLE else View.GONE
                val mudouDeTamanho = e.largura != larguraDoVideo || e.altura != alturaDoVideo
                larguraDoVideo = e.largura
                alturaDoVideo = e.altura
                ajustarProporcao(e.largura, e.altura)
                if (telaCheia && mudouDeTamanho) travarNaOrientacaoDoVideo()
                // Tentada a cada atualização até valer, e não uma vez só: com o tablet em pé ela espera,
                // e entra sozinha quando a pessoa deita o tablet.
                if (!telaCheiaAutomaticaFeita && podeEntrarSozinha(e.largura, e.altura)) {
                    telaCheiaAutomaticaFeita = true
                    entrarEmTelaCheia(automatica = true)
                }
                // Onde começa e acaba a linha da imagem, para pintá-la de laranja quando ela
                // acusa. Um `TextView` só, e um trecho colorido: a acusação tem de saltar sem
                // tingir o resto do painel.
                var inicioDaImagem = 0
                var fimDaImagem = 0
                val texto = buildString {
                    // **O painel de números fica em português, de propósito** (`docs/traducao.md`, Android): é
                    // diagnóstico de bancada (só com o diagnóstico ligado ou a bancada ativa, §11.3), e
                    // `tools/laco-de-audio.py` e `apps/android/tools/laco-no-aparelho.py` leem `textReceptorStats`
                    // procurando "perda exata". As linhas com acento levam `i18n-fora`.
                    append("$par · ${e.rotuloDaTrack}")
                    append(if (e.pareamentoNovo) " · pareado agora por PIN\n" else " · pareamento retomado\n")
                    if (e.largura > 0) {
                        append("${e.largura}×${e.altura} · ${e.perfil} · faixa ${e.faixaDeCor}\n")
                    }
                    if (e.decodificador.isNotBlank()) {
                        append("decodificador: ${e.decodificador} (hw=${e.decodificadorEhHardware})\n")
                    }
                    append("1º IDR: ${"%.1f".format(e.primeiroIdrMs)} ms · ")
                    append(
                        if (e.primeiraImagemMs > 0) {
                            "1ª imagem: ${"%.1f".format(e.primeiraImagemMs)} ms\n"
                        } else {
                            "1ª imagem: ainda não\n" // i18n-fora: painel de números de bancada
                        }
                    )
                    append("fps: ${"%.1f".format(e.fpsObtido)} · ")
                    append("decode p50=${"%.1f".format(e.decodeP50Ms)} ms p95=${"%.1f".format(e.decodeP95Ms)} ms\n")
                    append("recebidos: ${e.quadrosRecebidos}  enfileirados: ${e.quadrosEnfileirados}  ")
                    append("descartados: ${e.quadrosDescartadosNaCaixa}\n")
                    // **A linha da imagem, e ela é SEMPRE escrita.**
                    //
                    // A queixa que originou esta medida foi sobre a **tela**: "em nenhuma tela
                    // aparece nos contadores falhas, sempre é 0 e em todas estão falhando". Em
                    // 31/08 os cinco já mediam certo no `logcat` do receptor iOS e o usuário,
                    // olhando para o iPad no meio de uma corrida com 124 quadros suspeitos,
                    // disse "continua falhando e 0 falhas" — e continuava certo, porque nada
                    // disto chegava aqui. Uma casca que publica os contadores só onde uma
                    // ferramenta os lê não cumpre `docs/contrato-track.md`.
                    //
                    // Escrita mesmo valendo zero, de propósito: um campo que só aparece quando
                    // acusa não deixa a pessoa aprender que ele existe, e some justamente na
                    // corrida limpa que serviria de referência.
                    inicioDaImagem = length
                    append("imagem: rupturas ${e.rupturas} · suspeitos ${e.suspeitos} · ")
                    append("pior rajada ${e.piorRajada} · retidos ${e.retidos} · ")
                    append("sem_referencia_ms ${e.semReferenciaMs}")
                    append(if (e.congelando) " · porta LIGADA\n" else "\n")
                    if (e.suspeitos > 0) {
                        append("*** ${e.suspeitos} quadro(s) exibidos com a referência quebrada") // i18n-fora: painel de números de bancada
                        append(" — pior rajada ${e.piorRajada} seguidos ***\n")
                    }
                    fimDaImagem = length
                    append("antes do 1º IDR: ${e.quadrosAntesDoPrimeiroIdr}  ")
                    append("IDR pedidos: ${e.pedidosDeIdrEnviados}\n")
                    val s = sessao
                    val r = s?.recuperacaoMs ?: 0.0
                    if (r > 0) append("recuperação do último pedido: ${"%.1f".format(r)} ms\n") // i18n-fora: painel de números de bancada
                    if (s != null) {
                        append("perda no meio: ${s.eventosDePerda} evento(s) · ")
                        append("${s.quadrosPerdidosVistos} quadro(s)\n")
                        append("IDR por perda: ${s.pedidosPorPerda} · suprimidos: ${s.perdasSuprimidas} · ")
                        append("resolvidas sem pedir: ${s.perdasResolvidasSemPedido}\n")
                    }
                    // **Acima do JSON cru, e de propósito.** Esta é a tela que a bancada
                    // fotografa; o número que ela lia aqui era `packets_missing`, que nunca foi
                    // perda. A linha mastigada põe a perda exata, o teto e o "tarde demais" lado
                    // a lado, para que nenhum dos três possa ser lido sozinho.
                    if (e.resumoDePerda.isNotBlank()) append("${e.resumoDePerda}\n")
                    // O som, ao lado da imagem. Sem esta linha, "o Android toca?" só se responde
                    // com o ouvido, e ouvido não entra em relatório de bancada.
                    if (e.rotuloDoAudio.isNotBlank()) {
                        append("áudio: ${e.rotuloDoAudio} · ") // i18n-fora: painel de números de bancada
                        append(if (e.audioTocando) "tocando\n" else "parado\n")
                    }
                    if (e.resumoDeAudio.isNotBlank()) append("${e.resumoDeAudio}\n")
                    if (e.estatisticasDoNucleo.isNotBlank()) append("núcleo: ${e.estatisticasDoNucleo}") // i18n-fora: painel de números de bancada
                }
                binding.textReceptorStats.text =
                    if (e.suspeitos > 0 && fimDaImagem > inicioDaImagem) {
                        SpannableString(texto).apply {
                            setSpan(ForegroundColorSpan(Color.parseColor("#FF8C00")),
                                    inicioDaImagem, fimDaImagem,
                                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                        }
                    } else {
                        texto
                    }
                aplicarPainel()
            }
        }
    }

    // --- tela cheia ---------------------------------------------------------------------

    /**
     * O vídeo foi feito **para este painel**: tem exatamente os pixels da tela, deitado ou em pé.
     *
     * É o caso da tela estendida — o Mac cria o monitor com os pixels do tablet
     * (`docs/tela-estendida.md`) — e o de espelhar um monitor do mesmo tamanho. Aí a tela cheia é o
     * que se quer, e **1:1 é a única escala que não borra letra**: com as barras do sistema, o
     * painel de números e os botões ocupando a janela, um vídeo de 1920 × 1200 saía reduzido.
     *
     * **O painel físico, e só ele.** Medido em 10/09 no `SM-X230`, que estava com tamanho de tela
     * forçado (`wm size` → `Override size: 1080x1920` sobre um painel de 1200x1920): a janela
     * reportava 1920 × 1080. Comparar com a janela tinha dois defeitos — a tela estendida de
     * 1920 × 1200 nunca batia, e o Dell a 1920 × 1080 **passaria** a bater, levando a corrida
     * `tools/dell-para-android.py` para tela cheia sem ninguém pedir. Celulares espelhados
     * (720 × 1520, 1080 × 2340) e o Dell não batem com o painel do tablet.
     */
    private fun feitoParaEstePainel(largura: Int, altura: Int): Boolean {
        if (largura <= 0 || altura <= 0) return false
        val (fisW, fisH) = painelFisico()
        return (largura == fisW && altura == fisH) || (largura == fisH && altura == fisW)
    }

    /**
     * A entrada **automática** vale só quando dá certo sem a ajuda de ninguém:
     *
     * - o vídeo foi feito para este painel;
     * - **a janela já está na orientação do vídeo.** No Android 16, com `targetSdk` 36, pedir
     *   orientação é ignorado em tela com largura mínima ≥ 600 dp — é o tablet (revisão de 10/09).
     *   Entrar em tela cheia com o tablet em pé e o monitor deitado daria uma faixa no meio da tela,
     *   sem botão nenhum. Ela espera, e entra quando a pessoa gira o tablet;
     * - **fora de tela dividida e de janela livre**: ali o painel físico não é a janela, e esconder o
     *   painel de números numa meia tela com escala 0,5 é pior que não entrar.
     *
     * O botão "Tela cheia" continua valendo em qualquer caso — aí é escolha da pessoa.
     */
    private fun podeEntrarSozinha(largura: Int, altura: Int): Boolean {
        if (!feitoParaEstePainel(largura, altura) || isInMultiWindowMode) return false
        val janela = limitesDaJanela()
        val videoDeitado = largura >= altura
        val janelaDeitada = janela.width() >= janela.height()
        return videoDeitado == janelaDeitada
    }

    /** Os pixels de verdade do painel, que o tamanho forçado (`wm size`) não muda. */
    private fun painelFisico(): Pair<Int, Int> {
        val modo = telaDaAtividade?.mode ?: return 0 to 0
        return modo.physicalWidth to modo.physicalHeight
    }

    /**
     * Esconde as barras do sistema, o painel de números e os botões, e trava a orientação na do
     * vídeo. As barras voltam por um instante com o gesto da borda (`BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`),
     * e o gesto de voltar sai da tela cheia.
     *
     * **Tela limpa**, por decisão do usuário: nada por cima do monitor. A linha da imagem só aparece,
     * laranja, quando `suspeitos > 0` — exceção registrada em `docs/contrato-track.md`. O painel
     * inteiro volta com Voltar.
     */
    private fun entrarEmTelaCheia(automatica: Boolean) {
        if (telaCheia || binding.videoContainer.visibility != View.VISIBLE) return
        telaCheia = true
        // A tela cheia é a imagem limpa: o painel da câmera do outro lado fecha.
        cameraRemota.abrir(false)
        voltarDaTelaCheia.isEnabled = true

        // Do 35 em diante a janela já é de ponta a ponta, obrigatoriamente — mexer aqui e "restaurar"
        // na saída a deixaria diferente do que era antes da tela cheia (revisão de 10/09).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            WindowCompat.setDecorFitsSystemWindows(window, false)
        }
        WindowInsetsControllerCompat(window, binding.root).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        binding.receptorControles.visibility = View.GONE
        aplicarPainel()
        travarNaOrientacaoDoVideo()

        val tela = limitesMaximosDaJanela()
        val (fisW, fisH) = painelFisico()
        Log.i(TAG, "tela cheia: entrou (${if (automatica) "automática — vídeo feito para este painel" else "pedida"}) " +
            "vídeo ${larguraDoVideo}x$alturaDoVideo, janela ${tela.width()}x${tela.height()}, painel físico ${fisW}x$fisH")
        // Com tamanho forçado, a janela tem menos pixels que o painel e **nenhuma** escala sai 1:1:
        // o sistema desenha na resolução forçada e estica para o painel. Não é defeito do Quall, e
        // tem de estar no registro com a causa, senão vira "a letra ficou borrada" sem culpado.
        val janelaMaior = maxOf(tela.width(), tela.height())
        val janelaMenor = minOf(tela.width(), tela.height())
        if (fisW > 0 && (janelaMaior != maxOf(fisW, fisH) || janelaMenor != minOf(fisW, fisH))) {
            Log.w(TAG, "!! tamanho de tela forçado: janela ${janelaMaior}x$janelaMenor sobre painel " +
                "${maxOf(fisW, fisH)}x${minOf(fisW, fisH)} — a imagem não sai 1:1 (desfazer com `adb shell wm size reset`)")
        }
        // A dica do iOS por 2,5 s, sobre o vídeo; e um toque em qualquer ponto sai.
        binding.textDicaTelaCheia.visibility = View.VISIBLE
        binding.textDicaTelaCheia.removeCallbacks(apagarDica)
        binding.textDicaTelaCheia.postDelayed(apagarDica, 2_500)
    }

    private val apagarDica = Runnable { binding.textDicaTelaCheia.visibility = View.GONE }

    /**
     * A mensagem do formulário, como Aviso (§6.6): de informação no estado, vermelho no erro (o PIN
     * errado, a recusa, a queda; §11.1). Vazia, some.
     */
    private fun mensagem(texto: String, erro: Boolean) {
        binding.textReceptorStatus.text = texto
        binding.textReceptorStatus.tipo = if (erro) AvisoDaTela.Tipo.VERMELHO else AvisoDaTela.Tipo.INFO
        binding.textReceptorStatus.visibility = if (texto.isEmpty()) View.GONE else View.VISIBLE
    }

    /**
     * Pede a orientação do vídeo. **É pedido, não garantia**: no celular vale; no tablet com Android 16
     * o sistema ignora (`podeEntrarSozinha` explica). `SENSOR_*` deixa virar de ponta-cabeça.
     */
    private fun travarNaOrientacaoDoVideo() {
        if (larguraDoVideo <= 0 || alturaDoVideo <= 0) return
        requestedOrientation = if (larguraDoVideo >= alturaDoVideo) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        }
    }

    private fun sairDaTelaCheia() {
        if (!telaCheia) return
        telaCheia = false
        voltarDaTelaCheia.isEnabled = false

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            WindowCompat.setDecorFitsSystemWindows(window, true)
        }
        WindowInsetsControllerCompat(window, binding.root).show(WindowInsetsCompat.Type.systemBars())
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT
        }
        binding.receptorControles.visibility = View.VISIBLE
        aplicarPainel()
        binding.textDicaTelaCheia.visibility = View.GONE
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        Log.i(TAG, "tela cheia: saiu")
    }

    /**
     * Redimensiona a `SurfaceView` para caber no contêiner **preservando a proporção do vídeo**.
     *
     * Sem isto, `match_parent` estica a imagem do celular (retrato) para a tela do tablet
     * (paisagem) e o que aparece é uma prova falsa: parece funcionar, e está deformado.
     */
    private fun ajustarProporcao(largura: Int, altura: Int) {
        if (largura <= 0 || altura <= 0) return
        val pai = binding.videoContainer
        val dispW = pai.width
        val dispH = pai.height
        if (dispW <= 0 || dispH <= 0) return
        val escala = min(dispW.toDouble() / largura, dispH.toDouble() / altura)
        val alvoW = (largura * escala).toInt()
        val alvoH = (altura * escala).toInt()
        val lp = binding.surfaceVideo.layoutParams as FrameLayout.LayoutParams
        if (lp.width == alvoW && lp.height == alvoH) return
        lp.width = alvoW
        lp.height = alvoH
        lp.gravity = android.view.Gravity.CENTER
        binding.surfaceVideo.layoutParams = lp
        // A testemunha do 1:1, sem olhar pixel nenhum: a conta que decide o tamanho da superfície.
        // Com a tela estendida num tablet do mesmo tamanho, `escala` tem de sair 1.000.
        Log.i(TAG, "superfície: ${alvoW}x$alvoH para vídeo ${largura}x$altura no contêiner ${dispW}x$dispH " +
            "(escala ${"%.3f".format(escala)}, tela cheia=$telaCheia)")
    }
}
