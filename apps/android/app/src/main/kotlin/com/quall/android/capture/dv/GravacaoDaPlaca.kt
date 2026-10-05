package com.quall.android.capture.dv

import com.quall.android.R
import com.quall.android.capture.ParametrosDaGravacao

/**
 * As contas puras da gravação da placa de captura (a P4 adiantada, `docs/placa-de-captura-usb.md`
 * §9.6), para a JVM testar: a taxa do vídeo e a escolha da entrada de som.
 */
object GravacaoDaPlaca {
    /** O piso da taxa da placa: 640x480 pela regra da área (§14.2) dá ~2 Mbit/s, pouco para vídeo analógico com ruído. */
    const val PISO_BPS = 6_000_000
    const val FPS = 30

    /** A taxa: a regra da gravação da R5 (1080p30 a 14 Mbit/s pela área), com o piso de 6 Mbit/s. */
    fun taxa(largura: Int, altura: Int, fps: Int = FPS): Int =
        maxOf(PISO_BPS, ParametrosDaGravacao.taxa(emptyList(), largura, altura, fps).first)

    // ---- as escolhas da pessoa para a gravação da placa (§14.5) --------------------------------

    /**
     * O codec do arquivo: H.264 (toca em tudo) ou HEVC (menor na mesma qualidade). A [chave] é o que
     * fica guardado; o [rotulo], o texto da tela nos dois idiomas (`docs/traducao.md`, Android).
     */
    enum class Codec(val chave: String, val rotulo: Int) {
        H264("h264", R.string.placa_codec_h264), HEVC("hevc", R.string.placa_codec_hevc)
    }

    /** A qualidade: um fator sobre a taxa da regra ([taxa]). */
    enum class Qualidade(val chave: String, val rotulo: Int, val fator: Double) {
        ECONOMICA("economica", R.string.placa_qualidade_economica, 0.6),
        NORMAL("normal", R.string.placa_qualidade_normal, 1.0),
        ALTA("alta", R.string.placa_qualidade_alta, 2.0),
        MAXIMA("maxima", R.string.placa_qualidade_maxima, 4.0),
    }

    /** O HEVC chega à mesma qualidade com menos bits: 0,65 da taxa do H.264. */
    const val FATOR_DO_HEVC = 0.65
    /** O teto que o encoder aceita sem discutir (4K a 4× passaria de 200 Mbit/s). */
    const val TETO_BPS = 120_000_000

    private const val PREFS = "quall_video_usb"
    private fun prefs(c: android.content.Context) = c.applicationContext.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)

    fun codec(c: android.content.Context): Codec =
        Codec.values().firstOrNull { it.chave == prefs(c).getString("gravacao:codec", null) } ?: Codec.H264
    fun qualidade(c: android.content.Context): Qualidade =
        Qualidade.values().firstOrNull { it.chave == prefs(c).getString("gravacao:qualidade", null) } ?: Qualidade.NORMAL
    fun escolher(c: android.content.Context, codec: Codec) = prefs(c).edit().putString("gravacao:codec", codec.chave).apply()
    fun escolher(c: android.content.Context, q: Qualidade) = prefs(c).edit().putString("gravacao:qualidade", q.chave).apply()

    /** A taxa com as escolhas: a da regra, vezes a qualidade, vezes 0,65 no HEVC, até o [TETO_BPS]. */
    fun taxaEscolhida(largura: Int, altura: Int, fps: Int, codec: Codec, q: Qualidade): Int =
        (taxa(largura, altura, fps) * q.fator * (if (codec == Codec.HEVC) FATOR_DO_HEVC else 1.0))
            .toLong().coerceIn(1_000_000L, TETO_BPS.toLong()).toInt()

    /** Uma entrada de som do sistema (`AudioDeviceInfo`), só o que a escolha usa. */
    data class Entrada(val id: Int, val usb: Boolean, val nome: String, val embutido: Boolean = false)

    /**
     * **O microfone do telefone, pedido explicitamente** nas fontes que não são a placa (§8: com a
     * placa plugada, o `MIC` sem preferência lia da placa): a primeira entrada `TYPE_BUILTIN_MIC`, ou
     * nenhuma (aí vale a regra do sistema, e o diário diz o roteado).
     */
    fun escolherEmbutido(entradas: List<Entrada>): Entrada? = entradas.firstOrNull { it.embutido }

    /**
     * A entrada da placa: a USB cujo nome contém o `productName` do aparelho USB (o Android a chama
     * "USB-Audio - USB2.0 PC CAMERA", medido no S24, §1); sem casar pelo nome, a única USB de
     * entrada; senão nenhuma (duas USB sem nome que case: não se chuta).
     */
    fun escolherEntrada(entradas: List<Entrada>, nomeDaPlaca: String?): Entrada? {
        val usbs = entradas.filter { it.usb }
        val nome = nomeDaPlaca?.trim().orEmpty()
        if (nome.isNotEmpty()) usbs.firstOrNull { it.nome.contains(nome, ignoreCase = true) }?.let { return it }
        return usbs.singleOrNull()
    }
}

/**
 * A linha do tempo do som da placa contra a do vídeo (pura). O arquivo tem o som pela **contagem de
 * amostras** (o [GravadorMp4] dá a cada amostra o tempo `enviadas / taxa`), e cada bloco que o
 * `AudioRecord` entrega tem a hora de captura da primeira amostra (`getTimestamp`, CLOCK_MONOTONIC,
 * o relógio do carimbo do vídeo). Para cada bloco, [planejar] diz quantas amostras do começo pular e
 * quanto silêncio pôr antes, para a contagem acompanhar o relógio:
 * - antes do primeiro quadro (o zero do arquivo): o som cai;
 * - o primeiro bloco depois do zero: silêncio até a hora dele;
 * - depois, enquanto a contagem e o relógio concordam dentro de [toleranciaNs], nada; se o relógio
 *   passou à frente (o `AudioRecord` perdeu amostras), silêncio; se ficou atrás, amostras puladas;
 * - **no fim**, nada passa do fim do vídeo ([alvoDoFim], o `limite` de [planejar]), e o que faltar até
 *   ele vira silêncio ([completar]): o som e a imagem terminam juntos (§11, item 3).
 */
class LinhaDoSomDaPlaca(val taxa: Int = 48_000, val toleranciaNs: Long = 40_000_000L) {
    /** As amostras já postas no arquivo (por canal). */
    var enviadas = 0L
        private set
    var silencioPosto = 0L
        private set
    var puladas = 0L
        private set

    /** [pular] do começo do bloco, [silencio] antes dele, e [cortar] do fim (o fim do arquivo, [limite]). */
    data class Plano(val pular: Int, val silencio: Long, val cortar: Int = 0) {
        fun amostras(n: Int): Long = silencio + (n - pular - cortar)
    }

    /**
     * O bloco de [n] amostras cuja primeira foi capturada em [inicioNs]; [t0Ns] é o zero do vídeo.
     * Com [limite] (o fim do vídeo em amostras, [alvoDoFim]), nada passa dele: o silêncio e o fim do
     * bloco são cortados (§11, item 3: o som terminava ~51 ms antes da imagem).
     */
    fun planejar(inicioNs: Long, n: Int, t0Ns: Long, limite: Long = Long.MAX_VALUE): Plano {
        if (n <= 0) return Plano(0, 0)
        val p = planejarSemLimite(inicioNs, n, t0Ns)
        val cabe = (limite - enviadas).coerceAtLeast(0)
        val plano = when {
            p.silencio >= cabe -> Plano(n, cabe, 0)
            p.silencio + (n - p.pular) > cabe -> Plano(p.pular, p.silencio, (p.silencio + (n - p.pular) - cabe).toInt())
            else -> p
        }
        enviadas += plano.amostras(n)
        silencioPosto += plano.silencio
        puladas += plano.pular
        cortadas += plano.cortar
        return plano
    }

    /** As amostras cortadas do fim (o que passou do fim do vídeo). */
    var cortadas = 0L
        private set

    /**
     * O fim: o som acabou antes do vídeo (a leitura parou no prazo): o silêncio que falta até [alvo].
     * Soma em [enviadas] e [silencioPosto]; 0 se já chegou.
     */
    fun completar(alvo: Long): Long {
        val falta = (alvo - enviadas).coerceAtLeast(0)
        enviadas += falta
        silencioPosto += falta
        return falta
    }

    companion object {
        /**
         * O fim do vídeo em amostras do arquivo: o último quadro gravado ([ultimoQuadroNs], o carimbo
         * de chegada) mais a duração que ele tem no MP4 ([duracaoDoUltimoNs], um quadro a 30), contado
         * do zero [t0Ns], arredondado ao [multiplo] mais perto.
         *
         * O [multiplo] é o quadro do AAC (1024): o arquivo guarda o som em pacotes de 1024 amostras, e
         * um fim no meio de um pacote sai completado até o fim dele (até +21 ms). Com o total múltiplo
         * de 1024, o erro fica no arredondamento (±10,7 ms), dentro dos ±20 ms pedidos. Hipótese sobre
         * o encoder (o último pacote do fim de fluxo inteiro, o atraso de 2048 tirado do PTS, que é
         * múltiplo de 1024); a prova é o `ffprobe` do roteiro.
         */
        fun alvoDoFim(ultimoQuadroNs: Long, duracaoDoUltimoNs: Long, t0Ns: Long, taxa: Int = 48_000, multiplo: Int = 1): Long {
            val ns = ultimoQuadroNs + duracaoDoUltimoNs - t0Ns
            if (ns <= 0) return 0
            val amostras = (ns * taxa + 500_000_000L) / 1_000_000_000L
            val m = multiplo.coerceAtLeast(1).toLong()
            return (amostras + m / 2) / m * m
        }
    }

    private fun planejarSemLimite(inicioNs: Long, n: Int, t0Ns: Long): Plano {
        // a posição, em amostras do arquivo, em que a primeira amostra deste bloco deveria cair
        val medido = Math.floorDiv((inicioNs - t0Ns) * taxa, 1_000_000_000L)
        val tol = toleranciaNs * taxa / 1_000_000_000L
        val plano = if (enviadas == 0L) {
            when {
                medido + n <= 0 -> Plano(n, 0)                              // todo antes do vídeo
                medido < 0 -> Plano((-medido).toInt(), 0)                   // parte antes do vídeo
                else -> Plano(0, medido)                                    // começa depois: silêncio até ele
            }
        } else {
            val dif = medido - enviadas
            when {
                dif > tol -> Plano(0, dif)
                dif < -tol -> Plano(minOf(n.toLong(), -dif).toInt(), 0)
                else -> Plano(0, 0)
            }
        }
        return plano
    }
}
