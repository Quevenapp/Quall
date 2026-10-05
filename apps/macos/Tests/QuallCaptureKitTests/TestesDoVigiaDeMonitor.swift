import CoreGraphics
import XCTest
@testable import QuallCaptureKit

/// O que o `VigiaDeMonitor` faz **depois** que alguma testemunha chega.
///
/// # O que este teste prova, e o que ele não prova
///
/// Ele prova a metade que não depende de ninguém puxar um cabo: que uma testemunha derruba a
/// sessão, que a janela de tolerância colhe as outras antes de fechar, que a mesma testemunha
/// repetida não vira quatro linhas iguais, e que o relato final nomeia **quem não veio** — que é a
/// metade do achado que se perde quando só se registra o que aconteceu.
///
/// Ele **não** prova que o macOS avisa. Essa é pergunta de máquina, com o cabo na mão, e a
/// resposta está em `docs/app-macos.md`. A separação é deliberada: sem estes testes, uma corrida
/// de desplugue que não detectasse nada teria duas explicações — "o sistema não avisou" e "o vigia
/// está quebrado" — e nenhuma forma barata de distinguir. Com eles, sobra uma.
final class TestesDoVigiaDeMonitor: XCTestCase {

    /// Um id que não existe em máquina nenhuma, para o vigia nunca achar a tela na enumeração.
    private static let inexistente: CGDirectDisplayID = 0xDEAD_BEEF

    /// **Uma testemunha derruba, e derruba uma vez só.**
    func testeUmaTestemunhaDerrubaASessao() {
        let vigia = VigiaDeMonitor(monitorada: Self.inexistente, nomeDoMonitor: "TV de teste",
                                   janelaDeTolerancia: 0.1, periodoDaRonda: 10)
        let caiu = expectation(description: "o vigia avisou que o monitor sumiu")
        var colhidas: [VigiaDeMonitor.Testemunha] = []
        vigia.aoSumir = { t in
            colhidas = t
            caiu.fulfill()
        }
        vigia.registrarTestemunhaExterna(nome: "SCStream.didStopWithError", detalhe: "erro de teste")
        wait(for: [caiu], timeout: 2)

        XCTAssertEqual(colhidas.count, 1)
        XCTAssertEqual(colhidas.first?.nome, "SCStream.didStopWithError")
        XCTAssertEqual(colhidas.first?.msDesdeAPrimeira ?? -1, 0, accuracy: 0.001,
                       "a primeira testemunha é a origem do tempo")
        vigia.parar()
    }

    /// **A janela de tolerância existe para colher as outras testemunhas**, e é isso que permite a
    /// frase "fulano não disparou em N segundos" em vez do impreciso "fulano não disparou".
    func testeAJanelaDeToleranciaColheAsTestemunhasSeguintes() {
        let vigia = VigiaDeMonitor(monitorada: Self.inexistente, nomeDoMonitor: "TV de teste",
                                   janelaDeTolerancia: 0.4, periodoDaRonda: 10)
        let caiu = expectation(description: "fechou a janela")
        var colhidas: [VigiaDeMonitor.Testemunha] = []
        vigia.aoSumir = { t in
            colhidas = t
            caiu.fulfill()
        }

        vigia.registrarTestemunhaExterna(nome: "SCStream.didStopWithError", detalhe: "primeira")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            vigia.registrarTestemunhaExterna(nome: "CGDisplayReconfiguration", detalhe: "segunda")
        }
        wait(for: [caiu], timeout: 3)

        XCTAssertEqual(colhidas.count, 2, "a segunda testemunha chegou dentro da janela e foi perdida")
        XCTAssertEqual(colhidas[0].nome, "SCStream.didStopWithError")
        XCTAssertEqual(colhidas[1].nome, "CGDisplayReconfiguration")
        // O intervalo entre as duas é o número que a bancada relata. Faixa larga de propósito:
        // o que se afirma é que ele foi medido e é positivo, não que o agendador seja pontual.
        XCTAssertGreaterThan(colhidas[1].msDesdeAPrimeira, 100)
        XCTAssertLessThan(colhidas[1].msDesdeAPrimeira, 400)
        vigia.parar()
    }

    /// **A mesma testemunha repetida não vira quatro linhas iguais.**
    ///
    /// A ronda dispara cinco vezes por segundo. Sem esta regra, uma janela de 3 s encheria o
    /// relato com quinze linhas de reenumeração e esconderia as outras três — que são justamente
    /// as que respondem a pergunta.
    func testeATestemunhaRepetidaNaoDuplica() {
        let vigia = VigiaDeMonitor(monitorada: Self.inexistente, nomeDoMonitor: "TV de teste",
                                   janelaDeTolerancia: 0.2, periodoDaRonda: 10)
        let caiu = expectation(description: "fechou")
        var colhidas: [VigiaDeMonitor.Testemunha] = []
        vigia.aoSumir = { t in
            colhidas = t
            caiu.fulfill()
        }
        for _ in 0..<10 {
            vigia.registrarTestemunhaExterna(nome: "reenumeração (CGGetActiveDisplayList)", detalhe: "ronda")
        }
        wait(for: [caiu], timeout: 3)
        XCTAssertEqual(colhidas.count, 1)
        vigia.parar()
    }

    /// **Depois de fechar, o vigia fica calado.** Uma testemunha atrasada não pode derrubar uma
    /// sessão que já caiu — nem chamar `aoSumir` uma segunda vez sobre um objeto já desmontado.
    func testeDepoisDeFecharNaoAvisaDeNovo() {
        let vigia = VigiaDeMonitor(monitorada: Self.inexistente, nomeDoMonitor: "TV de teste",
                                   janelaDeTolerancia: 0.05, periodoDaRonda: 10)
        let caiu = expectation(description: "fechou")
        var vezes = 0
        vigia.aoSumir = { _ in
            vezes += 1
            caiu.fulfill()
        }
        vigia.registrarTestemunhaExterna(nome: "SCStream.didStopWithError", detalhe: "a")
        wait(for: [caiu], timeout: 2)
        vigia.registrarTestemunhaExterna(nome: "CGDisplayReconfiguration", detalhe: "atrasada")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(vezes, 1)
        vigia.parar()
    }

    /// **A ronda enxerga as telas de verdade desta máquina.**
    ///
    /// Não afirma quantas são — isso depende de quem plugou o quê — mas afirma que a enumeração
    /// responde e que a tela principal está nela. Uma ronda que devolvesse lista vazia declararia
    /// todo monitor como sumido, o que derrubaria toda sessão em 200 ms.
    func testeARondaEnxergaATelaPrincipal() {
        let ativas = VigiaDeMonitor.telasAtivas()
        XCTAssertFalse(ativas.isEmpty, "CGGetActiveDisplayList não devolveu tela nenhuma")
        XCTAssertTrue(ativas.contains(CGMainDisplayID()),
                      "a tela principal não está na lista de ativas — a ronda daria falso positivo")
    }

    /// **Uma tela que existe não dispara nada.** É o controle do teste acima: sem ele, um vigia
    /// que gritasse sempre passaria em todos os outros.
    func testeUmaTelaQueExisteNaoDisparaNada() {
        let vigia = VigiaDeMonitor(monitorada: CGMainDisplayID(), nomeDoMonitor: "principal",
                                   janelaDeTolerancia: 0, periodoDaRonda: 0.05)
        var disparou = false
        vigia.aoSumir = { _ in disparou = true }
        vigia.comecar()
        Thread.sleep(forTimeInterval: 0.5)
        vigia.parar()
        XCTAssertFalse(disparou, "o vigia declarou sumida uma tela que está ligada")
    }
}
