// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.teleprompter

/**
 * **A porta e o endereço do teleprompter** — a regra que as quatro cascas seguem igual (decisão do
 * coordenador, 13/09; o iOS e o Mac já fazem assim), numa conta pura e provada sem aparelho.
 *
 * - O prompter hospeda por padrão na porta **7979**. A 7877 é a do espelhamento
 *   (`QuallNative.PORTA_SINALIZACAO`): um aparelho pode espelhar e mostrar o texto sem as duas
 *   disputarem a porta. Se a 7979 estiver ocupada, o prompter pega a próxima livre e **mostra no
 *   endereço da tela** — quem digita lê de lá.
 * - O controle que recebe **só o host**, sem porta, completa com **7979** antes de conectar. Não
 *   se deixa o `endereco_manual` do núcleo completar: ele põe 7877, a porta do vídeo. (O
 *   coordenador leva esse completar para dentro do núcleo depois; até lá, cada casca faz.)
 * - Nenhuma tela mostra link nem QR (saíram em 24/09, por decisão do Pessoa Exemplo —
 *   `docs/contrato-teleprompter.md` §2): o caminho é o nome na lista, ou o `ip:porta` e o PIN que
 *   a tela do prompter mostra por extenso. Um `quall://<pin>@<host>:<porta>` colado no campo do
 *   endereço **continua entendido**, por tolerância (a bancada e as cascas antigas o usam), sem que
 *   a tela anuncie o formato.
 */
object EnderecoDoTeleprompter {
    const val PORTA_PADRAO = 7979

    /** Quantas portas depois da preferida o prompter tenta antes de desistir de achar uma livre. */
    const val PORTAS_A_TENTAR = 10

    /** O que o controle vai discar: `host:porta` (IPv6 entre colchetes), e o PIN, se veio num link colado. */
    data class Destino(val endpoint: String, val pin: String?)

    /**
     * O que a pessoa digitou (ou colou) no campo do endereço → para onde discar. `null` se não dá
     * para entender (vazio, porta fora de 1..65535, link sem host).
     *
     * - `192.168.57.8` → `192.168.57.8:7979`
     * - `192.168.57.8:8000` → como está
     * - `quall-944d0e.local` → `quall-944d0e.local:7979`
     * - `2804:1b1::1` (IPv6 sem colchetes) → `[2804:1b1::1]:7979`
     * - `[2804:1b1::1]` → `[2804:1b1::1]:7979`; `[2804:1b1::1]:8000` → como está
     * - `quall://424242@192.168.57.8:7979` (colado; nenhuma tela o mostra mais) → `192.168.57.8:7979`
     *   com o PIN 424242
     */
    fun doControle(digitado: String): Destino? {
        var t = digitado.trim()
        if (t.isEmpty()) return null
        var pin: String? = null
        if (t.startsWith("quall://", ignoreCase = true)) {
            t = t.substring("quall://".length).trimEnd('/')
            val arroba = t.lastIndexOf('@')
            if (arroba >= 0) {
                val p = t.substring(0, arroba)
                pin = p.takeIf { it.length == 6 && it.all(Char::isDigit) }
                t = t.substring(arroba + 1)
            }
            if (t.isEmpty()) return null
        }
        val endpoint = completar(t) ?: return null
        return Destino(endpoint, pin)
    }

    /** `host` ou `host:porta` → `host:porta`, com a porta padrão do teleprompter quando falta. */
    fun completar(hostOuHostPorta: String): String? {
        val t = hostOuHostPorta.trim()
        if (t.isEmpty()) return null
        if (t.startsWith("[")) {
            val fecha = t.indexOf(']')
            if (fecha < 0) return null
            val host = t.substring(0, fecha + 1)
            val resto = t.substring(fecha + 1)
            if (resto.isEmpty()) return "$host:$PORTA_PADRAO"
            if (!resto.startsWith(":")) return null
            return porta(resto.substring(1))?.let { "$host:$it" }
        }
        val doisPontos = t.count { it == ':' }
        return when {
            doisPontos == 0 -> "$t:$PORTA_PADRAO"
            // Mais de um ":" sem colchetes é IPv6 puro: não tem como trazer porta junto.
            doisPontos > 1 -> "[$t]:$PORTA_PADRAO"
            else -> {
                val host = t.substringBefore(':')
                if (host.isEmpty()) null else porta(t.substringAfter(':'))?.let { "$host:$it" }
            }
        }
    }

    private fun porta(texto: String): Int? = texto.toIntOrNull()?.takeIf { it in 1..65535 }

    /**
     * A porta em que o prompter vai hospedar: a preferida, ou a próxima livre até
     * [PORTAS_A_TENTAR] depois dela. `livre` testa uma porta (na casca, um `bind` de teste). Se
     * nenhuma estiver livre, devolve a preferida — e o núcleo diz por que não abriu.
     */
    fun escolherPorta(preferida: Int, livre: (Int) -> Boolean): Int {
        for (p in preferida until minOf(preferida + PORTAS_A_TENTAR, 65536)) {
            if (livre(p)) return p
        }
        return preferida
    }
}
