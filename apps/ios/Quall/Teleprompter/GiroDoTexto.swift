import SwiftUI
import UIKit

/// **Girar só o texto**, quando o sistema recusa a orientação escolhida.
///
/// # Por que existe (14/09/2026)
///
/// No iPad A16 (iPadOS 26.6) as três travas de `OrientacaoDoPrompter` voltaram recusadas: *"The
/// current windowing mode does not allow for programmatic changes to interface orientation"*. Um
/// iPad deitado sob o vidro ficaria com o texto de lado. Decisão do usuário, literal: *"girar só o
/// texto no ipad"* — nada de `UIRequiresFullScreen`.
///
/// # O que gira, e o que não gira
///
/// Só a vista do texto (`VistaDoRoteiro` e as alças da linha de leitura, que vêm junto): ela ganha o
/// quadro com largura e altura trocadas e é girada, em torno do centro, pelo ângulo que leva a
/// orientação atual da interface à escolhida. Os botões, as folhas e os avisos seguem a orientação
/// do aparelho — é o que o receptor já faz com o vídeo.
///
/// Dentro da vista girada tudo continua como antes, porque a vista não sabe que foi girada: a
/// largura do diagrama passa a ser a altura da tela (girada 90° ou 270°), o ponto de leitura
/// sobrevive ao layout novo, a margem e a linha de leitura são da vista, e o espelho continua
/// horizontal **em relação ao texto**. O arrasto das setas segue o dedo na vista girada: o gesto
/// mede no espaço de coordenadas dela.
///
/// # Só quando recusado
///
/// No iPhone a trava do sistema funciona (medido no X, iOS 16.7, e no 7, iOS 15.8), e o ângulo fica
/// em zero. Ele só sai de zero quando o sistema recusou a escolha (`EscolhaDeOrientacao.recusada`).
struct GiroDoTexto: ViewModifier {
    @ObservedObject var escolha: EscolhaDeOrientacao

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let g = escolha.giroDoTexto
            let deitado = g == 90 || g == 270
            content
                .frame(width: deitado ? geo.size.height : geo.size.width,
                       height: deitado ? geo.size.width : geo.size.height)
                .rotationEffect(.degrees(g))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                // A interface girou (a pessoa girou o iPad): o ângulo relativo muda junto.
                .onChange(of: geo.size) { _ in escolha.reavaliarGiro() }
        }
        // Uma virada de 180° (de uma paisagem para a outra) não muda o tamanho: vem pelo aparelho,
        // e a interface termina de girar depois da notificação.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { escolha.reavaliarGiro() }
        }
    }

    /// O ângulo, no sentido horário, em que o conteúdo fica "de pé" para cada orientação, visto no
    /// quadro nativo (em pé) do aparelho: em `.landscapeRight` o alto do conteúdo aponta para a
    /// borda direita do aparelho em pé (o topo dele fica à esquerda de quem olha).
    static func angulo(_ o: UIInterfaceOrientation) -> Double {
        switch o {
        case .landscapeRight: return 90
        case .portraitUpsideDown: return 180
        case .landscapeLeft: return 270
        default: return 0
        }
    }

    /// Quanto girar a vista, no sentido horário, para o texto ficar na orientação `pedida` com a
    /// interface em `interface`. Sempre em 0, 90, 180 ou 270.
    static func giro(pedida: UIInterfaceOrientation, interface: UIInterfaceOrientation) -> Double {
        (angulo(pedida) - angulo(interface) + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// **A captura da bancada feita pelo próprio app** (`--capturar`): no iPadOS 26 o `idevicescreenshot`
/// não tem o serviço de captura, e o `devicectl` não captura tela. O app desenha a janela dele
/// (`drawHierarchy`, o que está na tela, com os giros) num PNG em `Library/Caches/bancada/`, e a
/// bancada o copia com `devicectl device copy from`. Não é a captura do sistema: a barra de status
/// e o que o sistema põe por cima não entram.
enum CapturaDaBancada {
    static var ligada: Bool { CommandLine.arguments.contains("--capturar") }

    static func tirar(_ nome: String) {
        guard ligada else { return }
        let cenas = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let cena = cenas.first { $0.activationState == .foregroundActive } ?? cenas.first
        guard let janela = cena?.windows.first(where: \.isKeyWindow) ?? cena?.windows.first else { return }
        let imagem = UIGraphicsImageRenderer(bounds: janela.bounds).image { _ in
            janela.drawHierarchy(in: janela.bounds, afterScreenUpdates: false)
        }
        guard let pasta = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("bancada") else { return }
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let arquivo = pasta.appendingPathComponent(nome + ".png")
        do {
            try imagem.pngData()?.write(to: arquivo)
            DiarioDoTeleprompter.dizer("bancada: captura do app \(nome).png, janela \(Int(janela.bounds.width))x"
                                       + "\(Int(janela.bounds.height))")
        } catch {
            DiarioDoTeleprompter.dizer("bancada: a captura \(nome) não foi gravada: \(SanitizacaoDoLog.erro(error))")
        }
    }
}
