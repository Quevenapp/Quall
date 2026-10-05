import Foundation

/// Os dois papéis (`docs/contrato-teleprompter.md` §2). O `rawValue` é o texto do fio, literal.
public enum PapelDoTeleprompter: String, Sendable {
    /// Mostra o texto, hospeda e mostra o PIN.
    case prompter = "teleprompter"
    /// Conecta, edita e comanda.
    case controle = "controle_remoto"
}

/// O `QuallStatus` da fronteira, sem o tipo C. A ponte (`QuallNetKit`) traduz caso a caso, sem
/// `default` silencioso: um código novo no núcleo chega aqui como `.outro(n)` e aparece no
/// registro com o número.
public enum StatusDaFronteira: Equatable, Sendable {
    case ok, invalido, protocolo, descoberta, sinalizacao, transporte, pareamento, prazo
    case fechado, io, ponteiroNulo, naoUTF8, semRota, precisaDePin, cancelado, pinErrado, ocupado
    case outro(Int32)

    public var nome: String {
        switch self {
        case .ok: return "OK"
        case .invalido: return "INVALID"
        case .protocolo: return "PROTOCOL"
        case .descoberta: return "DISCOVERY"
        case .sinalizacao: return "SIGNALING"
        case .transporte: return "TRANSPORT"
        case .pareamento: return "PAIRING"
        case .prazo: return "TIMEOUT"
        case .fechado: return "CLOSED"
        case .io: return "IO"
        case .ponteiroNulo: return "NULL_POINTER"
        case .naoUTF8: return "NOT_UTF8"
        case .semRota: return "NO_ROUTE"
        case .precisaDePin: return "NEEDS_PIN"
        case .cancelado: return "CANCELLED"
        case .pinErrado: return "WRONG_PIN"
        case .ocupado: return "BUSY"
        case .outro(let n): return "código \(n)"
        }
    }
}

/// `quall_session_next_event`, sem o tipo C.
public enum EventoDaSessao: Equatable, Sendable {
    case nenhum, desconectou, falhou
}

/// O resultado de uma bombeada: o que mudou **e** se a sessão acabou — as duas coisas juntas,
/// como a fronteira devolve (`QUALL_STATUS_CLOSED` com `changed` preenchido).
public struct BombeadaDoLaco: Equatable, Sendable {
    public var mudancas: MudancasDoTeleprompter
    /// A sessão acabou: `QUALL_STATUS_CLOSED`, ou qualquer erro da bombeada (réplica envenenada,
    /// handle nulo) — nos dois casos não há mais o que ler.
    public var fechada: Bool
    public var status: StatusDaFronteira

    public init(mudancas: MudancasDoTeleprompter, fechada: Bool, status: StatusDaFronteira) {
        self.mudancas = mudancas
        self.fechada = fechada
        self.status = status
    }
}

/// **O que o laço pede à fronteira.** A implementação de verdade (`QuallNetKit`) é dona exclusiva
/// da sessão e do handle de mensagens: só a thread do laço chama estes métodos, então nenhum
/// ponteiro de sessão atravessa para outra thread — o precedente de `NucleoReceptor.swift:239-247`
/// (ponteiro tirado da trava e usado fora dela enquanto outra thread podia fechar) não se repete.
public protocol FronteiraDoLaco: AnyObject {
    /// Hospeda (prompter) ou conecta (controle) com este PIN — `nil` é sem PIN, pelo par conhecido.
    /// **Bloqueia** até a sessão subir, o prazo estourar ou o cancelador ser acionado.
    func abrir(pin: String?) -> (subiu: Bool, status: StatusDaFronteira, motivo: String)
    /// `quall_teleprompter_pump` com o handle da sessão aberta.
    func bombear(prazoMs: UInt32) -> BombeadaDoLaco
    /// `quall_session_next_event(s, 0)`.
    func proximoEvento() -> EventoDaSessao
    /// `quall_teleprompter_peer_lost`.
    func perdeuOPar() -> MudancasDoTeleprompter
    /// `quall_session_close` e `quall_messages_free`. É ele que solta a porta.
    func fechar()
    /// `quall_generate_pin`.
    func sortearPin() -> String
    /// Dorme até `ms`, acordando antes se o laço tiver de parar.
    func dormir(ms: Int)
}

/// O que o laço conta à tela. Sai da thread do laço; quem escuta leva para a main.
public enum AvisoDoLaco: Equatable, Sendable {
    /// Abrindo a sessão: o prompter esperando com este PIN; o controle conectando (PIN `nil` =
    /// pelo par conhecido).
    case abrindo(pin: String?, tentativa: Int)
    case conectou
    case mudou(MudancasDoTeleprompter)
    /// A sessão caiu (ou a pessoa parou), e a ordem do fim já rodou inteira.
    case caiu(porque: String)
    case falhou(StatusDaFronteira, motivo: String, decisao: DecisaoDoLaco)
    /// O laço acabou; a tela volta.
    case terminou(porque: String)
}

/// O que fazer depois de uma abertura que falhou.
public enum DecisaoDoLaco: Equatable, Sendable {
    case tentarDeNovo(pin: EscolhaDoPin, depoisDeMs: Int)
    case parar
}

public enum EscolhaDoPin: Equatable, Sendable {
    /// O mesmo PIN — nenhuma tentativa de PIN foi gasta.
    case mesmo
    /// PIN novo (`quall_generate_pin`): depois de `WRONG_PIN` ou `PAIRING` numa espera. Repetir o
    /// PIN abriria força bruta: seis dígitos são segurados por uma tentativa por conexão (§2).
    case novo
}

/// **O laço da thread da sessão**, dos dois papéis, com a ordem do fim do contrato (§6/§7):
///
/// 1. a bombeada que descobre o fim já vem com `changed` preenchido — aplicado; se o fim chegou por
///    `quall_session_next_event`, **uma bombeada final com prazo zero**, aplicada;
/// 2. só então `quall_teleprompter_peer_lost`;
/// 3. `quall_session_close` (solta a porta);
/// 4. no prompter, hospedar de novo na mesma porta — com o mesmo PIN depois de uma queda, e PIN
///    novo depois de `WRONG_PIN`/`PAIRING`; no controle, conectar de novo a cada ~1 s pelo par
///    conhecido, sem PIN.
///
/// Síncrono e sem thread própria: quem o roda é a `Thread` da tela, e os testes o rodam com uma
/// fronteira falsa que grava a ordem das chamadas.
public final class LacoDoTeleprompter {
    public let papel: PapelDoTeleprompter
    private let fronteira: FronteiraDoLaco
    private let deveParar: () -> Bool
    private let relogio: () -> Double
    private let avisar: (AvisoDoLaco) -> Void

    /// 80 ms: dentro dos 50–100 que o contrato recomenda, e no máximo 250.
    public var prazoDaBombeadaMs: UInt32 = 80
    /// Por quanto tempo o controle insiste diante de `BUSY` **antes** de a primeira sessão subir.
    /// Depois de uma queda, insiste até entrar: é o controle de volta ouvindo "ocupado" enquanto o
    /// prompter não percebe a queda (até 5 s, §2).
    public var insistirNoOcupadoMs = 12_000

    public init(papel: PapelDoTeleprompter, fronteira: FronteiraDoLaco,
                deveParar: @escaping () -> Bool,
                relogio: @escaping () -> Double,
                avisar: @escaping (AvisoDoLaco) -> Void) {
        self.papel = papel
        self.fronteira = fronteira
        self.deveParar = deveParar
        self.relogio = relogio
        self.avisar = avisar
    }

    /// Roda até a pessoa parar, ou até uma falha que precisa dela (PIN errado no controle, um
    /// aparelho que não é teleprompter).
    public func correr(pinInicial: String?) {
        var pin = pinInicial
        var jaSubiu = false
        var tentativa = 0
        var falhandoDesde: Double?
        var falhasSeguidas = 0
        var errosDePinSeguidos = 0

        while !deveParar() {
            tentativa += 1
            avisar(.abrindo(pin: pin, tentativa: tentativa))
            let inicio = relogio()
            let aberta = fronteira.abrir(pin: pin)
            if !aberta.subiu {
                let agora = relogio()
                let desde = falhandoDesde ?? inicio
                falhandoDesde = desde
                falhasSeguidas += 1
                if aberta.status == .pinErrado || aberta.status == .pareamento { errosDePinSeguidos += 1 }
                let decisao = LacoDoTeleprompter.decidir(
                    papel: papel, status: aberta.status, jaSubiu: jaSubiu,
                    durouMs: Int((agora - inicio) * 1000), falhandoHaMs: Int((agora - desde) * 1000),
                    falhasSeguidas: falhasSeguidas, errosDePinSeguidos: errosDePinSeguidos,
                    parando: deveParar(), insistirNoOcupadoMs: insistirNoOcupadoMs)
                avisar(.falhou(aberta.status, motivo: aberta.motivo, decisao: decisao))
                switch decisao {
                case .parar:
                    avisar(.terminou(porque: aberta.status == .cancelado || deveParar()
                                     ? "parada" : "falhou: \(aberta.status.nome)"))
                    return
                case .tentarDeNovo(let escolha, let espera):
                    if escolha == .novo { pin = fronteira.sortearPin() }
                    if espera > 0 { fronteira.dormir(ms: espera) }
                    continue
                }
            }

            jaSubiu = true
            tentativa = 0
            falhandoDesde = nil
            falhasSeguidas = 0
            errosDePinSeguidos = 0
            avisar(.conectou)
            let porque = sessao()

            // A ordem do fim, depois da bombeada final (que `sessao()` já fez): peer_lost, e só
            // então o fechamento que solta a porta.
            avisar(.mudou(fronteira.perdeuOPar()))
            fronteira.fechar()
            avisar(.caiu(porque: porque))

            // O controle volta pelo par conhecido: o PIN já foi gasto no pareamento, e o prompter o
            // mantém depois de uma queda — mas o par gravado é o caminho que não depende dele.
            if papel == .controle { pin = nil }
        }
        avisar(.terminou(porque: "parada"))
    }

    /// Bombeia e vigia até a sessão acabar. Devolve por quê.
    private func sessao() -> String {
        while true {
            if deveParar() {
                // A pessoa parou com a sessão de pé: o que já chegou entra antes de fechar, pela
                // mesma regra da queda.
                let final = fronteira.bombear(prazoMs: 0)
                if !final.mudancas.isEmpty { avisar(.mudou(final.mudancas)) }
                return "parada"
            }
            let b = fronteira.bombear(prazoMs: prazoDaBombeadaMs)
            // **Aplicar antes de qualquer outra coisa**: com `CLOSED`, `changed` traz a última
            // mensagem do outro lado (a pausa tocada logo antes da queda).
            if !b.mudancas.isEmpty { avisar(.mudou(b.mudancas)) }
            if b.fechada {
                return b.status == .fechado ? "a bombeada devolveu CLOSED" : "a bombeada falhou: \(b.status.nome)"
            }
            let evento = fronteira.proximoEvento()
            if evento != .nenhum {
                // A queda chegou pelo evento, não pela bombeada: a bombeada final com prazo zero lê
                // a fila até o fim antes de o par ser dado por perdido.
                let final = fronteira.bombear(prazoMs: 0)
                if !final.mudancas.isEmpty { avisar(.mudou(final.mudancas)) }
                return evento == .desconectou ? "o outro lado saiu (DISCONNECTED)" : "a sessão falhou (FAILED)"
            }
        }
    }

    /// Quantos erros de PIN seguidos o prompter aceita antes de parar de reabrir a espera sozinho.
    public static let errosDePinAteParar = 5
    /// Quantas falhas de sinalização seguidas (um `pares.json` que não se lê, por exemplo) antes de
    /// parar: é defeito que não se cura tentando de novo.
    public static let falhasDeSinalizacaoAteParar = 3

    /// **A regra depois de uma abertura que falhou.** Pura, para ser lida e testada como tabela.
    ///
    /// | papel | status | o que fazer |
    /// |---|---|---|
    /// | os dois | `CANCELLED`, ou a pessoa parando | parar |
    /// | prompter | `WRONG_PIN`, `PAIRING` | **PIN novo**, e espera crescente: 1, 2, 4, 8 s; no 5.º erro seguido, parar |
    /// | prompter | `INVALID`, `NULL_POINTER`, `NOT_UTF8` | parar: é defeito, não rede |
    /// | prompter | `SIGNALING` | mesmo PIN em 1 s; na 3.ª seguida, parar |
    /// | prompter | qualquer outro (prazo, recusa por versão, porta em uso…) | mesmo PIN, de novo |
    /// | controle | `BUSY` | de novo em 1 s (até 12 s na primeira vez; depois de uma queda, sempre) |
    /// | controle | `WRONG_PIN`, `NEEDS_PIN`, `PAIRING`, `PROTOCOL`, `SIGNALING`, `INVALID`… | parar: precisa da pessoa |
    /// | controle | rede (`IO`, `TIMEOUT`, `NO_ROUTE`, `TRANSPORT`…) | na primeira vez, parar e dizer; depois de uma queda, de novo a cada ~1 s |
    ///
    /// **Por que a espera crescente no PIN errado** (revisão adversarial de 13/09): trocar o PIN não
    /// muda a chance de cada tentativa, e o que segura seis dígitos é cada tentativa custar uma
    /// conexão. Reabrir na hora deixaria um aparelho na LAN tentar dezenas de PINs por segundo, e em
    /// algumas horas a chance de acerto deixa de ser desprezível. Com 1+2+4+8 s e parada no quinto
    /// erro, são cinco tentativas até a pessoa do prompter agir.
    ///
    /// Uma falha em menos de 1 s espera o resto do segundo antes de tentar de novo: sem isso, uma
    /// porta ocupada ou um endereço recusado viram um laço quente.
    public static func decidir(papel: PapelDoTeleprompter, status: StatusDaFronteira, jaSubiu: Bool,
                               durouMs: Int, falhandoHaMs: Int,
                               falhasSeguidas: Int = 1, errosDePinSeguidos: Int = 0,
                               parando: Bool, insistirNoOcupadoMs: Int = 12_000) -> DecisaoDoLaco {
        if parando || status == .cancelado { return .parar }
        let resto = max(0, 1000 - durouMs)
        switch papel {
        case .prompter:
            switch status {
            case .pinErrado, .pareamento:
                let n = max(1, errosDePinSeguidos)
                if n >= errosDePinAteParar { return .parar }
                let espera = min(60_000, 1000 << min(6, n - 1))
                return .tentarDeNovo(pin: .novo, depoisDeMs: max(resto, espera))
            case .invalido, .ponteiroNulo, .naoUTF8:
                return .parar
            case .sinalizacao:
                if falhasSeguidas >= falhasDeSinalizacaoAteParar { return .parar }
                return .tentarDeNovo(pin: .mesmo, depoisDeMs: max(resto, 1000))
            default:
                return .tentarDeNovo(pin: .mesmo, depoisDeMs: resto)
            }
        case .controle:
            switch status {
            case .ocupado:
                if jaSubiu || falhandoHaMs < insistirNoOcupadoMs {
                    return .tentarDeNovo(pin: .mesmo, depoisDeMs: resto)
                }
                return .parar
            case .pinErrado, .precisaDePin, .pareamento, .protocolo, .sinalizacao, .invalido,
                 .naoUTF8, .ponteiroNulo:
                return .parar
            default:
                return jaSubiu ? .tentarDeNovo(pin: .mesmo, depoisDeMs: resto) : .parar
            }
        }
    }
}
