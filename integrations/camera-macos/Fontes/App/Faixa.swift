import CoreVideo
import Foundation

/// **O relógio viaja dentro do vídeo.**
///
/// É o truque que `docs/medir-vidro-a-vidro.md` decidiu, aplicado ao caminho da câmera virtual: o
/// emissor desenha o próprio relógio monotônico numa faixa de células pretas e brancas no alto do
/// quadro. A faixa é conteúdo de imagem comum — o H.264 a carrega, o núcleo a transporta, o
/// decoder a devolve, a extensão a repassa —, e quem abre a câmera virtual **lê o número de
/// volta** dos pixels e subtrai do próprio relógio.
///
/// Por que isso e não carimbo em log: um carimbo mede o que o nosso código acha que aconteceu. A
/// faixa mede o que **chegou ao consumidor**, atravessando encode, RTP, decode, `CMSimpleQueue`,
/// o processo da extensão e o AVFoundation. Se qualquer elo enfileirar ou repetir quadro, o
/// número denuncia; um carimbo em log, não.
///
/// Duas escolhas herdadas do documento, e as duas custam zero:
///
/// - **Código de Gray**, não contador binário. Aqui os quadros chegam inteiros e não há célula
///   "meio acesa" como haveria filmando com câmera, então a razão original não morde — mas o
///   método está decidido, e seguir o decidido é mais barato que justificar a diferença.
/// - **Duas células de referência**, uma preta e uma branca, em toda faixa. O limiar sai delas, e
///   não de uma constante: assim a leitura não depende de o consumidor entregar exatamente 16 e
///   235 depois de passar por um encoder com perdas.
enum Faixa {
    /// 20 bits de dados: milissegundos que dão a volta em 2^20 ms ≈ 17,5 min, muito acima de
    /// qualquer latência que este caminho possa ter.
    static let bits = 20
    static let celulas = bits + 2
    static let modulo: UInt64 = 1 << 20

    static let alturaDaFaixa = 64
    static let larguraDaCelula = 56
    static let margemX = 8

    /// Gray: valores consecutivos diferem em exatamente uma célula.
    static func gray(_ v: UInt32) -> UInt32 { v ^ (v >> 1) }

    static func degray(_ g: UInt32) -> UInt32 {
        var b = g
        var deslocamento: UInt32 = 1
        while deslocamento < 32 {
            b ^= (g >> deslocamento)
            deslocamento += 1
        }
        return b
    }

    /// Desenha a faixa com `valorMs` (já reduzido ao módulo). Chame **por último**, depois do
    /// conteúdo: a faixa não pode ser sobrescrita por nada.
    static func desenhar(valorMs: UInt64, em buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let largura = CVPixelBufferGetWidth(buffer)
        guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let passoY = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let passoC = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let planoY = y.assumingMemoryBound(to: UInt8.self)
        let planoC = c.assumingMemoryBound(to: UInt8.self)

        let codificado = gray(UInt32(valorMs % modulo))

        for celula in 0..<celulas {
            let x = margemX + celula * larguraDaCelula
            guard x + larguraDaCelula <= largura else { break }
            let aceso: Bool
            switch celula {
            case 0: aceso = false                                   // referência preta
            case 1: aceso = true                                    // referência branca
            default: aceso = (codificado >> UInt32(celulas - 1 - celula)) & 1 == 1
            }
            let valor = aceso ? Placa.brancoLimitado : Placa.pretoLimitado
            for linha in 0..<alturaDaFaixa {
                memset(planoY + linha * passoY + x, Int32(valor), larguraDaCelula)
            }
        }

        // Croma neutro sob a faixa: cor nenhuma ali, para o encoder não gastar bits e para a
        // leitura depender só da luma.
        for linha in 0..<(alturaDaFaixa / 2) {
            memset(planoC + linha * passoC, 128, largura)
        }
    }

    /// Lê a faixa de volta. Devolve `nil` quando ela não está lá — quadro de placa da extensão,
    /// por exemplo, ou contraste insuficiente para um limiar honesto.
    static func ler(de buffer: CVPixelBuffer) -> UInt64? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let largura = CVPixelBufferGetWidth(buffer)
        let altura = CVPixelBufferGetHeight(buffer)
        guard altura >= alturaDaFaixa,
              let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let passoY = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let planoY = y.assumingMemoryBound(to: UInt8.self)

        // Só o miolo de cada célula: as bordas são onde o encoder com perdas erra, e onde uma
        // reescala eventual borraria.
        let recuo = larguraDaCelula / 4
        let linhaInicial = alturaDaFaixa / 4
        let linhaFinal = alturaDaFaixa - alturaDaFaixa / 4

        func media(_ celula: Int) -> Int? {
            let x = margemX + celula * larguraDaCelula + recuo
            let fim = margemX + (celula + 1) * larguraDaCelula - recuo
            guard fim <= largura else { return nil }
            var soma = 0
            var n = 0
            for linha in linhaInicial..<linhaFinal {
                let base = planoY + linha * passoY
                for coluna in x..<fim {
                    soma += Int(base[coluna])
                    n += 1
                }
            }
            return n > 0 ? soma / n : nil
        }

        guard let preto = media(0), let branco = media(1), branco - preto >= 60 else { return nil }
        let limiar = (preto + branco) / 2

        var codificado: UInt32 = 0
        for celula in 2..<celulas {
            guard let v = media(celula) else { return nil }
            codificado <<= 1
            if v > limiar { codificado |= 1 }
        }
        return UInt64(degray(codificado) & UInt32(modulo - 1))
    }
}
