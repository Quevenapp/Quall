package com.quall.android.capture

import android.os.Handler
import android.os.Looper

/**
 * Canal simples de status do serviço de captura para a Activity, sem dependência extra
 * (`LocalBroadcastManager` está depreciada; um `Flow`/`LiveData` de verdade seria mais peça do
 * que este app precisa). A Activity registra um único ouvinte por vez; o serviço publica.
 */
object CaptureBus {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var listener: ((String) -> Unit)? = null

    fun setListener(l: ((String) -> Unit)?) {
        listener = l
    }

    fun publish(mensagem: String) {
        val l = listener ?: return
        mainHandler.post { l(mensagem) }
    }
}
