import CoreGraphics
import CoreText
import XCTest
@testable import QuallTeleprompterKit

/// A "Fonte automática" e o texto centralizado entre as setas (`docs/teleprompter-ajustes-locais.md`
/// §3 e §5), pela mesma quebra do CoreText que a vista usa.
final class TestesDaFonteAutomatica: XCTestCase {

    private func fonte(_ t: CGFloat) -> CTFont { CTFontCreateWithName("Helvetica" as CFString, t, nil) }

    private func diagrama(_ texto: String, _ t: CGFloat, largura: CGFloat) -> TextoDiagramado {
        TextoDiagramado.diagramar(texto, fonte: fonte(t), cor: CGColor(gray: 1, alpha: 1), largura: largura)
    }

    private let prosa = String(repeating: "Boa noite a todos, hoje vamos falar de um assunto simples e bonito. ", count: 40)

    /// A resposta cumpre a regra, e a fonte um ponto acima não cumpre: é **a maior**.
    func test_a_maior_fonte_com_duas_palavras_por_linha() throws {
        let largura: CGFloat = 400
        let f = try XCTUnwrap(FonteAutomatica.maiorFonte(texto: prosa, largura: largura, criarFonte: fonte))
        XCTAssertGreaterThan(f, FonteAutomatica.menor)
        XCTAssertLessThan(f, FonteAutomatica.maior)
        XCTAssertTrue(FonteAutomatica.linhasComUmaPalavra(diagrama(prosa, f, largura: largura), texto: prosa).isEmpty)
        XCTAssertFalse(FonteAutomatica.linhasComUmaPalavra(diagrama(prosa, f + 1, largura: largura), texto: prosa).isEmpty,
                       "um ponto acima já deixa linha com uma palavra só: não é a maior")
    }

    /// Mais largura, fonte maior (a regra acompanha a coluna entre as setas).
    func test_coluna_mais_larga_da_fonte_maior() throws {
        let estreita = try XCTUnwrap(FonteAutomatica.maiorFonte(texto: prosa, largura: 300, criarFonte: fonte))
        let larga = try XCTUnwrap(FonteAutomatica.maiorFonte(texto: prosa, largura: 900, criarFonte: fonte))
        XCTAssertGreaterThan(larga, estreita)
    }

    /// A última linha de um parágrafo pode ficar com uma palavra: a viúva não derruba a fonte.
    func test_viuva_de_fim_de_paragrafo_nao_conta() {
        let texto = "Primeira frase do roteiro com várias palavras aqui.\nSegunda linha que termina em fim\n"
        let d = diagrama(texto, 60, largura: 700)
        for i in FonteAutomatica.linhasComUmaPalavra(d, texto: texto) {
            let ns = texto as NSString
            let inicio = d.geometria.inicios[i]
            let fim = i + 1 < d.geometria.inicios.count ? d.geometria.inicios[i + 1] : ns.length
            let trecho = ns.substring(with: NSRange(location: inicio, length: fim - inicio))
            XCTAssertFalse(trecho.hasSuffix("\n"), "linha de fim de parágrafo contou como defeito: \(trecho)")
        }
    }

    /// Uma palavra longa (12 letras ou mais) sozinha numa linha não conta; uma curta conta, **em
    /// qualquer fonte** — a primeira versão media meia largura, e em fonte grande "vamos" passava.
    func test_so_palavra_longa_sozinha_e_desculpada() {
        let largura: CGFloat = 360
        // Uma fonte em que "vamos falar" não cabe numa linha: "vamos" fica sozinha e é defeito.
        let curta = "noite a todos vamos falar hoje\n"
        let d = diagrama(curta, 90, largura: largura)
        let ruins = FonteAutomatica.linhasComUmaPalavra(d, texto: curta)
        let sozinhas = d.linhas.indices.filter { i in
            let ns = curta as NSString
            let fim = i + 1 < d.geometria.inicios.count ? d.geometria.inicios[i + 1] : ns.length
            let t = ns.substring(with: NSRange(location: d.geometria.inicios[i], length: fim - d.geometria.inicios[i]))
            return t.split(whereSeparator: { $0.isWhitespace }).count == 1 && !t.hasSuffix("\n")
        }
        XCTAssertFalse(sozinhas.isEmpty, "a fonte do teste tem de deixar uma palavra curta sozinha")
        XCTAssertEqual(ruins, sozinhas, "palavra curta sozinha tem de contar, mesmo ocupando meia largura")
        // A mesma situação com uma palavra longa, inteira na linha: desculpada.
        let longa = "responsabilidade seguimos\n"
        let dl = diagrama(longa, 40, largura: medida("responsabilidade", 40) + 4)
        XCTAssertEqual(dl.linhas.count, 2, "a palavra longa tem de ficar sozinha na primeira linha")
        XCTAssertTrue(FonteAutomatica.linhasComUmaPalavra(dl, texto: longa).isEmpty)
    }

    private func medida(_ s: String, _ t: CGFloat) -> CGFloat {
        let a = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): fonte(t)])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(a), nil, nil, nil))
    }

    /// Uma palavra que não cabe e sai partida conta contra a fonte, mesmo com pedaços de 12 letras
    /// ou mais — a primeira versão os desculpava como "palavra longa".
    func test_palavra_partida_no_meio_conta() {
        let texto = "anticonstitucionalissimamente e seguimos\n"
        let d = diagrama(texto, 40, largura: 360)
        XCTAssertGreaterThan(medida("anticonstitucionalissimamente", 40), 360, "o teste precisa partir a palavra")
        XCTAssertEqual(FonteAutomatica.linhasComUmaPalavra(d, texto: texto), [0])
        // E a fonte automática acha uma em que a palavra cabe inteira.
        let f = FonteAutomatica.maiorFonte(texto: texto, largura: 360, criarFonte: fonte)
        XCTAssertNotNil(f)
        XCTAssertLessThanOrEqual(medida("anticonstitucionalissimamente", f ?? 0), 360)
    }

    /// Travessão sozinho não é palavra, e pontuação não é letra.
    func test_travessao_nao_e_palavra_e_pontuacao_nao_e_letra() {
        let travessao = "— vamos falar hoje\n"
        let dt = diagrama(travessao, 40, largura: medida("— vamos", 40) + 4)
        XCTAssertEqual(FonteAutomatica.linhasComUmaPalavra(dt, texto: travessao), [0],
                       "\"— vamos\" tem uma palavra só")
        // "comunicação," tem 11 letras e 12 caracteres: não é palavra longa.
        let virgula = "comunicação, seguimos\n"
        let dv = diagrama(virgula, 40, largura: medida("comunicação,", 40) + 4)
        XCTAssertEqual(FonteAutomatica.linhasComUmaPalavra(dv, texto: virgula), [0])
    }

    /// Só palavras isoladas por quebra dura: toda linha é fim de parágrafo, a regra vale em qualquer
    /// fonte, e a resposta é a maior. Texto vazio não tem resposta (quem chama mantém a fonte).
    func test_so_fins_de_paragrafo_da_a_maior_e_vazio_da_nil() {
        let texto = "a\nb\nc\nd\ne\n"
        // Toda linha é fim de parágrafo: a regra está cumprida em qualquer fonte, e a maior vale.
        XCTAssertEqual(FonteAutomatica.maiorFonte(texto: texto, largura: 400, criarFonte: fonte), FonteAutomatica.maior)
        XCTAssertNil(FonteAutomatica.maiorFonte(texto: "", largura: 400, criarFonte: fonte))
    }

    /// Centralizado: cada linha tem o recuo que a põe no meio da coluna.
    func test_linhas_centralizadas_na_coluna() {
        let texto = "curta\numa linha bem mais comprida que a primeira\n"
        let largura: CGFloat = 600
        let d = diagrama(texto, 20, largura: largura)
        XCTAssertEqual(d.recuos.count, d.linhas.count)
        for (i, linha) in d.linhas.enumerated() {
            let visivel = TextoDiagramado.larguraVisivel(de: linha)
            XCTAssertEqual(d.recuos[i] * 2 + visivel, largura, accuracy: 2, "linha \(i) fora do centro")
        }
        XCTAssertGreaterThan(d.recuos[0], d.recuos[1], "a linha curta recua mais")
        let semCentro = TextoDiagramado.diagramar(texto, fonte: fonte(20), cor: CGColor(gray: 1, alpha: 1),
                                                  largura: largura, centralizar: false)
        XCTAssertEqual(semCentro.recuos, [0, 0])
    }
}
