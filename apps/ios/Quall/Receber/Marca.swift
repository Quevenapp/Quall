import CoreVideo
import Foundation

/// A régua de blocos que o gerador de fonte desenha no canto superior esquerdo, lida de volta do
/// quadro **decodificado**.
///
/// # Por que ela existe
///
/// "O iPad exibiu vídeo" é uma afirmação sobre pixels, e um contador de quadros não a sustenta: um
/// decodificador pode entregar 1200 buffers cinza e todos os contadores fecharem. A alternativa
/// óbvia — tirar um retrato da tela — guarda artefato de imagem, e a regra da bancada é medir por
/// contador.
///
/// A régua resolve os dois: o emissor escreve o número do quadro em quatro blocos chapados de
/// 64x64, e o receptor lê a média do miolo de cada bloco e reconstrói o número. Se ele bate com um
/// quadro plausível, os pixels que saíram do decodificador são os pixels que entraram no encoder —
/// e isso é um **contador**, não uma imagem.
///
/// # A cópia, e por que ela é assumida
///
/// Os valores abaixo são idênticos aos de `apps/ios/Receptor/Ferramentas/gerar-fonte.swift`. Os
/// dois lados não compartilham alvo de compilação (um é script de linha de comando do macOS, o
/// outro é app iOS), e não vale um pacote Swift só para quatro constantes. O risco da cópia é
/// real: uma divergência apareceria como "decodifica mas a marca nunca bate", que aponta para o
/// decodificador. `provar-receptor.sh` compara os dois arquivos como parte da corrida.
enum Marca {
    static let digitos = 4
    static let modulo = 256
    static let lado = 64

    static func luma(digito: Int) -> UInt8 { UInt8(40 + digito * 50) }

    static func digito(luma: Int) -> Int? {
        var melhor = -1
        var erro = 21
        for d in 0..<4 {
            let e = abs(luma - Int(Marca.luma(digito: d)))
            if e < erro { erro = e; melhor = d }
        }
        return melhor >= 0 ? melhor : nil
    }

    /// Lê a régua de um `CVPixelBuffer` decodificado. `nil` quando o quadro não a carrega — o que
    /// é o caso normal quando a origem não é o gerador desta frente, e por isso não é erro.
    ///
    /// Lê só o **miolo** de cada bloco (a metade central), porque a borda é onde o filtro de
    /// desbloqueio do H.264 mistura o bloco com o vizinho. Com a metade central, o valor lido fica
    /// a poucos níveis do que foi escrito mesmo a 4 Mbps.
    static func ler(de imagem: CVPixelBuffer) -> Int? {
        let largura = CVPixelBufferGetWidth(imagem)
        let altura = CVPixelBufferGetHeight(imagem)
        guard largura >= digitos * lado, altura >= lado else { return nil }

        CVPixelBufferLockBaseAddress(imagem, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imagem, .readOnly) }

        // Plano 0 de um buffer bi-planar 420v/420f é a luma. Um buffer de plano único não é o que
        // o VideoToolbox entrega aqui, e ler o plano 0 dele daria um número sem sentido: melhor
        // devolver `nil`.
        guard CVPixelBufferGetPlaneCount(imagem) >= 2,
              let base = CVPixelBufferGetBaseAddressOfPlane(imagem, 0) else { return nil }
        let passo = CVPixelBufferGetBytesPerRowOfPlane(imagem, 0)
        let y = base.assumingMemoryBound(to: UInt8.self)

        var valor = 0
        var peso = 1
        let borda = lado / 4
        for d in 0..<digitos {
            var soma = 0
            var quantos = 0
            for linha in borda..<(lado - borda) {
                let linhaBase = y + linha * passo + d * lado
                for x in borda..<(lado - borda) {
                    soma += Int(linhaBase[x])
                    quantos += 1
                }
            }
            guard quantos > 0, let digito = Marca.digito(luma: soma / quantos) else { return nil }
            valor += digito * peso
            peso *= 4
        }
        return valor
    }
}
