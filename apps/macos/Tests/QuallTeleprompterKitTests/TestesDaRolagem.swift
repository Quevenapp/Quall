import CoreGraphics
import CoreText
import XCTest
@testable import QuallTeleprompterKit

/// A rolagem em velocidade constante, a posição do contrato e a quebra de linhas do CoreText.
final class TestesDaRolagem: XCTestCase {

    private func geometria(linhas: Int, altura: Double = 60) -> GeometriaDoTexto {
        GeometriaDoTexto(alturaDaLinha: altura, inicios: (0..<linhas).map { $0 * 10 }, comprimentoUTF16: linhas * 10)
    }

    /// 0 = o centro da primeira linha na leitura; 1 = o centro da última (§3).
    func test_posicao_e_fracao_do_percurso() {
        let g = geometria(linhas: 101)
        XCTAssertEqual(g.percurso, 6000)
        XCTAssertEqual(g.deslocamento(paraPosicao: 0), 0)
        XCTAssertEqual(g.deslocamento(paraPosicao: 1), 6000)
        XCTAssertEqual(g.deslocamento(paraPosicao: 0.5), 3000)
        XCTAssertEqual(g.posicao(paraDeslocamento: 1500), 0.25)
        XCTAssertEqual(g.posicao(paraDeslocamento: -5), 0)
        XCTAssertEqual(g.posicao(paraDeslocamento: 9e9), 1)
        XCTAssertEqual(g.deslocamento(paraPosicao: .nan), 0)
        XCTAssertEqual(geometria(linhas: 1).percurso, 0, "uma linha só não tem percurso")
        XCTAssertEqual(geometria(linhas: 1).posicao(paraDeslocamento: 10), 0)
    }

    /// **Velocidade constante**: a distância andada é `velocidade × altura × tempo`, qualquer que
    /// seja a cadência dos quadros — 60 Hz regulares, 120 Hz, ou quadros irregulares.
    func test_velocidade_constante_independe_da_cadencia() {
        let g = geometria(linhas: 10_000)
        for dts in [Array(repeating: 1.0 / 60, count: 600),
                    Array(repeating: 1.0 / 120, count: 1200),
                    (0..<600).map { $0 % 3 == 0 ? 0.030 : 0.0075 } + [0.0]] {
            var r = Rolagem()
            var tempo = 0.0
            for dt in dts {
                r.avancar(dt: dt, velocidade: 2.5, geometria: g)
                tempo += dt
            }
            XCTAssertEqual(r.deslocamento, 2.5 * 60 * tempo, accuracy: 1e-6)
        }
    }

    /// Um quadro que chega depois de o Mac acordar não arrasta o texto meia página.
    func test_dt_grande_e_limitado() {
        var r = Rolagem()
        r.avancar(dt: 30, velocidade: 1, geometria: geometria(linhas: 1000))
        XCTAssertEqual(r.deslocamento, Rolagem.dtMaximo * 60, accuracy: 1e-9)
    }

    /// Chega ao fim uma vez só, e para nele.
    func test_para_no_fim_e_avisa_uma_vez() {
        let g = geometria(linhas: 3)   // percurso 120
        var r = Rolagem()
        XCTAssertFalse(r.avancar(dt: 0.2, velocidade: 5, geometria: g))   // 60
        XCTAssertTrue(r.avancar(dt: 0.2, velocidade: 5, geometria: g))    // 120: chegou
        XCTAssertFalse(r.avancar(dt: 0.2, velocidade: 5, geometria: g), "já estava no fim")
        XCTAssertEqual(r.deslocamento, 120)
        XCTAssertTrue(r.noFim(g))
        var vazia = Rolagem()
        XCTAssertFalse(vazia.avancar(dt: 0.2, velocidade: 5, geometria: .vazia), "sem texto não há fim a avisar")
    }

    /// **Para trás** ("segurar para rolar", §12.5): a mesma velocidade constante, no sentido
    /// contrário, qualquer que seja a cadência — e o mesmo teto de `dt`.
    func test_para_tras_na_mesma_velocidade() {
        let g = geometria(linhas: 10_000)
        let a60: [Double] = Array(repeating: 1.0 / 60, count: 600)
        let a120: [Double] = Array(repeating: 1.0 / 120, count: 1200)
        let irregular: [Double] = (0..<600).map { (i: Int) -> Double in i % 3 == 0 ? 0.030 : 0.0075 }
        for dts in [a60, a120, irregular] {
            var r = Rolagem(deslocamento: 300_000)
            var tempo = 0.0
            for dt in dts {
                r.recuar(dt: dt, velocidade: 2.5, geometria: g)
                tempo += dt
            }
            XCTAssertEqual(r.deslocamento, 300_000 - 2.5 * 60 * tempo, accuracy: 1e-6)
        }
        var r = Rolagem(deslocamento: 3000)
        r.recuar(dt: 30, velocidade: 1, geometria: g)
        XCTAssertEqual(r.deslocamento, 3000 - Rolagem.dtMaximo * 60, accuracy: 1e-9, "o dt é limitado nos dois sentidos")
    }

    /// Para no começo, avisa uma vez só, e fica lá: quem chama não muda `rolando` (§12.5).
    func test_para_tras_para_no_comeco_e_avisa_uma_vez() {
        let g = geometria(linhas: 3)   // percurso 120
        var r = Rolagem(deslocamento: 90)
        XCTAssertFalse(r.recuar(dt: 0.2, velocidade: 5, geometria: g))    // 30
        XCTAssertTrue(r.recuar(dt: 0.2, velocidade: 5, geometria: g))     // 0: chegou
        XCTAssertFalse(r.recuar(dt: 0.2, velocidade: 5, geometria: g), "já estava no começo")
        XCTAssertEqual(r.deslocamento, 0)
        XCTAssertTrue(r.noComeco)
        // Do fim para trás: sai do fim no primeiro passo.
        var doFim = Rolagem(deslocamento: 120)
        XCTAssertTrue(doFim.noFim(g))
        doFim.recuar(dt: 0.1, velocidade: 1, geometria: g)
        XCTAssertFalse(doFim.noFim(g))
        XCTAssertEqual(doFim.deslocamento, 114, accuracy: 1e-9)
        // Um deslocamento além do percurso (o texto encolheu) recua a partir do fim, não de fora.
        var alem = Rolagem(deslocamento: 500)
        alem.recuar(dt: 0.1, velocidade: 1, geometria: g)
        XCTAssertEqual(alem.deslocamento, 114, accuracy: 1e-9)
        var vazia = Rolagem()
        XCTAssertFalse(vazia.recuar(dt: 0.2, velocidade: 5, geometria: .vazia), "sem texto não há começo a avisar")
    }

    /// Trocar a fonte não tira quem lê do lugar: o caractere na linha de leitura continua nela.
    func test_o_ponto_de_leitura_sobrevive_ao_relayout() {
        // Antes: linhas de 10 caracteres, 60 pt. Depois: linhas de 25 caracteres, 90 pt.
        let antes = GeometriaDoTexto(alturaDaLinha: 60, inicios: stride(from: 0, to: 1000, by: 10).map { $0 },
                                     comprimentoUTF16: 1000)
        let depois = GeometriaDoTexto(alturaDaLinha: 90, inicios: stride(from: 0, to: 1000, by: 25).map { $0 },
                                      comprimentoUTF16: 1000)
        let d = 40.2 * 60  // entre a linha 40 e a 41, perto da 40: caractere 400
        let ponto = antes.pontoDeLeitura(noDeslocamento: d)
        XCTAssertEqual(ponto.caractere, 400)
        XCTAssertEqual(ponto.fracao, 0.2, accuracy: 1e-9)
        let novo = depois.deslocamento(paraPonto: ponto)
        XCTAssertEqual(depois.linha(doCaractere: 400), 16)
        XCTAssertEqual(novo, (16 + 0.2) * 90, accuracy: 1e-9)
        // Um texto que encolheu: o ponto cai na última linha, sem passar do fim.
        let curta = GeometriaDoTexto(alturaDaLinha: 60, inicios: [0, 10, 20], comprimentoUTF16: 30)
        XCTAssertEqual(curta.deslocamento(paraPonto: (5000, 0.4)), curta.percurso)
    }

    func test_linhas_visiveis() {
        let g = geometria(linhas: 100)
        // Leitura a 300 pt do topo, janela de 900 pt, deslocamento 0: a linha 0 está centrada em 300.
        let r = g.linhasVisiveis(deslocamento: 0, yLeitura: 300, alturaVisivel: 900)
        XCTAssertEqual(r.lowerBound, 0)
        XCTAssertEqual(r.upperBound, 11)   // até 900 pt: (900 − 270) / 60 = 10,5 → 11
        let depois = g.linhasVisiveis(deslocamento: 3000, yLeitura: 300, alturaVisivel: 900)
        XCTAssertEqual(depois.lowerBound, 45)
        XCTAssertTrue(depois.contains(50), "a linha 50 está na leitura com deslocamento 3000")
    }

    // MARK: - CoreText

    private let branco = CGColor(gray: 1, alpha: 1)

    /// Um roteiro de 128 KiB com acento e emoji: cada caractere cai em exatamente uma linha, as
    /// linhas cabem na largura, e as quebras duras viram linhas.
    func test_quebra_um_roteiro_grande_sem_perder_caractere() {
        var roteiro = ""
        var i = 0
        while roteiro.utf8.count < 128 * 1024 - 200 {
            roteiro += "Linha \(i): boa noite, ação e emoção no teleprompter. 🎬\n"
            if i % 17 == 0 { roteiro += "\n" }
            i += 1
        }
        let fonte = CTFontCreateUIFontForLanguage(.system, 48, nil)!
        let d = TextoDiagramado.diagramar(roteiro, fonte: fonte, cor: branco, largura: 900)
        let g = d.geometria
        XCTAssertEqual(d.linhas.count, g.quantasLinhas)
        XCTAssertEqual(g.inicios.first, 0)
        XCTAssertEqual(g.comprimentoUTF16, (roteiro as NSString).length)
        // Crescente e sem buraco: a linha k termina onde a k+1 começa.
        var soma = 0
        for (k, linha) in d.linhas.enumerated() {
            let faixa = CTLineGetStringRange(linha)
            XCTAssertEqual(faixa.location, g.inicios[k])
            soma += faixa.length
            let largura = CTLineGetTypographicBounds(linha, nil, nil, nil)
                - CTLineGetTrailingWhitespaceWidth(linha)
            XCTAssertLessThanOrEqual(largura, 900.5, "linha \(k) passa da largura")
        }
        XCTAssertEqual(soma, g.comprimentoUTF16, "todo caractere em exatamente uma linha")
        XCTAssertGreaterThan(g.quantasLinhas, i, "as linhas em branco do roteiro também são linhas")
        XCTAssertLessThan(d.custoMs, 2_000, "a quebra de 128 KiB levou \(d.custoMs) ms")
    }

    func test_linha_em_branco_e_quebra_final() {
        let fonte = CTFontCreateUIFontForLanguage(.system, 20, nil)!
        XCTAssertEqual(TextoDiagramado.diagramar("a\n\nb", fonte: fonte, cor: branco, largura: 500)
                        .geometria.quantasLinhas, 3)
        XCTAssertEqual(TextoDiagramado.diagramar("a\nb\n", fonte: fonte, cor: branco, largura: 500)
                        .geometria.quantasLinhas, 2, "o \\n final não cria uma linha vazia no fim")
        XCTAssertEqual(TextoDiagramado.diagramar("", fonte: fonte, cor: branco, largura: 500)
                        .geometria.quantasLinhas, 0)
    }

    /// A altura da linha é a da fonte (a unidade da velocidade), e cresce com ela.
    func test_altura_da_linha_acompanha_a_fonte() {
        let pequena = TextoDiagramado.diagramar("x", fonte: CTFontCreateUIFontForLanguage(.system, 24, nil)!,
                                                cor: branco, largura: 500)
        let grande = TextoDiagramado.diagramar("x", fonte: CTFontCreateUIFontForLanguage(.system, 96, nil)!,
                                               cor: branco, largura: 500)
        XCTAssertGreaterThan(grande.geometria.alturaDaLinha, 3.5 * pequena.geometria.alturaDaLinha)
        XCTAssertGreaterThan(pequena.baseDesdeOTopo, 0)
        XCTAssertLessThan(pequena.baseDesdeOTopo, CGFloat(pequena.geometria.alturaDaLinha))
    }
}
