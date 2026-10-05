import Foundation

// O helper iOS chama o tradutor apenas na nota de cabo; este teste isolado não carrega UIKit.
func tr(_ texto: String, _ argumentos: CVarArg...) -> String {
    String(format: texto, arguments: argumentos)
}

@main
enum TestesDoIpv6 {
    static var verificacoes = 0
    static func conferir(_ condicao: Bool, _ mensagem: String) {
        verificacoes += 1
        precondition(condicao, mensagem)
    }
    static func main() {
        for (ip, esperado) in [
            ("192.0.2.1", "192.0.2.1:7877"),
            ("fd00::1234", "[fd00::1234]:7877"),
            ("2001:db8::1234", "[2001:db8::1234]:7877"),
            ("fe80::1234%7", "[fe80::1234%7]:7877"),
            ("[fd00::1234]", "[fd00::1234]:7877"),
        ] { conferir(Enderecos.comPorta(ip, porta: 7877) == esperado, "colchetes: \(ip)") }
        #if IOS_ENDERECOS
        for ip in ["fd00::1234", "fc00::1234", "2001:db8::1234", "fe80::1234%en0"] {
            conferir(Enderecos.classificar(ip: ip, interface: "en0") == .lan, "IPv6 físico: \(ip)")
            for interface in ["utun0", "pdp_ip0", "awdl0", "lo0"] {
                conferir(Enderecos.classificar(ip: ip, interface: interface) == nil, "túnel/celular: \(interface)")
            }
        }
        for ip in ["::", "::1", "ff02::1", "fe80::zz", "fdg::1", "fe80::1%", "fe80::1%en0%en1"] {
            conferir(Enderecos.classificar(ip: ip, interface: "en0") == nil, "IPv6 inválido/não LAN: \(ip)")
        }
        for ip in ["fe80::1", "fe81::1", "febf::1%7"] {
            conferir(Enderecos.ehIPv6LinkLocal(ip), "fe80::/10: \(ip)")
            conferir(PermissaoDeRedeLocal.enderecoEhDaRedeLocal(ip), "sonda de link-local: \(ip)")
        }
        conferir(!Enderecos.ehIPv6LinkLocal("fec0::1"), "limite fe80::/10")
        conferir(!PermissaoDeRedeLocal.enderecoEhDaRedeLocal("fdg::1"), "prefixo textual não vira IPv6")
        conferir(PermissaoDeRedeLocal.enderecoEhDaRedeLocal("[fd00::1]:7877"), "ULA com porta")
        conferir(PermissaoDeRedeLocal.host(de: "[fe80::1%en0]:7877") == "fe80::1%en0", "zona na sonda")
        let mascara = "ffff:ffff:ffff:ffff::"
        conferir(Enderecos.mesmoPrefixoIPv6("2001:db8:1:2::8", local: "2001:db8:1:2::1", mascara: mascara), "global no mesmo enlace")
        conferir(!Enderecos.mesmoPrefixoIPv6("2001:db8:1:3::8", local: "2001:db8:1:2::1", mascara: mascara), "global fora do enlace")
        conferir(!Enderecos.mesmoPrefixoIPv6("inválido", local: "2001:db8::1", mascara: mascara), "destino inválido")
        conferir(!Enderecos.mesmoPrefixoIPv6("2001:db8::8", local: "2001:db8::1", mascara: "::"), "máscara ausente não inventa LAN")
        let mistos: [(interface: String, ip: String, enlace: Enderecos.Enlace)] = [
            ("en0", "fd00::1", .lan), ("en2", "192.0.2.1", .lan)
        ]
        conferir(Enderecos.escolher(mistos, enlace: .lan) == "192.0.2.1", "prioridade IPv4 preservada")
        conferir(Enderecos.escolher([mistos[0]], enlace: .lan) == "fd00::1", "fallback IPv6 da LAN")
        conferir(Enderecos.destaque(lan: "fd00::1", cabo: nil, porta: 7877) == "[fd00::1]:7877", "emissor IPv6 tem endereço")
        conferir(Enderecos.classificar(ip: "169.254.1.1", interface: "en2") == .cabo, "cabo IPv4 preservado")
        conferir(Enderecos.classificar(ip: "100.74.1.1", interface: "pdp_ip0") == nil, "CGNAT descartado")
        conferir(LinkDePareamento.comPorta("fe80::1%en0") == "[fe80::1%en0]:7979", "controle preserva zona")
        print("iOS helpers IPv6: \(verificacoes) verificações passaram; sem UI/aparelho/rede")
        #else
        for ip in ["fd00::1", "fc00::1", "2001:db8::1"] {
            conferir(Enderecos.ipv6Utilizavel(ip), "fallback global/ULA: \(ip)")
        }
        for ip in ["::", "::1", "ff02::1", "fe80::1", "fe81::1", "febf::1", "fe80::1%en0", "fdg::1"] {
            conferir(!Enderecos.ipv6Utilizavel(ip), "não oferecer como endereço manual: \(ip)")
        }
        let mistos = Enderecos.ordenar([("en0", "fd00::1"), ("en2", "192.0.2.1")])
        conferir(mistos.first?.ip == "192.0.2.1", "prioridade IPv4 preservada")
        let ipv6 = Enderecos.ordenar([("en2", "fd00::2"), ("en0", "fd00::1")])
        conferir(ipv6.first?.ip == "fd00::1", "prioridade Wi-Fi preservada no fallback")
        print("macOS helpers IPv6: \(verificacoes) verificações passaram; sem UI/aparelho/rede")
        #endif
    }
}
