import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Um `VTCompressionSession` H.264 com contadores. Não é o `CodificadorH264` do produto (que
/// converte para Annex-B e fala com o núcleo): aqui a saída é o `CMSampleBuffer` AVCC que o
/// VideoToolbox entrega, que é exatamente o que o `AVAssetWriterInput` de passagem aceita. Para a
/// "rede" a saída só é contada — o custo que importa medir é o do codificador, não o do envio.
///
/// Duas escolhas copiadas do produto, porque mudam a carga medida:
/// * `RealTime = true` e `AllowFrameReordering = false`;
/// * teto de quadros em voo: se o A10 não acompanhar, descarta e **conta**, em vez de enfileirar.
final class Codificador {
    let nome: String
    let largura: Int32
    let altura: Int32
    private let sessao: VTCompressionSession

    /// Chamado na fila do VideoToolbox. O buffer é AVCC com format description.
    var saida: ((CMSampleBuffer) -> Void)?

    private let trava = NSLock()
    private var emVoo = 0
    private let tetoEmVoo = 3
    private(set) var entregues = 0
    private(set) var descartadosEmVoo = 0
    private(set) var falhas = 0
    private(set) var descartadosPeloVT = 0
    private(set) var ultimaFalha: OSStatus = 0

    struct Falha: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "VTCompressionSessionCreate falhou: \(status)" }
    }

    init(nome: String, largura: Int32, altura: Int32, bitrate: Int, perfilAlto: Bool,
         intervaloDeIDR: Int) throws {
        self.nome = nome
        self.largura = largura
        self.altura = altura
        var s: VTCompressionSession?
        // Sem especificação de codificador: a chave "exigir hardware" só existe no iOS 17.4, e no
        // iPhone o H.264 do VideoToolbox é sempre o do hardware.
        let st = VTCompressionSessionCreate(
            allocator: nil, width: largura, height: altura, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard st == noErr, let sessao = s else { throw Falha(status: st) }
        self.sessao = sessao
        let perfil = perfilAlto ? kVTProfileLevel_H264_High_AutoLevel
                                : kVTProfileLevel_H264_Baseline_AutoLevel
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_ProfileLevel, value: perfil)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bitrate as CFNumber)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: 30 as CFNumber)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: intervaloDeIDR as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(sessao)
    }

    /// Chamado na fila da captura. Assíncrono: a saída chega depois, na fila do VideoToolbox.
    func codificar(_ imagem: CVImageBuffer, pts: CMTime, duracao: CMTime) {
        trava.lock()
        if emVoo >= tetoEmVoo {
            descartadosEmVoo += 1
            trava.unlock()
            return
        }
        emVoo += 1
        trava.unlock()

        let st = VTCompressionSessionEncodeFrame(
            sessao, imageBuffer: imagem, presentationTimeStamp: pts, duration: duracao,
            frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, flags, amostra in
            guard let self = self else { return }
            self.trava.lock()
            self.emVoo = max(0, self.emVoo - 1)
            if status != noErr {
                self.falhas += 1
                self.ultimaFalha = status
            } else if flags.contains(.frameDropped) || amostra == nil {
                self.descartadosPeloVT += 1
            } else {
                self.entregues += 1
            }
            self.trava.unlock()
            if status == noErr, let amostra = amostra { self.saida?(amostra) }
        }
        if st != noErr {
            trava.lock()
            emVoo = max(0, emVoo - 1)
            falhas += 1
            ultimaFalha = st
            trava.unlock()
        }
    }

    struct Contagem {
        var entregues = 0, descartadosEmVoo = 0, falhas = 0, descartadosPeloVT = 0
        var ultimaFalha: OSStatus = 0
    }

    func contagem() -> Contagem {
        trava.lock(); defer { trava.unlock() }
        return Contagem(entregues: entregues, descartadosEmVoo: descartadosEmVoo, falhas: falhas,
                        descartadosPeloVT: descartadosPeloVT, ultimaFalha: ultimaFalha)
    }

    func encerrar() {
        VTCompressionSessionCompleteFrames(sessao, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(sessao)
    }
}
