import CoreGraphics
import CoreText
import Foundation

/// **O roteiro quebrado em linhas**, pelo CoreText, na largura da vista menos as margens.
///
/// O CoreText e não o `NSTextView` porque o prompter precisa de três coisas que o sistema de texto
/// do AppKit não dá de graça: linhas de **altura uniforme** (a unidade da velocidade), rolagem por
/// **camadas movidas sem redesenho** (a vista pinta cada faixa uma vez) e **espelho horizontal**
/// — o `isFlipped` do AppKit inverte na vertical e não serve (`QuallReceptorKit/VistaDeVideo.swift`).
///
/// A quebra é a do `CTTypesetterSuggestLineBreak`, que respeita quebra dura (`\n`, `\u{2029}`):
/// uma linha em branco no roteiro é uma linha em branco na tela. Emoji e acento vêm da troca
/// automática de fonte do CoreText ao desenhar a linha.
public struct TextoDiagramado {
    public let geometria: GeometriaDoTexto
    public let linhas: [CTLine]
    public let ascendente: CGFloat
    public let descendente: CGFloat
    public let largura: CGFloat
    /// O recuo de cada linha a partir da borda esquerda da coluna, para **centralizar** a linha entre
    /// as setas do enquadramento (`docs/teleprompter-ajustes-locais.md` §3). O espaço que sobra no
    /// fim da linha (o da quebra) não conta na largura dela.
    public let recuos: [CGFloat]
    /// Quanto tempo a quebra levou, em ms — vai para o registro (um roteiro de 128 KB inteiro é
    /// quebrado a cada troca de fonte ou margem).
    public let custoMs: Double

    public static let vazio = TextoDiagramado(geometria: .vazia, linhas: [], ascendente: 0,
                                              descendente: 0, largura: 0, recuos: [], custoMs: 0)

    /// O espaço entre linhas, como fração da altura da fonte. 1,25 é o de teleprompter: linhas
    /// muito juntas fazem o olho pular de linha na leitura em movimento.
    public static let entrelinha: CGFloat = 1.25

    public static func diagramar(_ texto: String, fonte: CTFont, cor: CGColor,
                                 largura: CGFloat, centralizar: Bool = true) -> TextoDiagramado {
        let comeco = CFAbsoluteTimeGetCurrent()
        let ascendente = CTFontGetAscent(fonte)
        let descendente = CTFontGetDescent(fonte)
        let entrelinhaDaFonte = CTFontGetLeading(fonte)
        let altura = ((ascendente + descendente + entrelinhaDaFonte) * entrelinha).rounded(.up)
        let larguraUtil = max(1, largura)

        let utf16 = (texto as NSString).length
        guard utf16 > 0 else {
            return TextoDiagramado(geometria: GeometriaDoTexto(alturaDaLinha: Double(altura), inicios: [],
                                                               comprimentoUTF16: 0),
                                   linhas: [], ascendente: ascendente, descendente: descendente,
                                   largura: larguraUtil, recuos: [], custoMs: 0)
        }

        let atributos: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): fonte,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cor,
        ]
        let atribuido = NSAttributedString(string: texto, attributes: atributos)
        let tipografo = CTTypesetterCreateWithAttributedString(atribuido as CFAttributedString)

        var linhas: [CTLine] = []
        var inicios: [Int] = []
        var recuos: [CGFloat] = []
        recuos.reserveCapacity(utf16 / 30 + 1)
        linhas.reserveCapacity(utf16 / 30 + 1)
        inicios.reserveCapacity(utf16 / 30 + 1)
        var inicio = 0
        while inicio < utf16 {
            var quantos = CTTypesetterSuggestLineBreak(tipografo, inicio, Double(larguraUtil))
            if quantos <= 0 {
                // Nem um caractere cabe (largura ínfima): um agrupamento por linha, mas nunca um
                // laço sem fim.
                quantos = CTTypesetterSuggestClusterBreak(tipografo, inicio, Double(larguraUtil))
                if quantos <= 0 { quantos = 1 }
            }
            quantos = min(quantos, utf16 - inicio)
            let linha = CTTypesetterCreateLine(tipografo, CFRange(location: inicio, length: quantos))
            linhas.append(linha)
            inicios.append(inicio)
            recuos.append(centralizar ? TextoDiagramado.recuo(de: linha, largura: larguraUtil) : 0)
            inicio += quantos
        }
        // Um roteiro que termina em quebra **não** ganha a linha em branco depois dela: quase todo
        // editor termina o arquivo em `\n`, e com essa linha a posição 1 ("o fim na linha de
        // leitura", §3) deixaria a última linha escrita uma linha acima da leitura.

        let geometria = GeometriaDoTexto(alturaDaLinha: Double(altura), inicios: inicios,
                                         comprimentoUTF16: utf16)
        return TextoDiagramado(geometria: geometria, linhas: linhas, ascendente: ascendente,
                               descendente: descendente, largura: larguraUtil, recuos: recuos,
                               custoMs: (CFAbsoluteTimeGetCurrent() - comeco) * 1000)
    }

    /// A largura que a linha ocupa de fato: a tipográfica menos o espaço em branco do fim.
    public static func larguraVisivel(de linha: CTLine) -> CGFloat {
        let total = CGFloat(CTLineGetTypographicBounds(linha, nil, nil, nil))
        return max(0, total - CGFloat(CTLineGetTrailingWhitespaceWidth(linha)))
    }

    static func recuo(de linha: CTLine, largura: CGFloat) -> CGFloat {
        max(0, ((largura - larguraVisivel(de: linha)) / 2).rounded(.down))
    }

    /// A linha de base de uma linha dentro da caixa dela, a partir do topo da caixa: o glifo fica
    /// centrado na altura da linha.
    public var baseDesdeOTopo: CGFloat {
        let altura = CGFloat(geometria.alturaDaLinha)
        return (altura - (ascendente + descendente)) / 2 + ascendente
    }
}
