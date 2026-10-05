package com.quall.android.ui

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.recyclerview.widget.LinearLayoutManager
import com.quall.android.R
import com.quall.android.core.Bancada
import com.quall.android.core.DeviceIdentity
import com.quall.android.core.Idioma
import com.quall.android.core.Papeis
import com.quall.android.core.QuallBrowser
import com.quall.android.core.QuallNative
import com.quall.android.core.QuallNative.MudouNoTeleprompter
import com.quall.android.databinding.ActivityControleBinding
import com.quall.android.discovery.MulticastLockManager
import com.quall.android.teleprompter.Ajustes
import com.quall.android.teleprompter.Avisos
import com.quall.android.teleprompter.EnderecoDoTeleprompter
import com.quall.android.teleprompter.EstadoDoTeleprompter
import com.quall.android.teleprompter.ReplicaDoTeleprompter
import com.quall.android.teleprompter.Replicas
import com.quall.android.teleprompter.Resumo
import com.quall.android.teleprompter.SegurarParaRolar
import com.quall.android.teleprompter.SessaoDoControle
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * **O controle remoto do teleprompter**: acha o prompter (mDNS, chave `pa`, ou IP digitado),
 * conecta como `"controle_remoto"` e comanda — tocar e pausar, velocidade, voltar ao começo,
 * pular, espelho, fonte, margem, linha de leitura, e o roteiro (`docs/contrato-teleprompter.md`).
 *
 * Toda edição daqui vai para a réplica, que manda na hora ao prompter (da thread da tela —
 * `quall_teleprompter_set_*` não bloqueia) e confirma em uma ida e volta; acima de 1,5 s sem
 * confirmação a tela avisa que o comando não chegou (§3). A posição é o **relato** do prompter: a
 * barra de progresso só a mostra; arrastar e soltar pede um salto.
 *
 * Quando a sessão cai, [SessaoDoControle] tenta de novo a cada ~1 s, sem PIN, e o aviso laranja
 * fica até ela voltar. O prompter, do outro lado, continua como estava (a regra do usuário).
 *
 * O modo "Segurar para rolar" (§12.5) é uma camada por cima do painel, com os toques dela
 * ([ModoSegurar]); daqui ela recebe o painel aparecendo e sumindo, cada desenho, e o segundo plano.
 *
 * A **pergunta do texto** (§11.7): a trava ligada na réplica do controle ao abrir, a caixa por cima
 * de tudo ([TelaDaPergunta]) e os "Roteiros guardados" ([TelaDosRoteiros]); o salvo é gravado depois
 * da escolha e a cada cópia nova.
 */
class ControleActivity : AppCompatActivity() {

    companion object {
        /** Bancada: `ip:porta` do prompter — conecta sozinho ao abrir. */
        const val EXTRA_ENDERECO = "endereco"

        /** Bancada: o PIN do prompter. Sem ele, só entra um par já conhecido. */
        const val EXTRA_PIN = "pin"

        /** Bancada: nome de um arquivo em `getExternalFilesDir(null)` com um roteiro a mandar. */
        const val EXTRA_ROTEIRO = "roteiro"

        /** Bancada: liga ou desliga o modo "Segurar para rolar" (como o botão do painel e o "Sair"). */
        const val EXTRA_SEGURAR_PARA_ROLAR = "segurar_para_rolar"

        /**
         * Bancada, com a tela de pé (`onNewIntent`): `cima`, `baixo`, `cabecalho`, `inverter`,
         * `soltar`, `fora` ou `cancelar` no dedo [EXTRA_DEDO] — pelo mesmo caminho do toque
         * (`ModoSegurar.bancada`).
         */
        const val EXTRA_SEGURAR = "segurar"
        const val EXTRA_DEDO = "dedo"

        /**
         * Bancada: a resposta da pergunta do texto (`prompter`, `meu` ou `nenhuma`), dada pelo mesmo
         * botão da caixa quando ela abrir. Com [EXTRA_ROTEIRO] e sem esta, `meu`: a bancada que dá o
         * roteiro ao controle antes de conectar não pode ficar parada esperando um dedo (§11.7).
         */
        const val EXTRA_ESCOLHA = "escolha"

        private const val TAG = "QuallTeleprompter"
        private const val TIQUE_MS = 250L
    }

    private lateinit var b: ActivityControleBinding
    private lateinit var eu: DeviceIdentity
    private lateinit var multicastLock: MulticastLockManager
    private lateinit var lista: DeviceListAdapter
    private lateinit var editor: EditorDeTexto
    private var replica: ReplicaDoTeleprompter? = null
    private var modo: ModoSegurar? = null
    private var pergunta: TelaDaPergunta? = null
    private var roteiros: TelaDosRoteiros? = null
    private var sessao: SessaoDoControle? = null
    private var threadDaSessao: Thread? = null
    private val principal = Handler(Looper.getMainLooper())

    /** As frases dos módulos puros (avisos, sessão), no idioma desta tela (`docs/traducao.md`, Android). */
    private val t by lazy { Idioma.textos(this) }

    private var fase: SessaoDoControle.Fase? = null
    private var estado: EstadoDoTeleprompter? = null
    private var sessaoSubiuEm = 0L
    private var arrastandoProgresso = false
    private var desenhandoEspelho = false
    private var avisoMostrado = ""

    /** O que o botão "Rolar"/"Parar" mostra agora: o que a pessoa aperta é o contrário disto. */
    private var rolandoNoRotulo = false
    private var teto = 131_072L

    /** "Conectar" tocado enquanto a sessão anterior ainda encerra: sai quando ela terminar. */
    private var conectarAoTerminar = false

    private val bitsPendentes = AtomicInteger(0)
    private val aplicarBits = Runnable { aplicarMudancas(bitsPendentes.getAndSet(0)) }

    private val tique = object : Runnable {
        override fun run() {
            if (b.painelControle.visibility == View.VISIBLE) desenhar()
            principal.postDelayed(this, TIQUE_MS)
        }
    }

    private val ouvinte = object : SessaoDoControle.Ouvinte {
        override fun fase(f: SessaoDoControle.Fase) {
            principal.post { aplicarFase(f) }
        }

        override fun mudou(bits: Int) {
            if (bitsPendentes.getAndUpdate { it or bits } == 0) principal.post(aplicarBits)
        }
    }

    private val voltar = object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() {
            when {
                editor.aberto -> editor.voltar()
                roteiros?.aberta == true -> roteiros?.fechar()
                // A caixa da pergunta cobre tudo, também o "Sair" do modo segurar: o voltar é a saída
                // dela — desconecta, e a pergunta volta na próxima conexão (§11.2).
                pergunta?.visivel == true -> desconectar()
                // No "Segurar para rolar", o voltar (um gesto de borda de raspão) não derruba nada.
                modo?.visivel == true -> modo?.avisarSaida()
                b.painelControle.visibility == View.VISIBLE || b.conectandoControle.visibility == View.VISIBLE -> desconectar()
                else -> finish()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // O título que o TalkBack anuncia: no idioma escolhido (o do manifesto sai no do sistema).
        setTitle(R.string.tp_controle_titulo)
        b = ActivityControleBinding.inflate(layoutInflater)
        setContentView(b.root)
        // Um controle remoto que apaga no meio da leitura obriga a destravar o telefone para
        // pausar. Vale enquanto esta janela está na frente.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        eu = DeviceIdentity.load(this)
        multicastLock = MulticastLockManager(this)

        // O nome deste aparelho e o núcleo estão na folha de Ajustes › Sobre (a engrenagem do Início); a
        // nota do PIN virou "Deixe vazio se os dois já parearam." ao lado do rótulo (§6.7).
        arrumarOrientacao()

        lista = DeviceListAdapter(pareados = { eu.idsPareados() }, icone = R.drawable.ic_q_texto) { d ->
            val endpoint = d.endpoint
            if (endpoint == null) {
                Toast.makeText(this, getString(R.string.tp_sem_endereco, d.displayName), Toast.LENGTH_LONG).show()
            } else {
                b.editEnderecoPrompter.setText(endpoint)
                erro("")
                Log.i(TAG, "controle: escolhido na lista")
            }
        }
        b.recyclerPrompters.layoutManager = LinearLayoutManager(this)
        b.recyclerPrompters.adapter = lista

        val r = if (QuallNative.carregado) Replicas.obter(this, eu.deviceId, QuallNative.PAPEL_CONTROLE_REMOTO) else null
        if (r == null) {
            val motivo = if (!QuallNative.carregado) getString(R.string.tp_nucleo_nao_carregou, QuallNative.erroDeCarga.orEmpty())
            else getString(R.string.tp_replica_falhou, QuallNative.lastError())
            erro(motivo)
            b.buttonVoltarDoControle.setOnClickListener { finish() }
            b.buttonConectarControle.isEnabled = false
            b.buttonProcurarPrompters.isEnabled = false
            return
        }
        replica = r
        // A pergunta do texto (§11.10): a trava na réplica do CONTROLE, com a tela da pergunta de pé.
        // O salvo é um só com o do prompter (§11.2); a réplica do prompter nunca a liga.
        Log.i(TAG, "controle: pergunta do texto ligada (${QuallNative.Status.nome(r.ligarPerguntaDoTexto())})")
        teto = QuallNative.teleprompterMaxTextBytes()
        editor = EditorDeTexto(
            b.editorControle, this, teto,
            confirmar = { t ->
                r.definirTexto(t).also {
                    desenhar()
                    // Salva já: um `force-stop` antes do `onStop` perdia o roteiro do salvo (13/09).
                    if (it == QuallNative.Status.OK) salvarJa(r, "o roteiro confirmado")
                }
            },
            aoFechar = { },
        )
        onBackPressedDispatcher.addCallback(this, voltar)
        ViewCompat.setOnApplyWindowInsetsListener(b.editorControle.root) { v, insets ->
            val barras = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            v.setPadding(barras.left + 32, barras.top + 32, barras.right + 32, barras.bottom + 32)
            insets
        }
        ViewCompat.setOnApplyWindowInsetsListener(b.root) { v, insets ->
            val barras = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            b.escolhaControle.setPadding(barras.left, barras.top, barras.right, barras.bottom)
            b.painelControle.setPadding(barras.left, barras.top, barras.right, barras.bottom)
            b.conectandoControle.setPadding(barras.left, barras.top, barras.right, barras.bottom)
            val folga = (12 * resources.displayMetrics.density).toInt()
            b.modoSegurar.root.setPadding(barras.left + folga, barras.top + folga, barras.right + folga, barras.bottom + folga)
            b.roteirosGuardados.root.setPadding(barras.left + folga, barras.top + folga, barras.right + folga, barras.bottom + folga)
            b.perguntaDoTexto.root.setPadding(barras.left, barras.top, barras.right, barras.bottom)
            insets
        }

        modo = ModoSegurar(this, b.modoSegurar, r, b.painelControle)
        // §11.5: o salvo gravado logo depois de a escolha dar OK (e a cada `_TEXT_COPY`, em `aplicarMudancas`).
        pergunta = TelaDaPergunta(b.perguntaDoTexto, b.textConferindo, r) { st, manterOMeu ->
            if (st == QuallNative.Status.OK) {
                salvarJa(r, "a escolha da pergunta")
                // "Usar o do prompter" troca o texto daqui sem `_TEXT` (a adoção é local): o editor
                // aberto recebe o novo como qualquer texto que chega, e o rascunho não o apaga calado.
                if (!manterOMeu && editor.aberto) r.texto()?.let { editor.chegou(it) }
            }
            desenhar()
        }
        roteiros = TelaDosRoteiros(this, b.roteirosGuardados, r) { salvarJa(r, "os roteiros guardados") }
        when (val escolha = intent?.getStringExtra(EXTRA_ESCOLHA)) {
            null -> if (intent?.hasExtra(EXTRA_ROTEIRO) == true) pergunta?.escolherPelaBancada("meu")
            else -> pergunta?.escolherPelaBancada(escolha)
        }
        if (intent?.hasExtra(EXTRA_SEGURAR_PARA_ROLAR) == true) {
            modo?.ligar(intent.getBooleanExtra(EXTRA_SEGURAR_PARA_ROLAR, false), "bancada")
        }
        ligarBotoes(r)

        intent?.getStringExtra(EXTRA_ROTEIRO)?.let { carregarRoteiroDaBancada(r, it) }
        val enderecoDaBancada = intent?.getStringExtra(EXTRA_ENDERECO)
        intent?.getStringExtra(EXTRA_PIN)?.let { b.editPinPrompter.setText(it) }
        if (!enderecoDaBancada.isNullOrBlank()) {
            b.editEnderecoPrompter.setText(enderecoDaBancada)
            conectarTocado()
        } else if (!Bancada.ativa(this)) {
            // A procura na rede começa sozinha ao abrir (§6.7), menos com a bancada ativa (§11.3: as
            // corridas não podem mudar de condição) e quando a bancada já deu o endereço.
            procurar()
        }
    }

    /**
     * A paisagem em duas colunas (§11.1): o endereço à esquerda, o PIN e o Conectar à direita. O título e
     * o caminho saem da paisagem (o cabeçalho diz "Controlar"), e a lista fica com uma linha e meia. **Só na
     * tela baixa** ([telaBaixa], 30/09): o tablet deitado fica numa coluna centrada, inteira, como em pé.
     */
    private fun arrumarOrientacao() {
        val paisagem = telaBaixa()
        val v = if (paisagem) View.GONE else View.VISIBLE
        b.textTituloControle.visibility = v
        b.textSubtituloControle.visibility = v
        b.caixaDosPrompters.layoutParams = b.caixaDosPrompters.layoutParams.apply { height = dp(if (paisagem) 80 else 144) }
        b.colunasDoControle.requestLayout()
    }

    override fun onConfigurationChanged(novaConfiguracao: android.content.res.Configuration) {
        super.onConfigurationChanged(novaConfiguracao)
        arrumarOrientacao()
    }

    override fun onStart() {
        super.onStart()
        principal.post(tique)
    }

    override fun onStop() {
        // Segundo plano com o dedo no botão: o texto para. No `onStop`, e não no `onPause`: o
        // `onNewIntent` da bancada chega entre um `onPause` e um `onResume`, com a tela visível.
        modo?.soltarTudo("segundo plano")
        principal.removeCallbacks(tique)
        replica?.let { salvarJa(it, "segundo plano") }
        super.onStop()
    }

    /** A bancada com a tela de pé (`--es papel controle_de_pe`): o modo e os dedos, sem recriar a sessão. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val m = modo ?: return
        if (intent.hasExtra(EXTRA_SEGURAR_PARA_ROLAR)) m.ligar(intent.getBooleanExtra(EXTRA_SEGURAR_PARA_ROLAR, false), "bancada")
        intent.getStringExtra(EXTRA_SEGURAR)?.let { m.bancada(it, intent.getIntExtra(EXTRA_DEDO, 0)) }
        intent.getStringExtra(EXTRA_ESCOLHA)?.let {
            pergunta?.escolherPelaBancada(it)
            desenhar()
        }
    }

    /** Grava o salvo fora da thread da tela e em ordem (até ~1 MiB com as cópias, §11.5). */
    private fun salvarJa(r: ReplicaDoTeleprompter, porque: String) {
        r.salvarEmOrdem { Log.i(TAG, "controle: salvo gravado ($porque)") }
    }

    /** A tela está fechando: a procura na rede em curso para (ver `QuallBrowser.varrer`). */
    @Volatile
    private var fechando = false

    override fun onDestroy() {
        fechando = true
        modo?.soltarTudo("tela fechando")
        principal.removeCallbacksAndMessages(null)
        val s = sessao
        val t = threadDaSessao
        val r = replica
        s?.parar()
        if (r != null) {
            // Pelo `post`: numa recriação a tela nova pede a réplica antes de a velha soltar
            // (ver `PrompterActivity.onDestroy`).
            principal.post {
                thread(name = "quall-controle-fim") {
                    runCatching { t?.join(3_000) }
                    Replicas.soltar(r)
                }
            }
        }
        if (::multicastLock.isInitialized) multicastLock.release()
        super.onDestroy()
    }

    // --- escolher ----------------------------------------------------------------------------------

    private fun procurar() {
        multicastLock.acquire()
        // "procurando" (a bolinha violeta que pulsa) no lugar da frase de antes; o botão fica desligado
        // enquanto a procura de 5 s anda.
        b.linhaProcurandoPrompters.visibility = View.VISIBLE
        b.buttonProcurarPrompters.isEnabled = false
        b.buttonProcurarPrompters.alpha = 0.4f
        b.textListaDePromptersVazia.visibility = View.GONE
        thread(name = "quall-controle-procura") {
            // Só quem anuncia "teleprompter" (a chave `pa`), e nunca este aparelho. O lock é solto no fim
            // de cada procura, e a procura para se a tela fechar no meio.
            val comLock: Boolean
            val achados = try {
                Papeis.soTeleprompters(
                    QuallBrowser.varrer(5_000) { fechando }.filter { it.deviceId != eu.deviceId }
                )
            } finally {
                comLock = multicastLock.isHeld()
                multicastLock.release()
            }
            if (fechando) return@thread
            runOnUiThread {
                lista.submit(achados)
                b.linhaProcurandoPrompters.visibility = View.GONE
                b.buttonProcurarPrompters.isEnabled = true
                b.buttonProcurarPrompters.alpha = 1f
                b.textListaDePromptersVazia.text = getString(R.string.tp_lista_vazia)
                b.textListaDePromptersVazia.visibility = if (achados.isEmpty()) View.VISIBLE else View.GONE
                Log.i(TAG, "controle: ${achados.size} teleprompter(s) na rede (lock=$comLock)")
            }
        }
    }

    /** O erro do formulário, como Aviso vermelho, com frase inteira (como o iOS). Vazio apaga. */
    private fun erro(texto: String) {
        b.textControleStatus.text = texto
        b.textControleStatus.visibility = if (texto.isEmpty()) View.GONE else View.VISIBLE
    }

    /**
     * "Colar endereço": um `host:porta` da área de transferência — ou um `quall://PIN@host:porta`
     * antigo, que ainda é entendido (tolerância; nenhuma tela o mostra desde 24/09). Com PIN, conecta já.
     */
    private fun colarEndereco() {
        val colado = (getSystemService(android.content.ClipboardManager::class.java)?.primaryClip
            ?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()).orEmpty().trim()
        val destino = EnderecoDoTeleprompter.doControle(colado)
        if (destino == null) {
            erro(getString(R.string.tp_nao_e_endereco))
            return
        }
        erro("")
        b.editEnderecoPrompter.setText(destino.endpoint)
        destino.pin?.let {
            b.editPinPrompter.setText(it)
            conectarTocado()
        }
    }

    private fun conectarTocado() {
        val r = replica ?: return
        erro("")
        val campo = b.editEnderecoPrompter.text.toString().trim()
        // **A porta do teleprompter entra aqui, e não no núcleo**: só o IP, o `endereco_manual` do
        // núcleo completaria com 7877 — a porta do espelhamento. A regra das quatro cascas é 7979
        // (`teleprompter/Enderecos.kt`). Um `quall://<pin>@<host>:<porta>` colado ainda é entendido
        // e traz o PIN junto — tolerância, sem anunciar: nenhuma tela mostra link nem QR (24/09).
        val destino = if (campo.isEmpty()) null else EnderecoDoTeleprompter.doControle(campo)
        if (destino == null) {
            erro(getString(R.string.tp_digite_endereco))
            return
        }
        val endpoint = destino.endpoint
        val digitado = b.editPinPrompter.text.toString().trim().ifEmpty { destino.pin.orEmpty() }
        val pin = when {
            digitado.length == 6 && digitado.all(Char::isDigit) -> digitado
            digitado.isNotEmpty() -> {
                erro(getString(R.string.tp_pin_seis_digitos))
                return
            }
            eu.temParesConhecidos() -> null
            else -> {
                erro(getString(R.string.tp_digite_pin))
                return
            }
        }
        if (sessao != null) {
            // A sessão anterior ainda está saindo (fechar e salvar, ~100–300 ms). O toque não se
            // perde: sai quando ela terminar (achado da revisão de 13/09).
            conectarAoTerminar = true
            erro(getString(R.string.tp_encerrando))
            return
        }
        val s = SessaoDoControle(eu, r, endpoint, pin, Bancada.prenderEm(this), ouvinte, t)
        sessao = s
        mostrarConectando(endpoint, "")
        threadDaSessao = thread(name = "quall-controle") {
            try {
                s.rodar()
            } finally {
                principal.post {
                    if (sessao === s) {
                        sessao = null
                        if (conectarAoTerminar) {
                            conectarAoTerminar = false
                            conectarTocado()
                        }
                    }
                }
            }
        }
    }

    private fun desconectar() {
        // O soltar sai na sessão ainda de pé; depois do fim dela, a primeira coisa é o `peer_lost`
        // (em `Conducao`), e nenhuma edição do segurar entra no meio (regra da revisão do núcleo).
        modo?.soltarTudo("desconectar")
        sessao?.parar()
        mostrarEscolha()
    }

    private fun mostrarEscolha() {
        b.painelControle.visibility = View.GONE
        b.conectandoControle.visibility = View.GONE
        b.escolhaControle.visibility = View.VISIBLE
        modo?.painel(false)
    }

    /** "Conectando em X…", com o spinner e o Cancelar (a tela `conectando` do iOS). */
    private fun mostrarConectando(endpoint: String, aviso: String) {
        b.escolhaControle.visibility = View.GONE
        b.painelControle.visibility = View.GONE
        b.conectandoControle.visibility = View.VISIBLE
        b.textConectando.text = getString(R.string.tp_conectando_em, endpoint)
        b.textConectandoAviso.text = aviso
        b.textConectandoAviso.visibility = if (aviso.isEmpty()) View.GONE else View.VISIBLE
        modo?.painel(false)
    }

    private fun mostrarControle() {
        b.escolhaControle.visibility = View.GONE
        b.conectandoControle.visibility = View.GONE
        b.painelControle.visibility = View.VISIBLE
        modo?.painel(true)
        desenhar()
    }

    // --- a sessão ------------------------------------------------------------------------------

    private fun aplicarFase(f: SessaoDoControle.Fase) {
        // A escolha da bancada vale para a sessão em que foi dada: acabou (e não uma tentativa que
        // falhou antes de a sessão subir), fica esquecida.
        if (fase is SessaoDoControle.Fase.Controlando && f !is SessaoDoControle.Fase.Controlando) pergunta?.esquecerEscolhaDaBancada()
        fase = f
        when (f) {
            is SessaoDoControle.Fase.Conectando ->
                mostrarConectando(f.endpoint, if (f.tentativa > 1) getString(R.string.tp_tentativa, f.tentativa) else "")
            is SessaoDoControle.Fase.Controlando -> {
                sessaoSubiuEm = SystemClock.elapsedRealtime()
                endpointAtual = f.endpoint
                Log.i(TAG, "controle: controlando o par" +
                    if (f.pareamentoNovo) " · pareado agora por PIN" else " · pareamento retomado")
                // O PIN já cumpriu o papel dele: a volta de uma queda entra sem PIN, e um PIN velho
                // parado no campo faria da próxima conexão um pareamento novo (a lição do receptor).
                b.editPinPrompter.setText("")
                mostrarControle()
            }
            is SessaoDoControle.Fase.Reconectando -> {
                endpointAtual = f.endpoint
                // Com a tela "Conectando…" à vista (a sessão ainda não tinha subido), o porquê de estar
                // tentando de novo, e não só o número da tentativa (a revisão do código, 28/09).
                if (b.conectandoControle.visibility == View.VISIBLE) {
                    mostrarConectando(f.endpoint, listOf(f.aviso, if (f.tentativa > 1) getString(R.string.tp_tentativa, f.tentativa) else "")
                        .filter { it.isNotBlank() }.joinToString("\n"))
                }
            }
            is SessaoDoControle.Fase.PrecisaDePin -> {
                mostrarEscolha()
                b.editEnderecoPrompter.setText(f.endpoint)
                b.editPinPrompter.setText("")
                b.editPinPrompter.requestFocus()
                erro(f.mensagem.replaceFirstChar { it.uppercase() })
            }
            is SessaoDoControle.Fase.Erro -> {
                mostrarEscolha()
                erro(f.mensagem.replaceFirstChar { it.uppercase() })
            }
            SessaoDoControle.Fase.Parado -> mostrarEscolha()
        }
        desenhar()
    }

    /** O endereço do prompter desta sessão, para o cabeçalho. */
    private var endpointAtual = ""

    private fun aplicarMudancas(bits: Int) {
        val r = replica ?: return
        if (bits == 0) return
        val t = if (bits and MudouNoTeleprompter.TEXTO != 0) r.texto() else null
        if (t != null) {
            Log.i(TAG, "controle: roteiro chegou do prompter — ${t.toByteArray(Charsets.UTF_8).size} bytes, resumo ${Resumo.de(t)}")
            if (editor.aberto) editor.chegou(t)
            previaDoRoteiro = null
        }
        val relevantes = bits and MudouNoTeleprompter.POSICAO.inv() and MudouNoTeleprompter.PAR.inv()
        if (relevantes != 0) {
            r.estado()?.let { Log.i(TAG, "controle: mudou pelo prompter [${nomesDosBits(bits)}] → ${linhaDeEstado(it)}") }
        }
        // §11.5 (achado B7): uma cópia nova só existe na memória até o salvo ser gravado.
        if (bits and MudouNoTeleprompter.COPIA_DO_TEXTO != 0) salvarJa(r, "cópia nova do texto") // i18n-fora: porquê do diário
        desenhar()
    }

    // --- desenhar ------------------------------------------------------------------------------

    /** A prévia do roteiro (os primeiros 160 caracteres), relida só quando o texto muda. */
    private var previaDoRoteiro: String? = null
    private var bytesDaPrevia = -1L
    private var avisosDesenhados = ""
    private var desenhandoSegurar = false

    private fun desenhar() {
        val r = replica ?: return
        val e = r.estado() ?: return
        estado = e
        val f = fase
        val controlando = f is SessaoDoControle.Fase.Controlando
        val reconectando = f is SessaoDoControle.Fase.Reconectando
        val motivo = (f as? SessaoDoControle.Fase.Reconectando)?.aviso
        val sessaoHa = if (controlando) SystemClock.elapsedRealtime() - sessaoSubiuEm else 0L
        val perdida = Avisos.conexaoPerdida(reconectando, controlando, sessaoHa, e.parVistoHaMs)

        // O cabeçalho (tudo por `seMudou`: isto roda a cada 250 ms, e reescrever o mesmo texto é
        // evento de acessibilidade à toa — ver `Textos.kt`).
        val par = (f as? SessaoDoControle.Fase.Controlando)?.par.orEmpty()
        b.textControleTitulo.seMudou(when {
            reconectando -> getString(R.string.tp_conexao_perdida_titulo)
            controlando && par.isEmpty() -> getString(R.string.tp_conectado_ao_prompter)
            controlando -> getString(R.string.tp_conectado_a, par)
            else -> getString(R.string.tp_conectando)
        })
        b.textControleSub.seMudou(endpointAtual)
        val cor = if (controlando && !perdida) Cores.VERDE else Cores.VERMELHO
        if (b.bolinhaControle.tag != cor) {
            b.bolinhaControle.tag = cor
            b.bolinhaControle.background = android.graphics.drawable.GradientDrawable().apply {
                shape = android.graphics.drawable.GradientDrawable.OVAL
                setColor(cor)
            }
        }

        rolandoNoRotulo = e.rolando
        if (::botaoPlay.isInitialized) {
            botaoPlay.trocar(if (e.rolando) R.drawable.ic_q_pausa else R.drawable.ic_q_play, getString(if (e.rolando) R.string.tp_pausar else R.string.tp_rolar))
        }
        val progresso = (e.posicao * 1000).toInt()
        if (!arrastandoProgresso && b.seekPosicao.progress != progresso) b.seekPosicao.progress = progresso
        if (!arrastandoProgresso) b.textProgresso.seMudou(getString(R.string.tp_porcento, e.posicao * 100))
        modo?.let { m ->
            if (b.buttonSegurarParaRolar.isChecked != m.ligado) {
                desenhandoSegurar = true
                b.buttonSegurarParaRolar.isChecked = m.ligado
                desenhandoSegurar = false
            }
        }
        montador?.atualizar()

        // O roteiro: o tamanho e a prévia (ou "Sem roteiro.").
        b.textRoteiroInfo.seMudou(getString(R.string.tp_kib, e.textoBytes / 1024.0))
        if (previaDoRoteiro == null || bytesDaPrevia != e.textoBytes) {
            val t = r.texto().orEmpty()
            previaDoRoteiro = t.take(160)
            bytesDaPrevia = e.textoBytes
        }
        b.textPreviaDoRoteiro.seMudou(previaDoRoteiro.orEmpty().ifEmpty { getString(R.string.tp_sem_roteiro_curto) })

        // Em segundos, e não em ms: o número que muda a cada volta é justamente o que não se lê.
        // A linha de diagnóstico só aparece com a bancada (`Bancada.diagnosticoVisivel`): fica em português.
        fun segundos(ms: Long?) = when {
            ms == null -> "—"
            ms < 1_000 -> "agora"
            else -> "há ${ms / 1_000} s" // i18n-fora: diagnóstico de bancada
        }
        if (b.textControleDetalhe.visibility == View.VISIBLE) b.textControleDetalhe.seMudou(buildString {
            append("teleprompter visto: ${segundos(e.parVistoHaMs)} · ")
            append("sem confirmação: ${if (e.semConfirmacaoHaMs == null) "—" else segundos(e.semConfirmacaoHaMs)}\n") // i18n-fora: diagnóstico de bancada
            append("estados ${e.contador("estados_enviados")} · textos ${e.contador("textos_enviados")} · ")
            append("recebidas ${e.contador("recebidas")} · recusados ${e.contador("campos_recusados")}")
        })

        // Os avisos em faixas (`AvisosDoTeleprompter`): a conexão perdida em vermelho, o resto em laranja.
        val linhas = Avisos.doControle(e, reconectando, controlando, sessaoHa, motivo, t)
        val novo = linhas.joinToString("\n")
        if (novo != avisoMostrado) {
            Log.i(TAG, if (novo.isEmpty()) "controle: aviso apagado" else "controle: aviso LIGADO — $novo")
            avisoMostrado = novo
        }
        val chave = "$perdida|$novo"
        if (chave != avisosDesenhados) {
            avisosDesenhados = chave
            b.avisosControle.removeAllViews()
            linhas.forEachIndexed { i, t ->
                val caiu = i == 0 && perdida
                b.avisosControle.addView(faixaDeAviso(this, Aviso(t, if (caiu) Cores.VERMELHO else Cores.LARANJA,
                    if (caiu) R.drawable.ic_q_sem_rede else R.drawable.ic_q_aviso)),
                    LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                        topMargin = dp(6)
                    })
            }
        }
        modo?.desenhar(e, f, sessaoHa)
        // A caixa só com o painel da sessão à mostra, e não no "Conectando" de uma conexão nova: a
        // pergunta que sobrou de outro prompter não cobre a tela enquanto a sessão nova não sobe.
        pergunta?.desenhar(e, b.painelControle.visibility == View.VISIBLE && f !is SessaoDoControle.Fase.Conectando)
        roteiros?.desenhar(e)
    }

    // --- botões --------------------------------------------------------------------------------

    private lateinit var botaoPlay: BotaoDeIcone
    private var montador: MontadorDeAjustes? = null

    /** A cor do texto do tema (claro ou escuro): os controles do texto seguem o sistema, como no iOS. */
    private fun corDoTexto(): Int {
        val a = obtainStyledAttributes(intArrayOf(android.R.attr.textColorPrimary))
        val cor = a.getColor(0, Cores.BRANCO)
        a.recycle()
        return cor
    }

    private fun ligarBotoes(r: ReplicaDoTeleprompter) {
        b.buttonVoltarDoControle.setOnClickListener { finish() }
        b.buttonProcurarPrompters.setOnClickListener { procurar() }
        b.buttonConectarControle.setOnClickListener { conectarTocado() }
        b.buttonColarEndereco.setOnClickListener { colarEndereco() }
        b.buttonCancelarConexao.setOnClickListener { desconectar() }
        b.buttonDesconectar.setOnClickListener { desconectar() }
        b.buttonSegurarParaRolar.setOnCheckedChangeListener { _, ligado ->
            if (!desenhandoSegurar) modo?.ligar(ligado, "opção do painel") // i18n-fora: quem pediu, para o diário
        }
        b.buttonRoteirosGuardadosEscolha.setOnClickListener { roteiros?.abrir() }
        b.buttonRoteirosGuardadosPainel.setOnClickListener { roteiros?.abrir() }
        if (Bancada.diagnosticoVisivel(this)) b.textControleDetalhe.visibility = View.VISIBLE

        fun editar(acao: (EstadoDoTeleprompter) -> Int) {
            val e = estado ?: r.estado() ?: return
            val st = acao(e)
            if (st != QuallNative.Status.OK) Log.w(TAG, "controle: edição recusada (${QuallNative.Status.nome(st)})")
            desenhar()
        }

        // O transporte (`transporte` do iOS): começo, −5 %, −1 %, play/pausa, +1 %, +5 %.
        val t = b.transporteControle
        fun botao(icone: Int, rotulo: String, legenda: String?, peso: Float = 1f, acao: () -> Unit): View {
            val v = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = android.view.Gravity.CENTER
                minimumHeight = dp(56)
                background = fundoArredondado(Cores.SUPERFICIE_ALTA, dp(12).toFloat())
                contentDescription = rotulo
                isClickable = true
                isFocusable = true
                addView(android.widget.ImageView(context).apply {
                    setImageResource(icone)
                    imageTintList = android.content.res.ColorStateList.valueOf(Cores.ACENTO_CLARO)
                }, LinearLayout.LayoutParams(dp(22), dp(22)))
                if (legenda != null) addView(android.widget.TextView(context).apply {
                    text = legenda
                    setTextColor(Cores.ACENTO_CLARO)
                    textSize = 11f
                    typeface = android.graphics.Typeface.MONOSPACE
                })
                setOnClickListener { acao() }
            }
            t.addView(v, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, peso).apply {
                if (t.childCount > 0) leftMargin = dp(8)
            })
            return v
        }
        botao(R.drawable.ic_q_inicio, getString(R.string.tp_voltar_ao_comeco), null) { editar { r.saltar(0.0) } }
        botao(R.drawable.ic_q_recuar, getString(R.string.tp_voltar_5), "−5%") { editar { r.pular(-Ajustes.PULO) } }
        botao(R.drawable.ic_q_voltar, getString(R.string.tp_voltar_1), "−1%") { editar { r.pular(-0.01) } }
        // Só o que a pessoa apertou (o que ela via), contra o estado relido agora: nunca reafirma
        // `set_scrolling(true)` com o texto já rolando, e nunca no meio de um segurar (regra da
        // revisão do núcleo, 14/09; ver `SegurarParaRolar.rolarOuParar`).
        botaoPlay = BotaoDeIcone(this, R.drawable.ic_q_play, getString(R.string.tp_rolar)).apply {
            pintar(Cores.ACENTO)
            minimumHeight = dp(56)
            setOnClickListener {
                val agora = r.estado() ?: return@setOnClickListener
                val v = SegurarParaRolar.rolarOuParar(!rolandoNoRotulo, agora.rolando, agora.segurando)
                if (v != null) editar { r.definirRolando(v) } else {
                    Log.i(TAG, "controle: play/pausa sem efeito — rolando=${agora.rolando} segurando=${agora.segurando}")
                    desenhar()
                }
            }
        }
        t.addView(botaoPlay, LinearLayout.LayoutParams(0, dp(56), 1.6f).apply { leftMargin = dp(8) })
        botao(R.drawable.ic_q_seta_direita, getString(R.string.tp_pular_1), "+1%") { editar { r.pular(0.01) } }
        botao(R.drawable.ic_q_avancar, getString(R.string.tp_pular_5), "+5%") { editar { r.pular(Ajustes.PULO) } }

        // Os controles do texto: os mesmos da folha de Ajustes do prompter. No controle a velocidade
        // sai ao vivo; fonte, margem e linha de leitura, ao soltar (cada uma refaz o layout lá).
        val m = MontadorDeAjustes(this, corDoTexto())
        montador = m
        m.controlesDoTexto(b.controlesDoTextoControle, object : ControlesDoTextoAlvo {
            override fun estadoAgora() = estado ?: r.estado() ?: EstadoDoTeleprompter()
            override fun definirVelocidade(v: Double) = editar { r.definirVelocidade(v.coerceIn(0.05, 20.0)) }
            override fun definirFonte(v: Double) = editar { r.definirFonte(v.coerceIn(8.0, 400.0)) }
            override fun definirMargem(v: Double) = editar { r.definirMargem(v.coerceIn(0.0, 0.45)) }
            override fun definirLinhaDeLeitura(v: Double) = editar { r.definirLinhaDeLeitura(v.coerceIn(0.0, 1.0)) }
            override fun definirEspelho(ligado: Boolean) = editar { r.definirEspelho(ligado) }
        })

        b.seekPosicao.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(s: SeekBar?, p: Int, doUsuario: Boolean) {
                if (doUsuario) b.textProgresso.text = getString(R.string.tp_porcento_alvo, p / 10.0)
            }

            override fun onStartTrackingTouch(s: SeekBar?) {
                arrastandoProgresso = true
            }

            override fun onStopTrackingTouch(s: SeekBar?) {
                arrastandoProgresso = false
                val alvo = (s?.progress ?: 0) / 1000.0
                editar { r.saltar(alvo) }
            }
        })
        b.buttonEditarControle.setOnClickListener { r.texto()?.let { editor.abrir(it) } }
    }

    // --- bancada -------------------------------------------------------------------------------

    /** Ver `PrompterActivity.carregarRoteiroDaBancada`: arquivo no contêiner externo, só o nome. */
    private fun carregarRoteiroDaBancada(r: ReplicaDoTeleprompter, nome: String) {
        val base = getExternalFilesDir(null) ?: return
        val f = File(base, File(nome).name)
        val t = runCatching { f.readText(Charsets.UTF_8) }.getOrElse {
            Log.w(TAG, "bancada: não li o roteiro ${f.absolutePath}: ${Log.erroExterno(it.message)}")
            return
        }
        val st = r.definirTexto(t)
        if (st == QuallNative.Status.OK) salvarJa(r, "o roteiro da bancada")
        Log.i(TAG, "bancada: roteiro de ${f.name} — ${t.toByteArray(Charsets.UTF_8).size} bytes, resumo ${Resumo.de(t)}, " +
            "set_text=${QuallNative.Status.nome(st)}")
    }
}
