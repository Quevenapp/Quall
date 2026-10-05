import Foundation

/// **A câmera virtual do próprio Quall**, que o catálogo de fontes não pode oferecer.
///
/// A extensão de câmera (`integrations/camera-macos`) publica um `CMIOExtensionDevice` com o
/// `deviceID` fixo de `Identidade.idDoDispositivo`, e o `AVCaptureDevice` que o representa chega
/// à `DiscoverySession` do catálogo com esse UUID no `uniqueID` — medido em 18/09/2026 neste Mac
/// com a mesma sessão de descoberta, sem abrir câmera nenhuma (`docs/camera-no-windows.md`,
/// "Respostas à revisão"). Até então ela entrava na lista como "Quall": escolhida como fonte, o Mac
/// transmitiria o que ele mesmo recebe — a tela do celular de alguém volta para a rede como se
/// fosse câmera, e o que a câmera mostra é o que o Quall pôs nela. Um laço, e um vazamento.
///
/// **Por que o UUID e não o nome nem o fabricante.** O nome ("Quall") é o que a pessoa lê e pode
/// coincidir com outro aparelho; o fabricante é texto livre que qualquer extensão escreve. O
/// `deviceID` é o que o CoreMediaIO usa para casar o dispositivo entre execuções, e é literal nos
/// dois lados. É o par do Windows, que exclui pelo CLSID da fonte (`catalogo_de_cameras.rs`).
///
/// **Por que o literal está repetido aqui.** A extensão é outro projeto (Xcode, `project.yml`) e
/// este pacote não a enxerga. A cópia é vigiada: `TestesDaCameraDoQuall` lê
/// `integrations/camera-macos/Fontes/Comum/Identidade.swift` e falha se os dois divergirem.
public enum CameraDoQuall {
    /// `Identidade.idDoDispositivo` da extensão de câmera.
    public static let idDoDispositivo = UUID(uuidString: "9E7B34B1-6C0A-4F3D-9E2A-1C4D5B6A7E80")!

    /// `uniqueID` de um `AVCaptureDevice` é a câmera do Quall? Compara como UUID, não como texto:
    /// caixa diferente não pode deixar a câmera passar. Um `uniqueID` que não é UUID (a placa de
    /// captura USB deste MacBook dá `0x…`) nunca é a nossa; a câmera interna também tem forma de
    /// UUID, e fica porque o número é outro.
    public static func ehDoQuall(uniqueID: String) -> Bool {
        guard let u = UUID(uuidString: uniqueID) else { return false }
        return u == idDoDispositivo
    }
}
