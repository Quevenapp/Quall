package com.quall.android.ui

import android.app.Activity
import android.graphics.Point
import android.graphics.Rect
import android.os.Build
import android.view.Display

// O Android 10 (API 29) das centrais multimídia: `Activity.display` e as `WindowMetrics` só
// existem do 30 em diante, e chamá-las no 29 fecha o app com `NoSuchMethodError`. Do 30 para
// cima, as funções abaixo são exatamente as chamadas de antes.

/** A tela em que a atividade está. */
val Activity.telaDaAtividade: Display?
    get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
    else @Suppress("DEPRECATION") windowManager.defaultDisplay

/** Os limites da janela agora (`currentWindowMetrics.bounds`). */
fun Activity.limitesDaJanela(): Rect =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) windowManager.currentWindowMetrics.bounds
    else window.decorView.let { v ->
        if (v.width > 0) Rect(0, 0, v.width, v.height)
        else Point().also { @Suppress("DEPRECATION") windowManager.defaultDisplay.getSize(it) }
            .let { Rect(0, 0, it.x, it.y) }
    }

/** O maior tamanho que a janela pode ter (`maximumWindowMetrics.bounds`): a tela inteira. */
fun Activity.limitesMaximosDaJanela(): Rect =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) windowManager.maximumWindowMetrics.bounds
    else Point().also { @Suppress("DEPRECATION") windowManager.defaultDisplay.getRealSize(it) }
        .let { Rect(0, 0, it.x, it.y) }
