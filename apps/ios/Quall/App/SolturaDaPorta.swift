import Foundation

/// **A porta de sinalização da câmera entre uma tela e a seguinte** (defeito de 27/09, iPhone X):
/// fechar a tela "Teleprompter com câmera" no X e reabrir mostrava "a porta está ocupada", e só
/// fechar o app liberava.
///
/// A causa foi a cutucada (`EmissorDeCamera`, até 27/09): uma conexão TCP descartável para o
/// próprio endereço, que fazia o `quall_host` voltar com "handshake WebSocket falhou". O conserto
/// de 01/09 no núcleo (`SignalingServer::aceitar_um`, `crates/quall-core/src/signaling.rs`) passou
/// a **descartar** o candidato que morre no handshake e a continuar esperando até o prazo — certo
/// para o produto (quem desiste não derruba a espera), e o fim silencioso da cutucada: a espera
/// da tela fechada seguia na 7877 por até 20 s (`prazoPorTentativa`), e a tela nova batia em
/// `Address already in use`. O conselho da porta ocupada ficava na tela até alguém conectar.
///
/// O conserto tem duas metades, e esta é a segunda:
///
/// 1. o `quall_host` passa a ser `quall_host_cancelable`, e fechar a tela aciona o cancelador:
///    o `accept` do núcleo olha a bandeira a cada 20 ms, e o listener cai quando a chamada volta;
/// 2. **a tela nova espera a soltura com prazo curto, calada**: primeiro o laço da tela anterior
///    terminar (`esperarOsOutros`), depois, se ainda assim a porta estiver presa (o desmonte de
///    uma sessão que estava de pé, dívida 19), repete a espera sem aviso por até
///    `tolerancia` segundos (`repetirCalado`). Só depois disso a pessoa lê que a porta está
///    ocupada — e o laço continua tentando.
///
/// Tudo aqui é puro (Foundation, sem núcleo nem UIKit): roda no `Testes/rodar.sh`.
final class SolturaDaPorta {

    /// Quanto a tela nova espera, calada, pela soltura da anterior. Pedido do defeito: ~2 s.
    static let tolerancia: Double = 2

    /// A porta da câmera (a mesma do espelhamento): um registro por processo.
    static let daCamera = SolturaDaPorta()

    private let condicao = NSCondition()
    private var vivos = 0

    /// Quantos laços de hospedagem estão vivos nesta porta agora.
    var lacosVivos: Int {
        condicao.lock(); defer { condicao.unlock() }
        return vivos
    }

    /// Um laço de hospedagem começou a usar a porta.
    func entrar() {
        condicao.lock(); vivos += 1; condicao.unlock()
    }

    /// O laço terminou: a chamada bloqueante voltou e a sessão (se havia) foi fechada, isto é, o
    /// listener do núcleo já caiu.
    func sair() {
        condicao.lock()
        vivos = max(0, vivos - 1)
        condicao.broadcast()
        condicao.unlock()
    }

    /// Espera até `prazo` segundos que **nenhum outro** laço esteja vivo (o chamador ainda não
    /// entrou). Devolve quantos continuavam vivos ao fim: `0` é a porta livre de laço nosso.
    @discardableResult
    func esperarOsOutros(prazo: Double) -> Int {
        let fim = Date().addingTimeInterval(max(0, prazo))
        condicao.lock(); defer { condicao.unlock() }
        while vivos > 0 {
            if !condicao.wait(until: fim) { break }
        }
        return vivos
    }

    /// O erro de `quall_host` é a porta presa? O `bind` falha com o `io::Error` do sistema, que o
    /// núcleo passa adiante como `Error::Io` (prefixo `e/s:`, `crates/quall-core/src/error.rs`).
    /// `EADDRINUSE` é 48 no Darwin; o texto é o do `strerror`. Os dois, porque o texto muda com o
    /// idioma da libc e o número não.
    static func ehPortaOcupada(_ erro: String) -> Bool {
        guard erro.hasPrefix("e/s:") else { return false }
        return erro.localizedCaseInsensitiveContains("address already in use")
            || erro.contains("os error 48")
    }

    /// A falha é a porta presa e ainda estamos dentro da tolerância contada **do começo do laço**:
    /// tentar de novo, sem conselho e sem contar para o teto de tentativas.
    static func repetirCalado(erro: String, desdeOComeco segundos: Double) -> Bool {
        ehPortaOcupada(erro) && segundos < tolerancia
    }
}
