import AppKit
import QuallIdiomaKit

/// **A marca do Quall em unidades**, a mesma de `tools/icones/marca.py` (o ícone dos apps) e de
/// `MarcaDoQuall` (a barra lateral): um desenho de 32 unidades, com o anel de raio 10,5 e traço de 3,6
/// centrado em (15; 15), a bolinha (a luz de gravação) de raio 4,6 em (25,2; 25,2), e um vão de 1,5 em
/// volta da bolinha que corta o anel — o "corte do O" (30/09).
///
/// O eixo y cresce **para baixo**, como no PIL do `marca.py` e no `Canvas` do SwiftUI: a bolinha fica
/// embaixo, à direita. A caixa da marca (do anel à bolinha) é quadrada — de 2,7 a 29,8 nos dois eixos,
/// 27,1 de lado —, e é ela que ocupa o quadro inteiro da imagem.
public struct GeometriaDaMarca: Equatable {
    public static let centroDoAnel = CGPoint(x: 15, y: 15)
    public static let raioDoAnel: CGFloat = 10.5
    public static let traco: CGFloat = 3.6
    public static let centroDaLuz = CGPoint(x: 25.2, y: 25.2)
    public static let raioDaLuz: CGFloat = 4.6
    public static let vao: CGFloat = 1.5

    public static let raioDeFora = raioDoAnel + traco / 2
    public static let raioDeDentro = raioDoAnel - traco / 2
    public static let raioDoCorte = raioDaLuz + vao
    /// O canto da caixa da marca (o mesmo nos dois eixos): 2,7.
    public static let inicio = min(centroDoAnel.x - raioDeFora, centroDaLuz.x - raioDaLuz)
    /// O lado da caixa: 27,1.
    public static let ladoDaMarca = max(centroDoAnel.x + raioDeFora, centroDaLuz.x + raioDaLuz) - inicio

    /// Pontos (ou pixels) por unidade da marca.
    public let escala: CGFloat

    /// A marca ocupando um quadrado de `lado` (em pontos), com a caixa dela encostada nas quatro bordas.
    public init(lado: CGFloat) {
        escala = lado / GeometriaDaMarca.ladoDaMarca
    }

    /// Um ponto da marca (em unidades) no quadro da imagem, y para baixo.
    public func ponto(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - GeometriaDaMarca.inicio) * escala, y: (y - GeometriaDaMarca.inicio) * escala)
    }

    private func circulo(_ centro: CGPoint, _ raio: CGFloat) -> CGRect {
        let c = ponto(centro.x, centro.y)
        let r = raio * escala
        return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }

    /// A borda de fora do anel.
    public var anelDeFora: CGRect { circulo(GeometriaDaMarca.centroDoAnel, GeometriaDaMarca.raioDeFora) }
    /// A borda de dentro do anel (o furo).
    public var anelDeDentro: CGRect { circulo(GeometriaDaMarca.centroDoAnel, GeometriaDaMarca.raioDeDentro) }
    /// O círculo que some do anel em volta da bolinha (a bolinha mais o vão).
    public var corte: CGRect { circulo(GeometriaDaMarca.centroDaLuz, GeometriaDaMarca.raioDoCorte) }
    /// A bolinha.
    public var luz: CGRect { circulo(GeometriaDaMarca.centroDaLuz, GeometriaDaMarca.raioDaLuz) }
}

/// **O ícone do Quall na barra de menus** (01/10): a marca em 18 pt, desenhada por código.
///
/// # As duas imagens
///
/// - **Pronto** (nada saindo deste Mac): **imagem modelo** — monocromática, e quem pinta é a barra de
///   menus, na cor dela (clara, escura, realçada com o menu aberto). É o que todo ícone de barra faz.
/// - **No ar** (este Mac transmitindo: o espelhamento, a tela estendida com aparelho, a câmera indo):
///   a bolinha fica **vermelha** (`#FF453A`, o NO AR do app), e uma imagem modelo não pode ter cor.
///   Então ela deixa de ser modelo, e o anel é pintado **na hora de desenhar**, na cor da barra que
///   pediu: branco na escura, preto a 85 % na clara — o tom que a barra dá às imagens modelo, para o
///   anel não mudar de cor quando a bolinha acende. (`labelColor` foi a primeira ideia; na aparência
///   `VibrantLight` ela sai cinza-médio sem a vibração da barra, e o anel clareava ao entrar no ar.)
///
/// # Por que o anel colorido acerta o tema, mesmo com o app forçado no escuro
///
/// O app força `NSApp.appearance = darkAqua` (`docs/telas-estudio.md` §1), e a dúvida era se isso
/// vazava para o botão da barra — aí o anel sairia branco numa barra clara. **Medido em 01/10** com uma
/// sonda (um `NSStatusItem` num processo à parte, lendo só nomes de aparência, sem capturar nada): com o
/// app em `aqua` **e** com ele forçado em `darkAqua`, o botão tinha a mesma `effectiveAppearance`
/// (`NSAppearanceNameVibrantDark`, a barra daquele momento, que no macOS 26 segue o fundo de tela) — é
/// a barra que decide, não o app. E o bloco de desenho foi chamado **seis vezes**, em `VibrantLight`,
/// `Aqua`, `VibrantDark` e `DarkAqua`: a barra pede a imagem em cada aparência que pode precisar. Por
/// isso o desenho é um bloco (`NSImage(size:flipped:drawingHandler:)`) e não um bitmap pronto: a cor do
/// anel sai certa em cada pedido.
///
/// O corte é feito por **recorte** (tudo menos o círculo do corte), e não pintando "transparente" por
/// cima: o bloco desenha direto no contexto de quem chama, e um `.clear` furaria a barra de menus.
public enum MarcaNaBarra {
    /// O lado da imagem, em pontos. A barra tem 22 a 24 pt de altura; 18 é o tamanho de um ícone dela.
    public static let lado: CGFloat = 18
    /// O vermelho do NO AR (`Estilo.noAr` no escuro; `VERMELHO` do `marca.py`).
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

        // O anel, sem o círculo do corte: recorte "tudo menos o corte" (par-ímpar entre o quadro e o
        // círculo), e o anel por par-ímpar entre a borda de fora e a de dentro.
        NSGraphicsContext.saveGraphicsState()
        let recorte = NSBezierPath(rect: CGRect(x: -lado, y: -lado, width: 3 * lado, height: 3 * lado))
        recorte.appendOval(in: g.corte)
        recorte.windingRule = .evenOdd
        recorte.addClip()
        let anel = NSBezierPath(ovalIn: g.anelDeFora)
        anel.appendOval(in: g.anelDeDentro)
        anel.windingRule = .evenOdd
        corDoAnel.setFill()
        anel.fill()
        NSGraphicsContext.restoreGraphicsState()

        (noAr ? vermelho : corDoAnel).setFill()
        NSBezierPath(ovalIn: g.luz).fill()

        NSGraphicsContext.restoreGraphicsState()
    }

    /// O anel da imagem colorida: branco numa barra escura, preto a 85 % numa clara. As aparências de
    /// alto contraste caem na mais próxima das quatro.
    public static func corDoAnelNoAr(_ aparencia: NSAppearance) -> NSColor {
        let escura = aparencia.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        return escura == .darkAqua || escura == .vibrantDark ? .white : NSColor.black.withAlphaComponent(0.85)
    }
}
