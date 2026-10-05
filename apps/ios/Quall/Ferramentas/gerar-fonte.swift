// Gera o par `.h264` + `.json` do `docs/contrato-sidecar.md` a partir de um padrão **sintético**,
// no MacBook, com o VideoToolbox.
//
// # Por que isto existe, e por que ele não captura nada
//
// Para provar o receptor do iPad é preciso um emissor mandando H.264 **decodificável de verdade**.
// As duas fontes que já existiam não servem:
//
// - `quall-net-smoke` manda bytes fabricados com cabeçalho de NAL plausível e carga de lixo. Ele
//   prova a fronteira C e o transporte, e diz isso na própria documentação. Nenhum decodificador
//   monta imagem com aquilo.
// - `quall-capture` captura a **tela ou a câmera deste Mac**. É a origem de vídeo do usuário. A
//   regra desta bancada é medir por contador e não guardar artefato de imagem sem necessidade;
//   gravar um `.h264` de 40 s da tela do usuário para depois apagá-lo é necessidade que dá para
//   não ter.
//
// O padrão daqui não é foto de nada: fundo que muda de tom, um quadrado que anda, e uma **régua de
// blocos** no topo que carrega o número do quadro em luma. A régua é o que permite ao receptor
// dizer "o pixel que decodifiquei é o pixel que foi mandado" **por contador**, sem guardar imagem
// nenhuma — a mesma ideia da `Faixa` do receptor de câmera do macOS, com um alfabeto menor porque
// aqui ela atravessa um encoder com perda.
//
// # A régua, e por que ela sobrevive ao H.264
//
// O número do quadro entra módulo `Marca.modulo` em quatro blocos de 64x64 no canto superior
// esquerdo, cada um com um dígito na base 4 (16 níveis usados, 4 por bloco). Blocos grandes e
// chapados: um bloco de 64x64 de luma constante é o caso mais fácil que existe para um encoder de
// vídeo, e os níveis são espaçados de 40 em 40 justamente para que a quantização não confunda dois
// deles. O receptor lê a média do miolo de cada bloco (evitando a borda, onde o filtro de
// desbloqueio mexe) e reconstrói o número.
//
// Uso:
//   swiftc -O gerar-fonte.swift -o /tmp/gerar-fonte
//   /tmp/gerar-fonte --saida /tmp/fonte --quadros 900 --largura 720 --altura 1280 --fps 30

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// ---------------------------------------------------------------------------------------------
// A régua de blocos. **Este bloco é copiado, byte a byte, em `apps/ios/Receptor/Comum/Marca.swift`.**
// Duas cópias porque os dois lados não compartilham alvo de compilação (um é um script de
// linha de comando do macOS, o outro é um app iOS), e uma divergência entre elas apareceria como
// "o receptor decodifica mas a marca nunca bate" — que aponta para o decodificador, e não para
// aqui. O teste do roteiro confere as duas.
// ---------------------------------------------------------------------------------------------
enum Marca {
    /// Quantos blocos, e portanto quantos dígitos base 4.
    static let digitos = 4
    /// 4^4 = 256 valores distintos. A 30 fps a régua dá a volta em 8,5 s — folgado para uma
    /// corrida de 40 s, porque o que se compara é sempre o quadro que acabou de chegar.
    static let modulo = 256
    /// Lado de cada bloco, em pixels do quadro codificado.
    static let lado = 64
    /// Luma do dígito `d` (0..3). Espaçamento de 40 é o que sobrevive à quantização: mesmo com
    /// erro de ±15 níveis os quatro valores continuam separáveis.
    static func luma(digito: Int) -> UInt8 { UInt8(40 + digito * 50) }
    /// O dígito mais próximo de uma luma lida. Devolve `nil` se nenhum estiver a menos de 20.
    static func digito(luma: Int) -> Int? {
        var melhor = -1
        var erro = 21
        for d in 0..<4 {
            let e = abs(luma - Int(Marca.luma(digito: d)))
            if e < erro { erro = e; melhor = d }
        }
        return melhor >= 0 ? melhor : nil
    }
}

// ---------------------------------------------------------------------------------------------

struct Opcoes {
    var saida = "/tmp/fonte"
    var quadros = 900
    var largura = 720
    var altura = 1280
    var fps = 30
    var gop = 30
    var bitrate = 4_000_000
    /// Porcentagem da altura do quadro coberta por **agitação**: ruído que muda a cada quadro e
    /// não comprime. `0` (o padrão) mantém o padrão histórico desta bancada, byte a byte.
    ///
    /// ## Por que isto existe, e não é enfeite
    ///
    /// Medido em 2026-08-31, lado a lado, com a mesma regra de pacotizador:
    ///
    /// | | esta fonte (agitação 0) | tela real do Dell em uso |
    /// |---|---|---|
    /// | quadro não-IDR **máximo** | 11 324 B = **11 pacotes** | 94 225 B = **84 pacotes** |
    /// | IDR, p50 | 3 352 B = **3 pacotes** | 64 784 B = **60 pacotes** |
    /// | quadros na faixa de 40 a 79 pacotes | **0** | **55** de 749 |
    ///
    /// O penhasco de perda desta LAN foi medido **entre 40 e 80 pacotes** por rajada (rajada de 40
    /// perde 0,025 %; de 80 perde 30,8 %). O maior quadro que esta fonte já produziu tem **11**
    /// pacotes — um quarto da borda de baixo do penhasco. **Nenhuma medição de perda desta bancada
    /// chegou perto da faixa que importa**, e o instrumento que protegia a privacidade (padrão
    /// sintético em vez de tela real) é o mesmo que mantinha o quadro pequeno.
    ///
    /// `--agitacao` fecha essa lacuna sem olhar um pixel da tela de ninguém: a origem continua
    /// sendo nossa, a régua de blocos continua legível por cima, e o quadro passa a ter o tamanho
    /// de um quadro de tela real com movimento. É o melhor dos dois mundos que
    /// `docs/regras-de-frente.md` pede — quadro grande e origem provadamente nossa.
    var agitacao = 0
}

func parse(_ args: [String]) -> Opcoes {
    var o = Opcoes()
    var i = 0
    while i < args.count {
        let chave = args[i]
        let valor = i + 1 < args.count ? args[i + 1] : ""
        switch chave {
        case "--saida": o.saida = valor; i += 2
        case "--quadros": o.quadros = Int(valor) ?? o.quadros; i += 2
        case "--largura": o.largura = Int(valor) ?? o.largura; i += 2
        case "--altura": o.altura = Int(valor) ?? o.altura; i += 2
        case "--fps": o.fps = Int(valor) ?? o.fps; i += 2
        case "--gop": o.gop = Int(valor) ?? o.gop; i += 2
        case "--bitrate": o.bitrate = Int(valor) ?? o.bitrate; i += 2
        case "--agitacao", "--agitação": o.agitacao = max(0, min(100, Int(valor) ?? 0)); i += 2
        default: i += 1
        }
    }
    return o
}

let op = parse(Array(CommandLine.arguments.dropFirst()))

// --- o quadro sintético ----------------------------------------------------------------------

/// Desenha o quadro `n` num `CVPixelBuffer` 420v (faixa limitada — o padrão do projeto, fixado em
/// `docs/contrato-sidecar.md`).
func desenhar(_ buffer: CVPixelBuffer, quadro n: Int, largura: Int, altura: Int,
              agitacao: Int = 0) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
    let yPasso = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let cPasso = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    let y = yBase.assumingMemoryBound(to: UInt8.self)
    let c = cBase.assumingMemoryBound(to: UInt8.self)

    // Fundo: um gradiente que anda, para que o encoder tenha o que codificar e o P-frame não seja
    // vazio. Faixa limitada: luma entre 16 e 235.
    let deslocamento = (n * 3) % 220
    for linha in 0..<altura {
        let base = y + linha * yPasso
        let tom = UInt8(16 + ((linha / 8 + deslocamento) % 220))
        memset(base, Int32(tom), largura)
    }
    // Croma: 128/128 é cinza. Um empurrão lento no Cb para a imagem não ser cinza puro e o
    // caminho de croma ser exercitado de verdade.
    let cb = UInt8(clamping: 128 + Int(sin(Double(n) / 20.0) * 40))
    for linha in 0..<(altura / 2) {
        let base = c + linha * cPasso
        for x in stride(from: 0, to: largura, by: 2) {
            base[x] = cb
            base[x + 1] = 128
        }
    }

    // **Agitação**: uma faixa de ruído que muda inteira a cada quadro. Não comprime, então o
    // P-frame fica do tamanho de um quadro de tela real com movimento — que é a faixa de 40 a 80
    // pacotes onde o penhasco da LAN mora e onde esta bancada nunca mediu nada. Ver `Opcoes`.
    //
    // O gerador é um xorshift semeado pelo número do quadro: a fonte continua **determinística**,
    // então duas corridas com os mesmos argumentos mandam exatamente os mesmos bytes e o sidecar
    // vale para as duas. Ruído com relógio dentro seria irreproduzível, que é o oposto do que uma
    // fonte de bancada tem de ser.
    if agitacao > 0 {
        let linhas = min(altura, altura * agitacao / 100)
        var estado = UInt32(truncatingIfNeeded: n &* 2_654_435_761) | 1
        for linha in 0..<linhas {
            let base = y + linha * yPasso
            var x = 0
            while x < largura {
                estado ^= estado << 13; estado ^= estado >> 17; estado ^= estado << 5
                var v = estado
                var k = 0
                while k < 4 && x < largura {
                    // Faixa limitada: 16 a 235, como o resto do quadro.
                    base[x] = UInt8(16 + Int(v & 0xFF) * 219 / 255)
                    v >>= 8; x += 1; k += 1
                }
            }
        }
    }

    // O quadrado que anda: prova de movimento, e é o que a pessoa vê se olhar para o iPad.
    let lado = 120
    let cx = Int((sin(Double(n) / 25.0) * 0.5 + 0.5) * Double(largura - lado))
    let cy = Int((cos(Double(n) / 17.0) * 0.5 + 0.5) * Double(altura - lado))
    for linha in cy..<(cy + lado) {
        memset(y + linha * yPasso + cx, 235, lado)
    }

    // A régua de blocos, no canto superior esquerdo, **por cima de tudo**.
    var resto = n % Marca.modulo
    for d in 0..<Marca.digitos {
        let digito = resto % 4
        resto /= 4
        let tom = Marca.luma(digito: digito)
        let x0 = d * Marca.lado
        for linha in 0..<Marca.lado {
            memset(y + linha * yPasso + x0, Int32(tom), Marca.lado)
        }
    }
}

// --- o encoder -------------------------------------------------------------------------------

final class Coletor {
    var annexb = Data()
    var quadros: [[String: Any]] = []
    var erro: OSStatus = noErr
    let inicio = mach_absolute_time()
}
let coletor = Coletor()

var relogio = mach_timebase_info_data_t()
mach_timebase_info(&relogio)
func agoraUs() -> UInt64 {
    let t = mach_absolute_time()
    return t &* UInt64(relogio.numer) / UInt64(relogio.denom) / 1000
}

func annexbDe(_ amostra: CMSampleBuffer) -> (Data, Bool)? {
    guard let bloco = CMSampleBufferGetDataBuffer(amostra) else { return nil }
    var total = 0
    var ponteiro: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(bloco, atOffset: 0, lengthAtOffsetOut: nil,
                                      totalLengthOut: &total, dataPointerOut: &ponteiro) == noErr,
          let ponteiro else { return nil }

    var chave = true
    if let anexos = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: false) as? [[CFString: Any]],
       let primeiro = anexos.first {
        chave = !((primeiro[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    let start: [UInt8] = [0, 0, 0, 1]
    var saida = Data()

    // Todo IDR leva SPS e PPS junto — exigência do contrato, e é o que permite ao receptor que
    // entra no meio da sessão montar a primeira imagem.
    if chave, let formato = CMSampleBufferGetFormatDescription(amostra) {
        var quantos = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formato, parameterSetIndex: 0,
                                                           parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil,
                                                           parameterSetCountOut: &quantos,
                                                           nalUnitHeaderLengthOut: nil)
        for i in 0..<quantos {
            var p: UnsafePointer<UInt8>?
            var tamanho = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formato, parameterSetIndex: i,
                                                                  parameterSetPointerOut: &p,
                                                                  parameterSetSizeOut: &tamanho,
                                                                  parameterSetCountOut: nil,
                                                                  nalUnitHeaderLengthOut: nil) == noErr,
               let p {
                saida.append(contentsOf: start)
                saida.append(p, count: tamanho)
            }
        }
    }

    // AVCC -> Annex-B: o prefixo de tamanho de 4 bytes vira start code.
    var i = 0
    ponteiro.withMemoryRebound(to: UInt8.self, capacity: total) { bytes in
        while i + 4 <= total {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            if n <= 0 || i + n > total { break }
            saida.append(contentsOf: start)
            saida.append(bytes + i, count: n)
            i += n
        }
    }
    return (saida, chave)
}

var sessao: VTCompressionSession?
let criou = VTCompressionSessionCreate(
    allocator: kCFAllocatorDefault,
    width: Int32(op.largura), height: Int32(op.altura),
    codecType: kCMVideoCodecType_H264,
    encoderSpecification: nil,
    imageBufferAttributes: nil,
    compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil,
    compressionSessionOut: &sessao)
guard criou == noErr, let sessao else {
    FileHandle.standardError.write("!! VTCompressionSessionCreate falhou: \(criou)\n".data(using: .utf8)!)
    exit(1)
}

VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_ProfileLevel,
                     value: kVTProfileLevel_H264_Baseline_AutoLevel)
VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                     value: NSNumber(value: op.gop))
VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_AverageBitRate,
                     value: NSNumber(value: op.bitrate))
VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                     value: NSNumber(value: op.fps))

var reserva: CVPixelBufferPool?
let atributos: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferWidthKey: op.largura,
    kCVPixelBufferHeightKey: op.altura,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
]
CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, atributos as CFDictionary, &reserva)
guard let reserva else {
    FileHandle.standardError.write("!! não consegui criar a reserva de pixel buffers\n".data(using: .utf8)!)
    exit(1)
}

let escala: Int32 = 1_000_000
var latencias: [UInt64] = []

for n in 0..<op.quadros {
    var pixel: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, reserva, &pixel)
    guard let pixel else { continue }
    desenhar(pixel, quadro: n, largura: op.largura, altura: op.altura, agitacao: op.agitacao)

    let carimbo = UInt64(n) * UInt64(1_000_000 / op.fps)
    let pts = CMTime(value: CMTimeValue(carimbo), timescale: escala)
    let duracao = CMTime(value: CMTimeValue(1_000_000 / op.fps), timescale: escala)
    let antes = agoraUs()

    var bandeiras = VTEncodeInfoFlags()
    VTCompressionSessionEncodeFrame(
        sessao, imageBuffer: pixel, presentationTimeStamp: pts, duration: duracao,
        frameProperties: nil, infoFlagsOut: &bandeiras
    ) { estado, _, amostra in
        guard estado == noErr, let amostra, let (dados, chave) = annexbDe(amostra) else {
            coletor.erro = estado
            return
        }
        let custo = agoraUs() - antes
        latencias.append(custo)
        coletor.quadros.append([
            "number": coletor.quadros.count,
            "timestamp_us": Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(amostra)) * 1_000_000),
            "bytes": dados.count,
            "idr": chave,
            "encode_latency_us": Int(custo),
        ])
        coletor.annexb.append(dados)
    }
}
VTCompressionSessionCompleteFrames(sessao, untilPresentationTimeStamp: .invalid)
VTCompressionSessionInvalidate(sessao)

guard !coletor.quadros.isEmpty else {
    FileHandle.standardError.write("!! nenhum quadro saiu do encoder (erro \(coletor.erro))\n".data(using: .utf8)!)
    exit(1)
}
// O contrato exige que o primeiro quadro do sidecar seja IDR; `quall-probe` recusa o arquivo se
// não for, e recusar cedo é melhor que mandar lixo pela rede.
guard (coletor.quadros[0]["idr"] as? Bool) == true else {
    FileHandle.standardError.write("!! o primeiro quadro não saiu IDR\n".data(using: .utf8)!)
    exit(1)
}

let nomeVideo = (op.saida as NSString).lastPathComponent + ".h264"
let cabecalho: [String: Any] = [
    "width": op.largura,
    "height": op.altura,
    "target_fps": op.fps,
    "preset": "screen",
    "capture_api": "sintético (gerar-fonte.swift, sem captura)",
    "encoder": "VideoToolbox H.264 (VTCompressionSession)",
    "encoder_is_hardware": true,
    "target_bitrate_bps": op.bitrate,
    "gop_frames": op.gop,
    "color_range": "limited",
    "video_file": nomeVideo,
]
let sidecar: [String: Any] = ["header": cabecalho, "frames": coletor.quadros]

do {
    try coletor.annexb.write(to: URL(fileURLWithPath: op.saida + ".h264"))
    let json = try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
    try json.write(to: URL(fileURLWithPath: op.saida + ".json"))
} catch {
    FileHandle.standardError.write("!! não deu para gravar: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let idrs = coletor.quadros.filter { ($0["idr"] as? Bool) == true }.count
let ordenadas = latencias.sorted()
print("gerado: \(op.saida).h264 (\(coletor.annexb.count) bytes) + \(op.saida).json")
print("  quadros: \(coletor.quadros.count) (\(idrs) IDR), \(op.largura)x\(op.altura) @ \(op.fps) fps, GOP \(op.gop)")
print("  encode : p50=\(ordenadas[ordenadas.count / 2])us max=\(ordenadas.last ?? 0)us")
print("  marca  : \(Marca.digitos) blocos de \(Marca.lado)px, módulo \(Marca.modulo)")
