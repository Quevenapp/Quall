import CoreText
import UIKit

/// **A sonda de pilhas** (`--sonda-de-pilhas`): o mesmo roteiro, a mesma fonte e a mesma largura,
/// medidos em cada pilha de texto que o iOS oferece — para escolher o conserto do tranco pelo
/// número, e não pela fama da pilha.
///
/// Cada medida roda três vezes; sai a primeira (fria: caches de fonte e de glifo vazios para aquele
/// tamanho) e a mediana. Tudo na principal, menos o que diz `_fundo` (uma thread de
/// `userInitiated`, esperada pela principal: é o custo que a diagramação teria fora dela).
///
/// | pilha | o que é |
/// |---|---|
/// | `tk1_sozinho` | `NSTextStorage` + `NSLayoutManager` (contíguo) + `NSTextContainer`, sem vista: o que o TextKit 1 custa por si |
/// | `tk1_vista` | um `UITextView` em TextKit 1 fora da tela, como a vista de antes: `definir` (o `attributedText`) e `diagramar` (`ensureLayout`) |
/// | `tk2_vista` | um `UITextView` em TextKit 2 (iOS 16): a janela visível, a altura **estimada** no começo, no meio e no fim, e o layout inteiro |
/// | `ct_quebra` | o CoreText do Mac (`TextoDiagramado`): `CTTypesetterSuggestLineBreak` + `CTTypesetterCreateLine` no texto inteiro |
/// | `ct_so_quebra` | o mesmo, sem criar as linhas (só os índices) |
/// | `ct_frame` | `CTFramesetterSuggestFrameSizeWithConstraints` (só a altura) |
/// | `bounding` | `NSAttributedString.boundingRect` — só no menor tamanho: cresce muito mais que linear |
/// | `pintar_bloco`, `pintar_tela` | pintar ~380 pt, e uma tela, de linhas do CoreText num bitmap na escala da tela |
///
/// O que ela disse em 14/09 está no cabeçalho de `DiagramaDoRoteiro` e no de `VistaDoRoteiro`.
enum SondaDePilhas {

    private static func dizer(_ s: String) { DiarioDoTeleprompter.dizer("sonda: " + s) }

    /// Três vezes; devolve a primeira (fria) e a mediana, em ms.
    private static func cronometrar(_ vezes: Int = 3, _ bloco: () -> Void) -> (fria: Double, mediana: Double) {
        var t: [Double] = []
        for _ in 0..<vezes {
            let t0 = CACurrentMediaTime()
            bloco()
            t.append((CACurrentMediaTime() - t0) * 1000)
        }
        return (t[0], t.sorted()[t.count / 2])
    }

    private static func noFundo(_ bloco: @escaping () -> Void) {
        let s = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { bloco(); s.signal() }
        s.wait()
    }

    private static func linha(_ pilha: String, _ bytes: Int, _ fonte: CGFloat, _ t: (fria: Double, mediana: Double),
                              _ extra: String = "") {
        dizer(String(format: "pilha=%@ bytes=%d fonte=%.0f fria_ms=%.1f mediana_ms=%.1f", pilha, bytes, fonte,
                     t.fria, t.mediana) + (extra.isEmpty ? "" : " " + extra))
    }

    /// Os atributos da vista de antes (TextKit 1): altura de linha fixa e o texto no meio dela.
    static func atribuido(_ texto: String, fonte f: UIFont, linha L: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = L
        p.maximumLineHeight = L
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: texto, attributes: [
            .font: f, .foregroundColor: UIColor.white, .paragraphStyle: p, .baselineOffset: (L - f.lineHeight) / 4,
        ])
    }

    static func diagramarTK1(_ a: NSAttributedString, largura: CGFloat) -> CGFloat {
        let armazem = NSTextStorage(attributedString: a)
        let gerente = NSLayoutManager()
        gerente.allowsNonContiguousLayout = false
        let conteiner = NSTextContainer(size: CGSize(width: largura, height: .greatestFiniteMagnitude))
        conteiner.lineFragmentPadding = 0
        gerente.addTextContainer(conteiner)
        armazem.addLayoutManager(gerente)
        gerente.ensureLayout(for: conteiner)
        return gerente.usedRect(for: conteiner).height
    }

    /// A quebra do Mac (`TextoDiagramado.diagramar`), com as mesmas regras de avanço.
    static func quebrarCT(_ texto: String, fonte: CTFont, largura: CGFloat, criarLinhas: Bool) -> [CTLine] {
        let utf16 = (texto as NSString).length
        let a = NSAttributedString(string: texto, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): fonte,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.white.cgColor,
        ])
        let tipografo = CTTypesetterCreateWithAttributedString(a as CFAttributedString)
        var linhas: [CTLine] = []
        var inicio = 0
        while inicio < utf16 {
            var n = CTTypesetterSuggestLineBreak(tipografo, inicio, Double(largura))
            if n <= 0 { n = max(1, CTTypesetterSuggestClusterBreak(tipografo, inicio, Double(largura))) }
            n = min(n, utf16 - inicio)
            if criarLinhas { linhas.append(CTTypesetterCreateLine(tipografo, CFRange(location: inicio, length: n))) }
            inicio += n
        }
        return linhas
    }

    static func pintar(_ linhas: ArraySlice<CTLine>, largura: CGFloat, alturaDaLinha L: CGFloat,
                       base: CGFloat, escala: CGFloat) -> CGImage? {
        let altura = CGFloat(linhas.count) * L
        let formato = UIGraphicsImageRendererFormat()
        formato.scale = escala
        formato.opaque = true
        let r = UIGraphicsImageRenderer(size: CGSize(width: largura, height: altura), format: formato)
        return r.image { c in
            let ctx = c.cgContext
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: largura, height: altura))
            ctx.translateBy(x: 0, y: altura)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            for (i, linha) in linhas.enumerated() {
                ctx.textPosition = CGPoint(x: 0, y: altura - (CGFloat(i) * L + base))
                CTLineDraw(linha, ctx)
            }
        }.cgImage
    }

    static func correr(largura W: CGFloat, altura H: CGFloat, escala: CGFloat, tamanhos: [Int]) {
        let w = (W * 0.8).rounded()
        dizer("vista \(Int(W))x\(Int(H)) @\(Int(escala))x, largura do texto \(Int(w)) pt (margem 0,1), semibold; "
              + "\(ProcessInfo.processInfo.processorCount) núcleos, iOS \(UIDevice.current.systemVersion)")
        for tamanhoDaFonte in [48.0, 96.0] as [CGFloat] {
            let f = UIFont.systemFont(ofSize: tamanhoDaFonte, weight: .semibold)
            let ct = f as CTFont
            let L = (f.lineHeight * 1.2 * escala).rounded() / escala
            for bytes in tamanhos {
                let texto = BancadaDoTeleprompter.sintetico(bytes)
                let a = atribuido(texto, fonte: f, linha: L)

                var altura: CGFloat = 0
                linha("tk1_sozinho", bytes, tamanhoDaFonte, cronometrar { altura = diagramarTK1(a, largura: w) },
                      "linhas=\(Int((altura / L).rounded()))")
                linha("tk1_sozinho_fundo", bytes, tamanhoDaFonte, cronometrar { noFundo { _ = diagramarTK1(a, largura: w) } })

                // O UITextView da vista de antes, fora da tela.
                var definir: [Double] = [], diagramar: [Double] = []
                var alturaDaVista: CGFloat = 0
                for _ in 0..<3 {
                    let tv: UITextView
                    if #available(iOS 16.0, *) { tv = UITextView(usingTextLayoutManager: false) } else { tv = UITextView() }
                    tv.frame = CGRect(x: 0, y: 0, width: W, height: H)
                    tv.isEditable = false
                    tv.textContainer.lineFragmentPadding = 0
                    tv.layoutManager.allowsNonContiguousLayout = false
                    tv.textContainerInset = UIEdgeInsets(top: H * 0.3, left: W * 0.1, bottom: H * 0.7, right: W * 0.1)
                    let t0 = CACurrentMediaTime()
                    tv.attributedText = a
                    let t1 = CACurrentMediaTime()
                    tv.layoutManager.ensureLayout(for: tv.textContainer)
                    let t2 = CACurrentMediaTime()
                    definir.append((t1 - t0) * 1000)
                    diagramar.append((t2 - t1) * 1000)
                    alturaDaVista = tv.layoutManager.usedRect(for: tv.textContainer).height
                }
                linha("tk1_vista_definir", bytes, tamanhoDaFonte, (definir[0], definir.sorted()[1]),
                      "altura=\(Int(alturaDaVista))")
                linha("tk1_vista_diagramar", bytes, tamanhoDaFonte, (diagramar[0], diagramar.sorted()[1]))

                if #available(iOS 16.0, *) {
                    // "Só a parte visível": o TextKit 2 dispõe a janela e **estima** o resto. Mede-se
                    // a janela (definir + primeiro layout), a altura estimada em cinco pontos do
                    // percurso — se ela muda enquanto rola, a fração do contrato muda junto —, e o
                    // layout inteiro, que é o preço de ter a altura exata.
                    for vez in 0..<2 {
                        let tv = UITextView(usingTextLayoutManager: true)
                        tv.frame = CGRect(x: 0, y: 0, width: W, height: H)
                        tv.isEditable = false
                        tv.textContainer.lineFragmentPadding = 0
                        tv.textContainerInset = UIEdgeInsets(top: H * 0.3, left: W * 0.1, bottom: H * 0.7, right: W * 0.1)
                        let t0 = CACurrentMediaTime()
                        tv.attributedText = a
                        tv.layoutIfNeeded()
                        let janela = (CACurrentMediaTime() - t0) * 1000
                        var est = [tv.contentSize.height]
                        for f in [0.25, 0.5, 0.75, 1.0] {
                            tv.contentOffset = CGPoint(x: 0, y: max(0, (tv.contentSize.height - H) * f))
                            tv.layoutIfNeeded()
                            est.append(tv.contentSize.height)
                        }
                        let t1 = CACurrentMediaTime()
                        var exata: CGFloat = 0
                        if let g = tv.textLayoutManager {
                            g.ensureLayout(for: g.documentRange)
                            exata = g.usageBoundsForTextContainer.height
                        }
                        let inteiro = (CACurrentMediaTime() - t1) * 1000
                        linha("tk2_vista_janela", bytes, tamanhoDaFonte, (janela, janela),
                              String(format: "vez=%d estimadas=%@ exata=%.0f inteiro_ms=%.1f conteiner=%.0fx%.0f",
                                     vez, est.map { String(format: "%.0f", $0) }.joined(separator: ","), exata,
                                     inteiro, tv.textContainer.size.width, tv.textContainer.size.height))
                    }
                }

                var linhas: [CTLine] = []
                linha("ct_quebra", bytes, tamanhoDaFonte,
                      cronometrar { linhas = quebrarCT(texto, fonte: ct, largura: w, criarLinhas: true) },
                      "linhas=\(linhas.count)")
                linha("ct_quebra_fundo", bytes, tamanhoDaFonte,
                      cronometrar { noFundo { _ = quebrarCT(texto, fonte: ct, largura: w, criarLinhas: true) } })
                linha("ct_so_quebra", bytes, tamanhoDaFonte,
                      cronometrar { _ = quebrarCT(texto, fonte: ct, largura: w, criarLinhas: false) })

                var alturaFrame: CGFloat = 0
                linha("ct_frame", bytes, tamanhoDaFonte, cronometrar {
                    let fs = CTFramesetterCreateWithAttributedString(a as CFAttributedString)
                    alturaFrame = CTFramesetterSuggestFrameSizeWithConstraints(
                        fs, CFRange(location: 0, length: 0), nil, CGSize(width: w, height: .greatestFiniteMagnitude), nil).height
                }, "altura=\(Int(alturaFrame))")
                // `boundingRect` cresce muito mais que linear (0,6 s em 10 KB, 5 s em 50 KB, 20 s em
                // 100 KB no iPhone X, medido na primeira corrida desta sonda): só no menor.
                if bytes == tamanhos.first {
                    linha("bounding", bytes, tamanhoDaFonte, cronometrar(1) {
                        _ = a.boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin], context: nil)
                    })
                }

                if bytes == tamanhos.first, !linhas.isEmpty {
                    // O desenho: um bloco de ~380 pt (a unidade que a vista do Mac pinta de uma vez)
                    // e uma tela inteira, na escala da tela.
                    let base = (L - (CTFontGetAscent(ct) + CTFontGetDescent(ct))) / 2 + CTFontGetAscent(ct)
                    for (nome, pontos) in [("pintar_bloco", 380.0), ("pintar_tela", Double(H))] {
                        let fatia = linhas.prefix(max(1, Int(CGFloat(pontos) / L)))
                        linha(nome, bytes, tamanhoDaFonte, cronometrar(5) {
                            _ = pintar(fatia, largura: w, alturaDaLinha: L, base: base, escala: escala)
                        }, "linhas=\(fatia.count) px=\(Int(w * escala))x\(Int(CGFloat(fatia.count) * L * escala))")
                        linha(nome + "_fundo", bytes, tamanhoDaFonte, cronometrar(5) {
                            noFundo { _ = pintar(fatia, largura: w, alturaDaLinha: L, base: base, escala: escala) }
                        })
                    }
                }
            }
        }
        dizer("fim")
    }
}
