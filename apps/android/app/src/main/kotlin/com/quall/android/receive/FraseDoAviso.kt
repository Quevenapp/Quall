package com.quall.android.receive

import com.quall.android.R
import com.quall.android.core.Textos

/**
 * **O aviso da sessão em palavras** (`docs/traducao.md`, Android). Fora do [ReceptorBus] porque ele cria
 * um `Handler` do Android ao nascer, e esta peça é pura: o teste JVM prova as frases nos dois idiomas.
 */
object FraseDoAviso {
    /**
     * O [ReceptorBus.Estado.aviso] em palavras, no idioma de [t], com a primeira letra maiúscula. As frases
     * de hoje continuam (§5), menos o jargão: a espera pela track é "Esperando a imagem…" (a "track" fica
     * no diário). Sem aviso, vale [ReceptorBus.Estado.mensagem] como veio (o estado de mentira da vitrine
     * de `debug`).
     */
    fun de(t: Textos, e: ReceptorBus.Estado): String {
        val d = e.detalhe
        val f = when (e.aviso) {
            ReceptorBus.Aviso.NENHUM -> e.mensagem
            ReceptorBus.Aviso.RETOMANDO -> t.s(R.string.rx_aviso_retomando)
            ReceptorBus.Aviso.CONECTANDO_E_PAREANDO -> t.s(R.string.rx_aviso_conectando_e_pareando)
            ReceptorBus.Aviso.CANCELADO -> t.s(R.string.rx_aviso_cancelado)
            ReceptorBus.Aviso.PRECISA_DE_PIN -> t.s(R.string.rx_aviso_precisa_de_pin)
            ReceptorBus.Aviso.SEM_ROTA -> t.s(R.string.rx_aviso_sem_rota)
            ReceptorBus.Aviso.SEM_RESPOSTA -> t.s(R.string.rx_aviso_sem_resposta, d)
            ReceptorBus.Aviso.NAO_CONECTOU -> t.s(R.string.rx_aviso_nao_conectou, e.endpoint, d)
            ReceptorBus.Aviso.NUCLEO_NAO_CARREGOU -> t.s(R.string.rx_aviso_nucleo_nao_carregou, d)
            ReceptorBus.Aviso.RECEPCAO_MORREU -> t.s(R.string.rx_aviso_recepcao_morreu, d)
            ReceptorBus.Aviso.ESPERANDO_A_IMAGEM -> t.s(R.string.rx_aviso_esperando_a_imagem)
            ReceptorBus.Aviso.SEM_TRACK -> t.s(R.string.rx_aviso_sem_track, d.ifBlank { t.s(R.string.rx_par_sem_nome) })
            ReceptorBus.Aviso.SEM_CAIXA -> t.s(R.string.rx_aviso_sem_caixa)
            ReceptorBus.Aviso.TRATADOR_RECUSADO -> t.s(R.string.rx_aviso_tratador_recusado, d)
            ReceptorBus.Aviso.EMISSOR_SAIU -> t.s(R.string.rx_aviso_emissor_saiu, d)
            ReceptorBus.Aviso.TRANSPORTE_FALHOU -> t.s(R.string.rx_aviso_transporte_falhou, d)
            ReceptorBus.Aviso.SEM_QUADRO ->
                t.s(R.string.rx_aviso_sem_quadro, d, (ReceptorSessao.SILENCIO_ATE_DESISTIR_MS / 1000).toInt())
            ReceptorBus.Aviso.RECEPCAO_ENCERRADA -> t.s(R.string.rx_aviso_recepcao_encerrada)
            ReceptorBus.Aviso.RECEPCAO_TERMINOU -> t.s(R.string.rx_aviso_recepcao_terminou)
            ReceptorBus.Aviso.SO_SOM -> t.s(R.string.rx_aviso_so_som)
            ReceptorBus.Aviso.SESSAO_CAIU -> t.s(R.string.rx_aviso_sessao_caiu, d)
            ReceptorBus.Aviso.AUDIO_PAROU -> d.ifBlank { t.s(R.string.rx_aviso_audio_nao_toca) }
        }
        return f.replaceFirstChar { it.uppercase() }
    }
}
