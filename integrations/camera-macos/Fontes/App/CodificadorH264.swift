import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Encode H.264 em hardware para o **emissor de bancada**.
///
/// Adaptado de `apps/macos/Sources/QuallCaptureKit/H264Encoder.swift` e `AnnexB.swift`, que é
/// código provado da Frente 3 — mesma configuração (baseline, tempo real, sem reordenamento, GOP
/// curto) e mesma conversão AVCC → Annex-B com SPS/PPS antes de cada IDR. Foi copiado em vez de
/// importado porque `apps/macos` é um pacote SwiftPM de outra frente e este alvo é um app do
/// Xcode: puxá-lo para cá criaria dependência entre propriedades de frentes diferentes por uma
/// ferramenta de bancada.
///
/// O que existe aqui e não lá: **forçar IDR sob demanda**, que é a metade emissora do contrato de
/// track (`ao_pedir_idr`). Sem ela o receptor que entra depois fica sem imagem, que é exatamente
/// o defeito que o M1 mediu no Windows.
final class CodificadorH264 {
    private var sessao: VTCompressionSession?
    private(set) var emHardware = false
    private(set) var nomeDoEncoder = "?"
    private(set) var quadrosCodificados: UInt64 = 0
    private(set) var idrsEmitidos: UInt64 = 0
    private var custos: [UInt64] = []
    private let travaDosCustos = NSLock()
    /// Reescreve o SPS para declarar que aqui não se reordena quadro. Ver `RemendoDeSPS`.
    let remendoDeSPS = RemendoDeSPS()

    private let aoQuadro: (Data, UInt64, Bool) -> Void

    /// Quantos bits por segundo pedir ao encoder, direto do núcleo. Recusa da fronteira cai nos
    /// 4 Mbps históricos e não em zero: um alvo ausente é um encoder sem alvo.
    static func tetoDeTaxa(largura: Int32, altura: Int32, fps: Int32) -> Int32 {
        var t = QuallTeto()
        guard quall_teto_ajustar(UInt32(max(0, largura)), UInt32(max(0, altura)),
                                 UInt32(max(1, fps)), &t) == QUALL_STATUS_OK,
              t.teto_de_taxa_bps > 0 else { return 4_000_000 }
        return Int32(min(t.teto_de_taxa_bps, UInt32(Int32.max)))
    }

    init?(largura: Int32, altura: Int32, fps: Int32, aoQuadro: @escaping (Data, UInt64, Bool) -> Void) {
        self.aoQuadro = aoQuadro
        custos.reserveCapacity(4096)

        let exigirHardware: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var criada: VTCompressionSession?
        var status = VTCompressionSessionCreate(allocator: nil, width: largura, height: altura,
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: exigirHardware as CFDictionary,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &criada)
        if status != noErr || criada == nil {
            status = VTCompressionSessionCreate(allocator: nil, width: largura, height: altura,
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &criada)
        }
        guard status == noErr, let sessao = criada else { return nil }
        self.sessao = sessao

        func ajustar(_ chave: CFString, _ valor: CFTypeRef) { VTSessionSetProperty(sessao, key: chave, value: valor) }
        ajustar(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        ajustar(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        ajustar(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        ajustar(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        ajustar(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps))
        ajustar(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        // **O teto de taxa é perguntado, não escolhido.** Era `4_000_000` cravado até
        // 02/09/2026, e essa câmera virtual passou a 1920x1080 em 01/09 sem que este número
        // subisse junto: 2,25 vezes os pixels pelo mesmo orçamento de bits. Ver
        // `quall_core::teto::teto_de_taxa` — 720p30 continua recebendo os mesmos 4 Mbps.
        ajustar(kVTCompressionPropertyKey_AverageBitRate,
                NSNumber(value: CodificadorH264.tetoDeTaxa(largura: largura, altura: altura, fps: fps)))
        VTCompressionSessionPrepareToEncodeFrames(sessao)

        var emHardwareRef: CFTypeRef?
        VTSessionCopyProperty(sessao, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: &emHardwareRef)
        emHardware = (emHardwareRef as? Bool) ?? false

        var idRef: CFTypeRef?
        VTSessionCopyProperty(sessao, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &idRef)
        nomeDoEncoder = (idRef as? String) ?? (emHardware ? "hardware" : "software")
    }

    deinit { encerrar() }

    func encerrar() {
        guard let sessao else { return }
        VTCompressionSessionCompleteFrames(sessao, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(sessao)
        self.sessao = nil
    }

    func resumoDeCusto() -> (n: Int, media: UInt64, p50: UInt64, p95: UInt64, max: UInt64) {
        travaDosCustos.lock(); defer { travaDosCustos.unlock() }
        guard !custos.isEmpty else { return (0, 0, 0, 0, 0) }
        let o = custos.sorted()
        return (o.count, custos.reduce(0, +) / UInt64(custos.count), o[o.count / 2],
                o[min(o.count - 1, Int(Double(o.count) * 0.95))], o.last!)
    }

    /// Submete um quadro. `forcarIdr` vem do `quall_track_take_idr_request()` do laço de captura —
    /// que é a forma recomendada pelo header para quem já tem um laço por quadro.
    func codificar(_ imagem: CVPixelBuffer, timestampUs: UInt64, forcarIdr: Bool) {
        guard let sessao else { return }
        let propriedades: [CFString: Any]? = forcarIdr ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : nil
        let submissao = Medidas.agoraUs()
        // O sinal de vídeo é lido aqui, do buffer que está sendo submetido: o callback não recebe o
        // pixel buffer, e a format description comprimida do VideoToolbox não propaga faixa nem cor
        // quando a origem é `420v` — medido neste Mac em 2026-08-24.
        let sinal = RemendoDeSPS.SinalDeVideo.doPixelBuffer(imagem)
        VTCompressionSessionEncodeFrame(
            sessao,
            imageBuffer: imagem,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampUs), timescale: 1_000_000),
            duration: .invalid,
            frameProperties: propriedades as CFDictionary?,
            infoFlagsOut: nil
        ) { [weak self] status, bandeiras, amostra in
            guard let self, status == noErr, !bandeiras.contains(.frameDropped), let amostra,
                  CMSampleBufferGetNumSamples(amostra) > 0,
                  let annexb = Self.paraAnnexB(amostra, remendo: self.remendoDeSPS, sinal: sinal)
            else { return }
            let chave = Self.ehChave(amostra)
            self.travaDosCustos.lock()
            if self.custos.count < 100_000 { self.custos.append(Medidas.agoraUs() - submissao) }
            self.travaDosCustos.unlock()
            self.quadrosCodificados += 1
            if chave { self.idrsEmitidos += 1 }
            self.aoQuadro(annexb, timestampUs, chave)
        }
    }

    /// Sem o attachment `NotSync`, o quadro é sync — convenção do VideoToolbox.
    private static func ehChave(_ amostra: CMSampleBuffer) -> Bool {
        guard let lista = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: false) as? [[CFString: Any]],
              let primeiro = lista.first else { return true }
        return !((primeiro[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    /// AVCC → Annex-B. **SPS e PPS vão junto de todo IDR**, como o contrato de track exige: sem
    /// isso quem entra na sessão depois nunca monta a primeira imagem, e o contador
    /// `idrs_without_parameters` do núcleo acusa a casca.
    private static func paraAnnexB(_ amostra: CMSampleBuffer,
                                  remendo: RemendoDeSPS,
                                  sinal: RemendoDeSPS.SinalDeVideo?) -> Data? {
        guard let bloco = CMSampleBufferGetDataBuffer(amostra) else { return nil }
        var total = 0
        var ponteiro: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bloco, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &total, dataPointerOut: &ponteiro) == noErr,
              let ponteiro else { return nil }

        var saida = Data()
        saida.reserveCapacity(total + 128)

        if ehChave(amostra), let descricao = CMSampleBufferGetFormatDescription(amostra) {
            var quantos = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(descricao, parameterSetIndex: 0,
                                                               parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &quantos,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<quantos {
                var p: UnsafePointer<UInt8>?
                var tamanho = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(descricao, parameterSetIndex: i,
                                                                      parameterSetPointerOut: &p,
                                                                      parameterSetSizeOut: &tamanho,
                                                                      parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr,
                   let p {
                    saida.append(contentsOf: [0, 0, 0, 1])
                    if (p[0] & 0x1F) == 7 {
                        saida.append(contentsOf: remendo.spsParaEnviar(
                            UnsafeRawBufferPointer(start: p, count: tamanho), sinal: sinal))
                    } else {
                        saida.append(UnsafeBufferPointer(start: p, count: tamanho))
                    }
                }
            }
        }

        ponteiro.withMemoryRebound(to: UInt8.self, capacity: total) { bytes in
            var deslocamento = 0
            while deslocamento + 4 <= total {
                let tamanho = (Int(bytes[deslocamento]) << 24) | (Int(bytes[deslocamento + 1]) << 16)
                    | (Int(bytes[deslocamento + 2]) << 8) | Int(bytes[deslocamento + 3])
                deslocamento += 4
                guard tamanho >= 0, deslocamento + tamanho <= total else { break }
                saida.append(contentsOf: [0, 0, 0, 1])
                saida.append(UnsafeBufferPointer(start: bytes + deslocamento, count: tamanho))
                deslocamento += tamanho
            }
        }
        return saida
    }
}
