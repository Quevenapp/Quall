import AVFoundation

/// Os tetos do cardápio para uma câmera do aparelho (`TetosDoCardapio`), lidos dos formatos do
/// `AVCaptureDevice`: o maior fps de cada resolução entre os formatos do tamanho ou maiores. A tela e
/// uma câmera que não se acha dão `[:]`, que deixa tudo disponível.
enum TetosDaCamera {
    static func tetos(cameraID: String?) -> [Int: Int?] {
        guard let id = cameraID, let d = AVCaptureDevice(uniqueID: id) else { return [:] }
        let formatos = d.formats.map { f -> (largura: Int, altura: Int, fpsMaximo: Double) in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let w = Int(dim.width), h = Int(dim.height)
            return (max(w, h), min(w, h), f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        let tamanhos = Resolucao.allCases.map { (chave: $0.rawValue, largura: $0.teto.maior, altura: $0.teto.menor) }
        return TetosDoCardapio.tetos(formatos: formatos, tamanhos: tamanhos)
    }

    /// O estado do cardápio para a câmera [cameraID], com a escolha salva.
    static func estado(cameraID: String?, tetos: [Int: Int?]? = nil,
                       resolucao: Resolucao = Resolucao.escolhida, fps: Int = Resolucao.quadros) -> TetosDoCardapio.Estado {
        TetosDoCardapio.estado(tetos: tetos ?? self.tetos(cameraID: cameraID), escolhida: resolucao.rawValue,
                               fps: fps, taxas: Resolucao.taxas)
    }

    static func resolucao(para estado: TetosDoCardapio.Estado, preferida: Resolucao) -> Resolucao {
        estado.resolucaoEfetiva.flatMap(Resolucao.init(rawValue:)) ?? preferida
    }

    static func formato(em aparelho: AVCaptureDevice, alvo: Resolucao, fps: Int) -> AVCaptureDevice.Format? {
        let formatos = aparelho.formats
        let oferecidos = formatos.map { f in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return (largura: Int(dim.width), altura: Int(dim.height),
                    faixas: f.videoSupportedFrameRateRanges.map { (minima: $0.minFrameRate, maxima: $0.maxFrameRate) },
                    binned: f.isVideoBinned)
        }
        guard let i = TetosDoCardapio.indiceDoFormato(formatos: oferecidos,
                                                     largura: alvo.teto.maior, altura: alvo.teto.menor, fps: fps) else { return nil }
        return formatos[i]
    }
}
