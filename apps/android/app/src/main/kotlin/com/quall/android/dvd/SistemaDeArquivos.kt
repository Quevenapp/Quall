package com.quall.android.dvd

/** Um arquivo do disco: o setor do começo (contíguo, como os do DVD-Video) e o tamanho em bytes. */
data class ArquivoDoDisco(val nome: String, val lba: Long, val tamanho: Long, val diretorio: Boolean = false)

/** A raiz e o `VIDEO_TS` que o sistema de arquivos disse, e o nome do volume. */
data class ConteudoDoDisco(
    val volume: String,
    val raiz: List<ArquivoDoDisco>,
    /** `null`: o disco não tem `VIDEO_TS`. */
    val videoTs: List<ArquivoDoDisco>?,
    val sistema: String,
) {
    fun arquivo(nome: String): ArquivoDoDisco? = videoTs?.firstOrNull { it.nome.equals(nome, ignoreCase = true) }
}

/**
 * **O sistema de arquivos do DVD** (`docs/dvd-para-mp4.md` §2.3, a D3): o ISO 9660 (a ponte UDF/ISO
 * dos DVD-Video, como o disco medido no §1) e, sem ele, o UDF (o âncora no setor 256, a partição, o
 * conjunto de arquivos e os diretórios). Só lê o que o conversor precisa: a raiz, o `VIDEO_TS`, e
 * o nome do volume.
 */
object SistemaDeArquivos {
    /** O maior diretório ou extensão lido (a revisão do código, 10): um tamanho absurdo não vira OOM. */
    private const val MAIOR = 512L * 1024

    /**
     * Um sistema de arquivos que não se lê vira `null`; a recusa e o leitor parado não (a revisão
     * do código, 9: eles precisam chegar à tela com a frase deles).
     */
    private inline fun <T> tentar(f: () -> T?): T? = try {
        f()
    } catch (e: RecusaDoDisco) {
        throw e
    } catch (e: LeitorParou) {
        throw e
    } catch (e: Exception) {
        null
    }

    /**
     * O nome do volume para a tela: até o primeiro 0x00/0xFF, só o que se imprime (medido 29/09: o gravador
     * de mesa preenche o campo com 0xFF, e o `uiautomator` nem conseguia ler a tela com eles).
     */
    fun limparVolume(v: String): String =
        v.takeWhile { it != '\u0000' && it != '\u00FF' && it != '\uFFFD' }
            .filter { it.code in 0x20..0x7E || it.code in 0xC0..0xFE }
            .trim()

    fun ler(s: Setores): ConteudoDoDisco {
        val iso = tentar { iso9660(s) }
        if (iso != null && iso.videoTs != null) return iso
        val udf = tentar { udf(s) }
        if (udf != null && (udf.videoTs != null || iso == null)) return udf
        return iso ?: throw IllegalStateException("o disco não tem ISO 9660 nem UDF legível")
    }

    private fun le32(b: ByteArray, o: Int): Long =
        (b[o].toLong() and 0xFF) or ((b[o + 1].toLong() and 0xFF) shl 8) or
            ((b[o + 2].toLong() and 0xFF) shl 16) or ((b[o + 3].toLong() and 0xFF) shl 24)
    private fun le16(b: ByteArray, o: Int): Int = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8)
    private fun le64(b: ByteArray, o: Int): Long = le32(b, o) or (le32(b, o + 4) shl 32)

    /** Lê [bytes] a partir de [lba] em comandos de até 32 setores. */
    fun lerBytes(s: Setores, lba: Long, bytes: Long): ByteArray {
        val setores = ((bytes + 2047) / 2048).toInt()
        val saida = ByteArray(setores * 2048)
        var feito = 0
        while (feito < setores) {
            val n = minOf(LeitorDeDisco.SETORES_POR_COMANDO, setores - feito)
            s.ler(lba + feito, n).copyInto(saida, feito * 2048)
            feito += n
        }
        return saida
    }

    // ---- ISO 9660 ------------------------------------------------------------------------------

    fun iso9660(s: Setores): ConteudoDoDisco? {
        var pvd: ByteArray? = null
        for (setor in 16L until 32L) {
            val d = s.ler(setor, 1)
            if (String(d, 1, 5, Charsets.ISO_8859_1) != "CD001") return null
            val tipo = d[0].toInt() and 0xFF
            if (tipo == 1) { pvd = d; break }
            if (tipo == 255) break
        }
        val p = pvd ?: return null
        val volume = limparVolume(String(p, 40, 32, Charsets.ISO_8859_1))
        val raiz = listarIso(s, le32(p, 156 + 2), le32(p, 156 + 10))
        val vts = raiz.firstOrNull { it.diretorio && it.nome.equals("VIDEO_TS", true) }?.let { listarIso(s, it.lba, it.tamanho) }
        return ConteudoDoDisco(volume, raiz, vts, "ISO 9660")
    }

    private fun listarIso(s: Setores, lba: Long, tamanho: Long): List<ArquivoDoDisco> {
        val d = lerBytes(s, lba, tamanho.coerceIn(2048, MAIOR))
        val lista = ArrayList<ArquivoDoDisco>()
        var i = 0
        while (i < d.size) {
            val len = d[i].toInt() and 0xFF
            if (len == 0) { i = (i / 2048 + 1) * 2048; continue }  // o resto do setor é enchimento
            if (i + len > d.size || len < 34) break
            val flags = d[i + 25].toInt() and 0xFF
            val nlen = d[i + 32].toInt() and 0xFF
            if (i + 33 + nlen > d.size) break
            val primeiro = d[i + 33].toInt()
            if (!(nlen == 1 && (primeiro == 0 || primeiro == 1))) {  // "." e ".."
                val nome = String(d, i + 33, nlen, Charsets.ISO_8859_1).substringBefore(';').trimEnd('.')
                lista += ArquivoDoDisco(nome, le32(d, i + 2), le32(d, i + 10), flags and 2 != 0)
            }
            i += len
        }
        return lista
    }

    // ---- UDF -----------------------------------------------------------------------------------

    private fun tag(b: ByteArray, o: Int = 0): Int = le16(b, o)

    /** O "dstring" do UDF (o primeiro byte diz 8 ou 16 bits por caractere; o último, o tamanho). */
    private fun dstring(b: ByteArray, o: Int, campo: Int): String {
        val n = (b[o + campo - 1].toInt() and 0xFF).coerceAtMost(campo - 1)
        if (n <= 1) return ""
        return nomeUdf(b, o, n)
    }

    /** O identificador (d-characters OSTA): compressão 8 (Latin-1) ou 16 (UTF-16BE). */
    private fun nomeUdf(b: ByteArray, o: Int, n: Int): String = when (b[o].toInt() and 0xFF) {
        8 -> String(b, o + 1, n - 1, Charsets.ISO_8859_1)
        16 -> String(b, o + 1, (n - 1) and 1.inv(), Charsets.UTF_16BE)
        else -> ""
    }

    private class Particao(val inicio: Long)

    fun udf(s: Setores): ConteudoDoDisco? {
        val avdp = s.ler(256, 1)
        if (tag(avdp) != 2) return null
        val vdsTam = le32(avdp, 16)
        val vdsLoc = le32(avdp, 20)
        var particao: Particao? = null
        var fsdLbn = -1L
        var volume = ""
        val setores = ((vdsTam + 2047) / 2048).toInt().coerceIn(1, 32)
        val vds = lerBytes(s, vdsLoc, setores * 2048L)
        for (k in 0 until setores) {
            val o = k * 2048
            when (tag(vds, o)) {
                1 -> volume = limparVolume(dstring(vds, o + 24, 32))                              // Primary Volume Descriptor
                5 -> if (particao == null) particao = Particao(le32(vds, o + 188)) // Partition Descriptor
                6 -> fsdLbn = le32(vds, o + 248 + 4)                               // Logical Volume Descriptor
                8 -> break                                                          // Terminating
            }
        }
        val p = particao ?: return null
        if (fsdLbn < 0) return null
        val fsd = s.ler(p.inicio + fsdLbn, 1)
        if (tag(fsd) != 256) return null
        val raizIcb = le32(fsd, 400 + 4)
        val raiz = listarUdf(s, p, raizIcb)
        val vts = raiz.firstOrNull { it.diretorio && it.nome.equals("VIDEO_TS", true) }?.let { listarUdf(s, p, it.lba) }
        // Nos diretórios, `lba` é o ICB (o File Entry) em blocos da partição; nos arquivos, o
        // primeiro setor do dado, absoluto.
        return ConteudoDoDisco(volume, raiz, vts, "UDF")
    }

    /** O File Entry em [icb] (blocos da partição): as extensões do dado (absolutas) e o tamanho. */
    private fun extensoes(s: Setores, p: Particao, icb: Long): Pair<List<Pair<Long, Long>>, Long> {
        val fe = s.ler(p.inicio + icb, 1)
        val t = tag(fe)
        val (lEa, lAd, base) = when (t) {
            261 -> Triple(le32(fe, 168).toInt(), le32(fe, 172).toInt(), 176)  // File Entry
            266 -> Triple(le32(fe, 208).toInt(), le32(fe, 212).toInt(), 216)  // Extended File Entry
            else -> throw IllegalStateException("UDF: ICB $icb não é File Entry (tag $t)")
        }
        val tamanho = le64(fe, 56)
        val tipoAd = le16(fe, 16 + 18) and 7
        val ads = ArrayList<Pair<Long, Long>>()
        var o = base + lEa
        val fim = (o + lAd).coerceAtMost(2048)
        when (tipoAd) {
            0 -> while (o + 8 <= fim) {  // short_ad
                val len = le32(fe, o) and 0x3FFFFFFF
                if (len == 0L) break
                ads += (p.inicio + le32(fe, o + 4)) to len
                o += 8
            }
            1 -> while (o + 16 <= fim) {  // long_ad (a partição única do DVD)
                val len = le32(fe, o) and 0x3FFFFFFF
                if (len == 0L) break
                ads += (p.inicio + le32(fe, o + 4)) to len
                o += 16
            }
            3 -> ads += -1L to lAd.toLong()  // embutido no próprio File Entry
            else -> throw IllegalStateException("UDF: descritor de alocação $tipoAd")
        }
        return ads to tamanho
    }

    private fun listarUdf(s: Setores, p: Particao, icb: Long): List<ArquivoDoDisco> {
        val (ads, tamanho) = extensoes(s, p, icb)
        val d = if (ads.size == 1 && ads[0].first == -1L) {
            val fe = s.ler(p.inicio + icb, 1)
            val base = if (tag(fe) == 266) 216 + le32(fe, 208).toInt() else 176 + le32(fe, 168).toInt()
            fe.copyOfRange(base, (base + tamanho.toInt()).coerceAtMost(2048))
        } else {
            val partes = ads.map { (lba, len) ->
                val n = len.coerceAtMost(MAIOR)
                lerBytes(s, lba, n).copyOf(n.toInt())
            }
            val tudo = partes.fold(ByteArray(0)) { a, b -> if (a.size >= MAIOR) a else a + b }
            tudo.copyOf(minOf(tamanho.coerceAtMost(MAIOR), tudo.size.toLong()).toInt())
        }
        val lista = ArrayList<ArquivoDoDisco>()
        var o = 0
        while (o + 38 <= d.size) {
            if (tag(d, o) != 257) break
            val carac = d[o + 18].toInt() and 0xFF
            val lFi = d[o + 19].toInt() and 0xFF
            val icbFilho = le32(d, o + 20 + 4)
            val lIu = le16(d, o + 36)
            val nomeEm = o + 38 + lIu
            if (nomeEm + lFi > d.size) break
            val dir = carac and 2 != 0
            val pai = carac and 8 != 0
            if (!pai && lFi > 0) {
                val nome = nomeUdf(d, nomeEm, lFi)
                if (dir) {
                    lista += ArquivoDoDisco(nome, icbFilho, 0, diretorio = true)
                } else {
                    val (adsF, tamF) = extensoes(s, p, icbFilho)
                    val lba = adsF.firstOrNull()?.first ?: -1L
                    lista += ArquivoDoDisco(nome, lba, tamF)
                }
            }
            o += (38 + lIu + lFi + 3) and 3.inv()
        }
        return lista
    }
}
