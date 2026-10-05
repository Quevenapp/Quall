package com.quall.android.core

import com.quall.android.R
import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

/**
 * **Os [Textos] dos testes JVM**: lê os mesmos `res/values/ e res/values-pt/` que o app empacota e
 * resolve o `R.string.x` pelo nome (reflexão), para os módulos puros serem provados sem aparelho e no
 * idioma pedido. [PT] é o texto-fonte: os testes que comparavam a frase em português continuam
 * comparando a mesma frase.
 *
 * Imita o aapt2 só no que `ParidadeDasTraducoesTest` permite nos XML: espaços colapsados e cortados
 * nas pontas, aspas duplas cruas preservando espaço, e os escapes `\'` `\"` `\n` `\t` `\\` `\@` `\?`
 * `\uXXXX`. Formata como o `getString(id, args)` do Android: só com argumentos, no `Locale` do idioma.
 */
class TextosDeTeste private constructor(
    override val locale: Locale,
    private val porNome: Map<String, String>,
) : Textos {

    override fun s(id: Int, vararg args: Any): String {
        val nome = NOMES[id] ?: error("R.string sem nome para o id $id")
        val cru = porNome[nome] ?: error("\"$nome\" não está nos XML de ${locale.toLanguageTag()}")
        return if (args.isEmpty()) cru else String.format(locale, cru, *args)
    }

    /** O texto da chave [nome], sem formatar (para os testes de paridade). */
    fun cru(nome: String): String? = porNome[nome]

    companion object {
        /** O caminho dos recursos: o Gradle roda os testes de unidade com o diretório do módulo. */
        val RES = File("src/main/res")

        private val NOMES: Map<Int, String> by lazy {
            R.string::class.java.fields.associate { it.getInt(null) to it.name }
        }

        val PT: TextosDeTeste by lazy { TextosDeTeste(Locale.forLanguageTag("pt-BR"), ler("values-pt") + traducaoFixa()) }
        val EN: TextosDeTeste by lazy { TextosDeTeste(Locale.ENGLISH, ler("values")) }

        /** As chaves `translatable="false"` moram só em `values/` e valem nos dois idiomas. */
        private fun traducaoFixa(): Map<String, String> =
            entradas("values").filter { !it.traduzivel }.associate { it.nome to it.texto }

        private fun ler(pasta: String): Map<String, String> = entradas(pasta).associate { it.nome to it.texto }

        class Entrada(
            val nome: String,
            val bruto: String,
            val texto: String,
            val traduzivel: Boolean,
            val formatado: Boolean,
            val temFilhos: Boolean,
            val arquivo: String,
        )

        /** Todas as `<string>` dos `strings*.xml` de [pasta]. */
        fun entradas(pasta: String): List<Entrada> {
            val dir = File(RES, pasta)
            val arquivos = dir.listFiles { f -> f.name.startsWith("strings") && f.name.endsWith(".xml") }
                ?.sortedBy { it.name }.orEmpty()
            val fabrica = DocumentBuilderFactory.newInstance()
            return arquivos.flatMap { f ->
                val doc = fabrica.newDocumentBuilder().parse(f)
                val nos = doc.documentElement.getElementsByTagName("string")
                (0 until nos.length).map { i ->
                    val e = nos.item(i) as Element
                    val bruto = e.textContent
                    Entrada(
                        nome = e.getAttribute("name"),
                        bruto = bruto,
                        texto = comoAapt(bruto),
                        traduzivel = e.getAttribute("translatable") != "false",
                        formatado = e.getAttribute("formatted") != "false",
                        temFilhos = (0 until e.childNodes.length).any { e.childNodes.item(it) is Element },
                        arquivo = f.name,
                    )
                }
            }
        }

        /** O texto como o aapt2 o compila (o subconjunto permitido; ver a classe). */
        fun comoAapt(bruto: String): String {
            val sb = StringBuilder()
            var entreAspas = false
            var i = 0
            var espacoPendente = false
            while (i < bruto.length) {
                val c = bruto[i]
                when {
                    c == '\\' && i + 1 < bruto.length -> {
                        if (espacoPendente && sb.isNotEmpty()) sb.append(' ')
                        espacoPendente = false
                        val n = bruto[i + 1]
                        when (n) {
                            'n' -> sb.append('\n')
                            't' -> sb.append('\t')
                            'u' -> {
                                sb.append(bruto.substring(i + 2, i + 6).toInt(16).toChar())
                                i += 4
                            }
                            else -> sb.append(n)
                        }
                        i += 2
                        continue
                    }
                    c == '"' -> entreAspas = !entreAspas
                    c.isWhitespace() && !entreAspas -> espacoPendente = true
                    else -> {
                        if (espacoPendente && sb.isNotEmpty()) sb.append(' ')
                        espacoPendente = false
                        sb.append(c)
                    }
                }
                i++
            }
            return sb.toString()
        }
    }
}
