import Foundation

/// **A geometria do texto diagramado**, sem CoreText: onde cada linha começa e a altura delas.
///
/// # A posição do contrato
///
/// `posicao` é "fração do percurso: 0 = começo na linha de leitura, 1 = fim nela" (§3). Aqui isso
/// vira: com deslocamento 0, **o centro da primeira linha** está na linha de leitura; com
/// deslocamento `percurso`, o centro da última. Então `percurso = (linhas − 1) × altura`, e a
/// posição é `deslocamento / percurso`.
///
/// Todas as linhas têm a **mesma altura** — a da fonte do prompter —, que é a unidade da
/// velocidade ("linhas por segundo, linha = altura da linha na fonte do prompter", §3). Com altura
/// uniforme, velocidade constante em linhas por segundo é velocidade constante em pontos por
/// segundo, e o texto não acelera numa linha em branco.
public struct GeometriaDoTexto: Equatable, Sendable {
    /// A altura de uma linha, em pontos.
    public let alturaDaLinha: Double
    /// Onde cada linha começa, em unidades UTF-16 do texto (a unidade do CoreText). Crescente, e a
    /// primeira é 0 quando há texto.
    public let inicios: [Int]
    public let comprimentoUTF16: Int

    public init(alturaDaLinha: Double, inicios: [Int], comprimentoUTF16: Int) {
        self.alturaDaLinha = max(1, alturaDaLinha)
        self.inicios = inicios
        self.comprimentoUTF16 = comprimentoUTF16
    }

    public static let vazia = GeometriaDoTexto(alturaDaLinha: 1, inicios: [], comprimentoUTF16: 0)

    public var quantasLinhas: Int { inicios.count }
    public var alturaTotal: Double { Double(inicios.count) * alturaDaLinha }
    public var percurso: Double { Double(max(0, inicios.count - 1)) * alturaDaLinha }

    public func deslocamento(paraPosicao p: Double) -> Double {
        guard p.isFinite else { return 0 }
        return min(1, max(0, p)) * percurso
    }

    public func posicao(paraDeslocamento d: Double) -> Double {
        guard percurso > 0, d.isFinite else { return 0 }
        return min(1, max(0, d / percurso))
    }

    /// A linha cujo centro está mais perto da linha de leitura, com o deslocamento `d`.
    public func linha(noDeslocamento d: Double) -> Int {
        guard !inicios.isEmpty, d.isFinite else { return 0 }
        let i = Int((d / alturaDaLinha).rounded())
        return min(inicios.count - 1, max(0, i))
    }

    /// A linha que contém o caractere `c` (UTF-16): a última cujo início é `<= c`.
    public func linha(doCaractere c: Int) -> Int {
        guard !inicios.isEmpty else { return 0 }
        var baixo = 0, alto = inicios.count - 1
        while baixo < alto {
            let meio = (baixo + alto + 1) / 2
            if inicios[meio] <= c { baixo = meio } else { alto = meio - 1 }
        }
        return baixo
    }

    /// **O ponto de leitura**: o caractere que abre a linha que está na linha de leitura, e quanto
    /// do caminho até a próxima já foi andado (−0,5 a 0,5). É o que se guarda antes de refazer o
    /// layout, para quem lê não perder o lugar quando a fonte ou a margem mudam.
    public func pontoDeLeitura(noDeslocamento d: Double) -> (caractere: Int, fracao: Double) {
        guard !inicios.isEmpty else { return (0, 0) }
        let i = linha(noDeslocamento: d)
        let fracao = min(0.5, max(-0.5, d / alturaDaLinha - Double(i)))
        return (inicios[i], fracao)
    }

    /// O deslocamento que põe o ponto de leitura de volta na linha de leitura, nesta geometria.
    /// Um caractere além do fim do texto (o texto encolheu) cai na última linha.
    public func deslocamento(paraPonto ponto: (caractere: Int, fracao: Double)) -> Double {
        guard !inicios.isEmpty else { return 0 }
        let i = linha(doCaractere: max(0, ponto.caractere))
        let d = (Double(i) + ponto.fracao) * alturaDaLinha
        return min(percurso, max(0, d))
    }

    /// As linhas que aparecem numa janela de `alturaVisivel` pontos, com a linha de leitura a
    /// `yLeitura` pontos do topo e o deslocamento `d`. Serve ao desenho: só essas são pintadas.
    public func linhasVisiveis(deslocamento d: Double, yLeitura: Double, alturaVisivel: Double) -> Range<Int> {
        guard !inicios.isEmpty else { return 0..<0 }
        // O topo do texto, em coordenadas da vista (y para baixo): o centro da linha 0 fica em
        // `yLeitura` quando `d = 0`.
        let topoDoTexto = yLeitura - alturaDaLinha / 2 - d
        let primeira = Int(((0 - topoDoTexto) / alturaDaLinha).rounded(.down))
        let ultima = Int(((alturaVisivel - topoDoTexto) / alturaDaLinha).rounded(.up))
        let a = min(inicios.count, max(0, primeira))
        let b = min(inicios.count, max(a, ultima))
        return a..<b
    }
}

/// **A rolagem em velocidade constante.** O integrador de um quadro para o outro, sem relógio
/// próprio: quem chama passa o `dt` medido pelo relógio da tela.
///
/// Velocidade constante é `deslocamento += velocidade × altura × dt`, com o `dt` de verdade entre
/// dois quadros — nunca um passo fixo por quadro, que andaria mais devagar quando um quadro atrasa
/// e mais depressa numa tela de 120 Hz. O `dt` é limitado a 0,25 s: um quadro que chega depois de o
/// Mac acordar do repouso não pode arrastar o texto meia página de uma vez.
public struct Rolagem: Equatable, Sendable {
    public private(set) var deslocamento: Double = 0
    public static let dtMaximo = 0.25

    public init(deslocamento: Double = 0) {
        self.deslocamento = deslocamento.isFinite ? max(0, deslocamento) : 0
    }

    /// Anda `dt` segundos. Devolve `true` quando **acabou de chegar** ao fim (neste passo).
    @discardableResult
    public mutating func avancar(dt: Double, velocidade: Double, geometria: GeometriaDoTexto) -> Bool {
        guard dt.isFinite, velocidade.isFinite, dt > 0, velocidade > 0 else { return false }
        let antes = deslocamento
        let passo = min(dt, Rolagem.dtMaximo) * velocidade * geometria.alturaDaLinha
        deslocamento = min(geometria.percurso, deslocamento + passo)
        return geometria.percurso > 0 && antes < geometria.percurso && deslocamento >= geometria.percurso
    }

    /// **Anda `dt` segundos para trás** — o "segurar para rolar" com `para_tras`
    /// (`docs/contrato-teleprompter.md` §12.5): a mesma velocidade, a mesma conta e o mesmo teto de
    /// `dt` do `avancar`, no sentido contrário, e **para no começo** (deslocamento 0). Quem chama não
    /// muda `rolando` quando chega: o texto fica parado no começo até o controle soltar. Devolve
    /// `true` quando **acabou de chegar** ao começo (neste passo).
    @discardableResult
    public mutating func recuar(dt: Double, velocidade: Double, geometria: GeometriaDoTexto) -> Bool {
        guard dt.isFinite, velocidade.isFinite, dt > 0, velocidade > 0 else { return false }
        let antes = min(geometria.percurso, deslocamento)
        let passo = min(dt, Rolagem.dtMaximo) * velocidade * geometria.alturaDaLinha
        deslocamento = max(0, antes - passo)
        return antes > 0 && deslocamento == 0
    }

    /// Vai direto a um deslocamento (salto, relayout), preso ao percurso.
    public mutating func ir(para d: Double, geometria: GeometriaDoTexto) {
        guard d.isFinite else { return }
        deslocamento = min(geometria.percurso, max(0, d))
    }

    public func noFim(_ geometria: GeometriaDoTexto) -> Bool {
        geometria.percurso > 0 && deslocamento >= geometria.percurso
    }

    public var noComeco: Bool { deslocamento <= 0 }
}
