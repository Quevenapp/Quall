package com.quall.android.core

/** Redação só do diário; nunca é aplicada aos dados da UI, rede ou estado de pareamento. */
object RedacaoDeLogs {
    private val segredo = Regex("""(?i)["']?\b(?:pin|pinDoPrompter|pin_do_prompter|secret|segredo|password|senha|private[_-]?key|public[_-]?key|pair[_-]?key|resume[_-]?key|shared[_-]?secret|chave(?:[_-]?(?:privada|publica|pareamento|retomada))?|token|nonce|mac|proof|authorization|ice[_-]?pwd|ice[_-]?ufrag|ufrag)\b["']?\s*[:=][ \t]*""")
    private val pin = Regex("""(?i)\bPIN\b\s*(?:(?:novo|inválido|malformado)\s*)?(?:[:=]\s*)?(?=["']?[0-9])""") // i18n-fora: regex de redação do diário reconhece termos de PIN; não é texto da interface
    private val identificador = Regex("""(?i)["']?\b(?:device[_-]?id|display[_-]?name|peer[_-]?id|service[_-]?name|par[_-]?nome|nome|autor|author|prefixo|label|rotulo|rótulo)\b["']?\s*[:=][ \t]*""")
    private val link = Regex("""(?i)\b(?:quall|content|file)://[^\s"'<>]+""")
    private val aspasDeNome = Regex("“[^”]*”")
    private val hostLocal = Regex("""(?i)\b[a-z0-9][a-z0-9_.-]*\.local\b""")
    private val idDaCasca = Regex("""(?i)\b(?:android|ios|macos|windows|win)-[a-z0-9-]{8,}\b""")
    private val tokenLongo = Regex("""(?<![a-zA-Z0-9_])[a-zA-Z0-9+/=_-]{32,}(?![a-zA-Z0-9_])""")
    private val resumoDoRoteiro = Regex("""(?i)(\bresumo[ =]+)[a-f0-9]{16}\b""")
    private val endereco6 = Regex("""(?<![a-zA-Z0-9_.:])(?=[0-9a-fA-F:.]*:[0-9a-fA-F:.]*:)[0-9a-fA-F:.]+(?:%[a-zA-Z0-9_.-]+)?(?![a-zA-Z0-9_.:])""")
    private val endereco4 = Regex("""(?<![a-zA-Z0-9_.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![a-zA-Z0-9_.])""")
    private val caminhoPrivado = Regex("""/(?:data|storage|sdcard|mnt)/[^\s"'<>]+""")

    fun mensagem(original: String): String {
        var texto = link.replace(original) { "<uri>" }
        texto = caminhoPrivado.replace(texto, "<caminho privado>")
        texto = ocultarCampos(texto, segredo, "<segredo>")
        texto = ocultarCampos(texto, pin, "<segredo>")
        texto = ocultarCampos(texto, identificador, "<identificador>")
        texto = aspasDeNome.replace(texto, "“<identificador>”")
        texto = hostLocal.replace(texto, "<host local>")
        texto = idDaCasca.replace(texto, "<identificador>")
        texto = tokenLongo.replace(texto, "<token>")
        texto = resumoDoRoteiro.replace(texto) { "${it.groupValues[1]}<resumo>" }
        texto = endereco6.replace(texto) { if (ipv6(it.value)) "<ipv6>" else it.value }
        texto = endereco4.replace(texto) { if (ipv4(it.value)) "<ipv4>" else it.value }
        return texto
    }

    /** Valor completo conserva os campos seguintes. Incompleto/livre retira o resto da mensagem. */
    private fun ocultarCampos(texto: String, campo: Regex, marcador: String): String = buildString {
        var copiado = 0
        for (achado in campo.findAll(texto)) {
            if (achado.range.first < copiado) continue
            val inicio = achado.range.last + 1
            var fim = texto.length
            if (inicio < texto.length) {
                val primeiro = texto[inicio]
                if (primeiro in "\"'[{" ) {
                    var quote: Char? = primeiro.takeIf { it == '"' || it == '\'' }
                    val esperados = mutableListOf<Char>()
                    if (primeiro == '[') esperados.add(']')
                    if (primeiro == '{') esperados.add('}')
                    var escapado = false
                    var i = inicio + 1
                    while (i < texto.length) {
                        val c = texto[i]
                        if (quote != null) {
                            if (escapado) escapado = false
                            else if (c == '\\') escapado = true
                            else if (c == quote) {
                                quote = null
                                if (esperados.isEmpty()) { fim = i + 1; break }
                            }
                        } else if (c == '"' || c == '\'') quote = c
                        else if (c == '[') esperados.add(']')
                        else if (c == '{') esperados.add('}')
                        else if (c == ']' || c == '}') {
                            if (esperados.lastOrNull() != c) break
                            esperados.removeAt(esperados.lastIndex)
                            if (esperados.isEmpty()) { fim = i + 1; break }
                        }
                        i++
                    }
                }
            }
            append(texto, copiado, inicio).append(marcador)
            copiado = fim
        }
        append(texto, copiado, texto.length)
    }

    private val categoriasExternas = listOf(
        "address already in use" to "porta em uso", "connection refused" to "conexão recusada", // i18n-fora: categorias internas de erro do diário; não são texto da interface
        "network is unreachable" to "rede inacessível", "no route to host" to "sem rota", // i18n-fora: categorias internas de erro do diário; não são texto da interface
        "timed out" to "tempo esgotado", "timeout" to "tempo esgotado", "prazo esgotou" to "tempo esgotado",
        "permission denied" to "permissão recusada", "not permitted" to "operação recusada", // i18n-fora: categorias internas de erro do diário; não são texto da interface
        "no space" to "sem espaço", "sem espaço" to "sem espaço", "não está pareado aqui" to "pareamento ausente", // i18n-fora: termos de reconhecimento e categorias de erro do diário; preserva a redação
        "sem segredo guardado" to "pareamento ausente", "segredo carregado é do aparelho" to "pareamento de outro aparelho", // i18n-fora: termos de reconhecimento e categorias de erro do diário; preserva a redação
        "o transporte falhou" to "transporte falhou", "a sessão fechou" to "sessão fechada", // i18n-fora: termos de reconhecimento e categorias de erro do diário; preserva a redação
        "o outro lado saiu" to "outro lado desconectou", "camera" to "câmera", "codec" to "codec" // i18n-fora: categorias internas de erro do diário; não são texto da interface
    )
    private val codigoSistema = Regex("""(?i)\b(?:os error|errno)\s*[:=]?\s*(-?[0-9]{1,4})\b""")

    /** Prosa nativa/de exceção nunca é republicada; somente categorias e errno conhecido. */
    fun erroExterno(original: String?): String {
        val texto = original.orEmpty().lowercase(java.util.Locale.ROOT)
        val categoria = categoriasExternas.firstOrNull { (trecho, _) -> trecho in texto }?.second
            ?: "detalhe externo omitido"
        val errno = codigoSistema.findAll(texto).mapNotNull { it.groupValues[1].toIntOrNull() }
            .firstOrNull { it in -4095..4095 }
        return categoria + (errno?.let { "; errno=$it" } ?: "")
    }

    /** Causas e locais de código continuam visíveis; Throwable cru nunca vai para a logcat. */
    fun falha(erro: Throwable): String = buildString {
        var atual: Throwable? = erro
        val vistos = java.util.IdentityHashMap<Throwable, Boolean>()
        repeat(4) {
            val e = atual ?: return@repeat
            if (vistos.put(e, true) != null) { atual = null; return@repeat }
            if (isNotEmpty()) append("; causa=")
            append(e.javaClass.simpleName)
            append(": ").append(erroExterno(e.message))
            e.stackTrace.take(3).forEach { frame ->
                append(" @ ").append(frame.className).append('.').append(frame.methodName)
                    .append(':').append(frame.lineNumber)
            }
            if (e.suppressed.isNotEmpty()) append("; suprimidas=").append(e.suppressed.size)
            atual = e.cause
        }
    }

    private fun ipv4(texto: String): Boolean = texto.split('.').let { partes ->
        partes.size == 4 && partes.all { it.toIntOrNull() in 0..255 }
    }

    /** Parser numérico local: o diário nunca resolve DNS nem abre uma conexão. */
    private fun ipv6(texto: String): Boolean {
        val ip = texto.substringBefore('%')
        if (":::" in ip || !ip.contains(':')) return false
        val comprimido = ip.contains("::")
        if (comprimido && ip.indexOf("::") != ip.lastIndexOf("::")) return false
        if (!comprimido && (ip.startsWith(':') || ip.endsWith(':'))) return false
        val partes = ip.split(':').filter { it.isNotEmpty() }
        val comIpv4 = partes.lastOrNull()?.contains('.') == true
        if (comIpv4 && !ipv4(partes.last())) return false
        val hex = if (comIpv4) partes.dropLast(1) else partes
        if (!hex.all { p -> p.length in 1..4 && p.all { it in "0123456789abcdefABCDEF" } }) return false
        val unidades = partes.size + if (comIpv4) 1 else 0
        return if (comprimido) unidades < 8 else unidades == 8
    }
}
