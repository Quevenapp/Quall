// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import Foundation
import SystemConfiguration

/// O endereço que a pessoa digita no outro aparelho.
///
/// Não é recurso avançado escondido: é o **fallback obrigatório** do `PROMPT.md` para rede com
/// mDNS bloqueado ou isolamento de AP, e já se pagou mais de uma vez nesta bancada. No macOS o
/// aparelho também aparece por mDNS (ao contrário do iPhone, sem entitlement de multicast), então
/// aqui o endereço é o segundo caminho — mas continua na tela, porque a rede que quebra a lista é
/// exatamente a rede em que a pessoa precisa dele.
enum Enderecos {
    /// Uma interface de rede deste Mac, pelo nome que a pessoa reconhece em Ajustes > Rede.
    ///
    /// Existe para "sair pela Ethernet" (pedido do usuário, 10/09): o Mac da bancada fica com Wi-Fi
    /// (`en0`) **e** a placa USB Ethernet (`en12`, AX88179B) na mesma rede, e a tela de espera só
    /// mostrava o endereço do Wi-Fi. Escolher uma interface aqui prende o vídeo nela
    /// (`QuallSessionOptions::bind_address`, `docs/fluxo-de-uso.md` §3 — "falta chamador, não
    /// mecanismo") e desliga as outras para o vídeo.
    struct Interface: Identifiable, Hashable {
        enum Tipo: Hashable { case wifi, ethernet, outra }
        let bsd: String
        let ip: String
        let nome: String
        let tipo: Tipo
        var id: String { bsd }

        /// "Ethernet — AX88179B · 192.168.57.3", "Wi-Fi · 192.168.57.5".
        var rotulo: String {
            switch tipo {
            case .wifi: return "Wi-Fi · \(ip)"
            case .ethernet: return nome.localizedCaseInsensitiveContains("ethernet")
                ? "\(nome) · \(ip)" : "Ethernet — \(nome) · \(ip)"
            case .outra: return "\(nome) (\(bsd)) · \(ip)"
            }
        }
    }

    /// As interfaces com IP utilizável, na mesma ordem de `locais()`, com nome e tipo vindos do
    /// SystemConfiguration — o mesmo cadastro que Ajustes > Rede mostra.
    static func interfaces() -> [Interface] {
        var nomePorBSD: [String: (String, Interface.Tipo)] = [:]
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let nome = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? bsd
            let tipoSC = SCNetworkInterfaceGetInterfaceType(interface) as String?
            let tipo: Interface.Tipo = tipoSC == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi
                : (tipoSC == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet : .outra)
            nomePorBSD[bsd] = (nome, tipo)
        }
        var vistos = Set<String>()
        return enderecosPorInterface().filter { vistos.insert($0.nome).inserted }.map { par in
            let (nome, tipo) = nomePorBSD[par.nome] ?? (par.nome, .outra)
            return Interface(bsd: par.nome, ip: par.ip, nome: nome, tipo: tipo)
        }
    }

    /// IP das interfaces de verdade deste Mac, mantendo IPv4 na frente.
    ///
    /// Em rede IPv6-only oferece ULA/global da LAN física. Link-local continua pela descoberta:
    /// `%en0` deste Mac não identifica a interface de quem vai discar no outro aparelho.
    static func locais() -> [String] {
        enderecosPorInterface().map(\.ip)
    }

    /// Os pares (interface, IPv4) que valem a pena, já na ordem de mostrar.
    private static func enderecosPorInterface() -> [(nome: String, ip: String)] {
        var achados: [(nome: String, ip: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let primeiro = ptr else { return [] }
        defer { freeifaddrs(ptr) }

        var atual: UnsafeMutablePointer<ifaddrs>? = primeiro
        while let interface = atual {
            defer { atual = interface.pointee.ifa_next }

            let bandeiras = Int32(interface.pointee.ifa_flags)
            guard (bandeiras & IFF_UP) == IFF_UP else { continue }
            // Laço local nunca é caminho para outro aparelho: mostrar `127.0.0.1` na tela de
            // espera mandaria a pessoa digitar um endereço que sempre aponta de volta para o
            // aparelho dela.
            guard (bandeiras & IFF_LOOPBACK) == 0 else { continue }
            guard let endereco = interface.pointee.ifa_addr else { continue }
            let familia = endereco.pointee.sa_family
            guard familia == UInt8(AF_INET) || familia == UInt8(AF_INET6) else { continue }

            let nome = String(cString: interface.pointee.ifa_name)
            // Interfaces de túnel, ponte de virtualização e "Awdl" (o rádio ponto-a-ponto do
            // AirDrop) sobem com IPv4 e não levam a lugar nenhum que o outro aparelho alcance.
            guard !nome.hasPrefix("utun"), !nome.hasPrefix("awdl"), !nome.hasPrefix("llw"),
                  !nome.hasPrefix("bridge"), !nome.hasPrefix("vmenet"), !nome.hasPrefix("ap") else { continue }
            if familia == UInt8(AF_INET6) {
                guard nome.hasPrefix("en"), (bandeiras & IFF_BROADCAST) != 0,
                      (bandeiras & IFF_POINTOPOINT) == 0 else { continue }
            }

            var texto = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let deu = getnameinfo(
                endereco, socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                &texto, socklen_t(texto.count), nil, 0, NI_NUMERICHOST)
            guard deu == 0 else { continue }
            let ip = String(cString: texto)
            guard !ip.isEmpty, !ip.hasPrefix("169.254.") else { continue }
            if familia == UInt8(AF_INET6), !ipv6Utilizavel(ip) { continue }
            achados.append((nome, ip))
        }

        // `en0` primeiro: no MacBook é o Wi-Fi, e é a interface em que os aparelhos da bancada
        // estão. Sem essa ordem, um Mac com Ethernet e Wi-Fi mostraria o endereço da rede em que
        // o celular não está.
        return ordenar(achados)
    }

    /// IPv4 conserva sua prioridade mesmo quando outra interface oferece IPv6.
    static func ordenar(_ achados: [(nome: String, ip: String)]) -> [(nome: String, ip: String)] {
        achados.sorted { a, b in
                let av6 = a.ip.contains(":"), bv6 = b.ip.contains(":")
                if av6 != bv6 { return !av6 }
                let pa = a.nome == "en0" ? 0 : (a.nome.hasPrefix("en") ? 1 : 2)
                let pb = b.nome == "en0" ? 0 : (b.nome.hasPrefix("en") ? 1 : 2)
                return pa == pb ? a.nome < b.nome : pa < pb
            }
    }

    static func ipv6Utilizavel(_ ip: String) -> Bool {
        var addr = in6_addr()
        guard !ip.contains("%"), inet_pton(AF_INET6, ip, &addr) == 1 else { return false }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        return bytes.contains(where: { $0 != 0 }) && bytes[0] != 0xff
            && !(bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1)
            && !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
    }

    /// `ip:porta` pronto para ser lido em voz alta e digitado no outro aparelho, ou `nil` quando
    /// não há rede nenhuma — caso em que a interface tem de dizer isso, e não mostrar um campo
    /// vazio.
    static func paraDigitar(porta: UInt16) -> String? {
        guard let ip = locais().first else { return nil }
        return comPorta(ip, porta: porta)
    }

    static func comPorta(_ ip: String, porta: UInt16) -> String {
        ip.contains(":") && !ip.hasPrefix("[") ? "[\(ip)]:\(porta)" : "\(ip):\(porta)"
    }

    /// Uma porta de sinalização livre, escolhida **antes** de hospedar.
    ///
    /// Por que a casca escolhe a porta em vez de deixar `signaling_port = 0`: o anúncio por mDNS
    /// precisa da porta, e `quall_host` bloqueia até alguém chegar — a porta só poderia ser lida
    /// da sessão depois que ela sobe, quando o anúncio já não serve para nada. Ver
    /// `QuallNetKit/Anunciante.swift`.
    ///
    /// O método é o de sempre: pedir ao sistema uma porta efêmera, ler qual saiu, e devolvê-la.
    /// Há uma janela entre fechar este socket e o núcleo abrir o dele — quem perder essa corrida
    /// recebe erro de bind e a casca tenta de novo, que é barato e honesto. Fingir que não há
    /// corrida seria pior.
    /// **A porta pedida, se estiver livre agora; senão uma efêmera** (a espera da câmera da tela R5
    /// tenta a 7877, a porta do vídeo nos roteiros do iOS). A mesma janela de corrida de
    /// `portaLivre`: quem perder recebe erro de bind no `quall_host` e tenta de novo.
    static func portaPreferida(_ desejada: UInt16) -> (porta: UInt16, eraAPedida: Bool) {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        if s >= 0 {
            defer { close(s) }
            var sim: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &sim, socklen_t(MemoryLayout<Int32>.size))
            var alvo = sockaddr_in()
            alvo.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            alvo.sin_family = sa_family_t(AF_INET)
            alvo.sin_port = desejada.bigEndian
            alvo.sin_addr.s_addr = INADDR_ANY.bigEndian
            let ligou = withUnsafePointer(to: &alvo) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if ligou == 0 { return (desejada, true) }
        }
        return (portaLivre(), false)
    }

    static func portaLivre() -> UInt16 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return 0 }
        defer { close(s) }

        var sim: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &sim, socklen_t(MemoryLayout<Int32>.size))

        var alvo = sockaddr_in()
        alvo.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        alvo.sin_family = sa_family_t(AF_INET)
        alvo.sin_port = 0
        alvo.sin_addr.s_addr = INADDR_ANY.bigEndian

        let ligou = withUnsafePointer(to: &alvo) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ligou == 0 else { return 0 }

        var lido = sockaddr_in()
        var tamanho = socklen_t(MemoryLayout<sockaddr_in>.size)
        let leu = withUnsafeMutablePointer(to: &lido) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(s, sa, &tamanho)
            }
        }
        guard leu == 0 else { return 0 }
        return UInt16(bigEndian: lido.sin_port)
    }
}
