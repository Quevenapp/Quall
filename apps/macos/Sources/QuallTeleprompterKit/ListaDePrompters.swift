import Foundation

/// Um prompter achado pelo mDNS, para a lista do controle.
public struct PrompterAchado: Equatable, Identifiable, Sendable {
    public let deviceId: String
    public let nome: String
    public let endpoint: String
    public var id: String { deviceId + "@" + endpoint }

    public init(deviceId: String, nome: String, endpoint: String) {
        self.deviceId = deviceId
        self.nome = nome
        self.endpoint = endpoint
    }

    /// **A lista do controle**, do JSON de `quall_browser_devices_json`: só quem anuncia
    /// `"papel": "teleprompter"` (a chave só existe quando há papel, §2), com endereço utilizável,
    /// e nunca este próprio aparelho.
    ///
    /// Os receptores de vídeo fazem o contrário — escondem quem tem papel (§7). Um anúncio sem
    /// papel é um aparelho de vídeo e não entra aqui: bater nele como controle terminaria em recusa
    /// (o controle sai com `Bye`), e oferecer na lista o que vai ser recusado é pior que não
    /// oferecer.
    public static func lista(doJSON texto: String, excluindo meuId: String) -> [PrompterAchado] {
        guard let dados = texto.data(using: .utf8),
              let bruto = try? JSONSerialization.jsonObject(with: dados),
              let itens = bruto as? [[String: Any]] else { return [] }
        var vistos = Set<String>()
        var saida: [PrompterAchado] = []
        for item in itens {
            guard (item["papel"] as? String) == PapelDoTeleprompter.prompter.rawValue,
                  let endpoint = item["endpoint"] as? String, !endpoint.isEmpty,
                  let id = item["device_id"] as? String, id != meuId else { continue }
            let nome = (item["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? endpoint
            let achado = PrompterAchado(deviceId: id, nome: nome, endpoint: endpoint)
            if vistos.insert(achado.id).inserted { saida.append(achado) }
        }
        return saida.sorted { $0.nome.localizedCaseInsensitiveCompare($1.nome) == .orderedAscending }
    }
}
