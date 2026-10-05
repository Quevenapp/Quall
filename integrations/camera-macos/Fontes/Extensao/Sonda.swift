import Darwin
import Foundation

/// Sonda da extensão: responde por **medição** as três perguntas que decidem o desenho.
///
/// 1. **Tem limite de memória?** No iOS a resposta vem de `os_proc_available_memory()`, que é
///    `API_UNAVAILABLE(macos)`. Aqui a resposta vem de alocar e tocar até doer.
/// 2. **A extensão consegue rede?** Se conseguir, o desenho "extensão autônoma" — o que o iOS
///    escolheu — fica na mesa. Se não conseguir, ele cai por impossibilidade, não por gosto.
/// 3. **Ela compartilha estado com o app?** O processo roda como `_cmiodalassistants`, outro
///    usuário: o contêiner do App Group pode não ser o mesmo do app. Isso decide se `pares.json`
///    poderia ser lido dos dois lados — e a dívida 23 já diz o que dois escritores custam.
///
/// Só compila com `SONDA_MEMORIA` ligado. A sonda de memória mata a extensão de propósito se
/// houver teto, e uma câmera que morre no meio não prova nada com app de terceiro: a corrida da
/// sonda e a corrida da testemunha são **binários diferentes**.
enum Sonda {
    static func dispararSeConfigurada() {
        #if SONDA_MEMORIA
        guard !jaDisparou else { return }
        jaDisparou = true
        DispatchQueue.global(qos: .utility).async {
            ambiente()
            rede()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
            memoria()
        }
        #endif
    }

    #if SONDA_MEMORIA
    private static var jaDisparou = false

    private static func ambiente() {
        registro.info("SONDA ambiente; identidades e diretório pessoal omitidos")
        // A sonda opcional só consulta o grupo configurado pelo desenvolvedor; não embute
        // identificador de assinatura de uma instalação privada.
        let grupo = ProcessInfo.processInfo.environment["QUALL_SONDA_APP_GROUP"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "QuallSondaAppGroup") as? String)
        if let grupo, !grupo.isEmpty {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: grupo) {
                let alvo = url.appendingPathComponent("sonda-da-extensao.txt")
                var escreveu = "não"
                do {
                    try "extensão esteve aqui \(Date())".write(to: alvo, atomically: true, encoding: .utf8)
                    escreveu = "sim"
                } catch {
                    escreveu = "não (código=\((error as NSError).code); contexto omitido)"
                }
                registro.info("SONDA contêiner_do_grupo=disponível escreveu=\(escreveu, privacy: .public)")
            } else {
                registro.info("SONDA contêiner_do_grupo=INDISPONÍVEL")
            }
        } else {
            registro.info("SONDA contêiner_do_grupo=NÃO_CONFIGURADO")
        }
        registro.info("SONDA temporário; caminho omitido")
    }

    /// Duas perguntas separadas, porque falham separadamente: **sair** (cliente) e **ouvir**
    /// (servidor). Uma sessão do Quall precisa das duas — TCP de sinalização de saída, e UDP do
    /// ICE ligado a uma porta local que recebe.
    private static func rede() {
        // Cliente: um `connect` para o descarte no laço local. Não manda byte nenhum para
        // ninguém, e distingue "o sandbox recusou" (EPERM) de "ninguém escuta" (ECONNREFUSED).
        let tcp = socket(AF_INET, SOCK_STREAM, 0)
        if tcp < 0 {
            registro.info("SONDA rede_cliente: socket() falhou errno=\(errno, privacy: .public)")
        } else {
            var destino = sockaddr_in()
            destino.sin_family = sa_family_t(AF_INET)
            destino.sin_port = UInt16(9).bigEndian
            destino.sin_addr.s_addr = inet_addr("127.0.0.1")
            let r = withUnsafePointer(to: &destino) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(tcp, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            registro.info("SONDA rede_cliente: connect=\(r, privacy: .public) errno=\(errno, privacy: .public)")
            close(tcp)
        }

        // Servidor: ligar um UDP a uma porta efêmera e entrar no grupo do mDNS. É o que a
        // descoberta e o ICE fazem.
        let udp = socket(AF_INET, SOCK_DGRAM, 0)
        if udp < 0 {
            registro.info("SONDA rede_servidor: socket() falhou errno=\(errno, privacy: .public)")
            return
        }
        var endereco = sockaddr_in()
        endereco.sin_family = sa_family_t(AF_INET)
        endereco.sin_port = 0
        endereco.sin_addr.s_addr = INADDR_ANY
        let ligou = withUnsafePointer(to: &endereco) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(udp, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        registro.info("SONDA rede_servidor: bind=\(ligou, privacy: .public) errno=\(errno, privacy: .public)")

        var pedido = ip_mreq()
        pedido.imr_multiaddr.s_addr = inet_addr("224.0.0.251")
        pedido.imr_interface.s_addr = INADDR_ANY
        let entrou = setsockopt(udp, IPPROTO_IP, IP_ADD_MEMBERSHIP, &pedido, socklen_t(MemoryLayout<ip_mreq>.size))
        registro.info("SONDA rede_multicast: IP_ADD_MEMBERSHIP=\(entrou, privacy: .public) errno=\(errno, privacy: .public)")
        close(udp)
    }

    private static func memoria() {
        registro.info("SONDA memória começando; pegada=\(Medidas.pegadaDeMemoria(), privacy: .public) residente=\(Medidas.residente(), privacy: .public)")
        let chegou = Medidas.sondarTeto(ateMB: 1024, degrauMB: 32) { mb, pegada in
            registro.info("SONDA memória degrau_mb=\(mb, privacy: .public) pegada=\(pegada, privacy: .public)")
        }
        registro.info("SONDA memória terminou vivo em \(chegou, privacy: .public) MB; pegada=\(Medidas.pegadaDeMemoria(), privacy: .public)")
    }
    #endif
}
