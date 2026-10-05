import CoreVideo
import Foundation
import VideoToolbox

/// Encaixa o quadro decodificado na dimensão que a câmera virtual publica.
///
/// Existe porque o emissor manda o que a origem dele produz — 720x1280 de um celular em pé,
/// 1920x1080 de uma tela — e a webcam publica 1920x1080 fixo. Trocar o formato publicado a cada
/// origem faria o app de videoconferência renegociar no meio da chamada, que é pior do que
/// barra preta.
///
/// **A lição do iOS vale aqui, com o sinal trocado.** Lá, `imageBufferAttributes` só converte a
/// faixa de cor **quando há reescala** — então a câmera, que não reescalava, saía em faixa
/// completa. Aqui, quando as dimensões batem, esta classe **não** faz transferência nenhuma: o
/// quadro do decoder vai direto para a extensão. Não há conversão implícita para dar errado, e
/// não há cópia para pagar.
final class Ajustador {
    private var sessao: VTPixelTransferSession?
    private var reservatorio: CVPixelBufferPool?
    private let largura: Int32
    private let altura: Int32

    private(set) var passesDiretos: UInt64 = 0
    private(set) var transferencias: UInt64 = 0
    private var custos: [UInt64] = []

    init(largura: Int32, altura: Int32) {
        self.largura = largura
        self.altura = altura
        let atributos: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: largura,
            kCVPixelBufferHeightKey: altura,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, atributos as CFDictionary, &reservatorio)

        var nova: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &nova)
        if let nova {
            VTSessionSetProperty(nova, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: kVTScalingMode_Letterbox)
            VTSessionSetProperty(nova, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
            sessao = nova
        }
    }

    func resumoDeCusto() -> (n: Int, media: UInt64, p95: UInt64, max: UInt64) {
        guard !custos.isEmpty else { return (0, 0, 0, 0) }
        let o = custos.sorted()
        return (o.count, custos.reduce(0, +) / UInt64(custos.count),
                o[min(o.count - 1, Int(Double(o.count) * 0.95))], o.last!)
    }

    func ajustar(_ origem: CVPixelBuffer) -> CVPixelBuffer? {
        let l = Int32(CVPixelBufferGetWidth(origem))
        let a = Int32(CVPixelBufferGetHeight(origem))
        if l == largura, a == altura {
            passesDiretos += 1
            marcar(origem)
            return origem
        }
        guard let reservatorio, let sessao else { return nil }
        var destino: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, reservatorio, &destino) == kCVReturnSuccess,
              let destino else { return nil }
        let t0 = Medidas.agoraUs()
        let r = VTPixelTransferSessionTransferImage(sessao, from: origem, to: destino)
        guard r == noErr else { return nil }
        if custos.count < 100_000 { custos.append(Medidas.agoraUs() - t0) }
        transferencias += 1
        marcar(destino)
        return destino
    }

    /// BT.709 declarado no próprio buffer, para o consumidor não ter de adivinhar.
    private func marcar(_ b: CVPixelBuffer) {
        CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
