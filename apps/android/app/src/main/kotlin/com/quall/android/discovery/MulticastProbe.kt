package com.quall.android.discovery

import com.quall.android.core.LogSeguro as Log
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface

/**
 * Prova em campo — não em teoria — que pacotes multicast chegam ao processo com o
 * [MulticastLockManager] segurado. Abre um `MulticastSocket` bruto no grupo/porta reais do mDNS
 * (`224.0.0.251:5353`, o mesmo endereço que `tools/multicast-probe.py` mediu entre o MacBook e o
 * Dell G3 em `docs/bancada.md`) e conta datagramas por [durationMs].
 *
 * Não decodifica o pacote DNS — só conta chegada. É o suficiente para responder a pergunta desta
 * tarefa (chega ou não chega ao processo) sem reimplementar um parser de mDNS que o núcleo, via
 * `mdns-sd`, já tem em Rust.
 */
object MulticastProbe {
    private const val TAG = "QuallMulticastProbe"
    private const val GROUP = "224.0.0.251"
    private const val PORT = 5353

    data class Result(val received: Int, val fromAddresses: Set<String>)

    fun listen(durationMs: Long): Result {
        val group = InetAddress.getByName(GROUP)
        val socket = MulticastSocket(PORT)
        socket.reuseAddress = true
        socket.soTimeout = 500

        // Junta pelo grupo em toda interface de rede disponível — no aparelho real isso é a
        // interface Wi-Fi. Sem isso, alguns fabricantes não entregam multicast na interface
        // default sem bind explícito.
        val joinedAny = tryJoinAllInterfaces(socket, group)
        if (!joinedAny) {
            Log.w(TAG, "não consegui entrar no grupo $GROUP em nenhuma interface")
        }

        val received = HashSet<String>()
        var count = 0
        val buf = ByteArray(2048)
        val deadline = System.currentTimeMillis() + durationMs
        while (System.currentTimeMillis() < deadline) {
            try {
                val packet = DatagramPacket(buf, buf.size)
                socket.receive(packet)
                count++
                received.add(packet.address.hostAddress ?: "?")
            } catch (_: java.net.SocketTimeoutException) {
                // normal: só um jeito de checar o prazo periodicamente
            } catch (e: Exception) {
                Log.w(TAG, "erro recebendo", e)
            }
        }
        runCatching { socket.close() }
        return Result(count, received)
    }

    private fun tryJoinAllInterfaces(socket: MulticastSocket, group: InetAddress): Boolean {
        var joined = false
        val ifaces = runCatching {
            java.util.Collections.list(NetworkInterface.getNetworkInterfaces())
        }.getOrDefault(emptyList())
        for (iface in ifaces) {
            if (!iface.isUp || iface.isLoopback || !iface.supportsMulticast()) continue
            try {
                socket.joinGroup(InetSocketAddress(group, PORT), iface)
                joined = true
            } catch (e: Exception) {
                Log.d(TAG, "não entrou em ${iface.name}: ${Log.erroExterno(e.message)}")
            }
        }
        return joined
    }
}
