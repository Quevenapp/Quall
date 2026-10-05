import Foundation
import CoreMedia

/// Conversão do relógio de apresentação para os microssegundos que o contrato pede.
///
/// Existe como função própria, e testável, por causa do defeito mais caro desta frente: a corrida
/// de 464 s do degrau 4 morreu com `EXC_BREAKPOINT` numa conta de inteiro que ninguém tinha
/// olhado, dentro de um processo que custa um toque humano para exercitar. **O defeito teria sido
/// pego por um teste de cinco linhas no MacBook, a custo zero.**
///
/// O que estava escrito antes desta função, nos dois emissores:
///
///     UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
///
/// e ele derruba o processo em três entradas que a plataforma produz de verdade:
///
/// * **`CMTime` inválido** — `CMTimeGetSeconds` devolve `NaN`, `max(0, NaN)` devolve `NaN`, e
///   `UInt64(NaN)` é *fatal error: Double value cannot be converted to UInt64 because it is
///   either infinite or NaN*. Um `CMSampleBuffer` sem PTS válido é raro, não impossível — e
///   "raro" numa transmissão de meia hora a 30 fps é 54 000 sorteios.
/// * **infinito**, pelo mesmo caminho;
/// * **valor acima de `UInt64.max`**, que também é armadilha, não zero.
///
/// A regra que fica: no caminho do quadro, conversão numérica usa `exactly:` com padrão, e
/// aritmética de instrumento usa `&+` e `&-`. Sem exceção.
enum Carimbo {
    /// Microssegundos monotônicos da captura. Devolve `0` quando o instante não é representável —
    /// que é a resposta certa: um quadro sem carimbo utilizável ainda é um quadro que precisa
    /// atravessar, e o receptor tem RTP para se orientar.
    static func microssegundos(de pts: CMTime) -> UInt64 {
        let segundos = CMTimeGetSeconds(pts)
        guard segundos.isFinite, segundos > 0 else { return 0 }
        return UInt64(exactly: (segundos * 1_000_000).rounded(.down)) ?? 0
    }
}
