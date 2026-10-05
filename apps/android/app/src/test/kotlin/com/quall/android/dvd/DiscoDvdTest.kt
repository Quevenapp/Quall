package com.quall.android.dvd

import com.quall.android.core.TextosDeTeste
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * A D3 sem disco: um DVD montado à mão, byte a byte — o ISO 9660 (e, no outro, o UDF), o
 * `VIDEO_TS.IFO` com dois títulos e o `VTS_01_0.IFO` com duas PGC: a primeira com três células e
 * três faixas de som (AC-3 5.1 em inglês, LPCM 96 kHz em português, DTS), a segunda com uma célula
 * de ângulo entrelaçada.
 */
class DiscoDvdTest {
    private class Imagem(setores: Int) : Setores {
        val b = ByteArray(setores * 2048)
        val lidos = ArrayList<Pair<Long, Int>>()
        override fun ler(lba: Long, n: Int): ByteArray {
            lidos += lba to n
            return b.copyOfRange((lba * 2048).toInt(), ((lba + n) * 2048).toInt())
        }
        fun u8(o: Int, v: Int) { b[o] = v.toByte() }
        fun be16(o: Int, v: Int) { u8(o, v shr 8); u8(o + 1, v) }
        fun be32(o: Int, v: Long) { be16(o, (v shr 16).toInt()); be16(o + 2, v.toInt()) }
        fun le16(o: Int, v: Int) { u8(o, v); u8(o + 1, v shr 8) }
        fun le32(o: Int, v: Long) { le16(o, v.toInt()); le16(o + 2, (v shr 16).toInt()) }
        fun txt(o: Int, s: String) { s.toByteArray(Charsets.ISO_8859_1).copyInto(b, o) }
    }

    /** O VIDEO_TS.IFO no setor [s] e o VTS_01_0.IFO no setor [v]. */
    private fun ifos(img: Imagem, s: Int, v: Int) {
        val vmg = s * 2048
        img.txt(vmg, "DVDVIDEO-VMG")
        img.be32(vmg + 0xC4, 1)  // TT_SRPT no setor 1 do IFO
        val tt = vmg + 2048
        img.be16(tt, 2)
        img.be32(tt + 4, 8 + 24 - 1L)
        // título 1: 1 ângulo, 2 capítulos, VTS 1 título 1
        img.u8(tt + 8 + 1, 1); img.be16(tt + 8 + 2, 2); img.u8(tt + 8 + 6, 1); img.u8(tt + 8 + 7, 1); img.be32(tt + 8 + 8, v.toLong())
        // título 2: 2 ângulos, VTS 1 título 2
        img.u8(tt + 20 + 1, 2); img.be16(tt + 20 + 2, 1); img.u8(tt + 20 + 6, 1); img.u8(tt + 20 + 7, 2); img.be32(tt + 20 + 8, v.toLong())

        val vts = v * 2048
        img.txt(vts, "DVDVIDEO-VTS")
        img.be32(vts + 0xC4, 20)  // o VTSTT_VOBS 20 setores depois do IFO
        img.be32(vts + 0xC8, 1)   // PTT_SRPT no setor 1
        img.be32(vts + 0xCC, 2)   // PGCIT no setor 2
        img.u8(vts + 0x200, 0x4C) // MPEG-2, NTSC, 16:9
        img.u8(vts + 0x201, 0x00) // 720x480
        img.be16(vts + 0x202, 3)
        // AC-3 5.1 "en"; LPCM 96 kHz estéreo "pt"; DTS 5.1 sem idioma
        img.u8(vts + 0x204, 0x04); img.u8(vts + 0x205, 0x05); img.txt(vts + 0x206, "en")
        img.u8(vts + 0x20C, 0x84); img.u8(vts + 0x20D, 0x11); img.txt(vts + 0x20E, "PT")
        img.u8(vts + 0x214, 0xC0); img.u8(vts + 0x215, 0x05)

        val ptt = vts + 2048
        img.be16(ptt, 2)
        img.be32(ptt + 4, 28 - 1L)
        img.be32(ptt + 8, 16); img.be32(ptt + 12, 24)
        img.be16(ptt + 16, 1); img.be16(ptt + 18, 1)  // capítulo 1: PGC 1, programa 1
        img.be16(ptt + 20, 1); img.be16(ptt + 22, 2)  // capítulo 2: PGC 1, programa 2
        img.be16(ptt + 24, 2); img.be16(ptt + 26, 1)  // título 2: PGC 2

        val pgcit = vts + 4096
        img.be16(pgcit, 2)
        img.be32(pgcit + 8 + 4, 24)
        img.be32(pgcit + 16 + 4, 24 + 512)
        val p1 = pgcit + 24
        img.u8(p1 + 2, 2); img.u8(p1 + 3, 3)
        img.be16(p1 + 0x0C, 0x8000)          // faixa 0: AC-3 fluxo 0
        img.be16(p1 + 0x0E, 0x8000)          // faixa 1: LPCM fluxo 0
        img.be16(p1 + 0x10, 0x8000 or 0x100) // faixa 2: DTS fluxo 1
        img.be16(p1 + 0xE8, 0x100)
        fun celula(pgc: Int, i: Int, flags: Int, s: Int, ff: Int, primeiro: Long, ultimo: Long) {
            val e = pgc + 0x100 + 24 * i
            img.u8(e, flags)
            img.u8(e + 6, ((s / 10) shl 4) or (s % 10)); img.u8(e + 7, ff)
            img.be32(e + 8, primeiro); img.be32(e + 20, ultimo)
        }
        celula(p1, 0, 0x00, 10, 0xC0, 0, 99)            // 10 s
        celula(p1, 1, 0x00, 59, 0xC0 or 0x15, 100, 999) // 59 s + 15 quadros
        celula(p1, 2, 0x02, 5, 0xC0, 1000, 1099)        // 5 s, descontinuidade do STC
        val p2 = pgcit + 24 + 512
        img.u8(p2 + 3, 1)
        img.be16(p2 + 0xE8, 0x100)
        celula(p2, 0, 0x50 or 0x04, 30, 0xC0, 2000, 2999) // primeira célula de um bloco de ângulo, entrelaçada
    }

    private fun confereTitulos(d: DiscoDvd, v: Long) {
        assertEquals(2, d.titulos.size)
        val t = d.titulos[0]
        assertNull(t.recusa)
        assertFalse(t.pal)
        assertTrue(t.aspecto169)
        assertEquals(720, t.largura)
        assertEquals(480, t.altura)
        val c2 = 59 * 90_000L + 15 * 3003L
        assertEquals(
            listOf(
                TrechoDoTitulo(v + 20, v + 20 + 99, 0),
                TrechoDoTitulo(v + 20 + 100, v + 20 + 999, 900_000),
                TrechoDoTitulo(v + 20 + 1000, v + 20 + 1099, 900_000 + c2),
            ),
            t.trechos,
        )
        assertEquals(900_000 + c2 + 450_000, t.duracao90k)
        assertEquals(
            listOf(
                FaixaDeSom(0x80, "AC-3", 6, 48_000, "en"),
                FaixaDeSom(0xA0, "LPCM", 2, 96_000, "pt"),
                FaixaDeSom(0x89, "DTS", 6, 48_000, null),
            ),
            t.faixas,
        )
        assertEquals(listOf(0x80, 0xA0), t.faixasConvertiveis.map { it.substream })
        assertNull(t.avisoDeSom)
        assertEquals(FrasesDoDvd.ANGULOS, d.titulos[1].recusa)
        // A frase sem idioma monta o mesmo português de antes, e o inglês (docs/traducao.md, Android).
        assertEquals("Este título tem vários ângulos; o Quall ainda não converte.", d.titulos[1].recusa!!.em(TextosDeTeste.PT))
        assertEquals("This title has multiple angles; Quall can’t convert it yet.", d.titulos[1].recusa!!.em(TextosDeTeste.EN))
        assertEquals(1, d.padrao?.numero)
    }

    @Test
    fun `ISO 9660, VIDEO_TS e o IFO minimo`() {
        val img = Imagem(80)
        // o descritor primário no 16, o terminador no 17
        img.u8(16 * 2048, 1); img.txt(16 * 2048 + 1, "CD001"); img.txt(16 * 2048 + 40, "FORMATURA_2004".padEnd(32))
        img.u8(17 * 2048, 255); img.txt(17 * 2048 + 1, "CD001")
        fun registro(o: Int, nome: String, lba: Int, tam: Int, dir: Boolean): Int {
            val len = (33 + nome.length + 1) and 1.inv()
            img.u8(o, len); img.le32(o + 2, lba.toLong()); img.le32(o + 10, tam.toLong())
            img.u8(o + 25, if (dir) 2 else 0); img.u8(o + 32, nome.length); img.txt(o + 33, nome)
            return o + len
        }
        registro(16 * 2048 + 156, "\u0000", 20, 2048, true)
        var o = registro(20 * 2048, "\u0000", 20, 2048, true)
        o = registro(o, "\u0001", 20, 2048, true)
        o = registro(o, "AUDIO_TS", 22, 2048, true)
        registro(o, "VIDEO_TS", 21, 2048, true)
        o = registro(21 * 2048, "\u0000", 21, 2048, true)
        o = registro(o, "\u0001", 20, 2048, true)
        o = registro(o, "VIDEO_TS.IFO;1", 30, 4096, false)
        o = registro(o, "VTS_01_0.IFO;1", 40, 3 * 2048, false)
        registro(o, "VTS_01_1.VOB;1", 60, 1100 * 2048, false)
        ifos(img, 30, 40)
        val d = DiscoDvd.ler(img)
        assertEquals("FORMATURA_2004", d.volume)
        assertEquals("ISO 9660", d.sistema)
        assertTrue(d.avisos.toString(), d.avisos.isEmpty())
        confereTitulos(d, 40)
        // os metadados em comandos de no máximo 32 setores
        assertTrue(img.lidos.all { it.second in 1..32 })
        // a célula que passa do fim do disco (o READ CAPACITY) recusa o título (a revisão do código, 10)
        val curto = DiscoDvd.ler(img, setoresDoDisco = 1000)
        assertEquals(FrasesDoDvd.FORA_DO_DISCO, curto.titulos[0].recusa)
        assertNull(curto.padrao)
    }

    @Test
    fun `UDF sem ISO`() {
        val img = Imagem(400)
        fun tag(setor: Int, id: Int) = img.le16(setor * 2048, id)
        tag(256, 2); img.le32(256 * 2048 + 16, 4 * 2048L); img.le32(256 * 2048 + 20, 257)
        tag(257, 1); img.u8(257 * 2048 + 24, 8); img.txt(257 * 2048 + 25, "CASAMENTO"); img.u8(257 * 2048 + 24 + 31, 10)
        tag(258, 5); img.le32(258 * 2048 + 188, 300)
        tag(259, 6); img.le32(259 * 2048 + 248, 2048); img.le32(259 * 2048 + 252, 0)
        tag(260, 8)
        tag(300, 256); img.le32(300 * 2048 + 404, 1)  // o FSD: a raiz no bloco 1
        fun fe(lbn: Int, dado: Int, tam: Int) {
            val o = (300 + lbn) * 2048
            img.le16(o, 261); img.le16(o + 34, 0)
            img.le32(o + 56, tam.toLong()); img.le32(o + 168, 0); img.le32(o + 172, 8)
            img.le32(o + 176, tam.toLong()); img.le32(o + 180, dado.toLong())
        }
        fun fid(o: Int, nome: String?, carac: Int, icb: Int): Int {
            img.le16(o, 257); img.u8(o + 18, carac)
            val n = if (nome == null) 0 else nome.length + 1
            img.u8(o + 19, n); img.le32(o + 24, icb.toLong()); img.le16(o + 36, 0)
            if (nome != null) { img.u8(o + 38, 8); img.txt(o + 39, nome) }
            return o + ((38 + n + 3) and 3.inv())
        }
        var o = 302 * 2048
        o = fid(o, null, 0x0A, 1)
        o = fid(o, "VIDEO_TS", 0x02, 3)
        fe(1, 2, o - 302 * 2048)
        o = 304 * 2048
        o = fid(o, null, 0x0A, 1)
        o = fid(o, "VIDEO_TS.IFO", 0, 5)
        o = fid(o, "VTS_01_0.IFO", 0, 6)
        fe(3, 4, o - 304 * 2048)
        fe(5, 10, 4096)       // VIDEO_TS.IFO nos setores 310..311
        fe(6, 20, 3 * 2048)   // VTS_01_0.IFO nos setores 320..322
        ifos(img, 310, 320)
        val d = DiscoDvd.ler(img)
        assertEquals("UDF", d.sistema)
        assertEquals("CASAMENTO", d.volume)
        confereTitulos(d, 320)
    }

    @Test
    fun `sem VIDEO_TS, o DVD-VR nao finalizado recusa com a frase`() {
        val img = Imagem(40)
        img.u8(16 * 2048, 1); img.txt(16 * 2048 + 1, "CD001")
        img.u8(17 * 2048, 255); img.txt(17 * 2048 + 1, "CD001")
        val r = 16 * 2048 + 156
        img.u8(r, 34); img.le32(r + 2, 20); img.le32(r + 10, 2048); img.u8(r + 25, 2); img.u8(r + 32, 1)
        val o = 20 * 2048
        img.u8(o, 42); img.le32(o + 2, 21); img.le32(o + 10, 2048); img.u8(o + 25, 2); img.u8(o + 32, 8); img.txt(o + 33, "DVD_RTAV")
        try {
            DiscoDvd.ler(img)
            fail("devia recusar")
        } catch (e: RecusaDoDisco) {
            assertEquals(FrasesDoDvd.NAO_FINALIZADO, e.recusa)
            assertEquals("Este disco não foi finalizado. Finalize-o no aparelho que gravou e tente de novo.",
                e.recusa.em(TextosDeTeste.PT))
            // A compatibilidade do `MirrorService` (que ainda lê `e.frase`): o mesmo português.
            assertEquals(Recusas.NAO_FINALIZADO, e.frase)

        }
    }

    @Test
    fun `o tempo BCD do DVD`() {
        val b = byteArrayOf(0x01, 0x02, 0x03, (0xC0 or 0x29).toByte(), 0x00, 0x00, 0x10, (0x40 or 0x24).toByte())
        assertEquals((3600L + 120 + 3) * 90_000 + 29 * 3003, Ifo.tempo90k(b, 0))
        assertEquals(10 * 90_000L + 24 * 3600, Ifo.tempo90k(b, 4))  // PAL: 25 quadros por segundo
    }
}
