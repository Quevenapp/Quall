package com.quall.android.discovery

import android.content.Context
import android.net.wifi.WifiManager
import com.quall.android.core.LogSeguro as Log

/**
 * `MulticastLock`: sem ele o Android filtra pacotes multicast recebidos quando o rádio de Wi-Fi
 * entra em economia de energia (Doze / App Standby) — mDNS simplesmente some, sem erro. Achado
 * registrado em `docs/bancada.md` como tarefa desta frente no M2.
 *
 * Vale para qualquer socket multicast que o processo abrir diretamente — inclusive o que o
 * núcleo (`mdns-sd`, via JNI, quando a Frente 1 expuser o bridge) vai abrir por baixo. O
 * `NsdManager` do Android fala com o daemon de mDNS do sistema em vez de abrir socket próprio, e
 * por isso é menos sensível a isto — mas o lock é adquirido de qualquer forma sempre que a
 * descoberta está ativa, porque é o caminho que o resto do Quall (núcleo nativo) vai depender de
 * verdade.
 */
class MulticastLockManager(context: Context) {
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var lock: WifiManager.MulticastLock? = null

    @Synchronized
    fun acquire() {
        if (lock?.isHeld == true) return
        val l = wifi.createMulticastLock("quall-mdns")
        l.setReferenceCounted(true)
        l.acquire()
        lock = l
        Log.i("QuallMulticastLock", "adquirido")
    }

    @Synchronized
    fun release() {
        val l = lock ?: return
        if (l.isHeld) l.release()
        lock = null
        Log.i("QuallMulticastLock", "liberado")
    }

    @Synchronized
    fun isHeld(): Boolean = lock?.isHeld == true
}
