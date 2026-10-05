import Foundation

/// **A regra da "Fonte automática"** (`docs/teleprompter-ajustes-locais.md` §5), sem CoreText nem
/// UIKit: testada no MacBook por `Testes/rodar.sh`.
///
/// Pedido literal: "opção redimensionamento automático do tamanho da fonte com mais de uma palavra
/// na linha"; resposta do usuário: pelo menos 2 palavras por linha. Ligada, vale **a maior fonte em
/// que nenhuma linha fica com uma palavra só**, com duas exceções que não contam:
///
/// - a **última linha de um parágrafo** (a palavra que sobra no fim);
/// - a linha cuja única palavra é **longa, com 12 letras ou mais** ("responsabilidade",
///   "desenvolvimento").
///
/// **A exceção não depende da fonte** (correção de 14/09): a primeira versão (Mac) dizia "mais de
/// meia largura", e em fonte grande quase toda palavra ocupa meia largura — "vamos" ficou sozinha
/// numa linha. Contam-se as letras da palavra, no texto.
///
/// **As três definições, iguais nas quatro telas** (alinhadas em 14/09, §5):
///
/// - **palavra** é um trecho sem espaço com pelo menos uma letra ou algarismo. Um travessão ou
///   reticências sozinhos não contam, e "— vamos" é uma palavra só; uma linha só com eles, ou em
///   branco, não tem palavra nenhuma, e não conta;
/// - as **letras** de uma palavra são só as letras: "comunicação," tem 11;
/// - uma linha que **acaba no meio de uma palavra** (o motor a partiu por não caber) conta contra a
///   fonte, mesmo com um pedaço de 12 letras ou mais. "No meio" é a quebra cair dentro de um trecho
///   sem espaço — o que inclui a quebra depois de um hífen ("segunda-|feira"), pela mesma definição.
enum RegraDaFonteAutomatica {
    static let minimo = 8.0
    static let maximo = 400.0
    /// Quantas letras faz uma palavra longa.
    static let letrasDaPalavraLonga = 12

    /// Como uma linha fica diante da regra.
    enum Linha: Equatable {
        /// Duas palavras ou mais, ou nenhuma (linha em branco, ou só "—" ou "…").
        case ok
        /// Uma palavra só, na última linha do parágrafo: não conta.
        case fimDeParagrafo
        /// Uma palavra só, de 12 letras ou mais: não conta.
        case palavraLonga
        /// Uma palavra só, curta, no meio do parágrafo: **violação**.
        case sozinha
        /// A linha acaba no meio de uma palavra: **violação**, mesmo com um pedaço de 12 letras ou mais.
        case partida

        var violacao: Bool { self == .sozinha || self == .partida }
    }

    /// A linha `i` da tabela, diante da regra.
    ///
    /// - `inicios`: onde cada linha começa (UTF-16), a tabela do diagrama.
    /// - `texto`: o texto diagramado (os índices são dele). Pode ser só **o começo** do roteiro (a
    ///   amostra de `MotorDaFonteAutomatica`, cortada no fim de um parágrafo): a quebra é gulosa a
    ///   partir do início, então as linhas do começo são as mesmas do roteiro inteiro.
    static func linha(_ i: Int, inicios: [Int], texto: NSString) -> Linha {
        let n = inicios.count
        let fim = texto.length
        let a = inicios[i]
        let b = i + 1 < n ? inicios[i + 1] : fim
        guard b > a else { return .ok }
        let espacos = CharacterSet.whitespacesAndNewlines
        // Metade de um par substituto (emoji) não é espaço: é pedaço de trecho.
        func espaco(_ k: Int) -> Bool { Unicode.Scalar(texto.character(at: k)).map { espacos.contains($0) } ?? false }
        // Partida: a quebra cai dentro de um trecho sem espaço — o último caractere da linha e o
        // primeiro da seguinte não são espaço. Vem antes da exceção da palavra longa.
        if b < fim, !espaco(b - 1), !espaco(b) { return .partida }
        var x = a, y = b
        while x < y, espaco(x) { x += 1 }
        while y > x, espaco(y - 1) { y -= 1 }
        guard y > x else { return .ok }
        let palavras = texto.substring(with: NSRange(location: x, length: y - x))
            .components(separatedBy: espacos).filter(ehPalavra)
        // Nenhuma (só pontuação) ou duas e mais.
        guard palavras.count == 1 else { return .ok }
        // Última linha do parágrafo: termina em quebra dura, ou no fim do texto.
        if b == fim { return .fimDeParagrafo }
        let ultimo = texto.character(at: b - 1)
        if ultimo == 0x0A || ultimo == 0x0D || ultimo == 0x2029 || ultimo == 0x2028 { return .fimDeParagrafo }
        if letras(palavras[0]) >= letrasDaPalavraLonga { return .palavraLonga }
        return .sozinha
    }

    /// Um trecho sem espaço é palavra se tem pelo menos uma letra ou algarismo.
    static func ehPalavra(_ trecho: String) -> Bool {
        trecho.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    /// As letras de uma palavra (pontuação, algarismos e emoji não contam).
    static func letras(_ palavra: String) -> Int {
        palavra.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }

    /// A primeira linha que viola a regra, ou `nil`.
    static func violacao(inicios: [Int], texto: NSString) -> Int? {
        for i in 0..<inicios.count where linha(i, inicios: inicios, texto: texto).violacao { return i }
        return nil
    }

    /// A maior fonte, de ``minimo`` a ``maximo`` em passos de 1 pt, em que `passa` é verdade — busca
    /// binária, supondo que `passa` é verdade até um ponto e falsa daí para cima (quanto maior a
    /// fonte, menos palavras cabem por linha). Devolve também quantas fontes foram provadas.
    /// `passa(minimo)` falso devolve o mínimo: não há fonte menor para oferecer.
    static func maior(passa: (Double) -> Bool) -> (fonte: Double, provas: Int) {
        var baixo = Int(minimo), alto = Int(maximo), provas = 0
        while baixo < alto {
            let meio = (baixo + alto + 1) / 2
            provas += 1
            if passa(Double(meio)) { baixo = meio } else { alto = meio - 1 }
        }
        return (Double(baixo), provas)
    }
}
