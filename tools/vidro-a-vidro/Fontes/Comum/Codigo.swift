import CoreVideo
import Foundation

/// O cronômetro que viaja **dentro dos pixels**.
///
/// Grade de 6 x 4 células sobre a área útil da janela. O índice do quadro vai em **código de
/// Gray** de 16 bits, não em contador binário: valores consecutivos de um contador binário
/// diferem em até 16 células, e qualquer regra de descarte por leitura suja removeria
/// preferencialmente as amostras que mudam mais — que são justamente as lentas. Gray muda
/// exatamente uma célula por atualização, então uma leitura suja é sempre um erro de uma célula
/// só, e a paridade a pega.
///
/// Disposição dos índices (linha * 6 + coluna):
///
///     r0:  BRANCO   d0   d1   d2   d3   PRETO
///     r1:    d4     d5   d6   d7   d8    d9
///     r2:    d10    d11  d12  d13  d14   d15
///     r3:   PRETO   par  --   --   --   BRANCO
///
/// As quatro células de referência ficam nos cantos e servem a duas coisas ao mesmo tempo:
/// dão o limiar preto/branco de cada quadro (sem depender de brilho, gama ou faixa de cor) e
/// funcionam como marca de registro — se a geometria escorregar, elas leem errado e a amostra é
/// descartada em vez de virar número plausível.
public enum Codigo {
    public static let colunas = 6
    public static let linhas = 4
    public static let totalCelulas = colunas * linhas  // 24
    public static let bitsDeDados = 16

    /// Índices das células, na grade linear.
    public static let refBranco: [Int] = [0, 23]
    public static let refPreto: [Int] = [5, 18]
    public static let dados: [Int] = [1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
    public static let paridade: Int = 19
    public static let vazias: [Int] = [20, 21, 22]

    public static let modulo: UInt32 = 1 << UInt32(bitsDeDados)  // 65536

    // MARK: - Gray

    @inline(__always)
    public static func paraGray(_ n: UInt32) -> UInt32 {
        let v = n % modulo
        return v ^ (v >> 1)
    }

    @inline(__always)
    public static func deGray(_ g: UInt32) -> UInt32 {
        var n = g & (modulo - 1)
        var deslocamento = n >> 1
        while deslocamento != 0 {
            n ^= deslocamento
            deslocamento >>= 1
        }
        return n & (modulo - 1)
    }

    /// Os 24 valores de célula (`true` = branco) para um índice de quadro.
    public static func celulas(paraIndice indice: UInt32) -> [Bool] {
        var c = [Bool](repeating: false, count: totalCelulas)
        for i in refBranco { c[i] = true }
        for i in refPreto { c[i] = false }
        for i in vazias { c[i] = false }
        let g = paraGray(indice)
        var pares = 0
        for (bit, celula) in dados.enumerated() {
            let ligado = (g >> UInt32(bit)) & 1 == 1
            c[celula] = ligado
            if ligado { pares += 1 }
        }
        // Paridade par sobre as 16 células de dados.
        c[paridade] = (pares % 2) == 1
        return c
    }

    // MARK: - Leitura

    public enum FalhaDeLeitura: String, Error {
        case contrasteInsuficiente = "contraste_insuficiente"
        case referenciaErrada = "referencia_errada"
        case paridadeErrada = "paridade"
        case planoIndisponivel = "plano_indisponivel"
        case margemBaixa = "margem_baixa"
    }

    public struct Leitura {
        public let indice: UInt32
        /// Distância, em unidades de luma, entre a célula mais ambígua e o limiar.
        /// Baixa margem com paridade boa ainda é suspeita — fica registrada.
        public let margemMinima: Double
        public let referenciaBranco: Double
        public let referenciaPreto: Double
    }

    /// Lê o índice do quadro no plano de luma de um `CVPixelBuffer` 4:2:0 bi-planar.
    ///
    /// Amostra o miolo central de cada célula (40% central em cada eixo, 8 x 8 pontos), o que a
    /// torna indiferente a borda, sombra e ao borrão de bloco do H.264.
    /// Onde a faixa está dentro do quadro, em fração de 0 a 1.
    ///
    /// **Existe por causa da câmera.** No laço fechado o ScreenCaptureKit captura só a janela do
    /// emissor, e a faixa preenche o quadro de borda a borda — a grade 6x4 pode ser aplicada à
    /// imagem inteira. Uma câmera apontada para uma tela pega moldura, mesa e parede junto, e a
    /// mesma grade cairia fora das células. `Regiao.inteira` é o comportamento de sempre.
    public struct Regiao: Sendable {
        public var x: Double, y: Double, largura: Double, altura: Double
        public init(x: Double, y: Double, largura: Double, altura: Double) {
            self.x = x; self.y = y; self.largura = largura; self.altura = altura
        }
        public static let inteira = Regiao(x: 0, y: 0, largura: 1, altura: 1)
        /// `"x,y,l,a"` em fração de 0 a 1, como vem da linha de comando.
        public init?(texto: String) {
            let p = texto.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count == 4, p[2] > 0, p[3] > 0,
                  p[0] >= 0, p[1] >= 0, p[0] + p[2] <= 1.0001, p[1] + p[3] <= 1.0001 else { return nil }
            self.init(x: p[0], y: p[1], largura: p[2], altura: p[3])
        }
    }

    public static func ler(
        de pixelBuffer: CVPixelBuffer
    ) -> Result<Leitura, FalhaDeLeitura> {
        ler(de: pixelBuffer, regiao: .inteira)
    }

    public static func ler(
        de pixelBuffer: CVPixelBuffer,
        regiao: Regiao
    ) -> Result<Leitura, FalhaDeLeitura> {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let formato = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planar = formato == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || formato == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        let base: UnsafeMutableRawPointer?
        let bytesPorLinha: Int
        let largura: Int
        let altura: Int
        if planar {
            base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            bytesPorLinha = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            largura = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            altura = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        } else {
            base = CVPixelBufferGetBaseAddress(pixelBuffer)
            bytesPorLinha = CVPixelBufferGetBytesPerRow(pixelBuffer)
            largura = CVPixelBufferGetWidth(pixelBuffer)
            altura = CVPixelBufferGetHeight(pixelBuffer)
        }
        guard let base, largura > colunas * 4, altura > linhas * 4 else {
            return .failure(.planoIndisponivel)
        }
        // Formato não planar só é aceito se for BGRA; aí lemos o canal verde como proxy de luma.
        let passoDePixel: Int
        let deslocamentoNoPixel: Int
        if planar {
            passoDePixel = 1
            deslocamentoNoPixel = 0
        } else if formato == kCVPixelFormatType_32BGRA {
            passoDePixel = 4
            deslocamentoNoPixel = 1  // G
        } else {
            return .failure(.planoIndisponivel)
        }

        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // A grade passa a viver dentro da região, e não do quadro. Com `Regiao.inteira` os quatro
        // números abaixo são 0, 0, largura e altura — a aritmética de antes, sem desvio.
        let rx = regiao.x * Double(largura)
        let ry = regiao.y * Double(altura)
        let rl = regiao.largura * Double(largura)
        let ra = regiao.altura * Double(altura)
        func media(celula: Int) -> Double {
            let coluna = celula % colunas
            let linha = celula / colunas
            let x0 = rx + (Double(coluna) + 0.30) / Double(colunas) * rl
            let x1 = rx + (Double(coluna) + 0.70) / Double(colunas) * rl
            let y0 = ry + (Double(linha) + 0.30) / Double(linhas) * ra
            let y1 = ry + (Double(linha) + 0.70) / Double(linhas) * ra
            var soma = 0.0
            var n = 0
            let passos = 8
            for iy in 0..<passos {
                let fy = (Double(iy) + 0.5) / Double(passos)
                let y = min(altura - 1, max(0, Int(y0 + (y1 - y0) * fy)))
                for ix in 0..<passos {
                    let fx = (Double(ix) + 0.5) / Double(passos)
                    let x = min(largura - 1, max(0, Int(x0 + (x1 - x0) * fx)))
                    soma += Double(bytes[y * bytesPorLinha + x * passoDePixel + deslocamentoNoPixel])
                    n += 1
                }
            }
            return soma / Double(n)
        }

        var valores = [Double](repeating: 0, count: totalCelulas)
        for i in 0..<totalCelulas { valores[i] = media(celula: i) }

        let branco = refBranco.map { valores[$0] }.reduce(0, +) / Double(refBranco.count)
        let preto = refPreto.map { valores[$0] }.reduce(0, +) / Double(refPreto.count)
        // Faixa limitada de vídeo põe branco em ~235 e preto em ~16. Exijo folga generosa: sem
        // ela, o limiar é indefinido e todo bit vira moeda.
        guard branco - preto >= 40.0 else { return .failure(.contrasteInsuficiente) }

        // As referências têm de estar do lado certo do próprio limiar — é a marca de registro.
        let limiar = (branco + preto) / 2.0
        for i in refBranco where valores[i] <= limiar { return .failure(.referenciaErrada) }
        for i in refPreto where valores[i] >= limiar { return .failure(.referenciaErrada) }

        var margem = Double.greatestFiniteMagnitude
        var g: UInt32 = 0
        var pares = 0
        for (bit, celula) in dados.enumerated() {
            let v = valores[celula]
            margem = min(margem, abs(v - limiar))
            if v > limiar {
                g |= (1 << UInt32(bit))
                pares += 1
            }
        }
        let bitDeParidade = valores[paridade] > limiar
        margem = min(margem, abs(valores[paridade] - limiar))
        guard bitDeParidade == ((pares % 2) == 1) else { return .failure(.paridadeErrada) }

        // Uma margem irrisória com paridade certa continua sendo um palpite. 8 unidades de luma
        // sobre uma excursão de >= 40 é ~20% — abaixo disso eu não afirmo que li.
        guard margem >= 8.0 else { return .failure(.margemBaixa) }

        return .success(
            Leitura(
                indice: deGray(g),
                margemMinima: margem,
                referenciaBranco: branco,
                referenciaPreto: preto
            )
        )
    }
}
