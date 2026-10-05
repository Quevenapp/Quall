package com.quall.android.dvd

import org.junit.Assert.assertEquals
import org.junit.Test

/** O que a D1c decide sem aparelho: o tamanho de saída, o idioma do MP4 e o nome do arquivo. */
class SaidaDoDvdTest {
    @Test
    fun `pixels quadrados pelo sistema e pelo aspecto`() {
        assertEquals(640 to 480, ConversorDvd.tamanhoDeSaida(pal = false, aspecto169 = false))
        assertEquals(854 to 480, ConversorDvd.tamanhoDeSaida(pal = false, aspecto169 = true))
        assertEquals(768 to 576, ConversorDvd.tamanhoDeSaida(pal = true, aspecto169 = false))
        assertEquals(1024 to 576, ConversorDvd.tamanhoDeSaida(pal = true, aspecto169 = true))
    }

    @Test
    fun `o idioma do IFO em tres letras`() {
        assertEquals("por", ConversorDvd.idioma639_2("pt"))
        assertEquals("eng", ConversorDvd.idioma639_2("EN"))
        assertEquals("und", ConversorDvd.idioma639_2(null))
        assertEquals("und", ConversorDvd.idioma639_2(""))
        assertEquals("und", ConversorDvd.idioma639_2("xx"))
    }

    @Test
    fun `o nome do arquivo sem acento nem simbolo`() {
        assertEquals("Quall-DVD-ATTA_MIDIA_VYGOTSKY-01.mp4", GaleriaDoDvd.nome("ATTA_MIDIA_VYGOTSKY", 1))
        assertEquals("Quall-DVD-Formatura_Joao-12.mp4", GaleriaDoDvd.nome(" Formatura João ", 12))
        assertEquals("Quall-DVD-DVD-03.mp4", GaleriaDoDvd.nome("///", 3))
    }
}
