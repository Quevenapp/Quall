import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Codificador H.264 do arnês.
///
/// Deliberadamente **não** reusa `apps/macos/Sources/QuallCaptureKit/H264Encoder.swift`: aquele
/// pacote não declara `products` e tem `.unsafeFlags` num alvo, o que o torna impossível de
/// consumir como dependência SwiftPM. Os ajustes aqui espelham os de lá (tempo real, sem
/// reordenamento, baseline, GOP de 1 s) porque o objetivo é medir o caminho do produto, não um
/// caminho mais rápido inventado para a medição.
public final class Codificador {
    public typealias Saida = (_ annexB: Data, _ pts: CMTime, _ idr: Bool) -> Void

    private var sessao: VTCompressionSession?
    public private(set) var emHardware = false
    public private(set) var nome = "desconhecido"
    public let bitrateBps: Int
    public let gopQuadros: Int

    public init(largura: Int32, altura: Int32, fps: Int32, bitrateBps: Int = 4_000_000) throws {
        self.bitrateBps = bitrateBps
        self.gopQuadros = Int(fps)

        var s: VTCompressionSession?
        let exigeHardware: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: largura, height: altura,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: exigeHardware as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if status != noErr {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: largura, height: altura,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard status == noErr, let sessao = s else { throw ErroDeCodec.sessaoDeEncode(status) }
        self.sessao = sessao

        func ajuste(_ chave: CFString, _ valor: CFTypeRef) {
            VTSessionSetProperty(sessao, key: chave, value: valor)
        }
        ajuste(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        ajuste(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        ajuste(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        ajuste(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrateBps))
        ajuste(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: gopQuadros))
        ajuste(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        ajuste(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: Int(fps)))
        VTCompressionSessionPrepareToEncodeFrames(sessao)

        // Verifico no fluxo, não no retorno: pergunto à sessão já criada se ela é de hardware,
        // em vez de deduzir do sucesso da criação com a especificação.
        var usaHardware: CFTypeRef?
        if VTSessionCopyProperty(
            sessao, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault, valueOut: &usaHardware) == noErr,
            let b = usaHardware as? Bool
        {
            emHardware = b
        }
        var id: CFTypeRef?
        if VTSessionCopyProperty(
            sessao, key: kVTCompressionPropertyKey_EncoderID,
            allocator: kCFAllocatorDefault, valueOut: &id) == noErr,
            let texto = id as? String
        {
            nome = texto
        }
    }

    /// Devolve `false` quando o VideoToolbox **recusou a submissão**. Perda silenciosa é o defeito
    /// que este projeto já pagou caro; aqui ela vira contador.
    @discardableResult
    public func codificar(
        _ pixelBuffer: CVPixelBuffer, pts: CMTime, duracao: CMTime, saida: @escaping Saida
    ) -> Bool {
        guard let sessao else { return false }
        var sinalizadores = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            sessao, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: duracao,
            frameProperties: nil, infoFlagsOut: &sinalizadores
        ) { estado, flags, sampleBuffer in
            guard estado == noErr, !flags.contains(.frameDropped), let sb = sampleBuffer,
                CMSampleBufferGetNumSamples(sb) > 0
            else { return }
            guard let annexB = AnexoB.deSampleBuffer(sb) else { return }
            saida(annexB, CMSampleBufferGetPresentationTimeStamp(sb), AnexoB.ehIDR(sb))
        }
        return status == noErr
    }

    public func encerrar() {
        guard let sessao else { return }
        VTCompressionSessionCompleteFrames(sessao, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(sessao)
        self.sessao = nil
    }
}

public enum ErroDeCodec: Error, CustomStringConvertible {
    case sessaoDeEncode(OSStatus)
    case sessaoDeDecode(OSStatus)
    case formatoDeDecode(OSStatus)
    public var description: String {
        switch self {
        case .sessaoDeEncode(let s): return "VTCompressionSessionCreate falhou (\(s))"
        case .sessaoDeDecode(let s): return "VTDecompressionSessionCreate falhou (\(s))"
        case .formatoDeDecode(let s): return "CMVideoFormatDescriptionCreateFromH264ParameterSets falhou (\(s))"
        }
    }
}

// MARK: - Annex-B

public enum AnexoB {
    public static func ehIDR(_ sb: CMSampleBuffer) -> Bool {
        guard let anexos = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false),
            CFArrayGetCount(anexos) > 0
        else { return true }
        let dicionario = unsafeBitCast(CFArrayGetValueAtIndex(anexos, 0), to: CFDictionary.self)
        let chave = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        guard let valor = CFDictionaryGetValue(dicionario as CFDictionary, chave) else { return true }
        return !(unsafeBitCast(valor, to: CFBoolean.self) as! Bool)
    }

    /// AVCC (prefixo de tamanho) → Annex-B (start code de 4 bytes), com SPS/PPS na frente de todo
    /// quadro IDR. Sem VUI remendado: o remendo de SPS vive em `apps/**` e é de outra frente. Isso
    /// **importa para a leitura do número** e está declarado na seção "o que não cobre".
    public static func deSampleBuffer(_ sb: CMSampleBuffer) -> Data? {
        guard let bloco = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var tamanhoTotal = 0
        var ponteiro: UnsafeMutablePointer<Int8>?
        guard
            CMBlockBufferGetDataPointer(
                bloco, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &tamanhoTotal,
                dataPointerOut: &ponteiro) == noErr, let ponteiro
        else { return nil }

        var saida = Data()
        let inicio: [UInt8] = [0, 0, 0, 1]

        if ehIDR(sb), let formato = CMSampleBufferGetFormatDescription(sb) {
            var quantos = 0
            var tamanhoDoPrefixo: Int32 = 4
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formato, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &quantos,
                nalUnitHeaderLengthOut: &tamanhoDoPrefixo) == noErr
            {
                for i in 0..<quantos {
                    var p: UnsafePointer<UInt8>?
                    var tam = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        formato, parameterSetIndex: i, parameterSetPointerOut: &p,
                        parameterSetSizeOut: &tam, parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil) == noErr, let p
                    {
                        saida.append(contentsOf: inicio)
                        saida.append(p, count: tam)
                    }
                }
            }
        }

        let bytes = UnsafeRawPointer(ponteiro).assumingMemoryBound(to: UInt8.self)
        var deslocamento = 0
        while deslocamento + 4 <= tamanhoTotal {
            var tam: UInt32 = 0
            withUnsafeMutableBytes(of: &tam) { d in
                d.copyMemory(from: UnsafeRawBufferPointer(start: bytes + deslocamento, count: 4))
            }
            let n = Int(UInt32(bigEndian: tam))
            deslocamento += 4
            guard n > 0, deslocamento + n <= tamanhoTotal else { break }
            saida.append(contentsOf: inicio)
            saida.append(bytes + deslocamento, count: n)
            deslocamento += n
        }
        return saida.isEmpty ? nil : saida
    }

    /// Fatia um buffer Annex-B em NALs (aceita start code de 3 e de 4 bytes).
    public static func nals(_ dados: Data) -> [Range<Int>] {
        var resultado: [Range<Int>] = []
        let n = dados.count
        return dados.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> [Range<Int>] in
            var i = 0
            var inicioDoNal = -1
            while i + 2 < n {
                if b[i] == 0 && b[i + 1] == 0 && (b[i + 2] == 1 || (i + 3 < n && b[i + 2] == 0 && b[i + 3] == 1)) {
                    let tamanhoDoCodigo = b[i + 2] == 1 ? 3 : 4
                    if inicioDoNal >= 0 && i > inicioDoNal { resultado.append(inicioDoNal..<i) }
                    inicioDoNal = i + tamanhoDoCodigo
                    i += tamanhoDoCodigo
                } else {
                    i += 1
                }
            }
            if inicioDoNal >= 0 && inicioDoNal < n { resultado.append(inicioDoNal..<n) }
            return resultado
        }
    }
}

/// Decodificador H.264 alimentado por **Annex-B cru**, não por arquivo.
///
/// Essa distinção é a razão de ele existir: o que estava provado no tronco era decode em hardware
/// a partir de `.h264` em disco. Alimentar o decodificador com o que sai do fio, quadro a quadro,
/// é fio novo — e é exatamente o fio que a track vai precisar.
public final class Decodificador {
    public typealias Saida = (_ pixelBuffer: CVPixelBuffer, _ pts: CMTime) -> Void

    private var sessao: VTDecompressionSession?
    private var formato: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private let saida: Saida

    public private(set) var recebidos = 0
    public private(set) var decodificados = 0
    public private(set) var semParametros = 0
    public private(set) var recusados = 0
    public private(set) var sessoesCriadas = 0
    public private(set) var emHardware = false

    public init(saida: @escaping Saida) { self.saida = saida }

    public func alimentar(_ annexB: Data, ptsUs: UInt64, idr: Bool) {
        recebidos += 1
        var vcl = Data()
        var novoSPS: [UInt8]?
        var novoPPS: [UInt8]?
        let faixas = AnexoB.nals(annexB)
        annexB.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for faixa in faixas {
                guard faixa.count > 0 else { continue }
                let tipo = b[faixa.lowerBound] & 0x1F
                let corpo = Array(UnsafeBufferPointer(start: b.baseAddress!.assumingMemoryBound(to: UInt8.self) + faixa.lowerBound, count: faixa.count))
                switch tipo {
                case 7: novoSPS = corpo
                case 8: novoPPS = corpo
                case 1, 5:
                    var tamanho = UInt32(faixa.count).bigEndian
                    withUnsafeBytes(of: &tamanho) { vcl.append(contentsOf: $0) }
                    vcl.append(contentsOf: corpo)
                default: break
                }
            }
        }

        if let novoSPS, let novoPPS, novoSPS != sps || novoPPS != pps {
            sps = novoSPS
            pps = novoPPS
            criarSessao()
        }
        guard let sessao, let formato else {
            semParametros += 1
            return
        }
        guard !vcl.isEmpty else { return }

        var bloco: CMBlockBuffer?
        let bytes = [UInt8](vcl)
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes.count, flags: 0, blockBufferOut: &bloco) == noErr,
            let bloco,
            CMBlockBufferReplaceDataBytes(
                with: bytes, blockBuffer: bloco, offsetIntoDestination: 0, dataLength: bytes.count)
                == noErr
        else {
            recusados += 1
            return
        }

        var amostra: CMSampleBuffer?
        var tamanho = bytes.count
        var tempo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: bloco, formatDescription: formato,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &tempo,
                sampleSizeEntryCount: 1, sampleSizeArray: &tamanho, sampleBufferOut: &amostra)
                == noErr, let amostra
        else {
            recusados += 1
            return
        }

        var saidaDeFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            sessao, sampleBuffer: amostra, flags: [._1xRealTimePlayback], infoFlagsOut: &saidaDeFlags
        ) { [weak self] estado, _, imagem, pts, _ in
            guard let self else { return }
            guard estado == noErr, let imagem else { return }
            self.decodificados += 1
            self.saida(imagem, pts)
        }
        if status != noErr { recusados += 1 }
        _ = idr
    }

    private func criarSessao() {
        if let antiga = sessao {
            VTDecompressionSessionWaitForAsynchronousFrames(antiga)
            VTDecompressionSessionInvalidate(antiga)
            sessao = nil
        }
        guard let sps, let pps else { return }
        var descricao: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { pSPS in
            pps.withUnsafeBufferPointer { pPPS in
                let conjuntos = [pSPS.baseAddress!, pPPS.baseAddress!]
                let tamanhos = [sps.count, pps.count]
                return conjuntos.withUnsafeBufferPointer { pc in
                    tamanhos.withUnsafeBufferPointer { pt in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 2,
                            parameterSetPointers: pc.baseAddress!,
                            parameterSetSizes: pt.baseAddress!, nalUnitHeaderLength: 4,
                            formatDescriptionOut: &descricao)
                    }
                }
            }
        }
        guard status == noErr, let descricao else { return }
        formato = descricao

        let atributos: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: descricao,
            decoderSpecification: nil, imageBufferAttributes: atributos as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &s)
        guard r == noErr, let s else { return }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var usaHardware: CFTypeRef?
        if VTSessionCopyProperty(
            s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault, valueOut: &usaHardware) == noErr,
            let b = usaHardware as? Bool
        {
            emHardware = b
        }
        sessao = s
        sessoesCriadas += 1
    }

    public func encerrar() {
        if let sessao {
            VTDecompressionSessionWaitForAsynchronousFrames(sessao)
            VTDecompressionSessionInvalidate(sessao)
        }
        sessao = nil
    }
}
