package com.quall.android.core

import android.content.Context
import android.content.res.Configuration
import android.os.Build
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import com.quall.android.R
import java.util.Locale

/**
 * **O idioma do app: português ou inglês** (`docs/traducao.md`, Android).
 *
 * - **Padrão**: o do sistema. Os recursos resolvem sozinhos — `values-pt/` para qualquer `pt-*`,
 *   `values/` (inglês) para o resto. Nada é gravado enquanto o usuário não toca no seletor.
 * - **A escolha** (o seletor PT | EN do Início) vai para `AppCompatDelegate.setApplicationLocales`:
 *   no Android 13+ o sistema guarda e aplica ao processo inteiro (telas, serviços, `applicationContext`);
 *   no 9–12 o AppCompat guarda num arquivo dele (`AppLocalesMetadataHolderService` com
 *   `autoStoreLocales` no manifesto) e aplica **só às `AppCompatActivity`**.
 * - Por isso, abaixo do 13, quem não é `AppCompatActivity` (os serviços em primeiro plano, as
 *   notificações) pede o texto por [contexto], que monta um contexto no idioma escolhido. A escolha
 *   também é copiada para uma preferência nossa: o AppCompat só lê o arquivo dele quando a primeira
 *   `AppCompatActivity` nasce, e um serviço que sobe antes disso veria a lista vazia.
 *
 * A fonte de verdade de "qual idioma está valendo" é o próprio recurso ([codigo] lê `idioma_codigo`,
 * "pt" ou "en"): é exatamente o que a tela está mostrando, venha do sistema ou da escolha.
 */
object Idioma {
    const val PT = "pt"
    const val EN = "en"

    private const val PREFS = "quall_idioma"
    private const val CHAVE = "escolhido"

    /** "pt" ou "en": o idioma em que [ctx] está mostrando os textos agora. */
    fun codigo(ctx: Context): String = ctx.getString(R.string.idioma_codigo)

    /** A etiqueta BCP 47 que vai para o AppCompat: o português do Brasil é o texto-fonte. */
    private fun etiqueta(codigo: String): String = if (codigo == PT) "pt-BR" else "en"

    /**
     * Grava a escolha e aplica. As telas abertas são recriadas no novo idioma (no 13+ pelo sistema,
     * no 9–12 pelo AppCompat); a `MainActivity` trata a troca ela mesma (ver `onConfigurationChanged`
     * lá) para não recriar com uma sessão no ar.
     */
    fun escolher(ctx: Context, codigo: String) {
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(CHAVE, codigo).apply()
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(etiqueta(codigo)))
    }

    /** O idioma escolhido no seletor, ou `null` (segue o sistema). */
    private fun escolhido(ctx: Context): String? {
        val doAppCompat = AppCompatDelegate.getApplicationLocales()
        if (!doAppCompat.isEmpty) {
            val l = doAppCompat[0]?.language ?: return null
            return if (l == PT) PT else EN
        }
        return ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(CHAVE, null)
    }

    /**
     * Um contexto que fala o idioma escolhido, para quem o AppCompat não alcança abaixo do Android 13
     * (serviços, notificações, o `applicationContext`). No 13+ o sistema já aplica a escolha ao
     * processo inteiro, e o contexto volta como veio.
     *
     * **Não guarde o resultado** (o usuário pode trocar de idioma com o serviço no ar), e não peça
     * `applicationContext` dele: volta a ser o contexto original, no idioma do sistema.
     */
    fun contexto(ctx: Context): Context {
        if (Build.VERSION.SDK_INT >= 33) return ctx
        val codigo = escolhido(ctx) ?: return ctx
        if (codigo(ctx) == codigo) return ctx
        val config = Configuration(ctx.resources.configuration)
        config.setLocale(Locale.forLanguageTag(etiqueta(codigo)))
        return ctx.createConfigurationContext(config)
    }

    /** Os [Textos] de [ctx] para os módulos puros, no idioma em que [ctx] fala. */
    fun textos(ctx: Context): Textos = object : Textos {
        override val locale: Locale
            get() = ctx.resources.configuration.locales[0] ?: Locale.ROOT

        override fun s(id: Int, vararg args: Any): String =
            if (args.isEmpty()) ctx.getString(id) else ctx.getString(id, *args)
    }
}
