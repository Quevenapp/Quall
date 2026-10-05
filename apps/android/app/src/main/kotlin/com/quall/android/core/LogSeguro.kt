package com.quall.android.core

/** Mesmos níveis/tags em Debug e Release, com redação antes de escrever na logcat. */
object LogSeguro {
    fun erroExterno(texto: Any?): String = if (texto is Throwable) RedacaoDeLogs.falha(texto)
        else RedacaoDeLogs.erroExterno(texto?.toString())
    fun falha(erro: Throwable): String = RedacaoDeLogs.falha(erro)
    private fun escrever(nivel: Int, tag: String, texto: String?, erro: Throwable? = null): Int {
        val mensagem = RedacaoDeLogs.mensagem(texto.orEmpty())
        val causa = erro?.let { "\n" + RedacaoDeLogs.falha(it) }.orEmpty()
        return android.util.Log.println(nivel, RedacaoDeLogs.mensagem(tag), mensagem + causa)
    }

    fun v(tag: String, texto: String?, erro: Throwable? = null): Int =
        escrever(android.util.Log.VERBOSE, tag, texto, erro)
    fun d(tag: String, texto: String?, erro: Throwable? = null): Int =
        escrever(android.util.Log.DEBUG, tag, texto, erro)
    fun i(tag: String, texto: String?, erro: Throwable? = null): Int =
        escrever(android.util.Log.INFO, tag, texto, erro)
    fun w(tag: String, texto: String?, erro: Throwable? = null): Int =
        escrever(android.util.Log.WARN, tag, texto, erro)
    fun w(tag: String, erro: Throwable): Int = escrever(android.util.Log.WARN, tag, null, erro)
    fun e(tag: String, texto: String?, erro: Throwable? = null): Int =
        escrever(android.util.Log.ERROR, tag, texto, erro)
}
