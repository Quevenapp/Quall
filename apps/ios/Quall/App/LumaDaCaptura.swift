import Foundation
import CoreVideo

// --- a média de luma (R9, `docs/controles-de-camera.md` §5: a bandeira de bancada `luma_media`) ------

/// O estado da média de luma, fora do `DonoDaCaptura` para não mexer no leiaute dele. Sob `trava`.
final class ContadoresDeLuma {
    let trava = NSLock()
    var quadros: UInt64 = 0
    /// A janela do roteiro (`janelaDeLuma`): soma e quantas.
    var soma = 0.0
    var n = 0
    /// O custo de cada conta, em segundos, por janela de 10 s do relato.
    var custoSoma = 0.0
    var custoMaior = 0.0
    var contas = 0
}

extension DonoDaCaptura {
    /// Um por processo: só existe uma câmera aberta por vez.
    static let luma = ContadoresDeLuma()

    /// **Um quadro em 30**, na `fila`, dentro do `captureOutput`: a média do plano Y subamostrado
    /// (`MediaDeLuma`) e quanto ela custou. A linha do diário sai numa fila de utilidade: o
    /// `Diagnostico` não é chamado do caminho do quadro (a regra 3 dele). Só com `--luma-media`.
    func medirLuma(_ imagem: CVPixelBuffer) {
        let c = DonoDaCaptura.luma
        c.trava.lock()
        c.quadros &+= 1
        let vez = c.quadros
        c.trava.unlock()
        guard vez % 30 == 0 else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let m = MediaDeLuma.media(imagem)
        let custo = CFAbsoluteTimeGetCurrent() - t0
        c.trava.lock()
        if let m { c.soma += m; c.n += 1 }
        c.custoSoma += custo
        c.custoMaior = max(c.custoMaior, custo)
        c.contas += 1
        c.trava.unlock()
        DispatchQueue.global(qos: .utility).async {
            Diagnostico.nota(String(format: "APP CAMERA luma_media=%@ custo=%.0f µs quadro=%llu",
                                    m.map { String(format: "%.1f", $0) } ?? "?", custo * 1e6, vez))
        }
    }

    /// A média das contas desde a última chamada, e quantas foram (o roteiro de prova a usa por passo).
    func janelaDeLuma() -> (media: Double?, n: Int) {
        let c = DonoDaCaptura.luma
        c.trava.lock(); defer { c.trava.unlock() }
        let r = (c.n > 0 ? c.soma / Double(c.n) : nil, c.n)
        c.soma = 0
        c.n = 0
        return r
    }

    /// No relato de 10 s: o custo medido da conta (§5: "cada frente mede o custo antes de usar como
    /// prova").
    func relatarLuma() {
        guard BancadaDosControles.opcoes.lumaMedia else { return }
        let c = DonoDaCaptura.luma
        c.trava.lock()
        let (soma, maior, n) = (c.custoSoma, c.custoMaior, c.contas)
        c.custoSoma = 0; c.custoMaior = 0; c.contas = 0
        c.trava.unlock()
        Diagnostico.nota(String(format: "APP CAMERA luma_media custo: medio=%.0f µs maior=%.0f µs em %d contas"
                                + " (um quadro em 30; passo %d)",
                                n > 0 ? soma / Double(n) * 1e6 : 0, maior * 1e6, n, MediaDeLuma.passo))
    }
}
