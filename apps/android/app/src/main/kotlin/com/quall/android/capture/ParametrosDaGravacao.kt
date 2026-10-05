package com.quall.android.capture

/**
 * As contas da gravação local da tela R5 (`docs/teleprompter-com-camera.md` §5.1), puras, para a
 * JVM testar: o nível H.264, a taxa de bits e o tamanho que o codificador aceita.
 */
object ParametrosDaGravacao {

    /** Um perfil de gravação que o aparelho declara (`EncoderProfiles`/`CamcorderProfile`). */
    data class Perfil(val largura: Int, val altura: Int, val fps: Int, val bitrate: Int)

    /**
     * **A referência: 1080p30 a 14 Mbit/s** (decisão do Pessoa Exemplo, 24/09: o iPhone grava 1080p30 em
     * H.264 a ~16 Mbit/s; a faixa pedida foi 12–16). É o meio da faixa, e dá ~105 MB por minuto.
     *
     * Antes (fase 3) a taxa vinha do perfil de gravação do aparelho, e **sem o perfil do mesmo
     * tamanho, do mais perto escalado pela área**: no A07, que declara 720p30 a 9 Mbit/s, isso deu
     * 1080x1920 a **20,25 Mbit/s** — 1,5 GB em 10 min (a prova de 24/09). O perfil de 720p do
     * aparelho é generoso por pixel, e escalar a generosidade pela área multiplicou o excesso.
     */
    const val REFERENCIA_BPS = 14_000_000
    const val REFERENCIA_PIXELS = 1920L * 1080L
    const val REFERENCIA_FPS = 30

    /**
     * Quanto custa dobrar o fps: **1,5×**, e não 2× (o expoente é log2(1,5) ≈ 0,585). A 60 fps
     * cada quadro está mais perto do anterior, e o H.264 gasta menos por quadro; é a razão das
     * tabelas públicas de envio (1080p30 → 1080p60 em ~1,5×). 1080p60 fica em 21 Mbit/s.
     */
    const val EXPOENTE_DO_FPS = 0.585

    const val TAXA_MINIMA = 2_000_000
    const val TAXA_MAXIMA = 60_000_000

    /**
     * **A taxa da gravação** (§5.1, refeita em 24/09): a [REFERENCIA_BPS] escalada **pela área**
     * (proporcional aos pixels: 720p30 ≈ 6,2 Mbit/s; 4K30 = 56) e **pelo fps** ([EXPOENTE_DO_FPS]),
     * entre [TAXA_MINIMA] e [TAXA_MAXIMA].
     *
     * O perfil de gravação do aparelho (`CamcorderProfile`) entra **só como teto, e só o do mesmo
     * tamanho** (em pé ou deitado, ajustado ao fps pela mesma regra): um aparelho que declara menos
     * que a regra no tamanho exato sabe do codificador dele. O perfil de outro tamanho não entra — era
     * a escala dele que inflava a taxa. Devolve a taxa e de onde ela veio, para o diário.
     */
    fun taxa(perfis: List<Perfil>, largura: Int, altura: Int, fps: Int): Pair<Int, String> {
        val px = largura.toLong() * altura
        val f = maxOf(1, fps)
        fun fatorFps(de: Int, para: Int) = Math.pow(para.toDouble() / maxOf(1, de), EXPOENTE_DO_FPS)
        val regra = (REFERENCIA_BPS.toDouble() * px / REFERENCIA_PIXELS * fatorFps(REFERENCIA_FPS, f))
            .toLong().coerceIn(TAXA_MINIMA.toLong(), TAXA_MAXIMA.toLong()).toInt()
        val deOnde = "regra: 1080p30 a ${REFERENCIA_BPS / 1000} kbit/s, pela área e pelo fps" // i18n-fora: diário (de onde veio a taxa)
        val validos = perfis.filter { it.largura > 0 && it.altura > 0 && it.fps > 0 && it.bitrate > 0 }
        // O menor **depois** de ajustar cada um ao fps (a revisão, menor 1): um perfil de 60 fps com
        // taxa maior pode valer menos a 30 que um de 30.
        val ajustados = validos.filter { it.largura.toLong() * it.altura == px }
            .map { it to (it.bitrate * fatorFps(it.fps, f)).toLong().coerceIn(TAXA_MINIMA.toLong(), TAXA_MAXIMA.toLong()).toInt() }
        val (mesmo, doPerfil) = ajustados.minByOrNull { it.second } ?: (null to 0)
        if (mesmo != null) {
            if (doPerfil < regra) {
                return doPerfil to "perfil do aparelho ${mesmo.largura}x${mesmo.altura}@${mesmo.fps} " +
                    "${mesmo.bitrate / 1000} kbit/s, abaixo da regra (${regra / 1000} kbit/s)"
            }
        }
        return regra to deOnde
    }

    /**
     * O menor nível H.264 (×10: 31 = 3.1) que cabe [largura]×[altura] a [fps], pela tabela A-1 da
     * norma (tamanho do quadro e macroblocos por segundo). `null` acima do 5.2.
     */
    fun nivelMinimo(largura: Int, altura: Int, fps: Int): Int? {
        val mbs = ((largura + 15) / 16).toLong() * ((altura + 15) / 16)
        val mbps = mbs * fps
        // (nível, MaxFS, MaxMBPS)
        val tabela = listOf(
            Triple(31, 3_600L, 108_000L),
            Triple(32, 5_120L, 216_000L),
            Triple(40, 8_192L, 245_760L),
            Triple(42, 8_704L, 522_240L),
            Triple(50, 22_080L, 589_824L),
            Triple(51, 36_864L, 983_040L),
            Triple(52, 36_864L, 2_073_600L),
        )
        return tabela.firstOrNull { (_, fs, mb) -> mbs <= fs && mbps <= mb }?.first
    }

    /**
     * O tamanho que o codificador aceita: o pedido, ou o maior que couber mantendo a proporção,
     * em degraus de 1/8, com os dois lados pares. `null` se nem a metade couber.
     */
    fun tamanhoAceito(largura: Int, altura: Int, aceita: (Int, Int) -> Boolean): Pair<Int, Int>? {
        if (aceita(largura, altura)) return largura to altura
        for (oitavos in 7 downTo 4) {
            val w = (largura * oitavos / 8) and 1.inv()
            val h = (altura * oitavos / 8) and 1.inv()
            if (w > 0 && h > 0 && aceita(w, h)) return w to h
        }
        return null
    }

    /**
     * **O recuo do §14.4** (a chave de bancada `gravacao_teto_720`): o tamanho com o maior lado ≤ 1280
     * e o menor ≤ 720, na mesma proporção, os dois lados pares. Um tamanho que já cabe volta igual.
     */
    fun teto720(largura: Int, altura: Int): Pair<Int, Int> {
        val maior = maxOf(largura, altura)
        val menor = minOf(largura, altura)
        if (maior <= 1280 && menor <= 720) return largura to altura
        val escala = minOf(1280.0 / maior, 720.0 / menor)
        val w = Math.round(largura * escala).toInt() and 1.inv()
        val h = Math.round(altura * escala).toInt() and 1.inv()
        return w to h
    }

    /** µs → unidades de 1/90000 s, arredondado. */
    fun us90k(us: Long): Long = if (us >= 0) (us * 9 + 50) / 100 else -((-us * 9 + 50) / 100)

    /** Unidades de 1/90000 s → µs. */
    fun de90kUs(t: Long): Long = t * 100 / 9

    /**
     * A duração de um quadro no arquivo (1/90000 s): até o próximo; o último (sem próximo) leva a
     * do anterior, ou a de [fps] se não houver anterior. Sempre ≥ 1.
     */
    fun duracao(pts: Long, proximo: Long?, anterior: Long?, fps: Int): Long = when {
        proximo != null -> maxOf(1L, proximo - pts)
        anterior != null && anterior > 0 -> anterior
        else -> maxOf(1L, 90_000L / maxOf(1, fps))
    }
}
