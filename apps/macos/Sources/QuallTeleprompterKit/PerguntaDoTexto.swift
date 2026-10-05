import Foundation
import QuallIdiomaKit

/// **A "pergunta do texto"** no controle (`docs/contrato-teleprompter.md` §11.2–§11.7): um controle
/// que conecta num prompter que não é o da última vez, com roteiro diferente, pergunta uma vez
/// ("usar o do prompter ou mandar o meu") e guarda cópia do que sair — a decisão do usuário de 13/09,
/// e o "pode seguir" dele de 14/09.
///
/// Aqui mora o que se testa sem núcleo e sem janela: a leitura das duas chaves do estado
/// (`"pergunta_do_texto"` e `"copias_do_texto"`, §11.6), a contagem de palavras, a regra da caixa
/// e os textos, **literais e iguais nas quatro telas** (o pedido de 14/09 à tarde).
public enum TextosDaPergunta {
    public static func titulo(prompter nome: String) -> String { T("O prompter %@ tem outro roteiro.", nome) }
    public static var noPrompter: String { T("No prompter") }
    public static var nesteAparelho: String { T("Neste aparelho") }
    public static var usarODoPrompter: String { T("Usar o do prompter") }
    public static var mandarOMeu: String { T("Mandar o meu") }
    public static var oQueSairFicaGuardado: String { T("O roteiro que sair fica em Roteiros guardados.") }
    public static var conferindo: String { T("Conferindo o roteiro do prompter…") }
    public static var oPrompterSaiu: String { T("O prompter saiu. A pergunta volta quando ele voltar.") }
    public static var oRoteiroMudou: String { T("O roteiro do prompter mudou. Confira de novo.") }

    public static var roteirosGuardados: String { T("Roteiros guardados") }
    public static var nenhumRoteiroGuardado: String { T("Nenhum roteiro guardado.") }
    public static var ver: String { T("Ver") }
    public static var usarEste: String { T("Usar este") }
    public static var apagar: String { T("Apagar") }
    /// "Usar este roteiro? Ele substitui o roteiro atual, também no prompter conectado." — o literal
    /// do pedido, em título e mensagem do alerta.
    public static var usarEsteRoteiroTitulo: String { T("Usar este roteiro?") }
    public static var usarEsteRoteiroMensagem: String { T("Ele substitui o roteiro atual, também no prompter conectado.") }
    public static var usar: String { T("Usar") }
    public static var cancelar: String { T("Cancelar") }
    public static var apagarEsteRoteiro: String { T("Apagar este roteiro guardado?") }

    /// O tamanho em palavras, **com concordância e ponto de milhar em pt-BR**, igual nas quatro telas
    /// (o coordenador, 14/09): "1 palavra", "2 palavras", "1.234 palavras", "0 palavras" para texto
    /// vazio. Vale na caixa e em "Roteiros guardados".
    public static func palavras(_ n: Int) -> String { n == 1 ? T("1 palavra") : T("%@ palavras", comMilhar(n)) }

    /// O ponto de milhar feito aqui, e não pelo `NumberFormatter`: o texto não pode depender do idioma
    /// do Mac de quem usa. Segue o idioma do app: ponto em português, vírgula em inglês ("1,234 words").
    public static func comMilhar(_ n: Int) -> String {
        let digitos = String(n.magnitude)
        var s = ""
        for (i, c) in digitos.enumerated() {
            if i > 0, (digitos.count - i) % 3 == 0 { s.append(Idioma.atual == .en ? "," : ".") }
            s.append(c)
        }
        return n < 0 ? "-" + s : s
    }
}

/// **Palavra**, a mesma da fonte automática (`FonteAutomatica.linhasComUmaPalavra`, e
/// `docs/teleprompter-ajustes-locais.md` §5): um trecho sem espaço com pelo menos uma letra ou
/// algarismo — um travessão ou um emoji sozinhos não contam.
public enum Palavras {
    public static func contar(_ texto: String) -> Int {
        var n = 0
        for trecho in texto.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        where trecho.contains(where: { $0.isLetter || $0.isNumber }) {
            n += 1
        }
        return n
    }
}

/// Um dos dois lados da pergunta: `"meu"` e `"do_prompter"` (§11.6). A prévia são os primeiros até
/// 240 bytes do texto; o tamanho em palavras se conta no texto inteiro (quem conta é o modelo).
public struct LadoDaPergunta: Equatable, Sendable {
    public var bytes: Int
    public var resumo: String
    public var previa: String

    public init(bytes: Int, resumo: String, previa: String) {
        self.bytes = bytes
        self.resumo = resumo
        self.previa = previa
    }
}

/// `"pergunta_do_texto"` do estado: `nil` sem nada retido; `aberta == false` comparando (e
/// `doPrompter` nulo); `aberta == true` perguntando.
public struct PerguntaDoTexto: Equatable, Sendable {
    public var aberta: Bool
    public var retidoHaMs: UInt64
    public var prompterId: String
    public var prompterNome: String
    public var meu: LadoDaPergunta?
    public var doPrompter: LadoDaPergunta?

    public init(aberta: Bool, retidoHaMs: UInt64, prompterId: String, prompterNome: String,
                meu: LadoDaPergunta?, doPrompter: LadoDaPergunta?) {
        self.aberta = aberta
        self.retidoHaMs = retidoHaMs
        self.prompterId = prompterId
        self.prompterNome = prompterNome
        self.meu = meu
        self.doPrompter = doPrompter
    }

    /// O nome para a tela: o do prompter, e o `device_id` quando ele não tem nome (derivado).
    public var nomeParaATela: String { prompterNome.isEmpty ? prompterId : prompterNome }
}

/// De onde veio uma cópia (§11.5): o texto **do prompter** que perdeu, ou o **deste aparelho**.
public enum OrigemDaCopia: Equatable, Sendable {
    case prompter, controle
    case outra(String)
}

/// Uma cópia de `"copias_do_texto"` (§11.6). A chave é o **resumo**, e não a posição: a lista pode
/// mudar entre ler o estado e chamar `text_copy` ou `forget_text_copy`.
public struct CopiaDoTexto: Equatable, Sendable, Identifiable {
    public var origem: OrigemDaCopia
    public var prompterId: String
    public var prompterNome: String
    /// Relógio de parede da hora da cópia, em ms.
    public var quandoMs: UInt64
    public var bytes: Int
    public var resumo: String
    public var previa: String

    public var id: String { resumo }

    public init(origem: OrigemDaCopia, prompterId: String, prompterNome: String, quandoMs: UInt64,
                bytes: Int, resumo: String, previa: String) {
        self.origem = origem
        self.prompterId = prompterId
        self.prompterNome = prompterNome
        self.quandoMs = quandoMs
        self.bytes = bytes
        self.resumo = resumo
        self.previa = previa
    }

    /// "Do prompter {nome}" / "Deste aparelho, antes de {nome}" — literais do pedido.
    public var deOnde: String {
        let nome = prompterNome.isEmpty ? (prompterId.isEmpty ? T("outro aparelho") : prompterId) : prompterNome
        switch origem {
        case .prompter: return T("Do prompter %@", nome)
        case .controle: return T("Deste aparelho, antes de %@", nome)
        case .outra(let o): return "\(o) — \(nome)"
        }
    }
}

/// **A caixa da pergunta**, derivada do estado e da última resposta de `resolve_text`. Pura, para a
/// regra ser uma só e testável sem janela (§11.7 e o pedido de 14/09 à tarde).
public enum CaixaDaPergunta: Equatable, Sendable {
    /// Sem nada retido, ou comparando há pouco (menos de ~1 s): nada na tela.
    case nenhuma
    /// Comparando há mais de ~1 s: "Conferindo o roteiro do prompter…", sem botões.
    case conferindo
    /// A pergunta aberta. `escolhasLigadas` falso com o prompter fora (ou `CLOSED` na escolha);
    /// `aviso` é a linha de estado da caixa, quando há.
    case perguntando(prompterNome: String, doPrompter: LadoDaPergunta, meu: LadoDaPergunta,
                     escolhasLigadas: Bool, aviso: String?)

    /// Quanto tempo comparando antes de a caixa aparecer.
    public static let conferindoDepoisDeMs: UInt64 = 1_000

    /// - `recusa`: o status da última escolha que não passou, enquanto vale — `.fechado` (o prompter
    ///   não está conectado) e `.ocupado` (o roteiro do prompter mudou); o modelo o esquece quando a
    ///   pergunta fecha, quando uma sessão nova sobe, e na escolha seguinte.
    public static func calcular(pergunta: PerguntaDoTexto?, parVistoHaMs: UInt64?, conectado: Bool,
                                recusa: StatusDaFronteira?) -> CaixaDaPergunta {
        guard let p = pergunta else { return .nenhuma }
        guard p.aberta, let doPrompter = p.doPrompter, let meu = p.meu else {
            return p.retidoHaMs > conferindoDepoisDeMs ? .conferindo : .nenhuma
        }
        let ligadas = conectado && parVistoHaMs != nil && recusa != .fechado
        let aviso: String?
        if !ligadas {
            aviso = TextosDaPergunta.oPrompterSaiu
        } else if recusa == .ocupado {
            aviso = TextosDaPergunta.oRoteiroMudou
        } else {
            aviso = nil
        }
        return .perguntando(prompterNome: p.nomeParaATela, doPrompter: doPrompter, meu: meu,
                            escolhasLigadas: ligadas, aviso: aviso)
    }

    /// O resumo do texto do prompter que a caixa mostra — o que a escolha leva.
    public var resumoMostrado: String? {
        if case .perguntando(_, let doPrompter, _, _, _) = self { return doPrompter.resumo }
        return nil
    }

    public var escolhasLigadas: Bool {
        if case .perguntando(_, _, _, let ligadas, _) = self { return ligadas }
        return false
    }
}
