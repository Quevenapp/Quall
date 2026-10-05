package com.quall.android.ui

import android.widget.TextView
import java.util.Locale

/** O formato de número das telas do teleprompter: vírgula decimal. */
internal val PT_BR: Locale = Locale.forLanguageTag("pt-BR")

/**
 * Escreve só se o texto mudou.
 *
 * As telas do teleprompter redesenham a cada 250 ms (o aviso depende do tempo, não só dos bits).
 * Um `setText` com o mesmo texto ainda relayouta e dispara evento de acessibilidade — medido em
 * 13/09: o `uiautomator dump` do A07 nunca achava a tela do controle ociosa ("could not get idle
 * state"), e um leitor de tela receberia a mesma frase quatro vezes por segundo.
 */
internal fun TextView.seMudou(novo: CharSequence) {
    if (text.toString() != novo.toString()) text = novo
}
