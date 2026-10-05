import Darwin
import Foundation

/// Escritor NDJSON append-only. Uma linha por evento, nada bufferizado além do que o FileHandle
/// segura, e `sync` no fim. O join entre emissor e receptor é feito depois, por fora, por
/// `juntar.py` — assim o dado bruto sobrevive à minha aritmética e pode ser reconferido.
public final class Registro {
    private let handle: FileHandle
    private let fila = DispatchQueue(label: "br.com.queven.quall.vidro.registro")
    public let caminho: String

    public init(caminho: String) throws {
        self.caminho = caminho
        FileManager.default.createFile(atPath: caminho, contents: nil)
        guard let h = FileHandle(forWritingAtPath: caminho) else {
            throw NSError(
                domain: "vidro", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "não consegui abrir \(caminho) para escrita"])
        }
        handle = h
    }

    public func linha(_ objeto: [String: Any]) {
        fila.async { [handle] in
            guard let d = try? JSONSerialization.data(withJSONObject: objeto, options: [.sortedKeys]) else { return }
            handle.write(d)
            handle.write(Data([0x0A]))
        }
    }

    public func fechar() {
        fila.sync {}
        try? handle.synchronize()
        try? handle.close()
    }
}

/// Carga da máquina no instante da leitura. Três frentes usam este MacBook ao mesmo tempo e duas
/// compilam; carga de CPU contamina medição de latência. Registrar isso junto de cada corrida é o
/// que separa "o número" de "o número medido com o Xcode compilando ao lado".
public enum Carga {
    public static func mediaDeCarga() -> [Double] {
        var amostras = [Double](repeating: 0, count: 3)
        let n = getloadavg(&amostras, 3)
        guard n == 3 else { return [] }
        return amostras
    }

    public static func nucleos() -> Int { ProcessInfo.processInfo.processorCount }

    /// Ticks acumulados de CPU do sistema inteiro, para calcular ocupação entre dois instantes.
    public static func ticksDoSistema() -> (usados: Double, total: Double)? {
        var info = host_cpu_load_info()
        var contagem = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &contagem)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let usuario = Double(info.cpu_ticks.0)
        let sistema = Double(info.cpu_ticks.1)
        let ocioso = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let usados = usuario + sistema + nice
        return (usados, usados + ocioso)
    }

    public static func retrato() -> [String: Any] {
        var r: [String: Any] = [
            "nucleos": nucleos(),
            "load_avg": mediaDeCarga(),
        ]
        if let t = ticksDoSistema() {
            r["cpu_ticks_usados"] = t.usados
            r["cpu_ticks_total"] = t.total
        }
        return r
    }
}

/// Percentis por interpolação linear (o mesmo estimador do resto do projeto: índice inferior).
public enum Estatistica {
    public static func percentil(_ amostras: [Double], _ p: Double) -> Double {
        guard !amostras.isEmpty else { return .nan }
        let ordenadas = amostras.sorted()
        if ordenadas.count == 1 { return ordenadas[0] }
        let pos = p / 100.0 * Double(ordenadas.count - 1)
        let baixo = Int(pos.rounded(.down))
        let alto = min(ordenadas.count - 1, baixo + 1)
        let f = pos - Double(baixo)
        return ordenadas[baixo] * (1 - f) + ordenadas[alto] * f
    }
}
