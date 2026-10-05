import Foundation
import QuallIdiomaKit

/// **Os dois botões do "Segurar para rolar"** (`docs/contrato-teleprompter.md` §12.5): o pedido do
/// usuário em 14/09, *"dois botões grandes Rolar para cima / Rolar para baixo, duas setas que ele
/// fique segurando pressionado e vai rolando soltou o texto para"*.
///
/// **O mapeamento botão → sentido mora aqui, e só aqui**: "Rolar para cima" é `hold(t, true)` (o texto
/// volta), "Rolar para baixo" é `hold(t, false)` (o texto avança) — e o **"Inverter botões"** (pedido
/// do usuário, 14/09 à tarde: o espelho do suporte deixa o texto andando ao contrário da seta) troca
/// o sentido **aqui**, e em lugar nenhum mais. As setas e os rótulos ficam no lugar; a legenda segue a
/// ação. As teclas ↑ e ↓ (Mac e Windows; os passadores de slide mandam setas) são os botões de cima e
/// de baixo, e seguem a inversão por construção.
public enum BotaoDeSegurar: String, CaseIterable, Sendable {
    case cima
    case baixo

    /// O `backwards` de `quall_teleprompter_hold`, com ou sem o "Inverter botões".
    public func paraTras(invertido: Bool) -> Bool { (self == .cima) != invertido }

    /// O rótulo, literal, igual nas quatro telas. **Não troca** com a inversão.
    public var rotulo: String { self == .cima ? T("Rolar para cima") : T("Rolar para baixo") }
    /// A legenda pequena embaixo do rótulo: **o que o botão faz**, então troca com a inversão.
    public func legenda(invertido: Bool) -> String {
        BotaoDeSegurar.legenda(paraTras: paraTras(invertido: invertido))
    }
    public static func legenda(paraTras: Bool) -> String { paraTras ? T("volta o texto") : T("avança o texto") }
    /// O SF Symbol da seta.
    public var simbolo: String { self == .cima ? "arrow.up" : "arrow.down" }

    /// O `keyCode` da seta que segura este botão no teclado do Mac (`kVK_UpArrow`, `kVK_DownArrow`).
    public var codigoDaTecla: UInt16 { self == .cima ? 126 : 125 }

    public static func daTecla(_ codigo: UInt16) -> BotaoDeSegurar? {
        switch codigo {
        case 126: return .cima
        case 125: return .baixo
        default: return nil
        }
    }
}

/// De onde vem um aperto. O Mac tem um ponteiro só (o mouse, ou o trackpad) e várias teclas: o
/// mouse e uma seta, ou as duas setas, podem estar apertados ao mesmo tempo — são os "dois dedos"
/// do pedido.
public enum FonteDoAperto: String, Hashable, Sendable {
    case mouse
    case tecla
}

/// O que o modelo tem de mandar ao núcleo.
public enum ComandoDoSegurar: Equatable, Sendable {
    /// `quall_teleprompter_hold(t, paraTras)`.
    case segurar(paraTras: Bool)
    /// `quall_teleprompter_release(t)`.
    case soltar
}

/// **A regra dos apertos do controle**, pura, para ser testada sem janela e sem núcleo.
///
/// - Apertar manda `hold` na hora. Com mais de um aperto de pé, **vale o último apertado**, e o
///   `release` só sai quando **nenhum** sobrar.
/// - Soltar o que valia com outro ainda seguro volta ao sentido do que sobrou (*derivado*: "segurando
///   pressionado e vai rolando" — quem ainda segura um botão espera que ele role).
/// - O mesmo aperto de novo (a repetição automática da tecla, um `mouseDown` a mais) não faz nada.
/// - **O texto parou sozinho** — `segurando` voltou a `false` com um aperto de pé (a queda, o
///   silêncio de 2,5 s, a pausa no prompter): a tela mostra "O texto parou. Solte e aperte de novo."
///   e nada aperta de novo sozinho — nem a repetição da tecla, nem soltar um de dois apertos. Só um
///   aperto novo, da pessoa, segura de novo.
public struct SegurarParaRolar: Equatable, Sendable {
    public struct Aperto: Equatable, Sendable {
        public let fonte: FonteDoAperto
        public let botao: BotaoDeSegurar
    }

    /// Os apertos de pé, na ordem em que vieram: o último é o que vale.
    public private(set) var apertos: [Aperto] = []
    /// Um `hold` que o núcleo aceitou, e que ainda não caiu nem foi solto.
    public private(set) var seguro = false
    /// `segurando` voltou a `false` com um aperto de pé. Fica até o próximo aperto (ou até sair do
    /// modo, ou até o texto voltar a rolar por outro caminho): quem desviou os olhos ainda lê por que
    /// o texto parou.
    public private(set) var textoParou = false
    /// O sentido do aperto que valia quando o texto parou — **avançando** no fim do texto, a tela diz
    /// que o texto chegou ao fim em vez de "solte e aperte de novo" (derivado). É o sentido, e não o
    /// botão: com "Inverter botões", quem avança é o de cima.
    public private(set) var paraTrasQuandoParou: Bool?
    /// **"Inverter botões"** (ajuste local do controle): o de cima avança e o de baixo volta. Só muda
    /// sem aperto nenhum de pé (`definirInversao`).
    public private(set) var invertido: Bool

    public init(invertido: Bool = false) {
        self.invertido = invertido
    }

    /// O botão que vale agora (o último apertado), se houver.
    public var botaoAtivo: BotaoDeSegurar? { apertos.last?.botao }

    /// O `backwards` deste botão agora — o mapeamento de `BotaoDeSegurar`, com a inversão daqui.
    public func paraTras(_ botao: BotaoDeSegurar) -> Bool { botao.paraTras(invertido: invertido) }
    /// A legenda deste botão agora.
    public func legenda(_ botao: BotaoDeSegurar) -> String { botao.legenda(invertido: invertido) }

    /// **Com um dedo num botão de rolar, a troca não vale** (pedido de 14/09): a inversão fica
    /// desligada até soltar — trocar no meio de um aperto mudaria o sentido debaixo do dedo.
    public var podeInverter: Bool { apertos.isEmpty }

    /// Liga ou desliga o "Inverter botões". Devolve `false` (e não muda nada) com um aperto de pé.
    @discardableResult
    public mutating func definirInversao(_ v: Bool) -> Bool {
        guard podeInverter else { return false }
        invertido = v
        return true
    }

    /// O literal do pedido para o texto que parou sozinho.
    public static var avisoDeTextoParado: String { T("O texto parou. Solte e aperte de novo.") }
    /// *Derivado* (revisão de 14/09): "Rolar para baixo" segurado até o fim para o texto pela regra
    /// de sempre do prompter (o fim para `rolando`), e "solte e aperte de novo" ali não adianta.
    public static var avisoDeFimDoTexto: String { T("O texto chegou ao fim.") }

    /// O aviso do texto parado, se houver, com a posição que o prompter relatou.
    public func avisoDoTextoParado(posicao: Double) -> String? {
        guard textoParou else { return nil }
        if paraTrasQuandoParou == false, posicao >= 0.999 { return SegurarParaRolar.avisoDeFimDoTexto }
        return SegurarParaRolar.avisoDeTextoParado
    }

    public func estaApertado(_ botao: BotaoDeSegurar) -> Bool { apertos.contains { $0.botao == botao } }

    /// Um aperto novo. Devolve o `hold` a mandar, ou `nil` se o aperto já estava de pé.
    public mutating func apertar(_ botao: BotaoDeSegurar, por fonte: FonteDoAperto) -> ComandoDoSegurar? {
        guard !apertos.contains(Aperto(fonte: fonte, botao: botao)) else { return nil }
        // O ponteiro é um só: um aperto de mouse num botão é o fim de qualquer outro aperto de mouse
        // (um `mouseUp` que se perdeu não deixa um botão preso para sempre).
        if fonte == .mouse { apertos.removeAll { $0.fonte == .mouse } }
        apertos.append(Aperto(fonte: fonte, botao: botao))
        textoParou = false
        paraTrasQuandoParou = nil
        return .segurar(paraTras: paraTras(botao))
    }

    /// Um aperto que acabou (soltou, saiu do botão). Devolve o que mandar: `release` quando não
    /// sobra nenhum; o `hold` do que sobrou quando saiu o que valia; ou nada.
    public mutating func soltar(_ botao: BotaoDeSegurar, por fonte: FonteDoAperto) -> ComandoDoSegurar? {
        guard let i = apertos.firstIndex(of: Aperto(fonte: fonte, botao: botao)) else { return nil }
        let eraOQueValia = i == apertos.count - 1
        apertos.remove(at: i)
        guard let sobrou = apertos.last else {
            seguro = false
            return .soltar
        }
        if eraOQueValia, seguro, !textoParou, sobrou.botao != botao {
            return .segurar(paraTras: paraTras(sobrou.botao))
        }
        return nil
    }

    /// Solta tudo de uma vez: perdeu o foco, a tela fechou, saiu do modo, desconectou.
    public mutating func soltarTudo() -> ComandoDoSegurar? {
        guard !apertos.isEmpty else { return nil }
        apertos.removeAll()
        seguro = false
        return .soltar
    }

    /// Sair do modo: solta tudo e apaga o aviso.
    public mutating func sairDoModo() -> ComandoDoSegurar? {
        textoParou = false
        paraTrasQuandoParou = nil
        return soltarTudo()
    }

    /// A resposta do núcleo ao `hold`: aceito (`OK`) ou recusado (`PROTOCOL`, `CLOSED`…).
    public mutating func segurou(aceito: Bool) {
        seguro = aceito && !apertos.isEmpty
    }

    /// O `segurando` e o `rolando` do estado, a cada leitura. Devolve `true` quando o texto **acabou
    /// de parar sozinho** com um aperto de pé.
    ///
    /// O aviso se apaga quando o texto volta a rolar sem `hold` daqui — alguém deu play no prompter
    /// (ou no controle, fora do modo): "o texto parou" deixou de ser verdade (revisão de 14/09).
    public mutating func observar(segurando: Bool, rolando: Bool = false) -> Bool {
        if textoParou, rolando, !seguro {
            textoParou = false
            paraTrasQuandoParou = nil
        }
        guard seguro, !segurando else { return false }
        seguro = false
        guard let ativo = apertos.last?.botao else { return false }
        textoParou = true
        paraTrasQuandoParou = paraTras(ativo)
        return true
    }
}

/// **Os botões funcionam?** Só com o prompter dizendo que entende (`"par_entende_segurar": true`,
/// §12.2), e com a sessão de pé.
public enum DisponibilidadeDoSegurar: Equatable, Sendable {
    /// Sem sessão (conectando, caiu, tentando de novo): a tela mostra o estado da conexão.
    case semSessao
    /// A sessão subiu e o prompter ainda não mandou o primeiro estado — não se sabe se ele entende.
    /// (*Derivado*: sem isto, "Atualize o app do prompter" piscaria a cada conexão.)
    case esperandoOPrompter
    /// O prompter não responde há mais de 2,5 s: um aperto agora pararia no silêncio (§12.4) antes
    /// de rolar. (*Derivado*.)
    case prompterSumido
    /// O prompter não diz que entende (13/09, ou uma tela que não liga o segurar), ou o núcleo
    /// recusou com `PROTOCOL`: "Atualize o app do prompter para usar este modo".
    case prompterAntigo
    case pronto

    public var botoesLigados: Bool { self == .pronto }

    public static func calcular(conectado: Bool, parSumido: Bool, estado: EstadoDoTeleprompter,
                                recusouPorProtocolo: Bool) -> DisponibilidadeDoSegurar {
        guard conectado else { return .semSessao }
        if parSumido { return .prompterSumido }
        if estado.parEntendeSegurar { return .pronto }
        if recusouPorProtocolo { return .prompterAntigo }
        return estado.parVistoHaMs == nil ? .esperandoOPrompter : .prompterAntigo
    }
}
