import Foundation

/// A conta que liga a **posição** do contrato ao deslocamento da vista, em pontos.
///
/// `docs/contrato-teleprompter.md` §3: `posicao` é a fração do percurso — **0 = o começo na linha de
/// leitura, 1 = o fim nela** —, e `velocidade` é em linhas por segundo, com a linha sendo a altura
/// da linha na fonte do prompter. Esta estrutura é o único lugar em que as duas unidades viram
/// pontos; a vista (`VistaDoRoteiro`) só a consulta.
///
/// # O desenho
///
/// ```
///   ┌──────────── vista (altura H) ────────────┐
///   │  folga de cima T                          │
///   │  ─ ─ ─ ─ ─ linha de leitura em R = linha·H │   ← o centro da linha lida fica aqui
///   │  texto (alturaDoTexto, linhas de altura L) │
///   │  folga de baixo B                          │
///   └───────────────────────────────────────────┘
/// ```
///
/// Com o deslocamento `y`, o centro da primeira linha fica em `T + L/2 - y` na tela: está na linha
/// de leitura quando `y = y0 = T + L/2 - R`. O centro da última fica em `T + alturaDoTexto - L/2 -
/// y`, e está na linha de leitura quando `y = y1`. O percurso é `y1 - y0 = alturaDoTexto - L`.
///
/// As folgas `T` e `B` são as que deixam `y0` e `y1` dentro do que a vista rola sozinha, para o
/// dedo e o relógio andarem pelo mesmo trilho. Quando a linha de leitura encosta no topo (`R <
/// L/2`), `T` não fica negativa: a primeira linha começa meio cortada, que é o que a pessoa pediu.
///
/// Função pura, sem UIKit: testada no MacBook por `Testes/rodar.sh`.
struct GeometriaDoRoteiro: Equatable {
    /// Altura da vista do texto, em pontos.
    let alturaDaVista: Double
    /// Altura de uma linha, em pontos — a unidade da velocidade.
    let alturaDaLinha: Double
    /// Altura do texto já disposto, sem as folgas.
    let alturaDoTexto: Double
    /// Fração da altura da vista, a partir do topo (0 a 1).
    let linhaDeLeitura: Double

    /// Onde fica a linha de leitura, em pontos a partir do topo da vista.
    var r: Double { max(0, min(1, linhaDeLeitura)) * alturaDaVista }

    /// A folga de cima (`textContainerInset.top`).
    var folgaDeCima: Double { max(0, r - alturaDaLinha / 2) }
    /// A folga de baixo (`textContainerInset.bottom`).
    var folgaDeBaixo: Double { max(0, alturaDaVista - r - alturaDaLinha / 2) }

    /// O deslocamento com o começo do texto na linha de leitura.
    var y0: Double { folgaDeCima + alturaDaLinha / 2 - r }
    /// O deslocamento com o fim do texto na linha de leitura.
    var y1: Double { max(y0, folgaDeCima + alturaDoTexto - alturaDaLinha / 2 - r) }
    /// O percurso inteiro, em pontos. Zero quando o texto tem uma linha ou nenhuma.
    var percurso: Double { y1 - y0 }

    /// O deslocamento de uma posição (fração do percurso).
    func deslocamento(posicao: Double) -> Double {
        let p = posicao.isFinite ? max(0, min(1, posicao)) : 0
        return y0 + p * percurso
    }

    /// A posição (fração do percurso) de um deslocamento. Fora do trilho, prende nas pontas.
    func posicao(deslocamento: Double) -> Double {
        guard percurso > 0, deslocamento.isFinite else { return 0 }
        return max(0, min(1, (deslocamento - y0) / percurso))
    }

    /// Quantos pontos por segundo andam a `velocidade` linhas por segundo.
    func pontosPorSegundo(velocidade: Double) -> Double {
        guard velocidade.isFinite, velocidade > 0 else { return 0 }
        return velocidade * alturaDaLinha
    }

    /// Arredonda um deslocamento ao pixel da tela: texto que para entre dois pixels fica borrado,
    /// e o passo de ~1 pt por quadro de uma rolagem lenta passaria a maior parte do tempo assim.
    /// O acumulado continua em `Double` à parte — é só o que vai para a vista que arredonda.
    static func noPixel(_ y: Double, escala: Double) -> Double {
        guard escala > 0, y.isFinite else { return y }
        return (y * escala).rounded() / escala
    }

    /// A linha de leitura em coordenadas **do texto** (0 = topo da primeira linha), com o
    /// deslocamento `y`. É `y + L/2` sempre que a linha de leitura não encosta no topo.
    func leituraNoTexto(deslocamento y: Double) -> Double { y + r - folgaDeCima }

    /// O deslocamento que põe `leituraNoTexto` em `t`, preso ao trilho.
    func deslocamento(leituraNoTexto t: Double) -> Double {
        guard t.isFinite else { return y0 }
        return min(y1, max(y0, t - r + folgaDeCima))
    }
}

/// **Onde cada linha do roteiro começa**, depois de diagramado: a tabela que liga um caractere a
/// uma linha, e a linha de leitura a um caractere.
///
/// # O ponto de leitura sobrevive ao layout novo
///
/// A vista de antes guardava a **fração** do percurso ao refazer o layout. A fração é a unidade do
/// contrato, mas não é o lugar de quem lê: o texto não tem o mesmo número de caracteres por linha
/// do começo ao fim (e um roteiro de verdade, com linhas curtas e em branco, menos ainda), e a
/// mesma fração cai noutra frase. Medido em 14/09 no iPhone X, com o texto parado em 0,3 de um
/// roteiro de 100 KB: a frase na linha de leitura foi de 492 (48 pt) para 481 (96 pt) e para 524
/// (32 pt), pelos pixels da tela; e 50–200 linhas por troca de fonte na varredura com 100–128 KB.
/// Agora o que se guarda é o **caractere** que abre a linha que está na linha de leitura, e quanto
/// do caminho até a próxima já foi andado; no layout novo, a vista põe a linha que contém esse
/// caractere de volta na linha de leitura. É a regra do Mac (`GeometriaDoTexto.pontoDeLeitura`).
/// A posição relatada ao controle é recalculada no layout novo, que é o que o contrato manda (§3:
/// "a posição depende do layout de cada aparelho").
///
/// Pura, sem CoreText nem UIKit: testada no MacBook por `Testes/rodar.sh`.
struct LinhasDoRoteiro: Equatable {
    /// Onde cada linha começa, em unidades UTF-16 do texto (a unidade do CoreText). Crescente, e a
    /// primeira é 0 quando há texto.
    let inicios: [Int]
    let alturaDaLinha: Double

    static let vazia = LinhasDoRoteiro(inicios: [], alturaDaLinha: 1)

    var quantas: Int { inicios.count }
    var alturaDoTexto: Double { Double(inicios.count) * alturaDaLinha }

    /// A linha que contém o caractere `c`: a última cujo início é `<= c`.
    func linha(doCaractere c: Int) -> Int {
        guard !inicios.isEmpty else { return 0 }
        var baixo = 0, alto = inicios.count - 1
        while baixo < alto {
            let meio = (baixo + alto + 1) / 2
            if inicios[meio] <= c { baixo = meio } else { alto = meio - 1 }
        }
        return baixo
    }

    /// A linha que está em `t` (coordenadas do texto), presa às pontas.
    func linha(noTexto t: Double) -> Int {
        guard !inicios.isEmpty, t.isFinite else { return 0 }
        return min(inicios.count - 1, max(0, Int((t / alturaDaLinha).rounded(.down))))
    }

    /// O ponto de leitura com a linha de leitura em `t`: o caractere que abre a linha dela, e onde
    /// `t` está na linha, de −0,5 (topo) a 0,5 (pé), a partir do centro.
    func pontoDeLeitura(noTexto t: Double) -> PontoDeLeitura? {
        guard !inicios.isEmpty, t.isFinite else { return nil }
        let i = linha(noTexto: t)
        let fracao = min(0.5, max(-0.5, t / alturaDaLinha - Double(i) - 0.5))
        return PontoDeLeitura(caractere: inicios[i], fracao: fracao)
    }

    /// Onde a linha de leitura tem de ficar (coordenadas do texto) para mostrar o ponto. Um
    /// caractere além do fim (o texto encolheu) cai na última linha.
    func noTexto(paraPonto p: PontoDeLeitura) -> Double {
        guard !inicios.isEmpty else { return 0 }
        let i = linha(doCaractere: max(0, p.caractere))
        return (Double(i) + 0.5 + p.fracao) * alturaDaLinha
    }

    /// As linhas que tocam o intervalo `[de, ate)` do texto.
    func linhas(de: Double, ate: Double) -> Range<Int> {
        guard !inicios.isEmpty, de.isFinite, ate.isFinite, ate > de else { return 0..<0 }
        let a = min(inicios.count, max(0, Int((de / alturaDaLinha).rounded(.down))))
        let b = min(inicios.count, max(a, Int((ate / alturaDaLinha).rounded(.up))))
        return a..<b
    }
}

/// O caractere que abre a linha que está na linha de leitura, e quanto dela já passou (−0,5 a 0,5).
struct PontoDeLeitura: Equatable {
    let caractere: Int
    let fracao: Double
}
