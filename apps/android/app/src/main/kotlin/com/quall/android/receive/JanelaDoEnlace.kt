package com.quall.android.receive

import org.json.JSONObject

/**
 * O dano do enlace numa **janela**, e não desde o começo da sessão.
 *
 * Todo contador de recepção deste projeto é acumulado desde o início: `packets_seen`,
 * `packets_lost_for_real`, `suspeitos`, `idrs_broken`. Isso é certo para o relato final e é
 * inútil para decidir alguma coisa **agora** — uma sessão que perdeu 8 % nos primeiros dez
 * segundos e nada depois continua dizendo 8 % meia hora adiante. Quem escuta o enlace precisa da
 * derivada, não da integral.
 *
 * Esta classe é a derivada, e ela é a **mesma** peça em dois papéis:
 *
 * 1. **instrumento** — a linha `janela_do_enlace` no `logcat` é o que mede a curva de resposta
 *    (perda contra bitrate) numa sessão só, com o rádio parado;
 * 2. **sinal** — a mesma amostra é o que atravessa até o emissor quando o controlador de taxa
 *    está ligado.
 *
 * São o mesmo objeto de propósito: um controlador alimentado por um número diferente do que a
 * bancada mediu é um controlador projetado contra outra curva.
 *
 * # O denominador vem do emissor, e isso não é detalhe
 *
 * `perdaPct` divide por `pacotes + perdidos`, e não por `pacotes`. Os dois termos vêm de números
 * de sequência RTP, que são contíguos: `packets_seen + packets_lost_for_real` **é** o que o
 * emissor mandou naquela janela, contado deste lado.
 *
 * Em 31/08/2026 esta bancada quase publicou a conclusão oposta sobre a perda de regime porque um
 * instrumento dividia pelo que **chegou**: o braço que parecia o melhor da matriz era o pior, e o
 * laudo já estava escrito. A regra que ficou — *o denominador de uma taxa de perda é o que o
 * emissor mandou* — está honrada aqui por construção, não por disciplina.
 *
 * # Contador que anda para trás é sessão nova, não perda negativa
 *
 * `delta` trata regressão como reinício (devolve o valor cru) em vez de devolver negativo. Uma
 * track recriada zera os contadores do núcleo, e um delta negativo viraria "perda de −4 %"
 * alimentando um controlador — que é como se sobe o bitrate exatamente quando não se deve.
 */
class JanelaDoEnlace {

    /** Uma janela fechada. Todos os campos são **deltas**, exceto [ms]. */
    data class Amostra(
        /** Duração real da janela, em ms. Nunca a nominal — ver [fechar]. */
        val ms: Long,
        /** Pacotes RTP que o emissor mandou nesta janela: vistos + perdidos de verdade. */
        val pacotes: Long,
        /** Perda **exata** (`packets_lost_for_real`), não o teto `packets_missing_upper_bound`. */
        val perdidos: Long,
        val quadros: Long,
        val suspeitos: Long,
        val rupturas: Long,
        val idrsProntos: Long,
        val idrsQuebrados: Long,
    ) {
        /** Perda da janela em por cento, com o denominador do emissor. Ver a doc da classe. */
        val perdaPct: Double
            get() = if (pacotes <= 0) 0.0 else perdidos * 100.0 / pacotes

        /** Pacotes por segundo que o emissor pôs no ar nesta janela. A carga, que é o que dói. */
        val pacotesPorSegundo: Double
            get() = if (ms <= 0) 0.0 else pacotes * 1000.0 / ms

        fun linha(): String =
            "janela_do_enlace ms=$ms pacotes=$pacotes pac_s=${"%.0f".format(pacotesPorSegundo)} " +
                "perdidos=$perdidos perda_pct=${"%.2f".format(perdaPct)} quadros=$quadros " +
                "suspeitos=$suspeitos rupturas=$rupturas " +
                "idrs_ok=$idrsProntos idrs_quebrados=$idrsQuebrados"
    }

    private var abriuEm = 0L
    private var pacotesVistos = 0L
    private var perdidos = 0L
    private var quadros = 0L
    private var suspeitos = 0L
    private var rupturas = 0L
    private var idrsProntos = 0L
    private var idrsQuebrados = 0L
    private var temBase = false

    /**
     * Fecha a janela e abre a seguinte, se `agoraMs - abertura >= periodoMs`.
     *
     * `estatisticasDoNucleo` é o JSON de `quall_track_stats_json` — a **mesma** leitura que
     * [ReceptorSessao.relatar] já faz, passada adiante em vez de pedida de novo: duas leituras
     * dariam dois instantes, e a bancada compararia números que não fecham entre si.
     *
     * Devolve `null` enquanto a janela não fechou, e também na primeira chamada — que só
     * estabelece a linha de base. Uma primeira janela contando desde zero mediria o arranque da
     * sessão (o primeiro IDR, a subida do ICE) como se fosse regime.
     */
    fun fechar(agoraMs: Long, periodoMs: Long, estatisticasDoNucleo: String,
               suspeitosAcumulados: Long, rupturasAcumuladas: Long): Amostra? {
        if (periodoMs <= 0) return null
        val j = runCatching { JSONObject(estatisticasDoNucleo) }.getOrNull() ?: return null
        val vistosAgora = j.optLong("packets_seen")
        val perdidosAgora = j.optLong("packets_lost_for_real")
        val quadrosAgora = j.optLong("frames_ready")
        val idrsOkAgora = j.optLong("idrs_ready")
        val idrsRuinsAgora = j.optLong("idrs_broken")

        if (!temBase) {
            base(agoraMs, vistosAgora, perdidosAgora, quadrosAgora, idrsOkAgora, idrsRuinsAgora,
                suspeitosAcumulados, rupturasAcumuladas)
            return null
        }
        val decorrido = agoraMs - abriuEm
        if (decorrido < periodoMs) return null

        val a = Amostra(
            // A duração **real**: esta função é chamada de um laço que acorda quando acorda, e
            // dividir pelo período nominal daria uma taxa sistematicamente alta.
            ms = decorrido,
            pacotes = delta(vistosAgora, pacotesVistos) + delta(perdidosAgora, perdidos),
            perdidos = delta(perdidosAgora, perdidos),
            quadros = delta(quadrosAgora, quadros),
            suspeitos = delta(suspeitosAcumulados, suspeitos),
            rupturas = delta(rupturasAcumuladas, rupturas),
            idrsProntos = delta(idrsOkAgora, idrsProntos),
            idrsQuebrados = delta(idrsRuinsAgora, idrsQuebrados),
        )
        base(agoraMs, vistosAgora, perdidosAgora, quadrosAgora, idrsOkAgora, idrsRuinsAgora,
            suspeitosAcumulados, rupturasAcumuladas)
        return a
    }

    private fun base(agoraMs: Long, vistos: Long, perd: Long, quad: Long, idrOk: Long,
                     idrRuim: Long, susp: Long, rupt: Long) {
        abriuEm = agoraMs
        pacotesVistos = vistos
        perdidos = perd
        quadros = quad
        idrsProntos = idrOk
        idrsQuebrados = idrRuim
        suspeitos = susp
        rupturas = rupt
        temBase = true
    }

    /** Ver a doc da classe: contador que regride é sessão nova, e não perda negativa. */
    private fun delta(agora: Long, antes: Long): Long = if (agora >= antes) agora - antes else agora
}
