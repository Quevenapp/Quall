package com.quall.android.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.hardware.camera2.CameraCharacteristics
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import com.quall.android.core.LogSeguro as Log
import android.util.TypedValue
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.button.MaterialButton
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.capture.CameraEnumerator
import com.quall.android.capture.PreviaDoDono
import com.quall.android.core.QuallNative
import com.quall.android.mirror.GravacaoDaTelaBus
import com.quall.android.mirror.MicrofoneBus
import com.quall.android.mirror.MirrorBus
import com.quall.android.mirror.MirrorService
import com.quall.android.teleprompter.Avisos
import com.quall.android.teleprompter.DecisaoDaGravacao
import com.quall.android.teleprompter.Divisao
import com.quall.android.teleprompter.EstadoDoTeleprompter
import com.quall.android.teleprompter.Orientacao
import com.quall.android.teleprompter.ReplicaDoTeleprompter
import com.quall.android.teleprompter.SessaoDoPrompter
import java.util.Locale
import java.util.UUID

/**
 * **"Teleprompter com câmera"** (R5, `docs/teleprompter-com-camera.md`) no Android: o prompter de
 * sempre — a mesma réplica, a mesma sessão na 7979, o mesmo controle remoto — com a câmera frontal ao
 * lado, colada à lente, e transmitindo pela rede.
 *
 * ## O layout é o do iOS (pedido do Pessoa Exemplo, 28/09)
 *
 * `docs/telas-android-como-ios.md` §1: **texto | prévia | faixa** ([Divisao.comFaixa], [DivisaoDaTela]) — o
 * texto em cima, empilhado, também deitado (o pedido de 30/09; embaixo só de ponta-cabeça, e a faixa ao
 * lado da prévia quando a tela é larga e baixa, o celular deitado) —, e a faixa na ordem do iOS
 * (`FaixaDaTelaComCamera`):
 *
 * 1. **a linha dos avisos** ([LinhaDosAvisos]): o mais grave numa linha, "+N", o toque abre todos e
 *    eles se recolhem em 10 s. Os recados passageiros ("Controle conectado", "Voltar de novo fecha o
 *    teleprompter.") também vêm aqui, e não num `Toast`: desde o Android 11 o `Toast` sai no pé, que
 *    de ponta-cabeça é a borda da lente (a revisão de 24/09);
 * 2. **o estado numa linha**: o chip do Texto e o da Câmera (o toque abre o endereço e o PIN em letra
 *    grande), o microfone compacto e o Gravar;
 * 3. **a barra de ícones**: Sair, Editar, Ajustes, tartaruga (repete), play/pausa, coelho (repete),
 *    esconder a prévia — e a tela cheia, em tela grande (`smallestScreenWidthDp ≥ 600`).
 *
 * Um toque no texto alterna a **tela cheia da faixa** (somem o estado e a barra; os avisos ficam). O
 * resto dos ajustes do texto mora na folha de Ajustes ([FolhaDeAjustesDoPrompter]).
 *
 * ## Duas sessões, independentes (§3)
 *
 * - **O prompter** é o de [PrompterActivity], herdado inteiro.
 * - **O vídeo** é o [MirrorService] com a fonte [MirrorService.SOURCE_PROMPTER_CAMERA]: a câmera abre
 *   **uma vez**, com esta tela, e a sessão de vídeo se pendura nela quando o receptor pareia.
 *
 * ## A prévia
 *
 * Uma `SurfaceView` que o divisor GL do serviço desenha. Esconder é `visibility` da superfície **e** do
 * painel (a revisão, M3): a superfície morre, o divisor deixa de desenhar nela, e a câmera e a
 * transmissão seguem (§2.5, G2). Por cima dela, "Aguarde… abrindo a câmera" até o primeiro quadro
 * ([MirrorService.cameraEntregando]), e o que impede a câmera, com "Abrir os Ajustes" quando serve.
 *
 * ## Gravar (fase 3)
 *
 * O botão na linha de estado, e o controle remoto pelo pedido do contrato (§13): quem grava é o serviço
 * ([com.quall.android.mirror.GravacaoDaTela]). A tela diz ao núcleo que grava quando o arquivo **de
 * fato** começou ou fechou ([GravacaoDaTelaBus]), responde ao pedido do controle ([DecisaoDaGravacao])
 * ou o recusa com o motivo, e **trava a orientação** enquanto grava (§5.2).
 */
class PrompterComCameraActivity : PrompterActivity() {

    companion object {
        private const val TAG = "QuallR5"

        /** Bancada: mostrar (`true`) ou esconder (`false`) a prévia — o mesmo que o botão. */
        const val EXTRA_PREVIA = "previa"

        /** Bancada: a prévia como espelho — o mesmo que o ajuste (aplica e guarda). */
        const val EXTRA_ESPELHO_DA_PREVIA = "espelho_da_previa"

        /** Bancada: ligar (`true`) ou desligar (`false`) o microfone — o mesmo caminho do botão. */
        const val EXTRA_MICROFONE = "microfone"

        /** Bancada: gravar (`true`) ou parar (`false`) — o mesmo caminho do botão Gravar. */
        const val EXTRA_GRAVAR = "gravar"

        /**
         * Bancada: o "Lado do texto" ([Divisao.Escolha.chave]: `automatico`, `cima`, `baixo`,
         * `esquerda`, `direita`) — o mesmo que o ajuste (aplica e guarda). Para os retratos da R5
         * deitada não dependerem de uma escolha que ficou no aparelho (30/09).
         */
        const val EXTRA_LADO_DO_TEXTO = "lado_do_texto"

        private const val PREFERENCIAS = "quall-prompter-r5"
        private const val PREF_ESPELHO_DA_PREVIA = "espelho_da_previa"
        /** Até 28/09, um booleano ("texto do lado oposto"); lido uma vez e apagado (ver [lerLado]). */
        private const val PREF_TEXTO_OPOSTO_ANTIGO = "texto_oposto"
        private const val PREF_LADO = "lado_do_texto"
        /** + [Divisao.formato]: retrato | empilhada-larga (desde 30/09) | paisagem. */
        private const val PREF_FRACAO = "fracao_"

        private const val STATUS_MS = 500L

        /** A janela do "voltar de novo fecha" (fora da tela cheia). */
        private const val JANELA_DO_VOLTAR_MS = 3_000L

        /** A câmera entregou quadro há menos que isto: a prévia não está mais "abrindo". */
        private const val ENTREGANDO_MS = 1_000L

    }

    /** O marcador desta tela para o serviço (ver [MirrorService.EXTRA_DONO_DA_TELA]). */
    private val marcador = UUID.randomUUID().toString()

    private lateinit var divisao: DivisaoDaTela
    private lateinit var superficie: SurfaceView
    private lateinit var camadaAguarde: View
    private lateinit var camadaProblema: LinearLayout
    private lateinit var textoDoProblema: TextView
    private lateinit var botaoDoProblema: MaterialButton
    private lateinit var iconeDoProblema: ImageView

    /** O cartão do problema na forma compacta (a prévia com menos de 200 dp; ver [compactarProblema]). */
    private var problemaCompacto: Boolean? = null

    // A faixa: avisos, estado, barra.
    private lateinit var faixa: LinearLayout
    private lateinit var avisos: LinhaDosAvisos
    private lateinit var linhaDeEstado: LinearLayout
    private lateinit var chipDoTexto: ChipDeSessao
    private lateinit var chipDaCamera: ChipDeSessao
    private lateinit var microfone: BotaoDoMicrofoneDaTela
    private lateinit var gravar: BotaoDeGravar
    private lateinit var barra: LinearLayout
    private lateinit var botaoPlay: BotaoDeIcone
    private lateinit var botaoPrevia: BotaoDeIcone

    private val principal = Handler(Looper.getMainLooper())

    private var espelhoDaPrevia = true
    private var escolhaDoLado = Divisao.Escolha.AUTOMATICO
    private var videoPedido = false
    private var telaCheiaDaFaixa = false
    private var ultimoVoltarMs = 0L

    /** O que impede a câmera de abrir (a permissão, sem frontal, o serviço que não subiu). */
    private var problemaDaCamera: String? = null
    private var problemaAbreAjustes = false

    /** O recado passageiro e até quando ele fica. */
    private var recado: Aviso? = null
    private var recadoAte = 0L

    /** O aviso de uma vez só da migração do lado do texto (ver [lerLado]). */
    private var avisoDoLado: String? = null

    /** A folha do endereço aberta, para fechar com a tela (sem janela vazada). */
    private var folhaDoEndereco: com.google.android.material.bottomsheet.BottomSheetDialog? = null

    /** A falha que o serviço guardava quando esta tela pediu o vídeo (de outra sessão), e quando. */
    private var falhaDoPedido: String? = null
    private var falhaAntigaSumiu = false
    private var pedidoDoVideoEm = 0L

    /** A última vez que a superfície da prévia foi entregue de novo ao divisor ([reafirmarPrevia]). */
    private var previaReafirmadaEm = 0L

    /**
     * A câmera entrega ao divisor, mas a prévia não desenha: entrega a superfície de novo, no máximo
     * a cada 1,5 s. Cobre uma entrega que se perdeu entre a tela e o dono (a superfície que nasceu
     * antes de o dono existir, ou que mudou de tamanho no meio) — a linha diz, para o diário.
     */
    private fun reafirmarPrevia(agora: Long) {
        if (agora - previaReafirmadaEm < 1_500) return
        val h = superficie.holder
        val s = h.surface ?: return
        if (!s.isValid) return
        previaReafirmadaEm = agora
        Log.i(TAG, "r5: a câmera entrega e a prévia não desenha — a superfície vai de novo ao divisor")
        PreviaDoDono.ligar(s, this, daTelaR5 = true)
    }

    /** O problema na prévia veio da câmera que não abriu no serviço (e some quando ela abrir). */
    private var problemaDaFalha = false

    /** O botão do microfone da câmera: a permissão no primeiro toque, e o motivo quando negada. */
    private val botaoDoMicrofone = BotaoDoMicrofone(this)

    /** O pedido de bancada pendente (`--ez microfone`); tirado no `onDestroy`. */
    private var microfoneDaBancadaLigar = false
    private val microfoneDaBancada = Runnable { if (!isDestroyed) botaoDoMicrofone.aplicar(microfoneDaBancadaLigar) }

    // --- a gravação (fase 3) ---------------------------------------------------------------------

    /** O que a réplica já ouviu de nós: o arquivo gravando (`true`) ou não. */
    private var gravandoDito = false

    /** A última recusa do serviço já respondida (o número só cresce; ver [GravacaoDaTelaBus]). */
    private var recusaVista = 0L

    /** A última mensagem de parada já mostrada (para mostrar cada uma uma vez). */
    private var paradaVista = ""

    /** O pedido do controle para o qual já se pediu começar ou parar ao serviço: não se pede duas vezes. */
    private var pedidoEncaminhado: Long? = null

    private var faseVista = GravacaoDaTelaBus.Fase.PARADA

    /**
     * **Este aparelho não grava** (§14.3, caso 1), calculado pela própria tela ao abrir: o serviço só
     * põe o motivo no [GravacaoDaTelaBus] depois, e a réplica já teria dito ao controle que grava (a
     * revisão, 13a). Com o serviço de pé, vale o do Bus.
     */
    private var indisponivelDaTela: String? = null
    private var indisponivelCalculado = false

    /** O que a réplica diz ao controle: esta tela grava (`enable_recording`). */
    private var gravacaoLigadaNaReplica = false

    private fun indisponivel(e: GravacaoDaTelaBus.Estado = GravacaoDaTelaBus.atual): String? =
        if (e.disponivel && !e.daCameraComum && e.indisponivelConferido) e.indisponivel else indisponivelDaTela

    /** Já se sabe se o aparelho grava: a conta da tela, ou a do serviço, voltou. */
    private fun indisponivelSabido(e: GravacaoDaTelaBus.Estado = GravacaoDaTelaBus.atual): Boolean =
        indisponivelCalculado || (e.disponivel && !e.daCameraComum && e.indisponivelConferido)

    private val pedirCamera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) iniciarVideo() else semPermissaoDeCamera()
    }

    private val lerStatus = object : Runnable {
        override fun run() {
            desenharFaixa()
            principal.postDelayed(this, STATUS_MS)
        }
    }

    private val ouvinteDaTela = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) = Unit
        override fun onDisplayRemoved(id: Int) = Unit
        override fun onDisplayChanged(id: Int) {
            if (id == telaDaAtividade?.displayId) aplicarLado()
        }
    }

    private val callbackDaSuperficie = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
            Log.i(TAG, "r5: a superfície da prévia nasceu")
            PreviaDoDono.ligar(holder.surface, this@PrompterComCameraActivity, daTelaR5 = true)
        }

        override fun surfaceChanged(holder: SurfaceHolder, formato: Int, largura: Int, altura: Int) {
            Log.i(TAG, "r5: a prévia mede ${largura}x$altura")
            // A borda arrastada ou a faixa que cresce mudam o tamanho: o divisor recebe a superfície de
            // novo (o tamanho da janela EGL acompanha).
            PreviaDoDono.ligar(holder.surface, this@PrompterComCameraActivity, daTelaR5 = true)
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            // Antes de voltar daqui a superfície ainda vale: o divisor para de desenhar nela já.
            PreviaDoDono.soltar(this@PrompterComCameraActivity)
            Log.i(TAG, "r5: a superfície da prévia morreu (escondida ou fora da tela) — a câmera segue aberta")
        }
    }

    // --- a tela ----------------------------------------------------------------------------------

    /** O título da janela (o que o TalkBack anuncia e a recusa de "um prompter por aparelho" cita). */
    override val tituloDaTela: Int get() = R.string.r5_titulo

    override fun montarTela() {
        // **A conta do gravador, fora da principal e antes da réplica** (a D1, §14.3; a revisão de
        // 28/09, M2): `montarTela` roda no começo do `super.onCreate`, antes de `aoTerReplica`.
        val app = applicationContext
        Thread({
            val m = com.quall.android.mirror.GravacaoIndisponivel.motivo(app)
            principal.post {
                if (isDestroyed || indisponivelCalculado) return@post
                indisponivelDaTela = m
                indisponivelCalculado = true
                m?.let { Log.i(TAG, "r5: APP GRAVACAO indisponível: $it") }
                acompanharGravacaoNaReplica(GravacaoDaTelaBus.atual)
                desenharFaixa()
            }
        }, "quall-gravacao-indisponivel").start()
        val p = getSharedPreferences(PREFERENCIAS, MODE_PRIVATE)
        espelhoDaPrevia = p.getBoolean(PREF_ESPELHO_DA_PREVIA, true)
        escolhaDoLado = lerLado()

        val painel = montarPainelDaPrevia()
        montarFaixa()

        // A vista do roteiro sai da raiz e entra na divisão. O aviso, a espera e a barra de botões de
        // texto do prompter comum saem da tela: a faixa do iOS os substitui (a classe base continua
        // escrevendo neles, sem efeito na tela).
        val vista = b.vistaRoteiro
        val raiz = b.root
        val indice = raiz.indexOfChild(vista)
        for (v in listOf(vista, b.altoPrompter, b.pePrompter)) raiz.removeView(v)
        divisao = DivisaoDaTela(this, vista, painel, faixa)
        raiz.addView(divisao, indice, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        montarPainelDaCamera(raiz, vista)
        // A borda de cada formato (em pé, deitado empilhado, lado a lado), lida quando ele muda.
        divisao.fracaoGuardada = { formato ->
            getSharedPreferences(PREFERENCIAS, MODE_PRIVATE).getFloat(PREF_FRACAO + formato, Divisao.PADRAO.toFloat()).toDouble()
        }
        divisao.aoArrastar = { f, soltou ->
            if (soltou) {
                val formato = divisao.formato
                getSharedPreferences(PREFERENCIAS, MODE_PRIVATE).edit().putFloat(PREF_FRACAO + formato, f.toFloat()).apply()
                Log.i(TAG, String.format(Locale.ROOT, "r5: borda em %.3f do texto (%s), guardada neste aparelho", f, formato))
            }
        }
        aplicarLado()
    }

    /**
     * O lado do texto guardado. Até 28/09 era um booleano ("lado oposto"), que não tem par exato nas
     * cinco opções do iOS ("oposto" era relativo à lente): quem o tinha ligado volta ao automático, e
     * a faixa diz isso uma vez, para a pessoa escolher em Ajustes.
     */
    private fun lerLado(): Divisao.Escolha {
        val p = getSharedPreferences(PREFERENCIAS, MODE_PRIVATE)
        if (p.contains(PREF_TEXTO_OPOSTO_ANTIGO)) {
            val oposto = runCatching { p.getBoolean(PREF_TEXTO_OPOSTO_ANTIGO, false) }.getOrDefault(false)
            p.edit().remove(PREF_TEXTO_OPOSTO_ANTIGO).apply()
            if (oposto) {
                avisoDoLado = getString(R.string.r5_lado_voltou)
                Log.i(TAG, "r5: o ajuste antigo \"texto do lado oposto\" saiu; o texto volta ao automático")
            }
        }
        return Divisao.Escolha.daChave(p.getString(PREF_LADO, null)) ?: Divisao.Escolha.AUTOMATICO
    }

    private fun montarPainelDaPrevia(): FrameLayout {
        superficie = SurfaceView(this)
        superficie.holder.addCallback(callbackDaSuperficie)
        // O toque na prévia (R9, §4.4): só nela, nunca no texto, e nunca com a prévia escondida ou com o
        // "Aguarde…" / o problema por cima.
        val gestos = GestosDaPrevia(this, daTelaR5 = true,
            ondeEsta = {
                superficie.takeIf {
                    it.visibility == View.VISIBLE && !divisao.previaEscondida &&
                        camadaAguarde.visibility != View.VISIBLE && camadaProblema.visibility != View.VISIBLE
                }
            },
            marcas = { marcasDoToque })
        superficie.setOnTouchListener { _, e ->
            gestos.observar(e)
            true
        }
        // "Aguarde… abrindo a câmera" (§8.12.10 do iOS): a tela aparece na hora, e a câmera abre no serviço.
        camadaAguarde = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(16), 0, dp(16), 0)
            addView(spinnerBranco(context), LinearLayout.LayoutParams(dp(32), dp(32)))
            // A frase centrada embaixo do círculo (o tablet de 30/09: sem isto ela saía encostada à
            // esquerda — a vista filha de um LinearLayout vertical nasce com a largura toda, e o texto
            // dela começa no início). A camada é do tamanho da moldura da prévia, onde quer que ela esteja.
            addView(TextView(context).apply {
                text = getString(R.string.r5_aguarde)
                setTextColor(Cores.BRANCO)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                gravity = Gravity.CENTER
                textAlignment = View.TEXT_ALIGNMENT_CENTER
                setPadding(0, dp(10), 0, 0)
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            contentDescription = getString(R.string.r5_aguarde)
        }
        textoDoProblema = TextView(this).apply {
            setTextColor(Cores.BRANCO)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, dp(10))
        }
        botaoDoProblema = MaterialButton(this, null, com.google.android.material.R.attr.borderlessButtonStyle).apply {
            text = getString(R.string.r5_abrir_ajustes)
            isAllCaps = false
            setTextColor(Cores.ACENTO_CLARO)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setOnClickListener { abrirAjustesDoApp() }
        }
        iconeDoProblema = ImageView(this).apply {
            setImageResource(R.drawable.ic_q_video_cortado)
            imageTintList = ColorStateList.valueOf(Cores.BRANCO)
        }
        camadaProblema = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(24), dp(24), dp(24))
            addView(iconeDoProblema, LinearLayout.LayoutParams(dp(32), dp(32)))
            addView(textoDoProblema)
            addView(botaoDoProblema)
            visibility = View.GONE
        }
        // A prévia baixa (deitado, o A07 tem 384 dp de altura: a prévia fica com 150 a 190 dp) cortava o
        // botão "Abrir os Ajustes" do cartão da câmera negada, como no iOS (30/09): abaixo de 200 dp, o
        // cartão fica compacto antes de medir.
        return object : FrameLayout(this) {
            override fun onMeasure(larguraSpec: Int, alturaSpec: Int) {
                compactarProblema(MeasureSpec.getSize(alturaSpec) < dp(200))
                super.onMeasure(larguraSpec, alturaSpec)
            }
        }.apply {
            setBackgroundColor(0xFF000000.toInt())
            addView(superficie, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(camadaAguarde, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(camadaProblema, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            // O quadrado do toque e a pílula da trava (R9, §4.4), por cima da prévia.
            marcasDoToque = MarcasDoToque(context).apply {
                fonteDaPilula = { MarcasDoToque.pilulaDaCamera(context, daTelaR5 = true) }
            }
            addView(marcasDoToque, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
    }

    /**
     * **O cartão do problema compacto** (a prévia com menos de 200 dp, a mesma regra do iOS de 30/09): sem
     * o ícone, com recuos de 8 dp, o texto em 13 e o botão sem as folgas do Material — o "Abrir os
     * Ajustes" cabe inteiro. Só muda quando a forma muda (é chamado de dentro da medida).
     */
    private fun compactarProblema(compacto: Boolean) {
        if (problemaCompacto == compacto || !::camadaProblema.isInitialized) return
        problemaCompacto = compacto
        val recuo = dp(if (compacto) 8 else 24)
        camadaProblema.setPadding(recuo, recuo, recuo, recuo)
        iconeDoProblema.visibility = if (compacto) View.GONE else View.VISIBLE
        textoDoProblema.setTextSize(TypedValue.COMPLEX_UNIT_SP, if (compacto) 13f else 15f)
        textoDoProblema.setPadding(0, dp(if (compacto) 2 else 10), 0, dp(if (compacto) 2 else 10))
        botaoDoProblema.setTextSize(TypedValue.COMPLEX_UNIT_SP, if (compacto) 14f else 16f)
        botaoDoProblema.minHeight = dp(if (compacto) 36 else 48)
        botaoDoProblema.minimumHeight = dp(if (compacto) 36 else 48)
        botaoDoProblema.insetTop = if (compacto) 0 else dp(6)
        botaoDoProblema.insetBottom = if (compacto) 0 else dp(6)
    }

    // --- os ajustes da câmera (R9) ---------------------------------------------------------------

    private lateinit var painelDaCamera: PainelDaCamera
    private lateinit var botaoAjustesDaCamera: BotaoDeIcone
    private var marcasDoToque: MarcasDoToque? = null

    /**
     * **O painel "Ajustes da câmera" na R5** (§4.2): por cima da **metade do texto**, e não da prévia — ali
     * a prévia já ocupa a outra metade, em pé e deitada; enquanto se ajusta a câmera, o texto não é o
     * assunto. Um filho da raiz, com o retângulo da vista do roteiro, refeito a cada layout da divisão.
     */
    private fun montarPainelDaCamera(raiz: ViewGroup, vista: View) {
        painelDaCamera = PainelDaCamera(this, daTelaR5 = true) { abrirPainelDaCamera(false) }
        // A metade do texto pode ser mais baixa que o painel (o A10s: ~310 dp em pé, ~206 deitado, contra os
        // [PainelDaCamera.ALTURA_MAXIMA_DP]). Aqui vence a prévia, que não é coberta, e o painel rola **por
        // dentro**: as abas e o "Pronto" ficam fixos no alto, e só o corpo rola (`PainelDaCamera`).
        rolagemDoPainel = FrameLayout(this).apply {
            visibility = View.GONE
            addView(painelDaCamera, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        raiz.addView(rolagemDoPainel, FrameLayout.LayoutParams(0, 0))
        divisao.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> posicionarPainelDaCamera(vista) }
        // As barras que aparecem ou somem sem a divisão mudar de forma também mudam a área útil.
        androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(rolagemDoPainel) { _, insets ->
            principal.post { posicionarPainelDaCamera(vista) }
            insets
        }
        vistaDoPainel = vista
    }

    /** A vista do roteiro, de onde sai o retângulo do painel. */
    private var vistaDoPainel: View? = null

    /** O contêiner do painel na raiz, com o retângulo da vista do roteiro. */
    private lateinit var rolagemDoPainel: FrameLayout

    private fun posicionarPainelDaCamera(vista: View) {
        val lp = rolagemDoPainel.layoutParams as FrameLayout.LayoutParams
        val raiz = rolagemDoPainel.parent as? View ?: return
        // A vista do texto vai de ponta a ponta, por baixo das barras: o painel fica no pedaço dela que está
        // na área útil (`RetanguloDoPainel`; o "Pronto" ia para debaixo da barra de navegação no A10s deitado).
        val ins = androidx.core.view.ViewCompat.getRootWindowInsets(raiz)?.getInsets(
            androidx.core.view.WindowInsetsCompat.Type.systemBars() or androidx.core.view.WindowInsetsCompat.Type.displayCutout())
        val l0 = divisao.left + vista.left
        val t0 = divisao.top + vista.top
        val r = RetanguloDoPainel.daR5(
            RetanguloDoPainel.Ret(l0, t0, l0 + vista.width, t0 + vista.height), raiz.width, raiz.height,
            RetanguloDoPainel.Recuos(ins?.left ?: 0, ins?.top ?: 0, ins?.right ?: 0, ins?.bottom ?: 0))
        if (lp.leftMargin == r.esquerda && lp.topMargin == r.topo && lp.width == r.largura && lp.height == r.altura) return
        lp.leftMargin = r.esquerda
        lp.topMargin = r.topo
        lp.width = r.largura
        lp.height = r.altura
        // Fora do layout em curso: pedir layout de dentro de um `onLayoutChange` é ignorado.
        principal.post { rolagemDoPainel.layoutParams = lp }
    }

    private fun abrirPainelDaCamera(abrir: Boolean) {
        vistaDoPainel?.let { posicionarPainelDaCamera(it) }
        rolagemDoPainel.visibility = if (abrir) View.VISIBLE else View.GONE
        botaoAjustesDaCamera.pintar(if (abrir) Cores.ACENTO_FUNDO else Cores.FUNDO_DO_BOTAO)
        Log.i(TAG, "r9: painel dos ajustes da câmera ${if (abrir) "aberto" else "fechado"} (R5)")
    }

    /** A faixa do iOS: avisos, estado e barra, com fundo preto e 6 dp entre as linhas. */
    private fun montarFaixa() {
        faixa = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF000000.toInt())
            // A faixa pega os toques que caem nos vãos dela: nada passa para a prévia ou para a borda.
            // Não é um botão: fora do leitor de tela (os filhos continuam nele).
            isClickable = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            // Clicável vira focável: fora do modo de toque, o realce padrão velava a faixa inteira.
            defaultFocusHighlightEnabled = false
        }
        avisos = LinhaDosAvisos(this)
        // Com peso: numa banda mais baixa que a faixa (deitado num celular, a borda no teto, ou a lista de
        // avisos aberta), quem encolhe é a linha dos avisos, e o estado e a barra ficam inteiros (a revisão
        // do ramo, 30/09: a faixa natural tem 176 dp, e a banda no teto do A07 deitado, 150).
        faixa.addView(avisos, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        linhaDeEstado = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(8), 0)
        }
        chipDoTexto = ChipDeSessao(this, getString(R.string.r5_chip_texto)).apply { setOnClickListener { abrirEnderecoDoTexto() } }
        chipDaCamera = ChipDeSessao(this, getString(R.string.r5_chip_camera)).apply { setOnClickListener { abrirEnderecoDaCamera() } }
        microfone = BotaoDoMicrofoneDaTela(this, compacto = true).apply { setOnClickListener { botaoDoMicrofone.alternar() } }
        gravar = BotaoDeGravar(this, compacto = true).apply {
            setOnClickListener { alternarGravacao() }
            // "Tentar mesmo assim" (a D1, §14.3): o toque longo no Gravar apagado esquece as falhas guardadas.
            setOnLongClickListener { tentarGravarMesmoAssim() }
        }
        fun lp(peso: Float) = LinearLayout.LayoutParams(if (peso > 0) 0 else ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT, peso).apply { rightMargin = dp(6) }
        linhaDeEstado.addView(chipDoTexto, lp(1f))
        linhaDeEstado.addView(chipDaCamera, lp(1f))
        linhaDeEstado.addView(microfone, lp(0f))
        linhaDeEstado.addView(gravar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        faixa.addView(linhaDeEstado, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(6)
        })

        barra = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = fundoArredondado(Cores.FUNDO_DA_BARRA, dp(14).toFloat())
            setPadding(dp(6), dp(6), dp(6), dp(6))
        }
        fun naBarra(v: View, peso: Float = 1f) = barra.addView(v, LinearLayout.LayoutParams(0, dp(44), peso).apply {
            if (barra.childCount > 0) leftMargin = dp(4)
        })
        naBarra(BotaoDeIcone(this, R.drawable.ic_q_fechar, getString(R.string.tp_sair)).apply { setOnClickListener { finish() } })
        naBarra(BotaoDeIcone(this, R.drawable.ic_q_editar, getString(R.string.tp_editar)).apply { setOnClickListener { abrirEditor() } })
        naBarra(BotaoDeIcone(this, R.drawable.ic_q_ajustes, getString(R.string.ajustes)).apply { setOnClickListener { abrirAjustesDoPrompter() } })
        // "Ajustes da câmera" (R9, `docs/controles-de-camera.md` §4.1), ao lado do "Ajustes" do texto: a
        // engrenagem, para não repetir o `ic_q_ajustes` do lado (a decisão do Pessoa Exemplo de 01/10).
        // O rótulo em português ("Ajustes da câmera") é o que `tools/prova-r9-controles.py` procura.
        botaoAjustesDaCamera = BotaoDeIcone(this, R.drawable.ic_q_engrenagem, getString(R.string.r5_ajustes_da_camera)).apply {
            setOnClickListener { abrirPainelDaCamera(rolagemDoPainel.visibility != View.VISIBLE) }
        }
        naBarra(botaoAjustesDaCamera)
        naBarra(BotaoDeIcone(this, R.drawable.ic_q_tartaruga, getString(R.string.tp_mais_devagar)).also { t ->
            repetirEnquantoPressionado(t) { mudarVelocidade(-1) }
        })
        botaoPlay = BotaoDeIcone(this, R.drawable.ic_q_play, getString(R.string.tp_rolar)).apply {
            pintar(Cores.ACENTO)
            setOnClickListener { alternarRolando() }
        }
        naBarra(botaoPlay, 1.5f)
        naBarra(BotaoDeIcone(this, R.drawable.ic_q_coelho, getString(R.string.tp_mais_depressa)).also { c ->
            repetirEnquantoPressionado(c) { mudarVelocidade(+1) }
        })
        botaoPrevia = BotaoDeIcone(this, R.drawable.ic_q_video, getString(R.string.r5_esconder_previa)).apply {
            setOnClickListener { mostrarCamera(divisao.previaEscondida) }
        }
        naBarra(botaoPrevia)
        if (resources.configuration.smallestScreenWidthDp >= 600) {
            naBarra(BotaoDeIcone(this, R.drawable.ic_q_tela_cheia, getString(R.string.tela_cheia)).apply { setOnClickListener { alternarTelaCheia() } })
        }
        faixa.addView(barra, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(6)
            leftMargin = dp(8)
            rightMargin = dp(8)
        })
        avisos.aoMudar = { faixa.requestLayout() }
        aplicarPaddingDaFaixa()
    }

    /** `.padding(.vertical, lista.isEmpty && telaCheia ? 0 : 6)` do iOS. */
    private fun aplicarPaddingDaFaixa() {
        val vazia = telaCheiaDaFaixa && avisos.visibility != View.VISIBLE
        val v = if (vazia) 0 else dp(6)
        if (faixa.paddingTop != v || faixa.paddingBottom != v) faixa.setPadding(0, v, 0, v)
    }

    /**
     * O espelho do texto (o do vidro) nasce **desligado** nesta tela (§2.5): aqui se lê a tela
     * direto, não por um vidro. O controle remoto pode ligá-lo. A réplica é a mesma do prompter
     * comum (o salvo do papel `teleprompter`), então o valor de antes **volta** quando esta tela
     * sai, se ninguém o tiver ligado aqui (a prova de 24/09 no S24; o iOS já fazia assim) — ver
     * [EspelhoDaTelaComCamera]. Sem chamar a base: ela devolveria o espelho que esta tela deve.
     */
    override fun aoTerReplica(r: ReplicaDoTeleprompter) {
        EspelhoDaTelaComCamera.desligarAoAbrir(applicationContext, r)
        // Esta tela grava (§13.5): o controle passa a ver o botão Gravar — **só se o aparelho grava**
        // (§14.3): no que não grava, o controle não mostra o botão. A conta (o `MediaCodecList`, o
        // pacote, as preferências) roda numa thread que `montarTela` já lançou; a réplica chega quase
        // sempre antes dela (é o `super.onCreate`), e a conta na principal travava a abertura no A10s
        // (a revisão de 28/09, M2). Até ela chegar, a réplica não diz que grava; quando chega,
        // `acompanharGravacaoNaReplica` liga.
        if (!indisponivelSabido()) {
            gravacaoLigadaNaReplica = false
            Log.i(TAG, "r5: a réplica espera a conta do gravador antes de dizer que grava " +
                "(enable_recording: ${QuallNative.Status.nome(r.ligarGravacao(false))})")
            return
        }
        val motivo = indisponivel()
        if (motivo == null) {
            gravacaoLigadaNaReplica = true
            Log.i(TAG, "r5: a réplica diz que grava (enable_recording: ${QuallNative.Status.nome(r.ligarGravacao(true))})")
        } else {
            gravacaoLigadaNaReplica = false
            Log.i(TAG, "r5: a réplica NÃO diz que grava (enable_recording desligado): $motivo " +
                "(${QuallNative.Status.nome(r.ligarGravacao(false))})")
        }
    }

    /** O motivo mudou (uma falha ao abrir, ou o "tentar mesmo assim"): a réplica acompanha. */
    private fun acompanharGravacaoNaReplica(e: GravacaoDaTelaBus.Estado) {
        val r = replicaDaTela ?: return
        // Antes de alguma conta voltar, a réplica espera (não diz que grava à toa).
        if (!indisponivelSabido(e)) return
        val grava = indisponivel(e) == null
        if (grava == gravacaoLigadaNaReplica) return
        gravacaoLigadaNaReplica = grava
        Log.i(TAG, "r5: a réplica ${if (grava) "volta a dizer" else "deixa de dizer"} que grava " +
            "(enable_recording: ${QuallNative.Status.nome(r.ligarGravacao(grava))})" + (indisponivel(e)?.let { ": $it" } ?: ""))
    }

    /** O bit de gravação: um pedido do controle chegou. Decide pelo mais novo (§13.2). */
    override fun aoMudarGravacao(r: ReplicaDoTeleprompter, e: EstadoDoTeleprompter) {
        decidirPedido(r, e)
    }

    /** Ligado aqui (pelo botão ou pelo controle): a escolha é de quem ligou, e não se devolve mais. */
    override fun aoAplicarEstado(e: EstadoDoTeleprompter) {
        if (e.espelho) EspelhoDaTelaComCamera.esquecer(applicationContext, "o espelho do texto foi ligado nesta tela")
        if (::botaoPlay.isInitialized) {
            botaoPlay.trocar(if (e.rolando) R.drawable.ic_q_pausa else R.drawable.ic_q_play, getString(if (e.rolando) R.string.tp_pausar else R.string.tp_rolar))
        }
    }

    /**
     * A sessão já parou (o controle não vê a volta) e a réplica ainda não foi solta — o `fechar`
     * dela grava o salvo com o espelho devolvido. Só se nenhuma tela de prompter abriu enquanto
     * esta saía: se abriu, ela decide (o comum devolve ao abrir; uma R5 nova continua devendo).
     */
    override fun aoEncerrarSessao(r: ReplicaDoTeleprompter, saindo: Boolean) {
        if (saindo) {
            // A tela que fecha recusa o pedido aberto (§13.3) e deixa de dizer que grava; a gravação
            // em si fecha no serviço, com a câmera. **Só se nenhuma tela de prompter abriu** nesse
            // meio (a revisão, médio 3): a R5 nova que o serviço já adotou grava na mesma réplica, e a
            // velha, depois do `join` de 3 s, desligaria a gravação dela.
            if (!PrompterActivity.algumaAberta) {
                r.definirGravando(false)
                r.ligarGravacao(false)
            }
            EspelhoDaTelaComCamera.devolver(applicationContext, r, "a tela com câmera fechou", soSemTelaAberta = true, gravarJa = true) // i18n-fora: motivo do diário
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (recusada) return
        // Os recuos: só as barras do sistema, se aparecerem (a tela é imersiva; aparecem num gesto da
        // borda) — **não o recorte da frontal**: o texto começa colado à lente, como no iOS (a
        // conferência de 28/09 no A07 viu ~120 px pretos em cima). A classe base punha nos botões de
        // texto, que saíram da tela.
        ViewCompat.setOnApplyWindowInsetsListener(b.altoPrompter, null)
        ViewCompat.setOnApplyWindowInsetsListener(b.pePrompter, null)
        ViewCompat.setOnApplyWindowInsetsListener(divisao) { v, insets ->
            val r = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            if (v.paddingLeft != r.left || v.paddingTop != r.top || v.paddingRight != r.right || v.paddingBottom != r.bottom) {
                v.setPadding(r.left, r.top, r.right, r.bottom)
            }
            insets
        }
        ViewCompat.requestApplyInsets(b.root)
        recusaVista = GravacaoDaTelaBus.atual.numeroDaRecusa
        paradaVista = GravacaoDaTelaBus.atual.mensagem
        GravacaoDaTelaBus.ouvir(this) { e -> aoMudarAGravacaoNoServico(e) }
        if (!QuallNative.carregado) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            iniciarVideo()
        } else {
            // Pedir, e não só ler (`docs/regras-de-frente.md`): é o pedido que cria a linha no painel.
            pedirCamera.launch(Manifest.permission.CAMERA)
        }
        intent?.let { lerBancada(it) }
    }

    override fun onStart() {
        super.onStart()
        if (recusada) return
        principal.post(lerStatus)
        getSystemService(DisplayManager::class.java)?.registerDisplayListener(ouvinteDaTela, principal)
        aplicarLado()
    }

    override fun onResume() {
        super.onResume()
        // A pessoa foi aos Ajustes e voltou com a câmera permitida: abre agora.
        if (!recusada && !videoPedido && problemaAbreAjustes && QuallNative.carregado &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        ) {
            Log.i(TAG, "r5: a permissão de câmera chegou pelos Ajustes — abrindo a câmera")
            iniciarVideo()
        }
    }

    override fun onStop() {
        if (!recusada) {
            principal.removeCallbacks(lerStatus)
            getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(ouvinteDaTela)
        }
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        lerBancada(intent)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (!recusada) aplicarLado()
    }

    override fun onDestroy() {
        principal.removeCallbacks(lerStatus)
        principal.removeCallbacks(microfoneDaBancada)
        GravacaoDaTelaBus.ouvir(this, null)
        folhaDoEndereco?.takeIf { it.isShowing }?.dismiss()
        if (!recusada) {
            PreviaDoDono.soltar(this)
            // A tela é dona do vídeo: fechando, a câmera fecha junto. Com o marcador, um fechamento
            // atrasado desta tela não derruba a de uma tela nova que o serviço já adotou.
            // Direto ao serviço, sem `Intent`: ver `MirrorService.pedirParada`.
            if (videoPedido && !isChangingConfigurations) MirrorService.pedirParada(marcador)
        }
        super.onDestroy()
    }

    // --- o toque, o voltar e a tela cheia ---------------------------------------------------------

    /** O toque no texto alterna a tela cheia da faixa, como no iOS. */
    override fun aoTocarNoTexto() = alternarTelaCheia()

    /**
     * **O voltar nunca fecha de primeira** (a regra do prompter): na tela cheia, o primeiro devolve a
     * faixa; fora dela, o primeiro diz "Voltar de novo fecha o teleprompter." e só o segundo, em até
     * 3 s, fecha — um voltar sem querer na borda, no meio da leitura, não derruba o texto e a câmera.
     */
    override fun aoVoltar(): Boolean {
        val agora = SystemClock.elapsedRealtime()
        when {
            telaCheiaDaFaixa -> {
                alternarTelaCheia()
                avisoCurto(getString(R.string.tp_voltar_de_novo_fecha), longo = false)
                ultimoVoltarMs = agora
            }
            agora - ultimoVoltarMs <= JANELA_DO_VOLTAR_MS -> finish()
            else -> {
                avisoCurto(getString(R.string.tp_voltar_de_novo_fecha), longo = false)
                ultimoVoltarMs = agora
            }
        }
        return true
    }

    private fun alternarTelaCheia() {
        telaCheiaDaFaixa = !telaCheiaDaFaixa
        val v = if (telaCheiaDaFaixa) View.GONE else View.VISIBLE
        linhaDeEstado.visibility = v
        barra.visibility = v
        aplicarPaddingDaFaixa()
        divisao.bordaPermitida = !telaCheiaDaFaixa && problemaDaCamera == null
        Log.i(TAG, "r5: tela cheia ${if (telaCheiaDaFaixa) "entrou" else "saiu"}")
        desenharFaixa()
    }

    /** Guias do enquadramento só com a folha de Ajustes aberta (24/09: nada do lado da lente). */
    override fun guiasDoEnquadramento(): Boolean = folhaDeAjustesAberta

    /** A seção da câmera na folha de Ajustes (`SecaoDaTelaComCamera` do iOS). */
    override fun ajustesDaCameraDaTela(): AjustesDaCamera = ajustesDaCamera

    /**
     * Um recado passageiro ("Controle “X” conectado", "Voltar de novo fecha o teleprompter."): na
     * linha dos avisos, e não num `Toast` — desde o Android 11 o `Toast` de texto sai sempre no pé
     * da tela, que de ponta-cabeça é a borda da lente (a revisão de 24/09).
     */
    override fun avisoCurto(mensagem: String, longo: Boolean, grave: Boolean) {
        if (!::avisos.isInitialized) return super.avisoCurto(mensagem, longo, grave)
        Log.i(TAG, "r5: recado na faixa — $mensagem")
        // O laranja vem de quem chama ([grave]), e não do começo da frase, que muda com o idioma.
        recado = Aviso(mensagem, if (grave) Cores.LARANJA else Cores.CINZA, if (grave) R.drawable.ic_q_aviso else R.drawable.ic_q_info)
        recadoAte = SystemClock.elapsedRealtime() + if (longo) 3_500L else 2_000L
        desenharFaixa()
    }

    // --- as folhas --------------------------------------------------------------------------------

    private fun abrirEnderecoDoTexto() {
        val (pin, endereco) = pinEEnderecoDoTexto()
        if (pin.isEmpty()) {
            avisoCurto(getString(R.string.tp_teleprompter_abrindo), longo = false)
            return
        }
        folhaDoEndereco = mostrarFolhaDoEndereco(this, getString(R.string.tp_folha_controlar_titulo),
            getString(R.string.tp_folha_controlar_instrucao), endereco, pin) { reesconderBarras() }
    }

    private fun abrirEnderecoDaCamera() {
        val e = MirrorBus.atual
        // Só com a sessão da câmera desta tela no ar: o `MirrorBus` guarda o PIN de uma sessão anterior.
        val noAr = videoPedido && (e.fase == MirrorBus.Fase.ESPERANDO || e.fase == MirrorBus.Fase.ESPELHANDO)
        if (!noAr || e.pin.isEmpty()) {
            avisoCurto(getString(R.string.r5_camera_nao_esperando), longo = false)
            return
        }
        folhaDoEndereco = mostrarFolhaDoEndereco(this, getString(R.string.r5_folha_camera_titulo),
            getString(R.string.r5_folha_camera_instrucao), e.enderecos.firstOrNull(), e.pin) { reesconderBarras() }
    }

    private fun pinEEnderecoDoTexto(): Pair<String, String?> = pinEEnderecoDaSessao()

    /** A tartaruga e o coelho: o mesmo passo do prompter comum e do iOS (±0,1 linha/s, [Ajustes.velocidade]). */
    private fun mudarVelocidade(sentido: Int) {
        editarReplica { it.definirVelocidade(com.quall.android.teleprompter.Ajustes.velocidade(estadoDaTela.velocidade, sentido)) }
    }

    private val ajustesDaCamera = object : AjustesDaCamera {
        override fun previaEspelhada() = espelhoDaPrevia
        override fun espelharPrevia(ligado: Boolean) = aplicarEspelhoDaPrevia(ligado)
        override fun ladoDoTexto() = escolhaDoLado
        override fun escolherLado(e: Divisao.Escolha) {
            escolhaDoLado = e
            getSharedPreferences(PREFERENCIAS, MODE_PRIVATE).edit().putString(PREF_LADO, e.chave).apply()
            avisoDoLado = null
            Log.i(TAG, "r5: lado do texto ${e.chave} (guardado neste aparelho)")
            aplicarLado()
        }
    }

    // --- o vídeo -----------------------------------------------------------------------------------

    private fun iniciarVideo() {
        val frontal = CameraEnumerator.listar(this).firstOrNull { it.lensFacing == CameraCharacteristics.LENS_FACING_FRONT }
        if (frontal == null) {
            mostrarProblema(getString(R.string.r5_sem_frontal), abreAjustes = false)
            return
        }
        val i = Intent(this, MirrorService::class.java)
            .putExtra(MirrorService.EXTRA_SOURCE_KIND, MirrorService.SOURCE_PROMPTER_CAMERA)
            .putExtra(MirrorService.EXTRA_CAMERA_ID, frontal.id)
            .putExtra(MirrorService.EXTRA_CAMERA_LABEL, frontal.label)
            .putExtra(MirrorService.EXTRA_DONO_DA_TELA, marcador)
        runCatching { ContextCompat.startForegroundService(this, i) }
            .onSuccess {
                falhaDoPedido = MirrorService.falhaDaCamera()
                falhaAntigaSumiu = falhaDoPedido == null
                pedidoDoVideoEm = SystemClock.elapsedRealtime()
                videoPedido = true
                mostrarProblema(null, abreAjustes = false)
                Log.i(TAG, "r5: vídeo pedido ao serviço com a câmera ${frontal.id} (${frontal.label})")
            }
            .onFailure {
                Log.e(TAG, "r5: o serviço de vídeo não subiu", it)
                mostrarProblema(getString(R.string.r5_video_nao_subiu, it.message.orEmpty()), abreAjustes = false)
            }
    }

    /**
     * Sem a permissão de câmera, a prévia diz por quê (o texto continua), e oferece os Ajustes do app:
     * no Android eles sempre resolvem — negada uma vez, ou "não perguntar de novo".
     */
    private fun semPermissaoDeCamera() {
        val bloqueada = !ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.CAMERA)
        Log.i(TAG, "r5: sem permissão de câmera (bloqueada: $bloqueada)")
        mostrarProblema(getString(R.string.r5_sem_permissao), abreAjustes = true)
    }

    private fun mostrarProblema(texto: String?, abreAjustes: Boolean, daFalha: Boolean = false) {
        problemaDaCamera = texto
        problemaDaFalha = texto != null && daFalha
        problemaAbreAjustes = texto != null && abreAjustes
        if (!::camadaProblema.isInitialized) return
        camadaProblema.visibility = if (texto == null) View.GONE else View.VISIBLE
        textoDoProblema.text = texto.orEmpty()
        botaoDoProblema.visibility = if (problemaAbreAjustes) View.VISIBLE else View.GONE
        divisao.bordaPermitida = !telaCheiaDaFaixa && texto == null
        desenharFaixa()
    }

    private fun abrirAjustesDoApp() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
        })
    }

    // --- os ajustes locais -------------------------------------------------------------------------

    /** Esconder ou mostrar a prévia: a `SurfaceView` também, e não só o painel (a revisão, M3). */
    private fun mostrarCamera(visivel: Boolean) {
        if (divisao.previaEscondida == !visivel) return
        superficie.visibility = if (visivel) View.VISIBLE else View.GONE
        divisao.previaEscondida = !visivel
        Log.i(TAG, "r5: prévia ${if (visivel) "à mostra" else "escondida (a câmera e a transmissão seguem)"}")
        botaoPrevia.trocar(if (visivel) R.drawable.ic_q_video else R.drawable.ic_q_video_cortado,
            getString(if (visivel) R.string.r5_esconder_previa else R.string.r5_mostrar_previa))
        desenharFaixa()
    }

    private fun aplicarEspelhoDaPrevia(ligar: Boolean) {
        espelhoDaPrevia = ligar
        getSharedPreferences(PREFERENCIAS, MODE_PRIVATE).edit().putBoolean(PREF_ESPELHO_DA_PREVIA, ligar).apply()
        PreviaDoDono.espelhar(ligar)
        Log.i(TAG, "r5: prévia espelhada ${if (ligar) "ligada" else "desligada"} (a rede nunca espelha)")
    }

    /**
     * O lado do texto pela rotação da tela e pelo ajuste (o automático, desde 30/09: em cima, menos de
     * ponta-cabeça). A posição da borda a divisão lê sozinha, pelo formato que ela mede
     * ([DivisaoDaTela.fracaoGuardada]).
     */
    private fun aplicarLado() {
        if (!::divisao.isInitialized) return
        val rot = telaDaAtividade?.rotation ?: 0
        val lado = Divisao.ladoDoTexto(rot, escolhaDoLado)
        if (lado != divisao.lado) Log.i(TAG, "r5: tela em ${rot * 90}°, texto ${lado.name.lowercase()}")
        divisao.lado = lado
        // As marcas do enquadramento longe da lente — a lente **pela rotação** (a revisão, menor): com
        // o texto fixado num lado, a borda da vista na direção da lente é a que dá para a câmera.
        b.vistaRoteiro.ladoDaLente = Divisao.ladoDaLente(rot)
        PreviaDoDono.espelhar(espelhoDaPrevia)
    }

    // --- a faixa ----------------------------------------------------------------------------------

    /**
     * **O aparelho que não grava** (a D1, §14.3; `GravacaoIndisponivel`): o motivo, ou `null`. Com
     * ele, o Gravar fica apagado mas tocável (o toque repete a mensagem; o toque longo tenta mesmo
     * assim), a mensagem de duas linhas vira aviso cinza na faixa, a réplica deixa de dizer ao
     * controle que grava, e um pedido que chegue mesmo assim é recusado com o motivo.
     */
    private fun motivoDeNaoGravar(): String? = indisponivel()

    /** A cada tique (500 ms) e a cada mudança: os avisos, os chips, o microfone, o Gravar e a prévia. */
    private fun desenharFaixa() {
        if (!::faixa.isInitialized || !::divisao.isInitialized) return
        val agora = SystemClock.elapsedRealtime()
        if (recado != null && agora > recadoAte) recado = null
        val mic = MicrofoneBus.atual
        // A do espelhamento comum não aparece aqui (ver [aoMudarAGravacaoNoServico]).
        val g = GravacaoDaTelaBus.atual.let { if (it.daCameraComum) GravacaoDaTelaBus.Estado() else it }
        val naoGrava = motivoDeNaoGravar()

        // A prévia: "Aguarde…" até a câmera entregar, e o problema — também o que não é desta tela:
        // o núcleo que não carregou, e a câmera que o serviço não conseguiu abrir (a revisão do
        // código, 28/09: sem isto o "Aguarde…" ficava para sempre, e o motivo só durava 3,5 s).
        val entregando = videoPedido && MirrorService.cameraEntregando(ENTREGANDO_MS)
        // A falha de uma sessão anterior (o `falhaDoDono` só zera quando o dono abre de novo) não vale:
        // só a que apareceu depois do pedido desta tela, ou a que persiste 6 s (a revisão de 28/09).
        val falhaAgora = if (videoPedido) MirrorService.falhaDaCamera() else null
        if (falhaAgora == null) falhaAntigaSumiu = true
        val falha = falhaAgora?.takeIf {
            falhaAntigaSumiu || it != falhaDoPedido || agora - pedidoDoVideoEm > 6_000
        }
        when {
            problemaDaCamera == null && !QuallNative.carregado -> {
                mostrarProblema(getString(R.string.r5_nucleo_nao_carregou, QuallNative.erroDeCarga.orEmpty()), abreAjustes = false)
                return
            }
            problemaDaCamera == null && falha != null -> {
                mostrarProblema(getString(R.string.r5_frontal_nao_abriu, falha), abreAjustes = false, daFalha = true)
                return
            }
            problemaDaFalha && falha == null && entregando -> {
                mostrarProblema(null, abreAjustes = false)
                return
            }
        }
        // "Aguarde…" até a **prévia** desenhar o primeiro quadro, e não só até a câmera entregar ao
        // divisor (a conferência de 28/09 no A07: a câmera a 30 fps, a prévia preta, e nenhum aviso).
        val previaDesenhando = PreviaDoDono.previaDesenhando
        if (entregando && !previaDesenhando && !divisao.previaEscondida) reafirmarPrevia(agora)
        val aguarde = problemaDaCamera == null && !divisao.previaEscondida && !(entregando && previaDesenhando)
        val va = if (aguarde) View.VISIBLE else View.GONE
        if (camadaAguarde.visibility != va) camadaAguarde.visibility = va

        // O estado numa linha.
        desenharChipDoTexto()
        desenharChipDaCamera()
        microfone.atualizar(mic)
        // **Apagado, mas sempre tocável** (a D1; a revisão de 28/09): antes de o serviço publicar, o
        // toque diz "a câmera não está aberta" e o longo tenta mesmo assim, em vez de não fazer nada.
        gravar.atualizar(g.fase, agora - g.desdeMs, g.espacoLivre, mic.ligado, habilitado = true)
        val apagado = (naoGrava != null && g.fase == GravacaoDaTelaBus.Fase.PARADA) || !g.disponivel
        gravar.alpha = if (apagado) 0.4f else 1f
        val descricao = if (naoGrava != null && g.fase == GravacaoDaTelaBus.Fase.PARADA) {
            getString(R.string.r5_desativado, com.quall.android.mirror.GravacaoIndisponivel.texto(Idioma.textos(this)))
        } else null
        if (androidx.core.view.ViewCompat.getStateDescription(gravar)?.toString() != descricao) androidx.core.view.ViewCompat.setStateDescription(gravar, descricao)

        // Os avisos, na ordem do iOS (`FaixaDaTelaComCamera.avisos`) — com o recado vivo em primeiro:
        // ele dura 2 a 3,5 s e é resposta a um gesto ("Voltar de novo fecha o teleprompter."), e atrás
        // de "+N" a pessoa não o veria (a revisão do código, 28/09).
        val lista = mutableListOf<Aviso>()
        val acoes = mutableListOf<AcaoDoAviso>()
        recado?.let { lista += it }
        if (telaCheiaDaFaixa && g.ocupada) {
            lista += Aviso(getString(if (g.fase == GravacaoDaTelaBus.Fase.GRAVANDO) R.string.r5_gravando else R.string.r5_gravacao_em_transicao),
                Cores.VERMELHO, R.drawable.ic_q_gravar)
        }
        if (g.fase == GravacaoDaTelaBus.Fase.GRAVANDO) {
            if (!mic.ligado) lista += Aviso(getString(R.string.r5_gravando_sem_som), Cores.LARANJA, R.drawable.ic_q_mic_cortado)
            else if (!mic.capturando) lista += Aviso(getString(R.string.r5_gravando_sem_som_ainda), Cores.LARANJA, R.drawable.ic_q_mic)
        }
        val e = estadoDaTela
        val f = faseDaSessao
        val (pin, endereco) = pinEEnderecoDoTexto()
        val sessaoDePe = f is SessaoDoPrompter.Fase.ComControle
        val sumido = Avisos.controleSumido(jaTeveControleNaTela, sessaoDePe, e.parVistoHaMs)
        val linhas = Avisos.doPrompter(e, jaTeveControleNaTela, sessaoDePe, pin.ifEmpty { null }, endereco, textos, compacto = false)
        val curtas = Avisos.doPrompter(e, jaTeveControleNaTela, sessaoDePe, pin.ifEmpty { null }, endereco, textos, compacto = true)
        linhas.forEachIndexed { i, t ->
            val primeiroSumido = i == 0 && sumido
            lista += Aviso(t, if (primeiroSumido) Cores.VERMELHO else Cores.LARANJA,
                if (primeiroSumido) R.drawable.ic_q_sem_rede else if (i == 0 && !sumido) R.drawable.ic_q_relogio else R.drawable.ic_q_aviso,
                curto = curtas.getOrNull(i))
        }
        val v = MirrorBus.atual
        if (videoPedido && v.fase == MirrorBus.Fase.ERRO && v.mensagem.isNotBlank()) {
            lista += Aviso(v.mensagem, Cores.VERMELHO, R.drawable.ic_q_video_cortado)
        } else if (videoPedido && mensagemDoVideoEhAviso(v) &&
            (v.fase == MirrorBus.Fase.ESPERANDO || v.fase == MirrorBus.Fase.ESPELHANDO)
        ) {
            lista += Aviso(v.mensagem, Cores.LARANJA, R.drawable.ic_q_aviso)
        }
        // O aparelho fraco transmite em 720p (`core/TransmissaoLeve.kt`, §14.15): dito enquanto está no ar.
        if (videoPedido && v.fase == MirrorBus.Fase.ESPELHANDO && v.transmissaoLeve) {
            lista += Aviso(com.quall.android.core.TransmissaoLeve.frase(this), Cores.CINZA, R.drawable.ic_q_info,
                curto = getString(R.string.r5_transmitindo_720p))
        }
        if (!mic.ligado && mic.motivo.isNotBlank() && mic.disponivel) {
            lista += Aviso(getString(R.string.r5_microfone_desligado, mic.motivo(Idioma.textos(this))), Cores.LARANJA, R.drawable.ic_q_mic_cortado)
            // O motivo que manda aos Ajustes cita os Ajustes no idioma da tela ("Ajustes"/"Settings"): o
            // `MicrofoneBus` não tem um campo para isso (o dono do botão do microfone foi avisado).
            if (mic.pedeAjustes) {
                acoes += AcaoDoAviso(getString(R.string.r5_abrir_ajustes_microfone)) { abrirAjustesDoApp() }
            }
        } else if (mic.ligado && mic.aviso.isNotBlank()) {
            lista += Aviso(getString(R.string.r5_microfone_aviso, mic.aviso), Cores.LARANJA, R.drawable.ic_q_mic)
        }
        avisoDoLado?.let { lista += Aviso(it, Cores.CINZA, R.drawable.ic_q_info) }
        // Sem réplica (o núcleo carregou, mas ela não abriu), o texto não funciona: fica dito, e não
        // só no recado de 3,5 s (a revisão do código, 28/09).
        if (QuallNative.carregado && replicaDaTela == null) {
            lista += Aviso(getString(R.string.r5_nao_abriu_teleprompter, QuallNative.lastError()), Cores.VERMELHO, R.drawable.ic_q_aviso)
        }
        if (naoGrava != null && !g.ocupada) {
            val gi = com.quall.android.mirror.GravacaoIndisponivel
            lista += Aviso(gi.mensagem(Idioma.textos(this)), Cores.CINZA, R.drawable.ic_q_info, curto = gi.texto(Idioma.textos(this)))
        }
        avisos.mostrar(lista, acoes)
        aplicarPaddingDaFaixa()
    }

    /** O chip do Texto: a bolinha e o estado da sessão do prompter (`corDoPrompter`/`textoDoPrompter` do iOS). */
    private fun desenharChipDoTexto() {
        val f = faseDaSessao
        val sumido = Avisos.controleSumido(jaTeveControleNaTela, f is SessaoDoPrompter.Fase.ComControle, estadoDaTela.parVistoHaMs)
        val (cor, estado) = when (f) {
            null, SessaoDoPrompter.Fase.Parado -> Cores.AMARELO to getString(R.string.r5_estado_parado)
            is SessaoDoPrompter.Fase.Esperando ->
                if (jaTeveControleNaTela) Cores.VERMELHO to getString(R.string.r5_estado_controle_desconectado)
                else Cores.AMARELO to getString(R.string.r5_estado_esperando_controle)
            is SessaoDoPrompter.Fase.ComControle -> when {
                sumido -> Cores.VERMELHO to getString(R.string.r5_estado_controle_desconectado)
                f.par.isEmpty() -> Cores.VERDE to getString(R.string.r5_estado_controle_conectado)
                else -> Cores.VERDE to getString(R.string.r5_estado_controlado_por, f.par)
            }
            is SessaoDoPrompter.Fase.Erro -> Cores.LARANJA to f.mensagem
        }
        chipDoTexto.atualizar(cor, pinEEnderecoDoTexto().first, estado)
    }

    /** O chip da Câmera, pelo `MirrorBus` (`corDaCamera`/`textoDaCamera` do iOS, os estados que o Android tem). */
    private fun desenharChipDaCamera() {
        val e = MirrorBus.atual
        val (cor, estado) = when {
            problemaDaCamera != null -> Cores.VERMELHO to getString(R.string.r5_camera_sem_acesso)
            !videoPedido -> Cores.AMARELO to getString(R.string.r5_camera_abrindo)
            e.fase == MirrorBus.Fase.ESPELHANDO ->
                Cores.VERDE to (if (e.par.isEmpty()) getString(R.string.r5_camera_enviando) else getString(R.string.r5_camera_enviando_para, e.par))
            e.fase == MirrorBus.Fase.ESPERANDO -> Cores.AMARELO to getString(R.string.r5_camera_esperando)
            e.fase == MirrorBus.Fase.ERRO -> Cores.VERMELHO to getString(R.string.r5_camera_parou)
            else -> Cores.AMARELO to getString(R.string.r5_camera_abrindo)
        }
        chipDaCamera.atualizar(cor, if (videoPedido) e.pin else "", estado)
    }

    // --- a gravação -------------------------------------------------------------------------------

    private fun alternarGravacao() {
        pedirGravacaoPelaTela(GravacaoDaTelaBus.atual.fase == GravacaoDaTelaBus.Fase.PARADA)
    }

    /** O botão (e a bancada): começar ou parar, sem pedido do controle. */
    private fun pedirGravacaoPelaTela(gravar: Boolean) {
        val fase = GravacaoDaTelaBus.atual.fase
        if (gravar && fase != GravacaoDaTelaBus.Fase.PARADA) return
        if (!gravar && fase == GravacaoDaTelaBus.Fase.PARADA) return
        if (gravar) indisponivel()?.let { motivo ->
            // O botão apagado repete o motivo no toque (§14.3).
            Log.i(TAG, "r5: botão — gravar, indisponível: $motivo")
            avisoCurto(com.quall.android.mirror.GravacaoIndisponivel.mensagem(Idioma.textos(this)), longo = true)
            return
        }
        if (GravacaoDaTelaBus.atual.daCameraComum) {
            avisoCurto(getString(R.string.r5_nao_da_gravar_espelhamento), longo = true, grave = true)
            return
        }
        Log.i(TAG, "r5: botão — ${if (gravar) "gravar" else "parar a gravação"}")
        if (!MirrorService.pedirGravacao(gravar, daTelaR5 = true) && gravar) {
            avisoCurto(getString(R.string.r5_nao_da_gravar_fechada), longo = true, grave = true)
        }
    }

    /**
     * **"Tentar mesmo assim"** (a revisão, 12): o toque longo no botão apagado esquece as falhas
     * guardadas. A bandeira de bancada continua valendo.
     */
    private fun tentarGravarMesmoAssim(): Boolean {
        if (indisponivel() == null) return false
        val gi = com.quall.android.mirror.GravacaoIndisponivel
        gi.esquecer(this)
        val novo = gi.motivo(this)
        indisponivelDaTela = novo
        if (GravacaoDaTelaBus.atual.disponivel && !GravacaoDaTelaBus.atual.daCameraComum) {
            GravacaoDaTelaBus.atualizar { it.copy(indisponivel = novo) }
        }
        Log.i(TAG, "r5: tentar gravar mesmo assim — ${novo?.let { "continua indisponível: $it" } ?: "o Gravar volta"}")
        avisoCurto(if (novo == null) getString(R.string.r5_gravar_voltou) else getString(R.string.r5_continua_sem_gravar, novo), longo = true)
        desenharFaixa()
        return true
    }

    /**
     * O serviço mudou a gravação: diz ao núcleo quando o arquivo de fato começou ou fechou (§13.8),
     * responde ao pedido aberto do controle com a recusa que o serviço deu, trava ou solta a
     * orientação, e decide de novo o pedido aberto (ele pode estar esperando esta fase).
     */
    private fun aoMudarAGravacaoNoServico(e: GravacaoDaTelaBus.Estado) {
        if (isDestroyed) return
        // A gravação do espelhamento comum não é desta tela (a câmera está com ele, e o serviço
        // recusou a tela R5): nem a réplica nem a orientação ouvem o que é dele.
        if (e.daCameraComum) {
            desenharFaixa()
            return
        }
        acompanharGravacaoNaReplica(e)
        val r = replicaDaTela
        if (e.fase != faseVista) {
            Log.i(TAG, "r5: gravação ${faseVista.name.lowercase()} → ${e.fase.name.lowercase()}" +
                if (e.nome.isNotBlank() && e.fase == GravacaoDaTelaBus.Fase.GRAVANDO) " (${e.nome})" else "")
            faseVista = e.fase
        }
        if (e.fase == GravacaoDaTelaBus.Fase.GRAVANDO || e.fase == GravacaoDaTelaBus.Fase.PARADA) {
            val gravando = e.fase == GravacaoDaTelaBus.Fase.GRAVANDO
            if (r != null && gravando != gravandoDito) {
                val st = r.definirGravando(gravando)
                gravandoDito = gravando
                Log.i(TAG, "r5: a réplica sabe que ${if (gravando) "grava" else "parou"} (set_recording: ${QuallNative.Status.nome(st)})")
                pedidoEncaminhado = null
            }
        }
        // Um arquivo só (§5.2): da abertura ao fechamento, a tela não gira.
        travarOrientacao(e.ocupada)
        atualizarFolhaDeAjustes()
        if (e.numeroDaRecusa != recusaVista && e.recusa.isNotBlank()) {
            recusaVista = e.numeroDaRecusa
            avisoCurto(getString(R.string.r5_nao_gravou, e.recusa), longo = true, grave = true)
            // A recusa responde **ao pedido que a tela encaminhou** (o `n` que ela decidiu, §13.3), e
            // não ao que estiver aberto agora (a revisão, menor): um pedido mais novo que chegou no
            // meio dá `BUSY` e é decidido de novo. Uma recusa do botão não responde a pedido nenhum.
            val n = pedidoEncaminhado
            pedidoEncaminhado = null
            if (r != null && n != null) {
                val st = r.recusarGravacao(n, DecisaoDaGravacao.motivo(e.recusa, textos))
                Log.i(TAG, "r5: pedido $n do controle recusado: ${e.recusa} (${QuallNative.Status.nome(st)})")
            }
        }
        if (e.fase == GravacaoDaTelaBus.Fase.PARADA && e.mensagem.isNotBlank() && e.mensagem != paradaVista) {
            paradaVista = e.mensagem
            avisoCurto(e.mensagem, longo = true)
        }
        if (r != null) r.estado()?.let { decidirPedido(r, it) }
        desenharFaixa()
    }

    /** O pedido aberto do controle, contra o estado do arquivo ([DecisaoDaGravacao]). */
    private fun decidirPedido(r: ReplicaDoTeleprompter, e: EstadoDoTeleprompter) {
        val p = e.pedidoDeGravacao ?: return
        if (GravacaoDaTelaBus.atual.daCameraComum) {
            if (pedidoEncaminhado == p.n) return
            pedidoEncaminhado = p.n
            val st = r.recusarGravacao(p.n, DecisaoDaGravacao.motivo(getString(R.string.r5_recusa_espelhamento), textos))
            Log.i(TAG, "r5: pedido ${p.n} recusado: a câmera está com o espelhamento comum (${QuallNative.Status.nome(st)})")
            return
        }
        // O aparelho que não grava (a D1): o pedido de gravar do controle é recusado com o motivo.
        val naoGrava = motivoDeNaoGravar()
        if (p.gravar && naoGrava != null && GravacaoDaTelaBus.atual.fase == GravacaoDaTelaBus.Fase.PARADA) {
            if (pedidoEncaminhado == p.n) return
            pedidoEncaminhado = p.n
            val st = r.recusarGravacao(p.n, DecisaoDaGravacao.motivo(naoGrava, textos))
            Log.i(TAG, "r5: pedido ${p.n} recusado: $naoGrava (${QuallNative.Status.nome(st)})")
            return
        }
        val fase = GravacaoDaTelaBus.atual.fase
        when (DecisaoDaGravacao.decidir(p.gravar, fase)) {
            DecisaoDaGravacao.Acao.RESPONDER -> {
                val st = r.definirGravando(p.gravar)
                gravandoDito = p.gravar
                Log.i(TAG, "r5: pedido ${p.n} do controle (${if (p.gravar) "gravar" else "parar"}) respondido: já estava assim " +
                    "(${QuallNative.Status.nome(st)})")
            }
            DecisaoDaGravacao.Acao.COMECAR, DecisaoDaGravacao.Acao.PARAR -> {
                if (pedidoEncaminhado == p.n) return
                pedidoEncaminhado = p.n
                Log.i(TAG, "r5: pedido ${p.n} do controle: ${if (p.gravar) "gravar" else "parar"} — pedindo ao serviço")
                if (!MirrorService.pedirGravacao(p.gravar, daTelaR5 = true) && p.gravar) {
                    pedidoEncaminhado = null
                    val st = r.recusarGravacao(p.n, DecisaoDaGravacao.motivo(getString(R.string.r5_recusa_camera_fechada), textos))
                    Log.i(TAG, "r5: pedido ${p.n} recusado: sem serviço de vídeo (${QuallNative.Status.nome(st)})")
                }
            }
            DecisaoDaGravacao.Acao.ESPERAR -> Unit
        }
    }

    private fun lerBancada(i: Intent) {
        if (!::divisao.isInitialized) return
        if (i.hasExtra(EXTRA_LADO_DO_TEXTO)) {
            val chave = i.getStringExtra(EXTRA_LADO_DO_TEXTO)
            val e = Divisao.Escolha.daChave(chave)
            if (e == null) Log.w(TAG, "r5: bancada pede o lado do texto \"$chave\", que não existe " +
                "(${Divisao.Escolha.entries.joinToString(" | ") { it.chave }})")
            else ajustesDaCamera.escolherLado(e)
        }
        if (i.hasExtra(EXTRA_PREVIA)) mostrarCamera(i.getBooleanExtra(EXTRA_PREVIA, true))
        if (i.hasExtra(EXTRA_ESPELHO_DA_PREVIA)) aplicarEspelhoDaPrevia(i.getBooleanExtra(EXTRA_ESPELHO_DA_PREVIA, true))
        if (i.hasExtra(EXTRA_GRAVAR)) {
            val gravar = i.getBooleanExtra(EXTRA_GRAVAR, false)
            Log.i(TAG, "r5: bancada pede ${if (gravar) "gravar" else "parar a gravação"} (o caminho do botão)")
            // Como o microfone: um pedido que chega junto com a abertura espera o serviço subir.
            principal.postDelayed({ if (!isDestroyed) pedirGravacaoPelaTela(gravar) }, 300)
        }
        if (i.hasExtra(EXTRA_MICROFONE)) {
            val ligar = i.getBooleanExtra(EXTRA_MICROFONE, false)
            Log.i(TAG, "r5: bancada pede o microfone ${if (ligar) "ligado" else "desligado"}")
            // Pelo mesmo caminho do toque, com o serviço já de pé: um pedido que chega junto com a
            // abertura da tela espera o serviço subir. Um só pendente, e cancelado ao sair.
            principal.removeCallbacks(microfoneDaBancada)
            microfoneDaBancadaLigar = ligar
            principal.postDelayed(microfoneDaBancada, 300)
        }
    }
}

/**
 * **O espelho do texto que a tela R5 desliga ao abrir, e devolve ao sair** (§8.3). A réplica é uma
 * só para o prompter comum e para a tela R5, e o salvo dela também: desligado aqui e não devolvido,
 * o prompter comum abria sem espelho — o vidro do suporte mostrava o texto ao contrário (a prova de
 * 24/09 no S24).
 *
 * A dívida mora nas preferências, e não na tela: sobrevive a uma recriação e à morte do processo
 * com a tela aberta — nesse caso quem paga é o prompter comum, ao abrir. Uma trava só para anotar,
 * esquecer e devolver: a tela que sai devolve numa thread dela, e uma tela nova pode estar abrindo
 * ao mesmo tempo.
 */
internal object EspelhoDaTelaComCamera {
    private const val TAG = "QuallR5"
    private const val PREFERENCIAS = "quall-prompter-r5"
    private const val CHAVE = "espelho_do_texto_a_devolver"
    private val trinco = Any()

    private fun prefs(c: Context) = c.getSharedPreferences(PREFERENCIAS, Context.MODE_PRIVATE)

    /** Ao abrir a tela R5: desliga o espelho do texto e anota que ele volta. */
    fun desligarAoAbrir(c: Context, r: ReplicaDoTeleprompter) = synchronized(trinco) {
        val e = r.estado() ?: return@synchronized
        if (!e.espelho) {
            if (prefs(c).getBoolean(CHAVE, false)) {
                Log.i(TAG, "r5: espelho do texto já desligado e ainda devido ao prompter comum (de uma tela anterior)")
            }
            return@synchronized
        }
        // Anotado antes de desligar: morrendo entre os dois, o comum confere o estado e não liga à toa.
        prefs(c).edit().putBoolean(CHAVE, true).commit()
        val st = r.definirEspelho(false)
        if (st != QuallNative.Status.OK) prefs(c).edit().remove(CHAVE).commit()
        Log.i(TAG, "r5: espelho do texto desligado ao abrir (${QuallNative.Status.nome(st)}); volta ao sair, se ninguém o ligar aqui")
    }

    /** O espelho foi ligado durante a tela: a dívida some. */
    fun esquecer(c: Context, motivo: String) = synchronized(trinco) {
        val p = prefs(c)
        if (!p.getBoolean(CHAVE, false)) return@synchronized
        p.edit().remove(CHAVE).commit()
        Log.i(TAG, "r5: $motivo — não será devolvido ao sair")
    }

    /**
     * Paga a dívida, se houver: liga o espelho do texto (se continua desligado), grava e esquece.
     * [soSemTelaAberta]: a tela R5 que sai não paga se outra tela de prompter já abriu — essa decide.
     */
    fun devolver(c: Context, r: ReplicaDoTeleprompter, motivo: String, soSemTelaAberta: Boolean, gravarJa: Boolean = false): Boolean =
        synchronized(trinco) {
            val p = prefs(c)
            if (!p.getBoolean(CHAVE, false)) return@synchronized false
            if (soSemTelaAberta && PrompterActivity.algumaAberta) {
                Log.i(TAG, "r5: espelho do texto não devolvido ($motivo): outra tela de prompter já abriu e decide")
                return@synchronized false
            }
            val e = r.estado() ?: return@synchronized false // réplica fechada: a dívida fica
            if (!e.espelho) {
                val st = r.definirEspelho(true)
                if (st != QuallNative.Status.OK) {
                    Log.w(TAG, "r5: espelho do texto não devolvido ($motivo): ${QuallNative.Status.nome(st)}")
                    return@synchronized false
                }
                // Fora da thread principal (a tela que sai), grava antes de esquecer a dívida: um
                // processo morto entre os dois deixaria o salvo desligado e ninguém devendo.
                if (gravarJa) r.salvar() else r.salvarEmOrdem()
                Log.i(TAG, "r5: espelho do texto devolvido ao prompter comum ($motivo)")
            }
            p.edit().remove(CHAVE).commit()
            true
        }
}
