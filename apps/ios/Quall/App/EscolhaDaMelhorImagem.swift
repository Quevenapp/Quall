import Foundation

/// **"A melhor imagem" é uma escolha sobre os formatos que a câmera escolhida oferece**, e não um
/// preset fixo. Função pura, sem AVFoundation: quem chama traduz `AVCaptureDevice.formats` para
/// `FormatoOferecido` e aplica o índice devolvido por `activeFormat`. É testada no MacBook
/// (`Testes/rodar.sh`) sobre listas de formatos falsas.
///
/// # Por que existe (defeito provado no iPhone X, iOS 16.7, 24/09 18:06)
///
/// A fase 3 do R5 pedia `.hd4K3840x2160` à sessão **antes** de a entrada da câmera entrar nela. Sem
/// entrada, `canSetSessionPreset` não tem contra o que conferir e disse sim; a frontal do iPhone X
/// não faz 4K, então o `canAddInput` seguinte recusou a câmera e a captura inteira caiu ("Não foi
/// possível abrir a câmera deste iPhone"): sem prévia, sem botão Gravar. Uma preferência de
/// qualidade derrubou a câmera.
///
/// # A regra
///
/// Entre os formatos da câmera:
/// 1. só `420v` e `420f` (8 bits, o que a saída e os dois codificadores sabem ler — fica de fora o
///    10 bits `x420` e qualquer outro);
/// 2. só os tamanhos padrão de vídeo — 1280x720, 1920x1080 e 3840x2160, deitados ou em pé: a
///    câmera oferece formatos de foto 4:3 (1920x1440, 4032x3024) com vídeo a 30 fps, e 16:9
///    exóticos (3072x1728, 4096x2304) que nem o cardápio nem os codificadores conhecem; "o maior"
///    sem esta regra seria um deles;
/// 3. com uma faixa de taxa que contém a taxa pedida (e nunca abaixo de 30);
/// 4. o de **maior área**; no empate, o que **não** é *binned* (`isVideoBinned`: os formatos de
///    120/240 fps no mesmo tamanho costumam ser, com imagem pior); no empate ainda, `420v`, que é o
///    que a saída pede (`DonoDaCaptura.montarCaptura`) e dispensa conversão; e por fim o primeiro
///    da lista do AVFoundation.
///
/// Sem candidato, devolve `nil`, e quem chama cai no cardápio da fase 2 — nunca derruba a captura.
struct FormatoOferecido: Equatable {
    struct Faixa: Equatable {
        let minima: Double
        let maxima: Double
    }

    let largura: Int
    let altura: Int
    /// O FourCC do `CMFormatDescriptionGetMediaSubType`.
    let subtipo: UInt32
    let faixas: [Faixa]
    /// `AVCaptureDevice.Format.isVideoBinned`.
    let binned: Bool

    init(largura: Int, altura: Int, subtipo: UInt32, faixas: [Faixa], binned: Bool = false) {
        self.largura = largura
        self.altura = altura
        self.subtipo = subtipo
        self.faixas = faixas
        self.binned = binned
    }

    var area: Int { largura * altura }

    /// `'420v'` e `'420f'` em FourCC — os mesmos valores de
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` e `…FullRange`, escritos aqui para a
    /// função não depender de CoreVideo.
    static let subtipo420v: UInt32 = 0x3432_3076
    static let subtipo420f: UInt32 = 0x3432_3066

    var nomeDoSubtipo: String {
        switch subtipo {
        case FormatoOferecido.subtipo420v: return "420v"
        case FormatoOferecido.subtipo420f: return "420f"
        default:
            let b = [24, 16, 8, 0].map { UInt8((subtipo >> UInt32($0)) & 0xff) }
            return String(bytes: b, encoding: .ascii) ?? String(subtipo, radix: 16)
        }
    }

    func faz(_ fps: Double) -> Bool {
        faixas.contains { $0.minima <= fps && $0.maxima >= fps }
    }
}

enum EscolhaDaMelhorImagem {
    /// Os tamanhos aceitos, como (lado maior, lado menor).
    static let tamanhosPadrao: [(maior: Int, menor: Int)] = [(1280, 720), (1920, 1080), (3840, 2160)]

    /// O índice, em `formatos`, da melhor imagem a `fps` quadros por segundo, ou `nil` se nenhum
    /// formato serve. `fps` abaixo de 30 conta como 30 ("a melhor imagem" é a ≥ 30 fps).
    static func escolher(_ formatos: [FormatoOferecido], fps: Int) -> Int? {
        let pedido = Double(max(30, fps))
        let candidatos = formatos.indices.filter { i in
            let f = formatos[i]
            let maior = max(f.largura, f.altura)
            let menor = min(f.largura, f.altura)
            return (f.subtipo == FormatoOferecido.subtipo420v || f.subtipo == FormatoOferecido.subtipo420f)
                && tamanhosPadrao.contains { $0.maior == maior && $0.menor == menor }
                && f.faz(pedido)
        }
        // `max(by:)` com "a < b" = "a é pior que b".
        return candidatos.max { a, b in
            let fa = formatos[a], fb = formatos[b]
            if fa.area != fb.area { return fa.area < fb.area }
            if fa.binned != fb.binned { return fa.binned }
            let va = fa.subtipo == FormatoOferecido.subtipo420v
            let vb = fb.subtipo == FormatoOferecido.subtipo420v
            if va != vb { return !va }
            // Empate total: o primeiro da lista vence (a ordem do AVFoundation), para a escolha
            // ser determinística.
            return a > b
        }
    }

    /// A escolha com a queda de taxa: primeiro a taxa do cardápio; se nenhum formato a faz (60
    /// numa frontal que só faz 30), a melhor imagem a 30 — o `limitarTaxa` fixa o que o formato dá.
    static func escolherComQueda(_ formatos: [FormatoOferecido], fps: Int) -> (indice: Int, fps: Int)? {
        if let i = escolher(formatos, fps: fps) { return (i, max(30, fps)) }
        if fps > 30, let i = escolher(formatos, fps: 30) { return (i, 30) }
        return nil
    }
}
