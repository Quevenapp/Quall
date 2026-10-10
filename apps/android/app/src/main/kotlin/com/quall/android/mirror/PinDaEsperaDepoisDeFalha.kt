package com.quall.android.mirror

import com.quall.android.core.QuallNative.Status

/**
 * Política conservadora: WRONG_PIN e PAIRING renovam o PIN da próxima espera.
 * O status não prova a fase do PAKE nem se o modo era PIN ou retomada. A troca
 * afeta apenas futuras conexões com PIN; não altera pares ou segredos salvos.
 * Outros status preservam o valor. Sessões bem-sucedidas não passam por aqui.
 * Retorna null para encerrar a espera se não houver novo PIN válido e diferente.
 */
internal fun pinDepoisDaFalhaDaEspera(
    pinAtual: String,
    status: Int,
    sortear: () -> String,
): String? {
    if (status != Status.WRONG_PIN && status != Status.PAIRING) return pinAtual
    repeat(8) {
        val candidato = runCatching(sortear).getOrNull() ?: return null
        if (candidato.length != 6 || !candidato.all { it in '0'..'9' }) return null
        if (candidato != pinAtual) return candidato
    }
    return null
}
