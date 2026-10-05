package com.quall.android.capture

import com.quall.android.capture.dv.GravacaoDaPlaca
import com.quall.android.capture.dv.GravacaoDaPlaca.Entrada
import com.quall.android.capture.dv.LinhaDoSomDaPlaca
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** As contas puras da gravação da placa (a P4 adiantada, `docs/placa-de-captura-usb.md` §9.6). */
class GravacaoDaPlacaTest {

    @Test
    fun aTaxaDa640x480EOPiso() {
        // 14 Mbit/s x 307200/2073600 = 2,07 Mbit/s pela área: abaixo do piso.
        assertEquals(6_000_000, GravacaoDaPlaca.taxa(640, 480))
        assertEquals(6_000_000, GravacaoDaPlaca.taxa(720, 576))
        // Um tamanho grande passa do piso pela regra.
        assertEquals(14_000_000, GravacaoDaPlaca.taxa(1920, 1080))
    }

    private val microfone = Entrada(1, usb = false, nome = "Galaxy S24 Ultra")
    private val placa = Entrada(7, usb = true, nome = "USB-Audio - USB2.0 PC CAMERA")
    private val fone = Entrada(9, usb = true, nome = "USB-Audio - Fone USB-C")

    @Test
    fun aEntradaDaPlacaPeloNome() {
        assertEquals(placa, GravacaoDaPlaca.escolherEntrada(listOf(microfone, fone, placa), "USB2.0 PC CAMERA"))
        assertEquals(placa, GravacaoDaPlaca.escolherEntrada(listOf(microfone, placa), "usb2.0 pc camera"))
    }

    @Test
    fun semCasarPeloNomeAUnicaUsb() {
        assertEquals(placa, GravacaoDaPlaca.escolherEntrada(listOf(microfone, placa), "Outro Nome"))
        assertEquals(placa, GravacaoDaPlaca.escolherEntrada(listOf(microfone, placa), null))
    }

    @Test
    fun duasUsbSemNomeOuNenhumaUsbNaoChuta() {
        assertNull(GravacaoDaPlaca.escolherEntrada(listOf(microfone, placa, fone), "Outro Nome"))
        assertNull(GravacaoDaPlaca.escolherEntrada(listOf(microfone), "USB2.0 PC CAMERA"))
    }

    /** As outras câmeras pedem o microfone do telefone, explicitamente (§8: o `MIC` lia da placa). */
    @Test
    fun oMicrofoneEmbutidoExplicito() {
        val embutido = Entrada(1, usb = false, nome = "Galaxy S24 Ultra", embutido = true)
        val traseiro = Entrada(2, usb = false, nome = "Galaxy S24 Ultra", embutido = true)
        assertEquals(embutido, GravacaoDaPlaca.escolherEmbutido(listOf(placa, embutido, traseiro, fone)))
        assertNull(GravacaoDaPlaca.escolherEmbutido(listOf(placa, fone)))
    }

    // ---- a linha do tempo do som --------------------------------------------------------------

    private val ms = 1_000_000L

    @Test
    fun oSomAntesDoPrimeiroQuadroCai() {
        val l = LinhaDoSomDaPlaca()
        val t0 = 10_000 * ms
        // todo antes
        assertEquals(LinhaDoSomDaPlaca.Plano(480, 0), l.planejar(t0 - 20 * ms, 480, t0))
        assertEquals(0L, l.enviadas)
        // metade antes: 240 amostras (5 ms) puladas
        assertEquals(LinhaDoSomDaPlaca.Plano(240, 0), l.planejar(t0 - 5 * ms, 480, t0))
        assertEquals(240L, l.enviadas)
        // o seguinte, contíguo: nada
        assertEquals(LinhaDoSomDaPlaca.Plano(0, 0), l.planejar(t0 + 5 * ms, 480, t0))
        assertEquals(720L, l.enviadas)
    }

    @Test
    fun oPrimeiroBlocoDepoisDoZeroGanhaSilencioAteEle() {
        val l = LinhaDoSomDaPlaca()
        val t0 = 0L
        assertEquals(LinhaDoSomDaPlaca.Plano(0, 4800), l.planejar(100 * ms, 480, t0))  // 100 ms
        assertEquals(5280L, l.enviadas)
    }

    @Test
    fun oTremorDentroDaToleranciaNaoMexe() {
        val l = LinhaDoSomDaPlaca()
        l.planejar(0, 480, 0)
        // o carimbo do segundo bloco 30 ms atrasado (dentro dos 40): nada
        assertEquals(LinhaDoSomDaPlaca.Plano(0, 0), l.planejar(40 * ms, 480, 0))
        // 20 ms adiantado: nada
        assertEquals(LinhaDoSomDaPlaca.Plano(0, 0), l.planejar(0 * ms, 480, 0))
    }

    @Test
    fun umBuracoViraSilencioEUmAdiantadoEPulado() {
        val l = LinhaDoSomDaPlaca()
        l.planejar(0, 480, 0)  // enviadas 480 (10 ms)
        // o AudioRecord perdeu 100 ms: o bloco começa em 110 ms
        assertEquals(LinhaDoSomDaPlaca.Plano(0, 4800), l.planejar(110 * ms, 480, 0))
        assertEquals(5760L, l.enviadas)  // 120 ms
        // um bloco que diz 60 ms antes do que a contagem espera: 2880 amostras puladas (o bloco inteiro de 480)
        assertEquals(LinhaDoSomDaPlaca.Plano(480, 0), l.planejar(60 * ms, 480, 0))
        assertEquals(5760L, l.enviadas)
        assertEquals(4800L, l.silencioPosto)
    }

    // ---- o fim do som no fim do vídeo (§11, item 3: o som terminava ~51 ms antes) ----------------

    @Test
    fun oAlvoDoFimEOUltimoQuadroMaisADuracaoDele() {
        val t0 = 5_000 * ms
        // último quadro 83,709 s depois do zero, mais 1/30 s: 83,742 s = 4 019 616 amostras
        val alvo = LinhaDoSomDaPlaca.alvoDoFim(t0 + 83_708_667 * 1000L, 33_333_333L, t0)
        assertEquals(4_019_616L, alvo)
        // no múltiplo de 1024 mais perto (o pacote do AAC): erro de no máximo meio pacote (10,7 ms)
        val a1024 = LinhaDoSomDaPlaca.alvoDoFim(t0 + 83_708_667 * 1000L, 33_333_333L, t0, multiplo = 1024)
        assertEquals(0L, a1024 % 1024)
        assertTrue(Math.abs(a1024 - alvo) <= 512)
        // sem vídeo depois do zero: nada
        assertEquals(0L, LinhaDoSomDaPlaca.alvoDoFim(t0 - 50 * ms, 33_333_333L, t0))
    }

    @Test
    fun nadaPassaDoFimDoVideo() {
        val l = LinhaDoSomDaPlaca()
        l.planejar(0, 960, 0)  // 960 no arquivo
        // o fim do vídeo em 1200: do próximo bloco de 960, só 240 cabem (720 cortadas do fim)
        assertEquals(LinhaDoSomDaPlaca.Plano(0, 0, 720), l.planejar(20 * ms, 960, 0, limite = 1200))
        assertEquals(1200L, l.enviadas)
        assertEquals(720L, l.cortadas)
        // depois do fim, tudo cortado
        assertEquals(0L, l.planejar(40 * ms, 960, 0, limite = 1200).amostras(960))
        assertEquals(1200L, l.enviadas)
    }

    @Test
    fun oSilencioAntesDoFimTambemPara() {
        val l = LinhaDoSomDaPlaca()
        l.planejar(0, 960, 0)
        // um buraco de 100 ms (4800 de silêncio) com o fim em 2000: 1040 de silêncio, e o bloco fora
        val p = l.planejar(120 * ms, 960, 0, limite = 2000)
        assertEquals(1040L, p.silencio)
        assertEquals(0L, p.amostras(960) - p.silencio)
        assertEquals(2000L, l.enviadas)
    }

    @Test
    fun oQueFaltaAteOFimViraSilencio() {
        val l = LinhaDoSomDaPlaca()
        l.planejar(0, 960, 0)
        assertEquals(1040L, l.completar(2000))
        assertEquals(2000L, l.enviadas)
        assertEquals(1040L, l.silencioPosto)
        // já no fim: nada
        assertEquals(0L, l.completar(2000))
        assertEquals(0L, l.completar(1500))
    }
}
