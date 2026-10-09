import Foundation

/// Só lê o necessário para detectar perda de referência antes de mandar uma fatia para o arquivo.
struct ReferenciasH264Recebidas {
    private var bitsDoNumero: Int?, campo = false, planoSeparado = false
    private var anterior: Int?
    init() {}
    init(sps: Data) {
        var b = Bits(sps)
        guard let perfil = b.ler(8), b.ler(16) != nil, b.ue() != nil else { return }
        if [100,110,122,244,44,83,86,118,128,138,139,134,135].contains(perfil) {
            guard let c = b.ue(), c <= 3 else { return }
            if c == 3 { guard let sep = b.ler(1) else { return }; planoSeparado = sep != 0 }
            guard b.ue() != nil, b.ue() != nil, b.ler(1) != nil, let escala = b.ler(1) else { return }
            if escala != 0 {
                for n in 0..<(c == 3 ? 12 : 8) {
                    guard let presente = b.ler(1) else { return }
                    if presente != 0 {
                        var ultima = 8, proxima = 8
                        for _ in 0..<(n < 6 ? 16 : 64) {
                            if proxima != 0 { guard let d = b.se() else { return }; proxima = (ultima + d + 256) % 256 }
                            if proxima != 0 { ultima = proxima }
                        }
                    }
                }
            }
        }
        guard let log = b.ue(), log <= 12, let poc = b.ue() else { return }
        bitsDoNumero = log + 4
        if poc == 0 { guard b.ue() != nil else { bitsDoNumero = nil; return } }
        else if poc == 1 {
            guard b.ler(1) != nil, b.se() != nil, b.se() != nil, let n = b.ue(), n < 256 else { bitsDoNumero = nil; return }
            for _ in 0..<n { guard b.se() != nil else { bitsDoNumero = nil; return } }
        }
        guard b.ue() != nil, b.ler(1) != nil, b.ue() != nil, b.ue() != nil,
              let soQuadro = b.ler(1) else { bitsDoNumero = nil; return }
        campo = soQuadro == 0
    }
    mutating func rompeu(_ nals: [Data], idr: Bool) -> Bool {
        guard let bitsDoNumero, let nal = nals.first, let cab = nal.first else { return true }
        if idr { anterior = 0; return false }
        var b = Bits(nal)
        guard b.ue() != nil, let tipo = b.ue(), b.ue() != nil else { return true }
        if tipo % 5 == 1 { return true } // O contrato de rede não transporta DTS separado para B-frames.
        if planoSeparado, b.ler(2) == nil { return true }
        guard let numero = b.ler(bitsDoNumero) else { return true }
        // Emissores Quall são progressivos. Não presume cadeia correta num campo entrelaçado.
        if campo, b.ler(1) != 0 { return true }
        let esperado = anterior.map { ($0 + 1) % (1 << bitsDoNumero) }
        let ruptura = esperado.map { numero != $0 } ?? false
        if cab & 0x60 != 0 { anterior = numero }
        return ruptura
    }
    private struct Bits {
        var dados: [UInt8] = [], pos = 0
        init(_ nal: Data) {
            var zeros = 0
            for byte in nal.dropFirst() {
                if zeros >= 2, byte == 3 { zeros = 0; continue }
                dados.append(byte); zeros = byte == 0 ? zeros + 1 : 0
            }
        }
        mutating func ler(_ n: Int) -> Int? {
            guard n >= 0, n <= 31, pos + n <= dados.count * 8 else { return nil }
            var v = 0
            for _ in 0..<n { v = (v << 1) | Int((dados[pos / 8] >> (7 - pos % 8)) & 1); pos += 1 }
            return v
        }
        mutating func ue() -> Int? {
            var zeros = 0
            while let bit = ler(1) {
                if bit == 1 { guard let baixo = ler(zeros) else { return nil }; return (1 << zeros) - 1 + baixo }
                zeros += 1; if zeros > 24 { return nil }
            }
            return nil
        }
        mutating func se() -> Int? { guard let v = ue() else { return nil }; return v % 2 == 0 ? -(v / 2) : (v + 1) / 2 }
    }
}
