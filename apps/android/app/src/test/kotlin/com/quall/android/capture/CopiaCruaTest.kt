package com.quall.android.capture

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream

/**
 * [CopiaCrua]: o formato da cópia ao lado da gravação do `MediaMuxer`
 * (`docs/teleprompter-com-camera.md` §14.4, §14.10, §14.12). Na JVM: o cabeçalho, os registros, o
 * corte no fim e o lixo com tamanho plausível (a revisão, 8), e a varredura que acha o fim da imagem.
 */
class CopiaCruaTest {

    private val formatos = FormatosDaGravacao(
        largura = 1080, altura = 1920,
        sps = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0x00, 0x28),
        pps = byteArrayOf(0, 0, 0, 1, 0x68, 0xCE.toByte(), 0x3C, 0x80.toByte()),
        taxaDoSom = 48_000, canaisDoSom = 1, bitrateDoSom = 96_000,
        asc = byteArrayOf(0x11, 0x88.toByte()),
        padraoDeCor = 1, faixaDeCor = 2, transferencia = 3,
    )

    /** Uma cópia com [quadros] de vídeo a 30 fps (IDR a cada 30) e o som a cada 1024 amostras. */
    private fun copia(quadros: Int, somAte: Long = quadros * 33_333L + 200_000L): ByteArray {
        val saida = ByteArrayOutputStream()
        saida.write(CopiaCrua.escreverCabecalho(42, "Quall-R5-20260928-120000.mp4", formatos))
        val o = DataOutputStream(saida)
        var som = 0L
        for (i in 0 until quadros) {
            val pts = i * 33_333L
            CopiaCrua.escreverRegistro(o, true, i % 30 == 0, pts, ByteArray(100 + i) { i.toByte() })
            while (som <= pts + 33_333L && som < somAte) {
                CopiaCrua.escreverRegistro(o, false, true, som, ByteArray(20) { 7 })
                som += 21_333L
            }
        }
        o.flush()
        return saida.toByteArray()
    }

    @Test
    fun o_cabecalho_volta_igual() {
        val b = CopiaCrua.escreverCabecalho(42, "Quall-R5-x.mp4", formatos)
        val c = CopiaCrua.lerCabecalho(DataInputStream(ByteArrayInputStream(b)))
        assertNotNull(c)
        assertEquals(42L, c!!.id)
        assertEquals("Quall-R5-x.mp4", c.nome)
        assertEquals(1080, c.formatos.largura)
        assertEquals(1920, c.formatos.altura)
        assertArrayEquals(formatos.sps, c.formatos.sps)
        assertArrayEquals(formatos.pps, c.formatos.pps)
        assertArrayEquals(formatos.asc, c.formatos.asc)
        assertEquals(3, c.formatos.transferencia)
    }

    @Test
    fun um_cabecalho_cortado_ou_mexido_nao_vale() {
        val b = CopiaCrua.escreverCabecalho(42, "x.mp4", formatos)
        assertNull(CopiaCrua.lerCabecalho(DataInputStream(ByteArrayInputStream(b.copyOf(b.size - 3)))))
        val mexido = b.copyOf().also { it[20] = (it[20] + 1).toByte() }
        assertNull(CopiaCrua.lerCabecalho(DataInputStream(ByteArrayInputStream(mexido))))
        assertNull(CopiaCrua.lerCabecalho(DataInputStream(ByteArrayInputStream(ByteArray(0)))))
    }

    @Test
    fun a_varredura_conta_os_quadros_e_acha_o_fim_da_imagem() {
        val v = CopiaCrua.varrer(ByteArrayInputStream(copia(90)))!!
        assertTrue(v.legivel)
        assertEquals(90, v.quadros)
        assertEquals(3, v.idrs)
        assertEquals(0L, v.inicioDoVideoUs)
        // O último quadro em 89 × 33 333 µs, mais a duração do anterior.
        assertEquals(90 * 33_333L, v.fimDoVideoUs)
    }

    @Test
    fun o_fim_cortado_no_meio_de_um_registro_para_no_ultimo_inteiro() {
        val tudo = copia(60)
        val inteira = CopiaCrua.varrer(ByteArrayInputStream(tudo))!!
        val cortada = CopiaCrua.varrer(ByteArrayInputStream(tudo.copyOf(tudo.size - 10)))!!
        assertEquals(inteira.registros - 1, cortada.registros)
    }

    @Test
    fun lixo_com_tamanho_plausivel_no_fim_nao_passa_pelo_crc() {
        val tudo = copia(30)
        val saida = ByteArrayOutputStream().apply { write(tudo) }
        // Um "registro" de vídeo com o tamanho certo e bytes zerados no lugar do CRC e dos dados: o
        // que um desligamento brusco deixa no fim do arquivo.
        DataOutputStream(saida).apply {
            writeByte(0); writeByte(0); writeLong(30 * 33_333L); writeInt(200); writeInt(0)
            write(ByteArray(200))
            flush()
        }
        val antes = CopiaCrua.varrer(ByteArrayInputStream(tudo))!!
        val depois = CopiaCrua.varrer(ByteArrayInputStream(saida.toByteArray()))!!
        assertEquals(antes.registros, depois.registros)
        assertEquals(antes.quadros, depois.quadros)
    }

    @Test
    fun sem_nenhum_idr_nao_e_legivel() {
        val saida = ByteArrayOutputStream()
        saida.write(CopiaCrua.escreverCabecalho(1, "x.mp4", formatos))
        val o = DataOutputStream(saida)
        CopiaCrua.escreverRegistro(o, false, true, 0, ByteArray(10))
        CopiaCrua.escreverRegistro(o, true, false, 0, ByteArray(10))
        o.flush()
        val v = CopiaCrua.varrer(ByteArrayInputStream(saida.toByteArray()))!!
        assertFalse(v.legivel)
        assertEquals(0, v.quadros)
    }

    @Test
    fun a_varredura_conta_o_som_dentro_da_imagem() {
        // O som vai até 200 ms depois da imagem: os de fora não contam.
        val v = CopiaCrua.varrer(ByteArrayInputStream(copia(30)))!!
        assertTrue(v.sonsNaFaixa > 0)
        val semSom = CopiaCrua.varrer(ByteArrayInputStream(copia(30, somAte = 0)))!!
        assertEquals(0, semSom.sonsNaFaixa)
    }

    @Test
    fun o_registro_volta_igual_com_o_crc() {
        val saida = ByteArrayOutputStream()
        val o = DataOutputStream(saida)
        val dados = ByteArray(1234) { (it * 7).toByte() }
        CopiaCrua.escreverRegistro(o, true, true, 123_456_789L, dados)
        o.flush()
        val r = CopiaCrua.lerRegistro(DataInputStream(ByteArrayInputStream(saida.toByteArray())))!!
        assertTrue(r.video)
        assertTrue(r.chave)
        assertEquals(123_456_789L, r.ptsUs)
        assertArrayEquals(dados, r.dados)
    }
}
