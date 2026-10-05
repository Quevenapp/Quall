package com.quall.android.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.ext.SdkExtensions
import android.os.Handler
import android.os.Looper
import com.quall.android.core.LogSeguro as Log

/**
 * Lista de aparelhos da rede pela API de alto nível do Android (`NsdManager`), que fala com o
 * daemon de mDNS do sistema em vez de abrir socket próprio. É o caminho usado pela tela "ver
 * aparelhos da rede" do app — não o caminho que o núcleo Rust vai usar quando o bridge JNI
 * existir (esse abre socket próprio via `mdns-sd`, e é aí que o [MulticastLockManager] importa
 * de verdade; ver a documentação da classe).
 *
 * Tipo de serviço espelha `SERVICE_TYPE` de `crates/quall-core/src/protocol.rs`
 * (`"_quall._tcp"`) — aqui com o ponto final que o `NsdManager` exige.
 */
class NsdDeviceDiscovery(context: Context) {
    companion object {
        private const val TAG = "QuallNsd"
        const val SERVICE_TYPE = "_quall._tcp."
    }

    data class DiscoveredDevice(
        val serviceName: String,
        val host: String?,
        val port: Int,
    )

    private val nsdManager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val found = LinkedHashMap<String, DiscoveredDevice>()
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var onUpdate: ((List<DiscoveredDevice>) -> Unit)? = null
    // Achado em bancada (A07, Android 16): a partir da API 33, `registerServiceInfoCallback`
    // chama de volta numa "ConnectivityThread" interna do sistema, não na main — e o
    // `resolveService` legado (API < 33) também não garante a main. `submit()` do adapter mexe
    // em RecyclerView, e RecyclerView derruba o processo se tocado fora da main
    // (`CalledFromWrongThreadException`), sem aviso prévio nenhum. Todo `onUpdate` sai por aqui.
    private val mainHandler = Handler(Looper.getMainLooper())

    // Achado em bancada (A10s, Android 11): `NsdManager.resolveService` só aceita **uma**
    // resolução em voo por vez — chamar de novo antes da primeira terminar derruba a segunda com
    // `onResolveFailed(..., FAILURE_ALREADY_ACTIVE=3)`, silenciosamente (sem crash, só o
    // aparelho nunca aparece na lista). Aconteceu de verdade aqui: dois serviços `_quall._tcp`
    // (um deles anúncio remanescente de uma sessão anterior de `quall-probe`, ainda no cache de
    // mDNS) chegaram quase juntos, e o segundo `resolve()` foi descartado. Uma fila resolve um de
    // cada vez — mais lento, mas correto. Documentação do Android não avisa disso.
    private val pendingResolves = ArrayDeque<NsdServiceInfo>()
    private var resolveInFlight = false

    fun start(onUpdate: (List<DiscoveredDevice>) -> Unit) {
        stop()
        this.onUpdate = onUpdate
        found.clear()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.i(TAG, "descoberta iniciada: $serviceType")
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                Log.i(TAG, "serviço LAN achado")
                resolve(service)
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                found.remove(service.serviceName)
                publish()
            }

            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "falha ao iniciar descoberta: $errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        discoveryListener = listener
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    @Synchronized
    private fun resolve(service: NsdServiceInfo) {
        pendingResolves.addLast(service)
        pumpResolveQueue()
    }

    @Synchronized
    private fun pumpResolveQueue() {
        if (resolveInFlight) return
        val next = pendingResolves.removeFirstOrNull() ?: return
        resolveInFlight = true

        // Achado em bancada (A10s, Android 11): resolver um serviço `_quall._tcp` cujo anúncio
        // mDNS já não tem ninguém respondendo (processo do outro lado morreu sem mandar
        // "Goodbye", registro ainda vivo no cache local) pode nunca chamar `onServiceResolved`
        // nem `onResolveFailed` — o `NsdManager` não garante timeout. Sem um limite próprio, um
        // serviço morto travava a fila inteira para sempre, e o aparelho seguinte na fila (o que
        // estava mesmo respondendo) nunca era resolvido. 5 s é generoso para LAN.
        var done = false
        val advance = {
            if (!done) {
                done = true
                synchronized(this) { resolveInFlight = false }
                pumpResolveQueue()
            }
        }
        val timeoutRunnable = Runnable {
            Log.w(TAG, "resolve de serviço LAN não respondeu em 5s — seguindo em frente")
            advance()
        }
        mainHandler.postDelayed(timeoutRunnable, 5_000)

        resolveOne(next) {
            mainHandler.removeCallbacks(timeoutRunnable)
            advance()
        }
    }

    private fun resolveOne(service: NsdServiceInfo, onDone: () -> Unit) {
        // `registerServiceInfoCallback` é do 14, ou do 13 com a extensão 7 do SDK (que vem por
        // atualização da Play e nem todo Android 13 tem). Antes era `>= TIRAMISU` puro: um 13 sem a
        // extensão fechava o app na busca com `NoSuchMethodError`.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                SdkExtensions.getExtensionVersion(Build.VERSION_CODES.TIRAMISU) >= 7)
        ) {
            nsdManager.registerServiceInfoCallback(
                service,
                { it.run() },
                object : NsdManager.ServiceInfoCallback {
                    private var finished = false
                    private fun finish() {
                        if (finished) return
                        finished = true
                        onDone()
                    }
                    override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                        Log.w(TAG, "registro de callback de serviço LAN falhou: $errorCode")
                        finish()
                    }
                    override fun onServiceUpdated(info: NsdServiceInfo) {
                        addResolved(info)
                        runCatching { nsdManager.unregisterServiceInfoCallback(this) }
                        finish()
                    }
                    override fun onServiceLost() {
                        finish()
                    }
                    override fun onServiceInfoCallbackUnregistered() {
                        finish()
                    }
                },
            )
        } else {
            @Suppress("DEPRECATION")
            nsdManager.resolveService(service, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    Log.w(TAG, "resolve de serviço LAN falhou: $errorCode")
                    onDone()
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    addResolved(serviceInfo)
                    onDone()
                }
            })
        }
    }

    private fun addResolved(info: NsdServiceInfo) {
        val host = runCatching { info.host?.hostAddress }.getOrNull()
        found[info.serviceName] = DiscoveredDevice(info.serviceName, host, info.port)
        publish()
    }

    private fun publish() {
        val snapshot = found.values.toList()
        mainHandler.post { onUpdate?.invoke(snapshot) }
    }

    fun stop() {
        val l = discoveryListener ?: return
        runCatching { nsdManager.stopServiceDiscovery(l) }
        discoveryListener = null
    }
}
