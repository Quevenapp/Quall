import Foundation

/// Alvo de breakpoint do degrau 1 da escada de portões do M3.
///
/// Existe para provar três coisas que falham separadamente no iPhone 7 (iOS 15.8.8):
/// símbolo de Swift resolvendo por nome, breakpoint parando de fato, e `po`/`frame variable`
/// respondendo sobre tipos de Swift (String, struct, enum) no aparelho.
///
/// Nada aqui é código de produto: é instrumento de portão.
enum Grandeza: Int {
    case tela = 7
    case camera = 15
}

struct MarcaDeProva {
    let giro: Int
    let rotulo: String
    let grandeza: Grandeza
    let fracao: Double
}

@inline(never)
func provaDeDepuracao(giro: Int) -> MarcaDeProva {
    let rotulo = "portao-m3-giro-\(giro)"
    let grandeza: Grandeza = (giro % 2 == 0) ? .tela : .camera
    let fracao = Double(giro) / 3.0
    let marca = MarcaDeProva(giro: giro, rotulo: rotulo, grandeza: grandeza, fracao: fracao)
    // A soma existe só para dar uma linha depois da construção, com a marca já viva.
    let soma = giro + grandeza.rawValue
    NSLog("QUALL-PROVA giro=%d rotulo=%@ soma=%d", giro, rotulo, soma)
    return marca
}
