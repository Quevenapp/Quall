import SwiftUI
import UIKit

/// A orientação da interface, que a tela cheia prende na do vídeo e depois solta.
///
/// # Por que existe
///
/// Em 10/09/2026 o usuário olhou o iPhone X recebendo a tela estendida do Mac e disse: *"não tem
/// botão tela cheia"*. O vídeo é 1920 × 1200, deitado; o iPhone estava em pé (`camada=375x812`), e
/// um quadro deitado numa tela em pé ocupa um terço dela. Com o bloqueio de rotação ligado — o
/// comum —, girar o aparelho não resolve. O receptor Android faz o mesmo
/// (`ReceptorActivity.travarNaOrientacaoDoVideo`).
///
/// # Como
///
/// O sistema pergunta ao delegado do app quais orientações valem (`DelegadoDoApp`). Fora da tela
/// cheia a resposta é a do `Info.plist` — retrato e paisagem no iPhone, as quatro no iPad —, então
/// nada muda para o resto do app. Na tela cheia, só a do vídeo, e o sistema gira para ela mesmo
/// com o bloqueio de rotação ligado.
///
/// No iOS 16 isso é `requestGeometryUpdate`. No iOS 15 (o iPhone 7) não há API pública: o
/// caminho é `UIDevice.orientation` por KVC seguido de `attemptRotationToDeviceOrientation`, que é
/// o que apps de vídeo fazem desde sempre.
enum Orientacao {
    /// O que o app declara ao sistema agora.
    private(set) static var mascara: UIInterfaceOrientationMask = padrao

    /// A mesma lista do `Info.plist` (`project.yml`): retrato de cabeça para baixo só no iPad.
    static var padrao: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    static var descricao: String {
        switch mascara {
        case .landscape: return "paisagem"
        case .landscapeRight: return "paisagem (topo à esquerda)"
        case .landscapeLeft: return "paisagem invertida (topo à direita)"
        case .portrait: return "retrato"
        default: return "livre"
        }
    }

    /// Prende na orientação do vídeo: deitado vira paisagem, em pé vira retrato, quadrado não prende.
    static func travar(larguraDoVideo: Int, alturaDoVideo: Int) {
        guard larguraDoVideo > 0, alturaDoVideo > 0, larguraDoVideo != alturaDoVideo else { return }
        let deitado = larguraDoVideo > alturaDoVideo
        mascara = deitado ? .landscape : .portrait
        aplicar(preferida: deitado ? .landscapeRight : .portrait)
    }

    static func soltar() {
        guard mascara != padrao else { return }
        mascara = padrao
        aplicar(preferida: nil)
    }

    /// Prende numa orientação escolhida pela pessoa (o ajuste "Orientação" do prompter,
    /// `OrientacaoDoPrompter`): a máscara é **só ela**, para o sensor não desfazer a escolha — é o
    /// caso do aparelho deitado sob o vidro, em que o sensor não decide nada.
    static func prender(_ nova: UIInterfaceOrientationMask, preferida: UIInterfaceOrientation,
                        aoRecusar: @escaping (String) -> Void) {
        mascara = nova
        aplicar(preferida: preferida, aoRecusar: aoRecusar)
    }

    /// Solta de volta ao `Info.plist`, dizendo a recusa a quem pediu.
    static func soltar(aoRecusar: @escaping (String) -> Void) {
        guard mascara != padrao else { return }
        mascara = padrao
        aplicar(preferida: nil, aoRecusar: aoRecusar)
    }

    private static func aplicar(preferida: UIInterfaceOrientation?,
                                aoRecusar: ((String) -> Void)? = nil) {
        // **A cena ativa, e não a primeira da lista.** Em 11/09 o giro funcionou numa abertura e,
        // na seguinte (o app reaberto pelo `idevicedebug`), foi recusado seis vezes seguidas com
        // `BSActionErrorDomain error 1` — o vídeo ficou em pé, numa faixa, com o usuário tocando em
        // "Tela cheia". `connectedScenes` não tem ordem; pedir o giro a uma cena que não está na
        // frente é recusado. A recusa agora diz o que o sistema via, para a próxima não ser palpite.
        let cenas = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let cena = cenas.first { $0.activationState == .foregroundActive } ?? cenas.first
        if #available(iOS 16.0, *) {
            for janela in cena?.windows ?? [] { janela.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            cena?.requestGeometryUpdate(.iOS(interfaceOrientations: mascara)) { erro in
                let estados = cenas.map { "\($0.activationState.rawValue)" }.joined(separator: ",")
                let porque = "\(SanitizacaoDoLog.erro(erro)) "
                    + "[cenas=\(cenas.count) estados=\(estados) (0=ativa) "
                    + "interface=\(cena?.interfaceOrientation.rawValue ?? -1) "
                    + "aparelho=\(UIDevice.current.orientation.rawValue) pedida=\(descricao)]"
                if let aoRecusar {
                    aoRecusar(porque)
                } else {
                    Diario.dizer("tela cheia: o sistema não girou — " + porque
                                 + (mascara == .landscape ? " — o vídeo gira na própria vista (TelaDeRecepcao)" : ""))
                }
            }
        } else {
            if let preferida { UIDevice.current.setValue(preferida.rawValue, forKey: "orientation") }
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

/// Quem responde ao sistema quais orientações valem. Ver ``Orientacao``.
final class DelegadoDoApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientacao.mascara
    }
}

/// Esconde o indicador de início (a barra de baixo do iPhone X em diante) na tela cheia.
///
/// Só existe em SwiftUI a partir do iOS 16. No iOS 15 fica como está — e o aparelho de iOS 15 da
/// bancada, o iPhone 7, tem botão de início e não tem indicador.
struct IndicadorDeInicio: ViewModifier {
    let escondido: Bool

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.persistentSystemOverlays(escondido ? .hidden : .automatic)
        } else {
            content
        }
    }
}
