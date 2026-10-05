package com.quall.android.dvd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

/** A D2 sem USB: as regras que falham fechado e a ordem do que a leitura empurra. */
class LeituraDoTituloTest {
    @Test
    fun `o CPST ilegivel ou diferente de zero recusa`() {
        assertFalse(PoliticaDoDisco.recusaPeloCpst(0))
        assertTrue(PoliticaDoDisco.recusaPeloCpst(1))  // CSS/CPPM
        assertTrue(PoliticaDoDisco.recusaPeloCpst(2))  // CPRM
        assertTrue(PoliticaDoDisco.recusaPeloCpst(3))
        assertTrue(PoliticaDoDisco.recusaPeloCpst(null))  // ilegível
    }

    @Test
    fun `so o gravavel pula bloco, e o perfil desconhecido e prensado`() {
        for (p in listOf(0x11, 0x13, 0x14, 0x1A, 0x1B, 0x2B)) assertTrue(PoliticaDoDisco.gravavel(p))
        assertFalse(PoliticaDoDisco.gravavel(0x10))  // DVD-ROM
        assertFalse(PoliticaDoDisco.gravavel(null))
        assertFalse(PoliticaDoDisco.gravavel(0x08))
        // O book type manda (29/09: o DVD-R TDK finalizado com o perfil atual DVD-ROM no hp GTB0N).
        assertTrue(PoliticaDoDisco.gravavel(0x10, 2))
        assertFalse(PoliticaDoDisco.gravavel(0x10, 0))   // prensado
        assertFalse(PoliticaDoDisco.gravavel(0x1B, 0))   // DVD+R com bitsetting: o lado seguro
        assertTrue(PoliticaDoDisco.gravavel(0x11, null)) // book ilegível: o perfil de reserva
        assertFalse(PoliticaDoDisco.pulaBlocoRuim(false))
        assertTrue(PoliticaDoDisco.senseDeProtecao(0x6F))
        assertTrue(PoliticaDoDisco.senseDeDiscoTrocado(0x28))
        assertFalse(PoliticaDoDisco.senseDeDiscoTrocado(0x11))
        assertFalse(PoliticaDoDisco.senseDeProtecao(0x11))
    }

    private class Disco : Setores {
        val pedidos = ArrayList<Pair<Long, Int>>()
        var falharEm = -1L
        override fun ler(lba: Long, n: Int): ByteArray {
            pedidos += lba to n
            if (lba == falharEm) throw RecusaDoDisco(FrasesDoDvd.PROTEGIDO)
            return ByteArray(n * 2048) { (lba and 0xFF).toByte() }
        }
    }

    private class Destino : DestinoDaLeitura {
        val eventos = ArrayList<String>()
        var fim = false
        var abortado = 0
        var proximo = 0L
        override fun celula(pos: Long, acumulado90k: Long): Int { eventos += "celula $pos $acumulado90k"; return 0 }
        override fun empurrar(buf: ByteBuffer, n: Int, pos: Long): Int {
            assertEquals("contíguo", proximo, pos)
            assertEquals(0, n % 2048)
            proximo += n
            eventos += "bloco $pos ${n / 2048}"
            return 0
        }
        override fun fimDaEntrada() { fim = true }
        override fun abortar(erro: Int) { abortado = erro }
    }

    @Test
    fun `os trechos em ordem, 64 KB sem passar da ponta, a celula antes do dado`() {
        val disco = Disco()
        val destino = Destino()
        val l = LeituraDoTitulo(disco, listOf(TrechoDoTitulo(1000, 1039, 0), TrechoDoTitulo(5000, 5004, 90000)), destino)
        l.ler()
        assertEquals(listOf(1000L to 32, 1032L to 8, 5000L to 5), disco.pedidos)
        assertEquals(
            listOf("celula 0 0", "bloco 0 32", "bloco 65536 8", "celula 81920 90000", "bloco 81920 5"),
            destino.eventos,
        )
        assertTrue(destino.fim)
        assertEquals(45L, l.lidos)
        assertEquals(45L, l.total)
        assertNull(l.falha)
    }

    @Test
    fun `a recusa do leitor para o pipeline com o erro da protecao`() {
        val disco = Disco().apply { falharEm = 1032 }
        val destino = Destino()
        val l = LeituraDoTitulo(disco, listOf(TrechoDoTitulo(1000, 1100, 0)), destino)
        l.ler()
        assertFalse(destino.fim)
        assertEquals(QuallDvd.ERRO_CIFRADO, destino.abortado)
        assertTrue(l.falha is RecusaDoDisco)
        assertEquals(FrasesDoDvd.PROTEGIDO, (l.falha as RecusaDoDisco).recusa)
    }

    /**
     * A revisão da transmissão, 1: o pulo para a leitura (`parar`) no meio do bloco que o leitor recusa.
     * A recusa fica em `falha` — é dela que a transmissão lê antes de descartar o pipeline velho.
     */
    @Test
    fun `a recusa que chega junto com o parar do pulo nao se perde`() {
        lateinit var l: LeituraDoTitulo
        val disco = object : Setores {
            override fun ler(lba: Long, n: Int): ByteArray {
                if (lba >= 1032) { l.parar(); throw RecusaDoDisco(FrasesDoDvd.PROTEGIDO, "prensado com setor ilegível em $lba") }
                return ByteArray(n * 2048)
            }
        }
        val destino = Destino()
        l = LeituraDoTitulo(disco, listOf(TrechoDoTitulo(1000, 1100, 0)), destino)
        l.ler()
        assertTrue(l.falha is RecusaDoDisco)
        assertFalse(destino.fim)
    }

    @Test
    fun `o setor cifrado que o C recusa vira a recusa da leitura`() {
        val destino = object : DestinoDaLeitura {
            override fun celula(pos: Long, acumulado90k: Long) = 0
            override fun empurrar(buf: ByteBuffer, n: Int, pos: Long) = if (pos > 0) QuallDvd.ERRO_CIFRADO else 0
            override fun fimDaEntrada() {}
            override fun abortar(erro: Int) {}
        }
        val l = LeituraDoTitulo(Disco(), listOf(TrechoDoTitulo(1000, 1100, 0)), destino)
        l.ler()
        assertTrue(l.falha is RecusaDoDisco)
        assertEquals(FrasesDoDvd.PROTEGIDO, (l.falha as RecusaDoDisco).recusa)
    }
}
