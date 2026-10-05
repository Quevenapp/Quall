package com.quall.android.core

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **Nenhum texto de interface literal no código** (`docs/traducao.md`, Android): o que o usuário lê vem
 * de `res/values/ e res/values-pt/`, nos dois idiomas. A varredura olha:
 *
 * 1. os layouts: `android:text`, `contentDescription`, `hint`, `title` e `tooltipText` com texto cru
 *    (não `@string/…`). Etiquetas sem letra (`−`, `+`, `·`) passam;
 * 2. o Kotlin de `src/main` (fora da bancada): um literal com letras entregue direto a quem desenha ou
 *    anuncia texto (`text =`, `setText(`, `contentDescription =`, `setContentTitle(`, `Toast.makeText(`,
 *    `setTitle(`, `setMessage(`, os botões de diálogo, `seMudou(`…);
 * 3. o Kotlin de `src/main`: **qualquer** literal com letra acentuada fora de diário (`Log.*`, `diario`,
 *    exceção, `require`/`check`) — o português que escapou dos dois primeiros.
 *
 * O que fica de fora de propósito leva `// i18n-fora: <motivo>` na linha (texto de bancada, nome de
 * arquivo, protocolo). As pastas `bancada/` e `sonda/` ficam fora inteiras.
 */
class VarreduraDeTextosTest {
    private val main = File("src/main")
    private val foraDaVarredura = listOf("/bancada/", "/sonda/")

    private fun kotlin(): List<File> = File(main, "kotlin").walkTopDown()
        .filter { it.isFile && it.extension == "kt" }
        .filter { f -> foraDaVarredura.none { f.invariantSeparatorsPath.contains(it) } }
        .toList()

    private val literal = Regex(""""((?:[^"\\]|\\.)*)"""")
    private val temLetra = Regex("""\p{L}{2,}""")
    private val acento = Regex("""[À-ÖØ-öø-ÿ]""")

    private val sumidouros = Regex(
        """(\.text\s*=|setText\(|contentDescription\s*=|\.hint\s*=|setContentTitle\(|setContentText\(|setSubText\(|""" +
            """setTicker\(|makeText\(|setTitle\(|setMessage\(|setPositiveButton\(|setNegativeButton\(|setNeutralButton\(|""" +
            """seMudou\(|announceForAccessibility\(|tooltipText\s*=|NotificationChannel\()""",
    )
    private val diario = Regex(
        """(Log\.[vdiwe]\(|\bdiario|\bDiario|anotar\(|\bthrow\b|Exception\(|\berror\(|\brequire\(|\bcheck\(|""" +
            """\brequireNotNull\(|\bcheckNotNull\(|println\(|\bTODO\()""",
    )

    /** Os literais de uma linha de código (comentário de fim de linha fora). */
    private fun literais(linha: String): List<String> {
        val semComentario = linha.substringBefore(" // ").substringBefore("\t// ")
        return literal.findAll(semComentario).map { it.groupValues[1] }.toList()
    }

    /** O saldo de parênteses da linha, sem contar os de dentro dos literais. */
    private fun saldo(l: String): Int {
        val sem = l.replace(literal, "\"\"")
        return sem.count { it == '(' } - sem.count { it == ')' }
    }

    /**
     * As linhas de código de [f], sem comentários, sem as marcadas `i18n-fora` e **sem as de diário**:
     * uma chamada de diário (`Log.w(`, `throw`…) que abre parênteses e continua nas linhas seguintes leva
     * as seguintes junto, até fechar.
     */
    private fun linhasDeCodigo(f: File): Sequence<Pair<Int, String>> = sequence {
        var emBloco = false
        var diarioAberto = 0
        f.readLines().forEachIndexed { i, l ->
            val t = l.trim()
            if (emBloco) {
                if (t.contains("*/")) emBloco = false
                return@forEachIndexed
            }
            if (t.startsWith("/*")) {
                if (!t.contains("*/")) emBloco = true
                return@forEachIndexed
            }
            if (t.startsWith("//") || t.startsWith("*")) return@forEachIndexed
            if (diarioAberto > 0) {
                diarioAberto += saldo(l)
                return@forEachIndexed
            }
            if (diario.containsMatchIn(l)) {
                diarioAberto = maxOf(0, saldo(l))
                return@forEachIndexed
            }
            if (l.contains("i18n-fora")) return@forEachIndexed
            yield(i + 1 to l)
        }
    }

    @Test
    fun `nenhum texto cru nos layouts`() {
        val atributo = Regex("""android:(text|contentDescription|hint|title|tooltipText)="([^"]*)"""")
        val achados = File(main, "res").walkTopDown()
            .filter { it.isFile && it.extension == "xml" && it.parentFile.name.startsWith("layout") }
            .flatMap { f ->
                f.readLines().mapIndexedNotNull { i, l ->
                    if (l.contains("i18n-fora")) return@mapIndexedNotNull null
                    atributo.findAll(l).firstOrNull { m ->
                        val v = m.groupValues[2]
                        !v.startsWith("@") && !v.startsWith("?") && temLetra.containsMatchIn(v)
                    }?.let { "${f.name}:${i + 1}: ${it.value}" }
                }
            }.toList()
        assertTrue("texto cru em layout (use @string):\n" + achados.joinToString("\n"), achados.isEmpty())
    }

    @Test
    fun `nenhum texto cru entregue a quem desenha`() {
        val achados = kotlin().flatMap { f ->
            linhasDeCodigo(f).mapNotNull { (n, l) ->
                if (!sumidouros.containsMatchIn(l)) return@mapNotNull null
                val ruim = literais(l).firstOrNull { temLetra.containsMatchIn(it.replace(Regex("""\$\{[^}]*\}|\$\w+"""), "")) }
                ruim?.let { "${f.name}:$n: \"$it\"" }
            }.toList()
        }
        assertTrue("texto cru na interface (use getString):\n" + achados.joinToString("\n"), achados.isEmpty())
    }

    @Test
    fun `nenhum portugues solto no codigo`() {
        val achados = kotlin().flatMap { f ->
            linhasDeCodigo(f).mapNotNull { (n, l) ->
                literais(l).firstOrNull { acento.containsMatchIn(it) }?.let { "${f.name}:$n: \"$it\"" }
            }.toList()
        }
        assertTrue("português literal no código (recurso, ou `// i18n-fora: motivo`):\n" + achados.joinToString("\n"), achados.isEmpty())
    }
}
