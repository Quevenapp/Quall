package com.quall.android.bancada

import android.app.Activity
import android.os.Bundle
import android.util.Log
import com.quall.android.dvd.ConversaoDvdService

/**
 * **A porta de bancada do DVD para MP4** (a D1 de `docs/dvd-para-mp4.md` §2.8), só no APK de
 * `debug`: converte um VOB copiado para a pasta do app, sem leitor nem IFO (as faixas de som no modo
 * automático do C), pelo mesmo serviço do produto. O VOB é da bancada: **apague depois**.
 *
 * ```
 * adb push VTS_01_1.VOB /sdcard/Android/data/com.quall.android/files/
 * adb shell am start -n com.quall.android/.bancada.BancadaDoDvdActivity --es arquivo VTS_01_1.VOB
 * adb shell am start -n com.quall.android/.bancada.BancadaDoDvdActivity --es arquivo parar
 * adb logcat -s QuallDvd
 * adb shell rm /sdcard/Android/data/com.quall.android/files/VTS_01_1.VOB
 * ```
 */
class BancadaDoDvdActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        val arquivo = intent.getStringExtra("arquivo").orEmpty()
        when {
            arquivo == "parar" -> ConversaoDvdService.parar(this)
            arquivo.isNotEmpty() -> {
                Log.i("QuallDvd", "bancada: converter o arquivo $arquivo")
                ConversaoDvdService.comecarDoArquivo(this, arquivo)
            }
            else -> Log.w("QuallDvd", "bancada: falta --es arquivo <nome do VOB em Android/data/com.quall.android/files>")
        }
        window.decorView.postDelayed({ finish() }, 1500)
    }
}
