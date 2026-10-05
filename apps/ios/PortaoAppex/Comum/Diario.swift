import Foundation
import os

/// Ponte de observação entre a extension e o mundo de fora.
///
/// A extension é um processo que só se observa de fora: o `ios-deploy` lança um `.app`, e a appex
/// é criada pelo sistema a partir do seletor de transmissão. São dois caminhos, de propósito,
/// porque falham por motivos diferentes:
///
/// 1. **`os_log`** — sai do aparelho por `idevicesyslog`/`log`, em tempo real, sem passar pelo app.
///    É o caminho da aposta registrada em `docs/arquitetura-ios.md`.
/// 2. **Arquivo no App Group** — a extension escreve, o app hospedeiro copia para o próprio
///    `Documents`, e o `ios-deploy --download` traz. Mais lento e indireto, mas sobrevive a
///    qualquer filtro ou perda do `os_log`, e prova de quebra que o App Group está mesmo ligado.
public enum Diario {
    public static let grupo = "group.br.com.queven.quall"
    public static let subsistema = "br.com.queven.quall"

    public static let registro = Logger(subsystem: subsistema, category: "difusao")

    public static var pastaDoGrupo: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: grupo)
    }

    public static var arquivo: URL? {
        pastaDoGrupo?.appendingPathComponent("difusao.log")
    }

    /// Bandeira de "a transmissão começou", posta pela extension e lida pelo app.
    ///
    /// Existe porque o app precisa saber a hora exata em que a pessoa tocou em "Iniciar
    /// Transmissão" — e não tem como saber de outro jeito: a folha é desenhada pelo `replayd`,
    /// fora do nosso processo, e o delegado do `RPBroadcastActivityViewController` nunca é
    /// chamado. Um prazo fixo depois da abertura da folha seria um palpite sobre o tempo de
    /// reação de uma pessoa, e erraria justamente quando ela demorasse.
    public static var marcaDeTransmissao: URL? {
        pastaDoGrupo?.appendingPathComponent("transmitindo")
    }

    public static func marcarTransmissao(_ ligada: Bool) {
        guard let marca = marcaDeTransmissao else { return }
        if ligada {
            try? Data("1".utf8).write(to: marca, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: marca)
        }
    }

    public static var transmitindo: Bool {
        guard let marca = marcaDeTransmissao else { return false }
        return FileManager.default.fileExists(atPath: marca.path)
    }

    private static let trava = NSLock()

    /// Escreve nos dois caminhos de uma vez. `os_log` primeiro, porque é o que sobrevive se o
    /// App Group não estiver provisionado — e nesse caso o silêncio no arquivo é o próprio achado.
    public static func anotar(_ linha: String) {
        registro.notice("\(linha, privacy: .public)")

        guard let arquivo else { return }
        let carimbo = String(format: "%.6f", Date().timeIntervalSince1970)
        let bytes = Data("\(carimbo) \(linha)\n".utf8)

        trava.lock()
        defer { trava.unlock() }
        if let punho = try? FileHandle(forWritingTo: arquivo) {
            defer { try? punho.close() }
            _ = try? punho.seekToEnd()
            try? punho.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: arquivo, options: .atomic)
        }
    }

    public static func zerar() {
        guard let arquivo else { return }
        try? FileManager.default.removeItem(at: arquivo)
    }

    public static func ler() -> String {
        guard let arquivo, let dados = try? Data(contentsOf: arquivo) else { return "" }
        return String(decoding: dados, as: UTF8.self)
    }

    /// Memória que ainda resta ao processo antes do jetsam. É o número que importa dentro da
    /// extension, e não o tamanho do binário: o limite conta página suja, e `__TEXT` é limpo.
    public static var memoriaDisponivel: Int {
        os_proc_available_memory()
    }

    public static var pegadaEmBytes: UInt64 {
        var info = task_vm_info_data_t()
        var contagem = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let situacao = withUnsafeMutablePointer(to: &info) { ponteiro in
            ponteiro.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) { reapontado in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reapontado, &contagem)
            }
        }
        return situacao == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
