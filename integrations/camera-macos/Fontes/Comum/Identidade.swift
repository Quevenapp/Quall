import Foundation

/// Nomes e identificadores compartilhados entre o app anfitrião e a extensão.
///
/// Os UUIDs são **fixos e literais** de propósito. O `deviceID` de um
/// `CMIOExtensionDevice` é o que o CoreMediaIO usa para casar o dispositivo entre execuções, e
/// o app precisa achar o mesmo dispositivo pelo lado do DAL para escrever no fluxo de entrada.
/// Sortear em tempo de execução faria o app procurar um id que a extensão não tem.
enum Identidade {
    /// Bundle id do app anfitrião.
    static let idDoApp = "br.com.queven.quall.camera"

    /// Bundle id da extensão. É este o nome que aparece em Ajustes do Sistema.
    static let idDaExtensao = "br.com.queven.quall.camera.extensao"

    /// Nome com que a câmera aparece em Zoom, Meet, OBS.
    static let nomeDaCamera = "Quall"

    /// O `CMIOExtensionDevice`.
    static let idDoDispositivo = UUID(uuidString: "9E7B34B1-6C0A-4F3D-9E2A-1C4D5B6A7E80")!

    /// Fluxo de **saída**: o que os apps de terceiro leem. Direção `.source`.
    static let idDoFluxoDeSaida = UUID(uuidString: "9E7B34B1-6C0A-4F3D-9E2A-1C4D5B6A7E81")!

    /// Fluxo de **entrada**: por onde o app anfitrião empurra quadro. Direção `.sink`.
    static let idDoFluxoDeEntrada = UUID(uuidString: "9E7B34B1-6C0A-4F3D-9E2A-1C4D5B6A7E82")!

    /// Subsistema de `os_log`. A extensão roda como `_cmiodalassistants`, num processo que não é
    /// nosso e sem terminal: `log stream` é a única janela para dentro dela.
    static let subsistemaDeLog = "br.com.queven.quall.camera"

    /// Dimensão publicada. **1080p30 desde 01/09/2026; era 720p30, "a medida que o M4 pediu".**
    ///
    /// Subiu junto com `PERFIL_H264`, que passou a nível 4.0 no mesmo dia. Enquanto a câmera
    /// publicasse 720p, todo 1080p que chegasse pela rede era **reduzido antes de chegar ao
    /// Zoom** — o teto novo não alcançava este caminho.
    ///
    /// **O formato é fixo de propósito** e continua sendo: o `Ajustador` encaixa o que vier
    /// (retrato 720x1520 de um celular, 1920x1080 de uma tela) nesta moldura, porque renegociar
    /// formato com o app consumidor é o que derruba chamada de Zoom no meio. O preço da subida é
    /// que o que for **menor** passa a ser ampliado à toa; o ganho é que o que for do tamanho do
    /// teto atravessa intacto.
    static let largura: Int32 = 1920
    static let altura: Int32 = 1080
    static let quadrosPorSegundo: Int32 = 30
}
