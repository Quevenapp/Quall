package com.quall.android.core

/**
 * **Quem cada lista mostra**, pelo papel anunciado (`docs/contrato-teleprompter.md` §2, "Como o
 * controle acha o prompter").
 *
 * Até o teleprompter, as listas do Android não filtravam nada (`DeviceListAdapter`): todo aparelho
 * anunciando aparecia em toda lista. Com o papel isso deixa de servir nos dois sentidos:
 *
 * - **a lista do controle** mostra só quem anuncia `"teleprompter"` — um emissor de vídeo ali seria
 *   um toque que termina em "este aparelho não é um teleprompter";
 * - **as listas de vídeo** (exibir outro aparelho, e a de diagnóstico) escondem **todo** aparelho
 *   com papel — um prompter oferecido como tela para exibir recusaria o receptor no `Hello`, e um
 *   papel desconhecido de uma build futura também não é vídeo. A recusa no `Hello` continua sendo a
 *   rede de segurança; esconder é o que evita o toque perdido.
 *
 * Funções puras sobre a lista: provadas em `PapeisTest`, sem mDNS nem aparelho.
 */
object Papeis {
    const val TELEPROMPTER = "teleprompter"
    const val CONTROLE_REMOTO = "controle_remoto"

    /** Para a lista do controle: só os prompters. */
    fun soTeleprompters(lista: List<QuallBrowser.Device>): List<QuallBrowser.Device> =
        lista.filter { it.papel == TELEPROMPTER }

    /** Para as listas de vídeo: só quem não anuncia papel nenhum. */
    fun soDeVideo(lista: List<QuallBrowser.Device>): List<QuallBrowser.Device> =
        lista.filter { it.papel.isNullOrEmpty() }
}
