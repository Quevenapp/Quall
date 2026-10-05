import Foundation

/// Um aparelho de entrada de áudio, como o `AVCaptureDevice` o descreve: o `uniqueID`, o nome e o
/// **transporte** (`AVCaptureDevice.transportType`, um FourCC do CoreAudio:
/// `kAudioDeviceTransportType…`). Tirado do AVFoundation para a política ser testada sem abrir nada.
public struct AparelhoDeAudio: Equatable, Sendable {
    public let uniqueID: String
    public let nome: String
    public let transporte: UInt32

    public init(uniqueID: String, nome: String, transporte: UInt32) {
        self.uniqueID = uniqueID
        self.nome = nome
        self.transporte = transporte
    }

    /// Os transportes do CoreAudio que a política distingue (`AudioHardwareBase.h`), em FourCC.
    public static let embutido: UInt32 = 0x626C_746E      // 'bltn'
    public static let virtual: UInt32 = 0x7669_7274       // 'virt'
    public static let agregado: UInt32 = 0x6772_7570      // 'grup'
    public static let agregadoAutomatico: UInt32 = 0x6667_7270 // 'fgrp'
    public static let usb: UInt32 = 0x7573_6220           // 'usb '
    public static let bluetooth: UInt32 = 0x626C_7565     // 'blue'

    /// O FourCC legível, para o diário (`bltn`, `virt`, …); `0` é "desconhecido".
    public var nomeDoTransporte: String { AparelhoDeAudio.nome(doTransporte: transporte) }

    public static func nome(doTransporte t: UInt32) -> String {
        guard t != 0 else { return "desconhecido" }
        let b = [24, 16, 8, 0].map { UInt8((t >> UInt32($0)) & 0xff) }
        if b.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }), let s = String(bytes: b, encoding: .ascii) {
            return s.trimmingCharacters(in: .whitespaces)
        }
        return String(t, radix: 16)
    }
}

/// **Qual microfone abrir, e quando não abrir nenhum** (R5 fase 4, G5 de
/// `docs/teleprompter-com-camera.md` §8 e §8.9).
///
/// # A regra da bancada, e por que ela é mais estreita que "não o embutido"
///
/// `docs/audio.md` §8.1: **nunca o microfone do MacBook**, nem em prova nem em produto de bancada.
/// O G5 pede: em modo bancada, o microfone é escolhido **só** pelo `uniqueID` passado por argumento
/// (`--microfone=`), e todo dispositivo de transporte embutido é recusado. Esta política vai além e
/// **só aceita transporte virtual** (`'virt'`, o de um BlackHole — **hipótese** até o roteiro ler o
/// `transportType` dele):
///
/// - um **agregado** (`'grup'`, `'fgrp'`) pode conter o microfone embutido por dentro, e o
///   transporte dele não diz isso;
/// - um microfone **USB** ou **Bluetooth** capta a sala do mesmo jeito, e a bancada só aceita tom
///   sintético (`audio.md` §8.1);
/// - um transporte desconhecido (`0`) não se deixa conferir.
///
/// Sem `--microfone=` na bancada, **o microfone não abre** — não há "o padrão" na bancada, porque o
/// padrão de um MacBook é o embutido.
///
/// # O produto
///
/// Fora da bancada o microfone é o que a pessoa escolheu na tela (lembrado pelo `uniqueID`) ou, sem
/// escolha (ou com a escolhida sumida), o padrão do sistema. Só abre por toque no botão.
public enum PoliticaDoMicrofone {

    public enum Modo: Equatable, Sendable {
        /// `escolhido`: o `uniqueID` lembrado da escolha da pessoa, se houver.
        case produto(escolhido: String?)
        /// `pedido`: o `uniqueID` de `--microfone=`, se houver. `laco`: o de `--tom-no-dispositivo=`,
        /// o dispositivo em que o **nosso** gerador toca — a bancada só abre o microfone que é esse
        /// mesmo laço (a revisão de 25/09: Krisp, Loopback, o áudio do Teams e do Zoom também se
        /// declaram `'virt'` e repassam o microfone embutido; só o laço fechado com o gerador prova que
        /// o que entra é o tom).
        case bancada(pedido: String?, laco: String? = nil)
    }

    public enum Decisao: Equatable, Sendable {
        /// Abrir este aparelho.
        case usar(AparelhoDeAudio)
        /// Abrir o padrão do sistema (`AVCaptureDevice.default(for: .audio)`). Só no produto.
        case padraoDoSistema
        /// Não abrir nada, e o porquê para a tela e o diário.
        case recusar(String)
    }

    public static func decidir(_ modo: Modo, aparelhos: [AparelhoDeAudio]) -> Decisao {
        switch modo {
        case .produto(let escolhido):
            if let id = escolhido, let a = aparelhos.first(where: { $0.uniqueID == id }) { return .usar(a) }
            return .padraoDoSistema
        case .bancada(let pedido, let laco):
            guard let id = pedido, !id.isEmpty else {
                return .recusar("bancada sem --microfone=<uniqueID>: o microfone não abre "
                                + "(nunca o microfone do MacBook, G5)")
            }
            guard let a = aparelhos.first(where: { $0.uniqueID == id }) else {
                return .recusar("bancada: o microfone \(id) não está entre os aparelhos de áudio agora")
            }
            guard a.transporte == AparelhoDeAudio.virtual else {
                let porque = a.transporte == AparelhoDeAudio.embutido
                    ? "é embutido — nunca o microfone do MacBook (G5)"
                    : "a bancada só aceita dispositivo virtual (G5)"
                return .recusar("bancada: \"\(a.nome)\" tem transporte \(a.nomeDoTransporte); \(porque)")
            }
            guard laco == id else {
                return .recusar("bancada: \"\(a.nome)\" é virtual, mas o laço não está fechado — "
                                + "--tom-no-dispositivo= tem de ser o mesmo dispositivo de --microfone= "
                                + "(um virtual qualquer pode repassar o microfone do MacBook, G5)")
            }
            return .usar(a)
        }
    }
}
