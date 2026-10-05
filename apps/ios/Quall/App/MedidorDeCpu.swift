import Darwin
import Foundation

/// **Quanto de CPU cada etapa gasta** (§8.12.16): a medida que decide o próximo degrau quando o iPhone 7
/// quente, só transmitindo, ainda não entrega o som da rede em dia.
///
/// - **Por etapa**: cada trecho medido soma o tempo de CPU **da própria thread** (`CLOCK_THREAD_CPUTIME_ID`)
///   num balde com nome (a entrega do vídeo, a do som, a saída do encoder da rede, o Opus, o escritor da
///   gravação). Custa duas leituras de relógio por trecho.
/// - **A principal**: o tempo de CPU dela, lido de fora por `thread_info` (a porta é guardada da
///   principal uma vez).
/// - **O processo**: `getrusage(RUSAGE_SELF)`.
///
/// Fica de fora o que roda em outros processos (a câmera e o VideoToolbox no `mediaserverd`, o servidor de
/// renderização): o total do processo é só o nosso. O relato é em "% de um núcleo" na janela.
enum MedidorDeCpu {
    private static let trava = NSLock()
    private static var baldes: [String: UInt64] = [:]
    private static var principal: thread_act_t = 0
    private static var antes: (processo: UInt64, principal: UInt64, quando: UInt64)?

    /// O tempo de CPU desta thread, em ns.
    @inline(__always) static func agora() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// Soma ao balde `nome` o CPU desta thread desde `desde` (um `agora()`).
    @inline(__always) static func somar(_ nome: String, desde: UInt64) {
        let d = agora() &- desde
        trava.lock(); baldes[nome, default: 0] &+= d; trava.unlock()
    }

    /// Da principal, uma vez: guarda a porta dela para a leitura de fora.
    /// A porta de `mach_thread_self` fica com uma referência que nunca é devolvida: uma só por processo.
    static func marcarPrincipal() {
        guard Thread.isMainThread else { return }
        trava.lock(); if principal == 0 { principal = mach_thread_self() }; trava.unlock()
    }

    private static func cpuDoProcesso() -> UInt64 {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return 0 }
        func ns(_ t: timeval) -> UInt64 { UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_usec) * 1000 }
        return ns(u.ru_utime) + ns(u.ru_stime)
    }

    private static func cpuDaPrincipal() -> UInt64 {
        trava.lock(); let principal = self.principal; trava.unlock()
        guard principal != 0 else { return 0 }
        var info = thread_basic_info()
        var n = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                thread_info(principal, thread_flavor_t(THREAD_BASIC_INFO), $0, &n)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        func ns(_ t: time_value_t) -> UInt64 { UInt64(t.seconds) * 1_000_000_000 + UInt64(t.microseconds) * 1000 }
        return ns(info.user_time) + ns(info.system_time)
    }

    /// A linha do relato: o CPU desde a chamada anterior, em % de um núcleo, e zera os baldes. `nil` na
    /// primeira chamada (só marca o começo).
    static func relato() -> String? {
        let agoraReal = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let p = cpuDoProcesso(), m = cpuDaPrincipal()
        trava.lock()
        let b = baldes
        baldes = [:]
        let anterior = antes
        antes = (p, m, agoraReal)
        trava.unlock()
        guard let a = anterior, agoraReal > a.quando else { return nil }
        let janela = Double(agoraReal - a.quando)
        func pct(_ ns: UInt64) -> String { String(format: "%.1f%%", Double(ns) / janela * 100) }
        let etapas = b.sorted { $0.value > $1.value }.map { "\($0.key)=\(pct($0.value))" }.joined(separator: " ")
        return "processo=\(pct(p &- a.processo))" + (m == 0 ? "" : " principal=\(pct(m &- a.principal))")
            + (etapas.isEmpty ? "" : " · " + etapas)
            + String(format: " (em %% de um núcleo, janela de %.1f s)", janela / 1e9)
    }
}
