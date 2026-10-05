// **Um decodificador de plataforma aceita uma unidade de acesso com fatias faltando?**
//
// A pergunta decide um eixo inteiro do projeto. `docs/idr-que-sobrevive.md` mediu que o enlace de
// 2,4 GHz **trunca a cauda** de uma rajada acima de ~35 pacotes e entrega a cabeça inteira: num
// IDR de 60 pacotes cortado em 40 chegam dois terços da imagem. Hoje o depacotizador
// (`crates/quall-core/src/rtp.rs`) chama `abortar()` e joga esses dois terços fora. Fatiar no
// emissor só paga se o decodificador do outro lado souber pintar a cabeça. Se nenhum aceitar
// unidade de acesso incompleta, **fatiar não tem para que servir**.
//
// Esta sonda responde nesta máquina, sem rede e sem aparelho:
//
//  1. codifica uma origem **sintética** com `kVTCompressionPropertyKey_MaxH264SliceBytes` abaixo
//     da MTU útil do projeto (`MAX_FRAGMENTO` = 1188 B);
//  2. **confere no artefato** quantas fatias saíram por unidade de acesso — conta NAL de tipo 1 e
//     5, não confia no retorno da API (`docs/quinta-porta.md`: cinco portas, três aceitas e
//     ignoradas);
//  3. trunca o IDR nas K primeiras fatias completas e alimenta um `VTDecompressionSession`;
//  4. diz se sai imagem, se sai imagem parcial, ou se ele recusa — e com qual `OSStatus`.
//
// **Nada de tela de ninguém entra aqui.** A origem é um mosaico gerado por gerador congruencial
// de semente fixa, denso de propósito: fundo liso comprime a quase nada e o IDR sairia com meia
// dúzia de pacotes, longe do regime que a pergunta cobre. Nenhum quadro é gravado, aberto ou
// convertido em imagem — o que sai do decodificador é medido por **contadores** (chegou buffer?
// de que tamanho? com que status?), nunca por pixel.
//
//   swift run sonda-fatias
//   swift run sonda-fatias 720 1520 900

import CoreMedia
import CoreVideo
import Foundation
import QuallCaptureKit
import VideoToolbox

// ------------------------------------------------------------------------------------------------
// Origem sintética densa
// ------------------------------------------------------------------------------------------------

/// Mosaico de blocos de 8x8 com cor pseudoaleatória de **semente fixa**, mais uma barra que anda
/// com o número do quadro.
///
/// Semente fixa é o que faz "antes" e "depois" serem a mesma origem — e denso é o que faz o IDR
/// nascer no porte da tela real em vez de comprimir a nada.
func quadroDenso(largura: Int, altura: Int, n: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let atributos: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    guard CVPixelBufferCreate(kCFAllocatorDefault, largura, altura,
                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              atributos as CFDictionary, &pb) == kCVReturnSuccess,
          let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    var semente: UInt64 = 0x5DEECE66D
    func proximo(_ teto: UInt64) -> UInt64 {
        semente = (semente &* 0x5DEECE66D &+ 0xB) & ((1 << 48) - 1)
        return (semente >> 16) % teto
    }

    let lado = 8
    if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        let passo = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let p = y.assumingMemoryBound(to: UInt8.self)
        var by = 0
        while by < altura {
            var bx = 0
            while bx < largura {
                let v = UInt8(16 + proximo(220))
                for dy in 0..<min(lado, altura - by) {
                    let linha = p + (by + dy) * passo + bx
                    memset(linha, Int32(v), min(lado, largura - bx))
                }
                bx += lado
            }
            by += lado
        }
        // Uma barra que anda: sem movimento nenhum o encoder degeneraria em quadros P vazios e a
        // comparação de bitrate não diria nada.
        let x0 = (n * 17) % max(1, largura - 40)
        for linha in 0..<altura {
            memset(p + linha * passo + x0, 235, 40)
        }
    }
    if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
        let passo = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        memset(uv, 128, passo * CVPixelBufferGetHeightOfPlane(buffer, 1))
    }
    return buffer
}

// ------------------------------------------------------------------------------------------------
// Leitura de NAL — deliberadamente própria, e não a do produto
// ------------------------------------------------------------------------------------------------

struct Nal {
    let tipo: UInt8
    /// Faixa do NAL **com** o start code na frente, para poder recortar o fluxo por fatia.
    let comPrefixo: Range<Int>
    let bytes: Int
}

/// Divide um Annex-B em NALs. Aceita prefixo de 3 e de 4 bytes.
func nals(_ d: Data) -> [Nal] {
    let b = [UInt8](d)
    var inicios: [(Int, Int)] = []   // (início do prefixo, início do cabeçalho)
    var i = 0
    while i + 3 <= b.count {
        if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
            inicios.append((i, i + 3))
            i += 3
        } else {
            i += 1
        }
    }
    var saida: [Nal] = []
    for (k, par) in inicios.enumerated() {
        var (prefixo, cabecalho) = par
        // Um prefixo de 4 bytes é um de 3 com um zero na frente; o zero é do prefixo.
        if prefixo > 0 && b[prefixo - 1] == 0 { prefixo -= 1 }
        let fim = k + 1 < inicios.count ? inicios[k + 1].0 : b.count
        var fimReal = fim
        if fimReal > cabecalho && fimReal > 0 && b[fimReal - 1] == 0 { fimReal -= 1 }
        guard cabecalho < b.count else { continue }
        saida.append(Nal(tipo: b[cabecalho] & 0x1F,
                         comPrefixo: prefixo..<fim,
                         bytes: max(0, fimReal - cabecalho)))
    }
    return saida
}

/// `first_mb_in_slice` — o primeiro campo do cabeçalho de fatia, um Exp-Golomb sem sinal. Zero
/// significa "primeira fatia de uma imagem nova", que é a fronteira de unidade de acesso.
func primeiroMacroblocoDaFatia(_ d: Data, cabecalho: Int) -> Int? {
    let b = [UInt8](d)
    guard cabecalho + 1 < b.count else { return nil }
    var bit = 0
    func u1() -> Int {
        let indice = cabecalho + 1 + (bit >> 3)
        guard indice < b.count else { return 0 }
        let v = Int((b[indice] >> (7 - UInt8(bit & 7))) & 1)
        bit += 1
        return v
    }
    var zeros = 0
    while u1() == 0 && zeros < 32 { zeros += 1 }
    if zeros >= 32 { return nil }
    var resto = 0
    for _ in 0..<zeros { resto = (resto << 1) | u1() }
    return (1 << zeros) - 1 + resto
}

let VCL: Set<UInt8> = [1, 2, 3, 4, 5]

// ------------------------------------------------------------------------------------------------
// A corrida
// ------------------------------------------------------------------------------------------------

var args = CommandLine.arguments
/// Annex-B externo para a parte 2. Existe porque o encoder de hardware desta máquina **recusa**
/// o limite de fatia (ver a parte 1): sem uma origem multifatia de outro codificador, a pergunta
/// sobre o **decodificador** ficaria sem resposta por culpa do encoder, que é outra pergunta.
var fluxoExterno: String? = nil
if let i = args.firstIndex(of: "--fluxo"), i + 1 < args.count {
    fluxoExterno = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let largura = args.count > 1 ? Int32(args[1]) ?? 720 : 720
let altura = args.count > 2 ? Int32(args[2]) ?? 1520 : 1520
// 900 B: bem abaixo de `MAX_FRAGMENTO` (1188), para que cada fatia caiba num pacote RTP só.
let limiteDeFatia = args.count > 3 ? Int32(args[3]) ?? 900 : 900
let fps: Int32 = 30
let quadros = 60

func corrida(limite: Int32, fatias: Int32 = 0)
    -> (fluxo: [Data], resposta: String, encoder: String) {
    let enc: H264Encoder
    do {
        enc = try H264Encoder(width: largura, height: altura, fps: fps,
                              preset: .screen, maxBytesPorFatia: limite,
                              fatiasPorQuadro: fatias)
    } catch {
        print("!! não consegui criar o encoder: \(error)")
        exit(1)
    }
    var fluxo: [Data] = []
    let trava = NSLock()
    for n in 0..<quadros {
        guard let pb = quadroDenso(largura: Int(largura), altura: Int(altura), n: n) else { continue }
        let pts = CMTime(value: CMTimeValue(n), timescale: fps)
        enc.encode(pixelBuffer: pb, presentationTimeStamp: pts,
                   duration: CMTime(value: 1, timescale: fps),
                   forcarIDR: n == 0) { dados, _, _ in
            trava.lock(); fluxo.append(dados); trava.unlock()
        }
    }
    enc.finish()
    return (fluxo, enc.respostaDoLimiteDeFatia, enc.encoderName)
}

/// Fatias por unidade de acesso, e o tamanho da maior — **lido do bitstream**.
func resumo(_ fluxo: [Data]) -> (fatiasPorAu: [Int], maiorFatia: Int, idrs: Int, bytes: Int) {
    var contagens: [Int] = []
    var maior = 0
    var idrs = 0
    var bytes = 0
    for au in fluxo {
        let lista = nals(au)
        let fatias = lista.filter { VCL.contains($0.tipo) }
        contagens.append(fatias.count)
        maior = max(maior, fatias.map(\.bytes).max() ?? 0)
        if lista.contains(where: { $0.tipo == 5 }) { idrs += 1 }
        bytes += au.count
    }
    return (contagens, maior, idrs, bytes)
}

print("== sonda-fatias — \(largura)x\(altura) a \(fps) fps, origem sintética densa, \(quadros) quadros")
print()

// ------------------------------------------------------------------------------------------------
// 0. A plataforma tem o botão? Perguntado direto à VTCompressionSession, hardware e software.
// ------------------------------------------------------------------------------------------------
/// `VTSessionSetProperty` numa sessão crua, sem o `H264Encoder` do produto no meio.
///
/// Separa duas perguntas que se confundem: *"a Apple oferece limite de fatia?"* e *"o encoder que
/// esta máquina escolheu oferece?"*. `-12900` é `kVTPropertyNotSupportedErr`.
func sondarLimiteDeFatia(exigirHardware: Bool) -> String {
    let espec: [CFString: Any] = exigirHardware
        ? [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
           kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false]
    var sessao: VTCompressionSession?
    let st = VTCompressionSessionCreate(
        allocator: nil, width: largura, height: altura, codecType: kCMVideoCodecType_H264,
        encoderSpecification: espec as CFDictionary, imageBufferAttributes: nil,
        compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &sessao)
    guard st == noErr, let sessao else { return "sessão não criou (status \(st))" }
    defer { VTCompressionSessionInvalidate(sessao) }
    var hw: CFTypeRef?
    VTSessionCopyProperty(sessao,
                          key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                          allocator: nil, valueOut: &hw)
    let ehHardware = (hw as? Bool) ?? false
    let stSet = VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_MaxH264SliceBytes,
                                     value: NSNumber(value: limiteDeFatia))
    var lista: CFDictionary?
    VTSessionCopySupportedPropertyDictionary(sessao, supportedPropertyDictionaryOut: &lista)
    let chaves = (lista as? [String: Any])?.keys.sorted() ?? []
    let suportadas = chaves.contains("MaxH264SliceBytes")
    // **Perguntar à sessão vale mais que grep em cabeçalho.** "Não achei a constante no SDK" é a
    // mesma classe de conclusão que `docs/regras-de-frente.md` derruba em "ausência de linha no
    // `log show` não é ausência de evento". Esta linha lista o que a sessão **diz** ter.
    let parecidas = chaves.filter {
        let n = $0.lowercased()
        return n.contains("slice") || n.contains("refresh") || n.contains("intra")
    }
    return "hardware=\(ehHardware) · set=\(stSet) · "
        + "consta na lista de propriedades suportadas: \(suportadas ? "sim" : "NÃO") · "
        + "\(chaves.count) propriedades no total, com slice/refresh/intra no nome: "
        + "\(parecidas.isEmpty ? "NENHUMA" : parecidas.joined(separator: ", "))"
}
print("-- 0. a plataforma oferece kVTCompressionPropertyKey_MaxH264SliceBytes?")
print("   exigindo hardware : \(sondarLimiteDeFatia(exigirHardware: true))")
print("   sem exigir        : \(sondarLimiteDeFatia(exigirHardware: false))")
print("   (-12900 = kVTPropertyNotSupportedErr)")
print()

let semLimite = corrida(limite: 0)
let comLimite = corrida(limite: limiteDeFatia)
// A propriedade privada que a sessão declara. Ver `H264Encoder`. A varredura existe para a
// pergunta 3 do briefing — **quanto custa** —, e o ponto que interessa é aquele em que a maior
// fatia cai abaixo de `MAX_FRAGMENTO` (1188 B), porque aí cada fatia cabe num pacote RTP.
let comFatias = corrida(limite: 0, fatias: 8)
let a = resumo(semLimite.fluxo)
let b = resumo(comLimite.fluxo)
let c = resumo(comFatias.fluxo)

print("encoder: \(semLimite.encoder)")
print("resposta da API ao limite de fatia: \(comLimite.resposta)")
print()
print("-- 1. o botão funcionou? (conferido no bitstream, não no retorno)")
func histograma(_ v: [Int]) -> String {
    var h: [Int: Int] = [:]
    for x in v { h[x, default: 0] += 1 }
    return h.sorted { $0.key < $1.key }.map { "\($0.key)x:\($0.value)" }.joined(separator: " ")
}
print("   sem limite : fatias/AU  \(histograma(a.fatiasPorAu))   maior fatia \(a.maiorFatia) B   "
      + "IDR \(a.idrs)   \(a.bytes) B")
print("   com \(limiteDeFatia) B  : fatias/AU  \(histograma(b.fatiasPorAu))   maior fatia \(b.maiorFatia) B   "
      + "IDR \(b.idrs)   \(b.bytes) B")
print("   NumberOfSlices=8 : fatias/AU  \(histograma(c.fatiasPorAu))   maior fatia \(c.maiorFatia) B   "
      + "IDR \(c.idrs)   \(c.bytes) B")
print("   resposta da API a NumberOfSlices: \(comFatias.resposta)")
print()
print("-- 1b. quanto custa fatiar (mesma origem, mesmos 60 quadros)")
/// Preenche à direita. `String(format:)` com `%s` espera um ponteiro C e derruba o processo com
/// uma `String` do Swift — foi o que aconteceu na primeira versão desta tabela (sinal 11).
func col(_ t: String, _ n: Int) -> String {
    t.count >= n ? t : t + String(repeating: " ", count: n - t.count)
}
print("   " + col("fatias", 8) + col("obtidas/AU", 12) + col("maior fatia", 14)
      + col("maior em pacotes", 18) + "bytes (custo)")
for n: Int32 in [0, 2, 4, 8, 16, 32, 40, 48, 64] {
    let r = resumo(corrida(limite: 0, fatias: n).fluxo)
    let obtidas = Set(r.fatiasPorAu).sorted().map(String.init).joined(separator: "/")
    // A mesma regra de `pacotes_do_nal` de `crates/quall-core/src/track.rs`.
    func pacotes(_ tam: Int) -> Int {
        if tam <= 1188 { return 1 }
        let k = (tam + 1187) / 1188
        let m = max(0, (tam + k - 1) / k - 2)
        return m == 0 ? k : (tam - 1 + m - 1) / m
    }
    let delta = Double(r.bytes - a.bytes) / Double(a.bytes) * 100
    let sinal = delta >= 0 ? "+" : ""
    print("   " + col(String(n), 8) + col(obtidas, 12)
          + col(String(r.maiorFatia), 14) + col(String(pacotes(r.maiorFatia)), 18)
          + "\(r.bytes) (\(sinal)\(String(format: "%.2f", delta)) %)")
}
let funcionou = max(b.fatiasPorAu.max() ?? 1, c.fatiasPorAu.max() ?? 1) > (a.fatiasPorAu.max() ?? 1)
print("   >>> \(funcionou ? "FUNCIONOU" : "ACEITO E IGNORADO — o bitstream não mudou")")
print()

// ------------------------------------------------------------------------------------------------
// 2. O decodificador aceita a cabeça sozinha?
// ------------------------------------------------------------------------------------------------

/// Recorta uma unidade de acesso nas `k` primeiras **fatias completas**, mantendo todos os NALs
/// não-VCL que vierem antes (SPS, PPS, SEI). É exatamente a forma `N+M−` que
/// `docs/idr-que-sobrevive.md` mediu no ar: a cabeça chega inteira, a cauda morre.
func truncar(_ au: Data, fatias k: Int) -> Data {
    let lista = nals(au)
    var saida = Data()
    var vistas = 0
    for n in lista {
        if VCL.contains(n.tipo) {
            if vistas >= k { break }
            vistas += 1
        }
        saida.append(au.subdata(in: n.comPrefixo))
    }
    return saida
}

/// Alimenta um `VTDecompressionSession` com uma unidade de acesso e devolve o que aconteceu.
///
/// O que se mede é **contador**: chegou buffer de imagem, de que tamanho, com que `OSStatus`.
/// Nenhum pixel é lido, gravado ou convertido.
func decodificar(idrCompleto: Data, unidades: [Data]) -> [String] {
    let lista = nals(idrCompleto)
    guard let sps = lista.first(where: { $0.tipo == 7 }),
          let pps = lista.first(where: { $0.tipo == 8 }) else {
        return ["!! o IDR não trouxe SPS/PPS — não dá para montar o formato"]
    }
    func semPrefixo(_ n: Nal) -> [UInt8] {
        let d = idrCompleto.subdata(in: n.comPrefixo)
        let b = [UInt8](d)
        // Pula o start code (3 ou 4 bytes).
        var i = 0
        while i + 2 < b.count && !(b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) { i += 1 }
        return Array(b[(i + 3)...])
    }
    let spsB = semPrefixo(sps), ppsB = semPrefixo(pps)
    var formato: CMFormatDescription?
    let st = spsB.withUnsafeBufferPointer { sp in
        ppsB.withUnsafeBufferPointer { pp -> OSStatus in
            let ponteiros: [UnsafePointer<UInt8>] = [sp.baseAddress!, pp.baseAddress!]
            let tamanhos: [Int] = [spsB.count, ppsB.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: 2,
                parameterSetPointers: ponteiros, parameterSetSizes: tamanhos,
                nalUnitHeaderLength: 4, formatDescriptionOut: &formato)
        }
    }
    guard st == noErr, let fmt = formato else {
        return ["!! CMVideoFormatDescriptionCreateFromH264ParameterSets falhou: \(st)"]
    }

    var sessao: VTDecompressionSession?
    let stSessao = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault, formatDescription: fmt,
        decoderSpecification: nil,
        imageBufferAttributes: nil,
        outputCallback: nil, decompressionSessionOut: &sessao)
    guard stSessao == noErr, let sessao else {
        return ["!! VTDecompressionSessionCreate falhou: \(stSessao)"]
    }
    defer { VTDecompressionSessionInvalidate(sessao) }

    var linhas: [String] = []
    for (indice, au) in unidades.enumerated() {
        // Annex-B -> AVCC: o `CMSampleBuffer` quer comprimento de 4 bytes na frente de cada NAL,
        // e os NALs de parâmetro ficam de fora (já estão na format description).
        var avcc = Data()
        for n in nals(au) where !(n.tipo == 7 || n.tipo == 8) {
            let d = au.subdata(in: n.comPrefixo)
            let b = [UInt8](d)
            var i = 0
            while i + 2 < b.count && !(b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) { i += 1 }
            var corpo = Array(b[(i + 3)...])
            // Zeros de `trailing_zero_8bits` pertencem ao Annex-B, não ao NAL: em AVCC eles
            // entrariam no comprimento declarado e virariam bytes de fatia que não existem.
            while corpo.count > 1 && corpo.last == 0 { corpo.removeLast() }
            var tam = UInt32(corpo.count).bigEndian
            withUnsafeBytes(of: &tam) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: corpo)
        }
        var blockBuffer: CMBlockBuffer?
        var bytes = [UInt8](avcc)
        let stBloco = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: &bytes, blockLength: bytes.count,
            blockAllocator: kCFAllocatorNull, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &blockBuffer)
        guard stBloco == noErr, let bloco = blockBuffer else {
            linhas.append("   [\(indice)] CMBlockBufferCreate falhou: \(stBloco)")
            continue
        }
        var amostra: CMSampleBuffer?
        var tamanhos = [bytes.count]
        let stAmostra = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bloco, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &tamanhos, sampleBufferOut: &amostra)
        guard stAmostra == noErr, let amostra else {
            linhas.append("   [\(indice)] CMSampleBufferCreateReady falhou: \(stAmostra)")
            continue
        }
        var saiuImagem = false
        var larguraSaida = 0, alturaSaida = 0
        var statusDoQuadro: OSStatus = noErr
        var infoFlags = VTDecodeInfoFlags()
        let stDecode = VTDecompressionSessionDecodeFrame(
            sessao, sampleBuffer: amostra,
            flags: [._EnableTemporalProcessing],
            infoFlagsOut: &infoFlags
        ) { status, _, imagem, _, _ in
            statusDoQuadro = status
            if let imagem {
                saiuImagem = true
                larguraSaida = CVPixelBufferGetWidth(imagem)
                alturaSaida = CVPixelBufferGetHeight(imagem)
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(sessao)
        linhas.append("   [\(indice)] DecodeFrame=\(stDecode) callback=\(statusDoQuadro) "
                      + "imagem=\(saiuImagem ? "SIM \(larguraSaida)x\(alturaSaida)" : "não")")
    }
    return linhas
}

print("-- 2. o VTDecompressionSession aceita unidade de acesso truncada?")
/// Quando o encoder desta máquina recusa fatiar, a origem multifatia vem de fora (`--fluxo`).
/// A pergunta da parte 2 é sobre o **decodificador**: de que codificador vieram os bytes não
/// muda a resposta, e recusá-la por causa do encoder seria trocar uma pergunta pela outra.
func unidadesDoArquivo(_ caminho: String) -> [Data] {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: caminho)) else { return [] }
    var saida: [Data] = []
    var atual = Data()
    var temFatia = false
    for n in nals(d) {
        let pedaco = d.subdata(in: n.comPrefixo)
        if VCL.contains(n.tipo) {
            // `cabecalho` é o índice do **byte de cabeçalho do NAL** (o primeiro depois do start
            // code), porque é de onde `primeiroMacroblocoDaFatia` começa a ler o bit seguinte.
            let lb = n.comPrefixo.lowerBound
            let tamanhoDoPrefixo = (lb + 2 < d.count && d[lb + 2] == 1) ? 3 : 4
            let primeira = primeiroMacroblocoDaFatia(d, cabecalho: lb + tamanhoDoPrefixo) == 0
            if temFatia && primeira {
                saida.append(atual); atual = Data(); temFatia = false
            }
            temFatia = true
        }
        atual.append(pedaco)
    }
    if !atual.isEmpty { saida.append(atual) }
    return saida
}

var fonteDoIdr = comLimite.fluxo
if let caminho = fluxoExterno {
    let us = unidadesDoArquivo(caminho)
    print("   origem externa: \(caminho) — \(us.count) unidades de acesso")
    fonteDoIdr = us
}
if (c.fatiasPorAu.max() ?? 1) > 1 { fonteDoIdr = comFatias.fluxo }
guard let idr = fonteDoIdr.first(where: { nals($0).contains { $0.tipo == 5 } }) else {
    print("   !! não achei IDR no fluxo")
    exit(1)
}
let fatiasDoIdr = nals(idr).filter { VCL.contains($0.tipo) }.count
print("   o IDR fatiado tem \(fatiasDoIdr) fatias; truncando em 1, na metade, e em todas menos uma")
let cortes = Array(Set([1, max(1, fatiasDoIdr / 2), max(1, fatiasDoIdr - 1), fatiasDoIdr]))
    .sorted()
for k in cortes {
    let truncado = truncar(idr, fatias: k)
    let rotulo = k == fatiasDoIdr ? "\(k)/\(fatiasDoIdr) (completo)" : "\(k)/\(fatiasDoIdr)"
    print("   corte em \(rotulo) — \(truncado.count) B:")
    for l in decodificar(idrCompleto: idr, unidades: [truncado]) { print("  \(l)") }
}
print()
print("Leitura: `imagem=SIM` num corte menor que o total significa que o decodificador da Apple")
print("pinta a cabeça de uma unidade de acesso truncada, e que fatiar tem para que servir.")
print("`imagem=não` em todos os cortes parciais significa o contrário, e fecha o caminho.")
