import Foundation

/// **O cardápio apaga o que a câmera não faz** (06/10, o mesmo do Android). Puro, sem AVFoundation: os
/// testes do MacBook o compilam (`Testes/rodar.sh`).
///
/// No Android, o A07 não faz 60 fps em faixa nenhuma, e escolher 60 dava 720p a 30 fixos, com a imagem
/// escura. No iOS o recuo já existia (o `DonoDaCaptura` cai no maior fps do formato), mas o cardápio
/// oferecia o que a câmera não faz e dizia "60" com a câmera entregando 30.
///
/// As resoluções entram pela chave `maxFs` (o `rawValue` de `Resolucao`), para esta regra não depender
/// do tipo, que importa AVFoundation.
public enum TetosDoCardapio {
    public struct Estado: Equatable {
        /// As resoluções que a câmera não oferece: o segmento fica apagado.
        public var resolucoesFora: Set<Int> = []
        /// As taxas que a câmera não alcança na resolução escolhida: o segmento fica apagado.
        public var taxasFora: Set<Int> = []
        /// O fps que vai de fato, quando a escolha salva passa do teto da câmera.
        public var fpsEfetivo: Int?
        public init(resolucoesFora: Set<Int> = [], taxasFora: Set<Int> = [], fpsEfetivo: Int? = nil) {
            self.resolucoesFora = resolucoesFora
            self.taxasFora = taxasFora
            self.fpsEfetivo = fpsEfetivo
        }
    }

    /// O fps máximo de cada resolução: o maior entre os formatos **do tamanho ou maiores**, porque o
    /// 2K sai do 4K reduzido. `nil` quando nenhum formato chega ao tamanho. Os tamanhos e os formatos
    /// são em paisagem (largura ≥ altura), como o AVFoundation os declara.
    public static func tetos(formatos: [(largura: Int, altura: Int, fpsMaximo: Double)],
                             tamanhos: [(chave: Int, largura: Int, altura: Int)]) -> [Int: Int?] {
        var t: [Int: Int?] = [:]
        for tamanho in tamanhos {
            let cabem = formatos.filter { $0.largura >= tamanho.largura && $0.altura >= tamanho.altura }
            if let maior = cabem.map(\.fpsMaximo).max() {
                t[tamanho.chave] = .some(Int(maior.rounded()))
            } else {
                t[tamanho.chave] = .some(nil)
            }
        }
        return t
    }

    /// O estado do cardápio. [tetos]: `nil` = a câmera não oferece; chave ausente = não se sabe (fica
    /// disponível). A menor taxa nunca se apaga: numa câmera que faz 4K só a 24, o "30" continua e vai a
    /// 24. A escolha salva não muda; [Estado.fpsEfetivo] diz o que vai.
    public static func estado(tetos: [Int: Int?], escolhida: Int, fps: Int, taxas: [Int]) -> Estado {
        let fora = Set(tetos.compactMap { $0.value == nil ? $0.key : nil })
        guard let teto = tetos[escolhida] ?? nil else { return Estado(resolucoesFora: fora) }
        let menor = taxas.min()
        let taxasFora = Set(taxas.filter { $0 > teto && $0 != menor })
        return Estado(resolucoesFora: fora, taxasFora: taxasFora, fpsEfetivo: fps > teto ? teto : nil)
    }
}
