package com.quall.android.teleprompter

import com.quall.android.R
import com.quall.android.core.QuallNative.Status
import com.quall.android.core.Textos

/**
 * **O que fazer depois de cada falha**, dos dois lados — numa conta pura, provada sem aparelho.
 *
 * Os números de status são os de `QuallStatus` (`quall.h`); a regra é a do contrato
 * (`docs/contrato-teleprompter.md` §2, "Quando o controle cai", passo 3). As mensagens saem de
 * [Textos], no idioma da tela (`docs/traducao.md`, Android).
 */
object PoliticaDoPrompter {
    /** Quanto uma espera dura antes de voltar e esperar de novo (com o mesmo PIN). */
    const val ESPERA_MS = 300_000

    /** Abaixo disto, a espera não esperou ninguém: falhou de saída (porta ocupada, por exemplo). */
    const val FALHA_IMEDIATA_MS = 1_000L

    /**
     * Quantas falhas imediatas seguidas antes de desistir. A porta pode estar ocupada **por um
     * instante** — a sessão anterior desta mesma tela ainda soltando o `bind` —, então vale insistir
     * um pouco antes de dizer ao usuário que a porta não abre.
     */
    const val FALHAS_IMEDIATAS_ATE_DESISTIR = 8

    /** A pausa entre duas falhas imediatas da porta. */
    const val PAUSA_DEPOIS_DE_FALHA_MS = 500L

    /**
     * A pausa depois de uma **recusa de candidato** (versão errada, mensagem fora de ordem): sem
     * ela, um aparelho da LAN batendo na porta faria o laço de espera girar a toda.
     */
    const val PAUSA_DEPOIS_DE_RECUSA_MS = 300L

    /**
     * A pausa depois de um **PIN errado**. O PIN já muda a cada erro (§2); a pausa ainda limita
     * as tentativas a ~1 por segundo — seis dígitos a esse ritmo são centenas de horas.
     */
    const val PAUSA_DEPOIS_DE_PIN_ERRADO_MS = 1_000L

    sealed class Depois {
        /**
         * Esperar de novo **com o mesmo PIN** (queda de sessão, prazo, versão errada), depois de
         * `pausaMs`. `falhaDaPorta`: conta para a desistência — só a porta que não abre conta.
         */
        data class MesmoPin(val pausaMs: Long, val falhaDaPorta: Boolean) : Depois()

        /**
         * **PIN novo.** Depois de `WRONG_PIN` ou `PAIRING` numa espera o PIN é trocado: ele é
         * segurado por uma tentativa por conexão, e repeti-lo abriria força bruta online (§2).
         */
        data class PinNovo(val pausaMs: Long) : Depois()

        data class Desistir(val mensagem: String) : Depois()
    }

    /**
     * O que volta da espera **por culpa do servidor** — a porta que não abre, o `accept` que
     * falha. Os candidatos que caem com esses mesmos erros o núcleo já reespera sozinho
     * (`session.rs::e_acidente_do_candidato`), então quando eles voltam até aqui é a porta.
     */
    private fun eDaPorta(status: Int) =
        status == Status.IO || status == Status.SIGNALING || status == Status.CLOSED || status == Status.TRANSPORT

    fun depoisDaEspera(status: Int, decorridoMs: Long, falhasImediatasSeguidas: Int, motivo: String, porta: Int, t: Textos): Depois =
        when {
            status == Status.WRONG_PIN || status == Status.PAIRING -> Depois.PinNovo(PAUSA_DEPOIS_DE_PIN_ERRADO_MS)
            // Erro de programação ou de configuração: repetir não muda nada.
            status == Status.INVALID || status == Status.NULL_POINTER || status == Status.NOT_UTF8 ->
                Depois.Desistir(t.s(R.string.tp_erro_esperar_controle, motivo))
            // **Só a porta que não abre conta para desistir.** A primeira versão contava qualquer
            // volta rápida, e um aparelho da LAN que mandasse um `Hello` de outra versão assim
            // que a porta abrisse (`PROTOCOL`, decisão, em milissegundos) faria o prompter desistir
            // de esperar em ~4 s — e o controle que caiu nunca mais voltaria. Achado da revisão
            // adversarial de 13/09; o contrato (§2) diz que nada que chega pela porta derruba a
            // espera.
            eDaPorta(status) && decorridoMs < FALHA_IMEDIATA_MS ->
                if (falhasImediatasSeguidas + 1 >= FALHAS_IMEDIATAS_ATE_DESISTIR) {
                    Depois.Desistir(t.s(R.string.tp_erro_abrir_porta, porta, motivo))
                } else {
                    Depois.MesmoPin(PAUSA_DEPOIS_DE_FALHA_MS, falhaDaPorta = true)
                }
            // O prazo da espera estourou sem ninguém: volta na hora.
            status == Status.TIMEOUT -> Depois.MesmoPin(0, falhaDaPorta = false)
            // Recusa de um candidato (versão, mensagem fora de ordem) ou queda depois de um tempo:
            // mesmo PIN, com uma pausa curta para ninguém fazer o laço girar.
            else -> Depois.MesmoPin(PAUSA_DEPOIS_DE_RECUSA_MS, falhaDaPorta = false)
        }
}

object PoliticaDoControle {
    /** Prazo de uma tentativa de conexão (TCP, pareamento e o canal subir). */
    const val PRAZO_CONEXAO_MS = 10_000

    /** "O controle tenta de novo a cada ~1 s até entrar" (§2, passo 3). */
    const val INTERVALO_MS = 1_000L

    sealed class Depois {
        data class TentarDeNovo(val esperaMs: Long, val aviso: String) : Depois()
        data class PedirPin(val mensagem: String) : Depois()
        data class Desistir(val mensagem: String) : Depois()
    }

    /**
     * `jaConectou`: esta tela já teve sessão com o prompter. Aí toda falha de rede é "ele está
     * voltando" (re-hospedando na mesma porta, ou sem rede por um instante) e o controle insiste.
     * Na primeira conexão, a mesma falha quase sempre é endereço errado — e o usuário precisa ler
     * isso em vez de ver a tela insistir para sempre.
     */
    fun depoisDaFalha(status: Int, jaConectou: Boolean, motivo: String, endpoint: String, t: Textos): Depois =
        when (status) {
            // O atendente do prompter: segundo controle, ou o mesmo voltando antes de o prompter
            // perceber a queda (até 5 s). Nunca é queda; tenta de novo.
            Status.BUSY -> Depois.TentarDeNovo(
                INTERVALO_MS,
                t.s(if (jaConectou) R.string.tp_ocupado_soltando else R.string.tp_ocupado_outro_controle),
            )
            Status.NEEDS_PIN -> Depois.PedirPin(t.s(R.string.tp_pin_nao_reconhece))
            Status.WRONG_PIN -> Depois.PedirPin(t.s(R.string.tp_pin_nao_conferiu))
            Status.PAIRING -> Depois.PedirPin(t.s(R.string.tp_pareamento_nao_fechou))
            Status.PROTOCOL -> Depois.Desistir(t.s(R.string.tp_erro_protocolo, endpoint, motivo))
            Status.INVALID, Status.NULL_POINTER, Status.NOT_UTF8 ->
                Depois.Desistir(t.s(R.string.tp_erro_invalido, motivo))
            else ->
                if (jaConectou) {
                    Depois.TentarDeNovo(INTERVALO_MS, t.s(R.string.tp_tentando_reconectar))
                } else {
                    Depois.Desistir(
                        when (status) {
                            Status.NO_ROUTE -> t.s(R.string.tp_erro_sem_rota)
                            Status.TIMEOUT -> t.s(R.string.tp_erro_prazo, endpoint)
                            Status.IO -> t.s(R.string.tp_erro_recusou, endpoint)
                            else -> t.s(R.string.tp_erro_conectar, endpoint, motivo)
                        }
                    )
                }
        }
}
