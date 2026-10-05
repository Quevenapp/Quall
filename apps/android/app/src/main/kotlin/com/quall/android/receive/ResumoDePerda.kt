package com.quall.android.receive

import org.json.JSONObject

/**
 * A perda, em uma linha, com os **três** números que ela precisa para não mentir.
 *
 * Esta casca é o receptor da matriz desta bancada: a curva de banheira, a matriz Android↔Android e
 * quase toda medição de perda do projeto saíram de um número lido no logcat deste app. Até
 * 29/08/2026 esse número era `packets_missing` — que **nunca foi perda**. Ele é a soma dos saltos
 * de sequência, e uma reordenação de distância `d` entra ali como `1 + d` posições sem que nada
 * tenha se perdido. Numa corrida com 486 nele, o emissor tinha entregado 27.779 pacotes e o
 * receptor visto 27.729: sumiram **cinquenta**. O erro vai de 1,3× a 44×, e contaminou os laudos.
 *
 * O núcleo passou a publicar `packets_lost_for_real` (janela de reordenação de 128 posições) e
 * `packets_too_late` (que denuncia quando a própria janela foi curta demais). Esta classe existe
 * para que os três apareçam **juntos**, sempre, e para que nenhum deles possa ser lido sozinho:
 *
 * ```
 * perda exata 50 (0,180%) · teto 486 (1,720%) · tarde demais 0 · vistos 27729
 * ```
 *
 * O JSON cru continua saindo ao lado, porque é o que a bancada consome com script. O que esta
 * linha acrescenta é a leitura certa para o olho humano — e ela é a única coisa que impede o
 * próximo leitor de repetir o erro de ler o teto como perda.
 */
object ResumoDePerda {

    /**
     * Formata a linha a partir do JSON de [com.quall.android.core.QuallNative.trackStatsJson].
     *
     * Nunca lança: um JSON ilegível vira uma frase que diz que não deu para ler, porque um resumo
     * de perda que some do relatório é pior que um que se declara ausente.
     */
    fun formatar(estatisticasDoNucleo: String): String = runCatching {
        de(JSONObject(estatisticasDoNucleo))
    }.getOrElse { "perda: contadores do núcleo ilegíveis" } // i18n-fora: linha de bancada (diário e painel de números), lida por script

    /**
     * A mesma linha, a partir do objeto já desserializado.
     *
     * Chave ausente devolve `-1` e sai como `?` — **nunca como zero**. Um `0` diria "medi e não
     * perdi nada", que é a afirmação mais perigosa que este relatório pode fazer por engano; foi
     * exatamente para não fazê-la que a chave antiga não ganhou um alias no núcleo.
     */
    fun de(d: JSONObject): String {
        val exata = d.optLong("packets_lost_for_real", -1L)
        val teto = d.optLong("packets_missing_upper_bound", -1L)
        val tarde = d.optLong("packets_too_late", -1L)
        val vistos = d.optLong("packets_seen", -1L)

        if (vistos == 0L) return "perda: nenhum pacote chegou ainda (packets_seen=0) — nada a afirmar"

        val sb = StringBuilder()
        sb.append("perda exata ").append(numero(exata)).append(taxa(exata, vistos))
        sb.append(" · teto ").append(numero(teto)).append(taxa(teto, vistos))
        sb.append(" · tarde demais ").append(numero(tarde))
        sb.append(" · vistos ").append(numero(vistos))
        // A janela de reordenação tem 128 posições. Um pacote que chega depois de a posição dele
        // já ter saído dela é uma posição que foi cobrada como perda e não era: quando isto passa
        // de zero, a perda exata está superestimada nesse tanto e a leitura precisa dizer isso.
        if (tarde > 0L) sb.append(" — JANELA CURTA: a perda exata está superestimada em até $tarde") // i18n-fora: linha de bancada (diário e painel de números), lida por script
        return sb.toString()
    }

    private fun numero(v: Long) = if (v < 0) "?" else v.toString()

    /**
     * `(0.180%)` sobre a janela observada, ou nada quando falta um dos dois números.
     *
     * **`Locale.ROOT`, e não o do aparelho.** Este número é lido por `adb logcat` e por script; com
     * o locale do tablet (pt-BR) ele sairia com vírgula decimal, e a mesma linha teria formatos
     * diferentes conforme o idioma do aparelho de bancada. As outras três cascas imprimem ponto
     * porque `printf` de C e `String(format:)` de Swift usam o locale POSIX; esta precisa pedir.
     */
    private fun taxa(v: Long, vistos: Long): String {
        if (v < 0 || vistos <= 0) return ""
        val d = v + vistos
        return if (d <= 0) "" else " (${String.format(java.util.Locale.ROOT, "%.3f", 100.0 * v / d)}%)"
    }
}
