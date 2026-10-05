// Gera um par sidecar/`.h264` **sintético** para a bancada do PLI.
//
// Por que ele existe, e por que não reaproveitei o `captura.{json,h264}` que já roda nas outras
// frentes: aquele par é uma captura `ScreenCaptureKit` da tela do usuário (a `regras-de-frente.md`
// registra o dia em que um quadro dele foi aberto por engano), e ele mora no A10s, que não é meu
// nesta rodada. Aqui a origem é um padrão desenhado por código — barras que andam e um bloco que
// pisca —, então não há nada do usuário dentro do arquivo e ele pode ser inspecionado à vontade.
//
// O que este clipe precisa ter, e o `captura.h264` não tem:
//
//  1. **GOP longo e conhecido.** O defeito que esta frente mede é "o decodificador fica sem
//     referência até o próximo IDR programado", e o número que dói é o do Android:
//     `GOP_SEGUNDOS_CAMERA = 2f`. Com um clipe de 3 IDR em 29 quadros o pior caso é ~0,3 s, e o
//     A/B mediria a bancada em vez do produto. `--gop-segundos 2` reproduz a condição do produto.
//  2. **Movimento de verdade em todo quadro.** Quadro P quase vazio cabe num pacote só, e uma
//     rajada de perda que caia nele não condena quase nada. O padrão daqui muda a imagem inteira
//     a cada quadro, o que aproxima a distribuição de tamanho da de uma câmera.
//
// Encoder e conversão AVCC → Annex-B são os mesmos do `CodificadorH264.swift` do emissor de
// bancada — baseline, tempo real, sem reordenamento, SPS/PPS junto de todo IDR, com o
// `RemendoDeSPS` para o SPS declarar que não reordena. Compila junto com aquele arquivo, e não
// copiando dele, justamente para não haver duas verdades.
//
//   swiftc -O gerar-clipe/main.swift ../Fontes/App/RemendoDeSPS.swift -o /tmp/gerar-clipe
//   /tmp/gerar-clipe --saida /tmp/pli-clipe --segundos 20 --gop-segundos 2

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

func arg(_ nome: String, _ padrao: Double) -> Double {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: nome), i + 1 < a.count, let v = Double(a[i + 1]) else { return padrao }
    return v
}

func argTexto(_ nome: String, _ padrao: String) -> String {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: nome), i + 1 < a.count else { return padrao }
    return a[i + 1]
}

let saidaDir = argTexto("--saida", "/tmp/pli-clipe")
let largura = Int32(arg("--largura", 1280))
let altura = Int32(arg("--altura", 720))
let fps = Int32(arg("--fps", 30))
let segundos = arg("--segundos", 20)
let gopSegundos = arg("--gop-segundos", 2)
let bitrate = Int(arg("--bitrate", 4_000_000))
let nomeVideo = "sintetico.h264"

let totalQuadros = Int(segundos * Double(fps))
try? FileManager.default.createDirectory(atPath: saidaDir, withIntermediateDirectories: true)
let caminhoH264 = (saidaDir as NSString).appendingPathComponent(nomeVideo)
let caminhoJSON = (saidaDir as NSString).appendingPathComponent("sintetico.json")

// -------------------------------------------------------------------------------------------------
// O padrão: barras diagonais que andam, mais um bloco que muda de lugar a cada quadro.
//
// **Faixa limitada**, como o `contrato-sidecar.md` fixa: Y fica em 16..235 e CbCr em 16..240, e o
// pixel buffer é `420YpCbCr8BiPlanarVideoRange` — no macOS é o formato de entrada que decide a
// faixa, não uma propriedade da sessão de compressão.
// -------------------------------------------------------------------------------------------------
func desenhar(_ buffer: CVPixelBuffer, quadro: Int) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let l = CVPixelBufferGetWidth(buffer), a = CVPixelBufferGetHeight(buffer)

    if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        let passo = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let p = y.assumingMemoryBound(to: UInt8.self)
        let desl = quadro * 7
        for linha in 0..<a {
            let base = linha * passo
            for coluna in 0..<l {
                // Barras diagonais de período 64 px, andando 7 px por quadro: todo pixel muda.
                let v = ((coluna + linha + desl) / 32) % 2 == 0 ? 200 : 40
                p[base + coluna] = UInt8(v)
            }
        }
        // Bloco de 120x120 que caminha em diagonal e reflete nas bordas — movimento local forte,
        // que é o que faz o encoder gastar bits em quadro P.
        let bx = Int(abs(((Double(quadro) * 13).truncatingRemainder(dividingBy: Double(2 * (l - 120)))) - Double(l - 120)))
        let by = Int(abs(((Double(quadro) * 9).truncatingRemainder(dividingBy: Double(2 * (a - 120)))) - Double(a - 120)))
        for linha in by..<min(by + 120, a) {
            let base = linha * passo
            for coluna in bx..<min(bx + 120, l) { p[base + coluna] = 235 }
        }
    }
    if let cbcr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
        let passo = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let p = cbcr.assumingMemoryBound(to: UInt8.self)
        for linha in 0..<(a / 2) {
            let base = linha * passo
            for coluna in 0..<(l / 2) {
                p[base + coluna * 2] = UInt8(110 + (quadro % 20))
                p[base + coluna * 2 + 1] = UInt8(140 - (quadro % 20))
            }
        }
    }
}

// -------------------------------------------------------------------------------------------------
// Encode
// -------------------------------------------------------------------------------------------------
var criada: VTCompressionSession?
guard VTCompressionSessionCreate(allocator: nil, width: largura, height: altura,
                                 codecType: kCMVideoCodecType_H264,
                                 encoderSpecification: nil, imageBufferAttributes: nil,
                                 compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                 compressionSessionOut: &criada) == noErr,
      let sessao = criada else {
    FileHandle.standardError.write("VTCompressionSessionCreate falhou\n".data(using: .utf8)!)
    exit(1)
}
func ajustar(_ chave: CFString, _ valor: CFTypeRef) { VTSessionSetProperty(sessao, key: chave, value: valor) }
ajustar(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
ajustar(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
ajustar(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
ajustar(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
ajustar(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(gopSegundos * Double(fps))))
ajustar(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: gopSegundos))
ajustar(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
VTCompressionSessionPrepareToEncodeFrames(sessao)

var emHardwareRef: CFTypeRef?
VTSessionCopyProperty(sessao, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                      allocator: nil, valueOut: &emHardwareRef)
let emHardware = (emHardwareRef as? Bool) ?? false
var idRef: CFTypeRef?
VTSessionCopyProperty(sessao, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &idRef)
let nomeDoEncoder = (idRef as? String) ?? (emHardware ? "hardware" : "software")

let remendo = RemendoDeSPS()

func ehChave(_ amostra: CMSampleBuffer) -> Bool {
    guard let lista = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: false) as? [[CFString: Any]],
          let primeiro = lista.first else { return true }
    return !((primeiro[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
}

/// AVCC → Annex-B, com SPS/PPS antes de todo IDR. Mesma forma do `CodificadorH264.paraAnnexB`.
func paraAnnexB(_ amostra: CMSampleBuffer, sinal: RemendoDeSPS.SinalDeVideo?) -> Data? {
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

let atributos: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferWidthKey: largura,
    kCVPixelBufferHeightKey: altura,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
]
var reservatorio: CVPixelBufferPool?
CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, atributos as CFDictionary, &reservatorio)
guard let reservatorio else {
    FileHandle.standardError.write("sem reservatório de pixels\n".data(using: .utf8)!)
    exit(1)
}

struct Registro { let numero: Int; let timestampUs: UInt64; let bytes: Int; let idr: Bool }
final class Caixa {
    var dados = Data()
    var registros: [Registro] = []
    let trava = NSLock()
}
let caixa = Caixa()

FileHandle.standardError.write("gerando \(totalQuadros) quadros \(largura)x\(altura) @\(fps), GOP \(gopSegundos)s…\n".data(using: .utf8)!)

for numero in 0..<totalQuadros {
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, reservatorio, &buffer)
    guard let buffer else { continue }
    desenhar(buffer, quadro: numero)
    let ts = UInt64(numero) * UInt64(1_000_000 / Int(fps))
    let sinal = RemendoDeSPS.SinalDeVideo.doPixelBuffer(buffer)
    VTCompressionSessionEncodeFrame(
        sessao, imageBuffer: buffer,
        presentationTimeStamp: CMTime(value: CMTimeValue(ts), timescale: 1_000_000),
        duration: .invalid, frameProperties: nil, infoFlagsOut: nil
    ) { status, bandeiras, amostra in
        guard status == noErr, !bandeiras.contains(.frameDropped), let amostra,
              CMSampleBufferGetNumSamples(amostra) > 0,
              let annexb = paraAnnexB(amostra, sinal: sinal) else { return }
        let idr = ehChave(amostra)
        caixa.trava.lock()
        // A ordem de saída é a de entrada: baseline, sem reordenamento. O número do quadro sai da
        // contagem de saída, e não do `numero` capturado, para o sidecar descrever o arquivo e não
        // a intenção.
        caixa.registros.append(Registro(numero: caixa.registros.count,
                                        timestampUs: UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(amostra)) * 1_000_000),
                                        bytes: annexb.count, idr: idr))
        caixa.dados.append(annexb)
        caixa.trava.unlock()
    }
}
VTCompressionSessionCompleteFrames(sessao, untilPresentationTimeStamp: .invalid)
VTCompressionSessionInvalidate(sessao)

guard let primeiro = caixa.registros.first, primeiro.idr else {
    FileHandle.standardError.write("o primeiro quadro não saiu IDR; o sidecar exige que saia\n".data(using: .utf8)!)
    exit(1)
}

try caixa.dados.write(to: URL(fileURLWithPath: caminhoH264))

var quadrosJSON: [[String: Any]] = []
for r in caixa.registros {
    quadrosJSON.append([
        "number": r.numero, "timestamp_us": r.timestampUs, "bytes": r.bytes,
        "idr": r.idr, "encode_latency_us": 0,
    ])
}
let sidecar: [String: Any] = [
    "header": [
        "width": Int(largura), "height": Int(altura), "target_fps": Int(fps),
        "preset": "camera",
        "capture_api": "padrão sintético (bancada do PLI)",
        "encoder": nomeDoEncoder, "encoder_is_hardware": emHardware,
        "target_bitrate_bps": bitrate,
        "gop_frames": Int(gopSegundos * Double(fps)),
        "color_range": "limited",
        "video_file": nomeVideo,
    ],
    "frames": quadrosJSON,
]
let dados = try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys])
try dados.write(to: URL(fileURLWithPath: caminhoJSON))

let idrs = caixa.registros.filter { $0.idr }.count
let bytes = caixa.dados.count
print("clipe: \(caminhoH264) — \(bytes) B, \(caixa.registros.count) quadros, \(idrs) IDR")
print("sidecar: \(caminhoJSON)")
print("encoder: \(nomeDoEncoder) hardware=\(emHardware)")
