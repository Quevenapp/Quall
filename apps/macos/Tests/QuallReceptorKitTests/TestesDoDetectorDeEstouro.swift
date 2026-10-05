import XCTest
@testable import QuallReceptorKit

/// O detector do estouro da claquete (`DetectorDeEstouro`), contra estouros em posições conhecidas.
final class TestesDoDetectorDeEstouro: XCTestCase {

    /// `slots` slots de 960 amostras a 48 kHz: tom de 1 kHz (calado ±40 ms em volta) e um estouro
    /// de 10 ms a 3 150 Hz começando em `comeco`.
    private func sinal(comeco: Int, amplitude: Float = 0.5, slots: Int = 10) -> [Float] {
        let n = slots * 960
        return (0..<n).map { i -> Float in
            let centro = comeco + 240
            if i >= comeco && i < comeco + 480 {
                return amplitude * sin(2 * .pi * 3150 * Float(i - comeco) / 48_000)
            }
            if abs(i - centro) < 1920 { return 0 }
            return 0.5 * sin(2 * .pi * 1000 * Float(i) / 48_000)
        }
    }

    private func detectar(_ x: [Float]) -> [Double] {
        var d = DetectorDeEstouro()
        defer { d.liberar() }
        var achados: [Double] = []
        x.withUnsafeBufferPointer { b in
            for k in 0..<(x.count / 960) {
                if let o = d.processar(b.baseAddress!.advanced(by: k * 960), 960) {
                    achados.append(Double(k * 960) + o)
                }
            }
        }
        return achados
    }

    /// Em todas as fases do passo de 1 ms, e dos dois lados da emenda entre slots: o começo sai a
    /// menos de meio passo, e o tom de fundo não dispara nada.
    func testeOComecoDoEstouroSaiAMenosDeMeioMilissegundo() {
        var erros: [Double] = []
        for comeco in Array(stride(from: 3000, to: 3096, by: 4)) + [4790, 4800, 4810, 5750] {
            let achados = detectar(sinal(comeco: comeco))
            XCTAssertEqual(achados.count, 1, "um estouro em \(comeco): \(achados)")
            if let a = achados.first { erros.append(a - Double(comeco)) }
        }
        let media = erros.reduce(0, +) / Double(max(erros.count, 1))
        let pior = erros.map { abs($0 - media) }.max() ?? 0
        print(String(format: "detector: viés médio %.1f amostras, pior desvio %.1f amostras", media, pior))
        XCTAssertLessThan(abs(media), 6, "o viés descontado deixa o erro médio perto de zero")
        XCTAssertLessThan(pior, 26, "±0,5 ms de resolução (24 amostras)")
    }

    func testeOTomSozinhoNaoDispara() {
        let notas: [Float] = [400, 500, 800, 1000]
        var x = [Float](repeating: 0, count: 960 * 20)
        for i in 0..<x.count {
            let f = notas[(i / 12_000) % 4]
            let fase = 2 * Float.pi * f * Float(i) / 48_000
            x[i] = 0.5 * sin(fase)
        }
        XCTAssertEqual(detectar(x), [], "o tom de fundo não é estouro")
    }

    /// Mais fraco (o PCMU interpolado atenua 3 150 Hz) ainda é achado.
    func testeEstouroAtenuadoAindaEAchado() {
        XCTAssertEqual(detectar(sinal(comeco: 3100, amplitude: 0.25)).count, 1)
    }
}
