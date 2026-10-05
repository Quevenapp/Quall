// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.core

import java.net.Inet6Address
import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EnderecosLocaisTest {
    private fun endereco(nome: String, ip: String) =
        EnderecosLocais.classificar(nome, InetAddress.getByName(ip))

    @Test
    fun lan_ipv6_global_e_ula_sao_fallbacks() {
        for (nome in listOf("wlan0", "eth0", "rndis0", "usb0", "ncm0", "en2", "ap0", "swlan0", "softap0", "ap_br_wlan0", "ap_br_softap0")) {
            for (ip in listOf("fd00::1234", "fc00::1234", "2001:db8::1234")) {
                assertTrue(endereco(nome, ip)!!.ipv6)
            }
        }
    }

    @Test
    fun celular_vpn_e_tunel_nao_viram_endereco_de_lan() {
        for (nome in listOf("rmnet_data0", "clat4", "v4-wlan0", "tun0", "wg0", "ppp0", "utun0", "pdp_ip0", "lo", "apvpn", "swlanvpn")) {
            assertFalse(EnderecosLocais.interfaceDeLan(nome))
            assertNull(endereco(nome, "fd00::1"))
            assertNull(endereco(nome, "192.168.56.2"))
        }
    }

    @Test
    fun ipv4_e_cabo_continuam_sem_clat_ou_cgnat() {
        for (nome in listOf("wlan0", "ap0", "swlan0", "softap0", "ap_br_wlan0", "ap_br_softap0")) {
            assertNotNull(endereco(nome, "192.168.56.2"))
            for (ip in listOf("192.0.0.2", "192.0.0.254", "100.64.0.1", "100.127.255.254")) {
                assertNull(endereco(nome, ip))
            }
        }
        for (ip in listOf("192.168.56.2", "10.77.0.2", "172.16.53.2", "100.128.0.1", "169.254.1.2")) {
            assertNotNull(endereco("rndis0", ip))
        }
    }

    @Test
    fun link_local_ipv6_loopback_e_multicast_nao_sao_oferecidos() {
        for (ip in listOf("fe80::1", "fe81::1", "febf::1", "fec0::1", "64:ff9b::1", "::", "::1", "ff02::1", "0.0.0.0", "127.0.0.1", "224.0.0.1", "255.255.255.255")) {
            assertNull(endereco("wlan0", ip))
        }
    }

    @Test
    fun ipv4_conserva_prioridade_e_wifi_lidera_cada_familia() {
        val ipv6Wifi = endereco("wlan0", "fd00::1")!!
        val ipv6Cabo = endereco("eth0", "fd00::2")!!
        val ipv4Wifi = endereco("wlan0", "192.168.56.2")!!
        val ipv4Cabo = endereco("rndis0", "169.254.1.2")!!
        assertEquals(listOf(ipv4Wifi, ipv4Cabo, ipv6Wifi, ipv6Cabo),
            EnderecosLocais.ordenar(listOf(ipv6Cabo, ipv4Cabo, ipv6Wifi, ipv4Wifi, ipv4Wifi)))
        assertEquals(ipv6Wifi, EnderecosLocais.ordenar(listOf(ipv6Cabo, ipv6Wifi)).first())
    }

    @Test
    fun zona_local_de_endereco_global_nao_e_repassada_ao_par() {
        val global = Inet6Address.getByAddress(null, InetAddress.getByName("2001:db8::1").address, 7)
        assertFalse(EnderecosLocais.classificar("wlan0", global)!!.ip.contains('%'))
    }

    @Test
    fun portas_de_video_e_prompter_usam_colchetes_ipv6() {
        assertEquals("192.168.56.2:7877", EnderecosLocais.comPorta("192.168.56.2", 7877))
        assertEquals("[fd00::1]:7877", EnderecosLocais.comPorta("fd00::1", 7877))
        assertEquals("[2001:db8::1]:7979", EnderecosLocais.comPorta("2001:db8::1", 7979))
        assertEquals("[fd00::1]:7979", EnderecosLocais.comPorta("[fd00::1]", 7979))
    }
}
