import Foundation

/// **O tom de quatro notas da bancada**: 400, 500, 800 e 1000 Hz, 25 quadros de 20 ms (0,5 s) cada,
/// amplitude 0,5 — os números de `crates/quall-probe/src/audio.rs:47-59`, do
/// `apps/ios/Quall/Receber/TomSintetico.swift` e do Android. É a **assinatura** que o receptor
/// confere na prova do microfone do Mac (R5 fase 4, G5 de `docs/teleprompter-com-camera.md` §8): um
/// som de fora que entrasse no dispositivo virtual não teria estas notas nesta ordem.
///
/// A fase sai do índice **absoluto** da amostra: a onda é contínua de um quadro para o outro, e cada
/// nota tem um número inteiro de ciclos em 20 ms a 8 kHz e a 48 kHz (sem estalo na emenda).
///
/// Diferente do `TomSintetico` deste kit, que é um **tocador** de um tom só na saída padrão (a prova
/// do som de sistema): este é o **gerador** das notas, puro, e quem toca é o
/// `GeradorNoDispositivo` (na saída do dispositivo virtual) ou a fonte sintética do dono.
public enum TomDeQuatroNotas {
    public static let notasHz: [Double] = [400, 500, 800, 1000]
    public static let quadrosPorNota = 25
    public static let amplitude = 0.5
    /// A duração do quadro que dá o compasso das notas, em amostras a 48 kHz.
    public static let amostrasPorQuadro48k = 960

    /// Um quadro de `amostrasPorCanal` amostras, deterministicamente a partir do índice.
    public static func quadro(indice: Int, amostrasPorCanal: Int, taxaHz: Double, canais: Int = 1) -> [Int16] {
        let nota = notasHz[(indice / quadrosPorNota) % notasHz.count]
        let amostrasPorCiclo = taxaHz / nota
        let base = indice * amostrasPorCanal
        var saida = [Int16](repeating: 0, count: amostrasPorCanal * canais)
        for i in 0..<amostrasPorCanal {
            let fase = 2.0 * Double.pi * Double(base + i) / amostrasPorCiclo
            let v = Int16(sin(fase) * amplitude * Double(Int16.max))
            for c in 0..<canais { saida[i * canais + c] = v }
        }
        return saida
    }

    /// A amostra de número absoluto `n` a 48 kHz (para quem gera em blocos que não são de 20 ms: o
    /// tocador do dispositivo entrega o que o dispositivo pede). A nota muda a cada 25 × 960 amostras.
    public static func amostra(_ n: Int64, taxaHz: Double = 48_000) -> Float {
        let porQuadro = Int64((taxaHz * 0.020).rounded())
        let indiceDoQuadro = n / max(1, porQuadro)
        let nota = notasHz[Int((indiceDoQuadro / Int64(quadrosPorNota)) % Int64(notasHz.count))]
        let fase = 2.0 * Double.pi * Double(n) * nota / taxaHz
        return Float(sin(fase) * amplitude)
    }
}
