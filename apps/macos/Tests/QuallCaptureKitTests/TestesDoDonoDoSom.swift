import XCTest
@testable import QuallCaptureKit

/// D2 do `docs/som-no-receptor.md` §12.1: só o primeiro receptor **que toca** fica com o som na tela
/// estendida; quando ele sai, o som passa ao próximo que toca — com a passagem ligada. Desligada,
/// o som só vai para quem conectar com ninguém tocando.
final class TestesDoDonoDoSom: XCTestCase {

    func testeSoOPrimeiroReceptorToca() {
        var d = DonoDoSom(passar: true)
        XCTAssertEqual(d.conectou(1, toca: true), 1, "o primeiro a conectar toca")
        XCTAssertNil(d.conectou(2, toca: true), "o segundo não toma o som")
        XCTAssertNil(d.conectou(3, toca: true))
        XCTAssertEqual(d.dono, 1)
        XCTAssertNil(d.conectou(2, toca: true), "conectar de novo não muda nada")
    }

    func testeComAPassagemOSomVaiAoProximoNaOrdemDeConexao() {
        var d = DonoDoSom(passar: true)
        d.conectou(4, toca: true); d.conectou(2, toca: true); d.conectou(9, toca: true)
        XCTAssertNil(d.saiu(2), "quem saiu não era o dono: nada muda")
        XCTAssertEqual(d.dono, 4)
        XCTAssertEqual(d.saiu(4), 9, "o dono saiu: o som passa ao próximo que ainda está")
        XCTAssertEqual(d.dono, 9)
        XCTAssertNil(d.saiu(9), "não sobrou ninguém")
        XCTAssertNil(d.dono)
        XCTAssertEqual(d.conectou(5, toca: true), 5, "ninguém tocando: quem conecta toca")
    }

    func testeSemAPassagemOSomNaoVaiAQuemJaEstava() {
        var d = DonoDoSom(passar: false)
        d.conectou(1, toca: true); d.conectou(2, toca: true)
        XCTAssertNil(d.saiu(1), "o dono saiu e a passagem está desligada: ninguém toca")
        XCTAssertNil(d.dono)
        XCTAssertEqual(d.conectadas.map(\.id), [2], "o 2 continua conectado, calado")
        XCTAssertEqual(d.conectou(3, toca: true), 3, "quem conecta com ninguém tocando toca: o comportamento de antes")
        XCTAssertNil(d.saiu(2))
        XCTAssertEqual(d.dono, 3)
    }

    func testeLigarAPassagemDepoisValeNaProximaSaida() {
        var d = DonoDoSom(passar: false)
        d.conectou(1, toca: true); d.conectou(2, toca: true)
        d.passar = true
        XCTAssertEqual(d.saiu(1), 2)
        d.zerar()
        XCTAssertNil(d.dono)
        XCTAssertTrue(d.conectadas.isEmpty)
    }

    /// **Crítica 9, M3**: um iPhone primeiro (não toca PCMU) e um tablet Android depois. Antes, o
    /// dono era o iPhone e os dois ficavam mudos. Agora o dono é o tablet; e o iPhone, que entrou
    /// antes, continua sem o som mesmo depois que o tablet sai.
    func testeODonoEOPrimeiroQueToca() {
        var d = DonoDoSom(passar: true)
        XCTAssertNil(d.conectou(1, toca: false), "o iPhone não toca: não é dono")
        XCTAssertEqual(d.conectou(2, toca: true), 2, "o tablet é o primeiro que toca")
        XCTAssertEqual(d.conectou(3, toca: true), nil)
        XCTAssertEqual(d.saiu(2), 3, "o som passa ao próximo que toca, pulando o iPhone")
        XCTAssertNil(d.saiu(3), "sobrou só o iPhone, que não toca")
        XCTAssertNil(d.dono)
    }

    /// **Crítica 9, M2**: o tablet A (dono) volta pela sessão 3 antes de a 1 cair. Antes, a 1 saía,
    /// o som ia ao B, e a 3 entrava calada. Agora a 3 herda o som e a vaga da 1.
    func testeODonoQueReconectaMantemOSom() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true); d.conectou(2, toca: true)
        XCTAssertEqual(d.substituir(1, por: 3, novoToca: true), 3, "a sessão nova herda o som")
        XCTAssertEqual(d.dono, 3)
        XCTAssertEqual(d.conectadas.map(\.id), [3, 2], "e a vaga na fila")
        XCTAssertNil(d.saiu(1), "a velha sair depois não passa o som a ninguém")
        XCTAssertEqual(d.dono, 3)
        XCTAssertNil(d.conectou(3, toca: true), "a transmissão da nova começando não muda nada")
        // Quem não era dono também só troca de sessão.
        XCTAssertNil(d.substituir(2, por: 4, novoToca: true))
        XCTAssertEqual(d.dono, 3)
        XCTAssertEqual(d.conectadas.map(\.id), [3, 4])
    }

    // MARK: - a carência de 10 s (decisão do Pessoa Exemplo de 18/09): os mesmos casos de `som_puxado.rs`

    func testeODonoQueCaiEVoltaEm10sMantemOSom() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a", agoraMs: 0)
        d.conectou(2, toca: true, aparelho: "mac-b", agoraMs: 0)
        XCTAssertNil(d.caiu(1, agoraMs: 1_000), "o som não passa na queda")
        XCTAssertNil(d.dono, "nos 10 s ninguém toca")
        XCTAssertEqual(d.carencia?.aparelho, "android-a")
        XCTAssertEqual(d.carencia?.ate, 11_000)
        XCTAssertNil(d.tique(agoraMs: 10_999))
        XCTAssertEqual(d.conectou(3, toca: true, aparelho: "android-a", agoraMs: 10_999), 3,
                       "o mesmo aparelho volta e o som é dele")
        XCTAssertNil(d.carencia)
        XCTAssertNil(d.tique(agoraMs: 20_000), "sem carência, o relógio não mexe")
        XCTAssertEqual(d.dono, 3)
    }

    func testeDepoisDe10sOSomPassaAoProximo() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a", agoraMs: 0)
        d.conectou(2, toca: true, aparelho: "mac-b", agoraMs: 0)
        d.caiu(1, agoraMs: 1_000)
        XCTAssertEqual(d.tique(agoraMs: 11_000), 2, "vencido o prazo, passa ao próximo que toca")
        XCTAssertNil(d.conectou(3, toca: true, aparelho: "android-a", agoraMs: 12_000),
                     "o dono antigo volta tarde e fica calado")
        XCTAssertEqual(d.dono, 2)
    }

    func testeNos10sNinguemTocaNemQuemChega() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a", agoraMs: 0)
        d.conectou(2, toca: true, aparelho: "mac-b", agoraMs: 0)
        d.caiu(1, agoraMs: 1_000)
        XCTAssertNil(d.conectou(3, toca: true, aparelho: "ios-c", agoraMs: 2_000), "quem chega na carência não pega o som")
        XCTAssertNil(d.saiu(2), "quem sai na carência não passa nada")
        XCTAssertNil(d.dono)
        XCTAssertEqual(d.conectou(4, toca: true, aparelho: "win-d", agoraMs: 11_500), 3,
                       "a chegada depois do prazo vence a carência primeiro")
    }

    func testeQuemSaiPorGestoPassaNaHora() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a", agoraMs: 0)
        d.conectou(2, toca: true, aparelho: "mac-b", agoraMs: 0)
        XCTAssertEqual(d.saiu(1), 2)
        XCTAssertNil(d.carencia)
    }

    func testeODonoQueVoltaSemTocarPassaNaHora() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a", agoraMs: 0)
        d.conectou(2, toca: true, aparelho: "mac-b", agoraMs: 0)
        d.caiu(1, agoraMs: 1_000)
        XCTAssertEqual(d.conectou(3, toca: false, aparelho: "android-a", agoraMs: 2_000), 2,
                       "voltou por um app que não toca")
        XCTAssertNil(d.carencia)
    }

    func testeASessaoSemSomNaoSeguraOSom() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a", agoraMs: 0)
        d.conectou(2, toca: true, aparelho: "mac-b", agoraMs: 0)
        XCTAssertEqual(d.naoToca(1), 2, "a dona que perdeu o som passa na hora")
        XCTAssertNil(d.naoToca(2), "sem ninguém que toque, fica sem dono")
        XCTAssertNil(d.dono)
    }

    /// **O M2 da crítica 13, na ordem que o derrubava**: a queda chega antes da volta, e a volta
    /// entra por ``DonoDoSom/substituir(_:por:novoToca:aparelho:agoraMs:)`` (a velha ainda desmonta).
    func testeODonoQueCaiAntesDeVoltarMantemOSom() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a", agoraMs: 0)
        d.conectou(2, toca: true, aparelho: "mac-b", agoraMs: 0)
        d.caiu(1, agoraMs: 1_000)
        XCTAssertEqual(d.substituir(1, por: 3, novoToca: true, aparelho: "android-a", agoraMs: 4_000), 3)
        XCTAssertEqual(d.dono, 3)
        XCTAssertNil(d.saiu(1), "a velha terminar de sair não mexe no som")
    }

    func testeATabelaDeQuemTocaOPCMUDoMac() {
        XCTAssertTrue(QuemTocaOSomDoMac.tocaPCMU(deviceId: "mac-811cbe47-afb9"))
        XCTAssertTrue(QuemTocaOSomDoMac.tocaPCMU(deviceId: "android-1234"))
        XCTAssertFalse(QuemTocaOSomDoMac.tocaPCMU(deviceId: "ios-abcd"), "o iOS só toca Opus (R6)")
        XCTAssertFalse(QuemTocaOSomDoMac.tocaPCMU(deviceId: "win-abcd"),
                       "o Windows toca desde a S6, mas o app do Dell do Pessoa Exemplo ainda é de antes (crítica 13, M4)")
        XCTAssertFalse(QuemTocaOSomDoMac.tocaPCMU(deviceId: "9e7b34b1-6c0a-4f3d-9e2a-1c4d5b6a7e80"),
                       "o OBS e o app da câmera usam UUID puro, e não tocam")
        XCTAssertFalse(QuemTocaOSomDoMac.tocaPCMU(deviceId: "probe-182bda"))
    }

    /// Crítica 18, F2: o som da sessão voltou. Ela volta a ser candidata sem tomar o som; ganha só
    /// se ninguém o tem e nenhuma carência o espera.
    func testeOSomQueVoltaNaoTomaOSomDeQuemTem() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a")
        d.conectou(2, toca: true, aparelho: "mac-b")
        XCTAssertEqual(d.naoToca(1), 2)
        XCTAssertNil(d.voltouOSom(1, toca: true), "a 2 tem o som: a 1 só volta à fila")
        XCTAssertEqual(d.dono, 2)
        XCTAssertEqual(d.saiu(2), 1, "a 2 sai: o som passa à 1, que voltou")

        var e = DonoDoSom(passar: true)
        e.conectou(1, toca: true, aparelho: "android-a")
        e.naoToca(1)
        XCTAssertNil(e.dono, "sozinha e sem som: ninguém toca")
        XCTAssertEqual(e.voltouOSom(1, toca: true), 1, "o som voltou e ninguém tocava: é dela")

        var f = DonoDoSom(passar: true)
        f.conectou(1, toca: true, aparelho: "android-a")
        f.conectou(2, toca: true, aparelho: "mac-b")
        f.naoToca(2)
        f.caiu(1, agoraMs: 1_000)
        XCTAssertNil(f.voltouOSom(2, toca: true), "a carência do dono que caiu segura o som")
        XCTAssertNil(f.dono)
        XCTAssertEqual(f.tique(agoraMs: 11_000), 2, "vencida a carência, o som vai à que voltou")

        var g = DonoDoSom(passar: true)
        g.conectou(1, toca: false, aparelho: "ios-a")
        g.naoToca(1)
        XCTAssertNil(g.voltouOSom(1, toca: false), "quem não toca o PCMU continua sem ser candidata")
        XCTAssertNil(g.dono)
    }
}
