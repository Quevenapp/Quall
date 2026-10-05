package com.quall.android.dvd

import com.quall.android.R
import com.quall.android.core.TextosDeTeste
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * **As frases do DVD sem idioma** (`docs/traducao.md`, Android): a [Frase] monta o mesmo português de
 * antes e o inglês, com a frase de dentro no mesmo idioma.
 */
class FraseDoDvdTest {
    @Test
    fun `a frase de dentro sai no mesmo idioma`() {
        val f = Frase(R.string.dvd_parcial_na_galeria, Frase(R.string.dvd_conversao_cancelada), "Quall-DVD-FERIAS-01.mp4")
        assertEquals("conversão cancelada — o que já foi está em Movies/Quall/Quall-DVD-FERIAS-01.mp4", f.em(TextosDeTeste.PT))
        assertEquals("conversion canceled — what was done is in Movies/Quall/Quall-DVD-FERIAS-01.mp4", f.em(TextosDeTeste.EN))
    }

    @Test
    fun `o texto cru passa igual nos dois idiomas`() {
        val f = Frase(R.string.dvd_conversao_falhou, Frase.cru("IllegalStateException: x"))
        assertEquals("a conversão falhou: IllegalStateException: x", f.em(TextosDeTeste.PT))
        assertEquals("the conversion failed: IllegalStateException: x", f.em(TextosDeTeste.EN))
    }

    @Test
    fun `os motivos do C e o um canal so`() {
        assertEquals("conversão cancelada", QuallDvd.motivo(QuallDvd.ERRO_CANCELADO).em(TextosDeTeste.PT))
        assertEquals(FrasesDoDvd.PROTEGIDO, QuallDvd.motivo(QuallDvd.ERRO_CIFRADO))
        assertEquals(
            "Salvo na Galeria: Movies/Quall/a.mp4 (o disco tem som num canal só; o Quall copia para os dois lados)",
            Frase(R.string.dvd_com_um_canal, Frase(R.string.dvd_salvo_na_galeria, "a.mp4"), QuallDvd.UM_CANAL_SO).em(TextosDeTeste.PT),
        )
    }

    @Test
    fun `a compatibilidade em portugues das recusas`() {
        // O `MirrorService` e a vitrine ainda leem `Recusas` (String): a mesma frase do recurso.
        val pares = listOf(
            FrasesDoDvd.PROTEGIDO to Recusas.PROTEGIDO, FrasesDoDvd.LEITOR_PAROU to Recusas.LEITOR_PAROU,
            FrasesDoDvd.LEITOR_PRESO to Recusas.LEITOR_PRESO, FrasesDoDvd.SEM_LEITOR to Recusas.SEM_LEITOR,
            FrasesDoDvd.ANGULOS to Recusas.ANGULOS, FrasesDoDvd.SO_DTS to Recusas.SO_DTS,
            FrasesDoDvd.NAO_FINALIZADO to Recusas.NAO_FINALIZADO, FrasesDoDvd.DISCO_TROCADO to Recusas.DISCO_TROCADO,
            FrasesDoDvd.FORA_DO_DISCO to Recusas.FORA_DO_DISCO, FrasesDoDvd.CELULAS_DEMAIS to Recusas.CELULAS_DEMAIS,
        )
        for ((f, s) in pares) {
            assertEquals(s, f.em(TextosDeTeste.PT))
            assertEquals(s, Recusas.emPortugues(f))
        }
    }
}
