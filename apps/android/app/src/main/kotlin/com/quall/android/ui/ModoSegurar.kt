package com.quall.android.ui

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewTreeObserver
import android.widget.Toast
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.core.QuallNative
import com.quall.android.databinding.ModoSegurarBinding
import com.quall.android.teleprompter.Avisos
import com.quall.android.teleprompter.EstadoDoTeleprompter
import com.quall.android.teleprompter.ReplicaDoTeleprompter
import com.quall.android.teleprompter.SegurarParaRolar
import com.quall.android.teleprompter.SegurarParaRolar.Botao
import com.quall.android.teleprompter.SessaoDoControle

/**
 * **"Segurar para rolar" na tela do controle** (`docs/contrato-teleprompter.md` §12.5): a camada
 * com os dois botões grandes por cima do painel, os toques, e o que ela mostra. As regras (o que
 * cada toque manda, dois dedos, o texto que parou sozinho) são [SegurarParaRolar], sem Android.
 *
 * - A opção é **ajuste local do controle**, guardada no aparelho ([PREFERENCIAS], [PREF_LIGADO]).
 * - `release` ao tirar o dedo, ao cancelar o toque, ao escorregar para fora do botão, ao ir para o
 *   segundo plano e ao fechar a tela ([soltarTudo], chamado pela tela).
 * - Os botões só funcionam com o prompter dizendo que entende (`"par_entende_segurar"`) e a sessão
 *   de pé; sem isso ficam apagados e **não seguram** — mas o dedo que já estava num botão continua
 *   sendo acompanhado até sair, para o `release` nunca se perder.
 * - **Nada se mexe debaixo do dedo**: o aviso tem altura fixa e só fica invisível, senão um aviso que
 *   aparece empurraria os botões, e o dedo parado "sairia" do botão sozinho (revisão de 14/09).
 * - **"Inverter botões"** (pedido do usuário, 14/09 à tarde), no canto junto do "Sair" e, como ele,
 *   só segurando: o de cima avança e o de baixo volta; as setas e os rótulos ficam, as legendas
 *   trocam. Com um dedo num botão de rolar a troca não vale. Guardado com a opção do modo
 *   ([PREF_INVERTIDO]).
 *
 * A bancada ([bancada]) entra pelo **mesmo** caminho do dedo: monta o `MotionEvent` de toque, com
 * todos os dedos da bancada, e o entrega à janela — a divisão entre os dois botões é a do Android.
 */
internal class ModoSegurar(
    private val contexto: Context,
    private val v: ModoSegurarBinding,
    private val replica: ReplicaDoTeleprompter,
    /** O painel de sempre, embaixo da camada: some para o leitor de tela enquanto ela aparece. */
    private val painelDeBaixo: View,
) {
    companion object {
        private const val TAG = "QuallTeleprompter"

        /** As preferências do controle, deste aparelho (não vão para o outro lado). */
        const val PREFERENCIAS = "quall-controle"
        const val PREF_LIGADO = "segurar_para_rolar"

        /** "Inverter botões": local do controle, junto com a opção do modo; vale para qualquer prompter. */
        const val PREF_INVERTIDO = "inverter_botoes"

        private const val COR_DO_BOTAO = Cores.SUPERFICIE_ALTA
        private const val COR_SEGURANDO = 0xFF2E7D32.toInt()
        private const val COR_PAROU = 0xFF8A5A00.toInt()
        private const val ALFA_DESLIGADO = 0.35f
        private const val COR_DA_INVERSAO = Cores.ACENTO

        /** Bancada: quanto esperar a janela assentar depois do `am start` antes do toque longo. */
        private const val ESPERA_DO_FOCO_MS = 400L
    }

    private val prefs = contexto.getSharedPreferences(PREFERENCIAS, Context.MODE_PRIVATE)

    /** As frases do modo (legendas, avisos), no idioma da tela. */
    private val t = Idioma.textos(contexto)

    private val regras = SegurarParaRolar(object : SegurarParaRolar.Porta {
        override fun segurar(paraTras: Boolean): Int = replica.segurar(paraTras)
        override fun soltar(): Int = replica.soltar()
    }, invertido = prefs.getBoolean(PREF_INVERTIDO, false))

    /** A opção, como está guardada. */
    var ligado: Boolean = prefs.getBoolean(PREF_LIGADO, false)
        private set

    private var painelVisivel = false
    private var botoesLigados = false
    private var avisoMostrado: String? = null
    private val fundoCima = fundo()
    private val fundoBaixo = fundo()
    private val fundoDaInversao = GradientDrawable().apply {
        cornerRadius = 14f * contexto.resources.displayMetrics.density
        setColor(COR_DA_INVERSAO)
    }

    /** Um dedo da bancada: em que botão encostou e onde está, na janela. */
    private class DedoDaBancada(val id: Int, val botao: View, var x: Float, var y: Float)

    /** Os dedos da bancada que estão na tela, por id, e quando o gesto começou (o `downTime`). */
    private val dedosDaBancada = sortedMapOf<Int, DedoDaBancada>()
    private var inicioDoGesto = 0L

    init {
        v.botaoRolarParaCima.background = fundoCima
        v.botaoRolarParaBaixo.background = fundoBaixo
        desenharInversao()
        v.botaoRolarParaCima.setOnTouchListener { b, ev -> tocar(b, Botao.CIMA, ev) }
        v.botaoRolarParaBaixo.setOnTouchListener { b, ev -> tocar(b, Botao.BAIXO, ev) }
        // A saída não se aperta sem querer: só segurando. O toque curto só explica.
        v.buttonSairDoSegurar.setOnClickListener { avisarSaida() }
        v.buttonSairDoSegurar.setOnLongClickListener {
            ligar(false, "Sair")
            true
        }
        // "Inverter botões": protegido como o "Sair" — só segurando troca; o toque curto explica.
        v.buttonInverterBotoes.setOnClickListener {
            Toast.makeText(contexto, R.string.tp_inverter_como, Toast.LENGTH_SHORT).show()
        }
        v.buttonInverterBotoes.setOnLongClickListener {
            inverter(!regras.invertido, "Inverter botões") // i18n-fora: quem pediu, para o diário
            true
        }
    }

    /**
     * Liga ou desliga "Inverter botões" e guarda. **Com um dedo num botão de rolar, não vale**: nada
     * muda até soltar (as regras recusam, e o botão aparece apagado enquanto isso).
     */
    private fun inverter(sim: Boolean, quem: String) {
        if (!regras.inverter(sim)) {
            Log.i(TAG, "controle: inverter botões RECUSADO ($quem) — há um dedo num botão de rolar; fica ${estadoDaInversao()} até soltar")
            Toast.makeText(contexto, R.string.tp_inverter_solte, Toast.LENGTH_SHORT).show()
            return
        }
        prefs.edit().putBoolean(PREF_INVERTIDO, sim).apply()
        Log.i(TAG, "controle: inverter botões ${if (sim) "LIGADO" else "desligado"} ($quem) — cima: " +
            "hold(para_tras=${SegurarParaRolar.paraTras(Botao.CIMA, sim)}), baixo: hold(para_tras=${SegurarParaRolar.paraTras(Botao.BAIXO, sim)})")
        desenharInversao()
    }

    private fun estadoDaInversao() = if (regras.invertido) "ligado" else "desligado"

    /** As legendas (o que cada botão faz agora), e o "Inverter botões" com a marca de ligado. */
    private fun desenharInversao() {
        val sim = regras.invertido
        v.textEfeitoCima.seMudou(SegurarParaRolar.efeito(Botao.CIMA, t, sim))
        v.textEfeitoBaixo.seMudou(SegurarParaRolar.efeito(Botao.BAIXO, t, sim))
        v.buttonInverterBotoes.seMudou(contexto.getString(if (sim) R.string.tp_inverter_botoes_ligado else R.string.tp_inverter_botoes))
        v.buttonInverterBotoes.background = if (sim) fundoDaInversao else null
        v.buttonInverterBotoes.setTextColor(if (sim) 0xFFFFFFFF.toInt() else 0x99FFFFFF.toInt())
        v.buttonInverterBotoes.contentDescription =
            contexto.getString(if (sim) R.string.tp_inverter_descricao_ligado else R.string.tp_inverter_descricao_desligado)
        v.buttonInverterBotoes.alpha = if (regras.algumDedo) ALFA_DESLIGADO else 1f
    }

    private fun fundo() = GradientDrawable().apply {
        cornerRadius = 24f * contexto.resources.displayMetrics.density
        setColor(COR_DO_BOTAO)
    }

    /** Liga ou desliga a opção (o botão do painel, o "Sair", a bancada) e guarda. */
    fun ligar(sim: Boolean, quem: String) {
        if (!sim) soltarTudo("saiu do modo")
        if (ligado != sim) {
            ligado = sim
            prefs.edit().putBoolean(PREF_LIGADO, sim).apply()
            Log.i(TAG, "controle: segurar para rolar ${if (sim) "LIGADO" else "desligado"} ($quem)")
        }
        atualizarVisibilidade()
    }

    /** O painel do controle apareceu ou sumiu (a escolha do prompter no lugar dele). */
    fun painel(visivel: Boolean) {
        painelVisivel = visivel
        atualizarVisibilidade()
    }

    val visivel: Boolean get() = v.root.visibility == View.VISIBLE

    private fun atualizarVisibilidade() {
        val mostrar = ligado && painelVisivel
        if (!mostrar) soltarTudo("modo escondido")
        v.root.visibility = if (mostrar) View.VISIBLE else View.GONE
        painelDeBaixo.importantForAccessibility =
            if (mostrar) View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS else View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
    }

    fun avisarSaida() {
        Toast.makeText(contexto, R.string.tp_sair_como, Toast.LENGTH_SHORT).show()
    }

    // --- os toques -------------------------------------------------------------------------------

    /**
     * Um botão recebe os dedos que encostaram nele (o Android divide o toque entre as vistas):
     * encostar segura, e levantar, cancelar ou escorregar para fora sai. Os dois botões juntos são
     * os "dois dedos" de [SegurarParaRolar].
     *
     * Com um dedo já num botão, o Android entrega a esse mesmo botão o dedo novo que cai **fora**
     * dos dois (no cabeçalho, no aviso, no vão): ele não aperta — só encostar **dentro** aperta.
     */
    private fun tocar(botao: View, qual: Botao, ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val i = ev.actionIndex
                if (dentro(botao, ev.getX(i), ev.getY(i))) encostou(ev.getPointerId(i), qual)
            }
            MotionEvent.ACTION_MOVE -> for (i in 0 until ev.pointerCount) {
                if (!dentro(botao, ev.getX(i), ev.getY(i))) saiu(ev.getPointerId(i), "saiu do botão") // i18n-fora: como saiu, para o diário
            }
            MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP -> saiu(ev.getPointerId(ev.actionIndex), "levantou")
            MotionEvent.ACTION_CANCEL -> for (i in 0 until ev.pointerCount) saiu(ev.getPointerId(i), "toque cancelado")
        }
        return true
    }

    private fun dentro(v: View, x: Float, y: Float) = x >= 0f && y >= 0f && x < v.width && y < v.height

    private fun encostou(dedo: Int, qual: Botao) {
        if (!botoesLigados || !visivel) {
            Log.i(TAG, "controle: segurar — dedo $dedo em $qual com os botões desligados (${avisoMostrado ?: "modo escondido"}); nada sai")
            return
        }
        val st = regras.encostou(dedo, qual)
        Log.i(TAG, "controle: segurar — dedo $dedo encostou em $qual → hold(para_tras=${regras.paraTrasDe(qual)}) " +
            QuallNative.Status.nome(st))
        redesenhar()
    }

    private fun saiu(dedo: Int, como: String) {
        if (!regras.conhece(dedo)) return // o MOVE de um dedo que já saiu, ou que nunca apertou
        // Antes de o dedo sair, o estado de agora: se o texto já parou (a pausa no prompter, a
        // queda), o dedo que sobra não pode apertar de novo sozinho.
        conferir(replica.estado())
        val antes = regras.seguro
        val st = regras.saiu(dedo) ?: return
        val oQue = if (regras.algumDedo) "hold(para_tras=${regras.seguro?.let(regras::paraTrasDe)})" else "release"
        Log.i(TAG, "controle: segurar — dedo $dedo $como (segurava $antes) → $oQue ${QuallNative.Status.nome(st)}")
        redesenhar()
    }

    /** Segundo plano, fechar a tela, sair do modo, desconectar: nenhum dedo fica segurando. */
    fun soltarTudo(motivo: String) {
        dedosDaBancada.clear()
        val st = regras.soltarTudo() ?: return
        Log.i(TAG, "controle: segurar — $motivo com o dedo no botão → release ${QuallNative.Status.nome(st)}")
        redesenhar()
    }

    // --- desenhar ---------------------------------------------------------------------------------

    private var ultimo: EstadoDoTeleprompter? = null
    private var ultimaConexao: String? = null
    private var ultimoNaoChegou = false

    /**
     * A cada desenho da tela (os bits da sessão e o tique de 250 ms). [fase] e [sessaoHaMs] são os
     * da tela; daqui sai o estado da conexão, o aviso e se os botões funcionam.
     */
    fun desenhar(e: EstadoDoTeleprompter, fase: SessaoDoControle.Fase?, sessaoHaMs: Long) {
        val controlando = fase is SessaoDoControle.Fase.Controlando
        val reconectando = fase is SessaoDoControle.Fase.Reconectando
        val perdida = Avisos.conexaoPerdida(reconectando, controlando, sessaoHaMs, e.parVistoHaMs)
        ultimaConexao = when {
            fase is SessaoDoControle.Fase.Conectando -> contexto.getString(R.string.tp_segurar_conectando, fase.endpoint)
            fase is SessaoDoControle.Fase.Reconectando -> fase.aviso
            controlando && perdida -> contexto.getString(R.string.tp_segurar_nao_responde)
            controlando -> null
            else -> contexto.getString(R.string.tp_segurar_sem_conexao)
        }
        ultimoNaoChegou = Avisos.comandoNaoChegou(controlando, e.semConfirmacaoHaMs)
        v.textSegurarConexao.seMudou(
            (fase as? SessaoDoControle.Fase.Controlando)?.let { contexto.getString(R.string.tp_controlando_par, it.par) }
                ?: contexto.getString(R.string.tp_sem_sessao)
        )
        v.textSegurarVelocidade.seMudou(contexto.getString(R.string.tp_segurar_velocidade, e.velocidade))
        redesenhar(e)
    }

    /** O texto parou com o dedo no botão? Registra uma vez. */
    private fun conferir(e: EstadoDoTeleprompter?) {
        if (e != null && regras.conferir(e.segurando)) {
            Log.i(TAG, "controle: segurar — o texto PAROU com o dedo no botão (segurando=false; rolando=${e.rolando}); " +
                "espera soltar e apertar de novo")
        }
    }

    /**
     * Depois de um toque, com o estado **relido** da réplica: o `hold` que acabou de sair já pôs
     * `segurando` nela, e conferir com o estado do desenho anterior (de antes do aperto) daria
     * "o texto parou" no próprio aperto — medido no A07 em 14/09, na primeira corrida da prova 2.
     */
    private fun redesenhar(fresco: EstadoDoTeleprompter? = replica.estado()) {
        val e = fresco ?: ultimo ?: return
        ultimo = e
        conferir(e)
        val recusado = regras.ultimoStatus == QuallNative.Status.PROTOCOL && regras.algumDedo
        val s = SegurarParaRolar.situacao(
            semConexao = ultimaConexao,
            parVisto = e.parVistoHaMs != null,
            entende = e.parEntendeSegurar,
            recusado = recusado,
            parou = regras.parou,
            comandoNaoChegou = ultimoNaoChegou,
            t = t,
        )
        if (s.botoesLigados != botoesLigados) {
            botoesLigados = s.botoesLigados
            Log.i(TAG, "controle: segurar — botões ${if (s.botoesLigados) "ligados" else "DESLIGADOS"}")
        }
        if (s.aviso != avisoMostrado) {
            avisoMostrado = s.aviso
            Log.i(TAG, "controle: segurar — aviso ${s.aviso ?: "apagado"}")
            v.textSegurarAviso.text = s.aviso.orEmpty()
            // INVISIBLE, e não GONE: a altura fica, e os botões não andam debaixo do dedo.
            v.textSegurarAviso.visibility = if (s.aviso == null) View.INVISIBLE else View.VISIBLE
        }
        val alfa = if (s.botoesLigados) 1f else ALFA_DESLIGADO
        v.botaoRolarParaCima.alpha = alfa
        v.botaoRolarParaBaixo.alpha = alfa
        val ativo = regras.ativo
        fun cor(b: Botao) = when {
            ativo != b -> COR_DO_BOTAO
            regras.parou -> COR_PAROU
            regras.seguro == b -> COR_SEGURANDO
            else -> COR_DO_BOTAO
        }
        fundoCima.setColor(cor(Botao.CIMA))
        fundoBaixo.setColor(cor(Botao.BAIXO))
        v.buttonInverterBotoes.alpha = if (regras.algumDedo) ALFA_DESLIGADO else 1f
    }

    // --- bancada ----------------------------------------------------------------------------------

    /**
     * **A bancada, pelo mesmo caminho do dedo** (provas 2 e 3 do pedido de 14/09): um `MotionEvent`
     * de toque com **todos** os dedos da bancada, entregue à janela — como o sistema entrega. A
     * divisão entre os dois botões, e o dedo novo que cai fora deles, são os do Android.
     *
     * `acao`: `cima` ou `baixo` (encosta o dedo `dedo` no meio do botão), `cabecalho` (encosta fora
     * dos dois, na linha da conexão), `inverter` (segura "Inverter botões" o tempo de um toque longo
     * e levanta), `soltar` (levanta), `fora` (escorrega para o vão acima do botão) ou `cancelar` (o
     * sistema cancela o toque).
     */
    fun bancada(acao: String, dedo: Int) {
        val janela = v.root.rootView
        val agora = SystemClock.uptimeMillis()
        fun centro(b: View): Pair<Float, Float> {
            val xy = IntArray(2)
            b.getLocationInWindow(xy)
            return (xy[0] + b.width / 2f) to (xy[1] + b.height / 2f)
        }
        when (acao) {
            "cima", "baixo", "cabecalho" -> {
                if (dedosDaBancada.containsKey(dedo)) {
                    Log.w(TAG, "bancada: segurar $acao — o dedo $dedo já está na tela")
                    return
                }
                // `cabecalho`: um dedo que encosta fora dos dois botões (na linha da conexão).
                val botao = when (acao) {
                    "cima" -> v.botaoRolarParaCima
                    "baixo" -> v.botaoRolarParaBaixo
                    else -> v.textSegurarConexao
                }
                val (x, y) = centro(botao)
                val primeiro = dedosDaBancada.isEmpty()
                if (primeiro) inicioDoGesto = agora
                dedosDaBancada[dedo] = DedoDaBancada(dedo, botao, x, y)
                entregar(janela, if (primeiro) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_POINTER_DOWN, dedo, agora, acao)
            }
            "inverter" -> {
                // Um dedo que segura "Inverter botões" o tempo de um toque longo e levanta — o
                // mesmo toque longo do dedo de verdade (o `OnLongClickListener` do Android), com os
                // outros dedos da bancada onde estão. Espera a janela assentar com foco: o `am start`
                // da bancada passa por uma tela translúcida, a janela perde e recupera o foco, e a
                // perda cancela o toque longo em curso (`View.onWindowFocusChanged`) — medido no
                // tablet em 14/09: o primeiro toque longo da bancada não ligou nada.
                if (dedosDaBancada.containsKey(dedo)) {
                    Log.w(TAG, "bancada: segurar $acao — o dedo $dedo já está na tela")
                    return
                }
                depoisDoFoco { segurarOInverter(janela, dedo) }
            }
            "fora" -> {
                val d = dedosDaBancada[dedo] ?: return semDedo(acao, dedo)
                // Para o vão de 12 dp acima do botão dele (entre o aviso e o de cima; entre os dois).
                val xy = IntArray(2)
                d.botao.getLocationInWindow(xy)
                d.y = xy[1] - 6f * contexto.resources.displayMetrics.density
                entregar(janela, MotionEvent.ACTION_MOVE, dedo, agora, acao)
            }
            "soltar" -> {
                if (!dedosDaBancada.containsKey(dedo)) return semDedo(acao, dedo)
                entregar(janela, if (dedosDaBancada.size == 1) MotionEvent.ACTION_UP else MotionEvent.ACTION_POINTER_UP, dedo, agora, acao)
                dedosDaBancada.remove(dedo)
            }
            "cancelar" -> {
                if (dedosDaBancada.isEmpty()) return semDedo(acao, dedo)
                entregar(janela, MotionEvent.ACTION_CANCEL, dedo, agora, acao)
                dedosDaBancada.clear()
            }
            else -> Log.w(TAG, "bancada: segurar \"$acao\" desconhecido — use cima, baixo, cabecalho, inverter, soltar, fora ou cancelar")
        }
    }

    /** Roda [f] com a janela assentada e com foco (ver o `inverter` de [bancada]). */
    private fun depoisDoFoco(f: () -> Unit) {
        v.root.postDelayed({
            if (v.root.hasWindowFocus()) {
                f()
            } else {
                v.root.viewTreeObserver.addOnWindowFocusChangeListener(object : ViewTreeObserver.OnWindowFocusChangeListener {
                    override fun onWindowFocusChanged(temFoco: Boolean) {
                        if (!temFoco) return
                        v.root.viewTreeObserver.removeOnWindowFocusChangeListener(this)
                        f()
                    }
                })
            }
        }, ESPERA_DO_FOCO_MS)
    }

    private fun segurarOInverter(janela: View, dedo: Int) {
        if (dedosDaBancada.containsKey(dedo)) return
        val alvo = v.buttonInverterBotoes
        val agora = SystemClock.uptimeMillis()
        val xy = IntArray(2)
        alvo.getLocationInWindow(xy)
        val primeiro = dedosDaBancada.isEmpty()
        if (primeiro) inicioDoGesto = agora
        dedosDaBancada[dedo] = DedoDaBancada(dedo, alvo, xy[0] + alvo.width / 2f, xy[1] + alvo.height / 2f)
        entregar(janela, if (primeiro) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_POINTER_DOWN, dedo, agora, "inverter")
        v.root.postDelayed({
            if (dedosDaBancada[dedo]?.botao === alvo) {
                val tipo = if (dedosDaBancada.size == 1) MotionEvent.ACTION_UP else MotionEvent.ACTION_POINTER_UP
                entregar(janela, tipo, dedo, SystemClock.uptimeMillis(), "inverter, levantando")
                dedosDaBancada.remove(dedo)
            }
        }, ViewConfiguration.getLongPressTimeout() + 300L)
    }

    private fun semDedo(acao: String, dedo: Int) {
        Log.w(TAG, "bancada: segurar $acao — o dedo $dedo não está na tela")
    }

    private fun entregar(janela: View, tipo: Int, dedo: Int, agora: Long, acao: String) {
        val lista = dedosDaBancada.values.toList()
        val indice = lista.indexOfFirst { it.id == dedo }.coerceAtLeast(0)
        val propriedades = lista.map { d ->
            MotionEvent.PointerProperties().apply {
                id = d.id
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }.toTypedArray()
        val coordenadas = lista.map { d ->
            MotionEvent.PointerCoords().apply {
                x = d.x
                y = d.y
                pressure = 1f
                size = 1f
            }
        }.toTypedArray()
        val acaoCompleta = when (tipo) {
            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> tipo or (indice shl MotionEvent.ACTION_POINTER_INDEX_SHIFT)
            else -> tipo
        }
        val ev = MotionEvent.obtain(
            inicioDoGesto, agora, acaoCompleta, lista.size, propriedades, coordenadas,
            0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0,
        )
        Log.i(TAG, "bancada: segurar $acao (dedo $dedo) → ${MotionEvent.actionToString(acaoCompleta)} com ${lista.size} dedo(s), " +
            "em ${"%.0f".format(lista[indice].x)},${"%.0f".format(lista[indice].y)} na janela")
        janela.dispatchTouchEvent(ev)
        ev.recycle()
    }
}
