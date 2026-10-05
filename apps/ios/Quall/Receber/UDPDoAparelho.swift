import Darwin

/// Os contadores de UDP do **aparelho inteiro**, pelo `net.inet.udp.stats` do kernel.
///
/// # Por que existe
///
/// Em 11/09/2026 o iPhone X perdeu, na tela estendida, rajadas de 30–90 % do que chegava por 0,5 a
/// 2 s, no rádio de 5 GHz com sinal excelente e com o rádio dizendo que não transbordou
/// (`rxFifo0Ovfl=0` no `wifid`). Sobrou uma suspeita que o núcleo não enxerga: o pacote chega ao
/// aparelho e o **socket** não tem onde pô-lo. A libjuice pede 1 MiB de `SO_RCVBUF` (`udp.c`), e
/// cada datagrama de ~1.200 bytes ocupa um bloco de 2 KB no kernel — cabem ~450, e um IDR de
/// 2436 × 1124 tem 580–620. O kernel conta cada um desses descartes; o núcleo só vê o buraco na
/// sequência.
///
/// É do aparelho inteiro, não da sessão: outro app recebendo UDP entraria na conta. Numa bancada com
/// o Quall sozinho na frente, a diferença durante a sessão é dele.
///
/// O layout é o `struct udpstat` do XNU (`bsd/netinet/udp_var.h`): `udps_ipackets` no índice 0,
/// `udps_fullsock` no 6. Conferido no Mac com o `netstat -s -p udp` ("dropped due to full socket
/// buffers") em 11/09 — o mesmo kernel.
enum UDPDoAparelho {
    struct Leitura {
        let datagramas: UInt32
        let socketCheio: UInt32
    }

    /// `nil` se o sistema não deixar ler (a caixa de areia pode recusar) ou a estrutura vier curta.
    static func ler() -> Leitura? {
        var tamanho = 0
        guard sysctlbyname("net.inet.udp.stats", nil, &tamanho, nil, 0) == 0, tamanho >= 7 * 4 else { return nil }
        var dados = [UInt8](repeating: 0, count: tamanho)
        guard sysctlbyname("net.inet.udp.stats", &dados, &tamanho, nil, 0) == 0 else { return nil }
        return dados.withUnsafeBytes { p in
            Leitura(datagramas: p.load(fromByteOffset: 0, as: UInt32.self),
                    socketCheio: p.load(fromByteOffset: 6 * 4, as: UInt32.self))
        }
    }
}
