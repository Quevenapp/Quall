package com.quall.android.ui

import com.quall.android.core.LogSeguro as Log
import android.view.View
import android.widget.TextView
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.core.QuallNative
import com.quall.android.databinding.PerguntaDoTextoBinding
import com.quall.android.teleprompter.CaixaDaPergunta
import com.quall.android.teleprompter.CaixaDaPergunta.Caixa
import com.quall.android.teleprompter.EstadoDoTeleprompter
import com.quall.android.teleprompter.EstadoDoTeleprompter.VistaDoTexto
import com.quall.android.teleprompter.ReplicaDoTeleprompter
import com.quall.android.teleprompter.Resumo

/**
 * **A caixa da pergunta do texto na tela do controle** (`docs/contrato-teleprompter.md` §11.7): o
 * que ela mostra vem de [CaixaDaPergunta] (sem Android); aqui ficam a camada, os dois botões e a
 * bancada.
 *
 * - A escolha leva o `"resumo"` de `"do_prompter"` **que a caixa mostrou** ([Caixa.Perguntando.resumoMostrado]),
 *   nunca um relido na hora do toque: se o texto do prompter mudou, o núcleo responde `BUSY`, e a caixa
 *   diz que mudou e já mostra o novo.
 * - Os tamanhos ("{n} palavras") são do texto inteiro — o do prompter por `question_text`, o daqui
 *   por `text` —, contados uma vez por resumo.
 * - Só aparece com o painel da sessão à mostra: desconectado de propósito, a pergunta não fica na
 *   tela de escolher o prompter (ela volta na próxima conexão). O voltar, com ela aberta, desconecta.
 * - "Conferindo o roteiro do prompter…" **não cobre a tela**: é uma faixa que não pega toque
 *   ([faixaDoConferindo]) — com o texto retido, rolar, pausar e o resto seguem valendo (§11.3).
 */
internal class TelaDaPergunta(
    private val v: PerguntaDoTextoBinding,
    private val faixaDoConferindo: TextView,
    private val replica: ReplicaDoTeleprompter,
    /** Depois de cada escolha, com o status e o que se escolheu: com `OK`, quem chama grava o salvo (§11.5). */
    private val aoEscolher: (status: Int, manterOMeu: Boolean) -> Unit,
) {
    companion object {
        private const val TAG = "QuallTeleprompter"
    }

    private var caixa: Caixa = Caixa.Escondida

    /** O status da última escolha que não deu `OK`, enquanto a mesma pergunta estiver aberta. */
    private var ultimoStatus: Int? = null

    /** Bancada: a escolha que espera a pergunta abrir (`true` = "Mandar o meu"). */
    private var escolhaDaBancada: Boolean? = null

    private val palavrasPorResumo = HashMap<String, Int>()

    /** As frases da caixa, no idioma da tela (a tela é recriada quando o idioma muda). */
    private val t = Idioma.textos(v.root.context)

    val visivel: Boolean get() = v.root.visibility == View.VISIBLE

    init {
        v.buttonUsarODoPrompter.setOnClickListener { responder(manterOMeu = false) }
        v.buttonMandarOMeu.setOnClickListener { responder(manterOMeu = true) }
    }

    /** A cada desenho da tela do controle (os bits e o tique de 250 ms). */
    fun desenhar(e: EstadoDoTeleprompter, mostrarCaixa: Boolean) {
        val p = e.perguntaDoTexto
        if (p == null || !p.aberta) ultimoStatus = null
        // `CLOSED` quer dizer "sem sessão": com o prompter visto de novo, ele não vale mais.
        if (ultimoStatus == QuallNative.Status.CLOSED && e.parVistoHaMs != null) ultimoStatus = null
        val nova = if (mostrarCaixa) CaixaDaPergunta.caixa(p, e.parVistoHaMs != null, ultimoStatus, t) else Caixa.Escondida
        if (nova != caixa) registrar(nova)
        caixa = nova
        mostrar(nova)
        val escolha = escolhaDaBancada
        if (escolha != null && nova is Caixa.Perguntando && nova.botoesLigados) {
            Log.i(TAG, "bancada: a pergunta abriu — respondendo \"${if (escolha) "Mandar o meu" else "Usar o do prompter"}\" pelo botão")
            (if (escolha) v.buttonMandarOMeu else v.buttonUsarODoPrompter).performClick()
            // Só sai da espera com `OK`: com `BUSY` (a caixa se atualiza com o bit) ou `CLOSED`, a
            // bancada responde de novo quando a caixa voltar a aceitar.
            if (ultimoStatus == null) escolhaDaBancada = null
        }
    }

    /** Bancada (`--es escolha prompter|meu|nenhuma`): responde pelo mesmo botão quando a pergunta abrir. */
    fun escolherPelaBancada(valor: String) {
        escolhaDaBancada = when (valor) {
            "meu" -> true
            "prompter" -> false
            else -> null
        }
        Log.i(TAG, "bancada: escolha da pergunta = $valor" + if (escolhaDaBancada == null) " (a caixa espera o dedo)" else "")
    }

    /**
     * A escolha da bancada vale para a sessão em que foi dada: caída a sessão sem a pergunta ter
     * aberto, ela não fica esperando para responder, sem ninguém pedir, uma pergunta de outra vez.
     */
    fun esquecerEscolhaDaBancada() {
        if (escolhaDaBancada == null) return
        escolhaDaBancada = null
        Log.i(TAG, "bancada: a sessão acabou sem a pergunta abrir — a escolha da bancada foi esquecida")
    }

    private fun responder(manterOMeu: Boolean) {
        val c = caixa as? Caixa.Perguntando ?: return
        if (!c.botoesLigados) return
        val st = replica.resolverTexto(manterOMeu, c.resumoMostrado)
        ultimoStatus = if (st == QuallNative.Status.OK) null else st
        Log.i(TAG, "controle: pergunta do texto — \"${if (manterOMeu) "Mandar o meu" else "Usar o do prompter"}\" " +
            "(resumo mostrado ${c.resumoMostrado}) → ${QuallNative.Status.nome(st)}")
        aoEscolher(st, manterOMeu)
    }

    private fun registrar(c: Caixa) {
        when (c) {
            Caixa.Escondida -> Log.i(TAG, "controle: pergunta do texto — caixa escondida")
            Caixa.Conferindo -> Log.i(TAG, "controle: pergunta do texto — conferindo o roteiro do prompter")
            is Caixa.Perguntando -> Log.i(TAG, "controle: pergunta do texto — ${c.titulo} Do prompter ${c.doPrompter.bytes} B " +
                "(resumo ${c.doPrompter.resumo}), daqui ${c.meu.bytes} B (resumo ${c.meu.resumo}); " +
                "botões ${if (c.botoesLigados) "ligados" else "desligados"}" + (c.aviso?.let { " — $it" } ?: ""))
        }
    }

    private fun mostrar(c: Caixa) {
        faixaDoConferindo.seMudou(t.s(R.string.tp_conferindo))
        faixaDoConferindo.visibility = if (c == Caixa.Conferindo) View.VISIBLE else View.GONE
        when (c) {
            Caixa.Escondida, Caixa.Conferindo -> {
                v.root.visibility = View.GONE
                return
            }
            is Caixa.Perguntando -> {
                v.textPerguntaTitulo.seMudou(c.titulo)
                v.textPerguntaAviso.seMudou(c.aviso.orEmpty())
                v.textPerguntaAviso.visibility = if (c.aviso == null) View.GONE else View.VISIBLE
                v.blocosDaPergunta.visibility = View.VISIBLE
                v.botoesDaPergunta.visibility = View.VISIBLE
                v.textPerguntaGuardado.visibility = View.VISIBLE
                v.textPalavrasDoPrompter.seMudou(CaixaDaPergunta.palavras(palavras(c.doPrompter) { replica.textoDaPergunta() }, t))
                v.textPalavrasDaqui.seMudou(CaixaDaPergunta.palavras(palavras(c.meu) { replica.texto() }, t))
                v.textPreviaDoPrompter.seMudou(previa(c.doPrompter))
                v.textPreviaDaqui.seMudou(previa(c.meu))
                v.buttonUsarODoPrompter.isEnabled = c.botoesLigados
                v.buttonMandarOMeu.isEnabled = c.botoesLigados
            }
        }
        v.root.visibility = View.VISIBLE
    }

    /**
     * As palavras do texto inteiro, lido uma vez por resumo (até 128 KiB pela fronteira). O texto é
     * lido numa chamada à parte do estado: só entra na conta guardada se o resumo dele for o da caixa,
     * e uma leitura que falhou não fica guardada como "0 palavras".
     */
    private fun palavras(vista: VistaDoTexto, ler: () -> String?): Int {
        palavrasPorResumo[vista.resumo]?.let { return it }
        val texto = ler() ?: return 0
        val n = CaixaDaPergunta.contar(texto)
        if (Resumo.de(texto) == vista.resumo) {
            if (palavrasPorResumo.size > 16) palavrasPorResumo.clear()
            palavrasPorResumo[vista.resumo] = n
        }
        return n
    }

    /** A prévia (até 240 bytes), com reticências quando o texto é maior que ela. */
    private fun previa(vista: VistaDoTexto): String {
        val cortada = vista.previa.toByteArray(Charsets.UTF_8).size < vista.bytes
        return vista.previa.trimEnd() + if (cortada) "…" else ""
    }
}
