import Foundation
import SystemExtensions
import os

let registroDoApp = Logger(subsystem: Identidade.subsistemaDeLog, category: "app")

/// Instala, atualiza e desinstala a extensão de câmera.
///
/// Quem pede a ativação **precisa ser o app anfitrião**, rodando de dentro do bundle que carrega
/// a extensão em `Contents/Library/SystemExtensions`. Não há linha de comando equivalente: o
/// `systemextensionsctl` só lista e desinstala.
final class Ativacao: NSObject, OSSystemExtensionRequestDelegate {
    private let aoTerminar: (Int32) -> Void

    init(aoTerminar: @escaping (Int32) -> Void) {
        self.aoTerminar = aoTerminar
    }

    func ativar() {
        let pedido = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Identidade.idDaExtensao, queue: .main)
        pedido.delegate = self
        OSSystemExtensionManager.shared.submitRequest(pedido)
        dizer("pedido de ativação enviado para \(Identidade.idDaExtensao)")
    }

    func desativar() {
        let pedido = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Identidade.idDaExtensao, queue: .main)
        pedido.delegate = self
        OSSystemExtensionManager.shared.submitRequest(pedido)
        dizer("pedido de desativação enviado para \(Identidade.idDaExtensao)")
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        dizer("substituindo \(existing.bundleShortVersion)/\(existing.bundleVersion) por \(ext.bundleShortVersion)/\(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        dizer("PRECISA DE APROVAÇÃO: Ajustes do Sistema > Geral > Itens de Início e Extensões > Extensões de Câmera")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        dizer("terminou: \(nomeDoResultado(result)) (\(result.rawValue))")
        aoTerminar(0)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        dizer("FALHOU: \(RegistroSeguro.erro(error))")
        aoTerminar(1)
    }

    private func nomeDoResultado(_ r: OSSystemExtensionRequest.Result) -> String {
        switch r {
        case .completed: return "completed"
        case .willCompleteAfterReboot: return "willCompleteAfterReboot"
        @unknown default: return "desconhecido"
        }
    }
}

func dizer(_ mensagem: String) {
    let segura = RegistroSeguro.texto(mensagem)
    registroDoApp.info("APP \(segura, privacy: .public)")
    print("APP \(segura)")
    fflush(stdout)
}
