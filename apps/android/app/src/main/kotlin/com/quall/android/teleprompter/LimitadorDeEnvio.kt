package com.quall.android.teleprompter

/**
 * **No máximo um envio a cada [intervaloMs], e o último valor sempre sai** — para um gesto que
 * produz dezenas de valores por segundo (arrastar a linha de leitura) não virar dezenas de edições
 * no fio. É a mesma regra do Mac para os controles deslizantes (`limitado`, 0,12 s em
 * `apps/macos/Sources/QuallApp/Teleprompter.swift`), com uma coisa a mais: **ao soltar, o valor
 * final sai na hora**, sem esperar o intervalo.
 *
 * Conta pura, com o relógio de quem chama (na tela, `SystemClock.uptimeMillis`): quem chama agenda
 * [vencer] para [quandoSai].
 */
class LimitadorDeEnvio(private val intervaloMs: Long) {
    private var ultimoEnvioMs: Long? = null
    private var enviado: Double? = null
    private var pendente: Double? = null

    /** Um valor novo durante o gesto. Devolve o valor a mandar **agora**, ou `null` (fica esperando por [vencer]). */
    fun oferecer(valor: Double, agoraMs: Long): Double? {
        val ultimo = ultimoEnvioMs
        if (ultimo == null || agoraMs - ultimo >= intervaloMs) return marcar(valor, agoraMs)
        pendente = valor
        return null
    }

    /** Quando o valor que espera pode sair (no relógio de quem chama), ou `null` se nada espera. */
    fun quandoSai(): Long? = if (pendente == null) null else (ultimoEnvioMs ?: 0L) + intervaloMs

    /** O relógio chegou: sai o valor que espera — o mais novo, não um do meio. */
    fun vencer(agoraMs: Long): Double? {
        val p = pendente ?: return null
        val quando = quandoSai() ?: return null
        return if (agoraMs >= quando) marcar(p, agoraMs) else null
    }

    /** O dedo soltou: o valor final sai já, a menos que já tenha saído; nada fica esperando. */
    fun soltar(valor: Double, agoraMs: Long): Double? {
        pendente = null
        return if (valor != enviado) marcar(valor, agoraMs) else null
    }

    private fun marcar(valor: Double, agoraMs: Long): Double {
        ultimoEnvioMs = agoraMs
        enviado = valor
        pendente = null
        return valor
    }
}
