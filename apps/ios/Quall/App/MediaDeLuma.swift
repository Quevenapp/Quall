import Foundation
import CoreVideo

/// **A média de luma em contador** (`docs/controles-de-camera.md` §5, prova 2): o brilho médio do
/// quadro, para a prova ver EV, ISO e obturador mexerem **no fluxo** — e não só no retorno da API
/// (`regras-de-frente.md`, "Verifique no fluxo"). Soma o plano Y **subamostrado** do `CVPixelBuffer`
/// que o `captureOutput` já recebe: nenhum quadro é salvo, copiado nem aberto. As câmeras de verdade
/// filmam a sala ("Um vídeo de bancada pode conter a vida do usuário"), e um número é tudo o que sai.
///
/// Só roda com a bandeira de bancada `luma_media` (`--luma-media`), num quadro a cada 30. O código
/// vai no app, mas sem a bandeira (que só vale com o diagnóstico ligado, o padrão do Debug) nada
/// aqui é chamado. Testado e cronometrado no MacBook por `Testes/rodar.sh` sobre um buffer 420v de
/// 1920x1080.
enum MediaDeLuma {
    /// De quantos em quantos pixels, nos dois eixos. 8 dá 240 × 135 = 32.400 leituras num quadro de
    /// 1080p — o bastante para uma média estável, e 64 vezes menos que o plano inteiro.
    static let passo = 8

    /// A média do plano Y (0–255, na faixa que o buffer tiver: 16–235 em `420v`), ou `nil` se o
    /// buffer não tem plano de luma legível. Só leitura: `lockBaseAddress(.readOnly)`.
    static func media(_ imagem: CVPixelBuffer, passo: Int = MediaDeLuma.passo) -> Double? {
        guard passo > 0 else { return nil }
        let planar = CVPixelBufferIsPlanar(imagem)
        guard CVPixelBufferLockBaseAddress(imagem, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(imagem, .readOnly) }
        let base = planar ? CVPixelBufferGetBaseAddressOfPlane(imagem, 0) : CVPixelBufferGetBaseAddress(imagem)
        guard let base else { return nil }
        let largura = planar ? CVPixelBufferGetWidthOfPlane(imagem, 0) : CVPixelBufferGetWidth(imagem)
        let altura = planar ? CVPixelBufferGetHeightOfPlane(imagem, 0) : CVPixelBufferGetHeight(imagem)
        let linha = planar ? CVPixelBufferGetBytesPerRowOfPlane(imagem, 0) : CVPixelBufferGetBytesPerRow(imagem)
        // Só os formatos biplanares de 8 bits (420v/420f) têm luma no plano 0 byte a byte; o resto
        // (BGRA, 10 bits) não é o que a captura pede, e um número errado seria pior que nenhum.
        let tipo = CVPixelBufferGetPixelFormatType(imagem)
        guard tipo == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || tipo == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }
        guard largura > 0, altura > 0 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var soma = 0
        var n = 0
        var y = passo / 2
        while y < altura {
            let fileira = p + y * linha
            var x = passo / 2
            while x < largura {
                soma &+= Int(fileira[x])
                n &+= 1
                x &+= passo
            }
            y &+= passo
        }
        return n > 0 ? Double(soma) / Double(n) : nil
    }
}
