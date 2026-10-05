package com.quall.android.teleprompter

import com.quall.android.R
import com.quall.android.core.Textos

/**
 * **Os avisos das duas telas**, numa conta só e sem Android — para a regra do usuário valer igual
 * no prompter e no controle, e para ser provada sem aparelho.
 *
 * A regra de 13/09 (`docs/contrato-teleprompter.md` §2): **se o controle cai, o prompter continua
 * como estava** (rolando segue rolando), **com aviso visível nas duas telas até ele voltar**. O
 * aviso sai do estado da réplica: `par_visto_ha_ms` nulo (depois da queda) ou acima de 2,5 s
 * (`teleprompter::PAR_SUMIDO`). E acima de 1,5 s sem confirmação, a tela diz que o comando não
 * chegou (§3, "A confirmação").
 */
object Avisos {
    /** `teleprompter::PAR_SUMIDO` do núcleo. */
    const val PAR_SUMIDO_MS = 2_500L

    /** §3: "Acima de 1,5 s a tela deve avisar que o comando não chegou." */
    const val SEM_CONFIRMACAO_MS = 1_500L

    /**
     * **Prompter: o controle sumiu.** Só depois de ter havido controle nesta tela — antes disso a
     * tela mostra a espera com o PIN, e "controle desconectado" seria mentira. Fica ligado da queda
     * até a **primeira mensagem** do controle de volta (§2, passo 2): sessão nova de pé com
     * `par_visto` ainda nulo continua avisando.
     */
    fun controleSumido(jaTeveControle: Boolean, sessaoDePe: Boolean, parVistoHaMs: Long?): Boolean =
        jaTeveControle && (!sessaoDePe || parVistoHaMs == null || parVistoHaMs >= PAR_SUMIDO_MS)

    /**
     * **Controle: a conexão com o prompter se perdeu.** Reconectando, ou com a sessão de pé e o
     * prompter mudo há mais de 2,5 s. Logo que a sessão sobe o prompter ainda não falou (`null`):
     * isso só vira aviso depois de 2,5 s de sessão, senão toda conexão piscaria o aviso.
     */
    fun conexaoPerdida(reconectando: Boolean, sessaoDePe: Boolean, sessaoHaMs: Long, parVistoHaMs: Long?): Boolean {
        if (reconectando) return true
        if (!sessaoDePe) return false
        return if (parVistoHaMs == null) sessaoHaMs >= PAR_SUMIDO_MS else parVistoHaMs >= PAR_SUMIDO_MS
    }

    /** Uma edição daqui sem confirmação há mais de 1,5 s — com a sessão de pé (fora dela o aviso é o de conexão). */
    fun comandoNaoChegou(sessaoDePe: Boolean, semConfirmacaoHaMs: Long?): Boolean =
        sessaoDePe && semConfirmacaoHaMs != null && semConfirmacaoHaMs >= SEM_CONFIRMACAO_MS

    /**
     * As linhas do aviso do **prompter**, em ordem de importância. Vazio = sem aviso.
     *
     * [compacto]: a forma curta da tela "Teleprompter com câmera", que cabe numa linha no pé do
     * painel da câmera, longe da lente (o pedido de 24/09). Diz o mesmo — caiu, o texto segue como
     * estava, o PIN e o endereço para um controle novo —, sem a frase inteira.
     *
     * As frases saem de [t], no idioma da tela (`docs/traducao.md`, Android).
     */
    fun doPrompter(
        e: EstadoDoTeleprompter,
        jaTeveControle: Boolean,
        sessaoDePe: Boolean,
        pin: String?,
        endereco: String?,
        t: Textos,
        compacto: Boolean = false,
    ): List<String> = buildList {
        if (controleSumido(jaTeveControle, sessaoDePe, e.parVistoHaMs)) {
            // O PIN e o endereço não mudam de idioma: a frase os recebe já montados.
            val alvo = (if (pin != null) " · PIN $pin" else "") + (if (!endereco.isNullOrBlank()) " · $endereco" else "")
            add(
                if (compacto) {
                    // O PIN e o endereço antes: numa linha estreita, o que o fim corta é o menos útil.
                    t.s(if (e.rolando) R.string.tp_aviso_sumido_curto_rolando else R.string.tp_aviso_sumido_curto_parado, alvo)
                } else {
                    t.s(if (e.rolando) R.string.tp_aviso_sumido_rolando else R.string.tp_aviso_sumido_parado, alvo)
                }
            )
        } else if (comandoNaoChegou(sessaoDePe, e.semConfirmacaoHaMs)) {
            add(t.s(if (compacto) R.string.tp_aviso_nao_chegou_ao_controle_curto else R.string.tp_aviso_nao_chegou_ao_controle))
        }
        comuns(e, this, compacto, t)
    }

    /** As linhas do aviso do **controle**, em ordem de importância. Vazio = sem aviso. */
    fun doControle(
        e: EstadoDoTeleprompter?,
        reconectando: Boolean,
        sessaoDePe: Boolean,
        sessaoHaMs: Long,
        motivo: String?,
        t: Textos,
    ): List<String> = buildList {
        if (conexaoPerdida(reconectando, sessaoDePe, sessaoHaMs, e?.parVistoHaMs)) {
            add(t.s(R.string.tp_aviso_conexao_perdida, motivo?.takeIf { it.isNotBlank() } ?: t.s(R.string.tp_tentando_de_novo)))
        } else if (e != null && comandoNaoChegou(sessaoDePe, e.semConfirmacaoHaMs)) {
            add(t.s(R.string.tp_aviso_nao_chegou_ao_prompter))
        }
        if (e != null) comuns(e, this, compacto = false, t)
    }

    private fun comuns(e: EstadoDoTeleprompter, fora: MutableList<String>, compacto: Boolean, t: Textos) {
        // §4: "diferente de zero, a tela deve dizer 'atualize o app'" — uma sessão que só recebe
        // isso nunca sincroniza.
        if (e.contador("de_outra_versao") > 0) {
            fora.add(t.s(if (compacto) R.string.tp_aviso_outra_versao_curto else R.string.tp_aviso_outra_versao))
        }
        // §4: o texto que o outro lado recusa (relógio de um dos dois mais de um dia errado).
        if (e.contador("reenvios_desistidos") > 0 || e.contador("carimbos_do_futuro") > 0) {
            fora.add(t.s(if (compacto) R.string.tp_aviso_relogio_curto else R.string.tp_aviso_relogio))
        }
    }
}
