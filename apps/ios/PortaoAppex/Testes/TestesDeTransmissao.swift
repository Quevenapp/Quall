import XCTest

/// Dispensa o toque humano no seletor de transmissão — onde a plataforma deixa.
///
/// A appex não é lançada por nós: quem a cria é o sistema, a partir do seletor. O botão
/// "Iniciar transmissão" da folha do sistema é, normalmente, um toque de pessoa. Este teste
/// alcança essa folha por XCUITest.
///
/// Limite medido: `xcodebuild test` recusa o iPhone 7 (iOS 15.8.8) e o iPhone X (iOS 16.7.16)
/// com "Logic Testing Unavailable" — mensagem enganosa, porque o mesmo alvo compila com
/// `build-for-testing` para os três aparelhos e **roda** no iPad (iPadOS 26.6). Ou seja: no
/// aparelho que o M3 exige, o toque continua sendo humano.
final class TestesDeTransmissao: XCTestCase {

    private let rotulosIniciar = ["Iniciar transmissão", "Iniciar Transmissão", "Start Broadcast"]
    private let rotulosParar = ["Parar transmissão", "Parar Transmissão", "Stop Broadcast"]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// Idempotente de propósito: se já houver transmissão em curso, para primeiro.
    /// Parar produz `broadcastFinished` e começar produz `broadcastStarted` — as duas linhas
    /// de `os_log` que provam a observação de fora, numa captura só.
    func testCicloDeTransmissao() throws {
        let app = XCUIApplication()
        app.launch()

        let abrir = app.buttons["Abrir seletor"]
        XCTAssertTrue(abrir.waitForExistence(timeout: 20), "não achei o botão do app")

        // Volta 1: se estiver transmitindo, para.
        abrir.tap()
        Thread.sleep(forTimeInterval: 3)
        if tocar(rotulosParar, app) {
            print("QUALL-PAROU a transmissão que já estava em curso")
            Thread.sleep(forTimeInterval: 6)
            abrir.tap()
            Thread.sleep(forTimeInterval: 3)
        }

        // Volta 2: começa.
        guard tocar(rotulosIniciar, app) else {
            print("QUALL-ARVORE-APP\n\(app.debugDescription)")
            print("QUALL-ARVORE-SPRINGBOARD\n\(XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)")
            XCTFail("não achei o botão de iniciar transmissão")
            return
        }
        print("QUALL-INICIOU")

        // Tela deliberadamente imóvel: é a condição que o degrau 3 mede.
        let segundos = Double(ProcessInfo.processInfo.environment["QUALL_SEGUNDOS"] ?? "") ?? 75
        print("QUALL-ESPERANDO \(segundos) s com a tela parada")
        Thread.sleep(forTimeInterval: segundos)
        print("QUALL-FIM-DA-ESPERA")

        // Encerra, para deixar o aparelho num estado conhecido para a próxima rodada.
        abrir.tap()
        Thread.sleep(forTimeInterval: 3)
        if tocar(rotulosParar, app) { print("QUALL-ENCERROU") }
        Thread.sleep(forTimeInterval: 5)
    }

    /// A folha do sistema é um `_UIRemoteView`: ela se redesenha e invalida o elemento entre a
    /// consulta e o toque. Sem repetição, o toque morre com "no longer valid after interruption
    /// handling" — que foi exatamente o que aconteceu na primeira rodada.
    private func tocar(_ rotulos: [String], _ app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<4 {
            for alvo in [app, springboard] {
                for rotulo in rotulos {
                    let botao = alvo.buttons[rotulo]
                    if botao.waitForExistence(timeout: 2) && botao.isHittable {
                        botao.tap()
                        return true
                    }
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }
}
