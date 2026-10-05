import SwiftUI
import UIKit
import ReplayKit

/// O seletor de transmissão do sistema, e o único toque que este produto não consegue evitar.
///
/// ## O que foi tentado, e por que sobra um toque
///
/// Medido nesta bancada, com sondas dedicadas:
///
/// * `RPSystemBroadcastPickerView` — o botão interno **aceita**
///   `sendActions(for: .touchUpInside)`, e o log do aparelho mostra
///   `-[RPSystemBroadcastPickerView buttonPressed:]`. Mas a folha vem de
///   `-[RPDaemonProxy openControlCenterSystemRecordingView]`, desenhada pelo `replayd`: a sonda
///   despeja a hierarquia de vistas e encontra **uma janela, nenhum controlador apresentado,
///   nenhum controle**.
/// * `RPBroadcastActivityViewController.load(withPreferredExtension:)` — devolve o controlador,
///   mas ele carrega uma appex da Apple dentro de um `_UIRemoteView`, e o delegado nunca é
///   chamado sem escolha da pessoa.
///
/// Ou seja: declarar uma extension preferida **não** dispensa a confirmação. O que dá para
/// poupar é o primeiro toque — abrir a folha —, e é o que esta view faz. O segundo, em "Iniciar
/// Transmissão", é da pessoa, e o fluxo já o contabiliza ("1 toque + 1 no consentimento do
/// sistema").
///
/// ## Por que ela é invisível
///
/// A folha abre por código, no instante em que a tela de espera termina de montar. Um botão do
/// sistema no meio da tela de espera seria um segundo caminho para a mesma coisa, e o fluxo diz
/// que tela que não serve ao caminho não existe. A view fica com 1x1 ponto e alpha zero,
/// presente só porque é ela quem carrega o `preferredExtension`.
struct SeletorDeTransmissao: UIViewRepresentable {
    static let idDaExtension = "br.com.queven.quall.broadcast"

    /// Guardada para que `abrir()` a encontre sem varrer a hierarquia de vistas inteira — que é o
    /// que a sonda fazia, e funciona, mas depende da tela montada e da janela certa.
    private static weak var viva: RPSystemBroadcastPickerView?

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let vista = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        vista.preferredExtension = SeletorDeTransmissao.idDaExtension
        vista.showsMicrophoneButton = false
        vista.alpha = 0.01
        vista.isUserInteractionEnabled = false
        SeletorDeTransmissao.viva = vista
        return vista
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        SeletorDeTransmissao.viva = uiView
    }

    /// Abre a folha do sistema. Devolve `false` quando não achou o botão — o que significa que a
    /// tela que hospeda o seletor ainda não montou, e não que o sistema recusou.
    @discardableResult
    static func abrir() -> Bool {
        guard let vista = viva ?? procurarNaJanela() else { return false }
        for filha in vista.subviews {
            if let botao = filha as? UIButton {
                botao.sendActions(for: .touchUpInside)
                return true
            }
        }
        return false
    }

    private static func procurarNaJanela() -> RPSystemBroadcastPickerView? {
        let janelas = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        for janela in janelas {
            if let achada = procurar(janela) { return achada }
        }
        return nil
    }

    private static func procurar(_ vista: UIView) -> RPSystemBroadcastPickerView? {
        if let alvo = vista as? RPSystemBroadcastPickerView { return alvo }
        for filha in vista.subviews {
            if let achada = procurar(filha) { return achada }
        }
        return nil
    }
}
