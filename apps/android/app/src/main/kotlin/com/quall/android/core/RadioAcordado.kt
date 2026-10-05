package com.quall.android.core

import android.content.Context
import android.net.wifi.WifiManager
import com.quall.android.core.LogSeguro as Log

/**
 * `WifiLock` em modo de baixa latência, segurado enquanto o emissor está no ar.
 *
 * # Por que existe
 *
 * Medido em 05/09/2026 (`docs/bancada.md` §8.33). O A10s levava **11,4 s** entre o receptor pedir
 * conexão e o telefone *registrar qualquer coisa* — nem câmera, nem codificador, nem pareamento:
 * ele simplesmente não sabia que alguém estava chamando. A causa não estava no Quall. TCP cru
 * contra a porta do emissor, sem protocolo nenhum no meio, deu **mediana de 31 ms e pior caso de
 * 1694 ms**; `ping` na mesma janela deu 0 % de perda com **mínimo de 3,8 ms e máximo de 1324 ms**.
 *
 * Esse desenho — mínimo de LAN, máximo de mais de um segundo, zero perda — é economia de energia
 * do rádio: ele dorme entre beacons e o pacote que chega de fora espera a próxima janela. Um
 * pareamento precisa de várias idas e voltas, e basta que algumas peguem a janela ruim para virar
 * dez segundos de tela parada. Também é por isso que a **segunda** conexão parecia instantânea: o
 * tráfego da primeira mantinha o rádio acordado.
 *
 * # O que este lock faz, e o que ele não faz
 *
 * `WIFI_MODE_FULL_LOW_LATENCY` desliga a economia de energia do rádio **e** pede ao driver o modo
 * de baixa latência. Em troca gasta bateria, então ele vale só enquanto o emissor está no ar — é
 * adquirido e solto exatamente nos mesmos pontos do [MulticastLockManager][
 * com.quall.android.discovery.MulticastLockManager].
 *
 * **Ele só tem efeito com o app em primeiro plano e a tela ligada**, por decisão do Android. O
 * emissor satisfaz as duas: é serviço em primeiro plano e a tela de espelhamento fica aberta. Se
 * um dia o produto quiser espelhar com a tela apagada, este lock deixa de valer e a espera lenta
 * volta — e aí o caminho é outro, não é subir o modo do lock.
 *
 * Não confundir com o `MulticastLock`, que resolve outra coisa (filtro de multicast recebido, que
 * faz o mDNS sumir). Os dois são `WifiManager` e são independentes.
 */
class RadioAcordado(context: Context) {
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var lock: WifiManager.WifiLock? = null

    @Synchronized
    fun adquirir() {
        if (lock?.isHeld == true) return
        // `WIFI_MODE_FULL_LOW_LATENCY` é API 29 e o `minSdk` é 30, então não há caminho de fallback
        // a manter: se ele falhar aqui, é falha de verdade e o log tem que dizer.
        val l = runCatching {
            wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "quall-emissor")
        }.getOrElse {
            Log.w(TAG, "não criou o WifiLock; a espera pode ficar lenta", it)
            return
        }
        l.setReferenceCounted(true)
        runCatching { l.acquire() }.onFailure {
            Log.w(TAG, "não adquiriu o WifiLock; a espera pode ficar lenta", it)
            return
        }
        lock = l
        Log.i(TAG, "adquirido (baixa latência) — o rádio não dorme enquanto o emissor espera")
    }

    @Synchronized
    fun liberar() {
        val l = lock ?: return
        runCatching { if (l.isHeld) l.release() }
        lock = null
        Log.i(TAG, "liberado")
    }

    @Synchronized
    fun estaSegurando(): Boolean = lock?.isHeld == true

    private companion object {
        const val TAG = "QuallRadioAcordado"
    }
}
