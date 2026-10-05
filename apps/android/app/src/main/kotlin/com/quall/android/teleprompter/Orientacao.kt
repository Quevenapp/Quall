package com.quall.android.teleprompter

import android.content.pm.ActivityInfo
import androidx.annotation.StringRes
import com.quall.android.R
import java.text.Normalizer

/**
 * **A orientação da tela do prompter** — um ajuste **deste aparelho**, e não do teleprompter: não
 * vai para a réplica nem para o fio, e o controle não o vê (decisão do usuário, 14/09: "ajuste no
 * aparelho local"). Mora nas preferências da tela e vale na próxima vez que o prompter abrir.
 *
 * ## Por que existe
 *
 * Num suporte de teleprompter de verdade o telefone fica **deitado, com a tela para cima**, sob o
 * vidro a 45°. Deitado, o sensor não decide a orientação: o A10s do usuário ficou em retrato e o
 * texto saiu de lado no vidro (o espelho estava certo). `requestedOrientation` com um valor fixo
 * **trava a tela e independe do sensor** — o que se escolhe vale com o aparelho em qualquer
 * posição.
 *
 * ## Os nomes são literais (do coordenador)
 *
 * - **Automática**: o comportamento de antes (`UNSPECIFIED`: o sistema e o sensor decidem).
 * - **Retrato**.
 * - **Paisagem**: o topo do aparelho à **esquerda** de quem olha a tela (`LANDSCAPE`).
 * - **Paisagem invertida**: o topo à **direita** (`REVERSE_LANDSCAPE`).
 */
enum class Orientacao(
    /** Como vai nas preferências e na bancada (`--es orientacao paisagem_invertida`). */
    val chave: String,
    /**
     * O nome em português, o literal do coordenador: a bancada o aceita no lugar da chave
     * ([daChave]) e o diário o escreve. Na tela vale [rotulo], no idioma escolhido.
     */
    val nome: String,
    /** O nome na tela (`tp_orientacao_*`), no idioma da tela. */
    @StringRes val rotulo: Int,
    /** O `requestedOrientation` da janela. */
    val valorDoAndroid: Int,
) {
    AUTOMATICA("automatica", "Automática", R.string.tp_orientacao_automatica, ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED), // i18n-fora: nome da bancada e do diário; a tela usa o rótulo
    RETRATO("retrato", "Retrato", R.string.tp_orientacao_retrato, ActivityInfo.SCREEN_ORIENTATION_PORTRAIT),
    PAISAGEM("paisagem", "Paisagem", R.string.tp_orientacao_paisagem, ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE),
    PAISAGEM_INVERTIDA("paisagem_invertida", "Paisagem invertida", R.string.tp_orientacao_paisagem_invertida, ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE);

    companion object {
        val PADRAO = AUTOMATICA

        /**
         * A chave ou o nome, sem ligar para maiúscula, acento, espaço ou hífen ("Paisagem
         * invertida", "paisagem-invertida", "PAISAGEM_INVERTIDA"). `null` se não é nenhuma.
         */
        fun daChave(texto: String?): Orientacao? {
            val t = normalizar(texto ?: return null)
            if (t.isEmpty()) return null
            return entries.firstOrNull { normalizar(it.chave) == t || normalizar(it.nome) == t }
        }

        /** O que está guardado → a orientação; qualquer coisa ilegível vira a [PADRAO]. */
        fun doGuardado(texto: String?): Orientacao = daChave(texto) ?: PADRAO

        private fun normalizar(s: String): String =
            Normalizer.normalize(s.trim().lowercase(), Normalizer.Form.NFD)
                .replace(Regex("\\p{M}+"), "")
                .replace(Regex("[\\s_-]+"), "_")
    }
}
