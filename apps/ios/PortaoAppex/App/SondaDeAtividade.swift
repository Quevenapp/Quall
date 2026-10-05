import UIKit
import ReplayKit

/// Segunda tentativa de dispensar o toque humano, por outro caminho que não o seletor.
///
/// `RPBroadcastActivityViewController.load(withPreferredExtension:handler:)` é o caminho antigo
/// (iOS 11, obsoleto no 13, ainda presente no 15). A aposta: **com uma extension preferida
/// declarada não há o que escolher**, então talvez o `RPBroadcastController` chegue ao delegado
/// sem folha nenhuma — e aí `startBroadcast` começa a transmissão por código, sem toque.
///
/// Se falhar, falha com mensagem, e o registro passa a ser prova de que o toque é humano.
final class SondaDeAtividade: NSObject, RPBroadcastActivityViewControllerDelegate {
    static let compartilhada = SondaDeAtividade()
    private var controlador: RPBroadcastController?

    static func talvezSondar() {
        guard CommandLine.arguments.contains("atividade") else { return }
        Diario.anotar("ATIVIDADE ligada")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            compartilhada.pedir()
        }
    }

    private func pedir() {
        RPBroadcastActivityViewController.load(withPreferredExtension: idDaExtension) { vc, erro in
            if let erro {
                Diario.anotar("ATIVIDADE load falhou: \(erro.localizedDescription)")
                return
            }
            guard let vc else {
                Diario.anotar("ATIVIDADE load devolveu nil sem erro")
                return
            }
            Diario.anotar("ATIVIDADE recebi \(type(of: vc))")
            vc.delegate = self
            guard let raiz = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?
                .windows.first?.rootViewController else {
                Diario.anotar("ATIVIDADE sem view controller raiz")
                return
            }
            raiz.present(vc, animated: false) {
                Diario.anotar("ATIVIDADE apresentei o controlador")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { Sonda.despejar() }
            }
        }
    }

    func broadcastActivityViewController(_ broadcastActivityViewController: RPBroadcastActivityViewController,
                                         didFinishWith broadcastController: RPBroadcastController?,
                                         error: Error?) {
        broadcastActivityViewController.dismiss(animated: false)
        if let error {
            Diario.anotar("ATIVIDADE delegado com erro: \(error.localizedDescription)")
            return
        }
        guard let broadcastController else {
            Diario.anotar("ATIVIDADE delegado sem controlador")
            return
        }
        controlador = broadcastController
        Diario.anotar("ATIVIDADE tenho RPBroadcastController, chamando startBroadcast")
        broadcastController.startBroadcast { erro in
            if let erro {
                Diario.anotar("ATIVIDADE startBroadcast falhou: \(erro.localizedDescription)")
            } else {
                Diario.anotar("ATIVIDADE TRANSMISSÃO COMEÇOU SEM TOQUE")
            }
        }
    }
}
