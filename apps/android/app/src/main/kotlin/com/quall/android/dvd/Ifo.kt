package com.quall.android.dvd

/** Uma faixa de som do título, como o IFO a descreve (`docs/dvd-para-mp4.md` §2.3). */
data class FaixaDeSom(
    /** O substream do fluxo: 0x80+n AC-3, 0xA0+n LPCM, 0x1C0+n MPEG, 0x88+n DTS. */
    val substream: Int,
    val formato: String,
    val canais: Int,
    val taxa: Int,
    /** ISO 639-1 (duas letras), ou `null` quando o disco não diz. */
    val idioma: String?,
) {
    /** O Quall converte (o DTS não: sem decodificador livre adequado, §2.3). */
    val convertivel: Boolean get() = formato == "AC-3" || formato == "LPCM" || formato == "MPEG"
}

/** Um título do disco, pronto para a tela e para a conversão. */
data class TituloDoDvd(
    val numero: Int,
    val vts: Int,
    val angulos: Int,
    val capitulos: Int,
    val duracao90k: Long,
    /** As células na ordem da PGC: os setores absolutos e o acumulado (o C_PBTM). */
    val trechos: List<TrechoDoTitulo>,
    val pal: Boolean,
    val aspecto169: Boolean,
    val largura: Int,
    val altura: Int,
    val faixas: List<FaixaDeSom>,
    /** A frase de recusa (vários ângulos), ou `null`. */
    val recusa: Frase?,
) {
    /**
     * **Compatibilidade, para sair**: a vitrine de depuração monta o título com a recusa em `String`
     * (`Recusas.ANGULOS`); vira uma [Frase] crua. Quando ela passar a [FrasesDoDvd], este construtor some.
     */
    constructor(
        numero: Int, vts: Int, angulos: Int, capitulos: Int, duracao90k: Long, trechos: List<TrechoDoTitulo>,
        pal: Boolean, aspecto169: Boolean, largura: Int, altura: Int, faixas: List<FaixaDeSom>, recusa: String?,
    ) : this(numero, vts, angulos, capitulos, duracao90k, trechos, pal, aspecto169, largura, altura, faixas,
        recusa?.let { Frase.cru(it) })

    val setores: Long get() = trechos.sumOf { it.setores }
    val faixasConvertiveis: List<FaixaDeSom> get() = faixas.filter { it.convertivel }
    /** O aviso de som (só DTS: converte sem som), ou `null`. */
    val avisoDeSom: Frase? get() = if (faixas.isNotEmpty() && faixasConvertiveis.isEmpty()) FrasesDoDvd.SO_DTS else null
}

/**
 * **O IFO mínimo** (`docs/dvd-para-mp4.md` §2.3 e a revisão, 6): o VMGI_MAT e o TT_SRPT do
 * `VIDEO_TS.IFO`; de cada título, no `VTS_xx_0.IFO`, o VTSI_MAT (o começo do VTSTT_VOBS e os
 * atributos de vídeo e de som), o VTS_PTT_SRPT (as PGC do título, em ordem) e a PGCIT (a tabela de
 * controle de som, o C_PBI de cada célula). Sem arquivo nem USB: bytes entram, títulos saem (os
 * testes JVM montam IFO à mão).
 *
 * **Célula entrelaçada ou de ângulo recusa o título** (a revisão, 6): "este título tem vários
 * ângulos", em vez de misturar os ângulos.
 */
object Ifo {
    private fun be16(b: ByteArray, o: Int): Int = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)
    private fun be32(b: ByteArray, o: Int): Long =
        ((b[o].toLong() and 0xFF) shl 24) or ((b[o + 1].toLong() and 0xFF) shl 16) or
            ((b[o + 2].toLong() and 0xFF) shl 8) or (b[o + 3].toLong() and 0xFF)
    private fun u8(b: ByteArray, o: Int): Int = b[o].toInt() and 0xFF
    private fun bcd(v: Int): Int = (v shr 4) * 10 + (v and 0xF)

    /** O tempo BCD do DVD (hh mm ss ff, a taxa nos dois bits de cima de ff) em 90 kHz. */
    fun tempo90k(b: ByteArray, o: Int): Long {
        val h = bcd(u8(b, o)); val m = bcd(u8(b, o + 1)); val s = bcd(u8(b, o + 2))
        val ff = u8(b, o + 3)
        val quadro = if ((ff shr 6) == 1) 3600L else 3003L  // 1: 25 fps; 3: 29,97
        return (h * 3600L + m * 60L + s) * 90_000L + bcd(ff and 0x3F) * quadro
    }

    /** Uma entrada do TT_SRPT: o título `numero` está no VTS `vts`, título `ttn` dele. */
    data class EntradaDoTitulo(val numero: Int, val angulos: Int, val capitulos: Int, val vts: Int, val ttn: Int, val inicioDoVts: Long)

    /** O `VIDEO_TS.IFO`: os títulos do disco. */
    fun titulosDoVmg(vmg: ByteArray): List<EntradaDoTitulo> {
        require(vmg.size >= 0x100 && String(vmg, 0, 12, Charsets.ISO_8859_1) == "DVDVIDEO-VMG") { "não é um VIDEO_TS.IFO" }
        val o = (be32(vmg, 0xC4) * 2048).toInt()
        require(o in 0x100 until vmg.size - 8) { "TT_SRPT fora do arquivo" }
        val n = be16(vmg, o)
        return (0 until n).mapNotNull { i ->
            val e = o + 8 + 12 * i
            if (e + 12 > vmg.size) return@mapNotNull null
            EntradaDoTitulo(i + 1, u8(vmg, e + 1), be16(vmg, e + 2), u8(vmg, e + 6), u8(vmg, e + 7), be32(vmg, e + 8))
        }
    }

    /** As células que o pipeline em C aceita por título (`MAX_CELULAS` em `dvd.c`). */
    const val MAX_CELULAS = 4096

    /**
     * O título [t] a partir do `VTS_xx_0.IFO` dele ([vtsi]), que começa no setor [lbaDoVts] do
     * disco (o VTSTT_VOBS e as células são contados de lá). [setoresDoDisco] (o READ CAPACITY), quando se sabe: uma célula que passa dele recusa o
     * título (o IFO danificado; a revisão do código, 10).
     */
    fun titulo(t: EntradaDoTitulo, vtsi: ByteArray, lbaDoVts: Long, setoresDoDisco: Long? = null): TituloDoDvd {
        require(vtsi.size >= 0x300 && String(vtsi, 0, 12, Charsets.ISO_8859_1) == "DVDVIDEO-VTS") { "não é um VTS IFO" }
        val vobs = be32(vtsi, 0xC4)
        val pttO = (be32(vtsi, 0xC8) * 2048).toInt()
        val pgcitO = (be32(vtsi, 0xCC) * 2048).toInt()
        require(pttO in 0x300 until vtsi.size && pgcitO in 0x300 until vtsi.size) { "PTT_SRPT ou PGCIT fora do arquivo" }

        // o vídeo
        val v0 = u8(vtsi, 0x200); val v1 = u8(vtsi, 0x201)
        val pal = (v0 shr 4) and 3 == 1
        val aspecto169 = (v0 shr 2) and 3 == 3
        val altura = when ((v1 shr 2) and 3) { 3 -> if (pal) 288 else 240; else -> if (pal) 576 else 480 }
        val largura = when ((v1 shr 2) and 3) { 0 -> 720; 1 -> 704; else -> 352 }

        // as PGC do título, na ordem dos capítulos (a seguinte quando o título continua nela)
        val nTitulos = be16(vtsi, pttO)
        require(t.ttn in 1..nTitulos) { "o título ${t.ttn} não está no VTS ${t.vts} ($nTitulos)" }
        val fimPtt = pttO + be32(vtsi, pttO + 4).toInt() + 1
        val ini = pttO + be32(vtsi, pttO + 8 + 4 * (t.ttn - 1)).toInt()
        val fim = if (t.ttn < nTitulos) pttO + be32(vtsi, pttO + 8 + 4 * t.ttn).toInt() else fimPtt
        val pgcs = LinkedHashSet<Int>()
        var o = ini
        while (o + 4 <= minOf(fim, vtsi.size)) { pgcs += be16(vtsi, o); o += 4 }
        require(pgcs.isNotEmpty()) { "o título ${t.numero} sem capítulos" }

        val nPgc = be16(vtsi, pgcitO)
        var recusa: Frase? = if (t.angulos > 1) FrasesDoDvd.ANGULOS else null
        val trechos = ArrayList<TrechoDoTitulo>()
        var acumulado = 0L
        var controleDeSom: IntArray? = null
        for (pgcn in pgcs) {
            require(pgcn in 1..nPgc) { "PGC $pgcn fora da PGCIT ($nPgc)" }
            val pgc = pgcitO + be32(vtsi, pgcitO + 8 + 8 * (pgcn - 1) + 4).toInt()
            require(pgc + 0xEC <= vtsi.size) { "PGC $pgcn fora do arquivo" }
            if (controleDeSom == null) controleDeSom = IntArray(8) { be16(vtsi, pgc + 0x0C + 2 * it) }
            val nCelulas = u8(vtsi, pgc + 3)
            val cpb = pgc + be16(vtsi, pgc + 0xE8)
            for (c in 0 until nCelulas) {
                val e = cpb + 24 * c
                require(e + 24 <= vtsi.size) { "célula ${c + 1} da PGC $pgcn fora do arquivo" }
                val flags = u8(vtsi, e)
                val tipoDoBloco = (flags shr 4) and 3
                val entrelacada = flags and 0x04 != 0
                if (entrelacada || tipoDoBloco == 1) recusa = FrasesDoDvd.ANGULOS
                val dur = tempo90k(vtsi, e + 4)
                val primeiro = be32(vtsi, e + 8)
                val ultimo = be32(vtsi, e + 20)
                if (ultimo < primeiro) continue
                trechos += TrechoDoTitulo(lbaDoVts + vobs + primeiro, lbaDoVts + vobs + ultimo, acumulado)
                acumulado += dur
            }
        }

        // o som: os atributos do VTS e a tabela de controle da (primeira) PGC do título
        val nSom = be16(vtsi, 0x202).coerceIn(0, 8)
        val faixas = ArrayList<FaixaDeSom>()
        for (i in 0 until nSom) {
            val ctrl = controleDeSom!![i]
            if (ctrl and 0x8000 == 0) continue  // a faixa não existe nesta PGC
            val n = (ctrl shr 8) and 7
            val a = 0x204 + 8 * i
            val b0 = u8(vtsi, a); val b1 = u8(vtsi, a + 1)
            val (formato, base) = when ((b0 shr 5) and 7) {
                0 -> "AC-3" to 0x80
                2, 3 -> "MPEG" to 0x1C0
                4 -> "LPCM" to 0xA0
                6 -> "DTS" to 0x88
                else -> "?" to -1
            }
            if (base < 0) continue
            val idioma = if ((b0 shr 2) and 3 == 1) {
                val c = String(byteArrayOf(vtsi[a + 2], vtsi[a + 3]), Charsets.ISO_8859_1).lowercase()
                if (c.all { it in 'a'..'z' }) c else null
            } else null
            val taxa = if ((b1 shr 4) and 3 == 1) 96_000 else 48_000
            faixas += FaixaDeSom(base + n, formato, (b1 and 7) + 1, taxa, idioma)
        }
        if (recusa == null && trechos.size > MAX_CELULAS) recusa = FrasesDoDvd.CELULAS_DEMAIS
        if (recusa == null && setoresDoDisco != null && trechos.any { it.ultimo >= setoresDoDisco }) recusa = FrasesDoDvd.FORA_DO_DISCO
        if (recusa == null && trechos.isEmpty()) recusa = FrasesDoDvd.SEM_CELULAS
        return TituloDoDvd(t.numero, t.vts, t.angulos, t.capitulos, acumulado, trechos, pal, aspecto169,
            largura, altura, faixas, recusa)
    }
}
