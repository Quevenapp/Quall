import Foundation

// ================================================================================================
// "A pergunta do texto", no controle (`docs/contrato-teleprompter.md` §11.2–§11.7 e §11.10)
//
// A decisão do usuário (13/09), literal: "um controle que conecta num prompter que não é o da última
// vez, com roteiro diferente: pergunta uma vez ('usar o do prompter ou mandar o meu') e guarda cópia
// do que sair." Em 14/09: "pode seguir com a pergunta do texto".
//
// **A parte pura**: o que vem no estado, a contagem de palavras e o que a caixa mostra — sem núcleo
// nem UIKit, testada no MacBook por `Testes/rodar.sh`. Os textos da tela são os literais do pedido,
// iguais nas quatro telas.
// ================================================================================================

/// Um dos dois textos da pergunta (`"meu"`, `"do_prompter"`): tamanho, resumo e os primeiros até
/// 240 bytes.
struct VistaDoTexto: Decodable, Equatable {
    var bytes = 0
    var resumo = ""
    var previa = ""

    init(bytes: Int = 0, resumo: String = "", previa: String = "") {
        self.bytes = bytes; self.resumo = resumo; self.previa = previa
    }

    enum CodingKeys: String, CodingKey { case bytes, resumo, previa }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytes = (try? c.decodeIfPresent(Int.self, forKey: .bytes)) ?? 0
        resumo = (try? c.decodeIfPresent(String.self, forKey: .resumo)) ?? ""
        previa = (try? c.decodeIfPresent(String.self, forKey: .previa)) ?? ""
    }
}

/// `"pergunta_do_texto"` do estado. `nil` no estado: nada retido. `aberta == false`: comparando (o
/// texto do prompter ainda não chegou), e `doPrompter` nulo.
struct PerguntaDoTexto: Decodable, Equatable {
    var aberta = false
    var retidoHaMs: UInt64 = 0
    var prompterId = ""
    var prompterNome = ""
    var meu: VistaDoTexto?
    var doPrompter: VistaDoTexto?

    init(aberta: Bool = false, retidoHaMs: UInt64 = 0, prompterId: String = "", prompterNome: String = "",
         meu: VistaDoTexto? = nil, doPrompter: VistaDoTexto? = nil) {
        self.aberta = aberta; self.retidoHaMs = retidoHaMs; self.prompterId = prompterId
        self.prompterNome = prompterNome; self.meu = meu; self.doPrompter = doPrompter
    }

    enum CodingKeys: String, CodingKey {
        case aberta, meu
        case retidoHaMs = "retido_ha_ms"
        case prompterId = "prompter_id"
        case prompterNome = "prompter_nome"
        case doPrompter = "do_prompter"
    }

    /// Campo a campo e tolerante, como o resto do estado (§3).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aberta = (try? c.decodeIfPresent(Bool.self, forKey: .aberta)) ?? false
        retidoHaMs = (try? c.decodeIfPresent(UInt64.self, forKey: .retidoHaMs)) ?? 0
        prompterId = (try? c.decodeIfPresent(String.self, forKey: .prompterId)) ?? ""
        prompterNome = (try? c.decodeIfPresent(String.self, forKey: .prompterNome)) ?? ""
        meu = try? c.decodeIfPresent(VistaDoTexto.self, forKey: .meu)
        doPrompter = try? c.decodeIfPresent(VistaDoTexto.self, forKey: .doPrompter)
    }
}

/// Uma entrada de `"copias_do_texto"`: o texto que saiu numa escolha, numa fusão ou num vazio (§11.5).
/// A chave é o **resumo** (a lista pode mudar entre ler o estado e chamar).
struct CopiaDoTexto: Decodable, Equatable, Identifiable {
    var origem = ""
    var prompterId = ""
    var prompterNome = ""
    var quandoMs: UInt64 = 0
    var bytes = 0
    var resumo = ""
    var previa = ""

    var id: String { resumo }

    init(origem: String = "", prompterId: String = "", prompterNome: String = "", quandoMs: UInt64 = 0,
         bytes: Int = 0, resumo: String = "", previa: String = "") {
        self.origem = origem; self.prompterId = prompterId; self.prompterNome = prompterNome
        self.quandoMs = quandoMs; self.bytes = bytes; self.resumo = resumo; self.previa = previa
    }

    enum CodingKeys: String, CodingKey {
        case origem, bytes, resumo, previa
        case prompterId = "prompter_id"
        case prompterNome = "prompter_nome"
        case quandoMs = "quando_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origem = (try? c.decodeIfPresent(String.self, forKey: .origem)) ?? ""
        prompterId = (try? c.decodeIfPresent(String.self, forKey: .prompterId)) ?? ""
        prompterNome = (try? c.decodeIfPresent(String.self, forKey: .prompterNome)) ?? ""
        quandoMs = (try? c.decodeIfPresent(UInt64.self, forKey: .quandoMs)) ?? 0
        bytes = (try? c.decodeIfPresent(Int.self, forKey: .bytes)) ?? 0
        resumo = (try? c.decodeIfPresent(String.self, forKey: .resumo)) ?? ""
        previa = (try? c.decodeIfPresent(String.self, forKey: .previa)) ?? ""
    }

    /// De onde veio, literal: a cópia do prompter e a daqui, que saiu quando ele chegou.
    var deOnde: String {
        origem == "prompter" ? TextosDaPergunta.doPrompter(prompterNome) : TextosDaPergunta.desteAparelho(prompterNome)
    }

    /// A hora da cópia, no relógio de parede.
    var quando: Date { Date(timeIntervalSince1970: Double(quandoMs) / 1000) }
}

/// **Os textos da tela, literais nas quatro telas** (o pedido de 14/09, fim da tarde).
enum TextosDaPergunta {
    // Todos calculados na hora (`static var`, e não `static let`): seguem o idioma escolhido
    // (`Comum/Idioma.swift`). Em PT, o texto de sempre.
    static func titulo(_ nome: String) -> String { tr("O prompter %@ tem outro roteiro.", nome) }
    static var noPrompter: String { tr("No prompter") }
    static var nesteAparelho: String { tr("Neste aparelho") }
    static var usarODoPrompter: String { tr("Usar o do prompter") }
    static var mandarOMeu: String { tr("Mandar o meu") }
    static var ficaGuardado: String { tr("O roteiro que sair fica em Roteiros guardados.") }
    static var conferindo: String { tr("Conferindo o roteiro do prompter…") }
    static var prompterSaiu: String { tr("O prompter saiu. A pergunta volta quando ele voltar.") }
    static var roteiroMudou: String { tr("O roteiro do prompter mudou. Confira de novo.") }
    static var roteirosGuardados: String { tr("Roteiros guardados") }
    static func doPrompter(_ nome: String) -> String { tr("Do prompter %@", nome) }
    static func desteAparelho(_ nome: String) -> String { tr("Deste aparelho, antes de %@", nome) }
    static var ver: String { tr("Ver") }
    static var usarEste: String { tr("Usar este") }
    static var apagar: String { tr("Apagar") }
    static var confirmaUsar: String { tr("Usar este roteiro? Ele substitui o roteiro atual, também no prompter conectado.") }
    static var usar: String { tr("Usar") }
    static var cancelar: String { tr("Cancelar") }
    static var confirmaApagar: String { tr("Apagar este roteiro guardado?") }
    static var nenhumGuardado: String { tr("Nenhum roteiro guardado.") }
    /// O tamanho, com concordância e ponto de milhar em pt-BR, igual nas quatro telas: "0 palavras"
    /// (texto vazio), "1 palavra", "2 palavras", "1.234 palavras". Fixo, e não pela língua do aparelho:
    /// pelo idioma escolhido no Quall (em EN, "1 word", "1,234 words").
    static func palavras(_ n: Int) -> String { n == 1 ? tr("1 palavra") : tr("%@ palavras", milhar(n)) }

    /// O número com ponto a cada três algarismos: 1234567 → "1.234.567" (em EN, vírgula: "1,234,567").
    static func milhar(_ n: Int) -> String {
        let separador: Character = Idioma.atual == .en ? "," : "."
        let algarismos = String(abs(n))
        var saida = ""
        for (i, c) in algarismos.reversed().enumerated() {
            if i > 0, i % 3 == 0 { saida.append(separador) }
            saida.append(c)
        }
        return (n < 0 ? "-" : "") + String(saida.reversed())
    }
}

/// **As palavras de um texto**, pela mesma definição da fonte automática (§5 dos ajustes locais):
/// um trecho sem espaço com pelo menos uma letra ou algarismo. Um travessão ou reticências sozinhos
/// não contam, e "— vamos" é uma palavra só. Uma passada, sem copiar o texto: 128 KB em
/// milissegundos.
enum ContaDePalavras {
    static func de(_ texto: String) -> Int {
        let espacos = CharacterSet.whitespacesAndNewlines
        let letraOuAlgarismo = CharacterSet.letters.union(.decimalDigits)
        var n = 0
        var dentro = false
        var temLetra = false
        for u in texto.unicodeScalars {
            if espacos.contains(u) {
                if dentro, temLetra { n += 1 }
                dentro = false
                temLetra = false
            } else {
                dentro = true
                if !temLetra, letraOuAlgarismo.contains(u) { temLetra = true }
            }
        }
        if dentro, temLetra { n += 1 }
        return n
    }
}

/// O que o núcleo respondeu à última escolha, para a caixa dizer.
enum RespostaDaEscolha: Equatable {
    /// `BUSY`: o texto do prompter mudou, ou há um mais novo a caminho (§11.4).
    case roteiroMudou
    /// `CLOSED`: sem o prompter conectado.
    case prompterSaiu
}

/// **O que a caixa mostra**, do estado e da última resposta.
enum EstadoDaCaixa: Equatable {
    /// Nada retido, ou comparando há menos de ~1 s (não pisca a cada conexão).
    case escondida
    /// Comparando há mais de ~1 s: "Conferindo o roteiro do prompter…", sem botões.
    case conferindo
    /// A pergunta aberta. `botoes` falso: o prompter saiu. `aviso`: a frase sob o título.
    case pergunta(PerguntaDoTexto, botoes: Bool, aviso: String?)

    /// Quanto tempo comparando antes de dizer que está conferindo.
    static let limiteDoConferindo: UInt64 = 1000

    static func de(pergunta: PerguntaDoTexto?, prompterVisto: Bool, resposta: RespostaDaEscolha?) -> EstadoDaCaixa {
        guard let p = pergunta else { return .escondida }
        guard p.aberta, p.doPrompter != nil else {
            return p.retidoHaMs > limiteDoConferindo ? .conferindo : .escondida
        }
        if !prompterVisto || resposta == .prompterSaiu {
            return .pergunta(p, botoes: false, aviso: TextosDaPergunta.prompterSaiu)
        }
        if resposta == .roteiroMudou { return .pergunta(p, botoes: true, aviso: TextosDaPergunta.roteiroMudou) }
        return .pergunta(p, botoes: true, aviso: nil)
    }
}
