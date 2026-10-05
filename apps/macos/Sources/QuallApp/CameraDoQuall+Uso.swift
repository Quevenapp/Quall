import CoreMediaIO
import Foundation
import QuallCaptureKit
import QuallReceptorKit

/// **A câmera do Quall está em uso?** Para o mudo automático da D3 (`docs/som-no-receptor.md`
/// §12.1 e §17.5): enquanto um app usa a webcam do Quall, o som que este receptor toca no cômodo
/// vaza para a chamada pelo microfone.
///
/// Uma extensão do ``CameraDoQuall`` do `QuallCaptureKit`, e não um tipo próprio: o dispositivo é
/// achado pelo mesmo `idDoDispositivo` que o catálogo de fontes exclui, comparado como UUID por
/// ``CameraDoQuall/ehDoQuall(uniqueID:)`` — e aquele UUID é vigiado contra a extensão por
/// `TestesDaCameraDoQuall`. Sem critério pelo nome.
///
/// # Como
///
/// Só leitura: a lista de dispositivos do CoreMediaIO, o UID de cada um, e o
/// `kCMIODevicePropertyDeviceIsRunningSomewhere` do nosso. Nenhum fluxo é aberto, e o `tccd` não
/// registrou consulta de câmera nenhuma por estas leituras nas corridas do `provar-som.sh` (o
/// veredito do TCC reprova se registrar).
///
/// # O que o CoreMediaIO não distingue, e a leitura da D3
///
/// O `IsRunningSomewhere` é do **dispositivo**. O app da câmera do Quall, quando alimenta a câmera,
/// também põe o dispositivo para rodar (`CMIODeviceStartStream` no fluxo de entrada,
/// `integrations/camera-macos/Fontes/App/ClienteDoSumidouro.swift`), e o CoreMediaIO não tem
/// propriedade padrão por fluxo que diga "alguém está assistindo". A extensão sabe
/// (`clientesNaSaida`, `DispositivoQuall.swift`), mas não publica. **Rodando é em uso, e cala**,
/// com o app da câmera aberto ou não (``EstadoDaCameraDoQuall``); a chave da janela desfaz. O
/// conserto de verdade é a extensão publicar quem consome, numa propriedade própria.
extension CameraDoQuall {

    /// O estado da câmera do Quall para a D3. `ausente` quando ela não está instalada (ou não se
    /// deixou ler).
    static func emUso() -> EstadoDaCameraDoQuall {
        EstadoDaCameraDoQuall(rodando: rodandoEmAlgumLugar())
    }

    /// `nil` quando a câmera do Quall não está instalada (ou não se deixou ler).
    static func rodandoEmAlgumLugar() -> Bool? {
        guard let d = dispositivoNoCoreMediaIO() else { return nil }
        var valor: UInt32 = 0
        let tam = UInt32(MemoryLayout<UInt32>.size)
        var usado: UInt32 = 0
        var end = enderecoCMIO(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        guard CMIOObjectGetPropertyData(d, &end, 0, nil, tam, &usado, &valor) == noErr else { return nil }
        return valor != 0
    }

    private static func enderecoCMIO(_ seletor: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: seletor,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func dispositivoNoCoreMediaIO() -> CMIOObjectID? {
        var end = enderecoCMIO(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var tam: UInt32 = 0
        let sistema = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(sistema, &end, 0, nil, &tam) == noErr, tam > 0 else { return nil }
        let n = Int(tam) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: n)
        var usado: UInt32 = 0
        guard CMIOObjectGetPropertyData(sistema, &end, 0, nil, tam, &usado, &ids) == noErr else { return nil }
        return ids.first { id in uidNoCoreMediaIO(id).map { ehDoQuall(uniqueID: $0) } ?? false }
    }

    private static func uidNoCoreMediaIO(_ id: CMIOObjectID) -> String? {
        var end = enderecoCMIO(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
        var valor: Unmanaged<CFString>?
        let tam = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var usado: UInt32 = 0
        guard CMIOObjectGetPropertyData(id, &end, 0, nil, tam, &usado, &valor) == noErr,
              let v = valor else { return nil }
        return v.takeRetainedValue() as String
    }
}
