import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decode H.264 em hardware, no app anfitrião.
///
/// A saída é `420v` — faixa limitada, o padrão do projeto — e **respaldada por `IOSurface`**, que
/// não é detalhe: é o que permite o quadro atravessar para o processo da extensão sem cópia. Um
/// `CVPixelBuffer` sem `IOSurface` não é compartilhável, e o `CMSimpleQueue` do CoreMediaIO
/// entregaria memória que o outro processo não pode mapear.
final class DecodificadorH264 {
    private var sessao: VTDecompressionSession?
    private var descricao: CMFormatDescription?
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []
    /// O terceiro argumento é **`suspeito`**: a referência deste quadro foi condenada.
    ///
    /// Ele viaja por aqui, e não por uma variável do receptor, porque esta casca decodifica com
    /// `_EnableAsynchronousDecompression` — a saída não sai na thread que alimentou, nem
    /// necessariamente na mesma ordem. Uma bandeira lida no `entregar` pertenceria ao quadro
    /// errado. É a diferença desta casca para os receptores do iOS e do macOS, onde o decode é
    /// síncrono dentro do tratador e a bandeira simples basta.
    private let aoQuadro: (CVPixelBuffer, CMTime, Bool) -> Void

    private(set) var recebidos: UInt64 = 0
    private(set) var decodificados: UInt64 = 0
    private(set) var recusados: UInt64 = 0
    private(set) var semParametros: UInt64 = 0
    private var custos: [UInt64] = []
    private let travaDosCustos = NSLock()

    private(set) var largura: Int32 = 0
    private(set) var altura: Int32 = 0

    init(aoQuadro: @escaping (CVPixelBuffer, CMTime, Bool) -> Void) {
        self.aoQuadro = aoQuadro
        custos.reserveCapacity(4096)
    }

    deinit {
        if let sessao {
            VTDecompressionSessionWaitForAsynchronousFrames(sessao)
            VTDecompressionSessionInvalidate(sessao)
        }
    }

    func resumoDeCusto() -> (n: Int, media: UInt64, p50: UInt64, p95: UInt64, max: UInt64) {
        travaDosCustos.lock(); defer { travaDosCustos.unlock() }
        guard !custos.isEmpty else { return (0, 0, 0, 0, 0) }
        let o = custos.sorted()
        return (o.count,
                custos.reduce(0, +) / UInt64(custos.count),
                o[o.count / 2],
                o[min(o.count - 1, Int(Double(o.count) * 0.95))],
                o.last!)
    }

    /// Recebe um quadro Annex-B completo do núcleo. O ponteiro vale **só durante a chamada**.
    /// [suspeito] diz que a referência deste quadro foi condenada: ele **é decodificado** —
    /// parar de alimentar o VideoToolbox dessincronizaria a sessão — e sai marcado, para que
    /// quem o entrega decida não entregá-lo. Ver o bit 63 do `sourceFrameRefCon`, abaixo.
    func alimentar(annexb: UnsafeRawBufferPointer, timestampUs: UInt64, idr: Bool,
                   suspeito: Bool = false) {
        recebidos += 1
        var vcl: [(Int, Int)] = []   // (deslocamento, tamanho) de cada NAL de imagem
        var novoSps: [UInt8]?
        var novoPps: [UInt8]?

        percorrerNals(annexb) { inicio, tamanho in
            let tipo = annexb[inicio] & 0x1F
            switch tipo {
            case 7: novoSps = Array(UnsafeRawBufferPointer(rebasing: annexb[inicio..<(inicio + tamanho)]))
            case 8: novoPps = Array(UnsafeRawBufferPointer(rebasing: annexb[inicio..<(inicio + tamanho)]))
            case 1, 5: vcl.append((inicio, tamanho))
            default: break
            }
        }

        // **Sem sessão, todo IDR tenta de novo** (o M9 da crítica de 21/09): o par é guardado antes
        // de a sessão nascer, e uma recusa do VideoToolbox deixava os IDR seguintes com o mesmo
        // par sem tentar — a imagem parava até o SPS mudar. Com a troca de tamanho no meio da
        // sessão virando rotina, uma recusa única na troca congelaria a tela até a troca seguinte.
        if let novoSps, let novoPps, novoSps != sps || novoPps != pps || sessao == nil {
            sps = novoSps
            pps = novoPps
            recriarSessao()
        }
        guard sessao != nil, let descricao else {
            semParametros += 1
            return
        }
        guard !vcl.isEmpty else { return }

        // Annex-B -> AVCC: os start codes viram prefixos de tamanho de 4 bytes, big-endian.
        var carga = [UInt8]()
        carga.reserveCapacity(annexb.count + 8)
        for (inicio, tamanho) in vcl {
            let n = UInt32(tamanho).bigEndian
            withUnsafeBytes(of: n) { carga.append(contentsOf: $0) }
            carga.append(contentsOf: UnsafeRawBufferPointer(rebasing: annexb[inicio..<(inicio + tamanho)]))
        }

        var bloco: CMBlockBuffer?
        let criou = carga.withUnsafeMutableBytes { p -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                               memoryBlock: p.baseAddress,
                                               blockLength: p.count,
                                               blockAllocator: kCFAllocatorNull,
                                               customBlockSource: nil,
                                               offsetToData: 0,
                                               dataLength: p.count,
                                               flags: 0,
                                               blockBufferOut: &bloco)
        }
        guard criou == noErr, let bloco else { recusados += 1; return }

        var amostra: CMSampleBuffer?
        var tamanho = carga.count
        var tempo = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: CMTime(value: CMTimeValue(timestampUs), timescale: 1_000_000),
                                       decodeTimeStamp: .invalid)
        let fez = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                            dataBuffer: bloco,
                                            formatDescription: descricao,
                                            sampleCount: 1,
                                            sampleTimingEntryCount: 1,
                                            sampleTimingArray: &tempo,
                                            sampleSizeEntryCount: 1,
                                            sampleSizeArray: &tamanho,
                                            sampleBufferOut: &amostra)
        guard fez == noErr, let amostra, let sessao else { recusados += 1; return }

        // O instante da submissão viaja como **valor** no `sourceFrameRefCon`, que nunca é
        // dereferenciado. Evita uma alocação por quadro só para medir latência de decode.
        //
        // **E o bit 63 carrega a condenação da cadeia de referência**, de carona no mesmo valor.
        // `agoraUs()` é microssegundo monotônico desde o arranque: para acender o bit 63 sozinho
        // ele precisaria de 2^63 µs, que são 292 mil anos de uptime. Não há perda de precisão e
        // não há alocação nova — a alternativa seria um dicionário por quadro, na thread que
        // menos pode pagar por um.
        let submissao = Medidas.agoraUs()
        let marca = UnsafeMutableRawPointer(bitPattern: UInt(submissao | (suspeito ? DecodificadorH264.bitDeSuspeita : 0)))
        var saida = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            sessao,
            sampleBuffer: amostra,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            frameRefcon: marca,
            infoFlagsOut: &saida)
        if status != noErr { recusados += 1 }
    }

    private func recriarSessao() {
        if let antiga = sessao {
            VTDecompressionSessionWaitForAsynchronousFrames(antiga)
            VTDecompressionSessionInvalidate(antiga)
            sessao = nil
        }
        var nova: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { s -> OSStatus in
            pps.withUnsafeBufferPointer { p -> OSStatus in
                let conjuntos = [s.baseAddress!, p.baseAddress!]
                let tamanhos = [s.count, p.count]
                return conjuntos.withUnsafeBufferPointer { cp in
                    tamanhos.withUnsafeBufferPointer { tp in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: cp.baseAddress!,
                            parameterSetSizes: tp.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &nova)
                    }
                }
            }
        }
        guard status == noErr, let nova else { return }
        descricao = nova
        let dim = CMVideoFormatDescriptionGetDimensions(nova)
        largura = dim.width
        altura = dim.height

        let atributos: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            // Sem `IOSurface` o quadro decodificado não atravessa para a extensão.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { eu, refcon, status, _, imagem, _, _ in
                guard let eu else { return }
                let quem = Unmanaged<DecodificadorH264>.fromOpaque(eu).takeUnretainedValue()
                quem.saiu(status: status, imagem: imagem, marca: refcon)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        var criada: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                             formatDescription: nova,
                                             decoderSpecification: nil,
                                             imageBufferAttributes: atributos as CFDictionary,
                                             outputCallback: &callback,
                                             decompressionSessionOut: &criada)
        guard r == noErr, let criada else { return }
        VTSessionSetProperty(criada, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        sessao = criada
    }

    /// O bit do `sourceFrameRefCon` que diz "a referência deste quadro foi condenada".
    static let bitDeSuspeita: UInt64 = 1 << 63

    private func saiu(status: OSStatus, imagem: CVImageBuffer?, marca: UnsafeMutableRawPointer?) {
        guard status == noErr, let imagem else { recusados += 1; return }
        let cru = UInt64(UInt(bitPattern: marca))
        let suspeito = (cru & DecodificadorH264.bitDeSuspeita) != 0
        let submissao = cru & ~DecodificadorH264.bitDeSuspeita
        let custo = submissao > 0 ? Medidas.agoraUs() - submissao : 0
        travaDosCustos.lock()
        if custos.count < 100_000 { custos.append(custo) }
        travaDosCustos.unlock()
        decodificados += 1
        aoQuadro(imagem, CMClockGetTime(CMClockGetHostTimeClock()), suspeito)
    }

    /// Varre os NALs de um quadro Annex-B, aceitando start code de 3 e de 4 bytes.
    private func percorrerNals(_ dados: UnsafeRawBufferPointer, _ visitar: (Int, Int) -> Void) {
        let n = dados.count
        var i = 0
        var inicioDoNal = -1
        while i + 2 < n {
            if dados[i] == 0, dados[i + 1] == 0, dados[i + 2] == 1 {
                if inicioDoNal >= 0 {
                    var fim = i
                    if fim > inicioDoNal, dados[fim - 1] == 0 { fim -= 1 }  // start code de 4 bytes
                    if fim > inicioDoNal { visitar(inicioDoNal, fim - inicioDoNal) }
                }
                i += 3
                inicioDoNal = i
                continue
            }
            i += 1
        }
        if inicioDoNal >= 0, inicioDoNal < n { visitar(inicioDoNal, n - inicioDoNal) }
    }
}
