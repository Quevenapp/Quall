package com.quall.android.capture

import com.quall.android.capture.dv.Descritores
import com.quall.android.capture.dv.EscolhaDeFormato
import com.quall.android.capture.dv.Quadro
import com.quall.android.capture.dv.TipoUsb
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A placa de captura EasyCap Arkmicro (`18ec:5555`), com os números que o espião leu dela no S24
 * na P0 (`docs/placa-de-captura-usb.md` §1 e §8): UVC 1.00, VC na interface 0, VS na 1 com o
 * endpoint 0x83, um formato só (`VS_FORMAT_MJPEG`, índice 1), um quadro só (`VS_FRAME_MJPEG`
 * índice 1, 640x480, buffer 614400, padrão 333333, intervalos 166666/333333/666666/2000000), e
 * as alternativas isócronas de 192 a 3000 (a 11 é high-bandwidth, `wMaxPacketSize` 0x13e8).
 */
class DescritoresPlacaTest {
    private fun b(vararg v: Int) = v.map { it.toByte() }
    private fun u32(v: Long) = b((v and 0xFF).toInt(), ((v shr 8) and 0xFF).toInt(), ((v shr 16) and 0xFF).toInt(), ((v shr 24) and 0xFF).toInt())
    private fun u16(v: Int) = b(v and 0xFF, (v shr 8) and 0xFF)

    private fun quadroMjpeg(indice: Int, w: Int, h: Int, padrao: Long, vararg ints: Long): List<Byte> =
        b(26 + 4 * ints.size, 0x24, 0x07, indice, 0) + u16(w) + u16(h) +
            u32(w.toLong() * h * 16 * 5) + u32(w.toLong() * h * 16 * 30) + // bitrate mín./máx.
            u32(614400) + u32(padrao) + b(ints.size) + ints.flatMap { u32(it) }

    private fun formatoMjpeg(indice: Int, nQuadros: Int) = b(11, 0x24, 0x06, indice, nQuadros, 1, 1, 0, 0, 0, 0)

    /** As alternativas medidas: psize 192 ... 1024 e as de alta largura de banda até 3000. */
    private val alts: List<Byte> = listOf(0x00C0, 0x0180, 0x0200, 0x0280, 0x0320, 0x03B0, 0x0A00, 0x0B20, 0x0B84, 0x1300, 0x13E8)
        .flatMapIndexed { i, mps -> b(9, 4, 1, i + 1, 1, 0x0E, 2, 0, 0) + b(7, 5, 0x83, 5) + u16(mps) + b(1) }

    private fun placa(vararg formatos: List<Byte>): ByteArray = (
        b(9, 2, 0, 0, 4, 1, 0, 0x80, 250) +
            b(8, 0x0B, 0, 2, 0x0E, 3, 0, 0) +
            b(9, 4, 0, 0, 1, 0x0E, 1, 0, 0) +
            b(13, 0x24, 1, 0x00, 0x01, 51, 0, 0, 0x6C, 0xDC, 0x02, 1, 1) +
            b(9, 4, 1, 0, 0, 0x0E, 2, 0, 0) +
            b(14, 0x24, 1, formatos.size, 0, 0, 0x83, 0, 0, 0, 0, 0, 0, 0) +
            formatos.fold(emptyList<Byte>()) { a, f -> a + f } +
            alts
        ).toByteArray()

    private val easycap = placa(
        formatoMjpeg(1, 1) + quadroMjpeg(1, 640, 480, 333333, 166666, 333333, 666666, 2000000),
    )

    @Test
    fun osDescritoresDaPlaca() {
        val d = Descritores.analisar(easycap)
        assertEquals(0x0100, d.bcdUvc)
        assertEquals(0, d.vcInterface)
        val vs = d.vss[1]!!
        assertEquals(0x83, vs.endpointDoCabecalho)
        assertEquals(1, vs.formatos.size)
        val f = vs.formatos[0]
        assertEquals(0x06, f.subtipo)
        assertEquals("MJPEG", f.detalhe)
        assertEquals(1, f.quadros.size)
        val q = f.quadros[0]
        assertEquals(1, q.indice)
        assertEquals(640, q.largura)
        assertEquals(480, q.altura)
        assertEquals(333333L, q.intervaloPadrao)
        assertEquals(listOf(166666L, 333333L, 666666L, 2000000L), q.intervalos)
        assertFalse(q.continuo)
        assertEquals(614400L, q.bufferMax)
        assertEquals(11, vs.alts.size)
        assertEquals(3000, vs.alts.last().psize)  // 0x13e8 = 1000 x 3
        assertEquals(11, vs.alts.last().alt)
        assertTrue(d.resumo().contains("1:640x480 padrão 333333 166666/333333/666666/2000000"))
    }

    @Test
    fun aPlacaEscolheMjpeg640x480a30() {
        val e = EscolhaDeFormato.escolher(Descritores.analisar(easycap))
        assertNotNull(e)
        e!!
        assertEquals(TipoUsb.MJPEG, e.tipo)
        assertEquals(1, e.formato.indice)
        assertEquals(1, e.quadro!!.indice)
        assertEquals(640, e.quadro!!.largura)
        assertEquals(480, e.quadro!!.altura)
        assertEquals(333333L, e.intervalo)
        assertEquals(1, TipoUsb.MJPEG.codigo)  // o FORMATO_MJPEG do C
        assertEquals(0, TipoUsb.DV.codigo)
    }

    @Test
    fun comDvEMjpegADvVemPrimeiroEHerda() {
        // FORMAT_DV antes, na mesma VS: a DV ganha, sem quadro nem intervalo (herda, como a GS500).
        val dv = b(9, 0x24, 0x0C, 2, 0xC0, 0xD4, 0x01, 0x00, 0x80)
        val d = Descritores.analisar(placa(formatoMjpeg(1, 1) + quadroMjpeg(1, 640, 480, 333333, 333333), dv))
        val e = EscolhaDeFormato.escolher(d)!!
        assertEquals(TipoUsb.DV, e.tipo)
        assertEquals(2, e.formato.indice)
        assertNull(e.quadro)
        assertNull(e.intervalo)
    }

    @Test
    fun semDvNemMjpegNaoHaEscolha() {
        // Só YUY2 (VS_FORMAT_UNCOMPRESSED, 0x04): a abertura diz "não tem DV nem MJPEG".
        val yuy2 = b(27, 0x24, 0x04, 1, 1) + List(22) { 0.toByte() }
        assertNull(EscolhaDeFormato.escolher(Descritores.analisar(placa(yuy2))))
    }

    @Test
    fun mjpegSemQuadroNaoEEscolhido() {
        assertNull(EscolhaDeFormato.escolher(Descritores.analisar(placa(formatoMjpeg(1, 0)))))
    }

    @Test
    fun oMaiorQuadroAte1080p() {
        val qs = listOf(Quadro(1, 640, 480, 333333, listOf(333333)), Quadro(2, 2560, 1440, 333333, listOf(333333)),
            Quadro(3, 1920, 1080, 333333, listOf(333333)))
        assertEquals(3, EscolhaDeFormato.quadro(qs)!!.indice)
        // Na placa, o maior até 720x576: o PAL ganha do NTSC.
        val d = Descritores.analisar(placa(
            formatoMjpeg(1, 2) + quadroMjpeg(1, 640, 480, 333333, 333333) + quadroMjpeg(2, 720, 576, 400000, 400000),
        ))
        assertEquals(2, EscolhaDeFormato.escolher(d)!!.quadro!!.indice)
        // Nenhum cabe em 1080p: o menor.
        val so4k = listOf(Quadro(1, 3840, 2160, 333333, listOf(333333)), Quadro(2, 2560, 1440, 333333, listOf(333333)))
        assertEquals(2, EscolhaDeFormato.quadro(so4k)!!.indice)
    }

    @Test
    fun oIntervaloMaisPertoDe30() {
        fun q(vararg i: Long, padrao: Long = 0, continuo: Boolean = false) =
            Quadro(1, 640, 480, padrao, i.toList(), continuo)
        assertEquals(333333L, EscolhaDeFormato.intervalo(q(166666, 333333, 666666, 2000000)))
        // Sem 30: o mais perto (25 e 60 -> 25, 400000 está a 66667; 166666 a 166667).
        assertEquals(400000L, EscolhaDeFormato.intervalo(q(166666, 400000, 666666)))
        // Empate: o mais curto.
        assertEquals(333000L, EscolhaDeFormato.intervalo(q(333666, 333000)))
        // Lista vazia: o padrão.
        assertEquals(500000L, EscolhaDeFormato.intervalo(q(padrao = 500000)))
        // Contínuo [mín, máx, passo].
        assertEquals(333333L, EscolhaDeFormato.intervalo(q(166666, 2000000, 1, continuo = true)))
        assertEquals(400000L, EscolhaDeFormato.intervalo(q(400000, 2000000, 100000, continuo = true)))
        assertEquals(300000L, EscolhaDeFormato.intervalo(q(100000, 1000000, 100000, continuo = true)))
    }

    @Test
    fun quadroContinuoNosDescritores() {
        // bFrameIntervalType 0: mín., máx., passo.
        val cont = b(38, 0x24, 0x07, 1, 0) + u16(640) + u16(480) + u32(0) + u32(0) + u32(614400) +
            u32(333333) + b(0) + u32(166666) + u32(2000000) + u32(166666)
        val q = Descritores.analisar(placa(formatoMjpeg(1, 1) + cont)).vss[1]!!.formatos[0].quadros[0]
        assertTrue(q.continuo)
        assertEquals(listOf(166666L, 2000000L, 166666L), q.intervalos)
        assertEquals(333332L, EscolhaDeFormato.intervalo(q))
    }

    // --- a revisão do código da P1, 2: só a placa de captura, e não uma webcam ---------------

    @Test
    fun umaWebcamComYuy2EMjpeg720pNaoEAceita() {
        // Uma webcam UVC comum: VS_FORMAT_UNCOMPRESSED (YUY2) 640x480 e MJPEG até 1280x720.
        val yuy2 = b(27, 0x24, 0x04, 1, 1) + List(22) { 0.toByte() } +
            (b(30, 0x24, 0x05, 1, 0) + u16(640) + u16(480) + List(21) { 0.toByte() })
        val mjpeg = formatoMjpeg(2, 2) + quadroMjpeg(1, 640, 480, 333333, 333333) +
            quadroMjpeg(2, 1280, 720, 333333, 333333)
        val d = Descritores.analisar(placa(yuy2, mjpeg))
        assertEquals(2, d.vss[1]!!.formatos.size)
        assertFalse(EscolhaDeFormato.ehPlacaDeCaptura(d.vss[1]!!))
        assertNull(EscolhaDeFormato.escolher(d))
    }

    @Test
    fun soMjpegMasAcimaDe720x576NaoEPlaca() {
        val d = Descritores.analisar(placa(formatoMjpeg(1, 1) + quadroMjpeg(1, 1280, 720, 333333, 333333)))
        assertNull(EscolhaDeFormato.escolher(d))
    }

    @Test
    fun mjpegComFrameBasedNaoEPlaca() {
        val h264 = b(28, 0x24, 0x10, 2, 1) + List(23) { 0.toByte() }
        val d = Descritores.analisar(placa(formatoMjpeg(1, 1) + quadroMjpeg(1, 640, 480, 333333, 333333), h264))
        assertNull(EscolhaDeFormato.escolher(d))
    }

    @Test
    fun aEasyCapMedidaEPlaca() {
        assertTrue(EscolhaDeFormato.ehPlacaDeCaptura(Descritores.analisar(easycap).vss[1]!!))
    }

    // --- a revisão do código da P1, 1: o probe aceito ------------------------------------------

    private fun cur(formato: Int, quadro: Int) = ByteArray(26).also { it[2] = formato.toByte(); it[3] = quadro.toByte() }

    @Test
    fun oQuadroAceitoVemDoGetCur() {
        val f = Descritores.analisar(placa(
            formatoMjpeg(1, 2) + quadroMjpeg(1, 640, 480, 333333, 333333) + quadroMjpeg(2, 720, 576, 400000, 400000),
        )).vss[1]!!.formatos[0]
        // Pedimos o 2 (720x576) e a placa aceitou o 1: o tamanho é 640x480.
        val q = com.quall.android.capture.dv.Negociacao.quadroAceito(f, cur(1, 1))
        assertEquals(640, q.largura)
        assertEquals(480, q.altura)
    }

    @Test
    fun outroFormatoNoGetCurFalhaAAbertura() {
        val f = Descritores.analisar(easycap).vss[1]!!.formatos[0]
        val e = runCatching { com.quall.android.capture.dv.Negociacao.quadroAceito(f, cur(2, 1)) }.exceptionOrNull()
        assertTrue(e is IllegalStateException && e.message!!.contains("formato 2"))
        val e2 = runCatching { com.quall.android.capture.dv.Negociacao.quadroAceito(f, cur(1, 7)) }.exceptionOrNull()
        assertTrue(e2 is IllegalStateException && e2.message!!.contains("quadro 7"))
    }
}
