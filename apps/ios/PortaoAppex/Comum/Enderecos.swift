// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import Foundation

/// Os endereços IPv4 deste aparelho na LAN.
///
/// Existe por uma razão prática do degrau 4: o anúncio por mDNS está **desligado** (nenhum dos
/// perfis de provisionamento tem `com.apple.developer.networking.multicast`, e o pedido depende
/// da Apple), então o receptor conecta por IP digitado. Alguém precisa dizer qual é o IP — e a
/// extension é o único processo que sabe, porque é ela que hospeda a sinalização.
///
/// Escrever o IP no `os_log` transforma o fallback obrigatório do fluxo em algo que o roteiro de
/// medição lê sozinho, sem a pessoa ler a tela de Ajustes.
public enum Enderecos {
    /// `["en0=192.168.56.42", "bridge100=…"]`, sem loopback e sem link-local.
    public static func ipv4() -> [String] {
        var achados: [String] = []
        var primeiro: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&primeiro) == 0, let inicio = primeiro else { return achados }
        defer { freeifaddrs(inicio) }

        var atual: UnsafeMutablePointer<ifaddrs>? = inicio
        while let ponteiro = atual {
            let interface = ponteiro.pointee
            atual = interface.ifa_next

            guard let endereco = interface.ifa_addr,
                  endereco.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            guard (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }

            var texto = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let situacao = getnameinfo(endereco, socklen_t(endereco.pointee.sa_len),
                                      &texto, socklen_t(texto.count),
                                      nil, 0, NI_NUMERICHOST)
            guard situacao == 0 else { continue }
            let ip = String(cString: texto)
            guard !ip.hasPrefix("169.254.") else { continue }
            achados.append("\(String(cString: interface.ifa_name))=\(ip)")
        }
        return achados
    }
}
