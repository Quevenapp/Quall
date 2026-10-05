import AppKit
import QuallIdiomaKit

/// Placeholder original do snapshot público: moldura quadrada e indicador de estado central.
/// Não reproduz a marca gráfica privada cuja procedência ainda está em revisão.
public struct GeometriaDaMarca: Equatable {
    public static let ladoDaMarca: CGFloat = 32
    public let escala: CGFloat

    public init(lado: CGFloat) { escala = lado / GeometriaDaMarca.ladoDaMarca }

    public func ponto(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * escala, y: y * escala)
    }

    private func retangulo(_ x: CGFloat, _ y: CGFloat, _ lado: CGFloat) -> CGRect {
        CGRect(x: x * escala, y: y * escala, width: lado * escala, height: lado * escala)
    }

    public var moldura: CGRect { retangulo(4, 4, 24) }
    public var interior: CGRect { retangulo(8, 8, 16) }
    public var luz: CGRect { retangulo(14, 14, 4) }
}

/// Ícone de estado em 18 pt. Pronto é uma imagem modelo; no ar preserva a indicação vermelha.
public enum MarcaNaBarra {
    /// O lado da imagem, em pontos. A barra tem 22 a 24 pt de altura; 18 é o tamanho de um ícone dela.
    public static let lado: CGFloat = 18
    /// O vermelho do indicador de transmissão (`Estilo.noAr`).
    public static let vermelho = NSColor(srgbRed: 1, green: 69 / 255, blue: 58 / 255, alpha: 1)

    /// A imagem pronta para o `NSStatusItem`: modelo quando nada está no ar, colorida quando está.
    public static func imagem(noAr: Bool, lado: CGFloat = MarcaNaBarra.lado) -> NSImage {
        let imagem = NSImage(size: NSSize(width: lado, height: lado), flipped: true) { quadro in
            desenhar(noAr: noAr, em: quadro)
            return true
        }
        imagem.isTemplate = !noAr
        imagem.accessibilityDescription = noAr ? T("Quall Studio, no ar") : "Quall Studio"
        return imagem
    }

    /// Desenha a marca no quadro (y para baixo). Na imagem modelo só o alfa conta, e o anel vai em
    /// preto; na de "no ar", o anel vai na cor da barra de quem desenha (`corDoAnelNoAr`).
    public static func desenhar(noAr: Bool, em quadro: CGRect) {
        let lado = min(quadro.width, quadro.height)
        let g = GeometriaDaMarca(lado: lado)
        let deslocamento = NSAffineTransform()
        deslocamento.translateX(by: quadro.minX, yBy: quadro.minY)
        let corDoAnel: NSColor = noAr ? corDoAnelNoAr(NSAppearance.currentDrawing()) : .black

        NSGraphicsContext.saveGraphicsState()
        deslocamento.concat()

        // A moldura deixa o centro transparente, exceto pelo indicador de estado.
        let moldura = NSBezierPath(rect: g.moldura)
        moldura.appendRect(g.interior)
        moldura.windingRule = .evenOdd
        corDoAnel.setFill()
        moldura.fill()
        (noAr ? vermelho : corDoAnel).setFill()
        NSBezierPath(rect: g.luz).fill()

        NSGraphicsContext.restoreGraphicsState()
    }

    /// O anel da imagem colorida: branco numa barra escura, preto a 85 % numa clara. As aparências de
    /// alto contraste caem na mais próxima das quatro.
    public static func corDoAnelNoAr(_ aparencia: NSAppearance) -> NSColor {
        let escura = aparencia.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        return escura == .darkAqua || escura == .vibrantDark ? .white : NSColor.black.withAlphaComponent(0.85)
    }
}
