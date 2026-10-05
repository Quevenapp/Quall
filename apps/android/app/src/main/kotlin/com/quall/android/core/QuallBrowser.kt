package com.quall.android.core

import org.json.JSONArray

/**
 * Lista de aparelhos Quall na LAN, pelo **mesmo** mDNS que o núcleo usa (`mdns-sd`, socket
 * próprio), e não pelo `NsdManager` do Android.
 *
 * A troca é consequência do que a rodada anterior desta frente mediu no aparelho, não preferência
 * de estilo: o `NsdManager` aceita **uma** resolução em voo por vez, devolve
 * `FAILURE_ALREADY_ACTIVE` (código não documentado) para a segunda, e — pior — pode não chamar
 * nem sucesso nem falha quando o serviço resolvido já morreu, sem timeout nenhum. Um registro
 * mDNS obsoleto na rede travava a fila para sempre, e o aparelho que estava mesmo respondendo
 * nunca aparecia. `NsdDeviceDiscovery` continua no repositório como registro desses dois defeitos
 * e como caminho de contingência se algum dia o núcleo não carregar.
 *
 * Vantagem que só aparece agora: o JSON já traz `capabilities` e `endpoint` prontos, o mesmo que
 * o desktop vê — nada de reconstruir `ip:porta` na casca.
 */
object QuallBrowser {

    data class Device(
        val deviceId: String,
        val displayName: String,
        val protocolVersion: Int,
        val screenSource: Boolean,
        val cameraSource: Boolean,
        val sink: Boolean,
        /** `"ip:porta"`, ou `null` quando o aparelho não anunciou endereço utilizável. */
        val endpoint: String?,
        /**
         * O papel anunciado (chave TXT `pa`, `docs/contrato-teleprompter.md` §2), ou `null` para
         * todo aparelho de vídeo e toda build anterior. Ver [Papeis] para quem mostra o quê.
         */
        val papel: String? = null,
    )

    /**
     * Navega por `ms` milissegundos e devolve o que apareceu. **Bloqueia** — chame de uma thread
     * de trabalho.
     *
     * Abre e fecha o navegador a cada varredura de propósito: um handle de longa vida seria mais
     * eficiente e daria um recurso a mais para vazar num app que passa horas aberto, para ganhar
     * poucos milissegundos numa tela que se olha uma vez.
     */
    fun varrer(ms: Int): List<Device> {
        if (!QuallNative.carregado) return emptyList()
        val b = QuallNative.browserStart()
        if (b == 0L) {
            com.quall.android.core.LogSeguro.w("QuallBrowser", "browserStart falhou status=${QuallNative.lastStatus()}: ${com.quall.android.core.LogSeguro.erroExterno(QuallNative.lastError())}")
            return emptyList()
        }
        return try {
            val n = QuallNative.browserCollect(b, ms)
            val json = QuallNative.browserDevicesJson(b)
            // Contagens distinguem núcleo/lista sem publicar nomes, IDs ou endpoints na logcat.
            val aparelhos = interpretar(json)
            com.quall.android.core.LogSeguro.i("QuallBrowser", "collect=$n aparelhos=${aparelhos.size} json_chars=${json.length}")
            aparelhos
        } finally {
            QuallNative.browserStop(b)
        }
    }

    /**
     * Como [varrer], mas em fatias de 250 ms, e sai antes quando [parar] disser — a tela que fecha no
     * meio da procura não segura o navegador (nem o `MulticastLock`) até o fim dos 5 s. A lista é a
     * mesma: `quall_browser_collect` acumula os achados no navegador entre uma chamada e outra.
     */
    fun varrer(ms: Int, parar: () -> Boolean): List<Device> {
        if (!QuallNative.carregado || parar()) return emptyList()
        val b = QuallNative.browserStart()
        if (b == 0L) {
            com.quall.android.core.LogSeguro.w("QuallBrowser", "browserStart falhou status=${QuallNative.lastStatus()}: ${com.quall.android.core.LogSeguro.erroExterno(QuallNative.lastError())}")
            return emptyList()
        }
        return try {
            var resta = ms
            var n = 0
            while (resta > 0 && !parar()) {
                val fatia = minOf(250, resta)
                n = QuallNative.browserCollect(b, fatia)
                if (n < 0) break
                resta -= fatia
            }
            if (parar()) {
                com.quall.android.core.LogSeguro.i("QuallBrowser", "procura interrompida: a tela fechou")
                return emptyList()
            }
            val json = QuallNative.browserDevicesJson(b)
            val aparelhos = interpretar(json)
            com.quall.android.core.LogSeguro.i("QuallBrowser", "collect=$n aparelhos=${aparelhos.size} json_chars=${json.length}")
            aparelhos
        } finally {
            QuallNative.browserStop(b)
        }
    }

    private fun interpretar(json: String): List<Device> = runCatching {
        val arr = JSONArray(json)
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val caps = o.optJSONObject("capabilities")
            Device(
                deviceId = o.optString("device_id"),
                displayName = o.optString("display_name"),
                protocolVersion = o.optInt("protocol_version"),
                screenSource = caps?.optBoolean("screen_source") ?: false,
                cameraSource = caps?.optBoolean("camera_source") ?: false,
                sink = caps?.optBoolean("sink") ?: false,
                endpoint = o.optString("endpoint").takeIf { it.isNotBlank() && it != "null" },
                // A chave só aparece quando o aparelho anuncia um papel; ausente = vídeo.
                papel = if (o.has("papel") && !o.isNull("papel")) o.optString("papel") else null,
            )
        }
    }.getOrElse { emptyList() }
}
