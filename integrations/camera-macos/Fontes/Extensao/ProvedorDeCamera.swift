import CoreMediaIO
import Foundation
import os

let registro = Logger(subsystem: Identidade.subsistemaDeLog, category: "extensao")

/// Raiz da extensão: publica um provedor com um dispositivo, o `Quall`.
final class ProvedorDeCamera: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var dispositivo: DispositivoQuall!

    init(filaDeClientes: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: filaDeClientes)
        dispositivo = DispositivoQuall()
        do {
            try provider.addDevice(dispositivo.device)
        } catch {
            registro.error("EXT addDevice falhou código=\((error as NSError).code, privacy: .public); contexto omitido")
        }
        registro.info("EXT provedor de pé pid=\(getpid(), privacy: .public) pegada=\(Medidas.pegadaDeMemoria(), privacy: .public)")
    }

    func connect(to client: CMIOExtensionClient) throws {
        registro.info("EXT cliente conectou; identidade omitida")
    }

    func disconnect(from client: CMIOExtensionClient) {
        registro.info("EXT cliente saiu; identidade omitida")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Quall" }
        if properties.contains(.providerName) { p.name = "Quall" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
