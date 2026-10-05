// A testemunha T3 do som (S5 do `docs/som-no-receptor.md`, §9.4): a claquete lida **na gravação
// do próprio OBS**.
//
// Quem escreveu o arquivo foi o OBS — o compositor, o mixador de áudio, o encoder e o muxer dele — e
// quem o lê aqui é o AVFoundation. Nenhum código do Quall participa da leitura. O que este programa
// faz é contar:
//
// - **a imagem**: em cada quadro do vídeo, a régua de blocos da origem sintética (o índice do
//   quadro em base 4, `Marca.swift`), lida no miolo de cada bloco da luma;
// - **o som**: o começo de cada estouro de 3 150 Hz, por um Goertzel numa janela de Hann de 2 ms com
//   passo de 1 ms, os mesmos limiares e o mesmo viés do `DetectorDeEstouro` do Mac;
// - **a verdade** vem da sonda (`claquete.json`): para cada evento, o índice da régua do quadro
//   marcado e onde o estouro está em relação a ele.
//
// Para cada evento casado, **Δ = t_som − t_imagem − verdade**, as duas horas na linha do tempo da
// própria gravação: positivo é som atrasado em relação à imagem da mesma captura. E o controle 1: a
// classe de +40 ms menos a classe de 0 tem de dar 40.
//
// **Onde está a régua**: a origem de 1280x720 enche o canvas a partir do canto de cima à esquerda
// (`montar-cena.py montar --encher`); na gravação, o bloco tem `64 × largura / 1280` pixels.
//
//     swift ler-claquete-da-gravacao.swift gravacao.mp4 claquete.json [--json saida.json]
//
// Com `-` no lugar do `claquete.json` (uma sessão só de som, sem claquete), só diz o que a
// gravação tem: a duração e o pico do som.

import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("uso: ler-claquete-da-gravacao.swift gravacao.mp4 claquete.json [--json saida.json] [--janela DE ATE]\n".data(using: .utf8)!)
    exit(2)
}
let urlDaGravacao = URL(fileURLWithPath: args[1])
let urlDaVerdade = URL(fileURLWithPath: args[2])
let saidaJson = args.firstIndex(of: "--json").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
// `--janela DE ATE` (s da gravação): só a régua que aparece nesse trecho. É para a corrida com a sonda
// religada: as duas sessões têm a mesma claquete (a mesma semente) e a mesma régua, e sem a janela a
// âncora da primeira sessão caía na segunda, que é mais longa (`r16-pcmu-religada`: 13 de 17 casados,
// com Δ de 72 a 300 ms).
let janela: (de: Double, ate: Double)? = args.firstIndex(of: "--janela").flatMap { i in
    i + 2 < args.count ? (Double(args[i + 1]) ?? 0, Double(args[i + 2]) ?? .infinity) : nil
}

func falhar(_ texto: String) -> Never {
    FileHandle.standardError.write("ler-claquete: \(texto)\n".data(using: .utf8)!)
    exit(1)
}

// --- a régua (os valores de `Marca.swift` e do gerador) -------------------------------------------
let digitos = 4
func luma(digito: Int) -> Int { 40 + digito * 50 }
func digito(luma l: Int) -> Int? {
    var melhor = -1, erro = 21
    for d in 0..<4 {
        let e = abs(l - luma(digito: d))
        if e < erro { erro = e; melhor = d }
    }
    return melhor >= 0 ? melhor : nil
}

func lerRegua(_ imagem: CVPixelBuffer, lado: Int) -> Int? {
    CVPixelBufferLockBaseAddress(imagem, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(imagem, .readOnly) }
    guard CVPixelBufferGetPlaneCount(imagem) >= 2,
          let base = CVPixelBufferGetBaseAddressOfPlane(imagem, 0) else { return nil }
    let largura = CVPixelBufferGetWidthOfPlane(imagem, 0)
    let altura = CVPixelBufferGetHeightOfPlane(imagem, 0)
    guard largura >= digitos * lado, altura >= lado else { return nil }
    let passo = CVPixelBufferGetBytesPerRowOfPlane(imagem, 0)
    let y = base.assumingMemoryBound(to: UInt8.self)
    var valor = 0, peso = 1
    let borda = lado / 4
    for d in 0..<digitos {
        var soma = 0, quantos = 0
        for linha in borda..<(lado - borda) {
            let linhaBase = y + linha * passo + d * lado
            for x in borda..<(lado - borda) {
                soma += Int(linhaBase[x])
                quantos += 1
            }
        }
        guard quantos > 0, let dd = digito(luma: soma / quantos) else { return nil }
        valor += dd * peso
        peso *= 4
    }
    return valor
}

// --- o detector do estouro (o do Mac, `DetectorDeEstouro`) ----------------------------------------
struct Detector {
    let taxa: Double
    let janela: Int
    let passo: Int
    let pesos: [Float]
    let somaDosPesos: Float
    let coef: Float
    let limiarAlto: Float = 0.12
    let limiarBaixo: Float = 0.05
    let viesEmPassos = 0.81
    var ativo = false
    var abaixoHa = 20
    var amostras: [Float] = []
    var inicioGlobal = 0 // índice global da amostra 0 de `amostras`

    init(taxa: Double) {
        self.taxa = taxa
        janela = Int(taxa * 0.002)
        passo = Int(taxa * 0.001)
        var p = [Float](), s: Float = 0
        for i in 0..<janela {
            let w = Float(0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(janela - 1)))
            p.append(w); s += w
        }
        pesos = p; somaDosPesos = s
        coef = Float(2 * cos(2 * .pi * 3150.0 / taxa))
    }

    func amplitude(_ p: Int) -> Float {
        var s1: Float = 0, s2: Float = 0
        for i in 0..<janela {
            let s0 = amostras[p + i] * pesos[i] + coef * s1 - s2
            s2 = s1; s1 = s0
        }
        return 2 * sqrt(max(s1 * s1 + s2 * s2 - coef * s1 * s2, 0)) / somaDosPesos
    }

    /// Acrescenta amostras (mono) e devolve os começos achados, em índice global de amostra.
    mutating func processar(_ x: [Float]) -> [Double] {
        amostras.append(contentsOf: x)
        var achados: [Double] = []
        var p = 0
        while p + janela <= amostras.count {
            let a = amplitude(p)
            if ativo {
                if a < limiarBaixo { abaixoHa += 1 } else { abaixoHa = 0 }
                if abaixoHa >= 20 { ativo = false }
            } else if a > limiarAlto {
                if abaixoHa >= 20 {
                    achados.append(Double(inicioGlobal + p) + viesEmPassos * Double(passo))
                }
                ativo = true
                abaixoHa = 0
            } else if a < limiarBaixo {
                abaixoHa += 1
            }
            p += passo
        }
        amostras.removeFirst(p)
        inicioGlobal += p
        return achados
    }
}

// --- ler a gravação --------------------------------------------------------------------------------
let ativo = AVURLAsset(url: urlDaGravacao)
let sem = DispatchSemaphore(value: 0)
var trilhasDeVideo: [AVAssetTrack] = [], trilhasDeSom: [AVAssetTrack] = []
Task {
    trilhasDeVideo = (try? await ativo.loadTracks(withMediaType: .video)) ?? []
    trilhasDeSom = (try? await ativo.loadTracks(withMediaType: .audio)) ?? []
    sem.signal()
}
sem.wait()
guard let trilhaDeVideo = trilhasDeVideo.first else { falhar("a gravação não tem vídeo") }
guard let trilhaDeSom = trilhasDeSom.first else { falhar("a gravação não tem som") }

func inicioDaTrilha(_ t: AVAssetTrack) -> Double {
    var r = 0.0
    let s = DispatchSemaphore(value: 0)
    Task {
        if let intervalo = try? await t.load(.timeRange) { r = intervalo.start.seconds }
        s.signal()
    }
    s.wait()
    return r
}

guard let leitor = try? AVAssetReader(asset: ativo) else { falhar("AVAssetReader não abriu") }
let saidaDeVideo = AVAssetReaderTrackOutput(track: trilhaDeVideo, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
])
let taxaDoSom = 48_000.0
let saidaDeSom = AVAssetReaderTrackOutput(track: trilhaDeSom, outputSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: false,
    AVLinearPCMIsBigEndianKey: false,
    AVSampleRateKey: taxaDoSom,
    AVNumberOfChannelsKey: 1,
])
saidaDeVideo.alwaysCopiesSampleData = false
leitor.add(saidaDeVideo)
leitor.add(saidaDeSom)
guard leitor.startReading() else { falhar("a leitura não começou: \(String(describing: leitor.error))") }

var imagens: [(r: Int, t: Double)] = [] // o índice da régua e o pts do quadro, em segundos
var quadrosLidos = 0, quadrosComRegua = 0
var largura = 0
var estouros: [Double] = [] // pts do começo de cada estouro, em segundos
var detector = Detector(taxa: taxaDoSom)
var primeiraAmostraDeSom: Double?
var amostrasDeSom = 0
var picoDoSom: Float = 0

// Os dois leitores precisam andar juntos: o AVAssetReader intercala as trilhas, e ler uma até o fim
// antes da outra pode travar a outra. Alterna um de cada.
var fimDoVideo = false, fimDoSom = false
while !fimDoVideo || !fimDoSom {
    if !fimDoVideo {
        if let amostra = saidaDeVideo.copyNextSampleBuffer() {
            if let imagem = CMSampleBufferGetImageBuffer(amostra) {
                quadrosLidos += 1
                if largura == 0 { largura = CVPixelBufferGetWidth(imagem) }
                let lado = Int((64.0 * Double(largura) / 1280.0).rounded())
                if let r = lerRegua(imagem, lado: lado) {
                    quadrosComRegua += 1
                    imagens.append((r, CMSampleBufferGetPresentationTimeStamp(amostra).seconds))
                }
            }
        } else { fimDoVideo = true }
    }
    if !fimDoSom {
        if let amostra = saidaDeSom.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(amostra).seconds
            if primeiraAmostraDeSom == nil { primeiraAmostraDeSom = t }
            if let bloco = CMSampleBufferGetDataBuffer(amostra) {
                let bytes = CMBlockBufferGetDataLength(bloco)
                var dados = [Float](repeating: 0, count: bytes / 4)
                dados.withUnsafeMutableBytes { p in
                    _ = CMBlockBufferCopyDataBytes(bloco, atOffset: 0, dataLength: bytes, destination: p.baseAddress!)
                }
                for v in dados { picoDoSom = max(picoDoSom, abs(v)) }
                amostrasDeSom += dados.count
                // O índice global de amostra conta desde a primeira: a hora de cada começo é a
                // primeira hora mais o índice sobre a taxa.
                for i in detector.processar(dados) {
                    estouros.append((primeiraAmostraDeSom ?? 0) + i / taxaDoSom)
                }
            }
        } else { fimDoSom = true }
    }
}
if leitor.status == .failed { falhar("a leitura falhou: \(String(describing: leitor.error))") }

// --- a verdade ----------------------------------------------------------------------------------------
if args[2] == "-" {
    print(String(format: "gravação: %d quadros de vídeo; %.1f s de som, pico %.3f (%.1f dBFS)",
                 quadrosLidos, Double(amostrasDeSom) / taxaDoSom, picoDoSom,
                 picoDoSom > 0 ? 20 * log10(Double(picoDoSom)) : -.infinity))
    exit(picoDoSom > 0.01 ? 0 : 1)
}
guard let dados = try? Data(contentsOf: urlDaVerdade),
      let raiz = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
      let eventos = raiz["eventos"] as? [[String: Any]] else { falhar("claquete.json ilegível") }

// A primeira aparição de cada índice: o quadro marcado aparece aí na saída do OBS.
var primeiras: [(r: Int, t: Double)] = []
var anterior: Int?
for (r, t) in imagens {
    if let j = janela, t < j.de || t > j.ate { anterior = nil; continue }
    if r != anterior { primeiras.append((r, t)) }
    anterior = r
}

// A âncora entre o carimbo da sonda e a linha do tempo da gravação: a régua volta a cada 256
// quadros (8,5 s), e cada evento tem um candidato por volta. Só o candidato certo repete a mesma
// constante em (quase) todos os eventos. **Janela deslizante de ±20 ms, e não caixas fixas**: a
// constante certa caiu na borda de duas caixas na primeira corrida (0,899 e 0,900 s), a moda foi
// para outra volta da régua, e só 19 de 46 eventos casaram.
var difs: [Double] = []
for e in eventos {
    guard let regua = e["regua"] as? Int, let carimbo = e["carimbo_video_us"] as? Double else { continue }
    for p in primeiras where p.r == regua { difs.append(p.t - carimbo / 1e6) }
}
var ancora = 0.0
var melhor = 0
for d in difs {
    let vizinhos = difs.filter { abs($0 - d) <= 0.020 }
    if vizinhos.count > melhor {
        melhor = vizinhos.count
        let o = vizinhos.sorted()
        ancora = o[o.count / 2]
    }
}

var medidas: [(desloc: Double, cru: Double, delta: Double, t: Double)] = []
for e in eventos {
    guard let regua = e["regua"] as? Int, let carimbo = e["carimbo_video_us"] as? Double,
          let verdade = e["verdade_us"] as? Double, let desloc = e["desloc_us"] as? Double else { continue }
    guard let h = primeiras.first(where: { $0.r == regua && abs($0.t - carimbo / 1e6 - ancora) < 0.040 })?.t
    else { continue }
    let alvo = h + verdade / 1e6
    guard let s = estouros.min(by: { abs($0 - alvo) < abs($1 - alvo) }), abs(s - alvo) < 0.340 else { continue }
    let fase = (verdade - desloc) / 1e6
    medidas.append((desloc, s - h - fase, s - h - verdade / 1e6, h))
}

func quantis(_ v: [Double]) -> [String: Double] {
    let o = v.sorted()
    func q(_ p: Double) -> Double { o[min(o.count - 1, Int(p * Double(o.count - 1) + 0.5))] }
    return o.isEmpty ? [:] : ["n": Double(o.count), "p05": q(0.05) * 1000, "p50": q(0.5) * 1000, "p95": q(0.95) * 1000]
}
let delta = quantis(medidas.map(\.delta))
let crus0 = medidas.filter { $0.desloc == 0 }.map(\.cru).sorted()
let crus40 = medidas.filter { $0.desloc == 40_000 }.map(\.cru).sorted()
let controle1: Double? = (crus0.isEmpty || crus40.isEmpty) ? nil
    : (crus40[crus40.count / 2] - crus0[crus0.count / 2]) * 1000

let inicioDoVideo = inicioDaTrilha(trilhaDeVideo), inicioDoSom = inicioDaTrilha(trilhaDeSom)
print(String(format: "gravação: %d quadros de vídeo (%d com a régua, %d px de largura); %.1f s de som, pico %.3f",
             quadrosLidos, quadrosComRegua, largura, Double(amostrasDeSom) / taxaDoSom, picoDoSom))
print(String(format: "trilhas: o vídeo começa em %.4f s, o som em %.4f s (primeira amostra lida em %.4f s)",
             inicioDoVideo, inicioDoSom, primeiraAmostraDeSom ?? -1))
print("claquete: \(eventos.count) evento(s) na verdade, \(estouros.count) estouro(s) achados, "
      + "\(primeiras.count) aparições de índice, \(medidas.count) casados")
if let n = delta["n"] {
    print(String(format: "T3 (a gravação do OBS) Δ ms por evento: [n=%.0f p05=%.1f p50=%.1f p95=%.1f]",
                 n, delta["p05"]!, delta["p50"]!, delta["p95"]!))
}
if let c = controle1 {
    print(String(format: "controle 1: classe +40 menos classe 0 = %.1f ms (n=%d e %d; tem de dar 40)",
                 c, crus40.count, crus0.count))
}
if let saidaJson {
    let r: [String: Any] = [
        "quadros": quadrosLidos, "quadros_com_regua": quadrosComRegua, "largura": largura,
        "segundos_de_som": Double(amostrasDeSom) / taxaDoSom, "pico_do_som": Double(picoDoSom),
        "inicio_do_video_s": inicioDoVideo, "inicio_do_som_s": inicioDoSom,
        "eventos": eventos.count, "estouros": estouros.count, "casados": medidas.count,
        "T3": delta, "controle1_ms": controle1 as Any,
        // Cada evento na ordem da gravação: [a hora do quadro marcado na gravação (s), o Δ (ms)]. Um
        // Δ que muda de patamar no meio da corrida (uma troca de tique) aparece aqui, e não nos quantis.
        "por_evento": medidas.sorted { $0.t < $1.t }.map { [$0.t, $0.delta * 1000] },
    ]
    if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: saidaJson))
    }
}
exit(medidas.isEmpty ? 1 : 0)
