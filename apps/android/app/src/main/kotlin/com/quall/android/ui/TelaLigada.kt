package com.quall.android.ui

import android.content.Context
import android.content.SharedPreferences
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/** A escolha local da câmera, do prompter e das transmissões/gravações; ligada por padrão. */
class TelaLigada(
    private val activity: AppCompatActivity,
    private val emUso: () -> Boolean,
) : DefaultLifecycleObserver, SharedPreferences.OnSharedPreferenceChangeListener {
    companion object {
        private const val ARQUIVO = "quall-tela"
        private const val CHAVE = "manter_ligada"

        private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(ARQUIVO, Context.MODE_PRIVATE)
        fun escolhida(c: Context): Boolean = prefs(c).getBoolean(CHAVE, true)
        fun escolher(c: Context, ligada: Boolean) { prefs(c).edit().putBoolean(CHAVE, ligada).apply() }
    }

    private var visivel = false

    init { activity.lifecycle.addObserver(this) }

    override fun onStart(owner: LifecycleOwner) {
        visivel = true
        prefs(activity).registerOnSharedPreferenceChangeListener(this)
        atualizar()
    }

    override fun onStop(owner: LifecycleOwner) {
        visivel = false
        prefs(activity).unregisterOnSharedPreferenceChangeListener(this)
        atualizar()
    }

    override fun onResume(owner: LifecycleOwner) { atualizar() }

    override fun onSharedPreferenceChanged(prefs: SharedPreferences, chave: String?) {
        if (chave == CHAVE) atualizar()
    }

    /** Só impede o bloqueio automático da janela visível. Não mantém a tela ligada em outro app. */
    fun atualizar() {
        val ligada = visivel && emUso() && escolhida(activity)
        val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        val atual = activity.window.attributes.flags and flag != 0
        if (ligada != atual) {
            if (ligada) activity.window.addFlags(flag) else activity.window.clearFlags(flag)
        }
    }
}
