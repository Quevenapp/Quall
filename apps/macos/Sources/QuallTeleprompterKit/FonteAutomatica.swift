import CoreGraphics
import CoreText
import Foundation

/// **A "Fonte automática"** do prompter (`docs/teleprompter-ajustes-locais.md` §5): a maior fonte
/// em que nenhuma linha fica com uma palavra só — pedido do usuário em 14/09, "com mais de uma
/// palavra na linha", resposta "pelo menos 2 palavras".
///
/// Duas linhas de uma palavra **não** contam contra a fonte:
/// - a **última linha de um parágrafo** (a palavra que sobrou no fim), senão toda fonte grande
///   perderia para uma viúva;
/// - a linha cuja única palavra é **longa**: `letrasDaPalavraLonga` letras ou mais
///   ("responsabilidade", "desenvolvimento"). A primeira versão media "mais de meia largura", e isso
///   **dependia da fonte**: em fonte grande quase toda palavra ocupa meia largura, a exceção engolia a
///   regra e "vamos" ficava sozinha numa linha (visto na captura da janela do Mac, 14/09).
///
/// E três definições, iguais nas quatro telas (`docs/teleprompter-ajustes-locais.md` §5):
/// - **palavra** é um trecho sem espaço com pelo menos uma letra ou algarismo — um travessão ou
///   reticências sozinhos não fazem a linha "ter duas palavras";
/// - as **letras** de uma palavra são só as letras: a pontuação grudada e os algarismos não contam;
/// - uma linha que **acaba no meio de uma palavra** (o motor a partiu porque ela não cabia) conta
///   contra a fonte, senão um pedaço de 12 letras passaria por palavra longa numa fonte enorme.
///
/// A quebra é a mesma da vista (`TextoDiagramado`), então a regra conferida é a da tela.
public enum FonteAutomatica {
    public static let menor: CGFloat = 8
    public static let maior: CGFloat = 400
    /// A partir de quantas letras uma palavra sozinha numa linha não conta contra a fonte.
    public static let letrasDaPalavraLonga = 12

    /// As linhas que violam a regra, num diagrama já feito. Vazio = a fonte serve.
    public static func linhasComUmaPalavra(_ d: TextoDiagramado, texto: String) -> [Int] {
        let ns = texto as NSString
        let inicios = d.geometria.inicios
        var ruins: [Int] = []
        for i in d.linhas.indices {
            let inicio = inicios[i]
            let fim = i + 1 < inicios.count ? inicios[i + 1] : ns.length
            // Palavra partida: a linha acaba sem espaço e a seguinte começa sem espaço.
            if fim > inicio, fim < ns.length, !eEspaco(ns.character(at: fim - 1)), !eEspaco(ns.character(at: fim)) {
                ruins.append(i)
                continue
            }
            let trecho = ns.substring(with: NSRange(location: inicio, length: fim - inicio))
            let palavras = trecho.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .filter { $0.contains { $0.isLetter || $0.isNumber } }
            guard palavras.count == 1 else { continue }
            // Fim de parágrafo: a linha termina em quebra dura, ou é a última do texto.
            let fimDeParagrafo = fim >= ns.length || trecho.last.map { $0.isNewline } == true
            if fimDeParagrafo { continue }
            if palavras[0].filter(\.isLetter).count >= letrasDaPalavraLonga { continue }
            ruins.append(i)
        }
        return ruins
    }

    private static func eEspaco(_ c: unichar) -> Bool {
        guard let u = UnicodeScalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(u)
    }

    /// A maior fonte, em pontos inteiros, entre `menor` e `maior`, em que o texto cumpre a regra
    /// na `largura` dada. `nil` se nem a menor cumpre (o texto é feito de palavras isoladas por
    /// quebra dura, por exemplo) — quem chama mantém a fonte que está.
    ///
    /// Busca binária: a regra é monótona na prática (fonte maior, linhas mais curtas em palavras). O
    /// custo é ~9 diagramas do texto inteiro; quem chama roda isto **fora** da thread principal.
    /// `deveParar` corta a busca quando um pedido mais novo chegou.
    public static func maiorFonte(texto: String, largura: CGFloat,
                                  criarFonte: (CGFloat) -> CTFont,
                                  deveParar: () -> Bool = { false }) -> CGFloat? {
        guard !texto.isEmpty, largura > 1 else { return nil }
        let cor = CGColor(gray: 1, alpha: 1)
        func serve(_ f: CGFloat) -> Bool {
            let d = TextoDiagramado.diagramar(texto, fonte: criarFonte(f), cor: cor, largura: largura)
            return linhasComUmaPalavra(d, texto: texto).isEmpty
        }
        var baixo = menor
        guard serve(baixo) else { return nil }
        var alto = maior
        if serve(alto) { return alto }
        // Invariante: `baixo` serve, `alto` não.
        while alto - baixo > 1 {
            if deveParar() { return nil }
            let meio = ((baixo + alto) / 2).rounded(.down)
            if serve(meio) { baixo = meio } else { alto = meio }
        }
        return baixo
    }
}
