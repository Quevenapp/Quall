package com.quall.bancada.sondar5

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

const val ETIQUETA = "SondaR5"

/**
 * O relato de uma sonda: notas no logcat (etiqueta [ETIQUETA]) e um JSON só, gravado em dois
 * lugares — `files/` do app (lido por `adb shell run-as`) e `/sdcard/Android/data/<pacote>/files/`
 * (lido por `adb pull`).
 *
 * As três linhas que o roteiro (`rodar.sh`) procura, sempre nesta ordem e sempre uma vez:
 *
 *     VEREDITO: S-A1 <texto>
 *     SONDA-R5 FIM S-A1 <caminho do JSON em files/>
 *
 * **Nenhuma sonda guarda imagem nem som**: só contadores, carimbos, tamanhos e níveis.
 */
class Relato(private val ctx: Context, val id: String) {
    val raiz = JSONObject().apply {
        put("sonda", id)
        put("aparelho", "${Build.MANUFACTURER} ${Build.MODEL}")
        put("android", Build.VERSION.RELEASE)
        put("api", Build.VERSION.SDK_INT)
        put("inicio_ms", System.currentTimeMillis())
    }
    private val notas = JSONArray()
    private val fechado = AtomicBoolean(false)

    fun nota(texto: String) {
        Log.i(ETIQUETA, "$id: $texto")
        synchronized(notas) { notas.put(texto) }
    }

    /** Guarda um valor no JSON, de qualquer thread. */
    fun por(chave: String, valor: Any?) = synchronized(raiz) { raiz.put(chave, valor ?: JSONObject.NULL) }

    val fechou: Boolean get() = fechado.get()

    /** Idempotente: o vigia do tempo e a própria sonda podem chegar aqui; vale o primeiro. */
    fun fechar(veredito: String): Boolean {
        if (!fechado.compareAndSet(false, true)) return false
        val texto = synchronized(raiz) {
            synchronized(notas) { raiz.put("notas", notas) }
            raiz.put("veredito", veredito)
            raiz.put("fim_ms", System.currentTimeMillis())
            raiz.toString(2)
        }
        val nome = "sonda-$id-${System.currentTimeMillis()}.json"
        val interno = File(ctx.filesDir, nome)
        interno.writeText(texto)
        runCatching { ctx.getExternalFilesDir(null)?.let { File(it, nome).writeText(texto) } }
            .onFailure { Log.w(ETIQUETA, "$id: não gravou a cópia externa: ${it.message}") }
        Log.i(ETIQUETA, "VEREDITO: $id $veredito")
        Log.i(ETIQUETA, "SONDA-R5 FIM $id ${interno.absolutePath}")
        return true
    }
}

/** Percentil simples (vizinho mais próximo) de uma lista já ordenada. */
fun percentil(ordenada: List<Double>, p: Double): Double? {
    if (ordenada.isEmpty()) return null
    val i = ((p / 100.0) * (ordenada.size - 1)).toInt().coerceIn(0, ordenada.size - 1)
    return ordenada[i]
}

fun resumo(valores: List<Double>): JSONObject {
    val o = valores.sorted()
    return JSONObject().apply {
        put("n", o.size)
        percentil(o, 5.0)?.let { put("p05", arred(it)) }
        percentil(o, 50.0)?.let { put("p50", arred(it)) }
        percentil(o, 95.0)?.let { put("p95", arred(it)) }
        if (o.isNotEmpty()) { put("min", arred(o.first())); put("max", arred(o.last())) }
    }
}

fun arred(v: Double, casas: Int = 3): Double {
    if (v.isNaN() || v.isInfinite()) return v
    val f = Math.pow(10.0, casas.toDouble())
    return Math.round(v * f) / f
}

fun ms(ns: Long): Double = ns / 1e6

/** "12,3" — o número como o relato em português escreve. */
fun fmt(v: Double?, casas: Int = 1): String =
    if (v == null) "—" else String.format(java.util.Locale.forLanguageTag("pt-BR"), "%.${casas}f", v)
