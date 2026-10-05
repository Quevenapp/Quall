import Foundation

/// **O ritmo do botão que repete enquanto pressionado** (tartaruga e coelho, o − e o + da velocidade;
/// pedido do Pessoa Exemplo, 27/09: "tem que dar vários toques"). Puro: roda em `Testes/rodar.sh`.
///
/// Um toque é um passo (ao soltar); segurando, o primeiro passo vem depois de `espera`, e os
/// seguintes cada vez mais depressa, até `minimo`. Soltar para. `teto` repetições por aperto, no máximo (um gesto que o
/// sistema cancelar sem avisar não pode ficar mudando a velocidade para sempre).
enum RepeticaoDoBotao {
    static let espera: Double = 0.4
    static let primeiro: Double = 0.18
    static let minimo: Double = 0.05
    static let fator: Double = 0.85
    static let teto = 150

    /// O intervalo antes da repetição `n` (1 é a primeira): `espera`, depois `primeiro × fator^(n−2)`,
    /// nunca abaixo de `minimo`. `nil` passado o teto.
    static func intervalo(antesDaRepeticao n: Int) -> Double? {
        guard n >= 1, n <= teto else { return nil }
        if n == 1 { return espera }
        var v = primeiro
        for _ in 0..<(n - 2) { v *= fator }
        return max(minimo, v)
    }
}
