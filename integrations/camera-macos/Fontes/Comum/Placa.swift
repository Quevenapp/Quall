import CoreVideo
import Foundation

/// Desenha a placa de teste e a placa de espera **direto nos planos NV12**, sem CoreGraphics.
///
/// Duas razões para não usar CoreGraphics aqui, e as duas são de plataforma, não de gosto:
///
/// 1. O formato publicado é `420v` (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`), que é o
///    que o decoder de H.264 do VideoToolbox entrega. Desenhar em BGRA e converter acrescentaria
///    exatamente a conversão que o caminho de produto não tem.
/// 2. **Faixa limitada, BT.709 é o padrão do projeto.** Escrevendo o plano de luma na mão, o
///    branco é 235 e o preto é 16 por construção — não por uma conversão que talvez respeite a
///    faixa. A lição do iOS (o `imageBufferAttributes` só converte quando há reescala) é
///    justamente que conversão implícita é onde a faixa se perde em silêncio.
enum Placa {
    /// Fonte de 5x7 para os dígitos, um bit por pixel, bit mais significativo à esquerda.
    private static let digitos: [[UInt8]] = [
        [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],  // 0
        [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],  // 1
        [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],  // 2
        [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110],  // 3
        [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],  // 4
        [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],  // 5
        [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],  // 6
        [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],  // 7
        [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],  // 8
        [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],  // 9
    ]

    /// Fonte de 5x7 para as letras maiúsculas e três sinais. Existe pelo mesmo motivo da fonte de
    /// dígitos: a placa de espera precisa **dizer ao usuário o que fazer**, e o único jeito de
    /// escrever texto sem arrastar CoreGraphics (e a conversão de faixa que vem com ele) para
    /// dentro de uma extensão de 202 KB é desenhar os glifos na mão, no plano de luma.
    ///
    /// Só maiúsculas e sem acento, de propósito: as frases da placa foram escolhidas para caberem
    /// nesse alfabeto (`ABRA O APP QUALL NO MAC`), em vez de o alfabeto crescer para caber numa
    /// frase.
    private static let letras: [Character: [UInt8]] = [
        "A": [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        "B": [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
        "C": [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],
        "D": [0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100],
        "E": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
        "F": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],
        "G": [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111],
        "H": [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        "I": [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        "J": [0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100],
        "K": [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001],
        "L": [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111],
        "M": [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001],
        "N": [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001],
        "O": [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        "P": [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
        "Q": [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101],
        "R": [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001],
        "S": [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
        "T": [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
        "U": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        "V": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100],
        "W": [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001],
        "X": [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001],
        "Y": [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100],
        "Z": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111],
        " ": [0, 0, 0, 0, 0, 0, 0],
        ".": [0, 0, 0, 0, 0, 0b01100, 0b01100],
        "-": [0, 0, 0, 0b11111, 0, 0, 0],
        ":": [0, 0b01100, 0b01100, 0, 0b01100, 0b01100, 0],
    ]

    /// Luma de branco e de preto na **faixa limitada**. Não são 255 e 0, e é esse o ponto.
    static let brancoLimitado: UInt8 = 235
    static let pretoLimitado: UInt8 = 16

    /// Placa de teste: fundo em rampa, barra que varre e o número do quadro em dígitos grandes.
    ///
    /// O número existe para a testemunha externa: uma captura da janela do app de terceiro mostra
    /// um número legível, e dois quadros com números diferentes provam movimento — coisa que
    /// "a câmera aparece na lista" não prova.
    static func desenharPlacaDeTeste(numero: Int, em buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let largura = CVPixelBufferGetWidth(buffer)
        let altura = CVPixelBufferGetHeight(buffer)
        guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let passoY = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let passoC = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let planoY = y.assumingMemoryBound(to: UInt8.self)
        let planoC = c.assumingMemoryBound(to: UInt8.self)

        // Rampa vertical de luma, sempre dentro de 16..235.
        for linha in 0..<altura {
            let valor = UInt8(16 + (219 * linha) / max(1, altura - 1))
            memset(planoY + linha * passoY, Int32(valor), largura)
        }

        // Barra vertical que varre a tela: é o movimento que um olho vê sem ler número nenhum.
        let posicao = (numero * 11) % max(1, largura - 40)
        for linha in 0..<altura {
            memset(planoY + linha * passoY + posicao, Int32(brancoLimitado), 40)
        }

        // Croma: gira devagar, para a imagem não parecer congelada em cinza.
        let fase = Double(numero) * 0.05
        let cb = UInt8(clamping: Int(128 + 60 * cos(fase)))
        let cr = UInt8(clamping: Int(128 + 60 * sin(fase)))
        for linha in 0..<(altura / 2) {
            let base = planoC + linha * passoC
            for coluna in stride(from: 0, to: largura, by: 2) {
                base[coluna] = cb
                base[coluna + 1] = cr
            }
        }

        escrever(numero: numero, casas: 6, escala: 12, x: 60, y: 60,
                 planoY: planoY, passoY: passoY, largura: largura, altura: altura)
    }

    /// Placa de espera: cinza neutro e **a instrução do que fazer**. É o que o Zoom vê quando não
    /// há aparelho entregando quadro — inclusive depois de o app anfitrião fechar.
    ///
    /// Ela não pode ser só um fundo cinza. Quem está numa chamada e vê a fonte parar precisa saber
    /// se o problema é dele, e o único canal que a extensão tem para dizer isso é a própria
    /// imagem: ela não tem janela, não tem notificação e não tem como falar com o app. Por isso a
    /// placa **escreve** o que fazer, em vez de piscar um ponto que só diz "estou viva".
    static func desenharEspera(em buffer: CVPixelBuffer, marca: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let largura = CVPixelBufferGetWidth(buffer)
        let altura = CVPixelBufferGetHeight(buffer)
        guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let passoY = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let passoC = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let planoY = y.assumingMemoryBound(to: UInt8.self)
        let planoC = c.assumingMemoryBound(to: UInt8.self)

        for linha in 0..<altura {
            memset(planoY + linha * passoY, 40, largura)
        }
        for linha in 0..<(altura / 2) {
            memset(planoC + linha * passoC, 128, largura)
        }

        // As três linhas são medidas em relação à altura, não fixas: a placa é desenhada na
        // dimensão publicada hoje (1920x1080), mas nada aqui quebra se ela mudar.
        let escalaTitulo = max(1, altura / 90)      // 8 em 720p → letras de 40x56
        let escalaTexto = max(1, altura / 180)      // 4 em 720p → letras de 20x28
        centralizar("QUALL", escala: escalaTitulo, y: altura / 2 - 5 * escalaTitulo,
                    brilho: brancoLimitado, planoY: planoY, passoY: passoY,
                    largura: largura, altura: altura)
        centralizar("SEM SINAL - ABRA O APP QUALL", escala: escalaTexto,
                    y: altura / 2 + 4 * escalaTitulo, brilho: 170,
                    planoY: planoY, passoY: passoY, largura: largura, altura: altura)
        centralizar("E CONECTE AO APARELHO", escala: escalaTexto,
                    y: altura / 2 + 4 * escalaTitulo + 12 * escalaTexto, brilho: 170,
                    planoY: planoY, passoY: passoY, largura: largura, altura: altura)

        // O ponto que pisca continua, e agora tem função diferente do texto: o texto diz o que
        // fazer, o ponto diz que a extensão **ainda está correndo** — uma imagem congelada com a
        // mesma frase seria indistinguível de uma câmera travada.
        if (marca / 15) % 2 == 0 {
            for linha in (altura - 40)..<(altura - 20) {
                memset(planoY + linha * passoY + largura - 40, Int32(brancoLimitado), 20)
            }
        }
    }

    /// Escreve um texto centralizado na largura, no plano de luma.
    static func centralizar(_ texto: String, escala: Int, y: Int, brilho: UInt8,
                            planoY: UnsafeMutablePointer<UInt8>, passoY: Int,
                            largura: Int, altura: Int) {
        let larguraDoGlifo = 6 * escala
        let total = texto.count * larguraDoGlifo - escala
        let x = max(0, (largura - total) / 2)
        escrever(texto, escala: escala, x: x, y: y, brilho: brilho,
                 planoY: planoY, passoY: passoY, largura: largura, altura: altura)
    }

    /// Escreve um texto a partir de `x`, no plano de luma. Caractere fora da fonte vira espaço.
    static func escrever(_ texto: String, escala: Int, x: Int, y: Int, brilho: UInt8,
                         planoY: UnsafeMutablePointer<UInt8>, passoY: Int,
                         largura: Int, altura: Int) {
        for (indice, caractere) in texto.enumerated() {
            let mapa: [UInt8]
            if let letra = letras[caractere] {
                mapa = letra
            } else if let d = caractere.wholeNumberValue, d >= 0, d <= 9 {
                mapa = digitos[d]
            } else {
                continue
            }
            let origemX = x + indice * 6 * escala
            for (linhaDoMapa, bits) in mapa.enumerated() {
                for coluna in 0..<5 where (bits >> (4 - coluna)) & 1 == 1 {
                    for dy in 0..<escala {
                        let py = y + linhaDoMapa * escala + dy
                        guard py >= 0, py < altura else { continue }
                        let px = origemX + coluna * escala
                        guard px >= 0, px + escala <= largura else { continue }
                        memset(planoY + py * passoY + px, Int32(brilho), escala)
                    }
                }
            }
        }
    }

    private static func escrever(numero: Int, casas: Int, escala: Int, x: Int, y: Int,
                                 planoY: UnsafeMutablePointer<UInt8>, passoY: Int,
                                 largura: Int, altura: Int) {
        var valor = numero
        var digitosDoNumero = [Int](repeating: 0, count: casas)
        for i in stride(from: casas - 1, through: 0, by: -1) {
            digitosDoNumero[i] = valor % 10
            valor /= 10
        }
        let larguraDoDigito = 6 * escala  // 5 colunas + 1 de espaço
        for (indice, digito) in digitosDoNumero.enumerated() {
            let mapa = digitos[digito]
            let origemX = x + indice * larguraDoDigito
            for (linhaDoMapa, bits) in mapa.enumerated() {
                for coluna in 0..<5 where (bits >> (4 - coluna)) & 1 == 1 {
                    for dy in 0..<escala {
                        let py = y + linhaDoMapa * escala + dy
                        guard py >= 0, py < altura else { continue }
                        let px = origemX + coluna * escala
                        guard px >= 0, px + escala <= largura else { continue }
                        memset(planoY + py * passoY + px, Int32(brancoLimitado), escala)
                    }
                }
            }
        }
    }
}
