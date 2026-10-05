import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// **O roteiro quebrado em linhas pelo CoreText, fora da thread principal.**
///
/// # Por que CoreText, e não o TextKit que a vista usava
///
/// Medido na sonda de pilhas (`SondaDePilhas`, 14/09/2026), com o mesmo roteiro, a mesma fonte e a
/// mesma largura, no iPhone X (iOS 16.7) e no iPhone 7 (iOS 15.8):
///
/// | 100 KB, fonte 48 | iPhone X | iPhone 7 |
/// |---|---|---|
/// | TextKit 1 inteiro (o `attributedText` do `UITextView` já faz o layout todo) | 198 ms | 215 ms |
/// | o mesmo TextKit 1, **noutra thread** | 199 ms | 214 ms |
/// | CoreText, só os pontos de quebra (o que este tipo faz) | 34 ms | 45 ms |
/// | CoreText, quebra + `CTLine` de todas as linhas (o `TextoDiagramado` do Mac) | 54 ms | 68 ms |
///
/// O TextKit 1 custa o mesmo fora da principal: tirá-lo de lá deixaria o texto novo 200–400 ms
/// atrás e ainda pediria outra vista para desenhar, porque o `UITextView` refaz o layout dele na
/// principal. O CoreText quebra o mesmo texto no mesmo número de linhas (9528 nos dois, a 48 pt; no
/// máximo uma linha de diferença em 20 mil, a 96 pt — a altura bate com o `usedRect` do TextKit) em
/// um quarto do tempo, e é seguro fora da principal. O Mac já faz assim
/// (`QuallTeleprompterKit/TextoDiagramado.swift`, 8–18 ms num M4).
///
/// # Só os índices, e as linhas sob demanda
///
/// A quebra guarda onde cada linha começa (`LinhasDoRoteiro`) e o `CTTypesetter`; a `CTLine` de
/// uma linha só é criada quando o bloco dela vai ser pintado (~2 µs por linha). Guardar as linhas
/// todas seria pagar 20 ms a mais por layout e, na fonte máxima (400 pt, um caractere por linha),
/// dezenas de MB de `CTLine` que nunca aparecem.
///
/// # A regra de thread
///
/// O Core Text pede que um objeto de layout (`CTTypesetter`, `CTLine`) seja usado por uma thread de
/// cada vez. Este diagrama é **montado** inteiro na fila do diagrama e só depois **entregue** à
/// principal, que passa a ser a única a usá-lo; um diagrama novo tem o seu próprio tipógrafo.
/// Nunca há duas threads no mesmo objeto.
final class DiagramaDoRoteiro {
    /// O pedido a que ele responde: a vista descarta um diagrama que chega depois de um pedido mais
    /// novo.
    let geracao: Int
    let tabela: LinhasDoRoteiro
    /// A largura da coluna de texto (a vista menos as margens), em pontos.
    let largura: CGFloat
    /// A linha de base de uma linha, a partir do topo da caixa dela: o glifo fica centrado na
    /// altura da linha, que é onde o marcador da linha de leitura aponta.
    let base: CGFloat
    let fonte: Double
    let bytes: Int
    /// Quanto a quebra levou, em ms, **na fila do diagrama** — não na principal.
    let custoMs: Double
    private let tipografo: CTTypesetter?
    private let comprimentoUTF16: Int

    private init(geracao: Int, tabela: LinhasDoRoteiro, largura: CGFloat, base: CGFloat, fonte: Double, bytes: Int,
                 custoMs: Double, tipografo: CTTypesetter?, comprimentoUTF16: Int) {
        self.geracao = geracao
        self.tabela = tabela
        self.largura = largura
        self.base = base
        self.fonte = fonte
        self.bytes = bytes
        self.custoMs = custoMs
        self.tipografo = tipografo
        self.comprimentoUTF16 = comprimentoUTF16
    }

    /// Quebra `texto` em linhas de `largura` pontos. `deveParar` é consultado a cada poucas centenas
    /// de linhas: um pedido mais novo (a fonte mudando degrau a degrau num controle deslizante) faz
    /// este desistir, e devolve `nil`.
    static func diagramar(_ texto: String, fonte: CTFont, tamanho: Double, largura: CGFloat, alturaDaLinha: Double,
                          geracao: Int, deveParar: () -> Bool = { false }) -> DiagramaDoRoteiro? {
        let comeco = CACurrentMediaTime()
        let ascendente = CTFontGetAscent(fonte)
        let descendente = CTFontGetDescent(fonte)
        let base = (CGFloat(alturaDaLinha) - (ascendente + descendente)) / 2 + ascendente
        let larguraUtil = max(1, largura)
        let bytes = texto.utf8.count
        let utf16 = (texto as NSString).length
        guard utf16 > 0 else {
            return DiagramaDoRoteiro(geracao: geracao, tabela: LinhasDoRoteiro(inicios: [], alturaDaLinha: alturaDaLinha),
                                     largura: larguraUtil, base: base, fonte: tamanho, bytes: 0, custoMs: 0,
                                     tipografo: nil, comprimentoUTF16: 0)
        }
        let atribuido = NSAttributedString(string: texto, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): fonte,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let tipografo = CTTypesetterCreateWithAttributedString(atribuido as CFAttributedString)
        var inicios: [Int] = []
        inicios.reserveCapacity(utf16 / 12 + 1)
        var inicio = 0
        while inicio < utf16 {
            if inicios.count & 255 == 255, deveParar() { return nil }
            var n = CTTypesetterSuggestLineBreak(tipografo, inicio, Double(larguraUtil))
            if n <= 0 {
                // Nem um caractere cabe (largura ínfima): um agrupamento por linha, nunca um laço sem fim.
                n = max(1, CTTypesetterSuggestClusterBreak(tipografo, inicio, Double(larguraUtil)))
            }
            inicios.append(inicio)
            inicio += min(n, utf16 - inicio)
        }
        // Um roteiro que termina em quebra **não** ganha a linha em branco depois dela (a mesma
        // regra do Mac): com ela, a posição 1 deixaria a última linha escrita acima da leitura.
        return DiagramaDoRoteiro(geracao: geracao, tabela: LinhasDoRoteiro(inicios: inicios, alturaDaLinha: alturaDaLinha),
                                 largura: larguraUtil, base: base, fonte: tamanho, bytes: bytes,
                                 custoMs: (CACurrentMediaTime() - comeco) * 1000, tipografo: tipografo,
                                 comprimentoUTF16: utf16)
    }

    /// As `CTLine` das linhas `faixa`, para pintar um bloco. **Só na principal**, depois da entrega.
    func linhas(_ faixa: Range<Int>) -> [CTLine] {
        guard let tipografo else { return [] }
        let inicios = tabela.inicios
        return faixa.clamped(to: 0..<inicios.count).map { i in
            let fim = i + 1 < inicios.count ? inicios[i + 1] : comprimentoUTF16
            return CTTypesetterCreateLine(tipografo, CFRange(location: inicios[i], length: fim - inicios[i]))
        }
    }

    /// O texto das linhas `faixa`, para quem lê com o VoiceOver.
    func textoDas(_ faixa: Range<Int>, em texto: String) -> String {
        let ns = texto as NSString
        let inicios = tabela.inicios
        let f = faixa.clamped(to: 0..<inicios.count)
        guard let a = f.first, let z = f.last else { return "" }
        let fim = z + 1 < inicios.count ? inicios[z + 1] : min(comprimentoUTF16, ns.length)
        guard inicios[a] < fim, fim <= ns.length else { return "" }
        return ns.substring(with: NSRange(location: inicios[a], length: fim - inicios[a]))
    }
}

/// Um bloco de linhas, pintado uma vez (a unidade que o Mac também usa). Fundo preto opaco: o texto
/// sai com o antisserrilhado de fundo conhecido, e a composição não mistura transparência.
///
/// **Cada linha centrada na coluna** ("Alinhamento — centralizado", `docs/teleprompter-ajustes-
/// locais.md` §3: fixo, não é opção): a linha começa em `(coluna − largura dela sem o espaço do
/// fim) / 2`.
final class BlocoDoRoteiro: CALayer {
    var linhas: [CTLine] = []
    var alturaDaLinha: CGFloat = 1
    var base: CGFloat = 0
    /// A largura da coluna de texto, em pontos (o bloco tem 2 pt a mais, 1 de cada lado).
    var larguraDaColuna: CGFloat = 0

    override init() {
        super.init()
        isOpaque = true
        backgroundColor = CGColor(gray: 0, alpha: 1)
        needsDisplayOnBoundsChange = false
        actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "onOrderIn": NSNull(),
                   "onOrderOut": NSNull(), "sublayers": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let outro = layer as? BlocoDoRoteiro {
            linhas = outro.linhas
            alturaDaLinha = outro.alturaDaLinha
            base = outro.base
            larguraDaColuna = outro.larguraDaColuna
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("só por código") }

    override func draw(in ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(bounds)
        // A camada do iOS desenha com y para baixo; o CoreText, com y para cima.
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        for (i, linha) in linhas.enumerated() {
            let w = CGFloat(CTLineGetTypographicBounds(linha, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(linha))
            let x = 1 + max(0, (larguraDaColuna - w) / 2)
            ctx.textPosition = CGPoint(x: x, y: bounds.height - (CGFloat(i) * alturaDaLinha + base))
            CTLineDraw(linha, ctx)
        }
    }
}
