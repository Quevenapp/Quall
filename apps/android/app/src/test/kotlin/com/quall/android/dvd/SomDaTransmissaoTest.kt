package com.quall.android.dvd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **O som "pipocando" da transmissão** (medido no A07, 29/09: `caídas=2453613 silêncio=2452971` em
 * ~51 s), reproduzido sem aparelho: o produtor no ritmo do vídeo (a decodificação, presa a uma fila de
 * quadros à frente da tela, com o som do fluxo atrás do vídeo pelo `vbv_delay` do MPEG-2) contra o
 * consumidor no ritmo do emissor (um quadro de 20 ms a cada 20 ms, pela hora do [RelogioDoDisco]),
 * 60 s. Com a folga de 12 quadros e o relógio ancorado na hora, todo o som chega atrasado: cai, e no
 * lugar vai silêncio. Com a folga do [PoliticaDoRitmo] e a carga antes de ancorar, nada cai.
 */
class SomDaTransmissaoTest {
    private data class Resultado(val caidas: Long, val silencio: Long, val tiradas: Long)

    private fun simular(folga: Int, comCarga: Boolean, vbvUs: Long, segundos: Int = 60): Resultado {
        val fila = FilaDoSomDoDisco()
        fila.reiniciar(0)
        val relogio = RelogioDoDisco()
        val pcm = ShortArray(2 * 48_000)
        val saida = ShortArray(2 * 960)
        val vbv90k = vbvUs * 9 / 100
        var decodificados = 0L
        var apresentados = 0L
        var empurradas = 0L
        var tiradas = 0L
        var t = 0L
        while (t < segundos * 1_000_000L) {
            // A decodificação: tão rápida quanto a fila deixa; o som do fluxo chega até o vídeo − vbv.
            while (decodificados - apresentados < folga) {
                val pts = decodificados * 3003
                decodificados++
                val ate = maxOf(0L, pts - vbv90k) * 8 / 15
                var falta = ate - empurradas
                while (falta > 0) {
                    val n = minOf(falta, 4096L).toInt()
                    fila.empurrar(0, pcm, n)
                    empurradas += n
                    falta -= n
                }
            }
            // O ritmo: ancora (na hora, ou com a fila cheia) e apresenta o que já deu a hora.
            if (!relogio.ancorado) {
                val pode = !comCarga || PoliticaDoRitmo.podeAncorar((decodificados - apresentados).toInt(), folga, false, t)
                if (pode) relogio.ancorar(0, apresentados * 3003, t)
            }
            if (relogio.ancorado) {
                while (apresentados < decodificados && relogio.instanteUs(apresentados * 3003) <= t) apresentados++
            }
            // O emissor: 20 ms a cada 20 ms.
            if (t % 20_000L == 0L) {
                val alvo = relogio.amostraEm(0, t)
                fila.tirar(0, alvo, saida, 960, 2)
                if (alvo != null) tiradas += 960
            }
            t += 1_000
        }
        return Resultado(fila.caidas, fila.silencio, tiradas)
    }

    @Test
    fun `a folga de 12 quadros reproduz o defeito do A07`() {
        val r = simular(folga = 12, comCarga = false, vbvUs = 700_000)
        // Quase todo o som cai, e quase todo o tempo é silêncio: a assinatura medida.
        assertTrue("caídas ${r.caidas} de ${r.tiradas}", r.caidas > r.tiradas * 9 / 10)
        assertTrue("silêncio ${r.silencio} de ${r.tiradas}", r.silencio > r.tiradas * 9 / 10)
    }

    @Test
    fun `com a folga do ritmo e a carga antes de ancorar o som vai continuo`() {
        val folga = PoliticaDoRitmo.quadrosDeFolga(30)
        assertEquals(45, folga)
        assertEquals(38, PoliticaDoRitmo.quadrosDeFolga(25))
        for (vbv in listOf(0L, 300_000L, 700_000L, 1_000_000L)) {
            val r = simular(folga = folga, comCarga = true, vbvUs = vbv)
            assertTrue("vbv $vbv: ${r.tiradas} tiradas", r.tiradas > 59 * 48_000L)
            assertEquals("vbv $vbv: caídas", 0L, r.caidas)
            assertEquals("vbv $vbv: silêncio", 0L, r.silencio)
        }
    }

    @Test
    fun `a carga nao prende a imagem para sempre`() {
        assertTrue(PoliticaDoRitmo.podeAncorar(43, 45, false, 0))
        assertTrue(!PoliticaDoRitmo.podeAncorar(10, 45, false, 1_000_000))
        assertTrue(PoliticaDoRitmo.podeAncorar(10, 45, true, 0))
        assertTrue(PoliticaDoRitmo.podeAncorar(10, 45, false, PoliticaDoRitmo.ESPERA_MAXIMA_DA_CARGA_US))
    }
}
