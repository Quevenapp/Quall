package com.quall.android.teleprompter

import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R
import com.quall.android.core.DeviceIdentity
import com.quall.android.core.QuallNative
import com.quall.android.core.QuallNative.Status
import com.quall.android.core.Textos
import org.json.JSONObject

/**
 * **O lado que controla**: conecta no prompter como `"controle_remoto"`, conduz a sessão e, quando
 * ela cai, **tenta de novo a cada ~1 s até entrar** — com o par já conhecido, sem PIN
 * (`docs/contrato-teleprompter.md` §2, passo 3). Enquanto o prompter não percebe a queda (até 5 s)
 * a volta ouve `QUALL_STATUS_BUSY`, que é "tente de novo", nunca queda.
 *
 * Mesma disciplina de [SessaoDoPrompter]: a tela só vê [Ouvinte] e chama [parar].
 */
class SessaoDoControle(
    private val eu: DeviceIdentity,
    private val replica: ReplicaDoTeleprompter,
    private val endpoint: String,
    /** O PIN digitado, ou `null` para retomar um par conhecido. Só vale para a primeira entrada. */
    private val pinDigitado: String?,
    /** Bancada: prende a sinalização e a mídia a uma interface. Vazio = todas (o produto). */
    private val prenderEm: String,
    private val ouvinte: Ouvinte,
    /** As frases das fases (avisos, erros), no idioma da tela que abriu a sessão. */
    private val t: Textos,
) {
    sealed class Fase {
        data class Conectando(val endpoint: String, val tentativa: Int) : Fase()
        data class Controlando(val par: String, val endpoint: String, val pareamentoNovo: Boolean) : Fase()

        /** A sessão caiu (ou o prompter está ocupado) e o controle insiste. */
        data class Reconectando(val endpoint: String, val aviso: String, val tentativa: Int) : Fase()

        data class PrecisaDePin(val endpoint: String, val mensagem: String) : Fase()
        data class Erro(val mensagem: String) : Fase()
        data object Parado : Fase()
    }

    interface Ouvinte {
        fun fase(f: Fase)
        fun mudou(bits: Int)
    }

    companion object {
        private const val TAG = "QuallTeleprompter"
    }

    @Volatile private var pararPedido = false
    private val trincoDoCancelador = Any()
    private var cancelador = 0L

    fun parar() {
        pararPedido = true
        synchronized(trincoDoCancelador) {
            if (cancelador != 0L) QuallNative.sessionCancel(cancelador)
        }
    }

    fun rodar() {
        if (!QuallNative.carregado) {
            ouvinte.fase(Fase.Erro(t.s(R.string.tp_erro_nucleo, QuallNative.erroDeCarga.orEmpty())))
            return
        }
        var pin = pinDigitado
        var jaConectou = false
        var tentativa = 0
        var terminouSemParado = false
        try {
            while (!pararPedido && !replica.fechada) {
                tentativa++
                if (!jaConectou) ouvinte.fase(Fase.Conectando(endpoint, tentativa))
                // Cancelar é irreversível: um cancelador por tentativa, e a tela só o vê enquanto
                // a chamada bloqueante está em curso (nunca um handle já liberado).
                val canc = QuallNative.cancellerNew()
                synchronized(trincoDoCancelador) { cancelador = canc }
                if (pararPedido) QuallNative.sessionCancel(canc)
                val sessao = QuallNative.connectWithRole(
                    endpoint = endpoint,
                    deviceId = eu.deviceId,
                    displayName = eu.displayName,
                    caps = 0,
                    pin = pin,
                    knownPeersJson = eu.knownPeersJson(),
                    timeoutMs = PoliticaDoControle.PRAZO_CONEXAO_MS,
                    cancellerHandle = canc,
                    bindAddress = prenderEm.ifBlank { null },
                    papel = QuallNative.PAPEL_CONTROLE_REMOTO,
                )
                val st = if (sessao == 0L) QuallNative.lastStatus() else Status.OK
                val motivo = if (sessao == 0L) QuallNative.lastError() else ""
                synchronized(trincoDoCancelador) { cancelador = 0L }
                QuallNative.cancellerFree(canc)

                if (sessao == 0L) {
                    if (pararPedido || st == Status.CANCELLED) break
                    when (val d = PoliticaDoControle.depoisDaFalha(st, jaConectou, motivo, endpoint, t)) {
                        is PoliticaDoControle.Depois.TentarDeNovo -> {
                            if (tentativa == 1 || tentativa % 10 == 0) {
                                Log.i(TAG, "controle: ${Status.nome(st)} (tentativa $tentativa): ${Log.erroExterno(motivo)}")
                            }
                            ouvinte.fase(Fase.Reconectando(endpoint, d.aviso, tentativa))
                            dormir(d.esperaMs)
                        }
                        is PoliticaDoControle.Depois.PedirPin -> {
                            Log.w(TAG, "controle: ${Status.nome(st)} — pedindo o PIN (${Log.erroExterno(motivo)})")
                            ouvinte.fase(Fase.PrecisaDePin(endpoint, d.mensagem))
                            terminouSemParado = true
                            return
                        }
                        is PoliticaDoControle.Depois.Desistir -> {
                            Log.w(TAG, "controle: ${Log.erroExterno(d.mensagem)}")
                            ouvinte.fase(Fase.Erro(d.mensagem))
                            terminouSemParado = true
                            return
                        }
                    }
                    continue
                }

                jaConectou = true
                // Daqui em diante o par é conhecido: a volta de uma queda entra sem PIN. Repetir o
                // PIN digitado faria um pareamento novo a cada queda — e o prompter sorteia outro
                // PIN depois de erro, então a volta passaria a falhar.
                pin = null
                val fim = conduzir(sessao)
                if (pararPedido || replica.fechada) break
                tentativa = 0
                ouvinte.fase(Fase.Reconectando(endpoint, avisoDaQueda(fim), 0))
                dormir(PoliticaDoControle.INTERVALO_MS)
            }
        } finally {
            replica.salvar()
            if (!terminouSemParado) ouvinte.fase(Fase.Parado)
        }
    }

    private fun avisoDaQueda(fim: Conducao.Fim): String = when (fim) {
        Conducao.Fim.O_OUTRO_SAIU -> t.s(R.string.tp_queda_o_outro_saiu)
        Conducao.Fim.FALHOU -> t.s(R.string.tp_queda_rede)
        else -> t.s(R.string.tp_tentando_reconectar)
    }

    private fun conduzir(sessao: Long): Conducao.Fim {
        val parJson = QuallNative.sessionPeerJson(sessao)
        val parNome = runCatching { JSONObject(parJson).optString("display_name") }
            .getOrNull()?.takeIf { it.isNotBlank() } ?: t.s(R.string.tp_par_teleprompter)
        val novo = QuallNative.sessionPairingIsNew(sessao)
        runCatching { QuallNative.sessionKnownPeersJson(sessao, eu.knownPeersJson()) }
            .getOrNull()
            ?.let { eu.saveKnownPeersJson(it) }
        Log.i(TAG, "controle: conectado (${if (novo) "pareado agora por PIN" else "pareamento retomado"}); " +
            "caminho ${QuallNative.sessionPathJson(sessao)}")
        ouvinte.fase(Fase.Controlando(parNome, endpoint, novo))

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
            val st = QuallNative.sessionClose(sessao)
            if (st != Status.OK) Log.w(TAG, "quall_session_close: ${Status.nome(st)}")
            if (mensagens != 0L) QuallNative.messagesFree(mensagens)
            replica.salvar()
            Log.i(TAG, "controle: a sessão acabou ($fim)")
        }
        return fim
    }

    private fun dormir(ms: Long) {
        val fim = SystemClock.elapsedRealtime() + ms
        while (!pararPedido && SystemClock.elapsedRealtime() < fim) Thread.sleep(50)
    }
}
