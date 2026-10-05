package com.quall.android.teleprompter

import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R
import com.quall.android.core.DeviceIdentity
import com.quall.android.core.EnderecosLocais
import com.quall.android.core.QuallNative
import com.quall.android.core.QuallNative.Status
import com.quall.android.core.Textos
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.ServerSocket

/**
 * **O lado que mostra o texto**: anuncia com o papel, espera o controle com PIN, conduz a sessão
 * e, quando ela cai, **volta a esperar na mesma porta e com o mesmo PIN** — com PIN novo só depois
 * de erro de PIN (`docs/contrato-teleprompter.md` §2, "Quando o controle cai").
 *
 * Roda inteira na thread de quem chama [rodar]. A tela só vê [Ouvinte] e chama [parar]; ela
 * **nunca** toca em handle de sessão nem de mensagens — a mesma disciplina de `ReceptorSessao`
 * (nunca chamar a fronteira com um id que possa estar morto). Quem a tela toca é a
 * [ReplicaDoTeleprompter], que é segura de qualquer thread.
 */
class SessaoDoPrompter(
    private val eu: DeviceIdentity,
    private val replica: ReplicaDoTeleprompter,
    /** A porta pedida: [EnderecoDoTeleprompter.PORTA_PADRAO] (7979), ou a da bancada. */
    private val portaPedida: Int,
    /** PIN dado pela bancada (`am start`), ou `null` para sortear. Erro de PIN troca de qualquer jeito. */
    private val pinDado: String?,
    private val anunciar: Boolean,
    private val ouvinte: Ouvinte,
    /** As frases das fases (o erro, a última recusa), no idioma da tela que abriu a sessão. */
    private val t: Textos,
) {
    sealed class Fase {
        data class Esperando(
            val pin: String,
            val enderecos: List<String>,
            val anunciando: Boolean,
            /** A recusa anterior (PIN errado, versão), para a tela dizer por que o PIN mudou. */
            val ultimaRecusa: String?,
            val tentativa: Int,
        ) : Fase()

        data class ComControle(
            val par: String,
            val pareamentoNovo: Boolean,
            val pin: String,
            val enderecos: List<String>,
        ) : Fase()

        data class Erro(val mensagem: String) : Fase()
        data object Parado : Fase()
    }

    interface Ouvinte {
        /** Na thread da sessão. */
        fun fase(f: Fase)

        /** Bits de [QuallNative.MudouNoTeleprompter], na thread da sessão. */
        fun mudou(bits: Int)
    }

    companion object {
        private const val TAG = "QuallTeleprompter"

        /** Quanto a porta pedida tem para ficar livre antes de o prompter ir para a próxima. */
        private const val TOLERANCIA_DA_PORTA_MS = 2_000L
    }

    @Volatile private var pararPedido = false
    private val trincoDoCancelador = Any()
    private var cancelador = 0L

    /** Qualquer thread. Acorda a espera pelo cancelador; a condução para na próxima volta (≤ 100 ms). */
    fun parar() {
        pararPedido = true
        synchronized(trincoDoCancelador) {
            if (cancelador != 0L) QuallNative.sessionCancel(cancelador)
        }
    }

    /**
     * A porta em que esta tela hospeda **de verdade**: a pedida (7979 por padrão), ou a próxima
     * livre se ela estiver ocupada ([EnderecoDoTeleprompter.escolherPorta]). Escolhida uma vez, no
     * começo, e mantida a vida inteira da tela: depois de uma queda o prompter volta **na mesma
     * porta**, e o controle que caiu a reencontra (§2).
     */
    @Volatile var porta: Int = portaPedida
        private set

    fun rodar() {
        if (!QuallNative.carregado) {
            ouvinte.fase(Fase.Erro(t.s(R.string.tp_erro_nucleo, QuallNative.erroDeCarga.orEmpty())))
            return
        }
        // A pedida ganha uma tolerância antes de se passar à próxima: numa recriação da tela, a
        // sessão da tela velha ainda segura a porta enquanto fecha (uma bombeada, ~100–300 ms), e
        // sem a espera a tela nova iria para a 7980 — e o controle que caiu não a acharia mais.
        porta = EnderecoDoTeleprompter.escolherPorta(portaPedida) { p ->
            if (p == portaPedida) esperarLivre(p, TOLERANCIA_DA_PORTA_MS) else portaLivre(p)
        }
        if (porta != portaPedida) {
            Log.w(TAG, "prompter: a porta $portaPedida está ocupada — hospedando na $porta (a tela mostra)")
        }
        // O anúncio vive a tela inteira (a porta não muda entre sessões). Sem papel de fonte: um
        // prompter não emite vídeo, e o Windows o esconde da lista dele por isso (§2).
        val anunciante = if (anunciar) {
            QuallNative.advertiserStartWithRole(eu.deviceId, eu.displayName, 0, porta, QuallNative.PAPEL_TELEPROMPTER)
        } else {
            0L
        }
        if (anunciar && anunciante == 0L) {
            Log.w(TAG, "anúncio mDNS não subiu status=${QuallNative.lastStatus()}: ${Log.erroExterno(QuallNative.lastError())} — só o endereço digitado vai funcionar")
        }
        val canc = QuallNative.cancellerNew()
        synchronized(trincoDoCancelador) { cancelador = canc }

        var pin = pinDado?.takeIf { it.length == 6 && it.all(Char::isDigit) } ?: QuallNative.generatePin()
        var falhasImediatas = 0
        var ultimaRecusa: String? = null
        var tentativa = 0
        var desistiu = false
        val enderecos = enderecosLocais().map { EnderecosLocais.comPorta(it, porta) }
        try {
            while (!pararPedido && !replica.fechada) {
                tentativa++
                ouvinte.fase(Fase.Esperando(pin, enderecos, anunciante != 0L, ultimaRecusa, tentativa))
                Log.i(TAG, "prompter: esperando o controle na porta $porta (tentativa $tentativa, PIN ${if (pinDado != null) "da bancada" else "sorteado"})")
                val comecou = SystemClock.elapsedRealtime()
                val sessao = QuallNative.hostWithRole(
                    deviceId = eu.deviceId,
                    displayName = eu.displayName,
                    caps = 0,
                    pin = pin,
                    knownPeersJson = eu.knownPeersJson(),
                    porta = porta,
                    timeoutMs = PoliticaDoPrompter.ESPERA_MS,
                    cancellerHandle = canc,
                    papel = QuallNative.PAPEL_TELEPROMPTER,
                )
                val decorrido = SystemClock.elapsedRealtime() - comecou
                if (sessao == 0L) {
                    // Os dois são por thread, e esta é a thread que falhou.
                    val st = QuallNative.lastStatus()
                    val motivo = QuallNative.lastError()
                    if (pararPedido || st == Status.CANCELLED) break
                    when (val d = PoliticaDoPrompter.depoisDaEspera(st, decorrido, falhasImediatas, motivo, porta, t)) {
                        is PoliticaDoPrompter.Depois.PinNovo -> {
                            // §2: depois de erro de PIN numa espera, o PIN é trocado — repeti-lo
                            // abriria força bruta online.
                            pin = QuallNative.generatePin()
                            ultimaRecusa = t.s(R.string.tp_recusa_pin_mudou, Status.nome(st))
                            falhasImediatas = 0
                            Log.w(TAG, "prompter: ${Status.nome(st)} — PIN trocado (${Log.erroExterno(motivo)})")
                            dormir(d.pausaMs)
                        }
                        is PoliticaDoPrompter.Depois.MesmoPin -> {
                            if (d.falhaDaPorta) {
                                falhasImediatas++
                                Log.w(TAG, "prompter: a porta falhou em ${decorrido} ms (${Status.nome(st)}): ${Log.erroExterno(motivo)}")
                            } else {
                                falhasImediatas = 0
                                if (st != Status.TIMEOUT) {
                                    ultimaRecusa = motivo
                                    Log.w(TAG, "prompter: a espera voltou sem sessão em ${decorrido} ms (${Status.nome(st)}): ${Log.erroExterno(motivo)}")
                                }
                            }
                            dormir(d.pausaMs)
                        }
                        is PoliticaDoPrompter.Depois.Desistir -> {
                            Log.e(TAG, "prompter: ${Log.erroExterno(d.mensagem)}")
                            ouvinte.fase(Fase.Erro(d.mensagem))
                            desistiu = true
                            return
                        }
                    }
                    continue
                }
                falhasImediatas = 0
                ultimaRecusa = null
                conduzir(sessao, pin, enderecos)
            }
        } finally {
            synchronized(trincoDoCancelador) { cancelador = 0L }
            QuallNative.cancellerFree(canc)
            if (anunciante != 0L) QuallNative.advertiserStop(anunciante)
            replica.salvar()
            // Depois de um erro a tela fica com a frase do erro; "parado" a apagaria.
            if (!desistiu) ouvinte.fase(Fase.Parado)
        }
    }

    private fun conduzir(sessao: Long, pin: String, enderecos: List<String>) {
        val parJson = QuallNative.sessionPeerJson(sessao)
        val parNome = runCatching { JSONObject(parJson).optString("display_name") }
            .getOrNull()?.takeIf { it.isNotBlank() } ?: t.s(R.string.tp_par_controle)
        val novo = QuallNative.sessionPairingIsNew(sessao)
        // Persistido assim que a sessão sobe: o controle que cair volta sem PIN.
        runCatching { QuallNative.sessionKnownPeersJson(sessao, eu.knownPeersJson()) }
            .getOrNull()
            ?.let { eu.saveKnownPeersJson(it) }
        Log.i(TAG, "prompter: controle entrou (${if (novo) "pareado agora por PIN" else "pareamento retomado"}); " +
            "caminho ${QuallNative.sessionPathJson(sessao)}")
        ouvinte.fase(Fase.ComControle(parNome, novo, pin, enderecos))

        val mensagens = QuallNative.sessionMessages(sessao)
        var fim = Conducao.Fim.FALHOU
        try {
            if (mensagens == 0L) {
                Log.e(TAG, "quall_session_messages falhou status=${QuallNative.lastStatus()}: ${Log.erroExterno(QuallNative.lastError())}")
                replica.perdeuOPar(IntArray(1))
            } else {
                fim = Conducao(replica, ouvinte::mudou, { pararPedido }, TAG).conduzir(sessao, mensagens)
            }
        } finally {
            // Passo 3 do contrato: fechar a sessão velha **antes** de hospedar de novo — é o
            // fechamento que solta a porta. O handle das mensagens sobrevive ao fechamento e é
            // liberado depois dele.
            val st = QuallNative.sessionClose(sessao)
            if (st != Status.OK) Log.w(TAG, "quall_session_close: ${Status.nome(st)}")
            if (mensagens != 0L) QuallNative.messagesFree(mensagens)
            replica.salvar()
            val e = replica.estado()
            Log.i(TAG, "prompter: a sessão acabou ($fim); rolando=${e?.rolando} posição=${e?.posicao} — " +
                if (pararPedido) "parando" else "voltando a esperar na porta $porta com o mesmo PIN")
        }
    }

    private fun dormir(ms: Long) {
        val fim = SystemClock.elapsedRealtime() + ms
        while (!pararPedido && SystemClock.elapsedRealtime() < fim) Thread.sleep(50)
    }

    /**
     * A porta está livre? Um `bind` de teste com `SO_REUSEADDR` — o mesmo que o núcleo liga no
     * Unix: passa por cima de uma conexão em `TIME_WAIT`, e falha diante de alguém **escutando**
     * nela (o espelhamento de outro app, outra tela do Quall).
     */
    private fun portaLivre(p: Int): Boolean = runCatching {
        ServerSocket().use { s ->
            s.reuseAddress = true
            s.bind(InetSocketAddress(p))
        }
        true
    }.getOrDefault(false)

    /** A porta fica livre dentro de `ms`? Testa a cada 100 ms (e desiste se a tela pedir para parar). */
    private fun esperarLivre(p: Int, ms: Long): Boolean {
        val fim = SystemClock.elapsedRealtime() + ms
        while (true) {
            if (portaLivre(p)) return true
            if (pararPedido || SystemClock.elapsedRealtime() >= fim) return false
            Thread.sleep(100)
        }
    }

    /** A mesma escolha IPv4/IPv6 da espera de Espelhar e da linha de rede da tela. */
    private fun enderecosLocais(): List<String> = EnderecosLocais.listar().map { it.ip }
}
