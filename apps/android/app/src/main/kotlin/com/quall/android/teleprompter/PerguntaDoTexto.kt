package com.quall.android.teleprompter

import com.quall.android.R
import com.quall.android.core.QuallNative
import com.quall.android.core.Textos
import com.quall.android.teleprompter.EstadoDoTeleprompter.CopiaDoTexto
import com.quall.android.teleprompter.EstadoDoTeleprompter.PerguntaDoTexto
import com.quall.android.teleprompter.EstadoDoTeleprompter.VistaDoTexto
import java.text.NumberFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * **A caixa da "pergunta do texto"** no controle (`docs/contrato-teleprompter.md` §11.7), sem Android:
 * o que ela mostra a partir do estado, e os textos — literais, os mesmos nas quatro telas. As frases
 * moram em `strings_teleprompter.xml` (`tp_no_prompter`, `tp_usar_o_do_prompter`…) e saem de [Textos],
 * no idioma da tela (`docs/traducao.md`, Android).
 *
 * A decisão do usuário (13/09): *um controle que conecta num prompter que não é o da última vez, com
 * roteiro diferente, pergunta uma vez ("usar o do prompter ou mandar o meu") e guarda cópia do que
 * sair.* O núcleo decide quando perguntar e guarda as cópias; a tela só mostra e responde.
 */
object CaixaDaPergunta {
    fun titulo(prompterNome: String, t: Textos): String = t.s(R.string.tp_pergunta_titulo, prompterNome)

    /** Comparando por mais que isto, a caixa diz que está conferindo (antes, nada aparece). */
    const val ESPERA_PARA_CONFERINDO_MS = 1_000L

    /** O que a caixa mostra agora. */
    sealed interface Caixa {
        /** Sem pergunta, ou comparando há pouco. */
        data object Escondida : Caixa

        /** Comparando há mais de ~1 s: só o aviso, sem botões. */
        data object Conferindo : Caixa

        /**
         * A pergunta aberta: as duas prévias e os dois botões. [resumoMostrado] é o `"resumo"` de
         * `"do_prompter"` desta caixa — o que a escolha leva, e nunca um relido na hora do toque.
         */
        data class Perguntando(
            val titulo: String,
            val doPrompter: VistaDoTexto,
            val meu: VistaDoTexto,
            val botoesLigados: Boolean,
            val aviso: String?,
        ) : Caixa {
            val resumoMostrado: String get() = doPrompter.resumo
        }
    }

    /**
     * A caixa a partir da pergunta do estado:
     *
     * - `null` → escondida (a pergunta fechou, também pelo outro lado: a caixa some sozinha);
     * - comparando → escondida no primeiro segundo, depois [Caixa.Conferindo];
     * - aberta → [Caixa.Perguntando]. Com o prompter sumido ([parVisto] falso) ou a última escolha
     *   devolvendo `CLOSED`, os botões desligam e o aviso é `tp_pergunta_saiu`; com `BUSY`, ligados e
     *   `tp_pergunta_mudou` (a caixa já mostra o que o bit trouxe).
     */
    fun caixa(p: PerguntaDoTexto?, parVisto: Boolean, ultimoStatus: Int?, t: Textos): Caixa {
        if (p == null) return Caixa.Escondida
        val dele = p.doPrompter
        val meu = p.meu
        if (!p.aberta || dele == null || meu == null) {
            return if (p.retidoHaMs > ESPERA_PARA_CONFERINDO_MS) Caixa.Conferindo else Caixa.Escondida
        }
        val saiu = !parVisto || ultimoStatus == QuallNative.Status.CLOSED
        val aviso = when {
            saiu -> t.s(R.string.tp_pergunta_saiu)
            ultimoStatus == QuallNative.Status.BUSY -> t.s(R.string.tp_pergunta_mudou)
            else -> null
        }
        return Caixa.Perguntando(titulo(p.prompterNome, t), dele, meu, botoesLigados = !saiu, aviso = aviso)
    }

    /**
     * O tamanho em palavras, igual nas quatro telas (decisão do coordenador, 14/09): concordância e
     * separador de milhar do idioma — "1 palavra", "2 palavras", "1.234 palavras" (em inglês "1,234
     * words"), e "0 palavras" para o texto vazio. Na caixa e em "Roteiros guardados". Duas chaves e
     * `n == 1`, e não `<plurals>`: o pt do CLDR põe o 0 em "one" ("0 palavra").
     */
    fun palavras(n: Int, t: Textos): String =
        if (n == 1) t.s(R.string.tp_uma_palavra)
        else t.s(R.string.tp_n_palavras, NumberFormat.getIntegerInstance(t.locale).format(n))

    /** Palavras no texto inteiro — a mesma palavra da fonte automática (§5 dos ajustes locais). */
    fun contar(texto: String): Int = FonteAutomatica.contarPalavras(texto, 0, texto.length)

}

/**
 * **"Roteiros guardados"** (§11.5 e §11.7): o texto de cada cópia. Os textos fixos da lista e das
 * confirmações são chaves (`tp_roteiros_guardados`, `tp_confirma_usar`, `tp_confirma_apagar`…).
 */
object RoteirosGuardados {
    /** De onde veio: o texto do prompter, ou o daqui que saiu quando se usou o dele. */
    fun origem(c: CopiaDoTexto, t: Textos): String =
        if (c.doPrompter) t.s(R.string.tp_origem_do_prompter, c.prompterNome)
        else t.s(R.string.tp_origem_deste_aparelho, c.prompterNome)

    /** A hora local da cópia: "15:02" se foi hoje, "13/09 15:02" se não ("09/13 15:02" em inglês). */
    fun quando(quandoMs: Long, agoraMs: Long, t: Textos, fuso: TimeZone = TimeZone.getDefault()): String {
        val c = Calendar.getInstance(fuso).apply { timeInMillis = quandoMs }
        val hoje = Calendar.getInstance(fuso).apply { timeInMillis = agoraMs }
        val hora = String.format(Locale.ROOT, "%02d:%02d", c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE))
        val mesmoDia = c.get(Calendar.YEAR) == hoje.get(Calendar.YEAR) && c.get(Calendar.DAY_OF_YEAR) == hoje.get(Calendar.DAY_OF_YEAR)
        return if (mesmoDia) hora else t.s(R.string.tp_dia_e_hora, c.get(Calendar.DAY_OF_MONTH), c.get(Calendar.MONTH) + 1, hora)
    }
}
