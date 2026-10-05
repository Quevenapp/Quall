package com.quall.android.audio

/**
 * **O som da gravação local no tempo do arquivo** (R5, fase 3; `docs/teleprompter-com-camera.md`
 * §5.2, a revisão G3). Pura: quem chama passa as horas.
 *
 * O arquivo começa no **primeiro quadro de vídeo** gravado ([zeroUs], em `MONOTONIC`). O som chega
 * do microfone em quadros de 20 ms com a **hora da captura** da primeira amostra, no mesmo
 * `MONOTONIC` (`CapturaPorAudioRecord`, pelo `getTimestamp`). Esta linha decide onde cada amostra
 * cai no arquivo, e mantém o som **contínuo** — o AAC num MP4 não tem PTS por amostra: um buraco no
 * PTS vira som adiantado para o resto do arquivo, porque o tocador lê as amostras uma atrás da
 * outra.
 *
 * - **Antes do zero**: cai (o som anterior ao primeiro quadro não entra).
 * - **No lugar**: o quadro cai onde a linha está, se a hora dele disser o mesmo com folga de
 *   [limiarAmostras] (20 ms): o relógio do microfone anda um pouco diferente do `MONOTONIC`, e
 *   corrigir amostra a amostra seria um estalo a cada quadro.
 * - **Atrasado demais** (a hora do quadro está mais de 20 ms à frente da linha: o microfone abriu
 *   agora, ou soluçou): a linha recebe **silêncio** até a hora dele. A imagem não perde a boca.
 * - **Adiantado demais** (a hora está mais de 20 ms atrás: o silêncio já cobriu esse trecho, ou o
 *   relógio escorregou): o começo do quadro que já passou **cai**.
 * - **Sem microfone** (o botão desligado, ou ele ainda não abriu): [silencioAte] enche de silêncio
 *   até a hora pedida. O arquivo nasce e morre com a track de som (§5.2: "o arquivo nasce com
 *   track de som mesmo com o botão desligado").
 * - **No fim**, [limiteUs] corta o que passar do último quadro de vídeo, e [silencioAte] completa
 *   até ele: o som e a imagem terminam juntos.
 *
 * O que sai é por [Saida]: um pedaço de PCM (intercalado, [canais] canais) com a posição da
 * primeira amostra no arquivo — contínuo, sem buraco nem sobreposição, por construção.
 */
class LinhaDoSomDaGravacao(
    val taxaHz: Int,
    val canais: Int,
    /** Acima disto de desvio (em amostras por canal) entre a hora do quadro e a linha, corrige. */
    val limiarAmostras: Int = taxaHz / 50,
) {
    fun interface Saida {
        /** [n] amostras por canal de [pcm], a partir da amostra [desde] (por canal), na posição [posicao] do arquivo. */
        fun pedaco(pcm: ShortArray, desde: Int, n: Int, posicao: Long)
    }

    /** O começo do arquivo, em µs de `MONOTONIC`: a hora do primeiro quadro de vídeo. */
    var zeroUs: Long? = null

    /** Nada depois disto (µs de `MONOTONIC`): o fim do último quadro de vídeo. */
    var limiteUs: Long? = null

    /** Amostras por canal já entregues: a posição da linha no arquivo. */
    var escritas = 0L
        private set

    // --- para o diário ------------------------------------------------------------------------
    var quadros = 0L; private set
    var quadrosAntesDoZero = 0L; private set
    var quadrosSemHora = 0L; private set
    var silencioInserido = 0L; private set
    var amostrasCortadas = 0L; private set
    var correcoes = 0L; private set
    var maiorDesvioAmostras = 0L; private set

    private val zeros = ShortArray(taxaHz / 50 * canais)

    /** A posição (amostras por canal, desde o zero) da hora [us], arredondada. */
    fun amostraDe(us: Long): Long {
        val z = zeroUs ?: return 0
        val d = us - z
        return if (d >= 0) (d * taxaHz + 500_000) / 1_000_000 else -((-d * taxaHz + 500_000) / 1_000_000)
    }

    /**
     * Um quadro da captura: [n] amostras por canal em [pcm], a primeira capturada em [instanteUs]
     * (`MONOTONIC`), ou `null` quando a fonte não soube dizer — aí ele cai onde a linha está.
     */
    fun quadro(pcm: ShortArray, n: Int, instanteUs: Long?, saida: Saida) {
        if (n <= 0) return
        if (zeroUs == null) {
            quadrosAntesDoZero++
            return
        }
        quadros++
        var desde = 0
        var qtd = n
        var inicio = if (instanteUs != null) amostraDe(instanteUs) else {
            quadrosSemHora++
            escritas
        }
        if (inicio < 0) {
            val corte = minOf(-inicio, qtd.toLong()).toInt()
            desde += corte
            qtd -= corte
            inicio += corte
            if (qtd <= 0) {
                quadrosAntesDoZero++
                return
            }
        }
        val d = inicio - escritas
        if (Math.abs(d) > maiorDesvioAmostras) maiorDesvioAmostras = Math.abs(d)
        if (d > limiarAmostras) {
            correcoes++
            val teto = limiteUs?.let { amostraDe(it) - escritas } ?: d
            if (teto > 0) silencio(minOf(d, teto), saida)
        } else if (d < -limiarAmostras) {
            correcoes++
            val corte = minOf(-d, qtd.toLong()).toInt()
            desde += corte
            qtd -= corte
            amostrasCortadas += corte
            if (qtd <= 0) return
        }
        // O fim: nada passa do último quadro de vídeo.
        limiteUs?.let { lim ->
            val max = amostraDe(lim) - escritas
            if (max <= 0) {
                amostrasCortadas += qtd
                return
            }
            if (qtd > max) {
                amostrasCortadas += qtd - max
                qtd = max.toInt()
            }
        }
        saida.pedaco(pcm, desde, qtd, escritas)
        escritas += qtd
    }

    /**
     * Silêncio até a hora [us] (`MONOTONIC`), se a linha estiver antes dela — o microfone fechado,
     * ou o fim do arquivo. Respeita o [limiteUs]. Devolve quantas amostras (por canal) entraram.
     */
    fun silencioAte(us: Long, saida: Saida): Long {
        if (zeroUs == null) return 0
        var alvo = amostraDe(us)
        limiteUs?.let { alvo = minOf(alvo, amostraDe(it)) }
        val falta = alvo - escritas
        if (falta <= 0) return 0
        silencio(falta, saida)
        return falta
    }

    private fun silencio(amostras: Long, saida: Saida) {
        var falta = amostras
        val porVez = zeros.size / canais
        while (falta > 0) {
            val k = minOf(falta, porVez.toLong()).toInt()
            saida.pedaco(zeros, 0, k, escritas)
            escritas += k
            falta -= k
            silencioInserido += k
        }
    }

    fun linha(): String =
        "linha_do_som quadros=$quadros antes_do_zero=$quadrosAntesDoZero sem_hora=$quadrosSemHora " +
            "silencio_ms=${silencioInserido * 1000 / taxaHz} cortadas_ms=${amostrasCortadas * 1000 / taxaHz} " +
            "correcoes=$correcoes maior_desvio_ms=${maiorDesvioAmostras * 1000 / taxaHz} " +
            "escritas_ms=${escritas * 1000 / taxaHz}"
}
