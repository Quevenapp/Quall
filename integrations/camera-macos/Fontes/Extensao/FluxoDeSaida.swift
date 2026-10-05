import CoreMediaIO
import Foundation

/// O fluxo que os apps de terceiro leem. Direção `.source`.
final class FluxoDeSaida: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private weak var dispositivo: DispositivoQuall?
    private let formato: CMIOExtensionStreamFormat

    init(dispositivo: DispositivoQuall, formato: CMIOExtensionStreamFormat) {
        self.dispositivo = dispositivo
        self.formato = formato
        super.init()
        stream = CMIOExtensionStream(localizedName: "Quall vídeo",
                                     streamID: Identidade.idDoFluxoDeSaida,
                                     direction: .source,
                                     clockType: .hostTime,
                                     source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [formato] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: CMTimeScale(Identidade.quadrosPorSegundo))
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// Quem pode abrir a câmera. `true` aqui é o mesmo que qualquer webcam faz: quem controla o
    /// acesso é o TCC de Câmera do sistema, no processo cliente, não nós.
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { dispositivo?.comecarSaida() }

    func stopStream() throws { dispositivo?.pararSaida() }
}
