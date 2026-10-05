import SwiftUI
import UIKit

/// **As setas da linha de leitura, arrastáveis** — para acertar a linha na altura em que os olhos
/// de quem lê passam pela câmera.
///
/// # O pedido (14/09/2026)
///
/// Literal do usuário: *"as duas setas laranjas que definem a linha de leitura precisam ser móveis
/// para regular na linha do campo de visão da câmera para os olhos"*. Arrastar qualquer uma das
/// duas setas (ou a faixa entre elas) leva a linha de leitura até onde o dedo soltar, pelo campo
/// sincronizado `linha_de_leitura` (`definirLinhaDeLeitura` → `quall_teleprompter_set_reading_line`):
/// o controle vê a linha nova, e pode mudá-la de volta — vale o último que mudou (§3).
///
/// # Por cima da vista, e não dentro dela
///
/// As alças são uma camada por cima de `VistaDoRoteiro`, com o mesmo quadro: a vista continua
/// desenhando as setas onde o estado manda, e esta camada só pega o gesto. Assim ela não depende
/// de como a vista desenha o texto.
///
/// # Quem pega o gesto
///
/// Só as **zonas das setas** — 64 × 96 pt em cada borda, bem maiores que o desenho de 12 pt, porque
/// com o aparelho deitado sob o vidro a mão chega pela lateral — e uma **faixa** de 28 pt de altura
/// na linha, entre elas. O resto da camada não é tocável: um toque ou arrasto no texto passa para
/// o rolador da vista, como antes (rolar com o dedo, e o toque que alterna a tela cheia).
///
/// # O arrasto
///
/// - A linha anda **pela diferença** desde o toque (`inicio` → `agora`), e não salta para o dedo:
///   quem pega a seta um pouco acima do desenho não a vê pular.
/// - **Envios limitados**: no máximo um a cada ``ArrastoDaLinha/intervalo`` (120 ms); o valor mais
///   novo espera a vez, e **o último sempre sai** — ao soltar, na hora. Cada envio é uma edição
///   carimbada que vai ao controle (§4, "estado, por mudança de campo pequeno aqui: na hora"); um
///   arrasto a 60 Hz seriam 60 mensagens por segundo.
/// - Enquanto arrasta, o valor em % fica à mostra, na altura do dedo.
///
/// O espelho é horizontal e as setas são simétricas: espelhado ou não, a linha é a mesma e o
/// arrasto é vertical. A camada está nas coordenadas da interface, então em Paisagem e em Paisagem
/// invertida (`OrientacaoDoPrompter`) "para baixo" continua sendo para baixo na tela.
struct AlcasDaLinhaDeLeitura: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    @StateObject private var arrasto = ArrastoDaLinha()

    /// A zona de cada seta, e a altura da faixa entre elas.
    static let zonaDaSeta = CGSize(width: 64, height: 96)
    static let alturaDaFaixa: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let linha = arrasto.previa ?? modelo.estado.linhaDeLeitura
            let y = CGFloat(min(1, max(0, linha))) * h
            ZStack(alignment: .topLeading) {
                zona(largura: Self.zonaDaSeta.width, altura: Self.zonaDaSeta.height, altoDaVista: h)
                    .position(x: Self.zonaDaSeta.width / 2, y: y)
                zona(largura: Self.zonaDaSeta.width, altura: Self.zonaDaSeta.height, altoDaVista: h)
                    .position(x: w - Self.zonaDaSeta.width / 2, y: y)
                zona(largura: max(0, w - 2 * Self.zonaDaSeta.width), altura: Self.alturaDaFaixa, altoDaVista: h)
                    .position(x: w / 2, y: y)
                if let p = arrasto.previa {
                    Text(tr("Linha de leitura: %.0f %% do alto", p * 100))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundColor(.black)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Estilo.aguardando.opacity(0.92))
                        .cornerRadius(8)
                        .position(x: w / 2, y: max(18, y - 34))
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: ArrastoDaLinha.espaco)
            .onAppear {
                arrasto.ligar(modelo)
                arrasto.altura = h
                BancadaDaLinha.ligar(arrasto)
            }
            .onChange(of: h) { arrasto.altura = $0 }
        }
    }

    /// Uma zona tocável, invisível: a vista embaixo desenha as setas.
    private func zona(largura: CGFloat, altura: CGFloat, altoDaVista h: CGFloat) -> some View {
        Color.clear
            .frame(width: largura, height: altura)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(ArrastoDaLinha.espaco))
                .onChanged { v in arrasto.mover(deY: v.startLocation.y, paraY: v.location.y, altura: h) }
                .onEnded { v in arrasto.soltar(deY: v.startLocation.y, paraY: v.location.y, altura: h) })
            .accessibilityElement()
            .accessibilityLabel(tr("Linha de leitura"))
            .accessibilityValue(tr("%.0f %% do alto", modelo.estado.linhaDeLeitura * 100))
            .accessibilityAdjustableAction { direcao in
                let passo = direcao == .increment ? -0.01 : 0.01
                modelo.definirLinhaDeLeitura(modelo.estado.linhaDeLeitura + passo)
            }
    }
}

/// O arrasto da linha de leitura: a prévia local e os envios limitados. O reconhecedor do gesto
/// chama ``mover(deY:paraY:altura:)`` e ``soltar(deY:paraY:altura:)``; a bancada chama as mesmas.
final class ArrastoDaLinha: ObservableObject {
    static let espaco = "alcas-da-linha"
    /// O intervalo mínimo entre dois envios durante o arrasto.
    static let intervalo: CFTimeInterval = 0.12

    /// A linha durante o arrasto (fração da altura), antes de o estado a mostrar. `nil` fora dele.
    @Published private(set) var previa: Double?
    /// A altura da vista do texto, em pontos — a da camada, que tem o mesmo quadro.
    var altura: CGFloat = 0

    private weak var modelo: ModeloDoTeleprompter?
    private var inicial = 0.3
    private var comecouEm: CFTimeInterval = 0
    private var ultimoEnvio: CFTimeInterval = 0
    private var pendente: Double?
    private var agendado = false
    private var envios = 0
    private var eventos = 0

    func ligar(_ m: ModeloDoTeleprompter) { modelo = m }

    private func valor(deY: CGFloat, paraY: CGFloat, altura: CGFloat) -> Double {
        min(1, max(0, inicial + Double((paraY - deY) / altura)))
    }

    /// O dedo andou. O primeiro evento do arrasto guarda a linha de onde ele partiu.
    func mover(deY: CGFloat, paraY: CGFloat, altura: CGFloat) {
        guard altura > 1, let m = modelo else { return }
        if previa == nil {
            inicial = m.estado.linhaDeLeitura
            comecouEm = CACurrentMediaTime()
            envios = 0
            eventos = 0
            DiarioDoTeleprompter.dizer(String(format: "linha de leitura: arrasto começou em %.4f (vista de %.0f pt)",
                                              inicial, altura))
        }
        eventos += 1
        let v = valor(deY: deY, paraY: paraY, altura: altura)
        previa = v
        pendente = v
        enviarQuandoPuder()
    }

    /// O dedo saiu: o valor de onde ele saiu vai **agora**, mesmo que o último envio tenha sido há
    /// menos de 120 ms.
    func soltar(deY: CGFloat, paraY: CGFloat, altura: CGFloat) {
        guard altura > 1, modelo != nil else { return }
        if previa == nil { inicial = modelo?.estado.linhaDeLeitura ?? inicial; comecouEm = CACurrentMediaTime() }
        let v = valor(deY: deY, paraY: paraY, altura: altura)
        pendente = nil
        previa = nil
        enviar(v, porque: "soltou")
        DiarioDoTeleprompter.dizer(String(format: "linha de leitura: soltou em %.4f — %d envios em %d eventos do gesto, "
                                          + "%.0f ms de arrasto; o estado mostra %.4f", v, envios, eventos,
                                          (CACurrentMediaTime() - comecouEm) * 1000,
                                          modelo?.estado.linhaDeLeitura ?? -1))
    }

    private func enviarQuandoPuder() {
        let falta = ArrastoDaLinha.intervalo - (CACurrentMediaTime() - ultimoEnvio)
        if falta <= 0 {
            if let p = pendente { enviar(p, porque: "arrasto") }
            return
        }
        guard !agendado else { return }
        agendado = true
        DispatchQueue.main.asyncAfter(deadline: .now() + falta) { [weak self] in
            guard let self else { return }
            self.agendado = false
            // Solto no meio da espera: o soltar já mandou o último.
            if self.previa != nil, let p = self.pendente { self.enviar(p, porque: "arrasto") }
        }
    }

    private func enviar(_ v: Double, porque: String) {
        let agora = CACurrentMediaTime()
        let desde = ultimoEnvio > 0 ? (agora - ultimoEnvio) * 1000 : -1
        ultimoEnvio = agora
        pendente = nil
        envios += 1
        modelo?.definirLinhaDeLeitura(v)
        DiarioDoTeleprompter.dizer(String(format: "linha de leitura: envio %d (%@) %.4f, %.0f ms depois do anterior",
                                          envios, porque, v, desde))
    }
}

/// **A bancada da linha de leitura**, sem toque: `--arrastar-linha 0.6,0.25` faz, 4 s depois de a
/// tela aparecer, um arrasto até cada alvo — 1,2 s de gesto a 60 eventos por segundo, chamando
/// ``ArrastoDaLinha/mover(deY:paraY:altura:)`` e ``ArrastoDaLinha/soltar(deY:paraY:altura:)``,
/// que é o que o reconhecedor chama —, com a linha `bancada: linha: foto N (…)` depois de cada um,
/// para a captura da tela. `--arrastar-linha-apos S` muda a espera (para um controle conectar antes);
/// `--arrastar-linha-pausa` para o dedo 3 s no meio de cada arrasto (`foto N-meio`), que é quando o
/// valor em % está na tela.
///
/// **O que ela não prova**: o toque de verdade — o reconhecedor do SwiftUI recebendo o dedo, as
/// zonas pegando só o que devem, e o rolador recebendo o resto. Isso só com o dedo.
enum BancadaDaLinha {
    private static var consumida = false

    static func ligar(_ a: ArrastoDaLinha) {
        guard !consumida else { return }
        consumida = true
        let args = CommandLine.arguments
        func valor(_ chave: String) -> String? {
            guard let i = args.firstIndex(of: chave), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let lista = valor("--arrastar-linha") else { return }
        let alvos = lista.split(separator: ",").compactMap { Double($0) }
        let espera = valor("--arrastar-linha-apos").flatMap { Double($0) } ?? 4
        let pausa = args.contains("--arrastar-linha-pausa")
        DiarioDoTeleprompter.dizer("bancada: arrastos da linha de leitura para \(alvos), daqui a \(espera) s"
                                   + (pausa ? ", com o dedo parado 3 s no meio" : ""))
        let t = Thread { [weak a] in
            Thread.sleep(forTimeInterval: espera)
            for (n, alvo) in alvos.enumerated() {
                var h: CGFloat = 0
                var de: CGFloat = 0
                DispatchQueue.main.sync {
                    h = a?.altura ?? 0
                    // O dedo pousa **perto** da seta, e não no centro dela: 9 pt acima.
                    de = CGFloat(a?.estadoDaLinha() ?? 0.3) * h - 9
                }
                let para = de + CGFloat(alvo - Double((de + 9) / max(1, h))) * h
                let passos = 72
                for i in 1...passos {
                    let y = de + (para - de) * CGFloat(i) / CGFloat(passos)
                    DispatchQueue.main.sync { a?.mover(deY: de, paraY: y, altura: h) }
                    Thread.sleep(forTimeInterval: 1.0 / 60)
                    if pausa, i == passos / 2 {
                        // O dedo parado no meio do caminho: é quando o % aparece na captura.
                        DiarioDoTeleprompter.dizer("bancada: linha: foto \(n + 1)-meio (arrastando para \(alvo))")
                        Thread.sleep(forTimeInterval: 3)
                    }
                }
                DispatchQueue.main.sync { a?.soltar(deY: de, paraY: para, altura: h) }
                Thread.sleep(forTimeInterval: 2)
                DiarioDoTeleprompter.dizer("bancada: linha: foto \(n + 1) (alvo \(alvo))")
                Thread.sleep(forTimeInterval: 2.5)
            }
            DiarioDoTeleprompter.dizer("bancada: arrastos terminados")
        }
        t.name = "quall.teleprompter.arrastos"
        t.start()
    }
}

extension ArrastoDaLinha {
    /// A linha que o estado mostra agora (para a bancada pousar o dedo nela).
    func estadoDaLinha() -> Double { modelo?.estado.linhaDeLeitura ?? 0.3 }
}
