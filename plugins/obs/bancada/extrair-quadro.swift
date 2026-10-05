// Extrai um quadro de um vídeo e grava PNG, usando AVFoundation.
//
// Quem decodifica aqui é a Apple, sobre um arquivo que quem escreveu foi o **OBS**. Nenhum código
// nosso participa da leitura: é o mais perto de uma testemunha externa que esta bancada tem sem
// `ffmpeg` instalado.
//
//   swift extrair-quadro.swift entrada.mp4 saida.png [segundos]

import AVFoundation
import CoreImage
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("uso: extrair-quadro.swift entrada.mp4 saida.png [segundos]\n".data(using: .utf8)!)
    exit(2)
}
let entrada = URL(fileURLWithPath: args[1])
let saida = URL(fileURLWithPath: args[2])
let segundos = args.count > 3 ? Double(args[3]) ?? 5.0 : 5.0

let ativo = AVURLAsset(url: entrada)
let gerador = AVAssetImageGenerator(asset: ativo)
gerador.appliesPreferredTrackTransform = true
// Sem tolerância: o quadro entregue é o do instante pedido, não o quadro-chave mais próximo.
gerador.requestedTimeToleranceBefore = .zero
gerador.requestedTimeToleranceAfter = .zero

do {
    let imagem = try gerador.copyCGImage(at: CMTime(seconds: segundos, preferredTimescale: 600), actualTime: nil)
    let ci = CIImage(cgImage: imagem)
    let contexto = CIContext()
    try contexto.writePNGRepresentation(of: ci, to: saida, format: .RGBA8,
                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("quadro de \(segundos)s: \(imagem.width)x\(imagem.height) -> \(saida.path)")
} catch {
    FileHandle.standardError.write("falhou: \(error)\n".data(using: .utf8)!)
    exit(1)
}
