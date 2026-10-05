// Codifica uma origem **sintética crua** com o `H264Encoder` do produto e entrega o par do
// `docs/contrato-sidecar.md`. É a peça que faltava para medir qualidade de imagem do emissor do
// macOS sem capturar tela nenhuma.
//
// ## Por que existe
//
// O emissor do macOS estava provado **no nível do bitstream** — `sonda-sps` lê o SPS que sai do
// mesmo `H264Encoder` e confere profile e nível no artefato — e nunca **ponta a ponta em pixels**:
// ninguém jamais comparou o que sai do decodificador com o que entrou no encoder. A razão não era
// preguiça, era a regra: a única origem que o emissor do macOS tinha era o ScreenCaptureKit, e a
// tela do MacBook é a máquina de trabalho do usuário. `docs/regras-de-frente.md` proíbe
// renderizar, gravar ou abrir um quadro dessa origem, e a proibição vale inteira.
//
// A saída é dar ao encoder **outra origem**. Esta sonda lê quadros NV12 crus de um arquivo —
// gerados por `tools/qualidade-de-imagem.py` a partir do `testsrc2` do ffmpeg, padrão sintético
// nosso — e os empurra pelo encoder de verdade. O que sai pode ser decodificado, olhado e medido,
// porque nada da vida de ninguém entrou nele.
//
// ## O que ela usa do produto, e o que ela não usa
//
// **Usa**: `H264Encoder` (a mesma `VTCompressionSession`, o mesmo preset, a mesma configuração de
// zero filas), `TetoDoEmissor` e `RemendoDeSPS`. É o mesmo caminho de encode que o app de produto
// percorre, e é por isso que o número vale para ele.
//
// **Não usa**: `ScreenCapturer`, `CaptureSession`, `AVCaptureSession` — nenhuma captura. O que
// esta sonda **não** prova, portanto, é o elo entre o ScreenCaptureKit e o encoder: a conversão de
// formato de pixel, o ritmo de entrega e o que quer que a `SCStreamConfiguration` faça com a
// imagem antes de ela chegar aqui. Esse elo continua sem prova em pixels, e continua sem ela por
// um motivo que não é técnico.
//
// ## Uso
//
//   ffmpeg -i referencia.mkv -pix_fmt nv12 -f rawvideo origem.nv12
//   swift run sonda-qualidade --entrada origem.nv12 --largura 1274 --altura 716 --fps 24 \
//       --saida /tmp/macos
//   # produz /tmp/macos.h264 e /tmp/macos.json
//
// `--sem-teto` desliga o `TetoDoEmissor` para medir a resolução pedida sem redução — útil só para
// separar o custo do teto do custo do encoder, e **não** é o caminho do produto.

import CoreMedia
import CoreVideo
import Foundation
import QuallCaptureKit

struct Opcoes {
    var entrada: String = ""
    var saida: String = "saida"
    var largura: Int32 = 1274
    var altura: Int32 = 716
    var fps: Int32 = 24
    var preset: CapturePreset = .screen
    var comTeto: Bool = true
}

func uso() -> Never {
    FileHandle.standardError.write("""
    sonda-qualidade — codifica uma origem sintética crua com o encoder do produto.

      --entrada ARQ.nv12   quadros NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) crus
      --saida PREFIXO      escreve PREFIXO.h264 e PREFIXO.json
      --largura N --altura N --fps N
      --preset screen|camera
      --sem-teto           não aplica TetoDoEmissor (fora do caminho do produto)

    A origem TEM de ser padrão sintético. Não aponte esta sonda para captura de tela.

    """.data(using: .utf8)!)
    exit(2)
}

var o = Opcoes()
var i = 1
let args = CommandLine.arguments
while i < args.count {
    switch args[i] {
    case "--entrada": i += 1; if i < args.count { o.entrada = args[i] }
    case "--saida": i += 1; if i < args.count { o.saida = args[i] }
    case "--largura": i += 1; if i < args.count { o.largura = Int32(args[i]) ?? o.largura }
    case "--altura": i += 1; if i < args.count { o.altura = Int32(args[i]) ?? o.altura }
    case "--fps": i += 1; if i < args.count { o.fps = Int32(args[i]) ?? o.fps }
    case "--preset":
        i += 1
        if i < args.count { o.preset = args[i] == "camera" ? .camera : .screen }
    case "--sem-teto": o.comTeto = false
    case "--help", "-h": uso()
    default: break
    }
    i += 1
}
if o.entrada.isEmpty { uso() }

// O teto é do produto: `TetoDoEmissor` é o que faz o emissor caber no nível 3.1 que o SDP
// promete. Medir sem ele mediria um emissor que não existe.
var largura = Int(o.largura)
var altura = Int(o.altura)
var fps = o.fps
if o.comTeto {
    let t = TetoDoEmissor.ajustar(largura: largura, altura: altura, fps: fps)
    if t.largura != largura || t.altura != altura || t.fps != fps {
        FileHandle.standardError.write(
            "teto: \(largura)x\(altura)@\(fps) -> \(t.largura)x\(t.altura)@\(t.fps)\n"
                .data(using: .utf8)!)
    }
    largura = t.largura
    altura = t.altura
    fps = t.fps
}

// **Recusa em vez de escalar.** Esta sonda não sabe redimensionar, e escalar aqui poria uma
// reamostragem nossa dentro de uma medição de qualidade — o número mediria o escalador. Se o teto
// mudou o tamanho, quem gera a origem crua tem de gerá-la já no tamanho certo.
guard largura == Int(o.largura), altura == Int(o.altura) else {
    FileHandle.standardError.write("""
    o teto reduziu \(o.largura)x\(o.altura) para \(largura)x\(altura), e esta sonda não
    redimensiona: reamostrar aqui poria um escalador nosso dentro da medição de qualidade.
    Gere a origem crua já em \(largura)x\(altura) (e a referência também).

    """.data(using: .utf8)!)
    exit(1)
}

let bytesPorQuadro = largura * altura * 3 / 2
guard let dados = FileManager.default.contents(atPath: o.entrada) else {
    FileHandle.standardError.write("não consegui ler \(o.entrada)\n".data(using: .utf8)!)
    exit(1)
}
guard dados.count % bytesPorQuadro == 0, dados.count > 0 else {
    FileHandle.standardError.write("""
    \(o.entrada) tem \(dados.count) B, que não é múltiplo de \(bytesPorQuadro) B
    (\(largura)x\(altura) NV12). O tamanho declarado não é o do arquivo.

    """.data(using: .utf8)!)
    exit(1)
}
let totalDeQuadros = dados.count / bytesPorQuadro

/// Um `CVPixelBuffer` NV12 com os bytes crus de um quadro. Copia linha a linha porque o
/// `bytesPerRow` do `CVPixelBuffer` é alinhado pelo sistema e quase nunca é igual à largura.
func quadro(_ n: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let atributos: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    guard CVPixelBufferCreate(kCFAllocatorDefault, largura, altura,
                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              atributos as CFDictionary, &pb) == kCVReturnSuccess,
          let pb else { return nil }

    // A faixa é declarada no buffer, e não deixada em branco: `RemendoDeSPS.SinalDeVideo` lê
    // estes anexos para escrever o VUI, e um buffer sem eles produziria um SPS que não declara o
    // que o fluxo de fato é — que é exatamente a dívida que `RemendoDeSPS` existe para pagar.
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    let base = n * bytesPorQuadro
    dados.withUnsafeBytes { (cru: UnsafeRawBufferPointer) in
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let passo = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let destino = y.assumingMemoryBound(to: UInt8.self)
            for linha in 0..<altura {
                memcpy(destino + linha * passo,
                       cru.baseAddress!.advanced(by: base + linha * largura), largura)
            }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let passo = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let destino = uv.assumingMemoryBound(to: UInt8.self)
            let origemUV = base + largura * altura
            for linha in 0..<(altura / 2) {
                memcpy(destino + linha * passo,
                       cru.baseAddress!.advanced(by: origemUV + linha * largura), largura)
            }
        }
    }
    return pb
}

let encoder: H264Encoder
do {
    encoder = try H264Encoder(width: Int32(largura), height: Int32(altura), fps: fps,
                              preset: o.preset)
} catch {
    FileHandle.standardError.write("o encoder não subiu: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let h264 = URL(fileURLWithPath: o.saida + ".h264")
let sidecar = URL(fileURLWithPath: o.saida + ".json")
FileManager.default.createFile(atPath: h264.path, contents: nil)
guard let saida = try? FileHandle(forWritingTo: h264) else {
    FileHandle.standardError.write("não consegui abrir \(h264.path)\n".data(using: .utf8)!)
    exit(1)
}

struct QuadroDoSidecar: Encodable {
    let number: Int
    let timestamp_us: Int
    let bytes: Int
    let idr: Bool
}

let trava = NSLock()
var quadrosDoSidecar: [QuadroDoSidecar] = []
var recebidos = 0

// **Ordem de entrega, e por que ela é assumida aqui e verificada depois.** O `H264Encoder` é
// configurado com `AllowFrameReordering = false`, então o VideoToolbox entrega na ordem de
// apresentação. O sidecar exige `timestamp_us` estritamente crescente, e a conferência abaixo
// falha em vez de escrever um sidecar torto se essa premissa cair.
for n in 0..<totalDeQuadros {
    guard let pb = quadro(n) else { continue }
    encoder.encode(
        pixelBuffer: pb,
        presentationTimeStamp: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)),
        duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
        // Só o primeiro é forçado: o resto do GOP é o que o preset do produto decide, e é isso
        // que se quer medir.
        forcarIDR: n == 0
    ) { dados, pts, idr in
        trava.lock()
        defer { trava.unlock() }
        let numero = quadrosDoSidecar.count
        saida.write(dados)
        quadrosDoSidecar.append(QuadroDoSidecar(
            number: numero,
            timestamp_us: Int((Double(pts.value) / Double(pts.timescale)) * 1_000_000.0),
            bytes: dados.count,
            idr: idr))
        recebidos += 1
    }
}
encoder.finish()
try? saida.close()

trava.lock()
let quadros = quadrosDoSidecar
trava.unlock()

guard !quadros.isEmpty else {
    FileHandle.standardError.write("o encoder não entregou quadro nenhum\n".data(using: .utf8)!)
    exit(1)
}
guard quadros[0].idr else {
    FileHandle.standardError.write(
        "o primeiro quadro não é IDR e o contrato exige que seja\n".data(using: .utf8)!)
    exit(1)
}
for k in 1..<quadros.count where quadros[k].timestamp_us <= quadros[k - 1].timestamp_us {
    FileHandle.standardError.write("""
    carimbo não crescente entre os quadros \(k - 1) e \(k) (\(quadros[k - 1].timestamp_us) ->
    \(quadros[k].timestamp_us)). O encoder reordenou, e o contrato do sidecar não admite isso.

    """.data(using: .utf8)!)
    exit(1)
}

let soma = quadros.reduce(0) { $0 + $1.bytes }
let noDisco = (try? FileManager.default.attributesOfItem(atPath: h264.path)[.size] as? Int) ?? 0
guard soma == noDisco else {
    FileHandle.standardError.write(
        "a soma dos quadros (\(soma)) não bate com o arquivo (\(noDisco))\n"
            .data(using: .utf8)!)
    exit(1)
}

struct Cabecalho: Encodable {
    let width: Int
    let height: Int
    let target_fps: Int
    let preset: String
    let capture_api: String
    let encoder: String
    let encoder_is_hardware: Bool
    let target_bitrate_bps: Int
    let gop_frames: Int
    let color_range: String
    let video_file: String
}
struct Documento: Encodable {
    let header: Cabecalho
    let frames: [QuadroDoSidecar]
}

let doc = Documento(
    header: Cabecalho(
        width: largura, height: altura, target_fps: Int(fps),
        preset: o.preset == .camera ? "camera" : "screen",
        capture_api: "nenhuma — origem sintética crua (NV12) lida de arquivo",
        encoder: encoder.encoderName,
        encoder_is_hardware: encoder.backend == .hardware,
        target_bitrate_bps: encoder.targetBitrateBps,
        gop_frames: encoder.gopFrames,
        color_range: "limited",
        video_file: h264.lastPathComponent),
    frames: quadros)

let codificador = JSONEncoder()
codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
try? codificador.encode(doc).write(to: sidecar)

let idrs = quadros.filter { $0.idr }.count
print("""
sonda-qualidade
  origem      : \(o.entrada) (\(totalDeQuadros) quadros NV12 \(largura)x\(altura), sintética)
  encoder     : \(encoder.encoderName) (\(encoder.backend.rawValue))
  taxa alvo   : \(encoder.targetBitrateBps) bps   GOP: \(encoder.gopFrames) quadros
  SPS         : \(encoder.resumoDoSPS)
  saída       : \(h264.path) (\(soma) B, \(quadros.count) quadros, \(idrs) IDR)
                \(sidecar.path)
""")
if quadros.count != totalDeQuadros {
    print("  ATENÇÃO    : entraram \(totalDeQuadros) quadros e saíram \(quadros.count). "
          + "O encoder descartou \(totalDeQuadros - quadros.count).")
}
