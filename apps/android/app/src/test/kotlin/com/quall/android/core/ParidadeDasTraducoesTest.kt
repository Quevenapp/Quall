package com.quall.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **O inglês e o português dizem as mesmas coisas** (`docs/traducao.md`, Android): as mesmas chaves dos
 * dois lados, os mesmos marcadores de formato, e nada do que o aapt2 aceitaria mas o
 * [TextosDeTeste] não imita. O lint (`MissingTranslation`) pega parte disto; este teste roda no portão.
 */
class ParidadeDasTraducoesTest {
    private val en = TextosDeTeste.entradas("values")
    private val pt = TextosDeTeste.entradas("values-pt")

    /** `%s`, `%1$s`, `%d`, `%.1f`, `%2$,d`… — e não o `%%`. */
    private val marcador = Regex("""%(\d+\$)?[-#+ 0,(]*\d*(\.\d+)?[a-zA-Z]""")

    private fun marcadores(t: String): List<String> = marcador.findAll(t.replace("%%", "")).map { it.value }.sorted().toList()

    @Test
    fun `as mesmas chaves nos dois idiomas`() {
        val traduziveis = en.filter { it.traduzivel }.map { it.nome }.toSet()
        val doPt = pt.map { it.nome }.toSet()
        assertEquals("chaves só em values/ (falta o português)", emptySet<String>(), traduziveis - doPt)
        assertEquals("chaves só em values-pt/ (falta o inglês)", emptySet<String>(), doPt - traduziveis)
        val fixasNoPt = pt.filter { !it.traduzivel }.map { it.nome }
        assertTrue("translatable=false só em values/: $fixasNoPt", fixasNoPt.isEmpty())
        val fixas = en.filter { !it.traduzivel }.map { it.nome }.toSet()
        assertEquals("chaves fixas repetidas em values-pt/", emptySet<String>(), fixas intersect doPt)
    }

    @Test
    fun `nenhuma chave repetida`() {
        for (lado in listOf(en, pt)) {
            val repetidas = lado.groupBy { it.nome }.filter { it.value.size > 1 }.map { "${it.key} (${it.value.joinToString { e -> e.arquivo }})" }
            assertTrue("chaves repetidas: $repetidas", repetidas.isEmpty())
        }
    }

    @Test
    fun `os mesmos marcadores de formato`() {
        val ptPorNome = pt.associateBy { it.nome }
        val diferentes = en.filter { it.traduzivel }.mapNotNull { e ->
            val p = ptPorNome[e.nome] ?: return@mapNotNull null
            when {
                e.formatado != p.formatado -> "${e.nome}: formatted difere"
                e.formatado && marcadores(e.texto) != marcadores(p.texto) ->
                    "${e.nome}: ${marcadores(e.texto)} × ${marcadores(p.texto)}"
                else -> null
            }
        }
        assertTrue("marcadores diferentes:\n" + diferentes.joinToString("\n"), diferentes.isEmpty())
    }

    @Test
    fun `um percentual solto pede formatted false ou porcento dobrado`() {
        // Num texto com marcador, um "%" que não é marcador nem "%%" faz o `getString(id, args)` lançar.
        val ruins = (en + pt).filter { e ->
            e.formatado && marcadores(e.texto).isNotEmpty() && e.texto.replace("%%", "").replace(marcador, "").contains('%')
        }.map { "${it.arquivo}: ${it.nome}" }
        assertTrue("% solto num texto formatável:\n" + ruins.joinToString("\n"), ruins.isEmpty())
    }

    @Test
    fun `sem marcação nem escape que o teste não imite`() {
        val ruins = (en + pt).filter { e ->
            e.temFilhos || Regex("""\\[^'"nt\\@?u]""").containsMatchIn(e.bruto) || e.texto.contains('\\')
        }.map { "${it.arquivo}: ${it.nome}" }
        assertTrue("HTML, xliff ou escape fora da lista:\n" + ruins.joinToString("\n"), ruins.isEmpty())
    }

    @Test
    fun `nenhum texto vazio`() {
        val vazios = (en + pt).filter { it.texto.isBlank() }.map { "${it.arquivo}: ${it.nome}" }
        assertTrue("textos vazios: $vazios", vazios.isEmpty())
    }

    @Test
    fun `o codigo do idioma de cada pasta`() {
        assertEquals("en", TextosDeTeste.EN.cru("idioma_codigo"))
        assertEquals("pt", TextosDeTeste.PT.cru("idioma_codigo"))
    }
}
