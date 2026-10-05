import SwiftUI
import UIKit

/// Uma tela que **não para de mudar**, desenhada pelo app hospedeiro durante a corrida.
///
/// Não é enfeite: é condição experimental. A pergunta do degrau 4 é se a pegada da extension
/// estabiliza ou sobe ao longo de seis minutos, e a hipótese principal é o *churn* de alocador
/// das oito cópias que um quadro faz dentro da libdatachannel. Com a tela parada — que é o que
/// acontece se ninguém encostar no iPhone, e a instrução é justamente não encostar — o H.264
/// entrega quadros P de algumas centenas de bytes, o churn some, e a medição responderia com
/// precisão a uma pergunta mais fácil que a verdadeira.
///
/// O degrau 3 mediu a **entrega** com a tela imóvel de propósito, porque ali a pergunta era se o
/// ReplayKit continua entregando. Aqui a pergunta é outra, e a condição também tem de ser.
///
/// O agitador dá ao encoder o pior caso plausível de uma tela real: muitas arestas, cor
/// mudando, movimento em toda a área. Tudo em `CALayer` com ações implícitas desligadas — nenhum
/// `UIImage` por quadro, nenhuma alocação no laço. O custo fica no processo do **app**, que não
/// tem teto de 50 MB; o que se mede é a appex.
final class Agitador: UIView {
    private var blocos: [CALayer] = []
    private var relogio: CADisplayLink?
    private var semente: UInt64 = 0x2545F4914F6CDD1D
    private let contador = CATextLayer()
    private var giro = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        for _ in 0..<48 {
            let bloco = CALayer()
            bloco.actions = ["position": NSNull(), "bounds": NSNull(),
                             "backgroundColor": NSNull()]
            layer.addSublayer(bloco)
            blocos.append(bloco)
        }
        // Texto pequeno e mudando: aresta fina é o que mais custa a um encoder de tela, e é
        // exatamente o conteúdo que o produto precisa entregar legível.
        contador.fontSize = 22
        contador.foregroundColor = UIColor.white.cgColor
        contador.alignmentMode = .center
        contador.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer.addSublayer(contador)

        let d = CADisplayLink(target: self, selector: #selector(passo))
        d.preferredFramesPerSecond = 30
        d.add(to: .main, forMode: .common)
        relogio = d
    }

    required init?(coder: NSCoder) { nil }

    deinit { relogio?.invalidate() }

    /// Gerador barato e determinístico: `arc4random` por bloco por quadro seria syscall no laço
    /// de animação, e o ponto é não perturbar a medição com custo do instrumento.
    private func proximo() -> UInt64 {
        semente ^= semente << 13
        semente ^= semente >> 7
        semente ^= semente << 17
        return semente
    }

    @objc private func passo() {
        guard bounds.width > 1 else { return }
        giro += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bloco in blocos {
            let r = proximo()
            let x = CGFloat(r % UInt64(max(1, Int(bounds.width))))
            let y = CGFloat((r >> 16) % UInt64(max(1, Int(bounds.height))))
            let l = CGFloat(8 + (r >> 32) % 60)
            bloco.frame = CGRect(x: x, y: y, width: l, height: l)
            bloco.backgroundColor = UIColor(
                red: CGFloat((r >> 8) & 0xFF) / 255.0,
                green: CGFloat((r >> 24) & 0xFF) / 255.0,
                blue: CGFloat((r >> 40) & 0xFF) / 255.0,
                alpha: 1).cgColor
        }
        contador.frame = CGRect(x: 0, y: bounds.midY - 15, width: bounds.width, height: 30)
        contador.string = "quall degrau 4 — quadro \(giro)"
        CATransaction.commit()
    }
}

struct TelaAgitada: UIViewRepresentable {
    func makeUIView(context: Context) -> Agitador { Agitador(frame: .zero) }
    func updateUIView(_ uiView: Agitador, context: Context) {}
}
