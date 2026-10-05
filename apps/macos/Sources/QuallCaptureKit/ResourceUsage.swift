import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Snapshot de uso de CPU do processo via `getrusage(2)`. É a métrica primária de CPU deste
/// binário: como o encode de vídeo em hardware roda no bloco de mídia (Video Encoder Engine), não
/// no CPU, um `getrusage` baixo durante captura sustentada é evidência de que o encode está
/// mesmo saindo do CPU — o que é justamente o que precisa ser verificado, não só assumido.
struct ResourceUsage {
    let userSeconds: Double
    let systemSeconds: Double

    static func current() -> ResourceUsage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return ResourceUsage(userSeconds: user, systemSeconds: system)
    }
}
