import Darwin
import Foundation
import QuallIdiomaKit

/// Instrumento local da entrega: executado antes de criar modelos, janela ou capturadores.
/// Mede acesso real do pacote a dados, logs, Movies, recursos e UDP em loopback. Não pede TCC,
/// não abre dispositivos nem publica descoberta de rede. Cada arquivo de prova é removido.
enum ProvaDoSandbox {
    static func executar(etapa: String = "simples", id: String? = nil) -> Bool {
        guard ["simples", "escrever", "reler"].contains(etapa) else {
            FileHandle.standardError.write(Data("prova sandbox: etapa inválida\n".utf8))
            return false
        }
        var provas: [[String: Any]] = []
        func provar(_ nome: String, _ tarefa: () throws -> [String: Any]) {
            do { provas.append(try tarefa().merging(["prova": nome, "passou": true]) { _, novo in novo }) }
            catch { provas.append(["prova": nome, "passou": false, "erro": error.localizedDescription]) }
        }
        let arquivos = FileManager.default
        func escritaELeitura(_ pasta: URL) throws -> [String: Any] {
            let existia = arquivos.fileExists(atPath: pasta.path)
            try arquivos.createDirectory(at: pasta, withIntermediateDirectories: true)
            let url = pasta.appendingPathComponent(".quall-prova-\(UUID().uuidString).tmp")
            defer {
                try? arquivos.removeItem(at: url)
                if !existia, (try? arquivos.contentsOfDirectory(atPath: pasta.path).isEmpty) == true {
                    try? arquivos.removeItem(at: pasta)
                }
            }
            let esperado = Data("Quall Studio: prova local do sandbox\n".utf8)
            try esperado.write(to: url)
            guard try Data(contentsOf: url) == esperado else { throw Falha("bytes relidos diferem") }
            return ["pasta": pasta.path, "bytes": esperado.count]
        }
        provar("dadosApplicationSupport") {
            guard let base = arquivos.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw Falha("Application Support indisponível")
            }
            return try escritaELeitura(base.appendingPathComponent("Quall", isDirectory: true))
        }
        if etapa != "simples" {
            provar("persistenciaEntreAberturas") {
                guard let id, UUID(uuidString: id) != nil, ["escrever", "reler"].contains(etapa),
                      let base = arquivos.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                    throw Falha("etapa/id de persistência inválidos")
                }
                let pasta = base.appendingPathComponent("Quall", isDirectory: true)
                try arquivos.createDirectory(at: pasta, withIntermediateDirectories: true)
                let url = pasta.appendingPathComponent(".quall-prova-persistencia-\(id).json")
                if etapa == "escrever" {
                    guard !arquivos.fileExists(atPath: url.path) else { throw Falha("prova com este id já existe") }
                    let dados = try JSONSerialization.data(withJSONObject: ["id": id, "pid": getpid()])
                    try dados.write(to: url, options: .atomic)
                    return ["pasta": pasta.path, "arquivo": url.lastPathComponent, "etapa": etapa]
                }
                let dados = try Data(contentsOf: url)
                guard let anterior = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
                      anterior["id"] as? String == id,
                      let pid = (anterior["pid"] as? NSNumber)?.intValue, pid != Int(getpid()) else {
                    throw Falha("id não confere ou não houve outro processo")
                }
                try arquivos.removeItem(at: url)
                return ["pasta": pasta.path, "pidAnterior": pid, "etapa": etapa, "arquivoDeProvaRemovido": true]
            }
        }
        provar("logsLibrary") {
            guard let base = arquivos.urls(for: .libraryDirectory, in: .userDomainMask).first else {
                throw Falha("Library indisponível")
            }
            return try escritaELeitura(base.appendingPathComponent("Logs/Quall", isDirectory: true))
        }
        provar("destinoDoGravador") { try escritaELeitura(GravadorLocal.pastaPadrao(Argumentos())) }
        provar("avisos") {
            guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") else {
                throw Falha("recurso de avisos ausente")
            }
            let dados = try Data(contentsOf: url)
            guard !dados.isEmpty, String(data: dados, encoding: .utf8) != nil else {
                throw Falha("avisos vazios ou UTF-8 inválido")
            }
            return ["bytes": dados.count]
        }
        provar("traducaoEN") {
            guard T("Espelhar", em: .en) == "Mirror" else { throw Falha("tradução não carregou") }
            return [:]
        }
        provar("udpLoopback") { try udpLoopback() }
        let passou = provas.allSatisfy { ($0["passou"] as? Bool) == true }
        let relato: [String: Any] = [
            "passou": passou, "homeEfetivo": NSHomeDirectory(), "pid": getpid(), "etapa": etapa,
            "cameraAberta": false, "microfoneAberto": false, "capturaDeTela": false,
            "provas": provas,
        ]
        // LaunchServices pode redirecionar stdout; a cópia no temporário do próprio sandbox dá
        // uma segunda testemunha sem depender de acesso à pasta de bancada fora do container.
        do {
            let dados = try JSONSerialization.data(withJSONObject: relato, options: [.prettyPrinted, .sortedKeys])
            try dados.write(to: arquivos.temporaryDirectory.appendingPathComponent("quall-prova-sandbox-\(etapa).json"))
            FileHandle.standardOutput.write(dados + Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("prova sandbox: não consegui escrever o relato: \(error)\n".utf8))
            return false
        }
        return passou
    }

    private struct Falha: LocalizedError {
        let motivo: String
        init(_ motivo: String) { self.motivo = motivo }
        var errorDescription: String? { motivo }
    }

    private static func udpLoopback() throws -> [String: Any] {
        let servidor = socket(AF_INET, SOCK_DGRAM, 0)
        guard servidor >= 0 else { throw Falha("socket servidor: \(errno)") }
        defer { close(servidor) }
        var endereco = sockaddr_in()
        endereco.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endereco.sin_family = sa_family_t(AF_INET)
        endereco.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let ligado = withUnsafePointer(to: &endereco) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(servidor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ligado == 0 else { throw Falha("bind servidor: \(errno)") }
        var tamanho = socklen_t(MemoryLayout<sockaddr_in>.size)
        let lido = withUnsafeMutablePointer(to: &endereco) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(servidor, $0, &tamanho) }
        }
        guard lido == 0 else { throw Falha("getsockname: \(errno)") }
        let cliente = socket(AF_INET, SOCK_DGRAM, 0)
        guard cliente >= 0 else { throw Falha("socket cliente: \(errno)") }
        defer { close(cliente) }
        let conectado = withUnsafePointer(to: &endereco) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(cliente, $0, tamanho) }
        }
        guard conectado == 0 else { throw Falha("connect cliente: \(errno)") }
        var prazo = timeval(tv_sec: 1, tv_usec: 0)
        guard setsockopt(servidor, SOL_SOCKET, SO_RCVTIMEO, &prazo, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw Falha("timeout socket: \(errno)")
        }
        var enviado: UInt8 = 0x71
        guard send(cliente, &enviado, 1, 0) == 1 else { throw Falha("send cliente: \(errno)") }
        var recebido: UInt8 = 0
        guard recv(servidor, &recebido, 1, 0) == 1, recebido == enviado else { throw Falha("recv servidor: \(errno)") }
        return ["bytes": 1, "endereco": "127.0.0.1", "portaEfemera": UInt16(bigEndian: endereco.sin_port)]
    }
}
