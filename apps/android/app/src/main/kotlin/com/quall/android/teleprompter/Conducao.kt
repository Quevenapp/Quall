package com.quall.android.teleprompter

import com.quall.android.core.LogSeguro as Log
import com.quall.android.core.QuallNative
import com.quall.android.core.QuallNative.MudouNoTeleprompter
import com.quall.android.core.QuallNative.SessionEvent
import com.quall.android.core.QuallNative.Status

/**
 * **Uma sessão de pé, do primeiro instante até a queda** — o laço que os dois lados rodam igual.
 *
 * `docs/contrato-teleprompter.md` §6, "Threads e laço": a bombeada em laço na thread da sessão,
 * com prazo de 100 ms, **junto com `quall_session_next_event(s, 0)`** — é este que diz que o outro
 * lado saiu. E o fim da sessão **nesta ordem**:
 *
 * 1. `QUALL_STATUS_CLOSED` da bombeada vem **com `changed` preenchido** (a última mensagem do outro
 *    lado já fundida) — aplica-se. Se a queda chegou pelo **evento**, antes faz-se **uma bombeada
 *    final com prazo zero**, e aplica-se o `changed` dela: é onde entra a pausa tocada logo antes
 *    da queda, que até a revisão de 13/09 se perdia;
 * 2. só então `quall_teleprompter_peer_lost` — aqui, dentro de [conduzir];
 * 3. `quall_session_close` na sessão velha — em quem chama, logo depois (é o que solta a porta);
 * 4. no prompter, hospedar de novo — em quem chama.
 *
 * Os bits vão para [aoMudar] **na thread da sessão**; quem desenha os leva para a thread da tela.
 */
internal class Conducao(
    private val replica: ReplicaDoTeleprompter,
    private val aoMudar: (Int) -> Unit,
    private val deveParar: () -> Boolean,
    private val tag: String,
) {
    enum class Fim {
        /** A tela pediu para parar. */
        PARADO,

        /** O outro lado saiu (`DISCONNECTED`), ou a bombeada viu o canal fechar (`CLOSED`). */
        O_OUTRO_SAIU,

        /** O transporte falhou (`FAILED`), ou a bombeada devolveu um erro que não é o fim. */
        FALHOU,

        /** A réplica foi fechada por baixo (a tela saiu): não há mais o que bombear. */
        REPLICA_FECHADA,
    }

    companion object {
        /** §6: "no máximo 250 (50 a 100 é o recomendado)". */
        const val PRAZO_DA_BOMBEADA_MS = 100
    }

    fun conduzir(sessao: Long, mensagens: Long): Fim {
        val mudou = IntArray(1)
        var fim = Fim.FALHOU
        try {
            while (true) {
                if (deveParar()) {
                    fim = Fim.PARADO
                    break
                }
                val st = replica.bombear(mensagens, PRAZO_DA_BOMBEADA_MS, mudou)
                // Passo 1: o `changed` vale **também** na bombeada que devolve CLOSED.
                if (mudou[0] != 0) aoMudar(mudou[0])
                if (st == Status.CLOSED) {
                    fim = Fim.O_OUTRO_SAIU
                    break
                }
                if (st != Status.OK) {
                    fim = if (replica.fechada) Fim.REPLICA_FECHADA else Fim.FALHOU
                    if (fim == Fim.FALHOU) Log.w(tag, "a bombeada devolveu ${Status.nome(st)}")
                    break
                }
                val ev = QuallNative.sessionNextEvent(sessao, 0)
                if (ev != SessionEvent.NONE) {
                    // Passo 1, pelo evento: a bombeada final com prazo zero, antes de dar o par por
                    // perdido. O que estava na fila entra agora.
                    replica.bombear(mensagens, 0, mudou)
                    if (mudou[0] != 0) aoMudar(mudou[0])
                    fim = if (ev == SessionEvent.DISCONNECTED) Fim.O_OUTRO_SAIU else Fim.FALHOU
                    break
                }
            }
        } finally {
            // Passo 2: só agora a regra da queda (o prompter continua como estava; os dois avisam;
            // com o dedo no botão, o texto para). Em **todo** fim — a tela saindo (PARADO), a queda,
            // e até uma exceção no laço —, e antes de qualquer outra edição: um `hold` entre o fim
            // da sessão e o `peer_lost` iria parar no próximo prompter (regra da revisão do
            // núcleo, 14/09).
            replica.perdeuOPar(mudou)
            aoMudar(mudou[0] or MudouNoTeleprompter.PAR)
        }
        return fim
    }
}
