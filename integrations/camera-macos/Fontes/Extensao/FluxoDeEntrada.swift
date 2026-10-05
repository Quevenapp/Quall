import CoreMediaIO
import Foundation
import os

/// O fluxo por onde o app anfitrião empurra quadro. Direção `.sink`.
///
/// É esta a fronteira entre processos que a frente precisava medir: o app recebe da rede,
/// decodifica em VideoToolbox e escreve aqui; a extensão consome e repassa. O que atravessa é um
/// `CMSampleBuffer` sobre `IOSurface` — memória compartilhada, não cópia de 1,3 MB por quadro.
final class FluxoDeEntrada: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private weak var dispositivo: DispositivoQuall?
    private let formato: CMIOExtensionStreamFormat
    private var ativo = false
    private var subconsumos: UInt64 = 0

    init(dispositivo: DispositivoQuall, formato: CMIOExtensionStreamFormat) {
        self.dispositivo = dispositivo
        self.formato = formato
        super.init()
        stream = CMIOExtensionStream(localizedName: "Quall entrada",
                                     streamID: Identidade.idDoFluxoDeEntrada,
                                     direction: .sink,
                                     clockType: .hostTime,
                                     source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [formato] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration,
         .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkEndOfData, .streamSinkBufferUnderrunCount]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: CMTimeScale(Identidade.quadrosPorSegundo))
        }
        // Fila curta de propósito. O contrato do projeto é "empacota e solta, zero filas": uma
        // fila funda aqui trocaria latência por suavidade, que é o oposto do que espelhamento ao
        // vivo quer.
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(.streamSinkEndOfData) { p.sinkEndOfData = 0 }
        if properties.contains(.streamSinkBufferUnderrunCount) { p.sinkBufferUnderrunCount = 0 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// O cliente é guardado aqui, e não pego de `streamingClients` no `startStream`: a lista pode
    /// estar vazia no instante exato da partida, e nesse caso o laço de consumo nunca começaria —
    /// a câmera ficaria na placa de espera com o app empurrando quadro para o vazio.
    private var ultimoCliente: CMIOExtensionClient?

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        ultimoCliente = client
        return true
    }

    func startStream() throws {
        ativo = true
        registro.info("EXT entrada iniciou clientes=\(self.stream.streamingClients.count, privacy: .public)")
        guard let cliente = stream.streamingClients.first ?? ultimoCliente else {
            registro.error("EXT entrada iniciou sem cliente")
            return
        }
        consumir(de: cliente)
    }

    func stopStream() throws {
        ativo = false
        registro.info("EXT entrada parou; subconsumos=\(self.subconsumos, privacy: .public)")
    }

    private func consumir(de cliente: CMIOExtensionClient) {
        guard ativo else { return }
        stream.consumeSampleBuffer(from: cliente) { [weak self] amostra, sequencia, _, _, erro in
            guard let self, self.ativo else { return }
            if let erro {
                self.subconsumos += 1
                if self.subconsumos % 100 == 1 {
                    registro.error("EXT consumo falhou código=\((erro as NSError).code, privacy: .public); contexto omitido")
                }
                // Sem quadro para consumir agora; volte ao laço sem girar em vazio.
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.005) {
                    self.consumir(de: cliente)
                }
                return
            }
            if let amostra {
                let hostNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                self.dispositivo?.repassar(amostra, hostNs: hostNs)
                self.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequencia, hostTimeInNanoseconds: hostNs))
            }
            self.consumir(de: cliente)
        }
    }
}
