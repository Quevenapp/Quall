import Foundation
import Network
import Darwin
import dnssd

/// Descoberta v3 pelo daemon Bonjour público: sem socket multicast próprio ou
/// entitlement multicast especial. O SRV aponta para um host aleatório registrado
/// por DNSServiceRegisterRecord, nunca para o nome local do sistema. A identidade
/// real continua em QuallDeviceDesc e só atravessa a sessão depois do PAKE/AEAD.
final class AnuncianteBonjour {
    private struct Pedido {
        let token: String
        let porta: UInt16
        let capacidades: String
        let papel: String?
    }
    private struct Endereco: Hashable {
        let interface: UInt32
        let tipo: UInt16
        let dados: Data
    }
    private let fila = DispatchQueue(label: "quall.bonjour.publicacao")
    private let chaveDaFila = DispatchSpecificKey<Bool>()
    private var pedido: Pedido?
    private var conexaoDosRegistros: DNSServiceRef?
    private var servicos: [DNSServiceRef] = []
    private var enderecosPublicados: Set<Endereco> = []
    private var monitor: NWPathMonitor?

    init() { fila.setSpecific(key: chaveDaFila, value: true) }

    /// Compatibilidade da casca: nome/deviceId continuam sendo a identidade
    /// autenticada da sessão. Eles não são usados nos registros públicos.
    /// True significa pedido ativo; rede/permissão podem impedir a descoberta.
    @discardableResult
    func comecar(deviceId _: String, nome _: String, porta: UInt16,
                 emiteTela: Bool, emiteCamera: Bool, exibe: Bool = false,
                 papel: String? = nil) -> Bool {
        naFila {
            guard pedido == nil, porta != 0, quall_protocol_version() == 3,
                  papel == nil || papel == "teleprompter" else { return false }
            var capacidades = ""
            if emiteTela { capacidades += "s" }
            if emiteCamera { capacidades += "c" }
            if exibe { capacidades += "k" }
            pedido = Pedido(token: NomeDaInstancia.novoToken(), porta: porta,
                            capacidades: capacidades, papel: papel)
            atualizarPublicacao()
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] _ in self?.atualizarPublicacao() }
            monitor = m
            m.start(queue: fila)
            return true
        }
    }

    /// Exatamente o alias que o parser v3 mostra na lista, sem identidade real.
    var nomePublico: String? {
        naFila { pedido.map { "Quall " + String($0.token.prefix(8)) } }
    }

    func parar() {
        naFila {
            monitor?.cancel()
            monitor = nil
            pedido = nil
            retirarRegistros()
        }
    }

    private func naFila<T>(_ operacao: () -> T) -> T {
        if DispatchQueue.getSpecific(key: chaveDaFila) == true { return operacao() }
        return fila.sync(execute: operacao)
    }

    /// Apenas interfaces locais en*: exclui loopback, túnel VPN e rede celular.
    /// A/AAAA são publicados na mesma interface do endereço; IPv6 link-local
    /// mantém seu escopo pela interface, sem colocar scope-id nos 16 bytes AAAA.
    private static func enderecosLocais() -> Set<Endereco> {
        var lista: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lista) == 0 else { return [] }
        defer { freeifaddrs(lista) }
        var cursor = lista
        var encontrados: Set<Endereco> = []
        while let atual = cursor {
            let item = atual.pointee
            defer { cursor = item.ifa_next }
            guard let nome = item.ifa_name, let sa = item.ifa_addr,
                  String(cString: nome).hasPrefix("en"),
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let indice = if_nametoindex(nome)
            guard indice != 0 else { continue }
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var ip = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                let dados = Data(bytes: &ip, count: 4)
                guard dados.first != 0, dados.first != 127 else { continue }
                encontrados.insert(Endereco(interface: indice, tipo: UInt16(kDNSServiceType_A), dados: dados))
            case AF_INET6:
                var ip = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let dados = Data(bytes: &ip, count: 16)
                guard dados.contains(where: { $0 != 0 }), dados.first != 0xff else { continue }
                encontrados.insert(Endereco(interface: indice, tipo: UInt16(kDNSServiceType_AAAA), dados: dados))
            default: continue
            }
        }
        return encontrados
    }

    private func atualizarPublicacao() {
        guard let pedido else { return }
        let atuais = Self.enderecosLocais()
        guard atuais != enderecosPublicados || servicos.isEmpty else { return }
        retirarRegistros()
        guard !atuais.isEmpty,
              let instancia = NomeDaInstancia.montar(token: pedido.token),
              let host = NomeDaInstancia.host(token: pedido.token) else { return }
        let contexto = Unmanaged.passUnretained(self).toOpaque()
        var conexao: DNSServiceRef?
        guard DNSServiceCreateConnection(&conexao) == kDNSServiceErr_NoError, let conexao else { return }
        conexaoDosRegistros = conexao
        for endereco in atuais {
            var registro: DNSRecordRef?
            let erro = endereco.dados.withUnsafeBytes { bytes in
                DNSServiceRegisterRecord(conexao, &registro, DNSServiceFlags(kDNSServiceFlagsShared),
                    endereco.interface, host, endereco.tipo, UInt16(kDNSServiceClass_IN),
                    UInt16(bytes.count), bytes.baseAddress, 60,
                    { _, _, _, erro, contexto in
                        guard erro != kDNSServiceErr_NoError, let contexto else { return }
                        Unmanaged<AnuncianteBonjour>.fromOpaque(contexto).takeUnretainedValue().retirarRegistros()
                    }, contexto)
            }
            guard erro == kDNSServiceErr_NoError else { retirarRegistros(); return }
        }
        guard DNSServiceSetDispatchQueue(conexao, fila) == kDNSServiceErr_NoError else {
            retirarRegistros(); return
        }
        var txt = ["v": Data("3".utf8), "t": Data(pedido.token.utf8),
                   "p": Data(String(pedido.porta).utf8), "c": Data(pedido.capacidades.utf8)]
        if let papel = pedido.papel { txt["pa"] = Data(papel.utf8) }
        let dadosTXT = NetService.data(fromTXTRecord: txt)
        for indice in Set(atuais.map(\.interface)) {
            var servico: DNSServiceRef?
            let erro = dadosTXT.withUnsafeBytes { bytes in
                DNSServiceRegister(&servico, 0, indice, instancia, "_quall._tcp", "local.", host,
                    pedido.porta.bigEndian, UInt16(bytes.count), bytes.baseAddress,
                    { _, _, erro, _, _, _, contexto in
                        guard erro != kDNSServiceErr_NoError, let contexto else { return }
                        Unmanaged<AnuncianteBonjour>.fromOpaque(contexto).takeUnretainedValue().retirarRegistros()
                    }, contexto)
            }
            guard erro == kDNSServiceErr_NoError, let servico else { retirarRegistros(); return }
            servicos.append(servico)
            guard DNSServiceSetDispatchQueue(servico, fila) == kDNSServiceErr_NoError else {
                retirarRegistros(); return
            }
        }
        enderecosPublicados = atuais
    }

    /// Executado na mesma fila dos callbacks: sem deallocation concorrente.
    /// Deallocate da conexão remove também todos os DNSRecordRef A/AAAA dela.
    private func retirarRegistros() {
        for servico in servicos { DNSServiceRefDeallocate(servico) }
        servicos.removeAll()
        if let conexaoDosRegistros { DNSServiceRefDeallocate(conexaoDosRegistros) }
        conexaoDosRegistros = nil
        enderecosPublicados.removeAll()
    }

    deinit { parar() }
}
