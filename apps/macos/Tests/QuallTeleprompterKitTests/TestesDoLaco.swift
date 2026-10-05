import XCTest
@testable import QuallTeleprompterKit

/// **O laço da sessão contra uma fronteira falsa que grava a ordem das chamadas.**
///
/// O que se prova aqui é a regra da casca (§6/§7 e §2), que o núcleo não tem como impor: a
/// bombeada final antes de `peer_lost`, `peer_lost` antes do fechamento, o mesmo PIN depois de uma
/// queda, PIN novo depois de `WRONG_PIN`/`PAIRING`, o controle voltando sem PIN — e que o `changed`
/// da bombeada que devolve `CLOSED` chega à tela.
final class TestesDoLaco: XCTestCase {

    /// Um roteiro de respostas: cada abertura, bombeada e evento sai da fila na ordem.
    final class FronteiraFalsa: FronteiraDoLaco {
        var aberturas: [(Bool, StatusDaFronteira)] = []
        var bombeadas: [BombeadaDoLaco] = []
        var eventos: [EventoDaSessao] = []
        var perdido: MudancasDoTeleprompter = [.par]
        var chamadas: [String] = []
        var pinsSorteados = ["111111", "222222", "333333"]
        var aoAbrir: ((Int) -> Void)?
        var relogio = 0.0

        func abrir(pin: String?) -> (subiu: Bool, status: StatusDaFronteira, motivo: String) {
            chamadas.append("abrir(\(pin ?? "sem pin"))")
            aoAbrir?(chamadas.filter { $0.hasPrefix("abrir") }.count)
            guard !aberturas.isEmpty else { return (false, .cancelado, "fim do roteiro") }
            let (subiu, status) = aberturas.removeFirst()
            relogio += 0.1
            return (subiu, status, subiu ? "" : "motivo \(status.nome)")
        }

        func bombear(prazoMs: UInt32) -> BombeadaDoLaco {
            chamadas.append("bombear(\(prazoMs))")
            guard !bombeadas.isEmpty else { return BombeadaDoLaco(mudancas: [], fechada: false, status: .ok) }
            return bombeadas.removeFirst()
        }

        func proximoEvento() -> EventoDaSessao {
            chamadas.append("evento")
            return eventos.isEmpty ? .nenhum : eventos.removeFirst()
        }

        func perdeuOPar() -> MudancasDoTeleprompter {
            chamadas.append("peer_lost")
            return perdido
        }

        func fechar() { chamadas.append("fechar") }

        func sortearPin() -> String {
            chamadas.append("sortear")
            return pinsSorteados.removeFirst()
        }

        func dormir(ms: Int) {
            chamadas.append("dormir(\(ms))")
            relogio += Double(ms) / 1000
        }
    }

    private func correr(_ papel: PapelDoTeleprompter, _ f: FronteiraFalsa, pin: String?,
                        pararQuando: @escaping ([String]) -> Bool) -> [AvisoDoLaco] {
        var avisos: [AvisoDoLaco] = []
        let laco = LacoDoTeleprompter(papel: papel, fronteira: f,
                                      deveParar: { pararQuando(f.chamadas) },
                                      relogio: { f.relogio },
                                      avisar: { avisos.append($0) })
        laco.correr(pinInicial: pin)
        return avisos
    }

    /// A queda pela **bombeada**: `CLOSED` com `changed` preenchido — a pausa tocada antes da queda.
    /// Os bits chegam à tela antes de `peer_lost`, e `peer_lost` vem antes do fechamento.
    func test_closed_da_bombeada_aplica_changed_antes_de_peer_lost_e_fecha_depois() {
        let f = FronteiraFalsa()
        f.aberturas = [(true, .ok)]
        f.bombeadas = [
            BombeadaDoLaco(mudancas: [.texto], fechada: false, status: .ok),
            BombeadaDoLaco(mudancas: [.rolando], fechada: true, status: .fechado),
        ]
        let avisos = correr(.prompter, f, pin: "424242") { $0.contains("fechar") }
        XCTAssertEqual(Array(f.chamadas.prefix(6)),
                       ["abrir(424242)", "bombear(80)", "evento", "bombear(80)", "peer_lost", "fechar"],
                       "sem evento nem bombeada extra depois de CLOSED: a fila já foi lida até o fim")
        let mudancas = avisos.compactMap { a -> MudancasDoTeleprompter? in
            if case .mudou(let m) = a { return m } else { return nil }
        }
        XCTAssertEqual(mudancas, [[.texto], [.rolando], [.par]],
                       "o rolando da bombeada que devolveu CLOSED chega antes do peer_lost")
    }

    /// A queda pelo **evento**: bombeada final com prazo zero, e só então `peer_lost`.
    func test_disconnected_do_evento_faz_a_bombeada_final_com_prazo_zero() {
        let f = FronteiraFalsa()
        f.aberturas = [(true, .ok)]
        f.bombeadas = [
            BombeadaDoLaco(mudancas: [], fechada: false, status: .ok),
            BombeadaDoLaco(mudancas: [.rolando], fechada: false, status: .ok),
        ]
        f.eventos = [.desconectou]
        let avisos = correr(.prompter, f, pin: "424242") { $0.contains("fechar") }
        XCTAssertEqual(Array(f.chamadas.prefix(6)),
                       ["abrir(424242)", "bombear(80)", "evento", "bombear(0)", "peer_lost", "fechar"])
        XCTAssertTrue(avisos.contains(.mudou([.rolando])), "o changed da bombeada final chega à tela")
        XCTAssertTrue(avisos.contains(.caiu(porque: "o outro lado saiu (DISCONNECTED)")))
    }

    /// **Prompter: depois da queda de uma sessão que subiu, o mesmo PIN.**
    func test_prompter_hospeda_de_novo_com_o_mesmo_pin_depois_da_queda() {
        let f = FronteiraFalsa()
        f.aberturas = [(true, .ok), (true, .ok)]
        f.eventos = [.desconectou, .falhou]
        _ = correr(.prompter, f, pin: "424242") { $0.filter { $0 == "fechar" }.count == 2 }
        let aberturas = f.chamadas.filter { $0.hasPrefix("abrir") }
        XCTAssertEqual(aberturas, ["abrir(424242)", "abrir(424242)"])
        XCTAssertFalse(f.chamadas.contains("sortear"))
        // Fechar vem sempre antes da abertura seguinte: é ele que solta a porta.
        let i = f.chamadas.firstIndex(of: "fechar")!
        let j = f.chamadas.lastIndex(where: { $0.hasPrefix("abrir") })!
        XCTAssertLessThan(i, j)
    }

    /// **Prompter: depois de `WRONG_PIN` ou `PAIRING` numa espera, PIN novo** — nunca o mesmo.
    func test_prompter_troca_o_pin_depois_de_pin_errado_e_de_pareamento() {
        let f = FronteiraFalsa()
        f.aberturas = [(false, .pinErrado), (false, .pareamento), (false, .prazo), (true, .ok)]
        f.eventos = [.desconectou]
        let avisos = correr(.prompter, f, pin: "424242") { $0.contains("fechar") }
        XCTAssertEqual(f.chamadas.filter { $0.hasPrefix("abrir") },
                       ["abrir(424242)", "abrir(111111)", "abrir(222222)", "abrir(222222)"],
                       "PIN novo depois de WRONG_PIN e de PAIRING; o prazo estourado mantém o PIN")
        XCTAssertEqual(f.chamadas.filter { $0.hasPrefix("dormir") }, ["dormir(1000)", "dormir(2000)", "dormir(900)"])
        XCTAssertTrue(avisos.contains(.abrindo(pin: "111111", tentativa: 2)), "a tela ouve o PIN novo")
    }

    /// **PIN errado seguido não vira força bruta**: espera crescente (1, 2, 4, 8 s) e, no quinto erro
    /// seguido, o prompter para de reabrir sozinho. Uma sessão que sobe zera a conta.
    func test_pin_errado_seguido_espera_cada_vez_mais_e_para_no_quinto() {
        let f = FronteiraFalsa()
        f.pinsSorteados = ["1", "2", "3", "4", "5", "6"]
        f.aberturas = Array(repeating: (false, StatusDaFronteira.pinErrado), count: 6)
        let avisos = correr(.prompter, f, pin: "424242") { _ in false }
        XCTAssertEqual(f.chamadas.filter { $0.hasPrefix("dormir") },
                       ["dormir(1000)", "dormir(2000)", "dormir(4000)", "dormir(8000)"])
        XCTAssertEqual(f.chamadas.filter { $0.hasPrefix("abrir") }.count, 5, "cinco tentativas, e para")
        XCTAssertEqual(avisos.last, .terminou(porque: "falhou: WRONG_PIN"))
        // A conta recomeça depois de uma sessão que subiu.
        XCTAssertEqual(LacoDoTeleprompter.decidir(papel: .prompter, status: .pinErrado, jaSubiu: true,
                                                  durouMs: 5000, falhandoHaMs: 5000,
                                                  errosDePinSeguidos: 1, parando: false),
                       .tentarDeNovo(pin: .novo, depoisDeMs: 1000))
    }

    /// Defeito que não se cura tentando de novo não vira laço eterno: `INVALID` para na hora, e
    /// `SIGNALING` (um `pares.json` que não se lê) para na terceira seguida.
    func test_prompter_para_no_que_nao_e_rede() {
        XCTAssertEqual(LacoDoTeleprompter.decidir(papel: .prompter, status: .invalido, jaSubiu: false,
                                                  durouMs: 5, falhandoHaMs: 5, parando: false), .parar)
        XCTAssertEqual(LacoDoTeleprompter.decidir(papel: .prompter, status: .sinalizacao, jaSubiu: false,
                                                  durouMs: 5, falhandoHaMs: 5, falhasSeguidas: 2, parando: false),
                       .tentarDeNovo(pin: .mesmo, depoisDeMs: 1000))
        XCTAssertEqual(LacoDoTeleprompter.decidir(papel: .prompter, status: .sinalizacao, jaSubiu: false,
                                                  durouMs: 5, falhandoHaMs: 5, falhasSeguidas: 3, parando: false),
                       .parar)
        XCTAssertEqual(LacoDoTeleprompter.decidir(papel: .controle, status: .sinalizacao, jaSubiu: true,
                                                  durouMs: 5, falhandoHaMs: 5, parando: false),
                       .parar, "a recusa de uma build antiga precisa da pessoa")
    }

    /// Uma falha rápida (porta ocupada) espera o resto do segundo: sem laço quente.
    func test_falha_rapida_espera_antes_de_tentar_de_novo() {
        let f = FronteiraFalsa()
        f.aberturas = [(false, .io), (true, .ok)]
        f.eventos = [.desconectou]
        _ = correr(.prompter, f, pin: "424242") { $0.contains("fechar") }
        XCTAssertEqual(Array(f.chamadas.prefix(3)), ["abrir(424242)", "dormir(900)", "abrir(424242)"])
    }

    /// **Controle: volta pelo par conhecido, sem PIN, e insiste no `BUSY`** enquanto o prompter
    /// ainda não percebeu a queda da sessão velha.
    func test_controle_volta_sem_pin_e_insiste_no_ocupado() {
        let f = FronteiraFalsa()
        f.aberturas = [(true, .ok), (false, .ocupado), (false, .ocupado), (false, .io), (true, .ok)]
        f.eventos = [.desconectou, .desconectou]
        let avisos = correr(.controle, f, pin: "424242") { $0.filter { $0 == "fechar" }.count == 2 }
        XCTAssertEqual(f.chamadas.filter { $0.hasPrefix("abrir") },
                       ["abrir(424242)", "abrir(sem pin)", "abrir(sem pin)", "abrir(sem pin)", "abrir(sem pin)"])
        let fins = avisos.filter { if case .terminou = $0 { return true } else { return false } }
        XCTAssertEqual(fins, [.terminou(porque: "parada")], "nenhuma falha de reconexão encerra o laço")
    }

    /// Controle, **antes** de a primeira sessão subir: PIN errado, par desconhecido e aparelho que
    /// não é teleprompter param e voltam para a pessoa; uma falha de rede também (ela digitou algo
    /// errado, e tentar para sempre esconderia isso).
    func test_controle_para_no_que_precisa_da_pessoa() {
        for status in [StatusDaFronteira.pinErrado, .precisaDePin, .pareamento, .protocolo, .io, .prazo] {
            let f = FronteiraFalsa()
            f.aberturas = [(false, status)]
            let avisos = correr(.controle, f, pin: "424242") { _ in false }
            XCTAssertEqual(f.chamadas, ["abrir(424242)"], "\(status.nome): uma tentativa só")
            XCTAssertEqual(avisos.last, .terminou(porque: "falhou: \(status.nome)"))
        }
    }

    /// Controle diante de `BUSY` na primeira vez: insiste até 12 s e desiste com o motivo.
    func test_controle_desiste_do_ocupado_na_primeira_vez_depois_do_prazo() {
        XCTAssertEqual(LacoDoTeleprompter.decidir(papel: .controle, status: .ocupado, jaSubiu: false,
                                                  durouMs: 50, falhandoHaMs: 11_000, parando: false),
                       .tentarDeNovo(pin: .mesmo, depoisDeMs: 950))
        XCTAssertEqual(LacoDoTeleprompter.decidir(papel: .controle, status: .ocupado, jaSubiu: false,
                                                  durouMs: 50, falhandoHaMs: 12_500, parando: false),
                       .parar)
        XCTAssertEqual(LacoDoTeleprompter.decidir(papel: .controle, status: .ocupado, jaSubiu: true,
                                                  durouMs: 50, falhandoHaMs: 60_000, parando: false),
                       .tentarDeNovo(pin: .mesmo, depoisDeMs: 950),
                       "depois de uma queda, o controle insiste até entrar")
    }

    /// Cancelar é o caminho normal de sair, nos dois papéis.
    func test_cancelar_para_sem_tentar_de_novo() {
        for papel in [PapelDoTeleprompter.prompter, .controle] {
            XCTAssertEqual(LacoDoTeleprompter.decidir(papel: papel, status: .cancelado, jaSubiu: true,
                                                      durouMs: 10, falhandoHaMs: 10, parando: false), .parar)
            XCTAssertEqual(LacoDoTeleprompter.decidir(papel: papel, status: .prazo, jaSubiu: true,
                                                      durouMs: 10, falhandoHaMs: 10, parando: true), .parar)
        }
    }

    /// A pessoa para com a sessão de pé: o que já chegou entra (bombeada com prazo zero), e a
    /// ordem do fim é a mesma da queda.
    func test_parar_com_a_sessao_de_pe_segue_a_mesma_ordem_do_fim() {
        let f = FronteiraFalsa()
        f.aberturas = [(true, .ok)]
        f.bombeadas = [BombeadaDoLaco(mudancas: [], fechada: false, status: .ok),
                       BombeadaDoLaco(mudancas: [.velocidade], fechada: false, status: .ok)]
        // A pessoa para depois da primeira volta da sessão (o primeiro evento já foi lido).
        let avisos = correr(.controle, f, pin: "424242") { $0.contains("evento") }
        XCTAssertEqual(f.chamadas, ["abrir(424242)", "bombear(80)", "evento", "bombear(0)", "peer_lost", "fechar"])
        XCTAssertTrue(avisos.contains(.mudou([.velocidade])), "o que já tinha chegado entra antes de fechar")
        XCTAssertTrue(avisos.contains(.caiu(porque: "parada")))
        XCTAssertEqual(avisos.last, .terminou(porque: "parada"))
    }
}
