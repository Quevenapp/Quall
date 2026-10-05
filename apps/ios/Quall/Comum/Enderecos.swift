// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import Foundation

/// Os endereços deste aparelho, **classificados** por quem os alcança.
///
/// **Não é diagnóstico: é o fallback obrigatório do fluxo.** Nenhum dos perfis de provisionamento
/// deste projeto tem `com.apple.developer.networking.multicast`: o anúncio usa `NetService`
/// pelo daemon do sistema (`AnuncianteBonjour`), e o receptor iOS entra **por IP digitado**.
/// O endereço continua sendo o caminho que salva em
/// rede com multicast bloqueado ou isolamento de AP, e o fluxo o exige em destaque na tela de
/// espera.
///
/// ## O critério é a faixa do endereço, não o nome da interface — e isso mudou em 26/08/2026
///
/// A versão anterior escolhia por **nome**: `en0` primeiro, "e se não houver `en0` de pé, qualquer
/// outro serve melhor que nada". Isso funcionava por coincidência — no iPhone o `en0` é sempre o
/// Wi-Fi —, e o "qualquer outro" era uma bomba armada.
///
/// Dois aparelhos mostraram a bomba no mesmo dia, e um deles não era iOS:
///
/// * **Galaxy S24 Ultra**: com dados móveis numa operadora IPv6-only, o Android sobe o 464XLAT e a
///   `rmnet_data0` ganha um IPv4 em `192.0.0.2/27` — faixa de *IETF Protocol Assignments*, endereço
///   de tradução local ao aparelho. A enumeração o trouxe antes da `wlan0` e a tela de espera
///   passou a anunciar `192.0.0.2:7923`. O receptor digitou o que estava escrito e levou
///   `connection timed out`.
/// * **iPhone 15**: `ip=pdp_ip0=100.64.20.2 en0=192.168.56.152` — o primeiro é **CGNAT**
///   (`100.64.0.0/10`), da rede móvel. Aqui a tela acertou, porque `en0` existia e o nome ganhou.
///   Com o Wi-Fi caído, o fallback teria entregue o CGNAT.
///
/// Nenhuma das duas faixas é alcançável por um par da LAN, e **nenhuma das duas se reconhece pelo
/// nome da interface** — se reconhecem pelo endereço. Por isso o descarte é por faixa, e o nome
/// sobrou para **ordenar** (Wi-Fi na frente) e para a heurística do cabo (ver `classificar`).
///
/// O que **não** se descarta: endereço público. Há LAN com endereço público de verdade, e recusá-lo
/// seria trocar um defeito raro por outro.
///
/// ## `169.254/16` deixou de ser descarte e virou classe — 01/09/2026
///
/// Aquela decisão pôs `169.254.0.0/16` na mesma lista das outras duas, e **o comentário que a
/// justificava estava certo sobre o que mediu e errado por generalização**: APIPA não é
/// inalcançável, é inalcançável *pela LAN*. Um par no **mesmo enlace físico** a alcança, e isso
/// deixou de ser argumento em 01/09/2026:
///
/// * `docs/bancada.md` — iPad A16 em **Modo Avião**, USB-Ethernet, `169.254.75.173 ↔
///   169.254.20.3`: **720 de 720 quadros, 0 de 7003 pacotes perdidos, 0,000 %**;
/// * e o estúdio, no mesmo dia: **três** iOS emitindo câmera pelo cabo para o MacBook, **1497 /
///   1497 / 1496 quadros, 0,000 % nas três**, em 19 255 pacotes.
///
/// O custo do descarte era um defeito de produto que o usuário achou usando o app, não lendo
/// código: com só o cabo plugado, `principal()` devolvia `nil`, o botão de emitir ficava
/// desabilitado e a tela escrevia *"sem rede Wi‑Fi"* — de pé sobre o enlace que acabara de
/// entregar 19 255 pacotes sem perder um. `docs/regras-de-frente.md`: instrumento que erra em
/// silêncio custa mais que defeito.
///
/// A mudança é de **classificar em vez de descartar**. `principal()` continua devolvendo só `.lan`
/// — quem tem Wi-Fi não vê diferença nenhuma —, e o cabo entrou por uma porta nova,
/// `principalDoCabo()`.
public enum Enderecos {
    /// Por onde um par alcança este aparelho neste endereço.
    ///
    /// As duas classes não são intercambiáveis: um endereço `.lan` serve para qualquer par da
    /// mesma rede, e um `.cabo` **só** serve para quem está na outra ponta do fio.
    public enum Enlace: String, Equatable {
        /// Rede com roteador: o Wi-Fi (`en0` no iPhone), ou Ethernet com DHCP.
        case lan
        /// Link-local (`169.254.0.0/16`, APIPA) numa interface que não é o Wi-Fi — o cabo.
        case cabo
    }

    /// A classe de um endereço IPv4 deste aparelho, ou `nil` quando **ninguém** o alcança.
    ///
    /// Descartadas, e continuam descartadas, porque de fato não são alcançáveis por par nenhum:
    ///
    /// - `192.0.0.0/24` — *IETF Protocol Assignments*; é onde mora o `192.0.0.2` do clat (464XLAT).
    /// - `100.64.0.0/10` — CGNAT da operadora; é o `pdp_ip0` de um iPhone com dados móveis.
    ///
    /// ## A heurística do cabo, e ela é palpite
    ///
    /// `169.254.0.0/16` tem **duas** origens, e o endereço não as distingue — são o mesmo valor:
    ///
    ///   1. **o cabo**: USB-Ethernet, os dois lados sem DHCP, e o par do outro lado do fio alcança;
    ///   2. **Wi-Fi sem DHCP**: o `en0` associou ao AP e o servidor de DHCP não respondeu. O
    ///      aparelho se autoconfigurou e, na prática, não fala com ninguém.
    ///
    /// O que os separa é a **interface**, e o critério aqui é `en0` — no iPhone e no iPad o Wi-Fi é
    /// sempre `en0`. **É palpite, não medida.** O que o palpite erra, e para que lado:
    ///
    /// * **Erra escondendo, nunca inventando.** Um `169.254` em `en0` é descartado, então dois
    ///   aparelhos no mesmo AP sem DHCP — que *poderiam* se alcançar — continuam sem endereço na
    ///   tela, exatamente como hoje. É o lado seguro de propósito: o defeito que esta mudança
    ///   conserta é uma tela que **mente**, e classificar o Wi-Fi quebrado como cabo escreveria
    ///   "pelo cabo" com nenhum cabo plugado — o mesmo defeito virado do avesso.
    /// * **E o nome da interface do cabo no lado iOS nunca foi lido.** As corridas de 01/09 nomeiam
    ///   `en8`, `en10` e `en12`, que são as interfaces do **MacBook**; do lado do iPhone só se
    ///   registrou o endereço. Se um dia o cabo aparecer como `en0` num aparelho, este critério o
    ///   descarta e o defeito volta inteiro. A testemunha é barata e já está ligada: a linha
    ///   `APP aberto … ip=en0=192.168.56.141:lan en2=169.254.20.2:cabo` do `Diagnostico` imprime
    ///   interface e classe de cada endereço, e a primeira corrida de bancada com cabo responde.
    public static func classificar(ip: String, interface: String) -> Enlace? {
        if ip.contains(":") {
            // Interfaces físicas Apple usam `en*`. Não oferecer endereço de celular, VPN ou
            // túnel CoreDevice como fallback de LAN; a enumeração também confere as bandeiras.
            guard interface.hasPrefix("en"), let bytes = bytesIPv6(ip),
                  bytes.contains(where: { $0 != 0 }), bytes[0] != 0xff,
                  !(bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1) else { return nil }
            return .lan
        }
        let partes = ip.split(separator: ".").compactMap { UInt8($0) }
        guard partes.count == 4 else { return nil }
        if partes[0] == 192 && partes[1] == 0 && partes[2] == 0 { return nil }
        if partes[0] == 100 && partes[1] >= 64 && partes[1] <= 127 { return nil }
        if partes[0] == 169 && partes[1] == 254 {
            return interface == "en0" ? nil : .cabo
        }
        return .lan
    }

    /// `[("en0", "192.168.56.42", .lan), ("en2", "169.254.20.2", .cabo)]`, sem loopback, sem
    /// interface caída e sem endereço que ninguém alcança. O Wi-Fi vem primeiro; o resto continua
    /// listado, porque em rede onde o `en0` não é o caminho a lista é o que salva.
    public static func ipv4() -> [(interface: String, ip: String, enlace: Enlace)] {
        enumerar(familia: AF_INET)
    }

    /// IPv6 das interfaces físicas. Conserva a zona link-local para diagnóstico; o endereço
    /// principal abaixo usa ULA/global, pois a zona deste aparelho não é a zona de quem disca.
    public static func ipv6() -> [(interface: String, ip: String, enlace: Enlace)] {
        enumerar(familia: AF_INET6)
    }

    private static func enumerar(familia: Int32) -> [(interface: String, ip: String, enlace: Enlace)] {
        var achados: [(interface: String, ip: String, enlace: Enlace)] = []
        var primeiro: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&primeiro) == 0, let inicio = primeiro else { return achados }
        defer { freeifaddrs(inicio) }

        var atual: UnsafeMutablePointer<ifaddrs>? = inicio
        while let ponteiro = atual {
            let interface = ponteiro.pointee
            atual = interface.ifa_next

            guard let endereco = interface.ifa_addr,
                  endereco.pointee.sa_family == UInt8(familia) else { continue }
            guard (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            guard (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            if familia == AF_INET6 {
                guard (interface.ifa_flags & UInt32(IFF_BROADCAST)) != 0,
                      (interface.ifa_flags & UInt32(IFF_POINTOPOINT)) == 0 else { continue }
            }

            var texto = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let situacao = getnameinfo(endereco, socklen_t(endereco.pointee.sa_len),
                                      &texto, socklen_t(texto.count),
                                      nil, 0, NI_NUMERICHOST)
            guard situacao == 0 else { continue }
            let ip = String(cString: texto)
            let nome = String(cString: interface.ifa_name)
            guard let enlace = classificar(ip: ip, interface: nome) else { continue }
            achados.append((nome, ip, enlace))
        }
        // Wi-Fi na frente. É ordenação estável: quem não é `en0` mantém a ordem em que o sistema
        // enumerou, que é a única informação que temos sobre o resto.
        return achados.sorted { a, _ in a.interface == "en0" }
    }

    /// O endereço de **LAN** a mostrar em destaque na tela de espera. Não devolve cabo.
    ///
    /// `en0` primeiro porque é o Wi-Fi, que é por onde a LAN passa neste produto. **O "qualquer
    /// outro" do fallback é seguro**, porque `classificar` já tirou da lista o que ninguém alcança
    /// — antes ele podia devolver o CGNAT da rede móvel ou o endereço do clat.
    ///
    /// **A resposta desta função não mudou em 01/09/2026**, e não mudar era o objetivo: o conjunto
    /// que ela vê (`.lan`) é exatamente o que `ipv4()` devolvia antes de a classe existir. Quem tem
    /// Wi-Fi vê a mesma tela de antes; o cabo entra por `principalDoCabo()`, ao lado, e nunca no
    /// lugar. A ausência total continua sendo informação — mas quem chama já não pode traduzi-la
    /// por "ligue o Wi-Fi" sem antes perguntar pelo cabo.
    public static func principal() -> String? {
        escolher(ipv4() + ipv6().filter { !ehIPv6LinkLocal($0.ip) }, enlace: .lan)
    }

    /// O endereço do **cabo**, quando há um. `nil` sem cabo — e `nil` não quer dizer "sem rede".
    ///
    /// Só serve para quem está na outra ponta do fio, e é por isso que ele não entra em
    /// `principal()`: anunciar `169.254.x.y` para um par de Wi-Fi seria o defeito de 26/08 de
    /// novo, com outro endereço.
    ///
    /// Não há ordenação a inventar entre dois cabos: um aparelho iOS tem uma porta. Se houver mais
    /// de um endereço `.cabo`, ganha o primeiro que o sistema enumerou.
    public static func principalDoCabo() -> String? { escolher(ipv4(), enlace: .cabo) }

    /// A escolha, **separada da enumeração**: um endereço de uma classe, dada uma lista.
    ///
    /// Está fora de `principal()` para poder ser exercitada sem depender das interfaces desta
    /// máquina — `getifaddrs` devolve o que o MacBook tiver plugado no momento, e um teste que
    /// dependa disso não é teste. Ver `Testes/main.swift`.
    ///
    /// `en0` na frente é redundante com a ordenação de `ipv4()`, e fica aqui de propósito: assim a
    /// função está certa sozinha, para qualquer lista. Na classe `.cabo` ela nunca dispara, porque
    /// `classificar` não deixa `en0` virar cabo.
    public static func escolher(_ achados: [(interface: String, ip: String, enlace: Enlace)],
                                enlace: Enlace) -> String? {
        let todos = achados.filter { $0.enlace == enlace }
        let ipv4 = todos.filter { !$0.ip.contains(":") }
        let candidatos = ipv4.isEmpty ? todos : ipv4 // mantém toda prioridade IPv4 existente
        if let wifi = candidatos.first(where: { $0.interface == "en0" }) { return wifi.ip }
        return candidatos.first?.ip
    }

    // ----------------------------------------------------------------------------------------
    // O que a tela mostra. Puro, e num lugar só, porque são **duas** telas com **dois** emissores
    // e a decisão tem de ser a mesma nas quatro combinações.
    // ----------------------------------------------------------------------------------------

    /// O endereço que vai no lugar de destaque (o QR que o repetia saiu em 24/09/2026).
    ///
    /// **Quando há os dois, ganha a LAN.** É a mesma razão de `principal()` não ter mudado: o
    /// caminho de Wi-Fi está provado, quem o usa não pode ver a tela mudar debaixo de si, e quem
    /// digita o endereço é um terceiro aparelho que quase nunca é o que está no fio. O cabo não
    /// some nesse caso — vira a segunda linha (`notaDoEnlace`), que é onde uma instalação de
    /// estúdio vai buscá-lo. E ele **é** o destaque quando não há LAN, que é o caso que o produto
    /// não atendia.
    ///
    /// `nil` só quando não há nem um nem outro. Aí não há rede, e a frase da tela pode dizer isso
    /// sem citar Wi-Fi — porque cabo também é rede. É esse `nil`, e só ele, que desabilita o botão
    /// de emitir.
    ///
    /// Não devolve "qual dos dois é": quem rotula é `notaDoEnlace`, que já escreve a linha
    /// debaixo do destaque nos dois casos em que há cabo. Uma bandeira a mais aqui seria um
    /// segundo lugar para a mesma verdade, e o jeito de as duas discordarem.
    public static func destaque(lan: String?, cabo: String?, porta: UInt16) -> String? {
        if let lan { return comPorta(lan, porta: porta) }
        if let cabo { return comPorta(cabo, porta: porta) }
        return nil
    }

    public static func comPorta(_ ip: String, porta: UInt16) -> String {
        ip.contains(":") && !ip.hasPrefix("[") ? "[\(ip)]:\(porta)" : "\(ip):\(porta)"
    }

    private static func bytesIPv6(_ ip: String) -> [UInt8]? {
        let partes = ip.split(separator: "%", omittingEmptySubsequences: false)
        guard partes.count <= 2, !partes.contains(where: { $0.isEmpty }) else { return nil }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, String(partes[0]), &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    public static func ehIPv6LinkLocal(_ ip: String) -> Bool {
        guard let bytes = bytesIPv6(ip) else { return false }
        return bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
    }

    /// Rede local pode usar endereço global. A faixa sozinha não decide: comparar o destino
    /// com endereço/máscara de uma interface física ativa, sem conectar nem pedir permissão.
    public static func ipv6EhDaRedeLocal(_ ip: String) -> Bool {
        guard let bytes = bytesIPv6(ip) else { return false }
        if ehIPv6LinkLocal(ip) || (bytes[0] & 0xfe) == 0xfc { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        var primeiro: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&primeiro) == 0, let inicio = primeiro else { return false }
        defer { freeifaddrs(inicio) }
        var atual: UnsafeMutablePointer<ifaddrs>? = inicio
        while let ponteiro = atual {
            let interface = ponteiro.pointee
            atual = interface.ifa_next
            guard (interface.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST)) == UInt32(IFF_UP | IFF_BROADCAST),
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)) == 0,
                  String(cString: interface.ifa_name).hasPrefix("en"),
                  let endereco = interface.ifa_addr, let mascara = interface.ifa_netmask,
                  endereco.pointee.sa_family == UInt8(AF_INET6),
                  mascara.pointee.sa_family == UInt8(AF_INET6) else { continue }
            func texto(_ sa: UnsafePointer<sockaddr>) -> String? {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count),
                                  nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: buffer)
            }
            if let local = texto(endereco), let mask = texto(mascara),
               mesmoPrefixoIPv6(ip, local: local, mascara: mask) { return true }
        }
        return false
    }

    public static func mesmoPrefixoIPv6(_ ip: String, local: String, mascara: String) -> Bool {
        guard let a = bytesIPv6(ip), let b = bytesIPv6(local), let mask = bytesIPv6(mascara),
              mask.contains(where: { $0 != 0 }) else { return false }
        return (0..<16).allSatisfy { (a[$0] & mask[$0]) == (b[$0] & mask[$0]) }
    }

    /// A linha pequena debaixo do destaque, ou `nil` quando não há nada verdadeiro a acrescentar.
    ///
    /// Três casos, e o `nil` é um deles de propósito: **sem cabo, a tela não fala de cabo.**
    public static func notaDoEnlace(lan: String?, cabo: String?, porta: UInt16) -> String? {
        guard let cabo else { return nil }
        if lan == nil {
            return tr("pelo cabo (USB) — este aparelho está sem Wi‑Fi")
        }
        return tr("e, pelo cabo (USB): %@:%ld", cabo, Int(porta))
    }
}
