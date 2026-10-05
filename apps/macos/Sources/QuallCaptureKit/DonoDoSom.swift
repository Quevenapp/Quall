import Foundation

/// **Quem toca o som quando o Mac emite para vários receptores** — a tela estendida
/// (`docs/som-no-receptor.md` §12.1, D2).
///
/// O som do sistema é a mistura da máquina inteira: mandá-lo a cada monitor seria o mesmo som
/// tocando em vários aparelhos. A regra decidida pelo Pessoa Exemplo em 18/09/2026:
///
/// - **só o primeiro receptor toca**;
/// - **quando esse sai, o som passa ao próximo** — a passagem veio na sugestão que ele aceitou, e é
///   **a confirmar** (fica com o coordenador). Por isso ela liga e desliga (``passar``).
///
/// # "O primeiro receptor" é o primeiro que **toca** (revisão do código, crítica 9, M3)
///
/// Dar o som a um receptor que não toca o codec do Mac cala todos: um iPhone primeiro (o iOS só
/// toca Opus, e o Mac manda PCMU) deixava mudo o tablet Android que viesse depois. Então quem não
/// toca entra na fila das conectadas, mas nunca é dono; o dono é o primeiro que toca, na ordem de
/// conexão. Quem toca vem de ``QuemTocaOSomDoMac``.
///
/// # O mesmo aparelho que volta (crítica 9, M2)
///
/// O dono cujo Wi-Fi pisca volta por uma sessão nova antes de a velha cair. ``substituir(_:por:novoToca:aparelho:agoraMs:)``
/// passa a vaga dele — e o som, se era dele — à sessão nova, em vez de a velha sair (e o som ir ao
/// segundo receptor) e a nova entrar calada.
///
/// # O dono que cai: 10 s de carência (decisão do Pessoa Exemplo, 18/09/2026, ~22h30)
///
/// Quando o emissor vê a queda **antes** da volta (crítica 13, M2), a regra acima não alcança: a
/// velha já saiu. Então, se a conexão do dono **cai** (``caiu(_:agoraMs:)``), o som fica com o
/// **aparelho** dele por ``carenciaDoDonoMs``: ninguém toca nesse tempo, e se o mesmo aparelho
/// voltar, o som é dele. Vencido o prazo (``tique(agoraMs:)``), passa ao próximo. Quem **sai** (o
/// receptor fechou, a pessoa desconectou) passa o som na hora, como antes. O mesmo desenho, com os
/// mesmos casos de teste, está em `apps/windows/src/som_puxado.rs`.
///
/// Toda sessão **oferece** a track de som (ela tem de estar na oferta SDP desde o começo: o Quall
/// não renegocia); só a do dono **manda** pacote. No receptor, a track calada fica em `IDLE`.
public struct DonoDoSom: Equatable {
    /// A carência do dono que cai.
    public static let carenciaDoDonoMs: UInt64 = 10_000

    public var passar: Bool
    /// As sessões conectadas, na ordem em que conectaram, se cada uma toca, e o aparelho dela.
    public private(set) var conectadas: [(id: Int, toca: Bool, aparelho: String)] = []
    public private(set) var dono: Int?
    /// O aparelho do dono que caiu, e até quando (ms) o som espera por ele.
    public private(set) var carencia: (aparelho: String, ate: UInt64)?

    public init(passar: Bool) {
        self.passar = passar
    }

    public static func == (a: DonoDoSom, b: DonoDoSom) -> Bool {
        a.passar == b.passar && a.dono == b.dono
            && a.conectadas.map(\.id) == b.conectadas.map(\.id)
            && a.conectadas.map(\.toca) == b.conectadas.map(\.toca)
            && a.conectadas.map(\.aparelho) == b.conectadas.map(\.aparelho)
            && a.carencia?.aparelho == b.carencia?.aparelho && a.carencia?.ate == b.carencia?.ate
    }

    /// O primeiro conectado que toca, se a passagem estiver ligada.
    private func proximo() -> Int? {
        passar ? conectadas.first(where: { $0.toca })?.id : nil
    }

    /// Vence a carência, se passou do prazo: o som vai ao próximo que toca.
    private mutating func vencer(_ agoraMs: UInt64) {
        guard let c = carencia, agoraMs >= c.ate else { return }
        carencia = nil
        if dono == nil { dono = proximo() }
    }

    /// A sessão entrou na fila: é dona se o som espera por este aparelho, ou se ninguém é dono e não
    /// há carência.
    private mutating func entrou(_ id: Int, toca: Bool, aparelho: String) {
        if let c = carencia, !aparelho.isEmpty, c.aparelho == aparelho {
            carencia = nil
            // Voltou por um app que não toca: é como se tivesse saído, e o som passa já.
            dono = toca ? id : proximo()
            return
        }
        if dono == nil, carencia == nil, toca { dono = id }
    }

    /// Uma sessão conectou. Devolve o dono novo, quando ele mudou.
    @discardableResult
    public mutating func conectou(_ id: Int, toca: Bool, aparelho: String = "", agoraMs: UInt64 = 0) -> Int? {
        let antes = dono
        vencer(agoraMs)
        if !conectadas.contains(where: { $0.id == id }) {
            conectadas.append((id, toca, aparelho))
            entrou(id, toca: toca, aparelho: aparelho)
        }
        return dono != antes ? dono : nil
    }

    /// Uma sessão saiu por gesto, ou por falha que não é queda: o som passa **na hora**. Devolve o
    /// dono novo, quando o som passou a outra; `nil` quando ninguém ganhou o som.
    @discardableResult
    public mutating func saiu(_ id: Int) -> Int? {
        conectadas.removeAll { $0.id == id }
        guard dono == id else { return nil }
        dono = carencia == nil ? proximo() : nil
        return dono
    }

    /// A conexão da sessão caiu. Se ela era a dona, o som espera o aparelho dela por
    /// ``carenciaDoDonoMs``, e ninguém toca nesse tempo. Senão, é uma saída qualquer.
    @discardableResult
    public mutating func caiu(_ id: Int, agoraMs: UInt64) -> Int? {
        guard dono == id else { return saiu(id) }
        let aparelho = conectadas.first(where: { $0.id == id })?.aparelho ?? ""
        conectadas.removeAll { $0.id == id }
        dono = nil
        guard !aparelho.isEmpty else {
            // Sem identidade não há como reconhecer a volta: passa na hora.
            dono = proximo()
            return dono
        }
        carencia = (aparelho, agoraMs + DonoDoSom.carenciaDoDonoMs)
        return nil
    }

    /// O mesmo aparelho voltou: a sessão `novo` herda a vaga de `velho` na fila, e o som, se era
    /// dele — ou se o som espera por este aparelho. Devolve o dono novo, quando ele mudou.
    @discardableResult
    public mutating func substituir(_ velho: Int, por novo: Int, novoToca: Bool, aparelho: String = "",
                                    agoraMs: UInt64 = 0) -> Int? {
        let antes = dono
        vencer(agoraMs)
        conectadas.removeAll { $0.id == novo }
        if let i = conectadas.firstIndex(where: { $0.id == velho }) {
            conectadas[i] = (novo, novoToca, aparelho)
        } else {
            conectadas.append((novo, novoToca, aparelho))
        }
        if dono == velho {
            // O aparelho voltou por um app que não toca: é como se o dono tivesse saído.
            dono = novoToca ? novo : proximo()
        } else {
            entrou(novo, toca: novoToca, aparelho: aparelho)
        }
        return dono != antes ? dono : nil
    }

    /// A sessão ficou sem som: não toca, e se era a dona, o som passa na hora.
    @discardableResult
    public mutating func naoToca(_ id: Int) -> Int? {
        if let i = conectadas.firstIndex(where: { $0.id == id }) { conectadas[i].toca = false }
        guard dono == id else { return nil }
        dono = carencia == nil ? proximo() : nil
        return dono
    }

    /// O som da sessão voltou (crítica 18, F2): ela volta a ser candidata — `toca` é o que o
    /// aparelho toca, pela tabela —, **sem tomar o som** de quem tem. Só ganha o som se ninguém o tem
    /// e nenhuma carência o espera, pela regra de sempre (``proximo()``). Devolve o dono novo, quando
    /// ele mudou.
    @discardableResult
    public mutating func voltouOSom(_ id: Int, toca: Bool) -> Int? {
        guard let i = conectadas.firstIndex(where: { $0.id == id }) else { return nil }
        conectadas[i].toca = toca
        guard dono == nil, carencia == nil else { return nil }
        dono = proximo()
        return dono
    }

    /// O relógio: vence a carência. Devolve o dono novo, quando ele mudou.
    @discardableResult
    public mutating func tique(agoraMs: UInt64) -> Int? {
        let antes = dono
        vencer(agoraMs)
        return dono != antes ? dono : nil
    }

    /// Recomeça a rodada (o Parar de tudo, ou uma fonte nova).
    public mutating func zerar() {
        conectadas = []
        dono = nil
        carencia = nil
    }
}

/// **Quem toca o som que o Mac manda** (PCMU, `SessaoDeEmissao.swift`), pelo `device_id` do
/// receptor.
///
/// # Por que pelo `device_id`, e o que isto não é
///
/// O receptor ainda não diz ao emissor se toca, nem o quê: o aperto de mão só traz tela, câmera e
/// sumidouro. O `device_id` de cada casca tem um prefixo próprio (`Identidade.swift` do Mac e do
/// iOS, `DeviceIdentity.kt`, `identidade.rs`), e a tabela abaixo é o que cada casca toca **hoje**:
///
/// | prefixo | toca PCMU? |
/// |---|---|
/// | `mac-` | sim, desde a S4 |
/// | `android-` | sim (`UlawG711.kt`) |
/// | `ios-` | não: só Opus (risco R6) |
/// | `win-` | **ainda não** (ver abaixo) |
/// | outro (OBS, o app da câmera do Mac, a sonda) | não |
///
/// **O `win-` fica de fora até o app do Dell do Pessoa Exemplo ter a S6** (crítica 13, M4). O receptor do
/// Windows toca o PCMU desde a S6 (`apps/windows/src/tocador.rs`), mas o app que o Pessoa Exemplo usa no Dell
/// (`D:\OneDrive\Área de Trabalho\Quall.exe`, e o `quall-win`, SHA-256 `06BFE999…9BAF`, de 10/09)
/// é de antes e **ignora** a track de som. Com o `win-` aqui, um Dell conectado primeiro seria o dono
/// e ninguém tocaria. **Quando ligar**: no mesmo dia em que o `Quall.exe` do Dell for trocado por um
/// build com a S6 — é mudar a linha de ``tocaPCMU(deviceId:)`` para incluir `win-`, e o teste
/// `testeATabelaDeQuemTocaOPCMUDoMac`. A ordem de implantação é esta: primeiro o Dell, depois o Mac.
///
/// O OBS publica o som desde a S5, mas o `device_id` dele é um UUID puro, sem prefixo: continua
/// fora, e o som vai para quem toca no cômodo.
///
/// **É uma tabela que envelhece**: o jeito certo é o receptor declarar no aperto de mão se toca e
/// quais codecs, o que muda o protocolo e a fronteira. Fica registrado no §17.8 do
/// `som-no-receptor.md`. Até lá, esta tabela é o que separa "o primeiro receptor" de "o primeiro
/// que toca".
public enum QuemTocaOSomDoMac {
    public static func tocaPCMU(deviceId: String) -> Bool {
        let id = deviceId.lowercased()
        // `win-`: só quando o app do Dell tiver a S6 (ver acima).
        return id.hasPrefix("mac-") || id.hasPrefix("android-")
    }
}
