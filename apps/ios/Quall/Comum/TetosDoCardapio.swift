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
        /// O teto de taxa previsto para a sessão, quando a escolha salva precisa recuar.
        public var fpsEfetivo: Int?
        /// Recuo para uma resolução disponível, sem regravar a preferência.
        public var resolucaoEfetiva: Int?
        /// Capacidade real; não é inferida das duas opções de taxa da interface.
        public var tetoFPS: Int?
        public init(resolucoesFora: Set<Int> = [], taxasFora: Set<Int> = [], fpsEfetivo: Int? = nil,
                    resolucaoEfetiva: Int? = nil, tetoFPS: Int? = nil) {
            self.resolucoesFora = resolucoesFora
            self.taxasFora = taxasFora
            self.fpsEfetivo = fpsEfetivo
            self.resolucaoEfetiva = resolucaoEfetiva
            self.tetoFPS = tetoFPS
        }
    }

    /// O fps máximo de cada resolução: o maior entre os formatos **do tamanho ou maiores**, porque o
    /// 2K sai do 4K reduzido. `nil` quando nenhum formato chega ao tamanho. Os tamanhos e os formatos
    /// são em paisagem (largura ≥ altura), como o AVFoundation os declara.
    public static func tetos(formatos: [(largura: Int, altura: Int, fpsMaximo: Double)],
                             tamanhos: [(chave: Int, largura: Int, altura: Int)]) -> [Int: Int?] {
        var t: [Int: Int?] = [:]
        for tamanho in tamanhos {
            let cabem = formatos.filter {
                max($0.largura, $0.altura) >= max(tamanho.largura, tamanho.altura)
                    && min($0.largura, $0.altura) >= min(tamanho.largura, tamanho.altura)
            }
            if let maior = cabem.map(\.fpsMaximo).max() {
                t[tamanho.chave] = .some(Int(maior.rounded()))
            } else {
                t[tamanho.chave] = .some(nil)
            }
        }
        return t
    }

    /// O estado do cardápio. [tetos]: `nil` = a câmera não oferece; chave ausente = não se sabe (fica
    /// disponível). Toda taxa acima do teto se apaga; uma taxa efetiva fora das opções aparece como
    /// indicador selecionado somente leitura. A escolha salva não muda. Uma resolução indisponível
    /// recua para a maior disponível até ela (ou a menor disponível). O teto de capacidade e a
    /// taxa prevista são separados: uma câmera de 45, com 30 salvos, continua prevista para 30.
    public static func estado(tetos: [Int: Int?], escolhida: Int, fps: Int, taxas: [Int]) -> Estado {
        let fora = Set(tetos.compactMap { $0.value == nil ? $0.key : nil })
        var resolucao = escolhida
        if fora.contains(escolhida) {
            let disponiveis = tetos.compactMap { $0.value != nil ? $0.key : nil }.sorted()
            guard let recuo = disponiveis.last(where: { $0 <= escolhida }) ?? disponiveis.first else {
                return Estado(resolucoesFora: fora)
            }
            resolucao = recuo
        }
        guard let teto = tetos[resolucao] ?? nil else { return Estado(resolucoesFora: fora) }
        let taxasFora = Set(taxas.filter { $0 > teto })
        let efetivo = min(fps, teto)
        return Estado(resolucoesFora: fora, taxasFora: taxasFora,
                      fpsEfetivo: efetivo != fps ? efetivo : nil,
                      resolucaoEfetiva: resolucao != escolhida ? resolucao : nil,
                      tetoFPS: teto)
    }

    /// A captura usa a mesma geometria do cardápio: um formato que cobre o alvo, reduzido pelo
    /// encoder quando necessário (2K a partir de 4K). Entre os que fazem a taxa, prefere a menor
    /// área suficiente e, no empate, o não-binned; por fim a ordem do AVFoundation.
    public static func indiceDoFormato(
        formatos: [(largura: Int, altura: Int, faixas: [(minima: Double, maxima: Double)], binned: Bool)],
        largura: Int, altura: Int, fps: Int
    ) -> Int? {
        let candidatos = formatos.indices.filter { i in
            let f = formatos[i]
            return max(f.largura, f.altura) >= max(largura, altura)
                && min(f.largura, f.altura) >= min(largura, altura)
                && f.faixas.contains { $0.minima <= Double(fps) && $0.maxima >= Double(fps) }
        }
        return candidatos.min { a, b in
            let fa = formatos[a], fb = formatos[b]
            let aa = Int64(fa.largura) * Int64(fa.altura), ab = Int64(fb.largura) * Int64(fb.altura)
            if aa != ab { return aa < ab }
            if fa.binned != fb.binned { return !fa.binned }
            return a < b
        }
    }
}
