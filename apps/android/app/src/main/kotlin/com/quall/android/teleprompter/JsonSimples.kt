package com.quall.android.teleprompter

/**
 * Um leitor de JSON **mínimo**, em Kotlin puro, para o estado do teleprompter.
 *
 * ## Por que não o `org.json` que o resto do app usa
 *
 * O `org.json` do Android vive no `android.jar`, e nos testes de JVM (`src/test/`) ele é um
 * **esboço**: toda chamada lança "Method … not mocked". O estado do teleprompter é o que decide o
 * que as duas telas mostram — rolando ou não, o aviso de controle sumido, o salto — e essa leitura
 * precisa ser provada sem aparelho. Com este leitor, `EstadoDoTeleprompter.ler` roda no
 * `testDebugUnitTest` contra o JSON **literal** do contrato (`docs/contrato-teleprompter.md` §6).
 *
 * Lê o JSON inteiro (objetos, listas, textos com escapes, números, `true`/`false`/`null`) e devolve
 * `Map<String, Any?>`, `List<Any?>`, `String`, `Double`, `Boolean` ou `null`. Não escreve JSON: a
 * casca nunca escreve mensagem do teleprompter — quem escreve é o núcleo.
 */
object JsonSimples {

    class Erro(mensagem: String) : Exception(mensagem)

    /** Lê um documento inteiro. Lixo depois do valor é erro. */
    fun ler(texto: String): Any? {
        val l = Leitor(texto)
        l.espacos()
        val v = l.valor()
        l.espacos()
        if (l.i != texto.length) throw Erro("sobra depois do valor na posição ${l.i}")
        return v
    }

    /** Lê e exige um objeto; `null` para qualquer outra coisa ou erro. */
    fun objeto(texto: String): Map<String, Any?>? = runCatching {
        @Suppress("UNCHECKED_CAST")
        ler(texto) as? Map<String, Any?>
    }.getOrNull()

    private class Leitor(val s: String) {
        var i = 0

        fun espacos() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) i++
        }

        fun valor(): Any? {
            if (i >= s.length) throw Erro("fim inesperado")
            return when (val c = s[i]) {
                '{' -> objeto()
                '[' -> lista()
                '"' -> texto()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> if (c == '-' || c in '0'..'9') numero() else throw Erro("caractere '$c' na posição $i")
            }
        }

        private fun literal(palavra: String, v: Any?): Any? {
            if (!s.startsWith(palavra, i)) throw Erro("esperava $palavra na posição $i")
            i += palavra.length
            return v
        }

        private fun objeto(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            i++ // {
            espacos()
            if (i < s.length && s[i] == '}') { i++; return m }
            while (true) {
                espacos()
                if (i >= s.length || s[i] != '"') throw Erro("esperava chave na posição $i")
                val k = texto()
                espacos()
                if (i >= s.length || s[i] != ':') throw Erro("esperava ':' na posição $i")
                i++
                espacos()
                m[k] = valor()
                espacos()
                if (i >= s.length) throw Erro("objeto sem fim")
                when (s[i]) {
                    ',' -> i++
                    '}' -> { i++; return m }
                    else -> throw Erro("esperava ',' ou '}' na posição $i")
                }
            }
        }

        private fun lista(): List<Any?> {
            val l = ArrayList<Any?>()
            i++ // [
            espacos()
            if (i < s.length && s[i] == ']') { i++; return l }
            while (true) {
                espacos()
                l.add(valor())
                espacos()
                if (i >= s.length) throw Erro("lista sem fim")
                when (s[i]) {
                    ',' -> i++
                    ']' -> { i++; return l }
                    else -> throw Erro("esperava ',' ou ']' na posição $i")
                }
            }
        }

        private fun texto(): String {
            i++ // "
            val sb = StringBuilder()
            while (true) {
                if (i >= s.length) throw Erro("texto sem fim")
                val c = s[i++]
                when (c) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        if (i >= s.length) throw Erro("escape sem fim")
                        when (val e = s[i++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (i + 4 > s.length) throw Erro("\\u curto")
                                sb.append(s.substring(i, i + 4).toInt(16).toChar())
                                i += 4
                            }
                            else -> throw Erro("escape \\$e")
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }

        private fun numero(): Double {
            val inicio = i
            if (s[i] == '-') i++
            while (i < s.length && (s[i].isDigit() || s[i] == '.' || s[i] == 'e' || s[i] == 'E' ||
                    s[i] == '+' || s[i] == '-')) i++
            return s.substring(inicio, i).toDoubleOrNull() ?: throw Erro("número ruim na posição $inicio")
        }
    }
}
