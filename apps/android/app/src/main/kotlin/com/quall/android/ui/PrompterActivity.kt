package com.quall.android.ui

import android.content.Intent
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import android.view.View
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.quall.android.R
import com.quall.android.core.Bancada
import com.quall.android.core.DeviceIdentity
import com.quall.android.core.Idioma
import com.quall.android.core.QuallNative
import com.quall.android.core.QuallNative.MudouNoTeleprompter
import com.quall.android.databinding.ActivityPrompterBinding
import com.quall.android.teleprompter.Ajustes
import com.quall.android.teleprompter.Avisos
import com.quall.android.teleprompter.EnderecoDoTeleprompter
import com.quall.android.teleprompter.Enquadramento
import com.quall.android.teleprompter.EstadoDoTeleprompter
import com.quall.android.teleprompter.GiroDoTexto
import com.quall.android.teleprompter.LimitadorDeEnvio
import com.quall.android.teleprompter.Orientacao
import com.quall.android.teleprompter.ReplicaDoTeleprompter
import com.quall.android.teleprompter.Replicas
import com.quall.android.teleprompter.Resumo
import com.quall.android.teleprompter.SegurarParaRolar
import com.quall.android.teleprompter.SessaoDoPrompter
import java.io.File
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * **O prompter**: mostra o texto rolando e hospeda com o papel `"teleprompter"` para um controle
 * entrar (`docs/contrato-teleprompter.md`). No molde de [ReceptorActivity]: tela cheia, tela acesa,
 * a sessão numa thread própria e a tela como função do estado.
 *
 * ## Quem manda em quê
 *
 * - **A posição é desta tela** ([VistaDoRoteiro]): ela anda com o tempo do quadro e é relatada ao
 *   núcleo (`set_position`, que limita o envio a 4 Hz). O estado só a acerta num **salto** (bit
 *   `_JUMP`): vai-se até `"salto"`, relata-se, e `rolando` fica como está (§6).
 * - **Todo o resto vem da réplica**: rolando, velocidade, fonte, margem, linha de leitura, espelho e
 *   o texto. Um toque aqui edita a réplica (que manda na hora ao controle) e a tela relê o estado —
 *   o mesmo caminho de uma edição que chega do outro lado.
 * - `_POSITION` é ignorado aqui (§6): a posição do prompter é a dele.
 *
 * ## Quando o controle cai
 *
 * A regra do usuário (13/09): **o texto continua como estava** — o núcleo não mexe em `rolando`
 * (`POLITICA_SEM_PAR`) — e o aviso laranja fica até o controle voltar. A sessão volta a esperar na
 * mesma porta e com o mesmo PIN ([SessaoDoPrompter]); o aviso mostra o PIN para um controle novo.
 *
 * ## Sem serviço em primeiro plano, como o receptor
 *
 * A opção "Manter tela ligada", ligada por padrão, usa `FLAG_KEEP_SCREEN_ON` enquanto esta janela
 * está visível. A escolha é local, compartilhada com a câmera e a transmissão, e não vai ao controle.
 *
 * ## Um prompter por aparelho
 *
 * A tela "Teleprompter com câmera" ([PrompterComCameraActivity]) é esta mesma tela com a câmera ao
 * lado. As duas não abrem juntas (`docs/teleprompter-com-camera.md` §2.5): teriam réplicas e PINs
 * diferentes, e a segunda iria para a 7980 sem ninguém saber. A que chega com a outra de pé fecha
 * e diz por quê. A mesma classe duas vezes é uma recriação (a bancada abre com `CLEAR_TOP`), e vale.
 */
open class PrompterActivity : AppCompatActivity() {

    companion object {
        /** Bancada: o PIN (seis dígitos). Um erro de PIN troca de qualquer jeito (§2). */
        const val EXTRA_PIN = "pin"

        /**
         * Bancada: a porta de sinalização. Sem ela, **7979** — a do teleprompter nas quatro cascas
         * ([EnderecoDoTeleprompter.PORTA_PADRAO]); a 7877 é a do espelhamento. Ocupada, o prompter
         * pega a próxima livre e a tela mostra.
         */
        const val EXTRA_PORTA = "porta"

        /** Bancada: não anunciar por mDNS. */
        const val EXTRA_SEM_MDNS = "sem_mdns"

        /**
         * Bancada: a orientação da tela ([Orientacao.chave] ou o nome — `paisagem`,
         * `paisagem_invertida`, `retrato`, `automatica`). Vale como escolher no botão: aplica **e
         * guarda** neste aparelho. Com a tela de pé, chega por [onNewIntent] sem recriá-la.
         */
        const val EXTRA_ORIENTACAO = "orientacao"

        /**
         * Bancada: com `false`, a [EXTRA_ORIENTACAO] vale **só nesta abertura** e não é guardada. As
         * provas abriam a R5 com `retrato` e deixavam a escolha gravada (01/10: os quatro aparelhos; no
         * tablet, que recusa girar, o texto ficou girado). Padrão `true`: o contrato de sempre.
         */
        const val EXTRA_GUARDAR_ORIENTACAO = "guardar_orientacao"

        /** Bancada: a posição da leitura (fração do percurso, 0..1) — o mesmo que arrastar o texto até lá. */
        const val EXTRA_POSICAO = "posicao"

        /** Bancada, só na tela de pé ([onNewIntent]): rolar ou parar — o mesmo que o botão. */
        const val EXTRA_ROLAR = "rolar"

        /**
         * Bancada: liga ou desliga a "Fonte automática" (vale como o botão: aplica e guarda). Com
         * [EXTRA_TABELA_DA_FONTE], a próxima conta escreve a tabela de linhas em
         * `getExternalFilesDir(null)/fonte-automatica.tsv`.
         */
        const val EXTRA_FONTE_AUTOMATICA = "fonte_automatica"
        const val EXTRA_TABELA_DA_FONTE = "tabela_da_fonte"

        /** As preferências **desta tela**, fora do salvo do núcleo: a orientação é do aparelho, não do teleprompter. */
        private const val PREFERENCIAS = "quall-prompter"
        private const val PREF_ORIENTACAO = "orientacao"
        private const val PREF_FONTE_AUTOMATICA = "fonte_automatica"
        private const val PREF_ENQUADRAMENTO = "enquadramento_" // + retrato | paisagem

        /** Bancada: nome de um arquivo em `getExternalFilesDir(null)` com um roteiro a carregar. */
        const val EXTRA_ROTEIRO = "roteiro"

        private const val TAG = "QuallTeleprompter"
        private const val TIQUE_MS = 250L

        /** A tela de prompter viva agora, de qualquer das duas classes. Só a thread principal toca. */
        @Volatile private var aberta: java.lang.ref.WeakReference<PrompterActivity>? = null

        /** Há uma tela de prompter (comum ou R5) aberta agora? Qualquer thread. */
        internal val algumaAberta: Boolean get() = aberta?.get() != null
        private const val PULSO_NO_REGISTRO_MS = 2_000L

        /** Arrastando a linha de leitura: no máximo um envio a cada 120 ms (a regra do Mac), e o último sempre sai. */
        private const val INTERVALO_DA_LINHA_MS = 120L

        /**
         * Quanto esperar, depois de pedir a orientação, para concluir que o sistema a recusou e
         * girar só o texto. No telefone a rotação chega antes (a configuração muda em ~0,3 s) e o
         * texto não chega a girar.
         */
        private const val ESPERA_PELA_ROTACAO_MS = 1_000L
    }

    protected lateinit var b: ActivityPrompterBinding
        private set
    private lateinit var eu: DeviceIdentity
    private lateinit var editor: EditorDeTexto
    private var replica: ReplicaDoTeleprompter? = null
    private var sessao: SessaoDoPrompter? = null
    private var threadDaSessao: Thread? = null
    private var orientacao = Orientacao.PADRAO
    private val limitadorDaLinha = LimitadorDeEnvio(INTERVALO_DA_LINHA_MS)
    private var enviosDaLinha = 0
    private var arrastoDaLinhaDesde = 0L
    private val principal = Handler(Looper.getMainLooper())

    /** As frases dos módulos puros (avisos, sessão), no idioma desta tela (`docs/traducao.md`, Android). */
    protected val textos by lazy { Idioma.textos(this) }

    // --- o que a tela sabe (só a thread principal toca) ------------------------------------

    private var fase: SessaoDoPrompter.Fase? = null
    private var jaTeveControle = false
    private var estado = EstadoDoTeleprompter()
    private var texto = ""
    private var telaCheia = false
    private var avisoMostrado = ""

    /** O que o botão "Rolar"/"Parar" mostra agora: o que a pessoa aperta é o contrário disto. */
    private var rolandoNoRotulo = false
    private var ultimoPulsoNoRegistro = 0L

    /** Os bits que a thread da sessão juntou e a principal ainda não aplicou. */
    private val bitsPendentes = AtomicInteger(0)
    private val aplicarBits = Runnable { aplicarMudancas(bitsPendentes.getAndSet(0)) }

    private val tique = object : Runnable {
        override fun run() {
            atualizarEstadoEAvisos()
            principal.postDelayed(this, TIQUE_MS)
        }
    }

    private val ouvinte = object : SessaoDoPrompter.Ouvinte {
        override fun fase(f: SessaoDoPrompter.Fase) {
            principal.post { aplicarFase(f) }
        }

        override fun mudou(bits: Int) {
            if (bitsPendentes.getAndUpdate { it or bits } == 0) principal.post(aplicarBits)
        }
    }

    /**
     * O gesto de voltar **nunca fecha o prompter de primeira**: no meio de uma leitura, um voltar
     * sem querer na borda da tela derrubaria o texto e a sessão. Na tela cheia, o primeiro devolve os
     * controles e diz como sair; com os controles à vista, o segundo fecha.
     */
    private val voltar = object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() {
            when {
                editor.aberto -> editor.voltar()
                aoVoltar() -> Unit
                !controlesVisiveis -> {
                    mostrarControles(true)
                    avisoCurto(getString(R.string.tp_voltar_de_novo_fecha), longo = false)
                }
                else -> finish()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // O título que o TalkBack anuncia, no idioma escolhido (o do manifesto sai no do sistema), e
        // o que a recusa abaixo cita.
        setTitle(tituloDaTela)
        b = ActivityPrompterBinding.inflate(layoutInflater)
        setContentView(b.root)
        // Um prompter por aparelho (ver a doc da classe).
        val outra = aberta?.get()
        if (outra != null && outra !== this && !outra.isFinishing && outra.javaClass != javaClass) {
            val motivo = getString(R.string.tp_um_prompter_por_aparelho, outra.title, title)
            Log.w(TAG, "prompter: ${javaClass.simpleName} recusada — ${outra.javaClass.simpleName} está aberta")
            Toast.makeText(this, motivo, Toast.LENGTH_LONG).show()
            recusada = true
            finish()
            return
        }
        aberta = java.lang.ref.WeakReference(this)
        montarTela()
        // A mesma escolha da câmera e da transmissão, válida só enquanto esta janela está à vista.
        TelaLigada(this) { !recusada }
        // A orientação deste aparelho: a da bancada (que vale como escolher no botão) ou a guardada.
        val orientacaoDaBancada = Orientacao.daChave(intent?.getStringExtra(EXTRA_ORIENTACAO))
        aplicarOrientacao(orientacaoDaBancada ?: orientacaoGuardada(),
            guardar = orientacaoDaBancada != null && intent?.getBooleanExtra(EXTRA_GUARDAR_ORIENTACAO, true) != false)
        eu = DeviceIdentity.load(this)
        b.vistaRoteiro.semRoteiro = getString(R.string.tp_sem_roteiro)

        val r = if (QuallNative.carregado) Replicas.obter(this, eu.deviceId, QuallNative.PAPEL_TELEPROMPTER) else null
        if (r == null) {
            val motivo = if (!QuallNative.carregado) getString(R.string.tp_nucleo_nao_carregou, QuallNative.erroDeCarga.orEmpty())
            else getString(R.string.tp_replica_falhou, QuallNative.lastError())
            // Um aviso que fica (e não um recado que some): sem réplica, a tela não faz nada.
            avisoPersistente = motivo
            b.textEstadoPrompter.text = getString(R.string.tp_estado_parado)
            desenharAvisos(emptyList())
            // A R5 tira o alto desta tela: o motivo vai também para o recado dela (a faixa), senão
            // ficaria invisível lá (a revisão do código, 28/09).
            avisoCurto(motivo, longo = true)
            return
        }
        replica = r
        aoTerReplica(r)
        // "Segurar para rolar" (§12.2): esta tela rola para trás e para quando `rolando` cai
        // (`VistaDoRoteiro.paraTras`), então diz que entende — e só por isso o controle pode segurar.
        Log.i(TAG, "prompter: segurar para rolar ligado (${QuallNative.Status.nome(r.ligarSegurar())})")

        editor = EditorDeTexto(
            b.editorPrompter, this, QuallNative.teleprompterMaxTextBytes(),
            confirmar = { t ->
                r.definirTexto(t).also {
                    if (it == QuallNative.Status.OK) {
                        releTudo()
                        // Salva já: um processo morto antes do `onStop` (medido no A07 com
                        // `force-stop`, 13/09) voltava sem o roteiro que acabara de ser confirmado.
                        thread(name = "quall-prompter-salvar") { r.salvar() }
                    }
                }
            },
            aoFechar = { if (telaCheia) esconderBarrasDoSistema() },
        )
        onBackPressedDispatcher.addCallback(this, voltar)

        b.vistaRoteiro.aoAndar = { p -> r.definirPosicao(p) }
        b.vistaRoteiro.aoTocar = { aoTocarNoTexto() }
        b.vistaRoteiro.aoMoverLinha = { v, soltou -> moverLinhaDeLeitura(r, v, soltou) }
        ligarAjustesLocais(r)
        ligarBotoes(r)
        ligarRecuos()

        intent?.getStringExtra(EXTRA_ROTEIRO)?.let { carregarRoteiroDaBancada(r, it) }
        intent?.getStringExtra(EXTRA_POSICAO)?.toDoubleOrNull()?.takeIf { it in 0.0..1.0 }?.let { r.definirPosicao(it) }
        releTudo()
        // Uma tela recriada (idioma, negrito do sistema, a bancada com CLEAR_TOP) reencontra a
        // mesma réplica: o texto continua de onde estava, e não do topo — senão ela relataria 0
        // ao controle e o texto recomeçaria rolando do começo (achado da revisão de 13/09).
        b.vistaRoteiro.irPara(estado.posicao)
        entrarEmTelaCheia()
        iniciarSessao(r)
    }

    /**
     * Chamada logo depois de `setContentView`, antes de qualquer ligação: a tela R5 põe a vista do
     * roteiro dentro da divisão com a câmera. Aqui não faz nada.
     */
    protected open fun montarTela() = Unit

    /** O título desta tela (o `title` da janela): a R5 tem o dela. */
    protected open val tituloDaTela: Int get() = R.string.tp_prompter_titulo

    /**
     * Um recado passageiro ("controle conectado", "voltar de novo fecha"): uma faixa cinza entre os
     * avisos do alto, por 2 a 3,5 s — o iOS não tem `Toast`, e o `Toast` do Android sai sempre no pé
     * da tela, que de ponta-cabeça é a borda da lente. A R5 o põe na linha dos avisos da faixa dela.
     *
     * [grave]: um recado de falha (a gravação que não saiu), que a R5 pinta de laranja. Era decidido
     * pelo começo da frase ("Não gravou", "Não dá"), o que deixa de valer em inglês: quem chama diz.
     */
    protected open fun avisoCurto(mensagem: String, longo: Boolean, grave: Boolean = false) {
        recadoDaTela = mensagem
        recadoAte = SystemClock.elapsedRealtime() + if (longo) 3_500L else 2_000L
        avisosDesenhados = ""
        desenharAvisos(avisoMostrado.split("\n").filter { it.isNotEmpty() })
    }

    /**
     * A réplica pronta, antes de a tela lê-la pela primeira vez. No prompter comum: devolve o
     * espelho do texto que uma tela R5 desligou e não chegou a devolver (o processo morreu com ela
     * aberta, ou este prompter abriu antes de ela terminar de sair) — ver [EspelhoDaTelaComCamera].
     */
    protected open fun aoTerReplica(r: ReplicaDoTeleprompter) {
        EspelhoDaTelaComCamera.devolver(applicationContext, r, "o prompter comum abriu", soSemTelaAberta = false)
    }

    /** O estado da réplica acabou de ser aplicado na vista (daqui ou do controle). Aqui não faz nada. */
    protected open fun aoAplicarEstado(e: EstadoDoTeleprompter) = Unit

    /**
     * A sessão desta tela terminou de parar e a réplica ainda não foi solta. **Fora da thread
     * principal** e com a tela já destruída. [saindo] é falso numa recriação. Aqui não faz nada.
     */
    protected open fun aoEncerrarSessao(r: ReplicaDoTeleprompter, saindo: Boolean) = Unit

    /**
     * O bit de gravação chegou (§13 do contrato: um pedido do controle para gravar ou parar). Na
     * thread principal, com o estado já relido. Aqui não faz nada: só a tela com câmera grava.
     */
    protected open fun aoMudarGravacao(r: ReplicaDoTeleprompter, e: EstadoDoTeleprompter) = Unit

    /** A réplica desta tela, ou `null` (o núcleo não carregou). Para as subclasses. */
    protected val replicaDaTela: ReplicaDoTeleprompter? get() = replica

    // --- o que as telas no modelo do iOS leem e fazem (`docs/telas-android-como-ios.md`) ----------
    //
    // A tela R5 desenha a faixa do iOS (avisos, estado, barra de ícones) e a folha de Ajustes em vez
    // da barra de botões de texto daqui: lê o estado por estes nomes e age pelos mesmos caminhos dos
    // botões — uma edição daqui passa pela réplica e a tela relê, como a que chega do controle.

    /** A fase da sessão com o controle, ou `null` antes de ela começar. */
    protected val faseDaSessao: SessaoDoPrompter.Fase? get() = fase

    /** O último estado da réplica aplicado na vista. */
    protected val estadoDaTela: EstadoDoTeleprompter get() = estado

    /** Um controle já falou com esta tela (daí em diante, a queda é aviso). */
    protected val jaTeveControleNaTela: Boolean get() = jaTeveControle

    /** O toque no texto alterna a tela cheia: aqui somem a faixa do alto e a barra; na R5, o estado e a barra da faixa. */
    protected open fun aoTocarNoTexto() = mostrarControles(!controlesVisiveis)

    /** O gesto de voltar, antes da regra daqui (`true` = tratado). A R5 sai primeiro da tela cheia dela. */
    protected open fun aoVoltar(): Boolean = false

    /**
     * As guias verticais do enquadramento à mostra. Aqui, a regra do prompter do iOS: fora da tela
     * cheia, ou com a folha de Ajustes aberta; na R5, só com a folha (nada do lado da lente).
     */
    protected open fun guiasDoEnquadramento(): Boolean = controlesVisiveis || folhaDeAjustesAberta

    // --- a folha de Ajustes, das duas telas ----------------------------------------------------

    private var folhaDeAjustes: FolhaDeAjustesDoPrompter? = null

    protected val folhaDeAjustesAberta: Boolean get() = folhaDeAjustes?.aberta == true

    /** A seção da câmera na folha de Ajustes: só a R5 tem. */
    protected open fun ajustesDaCameraDaTela(): AjustesDaCamera? = null

    /** A folha de Ajustes (`FolhaDeAjustes` do iOS): "Voltar ao começo", orientação, fonte automática, enquadramento e o texto. */
    protected fun abrirAjustesDoPrompter() {
        if (folhaDeAjustesAberta || replica == null) return
        val f = FolhaDeAjustesDoPrompter(this, ajustesDoPrompter, ajustesDaCameraDaTela()) {
            reesconderBarras()
            atualizarAreaLivre()
        }
        folhaDeAjustes = f
        f.mostrar()
        atualizarAreaLivre()
    }

    /** O estado mudou fora do caminho da vista (a gravação trava a orientação): a folha acompanha. */
    protected fun atualizarFolhaDeAjustes() {
        folhaDeAjustes?.atualizar()
    }

    private val ajustesDoPrompter = object : AjustesDoPrompter {
        override fun estadoAgora() = estado
        override fun voltarAoComeco() = this@PrompterActivity.voltarAoComeco()
        override fun definirVelocidade(v: Double) = editarReplica { it.definirVelocidade(v.coerceIn(0.05, 20.0)) }
        override fun definirFonte(v: Double) = definirFonteAMao(v.coerceIn(8.0, 400.0))
        override fun definirMargem(v: Double) = editarReplica { it.definirMargem(v.coerceIn(0.0, 0.45)) }
        override fun definirLinhaDeLeitura(v: Double) = editarReplica { it.definirLinhaDeLeitura(v.coerceIn(0.0, 1.0)) }
        override fun definirEspelho(ligado: Boolean) = editarReplica { it.definirEspelho(ligado) }
        override fun orientacaoAgora(): Orientacao = orientacao
        override fun escolherOrientacao(o: Orientacao) = escolherOrientacaoLocal(o)
        override fun orientacaoTravada() = this@PrompterActivity.orientacaoTravada
        override fun fonteAutomaticaLigada() = fonteAutomatica
        override fun definirFonteAutomatica(ligada: Boolean) = aplicarFonteAutomatica(ligada)
        override fun larguraInteira() = enquadrarLarguraInteira()
    }

    /** Uma edição da réplica, e a tela relê (o caminho dos botões). */
    protected fun editarReplica(acao: (ReplicaDoTeleprompter) -> Int) {
        val r = replica ?: return
        val st = acao(r)
        if (st != QuallNative.Status.OK) Log.w(TAG, "prompter: edição recusada (${QuallNative.Status.nome(st)})")
        releTudo()
    }

    /** O play e a pausa: o que a pessoa via é o que ela pede (ver [SegurarParaRolar.rolarOuParar]). */
    protected fun alternarRolando() {
        val r = replica ?: return
        val agora = r.estado() ?: estado
        val v = SegurarParaRolar.rolarOuParar(querRolar = !rolandoNoRotulo, rolandoAgora = agora.rolando)
        if (v != null) editarReplica { it.definirRolando(v) } else {
            Log.i(TAG, "prompter: play/pausa sem efeito — o texto já está ${if (agora.rolando) "rolando" else "parado"}")
            releTudo()
        }
    }

    protected fun voltarAoComeco() {
        editarReplica { it.saltar(0.0) }
        b.vistaRoteiro.irPara(0.0)
    }

    /** A fonte à mão desliga a automática: senão a próxima conta desfaria o toque. */
    protected fun definirFonteAMao(sp: Double) {
        if (fonteAutomatica) desligarFonteAutomatica(getString(R.string.tp_fonte_automatica_desligada))
        editarReplica { it.definirFonte(sp) }
    }

    protected fun abrirEditor() {
        val r = replica ?: return
        mostrarBarrasDoSistema()
        editor.abrir(r.texto() ?: texto)
    }

    protected val orientacaoEscolhida: Orientacao get() = orientacao

    /** Escolher a orientação (a folha de Ajustes): aplica e guarda, como o botão. */
    protected fun escolherOrientacaoLocal(o: Orientacao) {
        if (orientacaoTravada) {
            avisoCurto(getString(R.string.tp_orientacao_travada), longo = false)
            return
        }
        aplicarOrientacao(o, guardar = true)
    }

    protected val fonteAutomaticaLigada: Boolean get() = fonteAutomatica

    protected fun ligarFonteAutomatica(ligar: Boolean) = aplicarFonteAutomatica(ligar)

    /** "Largura inteira": o enquadramento do formato de agora volta à coluna inteira, e fica guardado. */
    protected fun enquadrarLarguraInteira() {
        val formato = b.vistaRoteiro.formatoDoQuadro()
        val p = getSharedPreferences(PREFERENCIAS, MODE_PRIVATE)
        p.edit().putString(PREF_ENQUADRAMENTO + formato, Enquadramento.INTEIRO.guardado()).apply()
        fun guardado(f: String) =
            if (f == formato) Enquadramento.INTEIRO else Enquadramento.doGuardado(p.getString(PREF_ENQUADRAMENTO + f, null))
        b.vistaRoteiro.definirEnquadramentos(guardado(Enquadramento.RETRATO), guardado(Enquadramento.PAISAGEM))
        Log.i(TAG, "prompter: enquadramento de $formato de volta à largura inteira (guardado neste aparelho)")
    }

    /** Pede de novo a conta de onde as setas e as guias moram (a faixa mudou, a folha abriu ou fechou). */
    protected fun refazerAreaLivre() = atualizarAreaLivre()

    /** Uma folha ou um diálogo fechou: as barras do sistema voltam a sumir, se a tela é imersiva. */
    protected fun reesconderBarras() {
        if (telaCheia) esconderBarrasDoSistema()
    }

    /**
     * **A orientação travada** (a tela R5 gravando: um arquivo só, §5.2). Enquanto `true`, a tela não
     * gira — nem pelo sensor, nem pelo botão, nem pela bancada —; ao destravar, volta a orientação
     * escolhida.
     */
    protected var orientacaoTravada = false
        private set

    protected fun travarOrientacao(travar: Boolean) {
        if (travar == orientacaoTravada) return
        if (travar) {
            orientacaoTravada = true
            requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LOCKED
            Log.i(TAG, "prompter: orientação travada na de agora (${(telaDaAtividade?.rotation ?: 0) * 90}°) enquanto grava")
        } else {
            orientacaoTravada = false
            aplicarOrientacao(orientacao, guardar = false)
        }
    }

    /** `true` quando esta tela fechou na entrada porque a outra estava aberta. */
    protected var recusada = false
        private set

    override fun onStart() {
        super.onStart()
        if (recusada) return
        principal.post(tique)
        getSystemService(DisplayManager::class.java)?.registerDisplayListener(ouvinteDaTela, principal)
        atualizarGiroDoTexto()
    }

    /**
     * A bancada comanda **esta** tela sem recriá-la — a sessão com o controle fica de pé: a
     * orientação (que vale como escolher no botão), um roteiro, rolar ou parar, e a posição. Cada
     * um é o mesmo caminho do toque correspondente.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Orientacao.daChave(intent.getStringExtra(EXTRA_ORIENTACAO))?.let {
            aplicarOrientacao(it, guardar = intent.getBooleanExtra(EXTRA_GUARDAR_ORIENTACAO, true))
        }
        val r = replica ?: return
        lerAjustesLocaisDaBancada(intent)
        intent.getStringExtra(EXTRA_ROTEIRO)?.let { carregarRoteiroDaBancada(r, it) }
        if (intent.hasExtra(EXTRA_ROLAR)) r.definirRolando(intent.getBooleanExtra(EXTRA_ROLAR, false))
        releTudo()
        intent.getStringExtra(EXTRA_POSICAO)?.toDoubleOrNull()?.takeIf { it in 0.0..1.0 }?.let {
            r.definirPosicao(it)
            b.vistaRoteiro.irPara(it)
        }
        // A foto do momento, para as provas: o estado e onde a vista está de verdade.
        Log.i(TAG, "bancada: estado → ${linhaDeEstado(estado)}; a vista em ${"%.4f".format(Locale.ROOT, b.vistaRoteiro.posicao)}" +
            (if (b.vistaRoteiro.rolando) " rolando" + (if (b.vistaRoteiro.paraTras) " para trás" else "") else " parada"))
    }

    override fun onStop() {
        if (recusada) { super.onStop(); return }
        principal.removeCallbacks(tique)
        getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(ouvinteDaTela)
        // §3: salvar quando o app vai para o segundo plano. Fora da thread da tela (até ~260 KiB).
        replica?.let { r -> thread(name = "quall-prompter-salvar") { r.salvar() } }
        super.onStop()
    }

    override fun onDestroy() {
        if (aberta?.get() === this) aberta = null
        principal.removeCallbacksAndMessages(null)
        folhaDeAjustes?.fechar()
        folhaDoEndereco?.takeIf { it.isShowing }?.dismiss()
        val s = sessao
        val t = threadDaSessao
        val r = replica
        s?.parar()
        b.vistaRoteiro.rolando = false
        if (r != null) {
            // A sessão sai em até uma bombeada (100 ms) ou uma espera cancelada; a réplica só é
            // solta depois — e mesmo que o `join` estoure, a trava da réplica impede uso depois
            // de liberar.
            //
            // **Pelo `post`, e não já**: numa recriação, destruir a tela velha e criar a nova
            // rodam na mesma mensagem da thread principal. Postado, o `Replicas.obter` da tela
            // nova sempre vem antes deste `soltar` — e ela reencontra a mesma réplica, com o
            // `rolando` que não vai para o salvo.
            val saindo = !isChangingConfigurations
            principal.post {
                thread(name = "quall-prompter-fim") {
                    runCatching { t?.join(3_000) }
                    runCatching { aoEncerrarSessao(r, saindo) }
                        .onFailure { Log.w(TAG, "prompter: o fim da sessão falhou: ${Log.erroExterno(it.message)}") }
                    Replicas.soltar(r)
                }
            }
        }
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (recusada) return
        // O `configChanges` do manifesto segura a tela (e a sessão) numa rotação, no modo escuro
        // e no tamanho da letra do sistema; o sp muda de pixels com este último.
        b.vistaRoteiro.configuracaoMudou()
        if (telaCheia) esconderBarrasDoSistema()
        atualizarGiroDoTexto()
    }

    // --- a sessão --------------------------------------------------------------------------------

    private fun iniciarSessao(r: ReplicaDoTeleprompter) {
        val porta = intent?.getIntExtra(EXTRA_PORTA, 0)?.takeIf { it in 1..65535 } ?: EnderecoDoTeleprompter.PORTA_PADRAO
        val pin = intent?.getStringExtra(EXTRA_PIN)
        val anunciar = !(intent?.getBooleanExtra(EXTRA_SEM_MDNS, false) == true || Bancada.semMdns(this))
        val s = SessaoDoPrompter(eu, r, porta, pin, anunciar, ouvinte, textos)
        sessao = s
        threadDaSessao = thread(name = "quall-prompter") { s.rodar() }
    }

    private fun aplicarFase(f: SessaoDoPrompter.Fase) {
        fase = f
        when (f) {
            is SessaoDoPrompter.Fase.Esperando -> Unit
            is SessaoDoPrompter.Fase.ComControle -> {
                // `jaTeveControle` **não** liga aqui: liga na primeira mensagem do controle
                // (`atualizarAvisos`). Ligado já na entrada, o aviso "controle desconectado"
                // piscava na tela no instante em que o PRIMEIRO controle entrava, antes de ele
                // falar — medido no tablet em 13/09 (13 ms de aviso falso).
                avisoCurto(getString(if (f.pareamentoNovo) R.string.tp_controle_conectado_pareado else R.string.tp_controle_conectado_recado, f.par), longo = false)
            }
            is SessaoDoPrompter.Fase.Erro -> avisoCurto(f.mensagem, longo = true)
            SessaoDoPrompter.Fase.Parado -> Unit
        }
        desenharFaixaDeCima()
        atualizarEstadoEAvisos()
    }

    /** O PIN e o primeiro endereço da sessão agora (vazio e `null` sem sessão). */
    protected fun pinEEnderecoDaSessao(): Pair<String, String?> = when (val f = fase) {
        is SessaoDoPrompter.Fase.Esperando -> f.pin to f.enderecos.firstOrNull()
        is SessaoDoPrompter.Fase.ComControle -> f.pin to f.enderecos.firstOrNull()
        else -> "" to null
    }

    /**
     * **A faixa do alto** (`faixaDeCima` do iOS): a bolinha e o estado, "PIN 123 456" e o endereço (ou
     * "sem rede" em laranja), e o botão de letra grande. Ela fica à vista também depois do primeiro
     * controle — é o que um controle novo, ou o mesmo de volta de uma queda, precisa digitar.
     */
    private fun desenharFaixaDeCima() {
        val f = fase
        val sumido = Avisos.controleSumido(jaTeveControle, f is SessaoDoPrompter.Fase.ComControle, estado.parVistoHaMs)
        val (cor, texto) = when (f) {
            null, SessaoDoPrompter.Fase.Parado -> Cores.AMARELO to getString(R.string.tp_estado_parado)
            is SessaoDoPrompter.Fase.Esperando ->
                if (jaTeveControle) Cores.VERMELHO to getString(R.string.tp_controle_desconectado)
                else Cores.AMARELO to getString(R.string.tp_esperando_o_controle)
            is SessaoDoPrompter.Fase.ComControle -> when {
                sumido -> Cores.VERMELHO to getString(R.string.tp_controle_desconectado)
                f.par.isEmpty() -> Cores.VERDE to getString(R.string.tp_controle_conectado)
                else -> Cores.VERDE to getString(R.string.tp_controlado_por, f.par)
            }
            is SessaoDoPrompter.Fase.Erro -> Cores.LARANJA to f.mensagem
        }
        val (pin, endereco) = pinEEnderecoDaSessao()
        val chave = "$cor|$texto|$pin|$endereco"
        if (chave == faixaDesenhada) return
        faixaDesenhada = chave
        b.bolinhaPrompter.background = android.graphics.drawable.GradientDrawable().apply {
            shape = android.graphics.drawable.GradientDrawable.OVAL
            setColor(cor)
        }
        b.textEstadoPrompter.text = texto
        // "sem rede" só com a sessão de pé e sem endereço; parado ou em erro não há PIN nem endereço
        // a mostrar, e "sem rede" seria falso (a revisão do código, 28/09).
        val comSessao = f is SessaoDoPrompter.Fase.Esperando || f is SessaoDoPrompter.Fase.ComControle
        val vis = if (comSessao) View.VISIBLE else View.GONE
        b.textPinPrompter.visibility = vis
        b.textEnderecoPrompter.visibility = vis
        b.textPinPrompter.text = getString(R.string.tp_pin_rotulo, pinEspacado(pin))
        b.textPinPrompter.contentDescription = getString(R.string.tp_pin_rotulo, pin.toCharArray().joinToString(" "))
        b.textEnderecoPrompter.text = endereco ?: getString(R.string.tp_sem_rede)
        b.textEnderecoPrompter.setTextColor(if (endereco == null) Cores.LARANJA else Cores.BRANCO)
        b.buttonLetraGrandePrompter.visibility = if (endereco != null && pin.isNotEmpty()) View.VISIBLE else View.GONE
    }

    private var faixaDesenhada = ""

    /** Os bits do outro lado (§6), na thread principal. */
    private fun aplicarMudancas(bits: Int) {
        val r = replica ?: return
        if (bits == 0) return
        val e = r.estado() ?: return
        if (bits and MudouNoTeleprompter.TEXTO != 0) {
            texto = r.texto() ?: texto
            Log.i(TAG, "prompter: roteiro chegou do controle — ${texto.toByteArray(Charsets.UTF_8).size} bytes, resumo ${Resumo.de(texto)}")
            if (editor.aberto) editor.chegou(texto)
        }
        if (bits and MudouNoTeleprompter.SALTO != 0) {
            // §6: quem mostra o texto vai até "salto", relata com `set_position` e mantém `rolando`.
            e.salto?.let {
                b.vistaRoteiro.irPara(it)
                r.definirPosicao(it)
                Log.i(TAG, "prompter: salto para ${"%.4f".format(Locale.ROOT, it)}")
            }
        }
        val relevantes = bits and MudouNoTeleprompter.POSICAO.inv() and MudouNoTeleprompter.PAR.inv()
        if (relevantes != 0) {
            Log.i(TAG, "prompter: mudou pelo controle [${nomesDosBits(bits)}] → ${linhaDeEstado(e)}")
        }
        // Uma fonte que chega do controle desliga a automática (vale o último que mudou, §5).
        if (bits and MudouNoTeleprompter.FONTE != 0 && fonteAutomatica) {
            desligarFonteAutomatica(getString(R.string.tp_fonte_automatica_desligada_pelo_controle))
        }
        if (bits and MudouNoTeleprompter.GRAVACAO != 0) aoMudarGravacao(r, e)
        estado = e
        aplicarNaVista()
        atualizarAvisos(e)
    }

    // --- desenhar --------------------------------------------------------------------------------

    /** Relê o estado e o texto da réplica e aplica tudo (depois de uma edição daqui). */
    private fun releTudo() {
        val r = replica ?: return
        estado = r.estado() ?: estado
        texto = r.texto() ?: texto
        aplicarNaVista()
        atualizarAvisos(estado)
    }

    private fun aplicarNaVista() {
        val e = estado
        b.vistaRoteiro.aplicar(texto, e.fonte, e.margem, e.linhaDeLeitura, e.espelho)
        pedirFonteAutomatica() // o texto pode ter mudado (a coluna, a vista avisa sozinha)
        b.vistaRoteiro.velocidade = e.velocidade
        // "Segurar para rolar" (§12.5): com `rolando` e `para_tras`, para trás; os bits _SCROLLING e
        // _HOLD trazem os dois até aqui, e `rolando` caindo para tudo.
        b.vistaRoteiro.paraTras = e.paraTras
        b.vistaRoteiro.rolando = e.rolando
        rolandoNoRotulo = e.rolando
        if (::botaoPlayDaBarra.isInitialized) {
            botaoPlayDaBarra.trocar(if (e.rolando) R.drawable.ic_q_pausa else R.drawable.ic_q_play, getString(if (e.rolando) R.string.tp_pausar else R.string.tp_rolar))
        }
        desenharResumo()
        folhaDeAjustes?.atualizar()
        aoAplicarEstado(e)
    }

    /** A legenda acima da barra, como a do iOS: "1,00 linhas/s · 48 sp · 12 %" ("1.00 lines/s · 48 sp · 12%"). */
    private fun desenharResumo() {
        val e = estado
        b.textResumoPrompter.seMudou(getString(R.string.tp_resumo, e.velocidade, e.fonte, b.vistaRoteiro.posicao * 100))
    }

    private fun atualizarEstadoEAvisos() {
        val r = replica ?: return
        val e = r.estado() ?: return
        estado = e
        atualizarAvisos(e)
        desenharResumo()
        if (e.rolando) {
            val agora = SystemClock.elapsedRealtime()
            if (agora - ultimoPulsoNoRegistro >= PULSO_NO_REGISTRO_MS) {
                ultimoPulsoNoRegistro = agora
                Log.i(TAG, "prompter: rolando, posição ${"%.4f".format(Locale.ROOT, b.vistaRoteiro.posicao)} · " +
                    "controle ${if (fase is SessaoDoPrompter.Fase.ComControle) "conectado" else "ausente"} · " +
                    "aviso ${if (avisoMostrado.isEmpty()) "apagado" else "LIGADO"}")
            }
        }
    }

    private fun atualizarAvisos(e: EstadoDoTeleprompter) {
        val f = fase
        // "Já teve controle" = um controle **falou** com esta tela. Daí em diante, sessão caída
        // ou sessão nova ainda muda é aviso, até a primeira mensagem do controle de volta (§2).
        if (f is SessaoDoPrompter.Fase.ComControle && e.parVistoHaMs != null) jaTeveControle = true
        val (pin, endereco) = pinEEnderecoDaSessao()
        val linhas = Avisos.doPrompter(e, jaTeveControle, f is SessaoDoPrompter.Fase.ComControle, pin.ifEmpty { null }, endereco, textos)
        val novo = linhas.joinToString("\n")
        if (novo != avisoMostrado) {
            Log.i(TAG, if (novo.isEmpty()) "prompter: aviso apagado" else "prompter: aviso LIGADO — $novo")
            avisoMostrado = novo
        }
        desenharFaixaDeCima()
        desenharAvisos(linhas)
    }

    // --- os avisos em faixas (`AvisosDoTeleprompter` do iOS) ------------------------------------

    /** O motivo de a tela não funcionar (o núcleo, a réplica): fica até a tela fechar. */
    private var avisoPersistente: String? = null

    /** O recado passageiro ("Controle “X” conectado", "Voltar de novo fecha…") e até quando ele fica. */
    private var recadoDaTela: String? = null
    private var recadoAte = 0L
    private var avisosDesenhados = ""

    /**
     * Os avisos empilhados no alto, **também na tela cheia** (o do controle sumido é decisão do
     * usuário, §2): cada um uma faixa com ícone e cor — o do controle sumido em vermelho, os outros em
     * laranja, o recado em cinza.
     */
    private fun desenharAvisos(linhas: List<String>) {
        val agora = SystemClock.elapsedRealtime()
        if (recadoDaTela != null && agora > recadoAte) recadoDaTela = null
        val sumido = Avisos.controleSumido(jaTeveControle, fase is SessaoDoPrompter.Fase.ComControle, estado.parVistoHaMs)
        val lista = buildList {
            avisoPersistente?.let { add(Aviso(it, Cores.VERMELHO, R.drawable.ic_q_aviso)) }
            linhas.forEachIndexed { i, t ->
                val caiu = i == 0 && sumido
                add(Aviso(t, if (caiu) Cores.VERMELHO else Cores.LARANJA, if (caiu) R.drawable.ic_q_sem_rede else R.drawable.ic_q_aviso))
            }
            (fase as? SessaoDoPrompter.Fase.Esperando)?.ultimaRecusa?.let {
                add(Aviso(getString(R.string.tp_ultima_recusa, it), Cores.CINZA, R.drawable.ic_q_info))
            }
            recadoDaTela?.let { add(Aviso(it, Cores.CINZA, R.drawable.ic_q_info)) }
        }
        val chave = lista.joinToString("¦") { "${it.cor}|${it.texto}" }
        if (chave == avisosDesenhados) return
        avisosDesenhados = chave
        val pilha = b.avisosPrompter
        pilha.removeAllViews()
        for (a in lista) {
            pilha.addView(faixaDeAviso(this, a), android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(6) })
        }
    }

    // --- a barra de ícones (`barraDeBaixo` do iOS) --------------------------------------------------

    private lateinit var botaoPlayDaBarra: BotaoDeIcone

    /**
     * **A barra de ícones**, na ordem do iOS: Sair, Editar, Ajustes, (Voltar ao começo, em tablet),
     * tartaruga, play/pausa, coelho, (Espelho, em tablet), Tela cheia. A tartaruga e o coelho
     * **repetem enquanto pressionados** (pedido do Pessoa Exemplo, 27/09). O resto — fonte, margem, linha de
     * leitura, espelho no telefone, orientação, fonte automática — mora na folha de Ajustes.
     */
    private fun ligarBotoes(r: ReplicaDoTeleprompter) {
        val barra = b.barraPrompter
        val grande = resources.configuration.smallestScreenWidthDp >= 600
        fun por(v: View, peso: Float = 1f) = barra.addView(v, android.widget.LinearLayout.LayoutParams(0, dp(44), peso).apply {
            if (barra.childCount > 0) leftMargin = dp(4)
        })
        por(BotaoDeIcone(this, R.drawable.ic_q_fechar, getString(R.string.tp_sair)).apply { setOnClickListener { finish() } })
        por(BotaoDeIcone(this, R.drawable.ic_q_editar, getString(R.string.tp_editar)).apply { setOnClickListener { abrirEditor() } })
        por(BotaoDeIcone(this, R.drawable.ic_q_ajustes, getString(R.string.ajustes)).apply { setOnClickListener { abrirAjustesDoPrompter() } })
        if (grande) por(BotaoDeIcone(this, R.drawable.ic_q_inicio, getString(R.string.tp_voltar_ao_comeco)).apply { setOnClickListener { voltarAoComeco() } })
        por(BotaoDeIcone(this, R.drawable.ic_q_tartaruga, getString(R.string.tp_mais_devagar)).also { t ->
            repetirEnquantoPressionado(t) { editarReplica { it.definirVelocidade(Ajustes.velocidade(estado.velocidade, -1)) } }
        })
        // O que o botão mostra é o que ele manda: o que a pessoa via, contra o estado relido agora
        // (`alternarRolando`, ver `SegurarParaRolar.rolarOuParar`).
        botaoPlayDaBarra = BotaoDeIcone(this, R.drawable.ic_q_play, getString(R.string.tp_rolar)).apply {
            pintar(Cores.ACENTO)
            setOnClickListener { alternarRolando() }
        }
        por(botaoPlayDaBarra, 1.5f)
        por(BotaoDeIcone(this, R.drawable.ic_q_coelho, getString(R.string.tp_mais_depressa)).also { c ->
            repetirEnquantoPressionado(c) { editarReplica { it.definirVelocidade(Ajustes.velocidade(estado.velocidade, +1)) } }
        })
        if (grande) por(BotaoDeIcone(this, R.drawable.ic_q_espelho, getString(R.string.tp_espelho)).apply {
            setOnClickListener { editarReplica { it.definirEspelho(!estado.espelho) } }
        })
        por(BotaoDeIcone(this, R.drawable.ic_q_tela_cheia, getString(R.string.tela_cheia)).apply { setOnClickListener { mostrarControles(false) } })
        b.buttonLetraGrandePrompter.setOnClickListener {
            val (pin, endereco) = pinEEnderecoDaSessao()
            if (pin.isEmpty()) return@setOnClickListener
            folhaDoEndereco = mostrarFolhaDoEndereco(this, getString(R.string.tp_folha_controlar_titulo),
                getString(R.string.tp_folha_controlar_instrucao), endereco, pin) { reesconderBarras() }
        }
        Log.i(TAG, "prompter: barra de ícones com ${barra.childCount} botões${if (grande) " (tela grande)" else ""}" +
            " — velocidade ${"%.2f".format(Locale.ROOT, r.estado()?.velocidade ?: estado.velocidade)} linhas/s")
    }

    /** A folha do endereço aberta, para fechar com a tela (sem janela vazada). */
    private var folhaDoEndereco: com.google.android.material.bottomsheet.BottomSheetDialog? = null

    /**
     * Do 35 em diante a janela é de ponta a ponta obrigatoriamente, e a barra de tarefas do tablet
     * fica **por cima** — engoliu o toque no receptor (medido no SM-X230). O recuo vem do inset: o
     * alto recua pelo recorte da frontal e pela barra de estado, o pé pela barra de navegação.
     */
    private fun ligarRecuos() {
        ViewCompat.setOnApplyWindowInsetsListener(b.pePrompter) { v, insets ->
            val barras = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            v.setPadding(barras.left + dp(8), v.paddingTop, barras.right + dp(8), barras.bottom + dp(6))
            insets
        }
        ViewCompat.setOnApplyWindowInsetsListener(b.altoPrompter) { v, insets ->
            val barras = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            v.setPadding(barras.left + dp(12), barras.top + dp(4), barras.right + dp(12), v.paddingBottom)
            insets
        }
        ViewCompat.setOnApplyWindowInsetsListener(b.editorPrompter.root) { v, insets ->
            val barras = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            v.setPadding(barras.left + 32, barras.top + 32, barras.right + 32, barras.bottom + 32)
            insets
        }
    }

    // --- tela cheia ------------------------------------------------------------------------------
    //
    // Duas coisas diferentes, como no iOS: **a tela cheia do prompter** (somem a faixa do alto e a
    // barra; os avisos ficam) é o toque no texto e o botão; **as barras do sistema** ficam escondidas
    // o tempo todo (a tela é de leitura, imersiva) e só voltam com o editor aberto.

    /** Os controles (a faixa do alto e a barra) à mostra; `false` = a tela cheia do prompter. */
    protected var controlesVisiveis = true
        private set

    protected fun mostrarControles(mostrar: Boolean) {
        controlesVisiveis = mostrar
        val v = if (mostrar) View.VISIBLE else View.GONE
        b.faixaDeCimaPrompter.visibility = v
        b.pePrompter.visibility = v
        Log.i(TAG, "prompter: tela cheia ${if (mostrar) "saiu" else "entrou"}")
    }

    private fun entrarEmTelaCheia() {
        telaCheia = true
        esconderBarrasDoSistema()
    }

    private fun esconderBarrasDoSistema() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            WindowCompat.setDecorFitsSystemWindows(window, false)
        }
        WindowInsetsControllerCompat(window, b.root).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    private fun mostrarBarrasDoSistema() {
        WindowInsetsControllerCompat(window, b.root).show(WindowInsetsCompat.Type.systemBars())
    }

    // --- ajustes locais: "Enquadramento" e "Fonte automática" ---------------------------------------
    //
    // `docs/teleprompter-ajustes-locais.md` §2 e §5. Os dois são **deste aparelho**, como a
    // orientação: preferências da tela, fora do salvo do núcleo; o controle não os vê. O que sai para o
    // fio é só o efeito — a fonte que a automática escolhe vai por `definir_fonte`.

    private var fonteAutomatica = false
    private var escreverTabelaDaFonte = false
    private var ultimaChaveDaFonte: String? = null
    private val geracaoDaFonte = AtomicInteger(0)
    private val executorDaFonte = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "quall-fonte-automatica").apply { isDaemon = true }
    }

    private fun ligarAjustesLocais(r: ReplicaDoTeleprompter) {
        val p = getSharedPreferences(PREFERENCIAS, MODE_PRIVATE)
        b.vistaRoteiro.definirEnquadramentos(
            Enquadramento.doGuardado(p.getString(PREF_ENQUADRAMENTO + Enquadramento.RETRATO, null)),
            Enquadramento.doGuardado(p.getString(PREF_ENQUADRAMENTO + Enquadramento.PAISAGEM, null)),
        )
        b.vistaRoteiro.aoMoverEnquadramento = { formato, e, soltou ->
            if (soltou) {
                getSharedPreferences(PREFERENCIAS, MODE_PRIVATE).edit().putString(PREF_ENQUADRAMENTO + formato, e.guardado()).apply()
                Log.i(TAG, String.format(Locale.ROOT, "prompter: enquadramento de %s em %.4f–%.4f (coluna de %d px), guardado neste aparelho",
                    formato, e.esquerda, e.direita, b.vistaRoteiro.larguraDaColuna))
            }
        }
        b.vistaRoteiro.aoMudarColuna = { pedirFonteAutomatica() }
        // As setas azuis e as guias moram onde nada cobre: a cada passada de layout (o aviso aparece e
        // some, a barra também), a vista fica sabendo.
        b.root.viewTreeObserver.addOnGlobalLayoutListener { atualizarAreaLivre() }
        fonteAutomatica = p.getBoolean(PREF_FONTE_AUTOMATICA, false)
        if (fonteAutomatica) Log.i(TAG, "prompter: fonte automática ligada (a guardada neste aparelho)")
        lerAjustesLocaisDaBancada(intent)
    }

    /**
     * O que cobre a vista do roteiro agora: o aviso laranja e a barra de botões (e as barras do
     * sistema, se à mostra). No prompter comum o aviso fica no alto e a barra embaixo; na tela R5
     * os dois vão juntos para a borda longe da lente — em cima ou embaixo, e deitado só sobre o
     * painel da câmera. Por isso cada um conta pelo lado em que está, e só se passa sobre a vista.
     * As guias das bordas aparecem com a barra à mostra.
     */
    private fun atualizarAreaLivre() {
        val sistema = ViewCompat.getRootWindowInsets(b.root)?.getInsets(WindowInsetsCompat.Type.systemBars())
        // Tudo na coordenada da raiz, e só no fim na da vista: na tela R5 a vista do roteiro é uma
        // parte da tela (com a lente embaixo, a de baixo), e o aviso e a barra podem nem estar em
        // cima dela.
        val raiz = IntArray(2).also { b.root.getLocationInWindow(it) }
        val aqui = IntArray(2).also { b.vistaRoteiro.getLocationInWindow(it) }
        val desde = (aqui[1] - raiz[1]).toFloat()
        val h = b.vistaRoteiro.height.toFloat()
        val xVista = (aqui[0] - raiz[0]).toFloat()
        var topo = (sistema?.top ?: 0).toFloat()
        var baixo = (b.root.height - (sistema?.bottom ?: 0)).toFloat()
        val onde = IntArray(2)
        // O alto (a faixa do estado e os avisos) e o pé (a legenda e a barra). Na R5 os dois saem da
        // tela (não `isShown`), e nada cobre a vista.
        for (v in listOf(b.altoPrompter, b.pePrompter)) {
            if (!v.isShown || v.width <= 0 || v.height <= 0) continue
            v.getLocationInWindow(onde)
            val x = (onde[0] - raiz[0]).toFloat()
            val y = (onde[1] - raiz[1]).toFloat()
            if (x + v.width <= xVista || x >= xVista + b.vistaRoteiro.width) continue // ao lado, não por cima
            if (y + v.height / 2f < b.root.height / 2f) topo = maxOf(topo, y + v.height) else baixo = minOf(baixo, y)
        }
        val t = (topo - desde).coerceIn(0f, h)
        b.vistaRoteiro.definirAreaLivre(t, (baixo - desde).coerceIn(t, h), guias = guiasDoEnquadramento())
    }

    /** Bancada: a fonte automática (como o botão) e o pedido de escrever a tabela de linhas da próxima conta. */
    private fun lerAjustesLocaisDaBancada(i: Intent?) {
        if (i == null) return
        if (i.getBooleanExtra(EXTRA_TABELA_DA_FONTE, false)) {
            escreverTabelaDaFonte = true
            ultimaChaveDaFonte = null
            chavePedidaDaFonte = null
        }
        if (i.hasExtra(EXTRA_FONTE_AUTOMATICA)) aplicarFonteAutomatica(i.getBooleanExtra(EXTRA_FONTE_AUTOMATICA, false))
        else if (escreverTabelaDaFonte) pedirFonteAutomatica()
    }

    /** Liga ou desliga, e guarda neste aparelho. Ligar calcula já. */
    private fun aplicarFonteAutomatica(ligar: Boolean) {
        fonteAutomatica = ligar
        getSharedPreferences(PREFERENCIAS, MODE_PRIVATE).edit().putBoolean(PREF_FONTE_AUTOMATICA, ligar).apply()
        folhaDeAjustes?.atualizar()
        Log.i(TAG, "prompter: fonte automática ${if (ligar) "ligada" else "desligada"} (guardada neste aparelho)")
        if (ligar) {
            ultimaChaveDaFonte = null
            chavePedidaDaFonte = null
            pedirFonteAutomatica()
        } else {
            geracaoDaFonte.incrementAndGet() // uma conta em curso não vale mais
            principal.removeCallbacks(calcularFonte)
            chavePedidaDaFonte = null
        }
    }

    private fun desligarFonteAutomatica(aviso: String) {
        aplicarFonteAutomatica(false)
        Log.i(TAG, "prompter: $aviso")
        avisoCurto(aviso, longo = true)
    }

    /** O que a conta usa: o texto e a largura da coluna. `null` sem texto ou sem vista. */
    private fun chaveDaFonte(): String? {
        val t = texto
        val largura = b.vistaRoteiro.larguraDaColuna
        if (t.isEmpty() || largura <= 0) return null
        return "${t.length}:${t.hashCode()}:$largura"
    }

    /**
     * O texto ou a coluna podem ter mudado: a conta sai 300 ms depois do último pedido **que mudou
     * alguma coisa** (o arrasto de uma seta pede muitos). Um pedido com a mesma entrada não reinicia a
     * espera — medido no A07: com um controle editando a cada ~220 ms, a espera reiniciada a cada
     * edição nunca vencia, e a conta do roteiro novo não saía.
     */
    private fun pedirFonteAutomatica() {
        if (!fonteAutomatica) return
        val chave = chaveDaFonte() ?: return
        if (chave == ultimaChaveDaFonte || chave == chavePedidaDaFonte) return
        chavePedidaDaFonte = chave
        principal.removeCallbacks(calcularFonte)
        principal.postDelayed(calcularFonte, 300)
    }

    private var chavePedidaDaFonte: String? = null

    private val calcularFonte = Runnable {
        chavePedidaDaFonte = null
        val r = replica ?: return@Runnable
        val t = texto
        val largura = b.vistaRoteiro.larguraDaColuna
        if (!fonteAutomatica || t.isEmpty() || largura <= 0) return@Runnable
        val chave = "${t.length}:${t.hashCode()}:$largura"
        if (chave == ultimaChaveDaFonte) return@Runnable
        ultimaChaveDaFonte = chave
        val g = geracaoDaFonte.incrementAndGet()
        val tabela = escreverTabelaDaFonte
        val calculo = CalculoDaFonteAutomatica(resources.displayMetrics)
        executorDaFonte.execute {
            val res = calculo.calcular(t, largura)
            principal.post {
                if (g != geracaoDaFonte.get() || !fonteAutomatica) return@post
                Log.i(TAG, "prompter: fonte automática → ${res.sp} sp em ${res.ms} ms (${res.diagramas} diagramas, coluna de $largura px, " +
                    "${t.length} caracteres) — ${res.linhas} linhas: " +
                    res.porTipo.entries.sortedBy { it.key.ordinal }.joinToString(", ") { "${it.key.name.lowercase()} ${it.value}" } +
                    "; em ${res.sp + 1} sp quebrariam a regra: " +
                    res.quebrasNaSeguinte.joinToString(" ") { "[${it.first},${it.last + 1})" }.ifEmpty { "nenhuma (é o teto)" })
                if (res.sp.toDouble() != estado.fonte) {
                    val st = r.definirFonte(res.sp.toDouble())
                    if (st != QuallNative.Status.OK) Log.w(TAG, "prompter: a fonte automática foi recusada (${QuallNative.Status.nome(st)})")
                    else thread(name = "quall-prompter-salvar") { r.salvar() } // salva já, como a linha arrastada
                    releTudo()
                }
                if (tabela) {
                    escreverTabelaDaFonte = false
                    thread(name = "quall-tabela-da-fonte") {
                        val f = File(getExternalFilesDir(null), "fonte-automatica.tsv")
                        runCatching { f.writeText(res.tabela()) }
                            .onSuccess { Log.i(TAG, "bancada: tabela de linhas de ${res.sp} e ${res.sp + 1} sp em ${f.absolutePath}") }
                            .onFailure { Log.w(TAG, "bancada: não escrevi a tabela: ${Log.erroExterno(it.message)}") }
                    }
                }
            }
        }
    }

    // --- a linha de leitura arrastada -------------------------------------------------------------

    /** O valor que esperava o intervalo sai quando ele vence (o arrasto parou de mexer, mas não soltou). */
    private val enviarLinhaQueEspera = Runnable {
        val r = replica ?: return@Runnable
        limitadorDaLinha.vencer(SystemClock.uptimeMillis())?.let { enviarLinha(r, it) }
    }

    /**
     * O arrasto das setas ([VistaDoRoteiro]): a vista já desenha a linha no dedo; aqui vai para a
     * réplica — `definir_linha_de_leitura`, campo sincronizado, que o controle vê. No máximo um
     * envio a cada [INTERVALO_DA_LINHA_MS]; ao soltar, o valor final sai na hora.
     */
    private fun moverLinhaDeLeitura(r: ReplicaDoTeleprompter, v: Double, soltou: Boolean) {
        val agora = SystemClock.uptimeMillis()
        if (arrastoDaLinhaDesde == 0L) arrastoDaLinhaDesde = agora
        principal.removeCallbacks(enviarLinhaQueEspera)
        if (soltou) {
            limitadorDaLinha.soltar(v, agora)?.let { enviarLinha(r, it) }
            // Salva já, como o roteiro confirmado: um processo morto antes do `onStop` (a reinstalação
            // no A10s do usuário, 14/09) voltava com a linha de antes do arrasto.
            thread(name = "quall-prompter-salvar") { r.salvar() }
            Log.i(TAG, String.format(Locale.ROOT, "prompter: linha de leitura arrastada para %.4f — %d envio(s) em %d ms",
                v, enviosDaLinha, agora - arrastoDaLinhaDesde))
            enviosDaLinha = 0
            arrastoDaLinhaDesde = 0L
            atualizarEstadoEAvisos()
            return
        }
        limitadorDaLinha.oferecer(v, agora)?.let { enviarLinha(r, it) }
        limitadorDaLinha.quandoSai()?.let { principal.postAtTime(enviarLinhaQueEspera, it) }
    }

    private fun enviarLinha(r: ReplicaDoTeleprompter, v: Double) {
        enviosDaLinha++
        val st = r.definirLinhaDeLeitura(v)
        if (st != QuallNative.Status.OK) Log.w(TAG, "prompter: linha de leitura recusada (${QuallNative.Status.nome(st)})")
    }

    // --- orientação ------------------------------------------------------------------------------

    private fun orientacaoGuardada(): Orientacao =
        Orientacao.doGuardado(getSharedPreferences(PREFERENCIAS, MODE_PRIVATE).getString(PREF_ORIENTACAO, null))

    /**
     * Trava a janela na orientação escolhida por `requestedOrientation`, que independe do sensor —
     * o aparelho deitado no suporte, com a tela para cima, obedece. A tela **não** é recriada (o
     * `configChanges` do manifesto): a sessão com o controle fica, e o texto é diagramado de novo na
     * largura nova ([VistaDoRoteiro]). `guardar`: vale também na próxima vez que o prompter abrir.
     */
    private fun aplicarOrientacao(o: Orientacao, guardar: Boolean) {
        if (orientacaoTravada) {
            Log.i(TAG, "prompter: orientação ${o.nome} recusada — travada enquanto grava")
            avisoCurto(getString(R.string.tp_orientacao_travada), longo = false)
            return
        }
        orientacao = o
        requestedOrientation = o.valorDoAndroid
        // Se o sistema não obedecer (tela grande no Android 16), o texto gira sozinho: conferido
        // quando a tela girar, e de qualquer jeito daqui a pouco — recusa não avisa.
        principal.removeCallbacks(verificarGiro)
        principal.postDelayed(verificarGiro, ESPERA_PELA_ROTACAO_MS)
        folhaDeAjustes?.atualizar()
        if (guardar) {
            getSharedPreferences(PREFERENCIAS, MODE_PRIVATE).edit().putString(PREF_ORIENTACAO, o.chave).apply()
        }
        Log.i(TAG, "prompter: orientação ${o.nome} (requestedOrientation=${o.valorDoAndroid}${if (guardar) ", guardada neste aparelho" else ""})")
    }

    private val verificarGiro = Runnable { atualizarGiroDoTexto() }

    /** Qualquer mudança da tela — inclusive o giro de 180°, que não muda a configuração e não chama `onConfigurationChanged`. */
    private val ouvinteDaTela = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) = Unit
        override fun onDisplayRemoved(id: Int) = Unit
        override fun onDisplayChanged(id: Int) {
            if (id == telaDaAtividade?.displayId) atualizarGiroDoTexto()
        }
    }

    /**
     * **Girar só o texto quando o sistema recusa** ([GiroDoTexto]): compara a rotação em que a tela
     * está com a que a orientação pedida daria, e a vista do roteiro gira o texto a diferença. No
     * telefone a trava vale e isto dá zero; na tela grande do Android 16, que ignora o pedido, o
     * texto chega sozinho à orientação escolhida — e a acompanha se o aparelho girar.
     */
    private fun atualizarGiroDoTexto() {
        if (!::b.isInitialized) return
        val rotacao = telaDaAtividade?.rotation ?: return
        val q = GiroDoTexto.quartos(orientacao, rotacao, naturalEmPaisagem(rotacao))
        if (q == b.vistaRoteiro.quartosDeGiro) return
        Log.i(TAG, "prompter: a tela está em ${rotacao * 90}° e a orientação pedida é ${orientacao.nome} — " +
            if (q == 0) "o texto volta a seguir a tela" else "o sistema não obedeceu, o texto gira ${q * 90}° dentro da vista")
        b.vistaRoteiro.quartosDeGiro = q
    }

    /** A orientação natural do aparelho: o tamanho da tela inteira, desfeito da rotação atual. */
    private fun naturalEmPaisagem(rotacao: Int): Boolean {
        val r = limitesMaximosDaJanela()
        val deitadaAgora = r.width() > r.height()
        return if (rotacao == Surface.ROTATION_0 || rotacao == Surface.ROTATION_180) deitadaAgora else !deitadaAgora
    }

    // --- bancada ---------------------------------------------------------------------------------

    /**
     * Um roteiro de arquivo, para a bancada não depender do teclado: o arquivo vai por
     * `adb push` para `/sdcard/Android/data/com.quall.android/files/` (o contêiner externo do app,
     * que ele lê sem permissão nenhuma) e o nome vem no `am start`. Só nome, nunca caminho.
     */
    private fun carregarRoteiroDaBancada(r: ReplicaDoTeleprompter, nome: String) {
        val base = getExternalFilesDir(null) ?: return
        val f = File(base, File(nome).name)
        val t = runCatching { f.readText(Charsets.UTF_8) }.getOrElse {
            Log.w(TAG, "bancada: não li o roteiro ${f.absolutePath}: ${Log.erroExterno(it.message)}")
            return
        }
        val st = r.definirTexto(t)
        if (st == QuallNative.Status.OK) thread(name = "quall-bancada-salvar") { r.salvar() }
        Log.i(TAG, "bancada: roteiro de ${f.name} — ${t.toByteArray(Charsets.UTF_8).size} bytes, resumo ${Resumo.de(t)}, " +
            "set_text=${QuallNative.Status.nome(st)}")
    }
}

/** Os nomes dos bits, para o registro. */
internal fun nomesDosBits(bits: Int): String = buildList {
    if (bits and MudouNoTeleprompter.TEXTO != 0) add("texto")
    if (bits and MudouNoTeleprompter.ROLANDO != 0) add("rolando")
    if (bits and MudouNoTeleprompter.VELOCIDADE != 0) add("velocidade")
    if (bits and MudouNoTeleprompter.FONTE != 0) add("fonte")
    if (bits and MudouNoTeleprompter.MARGEM != 0) add("margem")
    if (bits and MudouNoTeleprompter.LINHA_DE_LEITURA != 0) add("linha")
    if (bits and MudouNoTeleprompter.ESPELHO != 0) add("espelho")
    if (bits and MudouNoTeleprompter.POSICAO != 0) add("posição") // i18n-fora: nomes dos bits para o diário
    if (bits and MudouNoTeleprompter.SALTO != 0) add("salto")
    if (bits and MudouNoTeleprompter.PAR != 0) add("par")
    if (bits and MudouNoTeleprompter.SEGURAR != 0) add("segurar")
    if (bits and MudouNoTeleprompter.PERGUNTA_DO_TEXTO != 0) add("pergunta")
    if (bits and MudouNoTeleprompter.COPIA_DO_TEXTO != 0) add("cópia") // i18n-fora: nomes dos bits para o diário
    if (bits and MudouNoTeleprompter.GRAVACAO != 0) add("gravação") // i18n-fora: nomes dos bits para o diário
}.joinToString(",")

/** O estado numa linha, para o registro (a bancada lê isto pelo `logcat`). */
internal fun linhaDeEstado(e: EstadoDoTeleprompter): String = String.format(
    Locale.ROOT,
    "rolando=%s vel=%.2f fonte=%.1f margem=%.4f linha=%.4f espelho=%s pos=%.4f salto=%s texto=%d B " +
        "par_visto=%s sem_conf=%s para_tras=%s segurando=%s par_entende_segurar=%s pergunta=%s cópias=%d", // i18n-fora: linha de estado do diário (a bancada lê)
    e.rolando, e.velocidade, e.fonte, e.margem, e.linhaDeLeitura, e.espelho, e.posicao,
    e.salto?.let { String.format(Locale.ROOT, "%.4f", it) } ?: "nenhum", e.textoBytes,
    e.parVistoHaMs?.toString() ?: "null", e.semConfirmacaoHaMs?.toString() ?: "null",
    e.paraTras, e.segurando, e.parEntendeSegurar,
    e.perguntaDoTexto?.let { if (it.aberta) "aberta" else "comparando" } ?: "nenhuma", e.copiasDoTexto.size,
)
