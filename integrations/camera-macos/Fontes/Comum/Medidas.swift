import Darwin
import Foundation

/// Medição de memória do próprio processo.
///
/// No iOS a pergunta "qual é o teto?" tem resposta direta: `os_proc_available_memory()` devolve
/// quanto falta para o limite. **No macOS essa função não existe** — o cabeçalho do SDK a declara
/// `API_UNAVAILABLE(macos)`. Então aqui a pegada é medida por `task_vm_info` e o teto é
/// descoberto por sondagem, não perguntado.
enum Medidas {
    /// `phys_footprint`: a mesma métrica que o jetsam cobra no iOS e que o Instruments mostra.
    static func pegadaDeMemoria() -> UInt64 {
        var info = task_vm_info_data_t()
        var contagem = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let resultado = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &contagem)
            }
        }
        return resultado == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Residente, para conferir a pegada por um segundo caminho.
    static func residente() -> UInt64 {
        var info = mach_task_basic_info()
        var contagem = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let resultado = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &contagem)
            }
        }
        return resultado == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Relógio monotônico em microssegundos, o mesmo tipo de relógio do contrato de tracks.
    static func agoraUs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000
    }

    /// Sonda de teto: aloca e **toca** a memória em degraus, registrando a pegada a cada degrau.
    ///
    /// Tocar é o ponto — memória alocada e não escrita não entra em `phys_footprint`, então uma
    /// sonda que só faz `malloc` mede nada. Se houver teto, o processo morre no degrau em que ele
    /// for cruzado, e a ausência do registro seguinte é a medida. Devolve quantos megabytes
    /// chegou a segurar de fato.
    @discardableResult
    static func sondarTeto(ateMB: Int, degrauMB: Int, aoAndar: (Int, UInt64) -> Void) -> Int {
        var blocos: [UnsafeMutableRawPointer] = []
        var seguros = 0
        let bytesPorDegrau = degrauMB * 1024 * 1024
        while seguros < ateMB {
            guard let bloco = malloc(bytesPorDegrau) else { break }
            memset(bloco, 0xA5, bytesPorDegrau)
            blocos.append(bloco)
            seguros += degrauMB
            aoAndar(seguros, pegadaDeMemoria())
        }
        for bloco in blocos { free(bloco) }
        return seguros
    }
}
