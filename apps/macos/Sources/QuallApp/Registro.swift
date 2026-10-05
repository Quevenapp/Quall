import Foundation

/// Saída em arquivo — a única testemunha que um app aberto pelo LaunchServices tem.
///
/// `docs/regras-de-frente.md` fixa a regra e o motivo: quem pede permissão é o **processo
/// responsável**, e um binário lançado por `exec` de shell herda o responsável errado. O jeito
/// certo de abrir este app é `open -n -W -a Quall.app --args …`. Só que **sob `open` não há
/// terminal herdado** — `print` iria para lugar nenhum. Sem um arquivo, uma corrida de bancada
/// não deixa rastro nenhum e "não afirmo nada" passa a ser a única resposta possível.
///
/// O que **não** entra aqui: nada que venha dos pixels. O registro conta quadros, bytes, status e
/// o que o SPS declara — nunca conteúdo. Um `.h264` não carrega no nome o que tem dentro, e um
/// log não deve carregar o que a tela tinha.
final class Registro: @unchecked Sendable {
    static let compartilhado = Registro()

    private let trava = NSLock()
    private var arquivo: FileHandle?
    private let formatador: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    /// `caminho` nulo usa `~/Library/Logs/Quall/quall-app.log`.
    func abrir(caminho: String?) {
        let url: URL
        if let caminho {
            url = URL(fileURLWithPath: caminho)
        } else {
            let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
            let pasta = base.appendingPathComponent("Logs/Quall", isDirectory: true)
            try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            url = pasta.appendingPathComponent("quall-app.log")
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        trava.lock()
        arquivo = try? FileHandle(forWritingTo: url)
        // Sempre no fim: uma corrida de bancada que sobrescrevesse o registro da anterior
        // apagaria a única evidência que a rodada passada deixou.
        _ = try? arquivo?.seekToEnd()
        trava.unlock()
    }

    func linha(_ texto: String) {
        let seguro = SanitizacaoDoLog.mensagem(texto)
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        trava.lock()
        let carimbada = "\(formatador.string(from: Date()))  \(seguro)\n"
        arquivo?.write(carimbada.data(using: .utf8) ?? Data())
        trava.unlock()
        // Também no stderr: quando alguém roda o binário direto (fora do `.app`), ver o que ele
        // faz sem ir atrás do arquivo é conveniência barata. Não substitui o arquivo.
        FileHandle.standardError.write(carimbada.data(using: .utf8) ?? Data())
    }

    func fechar() {
        trava.lock()
        try? arquivo?.close()
        arquivo = nil
        trava.unlock()
    }
}
