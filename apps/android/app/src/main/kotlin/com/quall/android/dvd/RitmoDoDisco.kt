package com.quall.android.dvd

/**
 * **O relógio de saída da transmissão** (`docs/dvd-para-mp4.md` §9, a T1): a conversão corre o mais
 * rápido que dá; a transmissão anda no relógio do vídeo — o quadro sai quando o carimbo dele (o
 * rebaseado da conversão, em 90 kHz, no tempo de saída do pipeline) chega no relógio monotônico
 * ancorado no primeiro quadro. O som usa o mesmo relógio (a amostra `n` da faixa é o tempo
 * `n / 48000` do mesmo pipeline, `dvd.c`: `escritas` começa no tempo 0 da saída).
 *
 * - **ancorar**: o primeiro quadro de uma geração (o começo, e cada pulo) fixa a âncora;
 * - **pausar/continuar**: o relógio para, e na volta a âncora anda o tempo da pausa (nada salta);
 * - **o atraso**: o quadro que chega mais de [alinharSeAtrasado] depois da hora dele (a leitura
 *   engasgou) empurra a âncora para agora, em vez de sair uma rajada de quadros atrasados;
 * - **a geração**: o pulo solta a âncora ([soltar]), e o som de uma geração velha não toca na nova.
 *
 * Puro (sem Android): os testes JVM o exercitam com um relógio de mentira. Os métodos são
 * `@Synchronized`: a thread do ritmo escreve, a do som e a tela leem.
 */
class RelogioDoDisco {
    /** A geração da âncora (o pulo troca a geração), -1 sem âncora nunca. */
    var geracao = -1
        @Synchronized get
        private set
    var ancorado = false
        @Synchronized get
        private set
    var pausado = false
        @Synchronized get
        private set
    /** Quantas vezes o atraso empurrou a âncora (o diário). */
    var reancoragens = 0
        @Synchronized get
        private set
    private var ancoraUs = 0L
    private var ancora90k = 0L
    private var pausadoEmUs = 0L

    /** O quadro [t90k] da [geracao] sai em [agoraUs]: a âncora. Com o relógio pausado, ele fica pausado ali. */
    @Synchronized
    fun ancorar(geracao: Int, t90k: Long, agoraUs: Long) {
        this.geracao = geracao
        ancoraUs = agoraUs
        ancora90k = t90k
        ancorado = true
        if (pausado) pausadoEmUs = agoraUs
    }

    /** O pulo: a âncora cai; o próximo quadro da geração nova ancora de novo. */
    @Synchronized
    fun soltar() {
        ancorado = false
    }

    /** A hora (µs do monotônico) em que o quadro [t90k] sai. Sem âncora, 0. */
    @Synchronized
    fun instanteUs(t90k: Long): Long = if (!ancorado) 0L else ancoraUs + paraUs(t90k - ancora90k)

    /** O tempo de saída (90 kHz) em [agoraUs]; pausado, o da pausa. `null` sem âncora. */
    @Synchronized
    fun posicao90k(agoraUs: Long): Long? {
        if (!ancorado) return null
        val t = if (pausado) pausadoEmUs else agoraUs
        return ancora90k + para90k(t - ancoraUs)
    }

    @Synchronized
    fun pausar(agoraUs: Long) {
        if (pausado) return
        pausado = true
        pausadoEmUs = agoraUs
    }

    @Synchronized
    fun continuar(agoraUs: Long) {
        if (!pausado) return
        pausado = false
        if (ancorado) ancoraUs += agoraUs - pausadoEmUs
    }

    /**
     * O quadro [t90k] passou da hora mais de [toleranciaUs] (a leitura engasgou, ou a rede ficou sem
     * saída): a âncora anda até ele sair agora. `true` quando andou.
     */
    @Synchronized
    fun alinharSeAtrasado(t90k: Long, agoraUs: Long, toleranciaUs: Long): Boolean {
        if (!ancorado || pausado) return false
        val atraso = agoraUs - (ancoraUs + paraUs(t90k - ancora90k))
        if (atraso <= toleranciaUs) return false
        ancoraUs += atraso
        reancoragens++
        return true
    }

    /**
     * A amostra (48 kHz, no tempo de saída do pipeline) que toca em [agoraUs], para o som da
     * [geracao]; `null` quando ele não toca (sem âncora, pausado, ou outra geração).
     */
    @Synchronized
    fun amostraEm(geracao: Int, agoraUs: Long): Long? {
        if (!ancorado || pausado || geracao != this.geracao) return null
        val t = ancora90k + para90k(agoraUs - ancoraUs)
        return Math.floorDiv(t * 8, 15L)  // 48000 / 90000
    }

    companion object {
        /** 90 kHz → µs (arredondado para baixo, também nos negativos). */
        fun paraUs(d90k: Long): Long = Math.floorDiv(d90k * 100, 9L)
        /** µs → 90 kHz. */
        fun para90k(dUs: Long): Long = Math.floorDiv(dUs * 9, 100L)
    }
}

/**
 * **Pular ±30 s** (`docs/dvd-para-mp4.md` §9, a T2): o tempo pedido vira a célula que o contém (pelo
 * acumulado do IFO) e um setor estimado dentro dela (pela fração do tempo da célula); a leitura
 * procura dali para a frente o **NAV pack** (o começo de um VOBU: o GOP fechado, o quadro I) e
 * reabre o fluxo do C **limpo** a partir dele, com o tempo do VOBU como zero da saída.
 *
 * O tempo do VOBU no título é o acumulado da célula + (`vobu_s_ptm` do VOBU − o do primeiro VOBU da
 * célula), que a leitura sabe lendo o primeiro setor da célula (um READ de um setor). Puro.
 */
object Reposicionamento {
    /** Onde começar a procurar o VOBU: a [celula] (o índice no título) e o [lba] estimado. */
    data class Alvo(val celula: Int, val lba: Long, val tempo90k: Long)

    /** A duração de cada célula (a diferença dos acumulados; a última, até [duracao90k]). */
    fun duracoes(trechos: List<TrechoDoTitulo>, duracao90k: Long): List<Long> = trechos.indices.map { i ->
        val fim = if (i + 1 < trechos.size) trechos[i + 1].acumulado90k else maxOf(duracao90k, trechos[i].acumulado90k)
        (fim - trechos[i].acumulado90k).coerceAtLeast(0)
    }

    /**
     * A célula e o setor estimado para o tempo [t90k] do título (limitado a [0, duração − 1 s]: pular
     * para o fim cai no último segundo, e não fora do título).
     */
    fun alvo(trechos: List<TrechoDoTitulo>, duracao90k: Long, t90k: Long): Alvo {
        require(trechos.isNotEmpty()) { "título sem células" }
        val t = t90k.coerceIn(0, maxOf(0, duracao90k - 90_000))
        var i = trechos.indexOfLast { it.acumulado90k <= t }
        if (i < 0) i = 0
        val c = trechos[i]
        val dur = duracoes(trechos, duracao90k)[i]
        val dentro = (t - c.acumulado90k).coerceAtLeast(0)
        val lba = if (dur <= 0) c.primeiro
        else (c.primeiro + (c.setores.toDouble() * dentro / dur).toLong()).coerceIn(c.primeiro, c.ultimo)
        return Alvo(i, lba, t)
    }

    /**
     * O `vobu_s_ptm` do setor, se ele é um NAV pack válido (o pack MPEG-2, o PES 0xBF com o
     * substream 0x00 do PCI, e o fim do VOBU depois do começo — o NAV zerado não vale); senão `null`.
     * A mesma regra de `dvd_confere_setor` (`dvd.c`).
     */
    fun navDoSetor(s: ByteArray, off: Int = 0): Long? {
        if (off < 0 || s.size < off + 2048) return null
        fun u8(i: Int) = s[off + i].toInt() and 0xFF
        fun be16(i: Int) = (u8(i) shl 8) or u8(i + 1)
        fun be32(i: Int) = (u8(i).toLong() shl 24) or (u8(i + 1).toLong() shl 16) or (u8(i + 2).toLong() shl 8) or u8(i + 3).toLong()
        if (be32(0) != 0x1BAL || (u8(4) and 0xC0) != 0x40) return null
        var o = 14 + (u8(13) and 7)
        while (o + 6 <= 2048) {
            if (u8(o) != 0 || u8(o + 1) != 0 || u8(o + 2) != 1 || u8(o + 3) < 0xBB) return null
            val id = u8(o + 3)
            val len = be16(o + 4)
            if (len == 0) return null
            val p = o + 6
            if (id == 0xBF && len >= 0x15 && p + 0x15 <= 2048 && u8(p) == 0x00) {
                val s0 = be32(p + 0x0D)
                val e0 = be32(p + 0x11)
                return if (e0 > s0) s0 else null
            }
            o += 6 + len
        }
        return null
    }

    /** A diferença de dois PTS de 33 bits, [depois] − [antes], com a volta do relógio. */
    fun diferenca33(depois: Long, antes: Long): Long {
        val m = (1L shl 33) - 1
        var d = (depois - antes) and m
        if (d >= (1L shl 32)) d -= 1L shl 33
        return d
    }

    /**
     * O tempo do VOBU no título: o acumulado da célula + (o `vobu_s_ptm` dele − o do primeiro VOBU da
     * célula). Fora da célula (o NAV de outra base, ou negativo), cai para a [estimativa].
     */
    fun tempoDoVobu(acumuladoDaCelula: Long, duracaoDaCelula: Long, sPtmDaCelula: Long?, sPtmDoVobu: Long, estimativa: Long): Long {
        if (sPtmDaCelula == null) return estimativa
        val d = diferenca33(sPtmDoVobu, sPtmDaCelula)
        return if (d < 0 || d > duracaoDaCelula + 90_000) estimativa else acumuladoDaCelula + d
    }

    /**
     * **A leitura de manutenção** (§8: o hp GTB0N desliga o motor ~45 s depois do último acesso, e a
     * partida derruba o leitor com a fonte fraca; a cada 20 s o motor nem para): um setor **perto** de
     * onde a leitura parou — à frente dela (2 a ~10 MB, fora do cache do leitor, que devolveria o mesmo
     * setor sem girar), um diferente a cada [n], dentro da célula; sem espaço à frente, atrás.
     */
    fun setorDeManutencao(trechos: List<TrechoDoTitulo>, ultimoLba: Long, n: Long): Long {
        require(trechos.isNotEmpty()) { "título sem células" }
        val t = trechos.firstOrNull { ultimoLba in it.primeiro..it.ultimo }
            ?: trechos.minByOrNull { minOf(kotlin.math.abs(it.primeiro - ultimoLba), kotlin.math.abs(it.ultimo - ultimoLba)) }!!
        val base = ultimoLba.coerceIn(t.primeiro, t.ultimo)
        val passo = 1_024L + (Math.floorMod(n, 16L)) * 256L
        return when {
            base + passo <= t.ultimo -> base + passo
            base - passo >= t.primeiro -> base - passo
            else -> t.primeiro + Math.floorMod(n, t.setores)
        }
    }

    /**
     * **O carimbo da gravação da transmissão** (a T4): o arquivo anda pelo conteúdo, e não pelo
     * relógio. O quadro seguinte da mesma geração, até 1 s depois no conteúdo, sai a essa distância do
     * anterior (a pausa não vira buraco: o conteúdo não andou); outra geração (o pulo) ou um salto
     * saem a um quadro ([ultimaDuracao90k]) do anterior — a costura sem salto de tempo. O primeiro
     * quadro ([ptsAnterior] < 0) é o 0. Devolve o carimbo e se o conteúdo continua.
     */
    fun carimboDaGravacao(
        ptsAnterior: Long, geracaoAnterior: Int, conteudoAnterior90k: Long, ultimaDuracao90k: Long,
        geracao: Int, conteudo90k: Long,
    ): Pair<Long, Boolean> {
        if (ptsAnterior < 0) return 0L to false
        val continua = geracao == geracaoAnterior && conteudo90k > conteudoAnterior90k &&
            conteudo90k - conteudoAnterior90k <= 90_000
        val passo = if (continua) conteudo90k - conteudoAnterior90k else ultimaDuracao90k
        return (ptsAnterior + passo) to continua
    }

    /**
     * Os trechos da leitura a partir do VOBU: o primeiro começa no [lba] do VOBU (dentro da [celula])
     * com o acumulado 0 — o zero da saída do pipeline novo —, e os seguintes com o acumulado menos a
     * [origem90k] (o tempo do VOBU no título).
     */
    fun trechosDesde(trechos: List<TrechoDoTitulo>, celula: Int, lba: Long, origem90k: Long): List<TrechoDoTitulo> {
        val c = trechos[celula]
        require(lba in c.primeiro..c.ultimo) { "o setor $lba não é da célula ${c.primeiro}..${c.ultimo}" }
        return listOf(TrechoDoTitulo(lba, c.ultimo, 0)) +
            trechos.drop(celula + 1).map { it.copy(acumulado90k = it.acumulado90k - origem90k) }
    }
}

/**
 * **O som da faixa na hora dele** (a T1): o PCM estéreo de 48 kHz que o pipeline entrega fica numa
 * fila com o índice da primeira amostra (o tempo de saída do pipeline: a amostra `n` é `n / 48000`
 * s), e cada quadro de 20 ms da rede leva as amostras da hora que o [RelogioDoDisco] diz:
 *
 * - dentro de [TOLERANCIA] da hora, as amostras seguem **contínuas** (nada de estalo por um
 *   arredondamento);
 * - atrasadas além disso (a leitura engasgou e o relógio andou), as velhas caem;
 * - adiantadas (um buraco no som), silêncio até a hora delas;
 * - sem âncora, pausado ou no meio de um pulo: silêncio, sem consumir.
 *
 * Pura: a [geracao] separa o som de um pipeline do seguinte (o pulo, [reiniciar]).
 */
class FilaDoSomDoDisco(private val capacidade: Int = 48_000 * 4) {
    private val fila = ShortArray(capacidade * 2)
    private var ini = 0
    private var n = 0
    /** O índice (no tempo de saída) da primeira amostra da fila. */
    private var inicio = 0L
    var geracao = -1
        @Synchronized get
        private set
    /** Os contadores do diário: amostras caídas por atraso, silêncio posto, amostras recusadas (fila cheia). */
    var caidas = 0L
        @Synchronized get
        private set
    var silencio = 0L
        @Synchronized get
        private set
    var recusadas = 0L
        @Synchronized get
        private set

    /** O pipeline novo (o começo, ou um pulo): a fila esvazia, e a amostra 0 é o tempo 0 dele. */
    @Synchronized
    fun reiniciar(geracao: Int) {
        this.geracao = geracao
        ini = 0; n = 0; inicio = 0
    }

    /** [amostras] estéreo intercaladas de [pcm] (s16), do pipeline da [geracao]; a de outra geração cai. */
    @Synchronized
    fun empurrar(geracao: Int, pcm: ShortArray, amostras: Int) {
        if (geracao != this.geracao || amostras <= 0) return
        var k = amostras
        var de = 0
        if (n + k > capacidade) {
            // Cheia (o relógio parado há muito): o mais velho sai, e o índice anda junto.
            val sai = minOf(n, n + k - capacidade)
            descartar(sai)
            recusadas += sai
            if (k > capacidade) { de = k - capacidade; inicio += de.toLong(); recusadas += de; k = capacidade }
        }
        for (i in 0 until k) {
            val p = (ini + n + i) % capacidade
            fila[2 * p] = pcm[2 * (de + i)]
            fila[2 * p + 1] = pcm[2 * (de + i) + 1]
        }
        n += k
    }

    private fun descartar(k: Int) {
        ini = (ini + k) % capacidade
        n -= k
        inicio += k.toLong()
    }

    /** Amostras na fila (o diário). */
    val tamanho: Int @Synchronized get() = n

    /** O índice (no tempo de saída) da amostra seguinte à última da fila: até onde o som já chegou. */
    val fim: Long @Synchronized get() = inicio + n

    /**
     * Enche [saida] com [amostras] amostras de [canais] canais (1: a média dos dois; 2: estéreo) para a
     * amostra [alvo] do tempo de saída da [geracao]; `alvo` `null` (sem âncora, pausado) ou outra
     * geração: silêncio, sem consumir.
     */
    @Synchronized
    fun tirar(geracao: Int, alvo: Long?, saida: ShortArray, amostras: Int, canais: Int) {
        java.util.Arrays.fill(saida, 0, amostras * canais, 0)
        if (alvo == null || geracao != this.geracao) return
        var pula = 0
        if (inicio < alvo - TOLERANCIA) {
            // As velhas caem; com a fila vazia e ainda atrasada, o índice fica (as amostras que chegarem
            // continuam de onde o pipeline parou, e caem na volta seguinte se ainda estiverem atrasadas).
            val cai = minOf(n.toLong(), alvo - inicio).toInt()
            descartar(cai)
            caidas += cai
        } else if (inicio > alvo + TOLERANCIA) {
            pula = minOf(amostras.toLong(), inicio - alvo).toInt()
            silencio += pula
        }
        val k = minOf(amostras - pula, n)
        for (i in 0 until k) {
            val p = (ini + i) % capacidade
            val l = fila[2 * p]
            val r = fila[2 * p + 1]
            val o = pula + i
            if (canais == 1) saida[o] = ((l + r) / 2).toShort()
            else { saida[2 * o] = l; saida[2 * o + 1] = r }
        }
        if (k > 0) descartar(k)
        // A fila secou (a leitura engasgou): o resto é silêncio; o som que chegar atrasado cai na volta seguinte.
        val falta = amostras - pula - k
        if (falta > 0) silencio += falta
    }

    companion object {
        /** 10 ms: abaixo disto, o som segue contínuo. */
        const val TOLERANCIA = 480L
    }
}

/**
 * **A folga da decodificação sobre a tela** (o som "pipocando" medido no A07, 29/09: `caídas=2453613
 * silêncio=2452971` em ~51 s — todo o som chegava atrasado e caía, e no lugar ia silêncio). A causa: no
 * fluxo do DVD o vídeo vem **adiantado** em relação ao som que toca junto (o `vbv_delay` do MPEG-2: o
 * pacote de vídeo entra no fluxo até ~0,7 s antes do PTS dele; o de som, perto do dele). O demuxer só
 * entrega o som da hora T quando já passou pelo vídeo de ~T + 0,7 s. Com a decodificação presa a 12
 * quadros (0,4 s) à frente da tela, o som da hora T só existia depois de T: sempre atrasado.
 *
 * O conserto: a decodificação anda [SEGUNDOS_DE_FOLGA] à frente da tela (os quadros escalados numa
 * fila desse tamanho), e o relógio só ancora com a fila cheia ([podeAncorar]) — no começo e em cada
 * pulo —, para o som chegar antes da hora dele desde o primeiro quadro. Puro.
 */
object PoliticaDoRitmo {
    /** Quanto a decodificação anda à frente da tela. */
    const val SEGUNDOS_DE_FOLGA = 1.5
    /** Esperando a fila encher para ancorar, no máximo isto (a leitura lenta não prende a imagem). */
    const val ESPERA_MAXIMA_DA_CARGA_US = 3_000_000L

    /** Os quadros da fila para [SEGUNDOS_DE_FOLGA] na taxa [fps] (45 no NTSC, 38 no PAL). */
    fun quadrosDeFolga(fps: Int): Int = kotlin.math.ceil(SEGUNDOS_DE_FOLGA * fps).toInt()

    /**
     * O relógio pode ancorar no primeiro quadro: a fila já tem a folga (menos dois, a folga da
     * decodificação que para com a fila cheia), o título acabou antes disso, ou a espera passou do
     * máximo.
     */
    fun podeAncorar(prontos: Int, folga: Int, fimDoTitulo: Boolean, esperandoUs: Long): Boolean =
        prontos >= folga - 2 || fimDoTitulo || esperandoUs >= ESPERA_MAXIMA_DA_CARGA_US
}
