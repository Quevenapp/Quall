// Que **nível de H.264** o emissor do macOS produz de verdade, por resolução.
//
// Existe por uma pergunta de uma linha que decidiu uma frente inteira: o SDP do núcleo anuncia
// `profile-level-id=42e028` — Constrained Baseline, **nível 4.0**, que comporta até 1920x1080 —
// e o `H264Encoder` pede `kVTProfileLevel_H264_Baseline_AutoLevel`, deixando o VideoToolbox
// escolher o nível a partir da resolução. Se o emissor codifica na resolução nativa de uma tela
// grande, o nível que sai no SPS pode passar muito do que foi prometido no SDP.
//
// **A regra da casa é conferir no artefato, não no retorno da API.** Por isso esta sonda não lê
// propriedade nenhuma da sessão: ela encoda de verdade, pega o Annex-B que sairia na rede, acha
// o SPS e lê os bytes. É o mesmo `H264Encoder` do produto — não uma cópia das configurações,
// que poderia divergir sem ninguém notar.
//
// A origem é **sintética** (um gradiente desenhado aqui). Nada da tela de ninguém entra nesta
// medição, e é por isso que ela pode rodar sem toque humano.
//
//   swift run sonda-sps
//   swift run sonda-sps 2560 1664

import CoreVideo
import Foundation
import QuallCaptureKit
import CoreMedia

/// Um quadro sintético em 4:2:0, com um gradiente que muda com o número do quadro — conteúdo o
/// bastante para o encoder não degenerar num quadro vazio.
func quadroSintetico(largura: Int, altura: Int, n: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let atributos: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    guard CVPixelBufferCreate(kCFAllocatorDefault, largura, altura,
                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              atributos as CFDictionary, &pb) == kCVReturnSuccess,
          let pb else { return nil }

    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
        let passo = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let bytes = y.assumingMemoryBound(to: UInt8.self)
        for linha in 0..<altura {
            for coluna in 0..<largura {
                bytes[linha * passo + coluna] = UInt8((coluna &+ linha &+ n &* 7) & 0xFF)
            }
        }
    }
    if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
        let passo = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let bytes = uv.assumingMemoryBound(to: UInt8.self)
        for linha in 0..<(altura / 2) {
            for coluna in 0..<largura {
                bytes[linha * passo + coluna] = 128
            }
        }
    }
    return pb
}

/// Percorre um Annex-B e devolve o primeiro NAL de um dado tipo. Aceita start code de 3 e de 4
/// bytes, porque os dois aparecem no mesmo fluxo.
func acharNal(_ d: Data, tipo: UInt8) -> Data? {
    let b = [UInt8](d)
    var i = 0
    var inicio = -1
    var tipoAtual: UInt8 = 0
    while i + 3 < b.count {
        var tamanhoDoPrefixo = 0
        if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 { tamanhoDoPrefixo = 3 }
        else if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 1 { tamanhoDoPrefixo = 4 }
        if tamanhoDoPrefixo > 0 {
            if inicio >= 0 && tipoAtual == tipo {
                return Data(b[inicio..<i])
            }
            let cabecalho = i + tamanhoDoPrefixo
            guard cabecalho < b.count else { break }
            tipoAtual = b[cabecalho] & 0x1F
            inicio = cabecalho
            i = cabecalho + 1
            continue
        }
        i += 1
    }
    if inicio >= 0 && tipoAtual == tipo { return Data(b[inicio...]) }
    return nil
}

/// O nome do nível, que é o que a pessoa lê. `level_idc` é o nível vezes dez.
func nomeDoNivel(_ v: UInt8) -> String {
    // 30 -> "3.0". O caso especial 1b (nível 1b) não aparece em tela grande e fica de fora.
    String(format: "%d.%d", v / 10, v % 10)
}

let args = CommandLine.arguments

/// As telas desta bancada, uma por casca, com o que cada emissor mandava antes do teto.
let bancada: [(Int32, Int32, Int32, String)] = [
    (1280, 720, 30, "o que o emissor iOS manda: 720p30"),
    (1280, 720, 60, "o mesmo tamanho, no fps antigo do macOS — isola o fps"),
    (720, 1520, 30, "a tela do A10s: alongada, e emitia em nível 3.2"),
    (750, 1334, 30, "a tela do iPhone 7"),
    (1920, 1080, 60, "monitor externo comum — o caso do Dell"),
    (2560, 1664, 60, "a tela deste MacBook Air, nativa"),
]

var medidas: [(Int32, Int32, Int32, String)] = []
if args.count >= 4, let l = Int32(args[1]), let a = Int32(args[2]), let f = Int32(args[3]) {
    medidas = [(l, a, f, "pedida na linha de comando")]
} else {
    // **Antes e depois, no mesmo instrumento e na mesma corrida.** Medir o "antes" numa build e o
    // "depois" noutra foi como esta casa produziu a afirmação "só o nível muda" que era falsa em
    // cinco variáveis (`docs/tela-preta.md` §8.2). Aqui as duas linhas saem do mesmo binário, do
    // mesmo encoder e do mesmo minuto — o que muda entre elas é só o teto.
    for (l, a, f, porque) in bancada {
        medidas.append((l, a, f, "ANTES — \(porque)"))
        let t = TetoDoEmissor.ajustar(largura: Int(l), altura: Int(a), fps: f)
        if t.largura == Int(l) && t.altura == Int(a) && t.fps == f {
            medidas.append((l, a, f, "DEPOIS — o teto não teve o que limitar"))
        } else {
            medidas.append((Int32(t.largura), Int32(t.altura), t.fps,
                            "DEPOIS — \(t.macroblocos)/\(TetoDoEmissor.maxFS) macroblocos"
                            + (t.exigeRecorte ? ", com frame_cropping" : "")))
        }
    }
}

print("")
print("o que o SDP promete ao outro lado:")
print("  profile-level-id=42e028  ->  Constrained Baseline, nível 4.0 (teto 1920x1080)")
print("")
print("o que o H264Encoder do macOS produz, medido no Annex-B que sairia na rede:")
print("")

var houveExcesso = false

for (largura, altura, fps, porque) in medidas {
    do {
        let encoder = try H264Encoder(width: largura, height: altura, fps: fps, preset: .screen)
        let pronto = DispatchSemaphore(value: 0)
        let caixa = NSLock()
        var sps: Data?

        // Alguns quadros: o primeiro já traz SPS/PPS, mas o encoder pode demorar a entregar.
        for n in 0..<4 {
            guard let pb = quadroSintetico(largura: Int(largura), altura: Int(altura), n: n) else {
                continue
            }
            encoder.encode(pixelBuffer: pb,
                           presentationTimeStamp: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)),
                           duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                           forcarIDR: n == 0) { dados, _, _ in
                caixa.lock()
                if sps == nil, let achado = acharNal(dados, tipo: 7) {
                    sps = achado
                    pronto.signal()
                }
                caixa.unlock()
            }
        }

        _ = pronto.wait(timeout: .now() + 5)
        caixa.lock(); let achado = sps; caixa.unlock()

        guard let s = achado, s.count >= 4 else {
            print("  \(largura)x\(altura) @\(fps)fps — nenhum SPS saiu em 5 s  (\(porque))")
            continue
        }
        let b = [UInt8](s)
        let profile = b[1]
        let nivel = b[3]
        let excede = nivel > 31
        // Só o "depois" conta para o veredito. As linhas "ANTES" existem justamente para
        // exceder — são o defeito, medido ao lado do conserto e no mesmo minuto.
        if excede && !porque.hasPrefix("ANTES") { houveExcesso = true }
        print(String(format: "  %4dx%-5d @%2dfps  profile_idc=%-3d level_idc=%-3d (nível %@)  %@",
                     largura, altura, Int(fps), Int(profile), Int(nivel), nomeDoNivel(nivel),
                     excede ? "*** ACIMA DO 3.1 ANUNCIADO ***" : "cabe no anunciado"))
        print("               \(porque)")
        // O SPS cru, para que **outro** analisador possa conferir a dimensão e o
        // `frame_cropping` — quem confere não pode ser o mesmo código que escreve. É a mesma
        // regra que fez `tools/ler-sps.py` ser escrito em Python, independente do `RemendoDeSPS`:
        //
        //     tools/ler-sps.py --hex <estes bytes>
        //
        // Importa aqui porque o teto quase nunca cai em múltiplo de 16, e a dimensão real do
        // quadro passa a depender do recorte declarado. Este projeto já quase reprovou uma
        // corrida **por ela estar certa** quando o iPhone X decodificou em 590x1280.
        print("               sps=\(s.map { String(format: "%02x", $0) }.joined())")
    } catch {
        print("  \(largura)x\(altura) @\(fps)fps — o encoder não subiu: \(error)")
    }
}

print("")
if houveExcesso {
    print("VEREDITO: o emissor do macOS produz SPS acima do nível que o SDP anunciou.")
    print("          O receptor recebe um fluxo que não foi o combinado na negociação.")
} else {
    print("VEREDITO: todo nível medido cabe no 3.1 anunciado. A hipótese do nível morre aqui.")
}
print("")
