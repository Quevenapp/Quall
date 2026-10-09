package com.quall.android.receive

import android.net.Uri
import android.os.Handler
import android.os.Looper

/** Recording state is independent of display stats, which are replaced on every update. */
object GravacaoRecebidaBus {
    enum class Fase { PARADA, ESPERANDO_IDR, GRAVANDO, SALVANDO, SALVA, ERRO }
    data class Estado(
        val fase: Fase = Fase.PARADA,
        val segundos: Long = 0,
        val nome: String = "",
        val uri: Uri? = null,
        val detalhe: String = "",
        val parte: Int = 1,
    ) {
        val ocupada: Boolean get() = fase == Fase.ESPERANDO_IDR || fase == Fase.GRAVANDO || fase == Fase.SALVANDO
    }
    @Volatile var atual = Estado(); private set
    @Volatile var comecos = 0L; private set
    @Volatile private var listener: ((Estado) -> Unit)? = null
    private var dono: Any? = null
    private val main = Handler(Looper.getMainLooper())
    fun setListener(l: ((Estado) -> Unit)?) {
        listener = l
        if (l != null) main.post { if (listener === l) l(atual) }
    }
    /** One recording owns file/codec/journal resources until its last close has completed. */
    @Synchronized fun tentarIniciar(token: Any): Boolean {
        if (dono != null) return false
        dono = token
        publicarAgora(Estado(Fase.ESPERANDO_IDR))
        return true
    }
    @Synchronized fun publicar(token: Any, e: Estado) {
        if (dono === token) publicarAgora(e)
    }
    @Synchronized fun concluir(token: Any, e: Estado) {
        if (dono !== token) return
        publicarAgora(e)
        dono = null
    }
    @Synchronized fun publicar(e: Estado) {
        if (dono == null) publicarAgora(e)
    }
    private fun publicarAgora(e: Estado) {
        if (e.fase == Fase.ESPERANDO_IDR && !atual.ocupada) comecos++
        atual = e
        // A queued old completion must not repaint a newly opened receiver/recording.
        listener?.let { l -> main.post { if (listener === l && atual === e) l(e) } }
    }
}
