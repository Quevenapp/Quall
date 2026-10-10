import AppKit
import XCTest
@testable import QuallBarraDeMenusKit

/// **A marca da barra de menus**: a geometria contra a de `tools/icones/marca.py`, e a imagem desenhada
/// de verdade num bitmap — o anel, o furo, o vão em volta da bolinha, o vermelho do NO AR e o anel que
/// segue o tema da barra. Nada aqui captura tela: o bitmap é nosso.
///
/// Com `QUALL_PNG_DA_BARRA=<pasta>`, `test_grava_os_pngs_para_olhar` grava as variantes em PNG (as duas
/// imagens nas barras clara e escura, ampliadas) — o jeito de olhar o desenho sem abrir o app.
final class TestesDaMarcaNaBarra: XCTestCase {

    // MARK: - a geometria

    /// Os números do `marca.py`: a caixa vai de 2,7 a 29,8 (27,1 de lado), e a bolinha encosta na borda
    /// direita e na de baixo; o anel, na de cima e na da esquerda.
    func test_a_caixa_e_a_do_marca_py() {
        XCTAssertEqual(GeometriaDaMarca.inicio, 2.7, accuracy: 1e-9)
        XCTAssertEqual(GeometriaDaMarca.ladoDaMarca, 27.1, accuracy: 1e-9)
        XCTAssertEqual(GeometriaDaMarca.raioDoCorte, 6.1, accuracy: 1e-9)
        let g = GeometriaDaMarca(lado: 18)
        XCTAssertEqual(g.escala, 18 / 27.1, accuracy: 1e-9)
        XCTAssertEqual(g.anelDeFora.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(g.anelDeFora.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(g.luz.maxX, 18, accuracy: 1e-9)
        XCTAssertEqual(g.luz.maxY, 18, accuracy: 1e-9)
        // A bolinha: raio 4,6 unidades ≈ 3,06 pt; o traço do anel, 3,6 ≈ 2,39 pt; o vão, 1,5 ≈ 1 pt.
        XCTAssertEqual(g.luz.width / 2, 4.6 * 18 / 27.1, accuracy: 1e-9)
        XCTAssertEqual((g.anelDeFora.width - g.anelDeDentro.width) / 2, 3.6 * 18 / 27.1, accuracy: 1e-9)
        XCTAssertEqual((g.corte.width - g.luz.width) / 2, 1.5 * 18 / 27.1, accuracy: 1e-9)
    }

    /// O corte morde o anel (senão não haveria "corte do O"), e a bolinha fica fora do furo.
    func test_o_corte_morde_o_anel() {
        let d = hypot(GeometriaDaMarca.centroDaLuz.x - GeometriaDaMarca.centroDoAnel.x,
                      GeometriaDaMarca.centroDaLuz.y - GeometriaDaMarca.centroDoAnel.y)
        XCTAssertLessThan(d - GeometriaDaMarca.raioDoCorte, GeometriaDaMarca.raioDeFora)
        XCTAssertGreaterThan(d - GeometriaDaMarca.raioDaLuz, GeometriaDaMarca.raioDeDentro)
    }

    // MARK: - a imagem desenhada

    /// Pronto: imagem modelo; o anel e a bolinha opacos, o furo e o vão transparentes.
    func test_pronto_e_modelo_com_o_vao_vazio() {
        let img = MarcaNaBarra.imagem(noAr: false)
        XCTAssertTrue(img.isTemplate)
        XCTAssertEqual(img.size, NSSize(width: 18, height: 18))
        let b = TestesDaMarcaNaBarra.desenhar(img, aparencia: .aqua)
        XCTAssertGreaterThan(alfa(b, 15, 4.5), 0.9, "o alto do anel")
        XCTAssertGreaterThan(alfa(b, 4.5, 15), 0.9, "a esquerda do anel")
        XCTAssertLessThan(alfa(b, 15, 15), 0.05, "o furo")
        XCTAssertGreaterThan(alfa(b, 25.2, 25.2), 0.9, "a bolinha")
        // No meio do vão (a 5,35 unidades da bolinha, entre 4,6 e 6,1) e dentro da faixa do anel (a
        // 9,08 do centro dele, entre 8,7 e 12,3): sem o corte, aqui haveria anel.
        XCTAssertLessThan(alfa(b, 21.42, 21.42), 0.1, "o vão em volta da bolinha")
    }

    /// No ar: a bolinha é o vermelho do NO AR, e a imagem deixa de ser modelo.
    func test_no_ar_tem_a_bolinha_vermelha() {
        let img = MarcaNaBarra.imagem(noAr: true)
        XCTAssertFalse(img.isTemplate)
        for aparencia in [NSAppearance.Name.aqua, .darkAqua] {
            let b = TestesDaMarcaNaBarra.desenhar(img, aparencia: aparencia)
            let c = b.rgba(marca: 25.2, 25.2)
            XCTAssertGreaterThan(c.a, 0.99, "\(aparencia.rawValue)")
            XCTAssertEqual(c.r, 1, accuracy: 0.01, "\(aparencia.rawValue)")
            XCTAssertEqual(c.g, 69 / 255, accuracy: 0.01, "\(aparencia.rawValue)")
            XCTAssertEqual(c.b, 58 / 255, accuracy: 0.01, "\(aparencia.rawValue)")
            XCTAssertLessThan(alfa(b, 21.42, 21.42), 0.1, "o vão (\(aparencia.rawValue))")
            XCTAssertLessThan(alfa(b, 15, 15), 0.05, "o furo (\(aparencia.rawValue))")
        }
    }

    /// No ar, o anel segue o tema de quem desenha: escuro na barra clara, claro na escura — inclusive nas
    /// aparências "vibrantes" que a barra de menus usa (medido em 01/10: a barra pede a imagem em
    /// `VibrantLight`, `Aqua`, `VibrantDark` e `DarkAqua`).
    func test_no_ar_o_anel_segue_o_tema() {
        let img = MarcaNaBarra.imagem(noAr: true)
        for (aparencia, escuraABarra) in [(NSAppearance.Name.aqua, false), (.vibrantLight, false),
                                          (.darkAqua, true), (.vibrantDark, true)] {
            let b = TestesDaMarcaNaBarra.desenhar(img, aparencia: aparencia)
            XCTAssertGreaterThan(alfa(b, 15, 4.5), 0.5, "o anel aparece (\(aparencia.rawValue))")
            let c = b.rgba(marca: 15, 4.5)
            let brilho = (c.r + c.g + c.b) / 3
            if escuraABarra {
                XCTAssertGreaterThan(brilho, 0.7, "anel claro na barra escura (\(aparencia.rawValue))")
            } else {
                XCTAssertLessThan(brilho, 0.3, "anel escuro na barra clara (\(aparencia.rawValue))")
            }
        }
    }

    // MARK: - os PNGs, para olhar

    func test_grava_os_pngs_para_olhar() throws {
        guard let pasta = ProcessInfo.processInfo.environment["QUALL_PNG_DA_BARRA"], !pasta.isEmpty else {
            throw XCTSkip("QUALL_PNG_DA_BARRA não definida: nada a gravar")
        }
        try FileManager.default.createDirectory(atPath: pasta, withIntermediateDirectories: true)
        // As duas imagens cruas, em 4x (72 × 72): a modelo em preto, a do NO AR na barra escura.
        try png(TestesDaMarcaNaBarra.desenhar(MarcaNaBarra.imagem(noAr: false), aparencia: .aqua),
                em: "\(pasta)/pronto-modelo@4x.png")
        try png(TestesDaMarcaNaBarra.desenhar(MarcaNaBarra.imagem(noAr: true), aparencia: .vibrantDark),
                em: "\(pasta)/no-ar-barra-escura@4x.png")
        // A folha: as duas variantes numa faixa de barra clara e numa escura, em 8x, a modelo tingida como
        // a barra tinge (preto a 85 % na clara, branco na escura).
        try png(folha(), em: "\(pasta)/marca-na-barra.png")
    }

    // MARK: - utilidades

    /// Um quadro RGBA sRGB desenhado por nós, lido byte a byte.
    ///
    /// Os bytes, e não o `colorAt` de um `NSBitmapImageRep`: na primeira versão deste teste o vermelho
    /// `#FF453A` voltava do `colorAt` como (1; 0,37; 0,29), enquanto os bytes do mesmo contexto diziam
    /// (255, 69, 58, 255) — a leitura convertia de espaço de cor, e o teste media a conversão, não o
    /// desenho (sonda de 01/10, quatro caminhos de desenho, todos com os bytes certos).
    struct Quadro {
        let ctx: CGContext
        var lado: Int { ctx.width }

        /// O pixel (do alto para baixo, como a marca), sem o alfa pré-multiplicado, de 0 a 1.
        func rgba(_ px: Int, _ py: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            let i = py * ctx.bytesPerRow + px * 4
            let a = CGFloat(p[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (CGFloat(p[i]) / 255 / a, CGFloat(p[i + 1]) / 255 / a, CGFloat(p[i + 2]) / 255 / a, a)
        }

        /// Um ponto da marca (em unidades, y para baixo).
        func rgba(marca x: CGFloat, _ y: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let p = GeometriaDaMarca(lado: CGFloat(lado)).ponto(x, y)
            return rgba(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
        }

        var imagem: CGImage { ctx.makeImage()! }
    }

    /// A imagem desenhada sozinha (fundo transparente) num quadro de `lado × escala` pixels, na aparência
    /// pedida.
    static func desenhar(_ img: NSImage, aparencia: NSAppearance.Name, escala: Int = 4) -> Quadro {
        let lado = Int(img.size.width) * escala
        return pintar(lado: lado) { _ in
            NSAppearance(named: aparencia)!.performAsCurrentDrawingAppearance {
                img.draw(in: NSRect(x: 0, y: 0, width: lado, height: lado))
            }
        }
    }

    static func pintar(lado: Int, _ bloco: (CGContext) -> Void) -> Quadro {
        let ctx = CGContext(data: nil, width: lado, height: lado, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        bloco(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return Quadro(ctx: ctx)
    }

    private func alfa(_ q: Quadro, _ x: CGFloat, _ y: CGFloat) -> CGFloat { q.rgba(marca: x, y).a }

    private func png(_ q: Quadro, em caminho: String) throws {
        let dados = try XCTUnwrap(NSBitmapImageRep(cgImage: q.imagem).representation(using: .png, properties: [:]))
        try dados.write(to: URL(fileURLWithPath: caminho))
    }

    /// Duas faixas (barra clara, barra escura), cada uma com "pronto" e "no ar" lado a lado.
    private func folha() -> Quadro {
        let escala = 8, celula = 18 * escala, margem = 6 * escala
        let lado = 2 * celula + 3 * margem
        let faixas: [(fundo: NSColor, tinta: NSColor, aparencia: NSAppearance.Name)] = [
            (NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1), NSColor.black.withAlphaComponent(0.85), .vibrantLight),
            (NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1), .white, .vibrantDark),
        ]
        // Cada célula desenhada antes, sozinha: a modelo tingida como a barra tinge (a tinta só onde há
        // alfa), a do NO AR na aparência da faixa.
        var celulas: [[CGImage]] = []
        for faixa in faixas {
            var linha: [CGImage] = []
            for noAr in [false, true] {
                let img = MarcaNaBarra.imagem(noAr: noAr)
                let solta = TestesDaMarcaNaBarra.pintar(lado: celula) { ctx in
                    NSAppearance(named: faixa.aparencia)!.performAsCurrentDrawingAppearance {
                        img.draw(in: NSRect(x: 0, y: 0, width: celula, height: celula))
                    }
                    if !noAr {
                        ctx.setBlendMode(.sourceAtop)
                        ctx.setFillColor(faixa.tinta.cgColor)
                        ctx.fill(CGRect(x: 0, y: 0, width: celula, height: celula))
                    }
                }
                linha.append(solta.imagem)
            }
            celulas.append(linha)
        }
        return TestesDaMarcaNaBarra.pintar(lado: lado) { ctx in
            let faixa = celula + 3 * margem / 2
            for (i, f) in faixas.enumerated() {
                // A clara em cima; o contexto tem y para cima.
                let baixo = lado - (i + 1) * faixa
                ctx.setFillColor(f.fundo.cgColor)
                ctx.fill(CGRect(x: 0, y: baixo, width: lado, height: faixa))
                let y = baixo + 3 * margem / 4
                for j in 0..<2 {
                    ctx.draw(celulas[i][j], in: CGRect(x: margem + j * (celula + margem), y: y, width: celula, height: celula))
                }
            }
        }
    }
}
