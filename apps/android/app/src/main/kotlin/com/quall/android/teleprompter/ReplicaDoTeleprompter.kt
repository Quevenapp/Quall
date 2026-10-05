package com.quall.android.teleprompter

import android.content.Context
import com.quall.android.core.LogSeguro as Log
import com.quall.android.core.QuallNative
import java.io.File
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * **A réplica do estado do teleprompter deste aparelho** — o `QuallTeleprompter*` do núcleo, com a
 * vida dele cuidada aqui.
 *
 * ## Três threads tocam nela, e nenhuma pode tocar num ponteiro morto
 *
 * A tela edita (`set_*`, da thread principal), a sessão bombeia (da thread dela, em laço) e alguém
 * a libera no fim. O núcleo é seguro entre as duas primeiras (`Teleprompter` é `Sync`); o que ele
 * não pode garantir é o **fim**: `quall_teleprompter_free` com a bombeada dentro seria uso depois de
 * liberar — a regra do projeto é nunca chamar a fronteira com um id que possa estar morto.
 *
 * Por isso toda chamada passa por uma **trava de leitura** (várias ao mesmo tempo: a tela edita
 * enquanto a sessão bombeia) e [fechar] pega a **de escrita**: ele espera quem está dentro sair (no
 * máximo o prazo de uma bombeada, 100 ms), salva, libera e zera o ponteiro. Quem chega depois
 * recebe um valor de falta, nunca um ponteiro morto.
 *
 * ## Persistência
 *
 * `quall_teleprompter_saved_json` (até ~260 KiB, o texto domina) vai para um arquivo em `filesDir`
 * — e não para `SharedPreferences`, que regrava o XML inteiro a cada `apply`. Salva-se quando a
 * tela vai para o segundo plano, ao fim de cada sessão e ao fechar (§3, "Persistência"). Gravação
 * atômica: arquivo temporário e `rename`, para uma morte do processo no meio não deixar meio JSON —
 * que o núcleo recusaria inteiro, perdendo o roteiro.
 */
class ReplicaDoTeleprompter private constructor(
    handle: Long,
    /** `"teleprompter"` ou `"controle_remoto"`. */
    val papel: String,
    private val arquivo: File,
) {
    private val trava = ReentrantReadWriteLock()
    private var handle: Long = handle

    /** Já foi fechada: toda chamada devolve o valor de falta. */
    val fechada: Boolean get() = trava.read { handle == 0L }

    private inline fun <T> comHandle(semHandle: T, f: (Long) -> T): T = trava.read {
        val h = handle
        if (h == 0L) semHandle else f(h)
    }

    // --- edições: qualquer thread, saem na hora ---------------------------------------------

    /** Ao **confirmar** a edição (§6). Devolve o `QuallStatus`: [QuallNative.Status.INVALID] acima do teto. */
    fun definirTexto(texto: String): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterSetText(it, texto) }

    fun definirRolando(v: Boolean): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterSetScrolling(it, v) }

    // --- a pergunta do texto e as cópias (§11) ------------------------------------------------

    /**
     * **Só a réplica do controle**, com a tela da pergunta de pé (§11.10). O salvo é um só para os
     * dois papéis (§11.2): a do prompter nunca liga, e a trava não vai no salvo.
     */
    fun ligarPerguntaDoTexto(): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterEnableTextQuestion(it) }

    /** A escolha, com o resumo **que a caixa mostrou** (§11.4). Grave o salvo quando der `OK`. */
    fun resolverTexto(manterOMeu: Boolean, resumoVisto: String): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterResolveText(it, manterOMeu, resumoVisto) }

    /** O texto do prompter na pergunta aberta; `null` sem pergunta. */
    fun textoDaPergunta(): String? = comHandle(null) { QuallNative.teleprompterQuestionText(it) }

    /** O texto inteiro de uma cópia guardada; `null` se ela saiu da lista. */
    fun copiaDoTexto(resumo: String): String? = comHandle(null) { QuallNative.teleprompterTextCopy(it, resumo) }

    fun esquecerCopiaDoTexto(resumo: String): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterForgetTextCopy(it, resumo) }

    // --- "Segurar para rolar" (§12) ----------------------------------------------------------

    /** **O prompter**, ao abrir — só porque a tela dele rola para trás e para quando `rolando` cai. */
    fun ligarSegurar(): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterEnableHold(it) }

    /** **O controle**, ao encostar o dedo. [QuallNative.Status.PROTOCOL]: o prompter não entende. */
    fun segurar(paraTras: Boolean): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterHold(it, paraTras) }

    /** **O controle**, ao tirar o dedo (ou sair do botão, ou ir para o segundo plano). */
    fun soltar(): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterRelease(it) }

    fun definirVelocidade(v: Double): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterSetSpeed(it, v) }

    fun definirFonte(v: Double): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterSetFontSize(it, v) }

    fun definirMargem(v: Double): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterSetMargin(it, v) }

    fun definirLinhaDeLeitura(v: Double): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterSetReadingLine(it, v) }

    fun definirEspelho(v: Boolean): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterSetMirror(it, v) }

    /** **Só o prompter.** A cada quadro, se quiser: o núcleo limita o envio a 4 Hz. */
    fun definirPosicao(v: Double): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterSetPosition(it, v) }

    fun saltar(v: Double): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterJump(it, v) }

    fun pular(delta: Double): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterJumpBy(it, delta) }

    // --- gravar pelo controle (§13) ------------------------------------------------------------

    /** **O prompter da tela com câmera**, ao abrir (`true`) e ao fechar (`false`): o estado dele diz que grava. */
    fun ligarGravacao(ligada: Boolean): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterEnableRecording(it, ligada) }

    /**
     * **O prompter**, quando o arquivo de fato começou (`true`) ou fechou (`false`) — pelo botão, pelo
     * pedido do controle, por pouco espaço, pela câmera caída. Com um pedido aberto do mesmo valor,
     * é a resposta que o aceita.
     */
    fun definirGravando(gravando: Boolean): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterSetRecording(it, gravando) }

    /** **O prompter** recusa o pedido aberto [n] com o motivo legível. `BUSY`: outro pedido o substituiu. */
    fun recusarGravacao(n: Long, motivo: String): Int =
        comHandle(QuallNative.Status.CLOSED) { QuallNative.teleprompterRefuseRecording(it, n, motivo) }

    /** **O controle** pede que grave (`true`) ou que pare. `PROTOCOL`: o prompter não grava. */
    fun pedirGravacao(gravar: Boolean): Int =
        comHandle(QuallNative.Status.CLOSED) {
            if (gravar) QuallNative.teleprompterRequestRecord(it) else QuallNative.teleprompterRequestStop(it)
        }

    // --- a sessão -----------------------------------------------------------------------------

    /**
     * A bombeada, da thread da sessão. Sem réplica (já fechada) devolve
     * [QuallNative.Status.NULL_POINTER] — diferente de [QuallNative.Status.CLOSED], que é o fim da
     * **sessão** e vem com `mudou[0]` preenchido.
     */
    fun bombear(mensagens: Long, prazoMs: Int, mudou: IntArray): Int {
        mudou[0] = 0
        return comHandle(QuallNative.Status.NULL_POINTER) {
            QuallNative.teleprompterPump(it, mensagens, prazoMs, mudou)
        }
    }

    fun perdeuOPar(mudou: IntArray): Int {
        mudou[0] = 0
        return comHandle(QuallNative.Status.NULL_POINTER) { QuallNative.teleprompterPeerLost(it, mudou) }
    }

    // --- leitura --------------------------------------------------------------------------------

    fun estado(): EstadoDoTeleprompter? =
        comHandle(null) { EstadoDoTeleprompter.ler(QuallNative.teleprompterStateJson(it)) }

    /** O roteiro, ou `null` se não deu para ler (réplica fechada, falha da fronteira) — nunca `""` por engano. */
    fun texto(): String? = comHandle(null) { QuallNative.teleprompterText(it) }

    // --- vida -----------------------------------------------------------------------------------

    /** Grava o salvo. Qualquer thread; o arquivo é escrito de uma vez só (temporário + `rename`). */
    fun salvar() {
        val json = comHandle("") { QuallNative.teleprompterSavedJson(it) }
        if (json.isNotBlank()) gravar(arquivo, json)
    }

    /**
     * Grava o salvo **fora da thread da tela e em ordem**: uma fila de uma thread só, e cada tarefa
     * tira a foto e grava. Com uma thread por gravação, uma foto mais velha podia gravar por cima de
     * uma mais nova — e em volta de cada escolha da pergunta do texto saem duas ou três (revisão de
     * 14/09). Depois de [fechar], a tarefa não acha a réplica e não grava nada.
     */
    fun salvarEmOrdem(depois: (() -> Unit)? = null) {
        gravador.execute {
            salvar()
            depois?.invoke()
        }
    }

    private val gravador = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "quall-salvo-$papel").apply { isDaemon = true }
    }

    /**
     * Salva, libera e zera. Espera quem estiver dentro sair (a trava de escrita). Idempotente.
     * Chame fora da thread principal quando puder: salvar escreve até ~260 KiB.
     */
    fun fechar() {
        trava.write {
            val h = handle
            if (h == 0L) return
            val json = QuallNative.teleprompterSavedJson(h)
            if (json.isNotBlank()) gravar(arquivo, json)
            QuallNative.teleprompterFree(h)
            handle = 0L
        }
        Log.i(TAG, "réplica ($papel) salva e liberada")
    }

    companion object {
        private const val TAG = "QuallTeleprompter"

        /** O salvo, em `filesDir`. Um arquivo só para os dois papéis: o roteiro acompanha o aparelho. */
        const val ARQUIVO = "teleprompter.json"

        private val trincoDoArquivo = Any()

        private fun gravar(arquivo: File, json: String) = synchronized(trincoDoArquivo) {
            runCatching {
                val tmp = File(arquivo.parentFile, arquivo.name + ".tmp")
                tmp.writeText(json, Charsets.UTF_8)
                if (!tmp.renameTo(arquivo)) {
                    arquivo.writeText(json, Charsets.UTF_8)
                    tmp.delete()
                }
            }.onFailure { Log.w(TAG, "não consegui salvar o teleprompter: ${Log.erroExterno(it.message)}") }
        }

        /**
         * Cria a réplica com o papel e o salvo da vida anterior. Salvo ilegível ou de outra versão:
         * o núcleo devolve nulo com [QuallNative.Status.INVALID], e a réplica nasce do padrão (§3).
         * Chame da thread que vai ler [QuallNative.lastError] (o erro é por thread).
         */
        internal fun criar(context: Context, autor: String, papel: String): ReplicaDoTeleprompter? {
            if (!QuallNative.carregado) return null
            val arquivo = File(context.filesDir, ARQUIVO)
            val salvo = synchronized(trincoDoArquivo) {
                runCatching { arquivo.takeIf { it.exists() }?.readText(Charsets.UTF_8) }.getOrNull()
            }?.takeIf { it.isNotBlank() }
            var h = QuallNative.teleprompterNew(autor, papel, salvo)
            if (h == 0L && salvo != null) {
                // O salvo recusado (outra versão, depois de instalar uma build mais antiga; ou
                // ilegível) vai para o lado **antes** de a réplica nova nascer do padrão: o
                // próximo `salvar` gravaria por cima, e o roteiro se perderia de vez (achado da
                // revisão de 13/09). Uma build que o leia pode recuperá-lo.
                val deLado = File(arquivo.parentFile, "$ARQUIVO.recusado")
                val guardou = synchronized(trincoDoArquivo) { runCatching { arquivo.renameTo(deLado) }.getOrDefault(false) }
                Log.w(TAG, "salvo do teleprompter recusado (${Log.erroExterno(QuallNative.lastError())}); " +
                    (if (guardou) "guardado em ${deLado.name}; " else "não consegui guardá-lo de lado; ") +
                    "começando do padrão")
                h = QuallNative.teleprompterNew(autor, papel, null)
            }
            if (h == 0L) {
                Log.e(TAG, "quall_teleprompter_new falhou status=${QuallNative.lastStatus()}: ${Log.erroExterno(QuallNative.lastError())}")
                return null
            }
            return ReplicaDoTeleprompter(h, papel, arquivo)
        }
    }
}

/**
 * **Uma réplica por aparelho, que vive mais que a sessão** (§3) — e mais que uma recriação da tela.
 *
 * A tela pede a réplica ao abrir e a solta ao fechar. Se uma tela nova do mesmo papel pede antes de
 * a velha soltar (recriação da Activity), recebe **a mesma**: nada de ida e volta pelo arquivo, e
 * nada de dois ponteiros para o mesmo roteiro. Trocar de papel (fechar o prompter e abrir o
 * controle) fecha a réplica velha — salvando — e cria a nova a partir do salvo: o roteiro
 * acompanha o aparelho.
 */
object Replicas {
    private var atual: ReplicaDoTeleprompter? = null
    private var usos = 0

    /**
     * Há tela do teleprompter de pé (ou saindo, até soltar a réplica). Só de leitura, para a folha de
     * Ajustes: uma sessão do prompter ou do controle grava os pares ao terminar, e "Esquecer aparelhos
     * pareados" com ela de pé sairia sem efeito.
     */
    val emUso: Boolean
        @Synchronized get() = usos > 0

    @Synchronized
    fun obter(context: Context, autor: String, papel: String): ReplicaDoTeleprompter? {
        val r = atual
        if (r != null && r.papel == papel && !r.fechada) {
            usos++
            return r
        }
        if (r != null) {
            r.fechar()
            atual = null
            usos = 0
        }
        val nova = ReplicaDoTeleprompter.criar(context.applicationContext, autor, papel) ?: return null
        atual = nova
        usos = 1
        return nova
    }

    /** A tela terminou com ela. A última a soltar fecha (salva e libera). */
    @Synchronized
    fun soltar(r: ReplicaDoTeleprompter) {
        if (r !== atual) {
            r.fechar()
            return
        }
        usos--
        if (usos <= 0) {
            r.fechar()
            atual = null
            usos = 0
        }
    }
}
