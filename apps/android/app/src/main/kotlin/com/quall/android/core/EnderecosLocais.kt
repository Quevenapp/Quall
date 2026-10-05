package com.quall.android.core

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.NetworkInterface

/** Endereços para o par da LAN digitar: IPv4 primeiro, IPv6 ULA/global como fallback. */
object EnderecosLocais {
    data class Endereco(val interfaceNome: String, val ip: String, val ipv6: Boolean)

    fun listar(): List<Endereco> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !it.isPointToPoint && interfaceDeLan(it.name) }
            .flatMap { iface -> iface.inetAddresses.toList().mapNotNull { classificar(iface.name, it) } }
            .let(::ordenar)
    }.getOrElse { emptyList() }

    /** Não oferecer rmnet/CLAT/celular ou túneis/VPN como caminho de LAN. */
    internal fun interfaceDeLan(nome: String): Boolean =
        listOf("wlan", "eth", "rndis", "usb", "ncm").any { nome.startsWith(it) }
            || (nome.startsWith("en") && nome.drop(2).firstOrNull()?.isDigit() == true)
            // Hotspot continua sendo LAN; a enumeração anterior também oferecia seu IPv4.
            || listOf("ap", "swlan", "softap", "ap_br_wlan", "ap_br_softap").any { prefixo ->
                nome.startsWith(prefixo) && nome.drop(prefixo.length).let { sufixo ->
                    sufixo.isNotEmpty() && sufixo.all(Char::isDigit)
                }
            }

    internal fun classificar(nome: String, endereco: InetAddress): Endereco? {
        if (!interfaceDeLan(nome) || endereco.isAnyLocalAddress || endereco.isLoopbackAddress
            || endereco.isMulticastAddress) return null
        val ip = endereco.hostAddress?.takeIf { it.isNotBlank() } ?: return null
        return when (endereco) {
            is Inet4Address -> {
                val bytes = endereco.address.map { it.toInt() and 0xff }
                // 464XLAT e CGNAT são endereços do aparelho/operadora, não do par da LAN.
                if ((bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 0)
                    || (bytes[0] == 100 && bytes[1] in 64..127)
                    || bytes.all { it == 255 }) null
                else Endereco(nome, ip, false) // conserva IPv4 link-local do cabo
            }
            is Inet6Address -> {
                // A zona deste aparelho não identifica a interface de quem vai discar. Além
                // disso, o gathering ICE atual exclui fe80::/10; não prometer mídia por ele.
                val primeiro = endereco.address[0].toInt() and 0xff
                val ulaOuGlobal = (primeiro and 0xfe) == 0xfc || (primeiro and 0xe0) == 0x20
                if (endereco.isLinkLocalAddress || !ulaOuGlobal) null
                else Endereco(nome, ip.substringBefore('%'), true)
            }
            else -> null
        }
    }

    internal fun ordenar(enderecos: List<Endereco>): List<Endereco> = enderecos
        .sortedWith(compareBy<Endereco>({ if (it.ipv6) 1 else 0 },
            { if (it.interfaceNome.startsWith("wlan")) 0 else 1 }))
        .distinctBy { it.ip }

    fun comPorta(ip: String, porta: Int): String =
        if (ip.contains(':') && !ip.startsWith('[')) "[$ip]:$porta" else "$ip:$porta"
}
