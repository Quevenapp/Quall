package com.quall.android.core

import androidx.annotation.StringRes
import java.util.Locale

/**
 * **Os textos de interface para quem não tem `Context`** (`docs/traducao.md`, Android): os módulos
 * puros (`teleprompter/Avisos`, `capture/RegrasDosControles`, `capture/dv/PainelDoVideoUsb`…) montam
 * frases, e as frases moram em `res/values/ e res/values-pt/` como todas as outras.
 *
 * No app a implementação é [Idioma.textos] (o `getString` do contexto, no idioma escolhido); nos
 * testes JVM é `TextosDeTeste.PT`/`EN`, que lê os mesmos XML. Assim um módulo puro continua provado
 * sem aparelho, e o teste que comparava a frase em português continua comparando a mesma frase.
 */
interface Textos {
    /** O idioma dos textos: formata número (vírgula ou ponto) junto com as frases. */
    val locale: Locale

    /** O `getString(id, *args)` do Android: sem argumentos, o texto como está; com, formatado. */
    fun s(@StringRes id: Int, vararg args: Any): String
}
