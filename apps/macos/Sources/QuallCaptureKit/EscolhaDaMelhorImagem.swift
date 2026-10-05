import Foundation

/// **"A melhor imagem" é uma escolha sobre os formatos que a câmera escolhida oferece**, e não um
/// preset fixo (R5, `docs/teleprompter-com-camera.md` §8.7 e §8.9). Função pura, sem AVFoundation:
/// quem chama traduz `AVCaptureDevice.formats` para `FormatoOferecido` e aplica o índice devolvido
/// por `activeFormat`. Testada em `TestesDaMelhorImagem`.
///
/// # De onde vem
///
/// **Cópia de `apps/ios/Quall/App/EscolhaDaMelhorImagem.swift`**, com uma regra a mais para o Mac. O
/// iOS e o Mac não dividem um alvo Swift (o iOS é XcodeGen, o Mac é SwiftPM), e mover a regra para
/// um kit comum mexeria no portão do iOS por 100 linhas. `TestesDaMelhorImagem` confere que a lista
/// de tamanhos padrão daqui é a mesma do arquivo do iOS (lido do disco); o resto da regra, quem
/// mudar muda nas duas.
///
/// # A regra
///
/// Entre os formatos da câmera:
/// 1. só os tamanhos padrão de vídeo — 1280x720, 1920x1080 e 3840x2160, deitados ou em pé (os de
///    foto 4:3 e os 16:9 exóticos ficam de fora: nem os codificadores nem o teto do SDP os
///    conhecem);
/// 2. com uma faixa de taxa que contém a taxa pedida (e nunca abaixo de 30);
/// 3. de preferência `420v`/`420f` (o que a saída pede e dispensa conversão). **No Mac**, quando a
///    câmera não oferece nenhum 420 do tamanho padrão — uma webcam USB costuma oferecer `2vuy` e
///    MJPEG, **hipótese pela ficha UVC** —, os outros subtipos entram: a
///    `AVCaptureVideoDataOutput` converte para o 420v que ela entrega (`aceitarOutrosSubtipos`);
/// 4. o de **maior área**; no empate, o que **não** é *binned*; depois `420v`; depois o primeiro da
///    lista do AVFoundation.
///
/// Sem candidato, devolve `nil`, e quem chama **fica com o formato ativo** — nunca derruba a captura.
public struct FormatoOferecido: Equatable, Sendable {
    public struct Faixa: Equatable, Sendable {
        public let minima: Double
        public let maxima: Double
        public init(minima: Double, maxima: Double) {
            self.minima = minima
            self.maxima = maxima
        }
    }

    public let largura: Int
    public let altura: Int
    /// O FourCC do `CMFormatDescriptionGetMediaSubType`.
    public let subtipo: UInt32
    public let faixas: [Faixa]
    /// `AVCaptureDevice.Format.isVideoBinned` (só existe no iOS; no Mac é sempre `false`).
    public let binned: Bool

    public init(largura: Int, altura: Int, subtipo: UInt32, faixas: [Faixa], binned: Bool = false) {
        self.largura = largura
        self.altura = altura
        self.subtipo = subtipo
        self.faixas = faixas
        self.binned = binned
    }

    public var area: Int { largura * altura }

    /// `'420v'` e `'420f'` em FourCC — os mesmos valores de
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` e `…FullRange`, escritos aqui para a
    /// função não depender de CoreVideo.
    public static let subtipo420v: UInt32 = 0x3432_3076
    public static let subtipo420f: UInt32 = 0x3432_3066

    public var eh420: Bool { subtipo == FormatoOferecido.subtipo420v || subtipo == FormatoOferecido.subtipo420f }

    public var nomeDoSubtipo: String {
        switch subtipo {
        case FormatoOferecido.subtipo420v: return "420v"
        case FormatoOferecido.subtipo420f: return "420f"
        default:
            let b = [24, 16, 8, 0].map { UInt8((subtipo >> UInt32($0)) & 0xff) }
            if b.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }), let s = String(bytes: b, encoding: .ascii) { return s }
            return String(subtipo, radix: 16)
        }
    }

    public func faz(_ fps: Double) -> Bool {
        faixas.contains { $0.minima <= fps && $0.maxima >= fps }
    }
}

public enum EscolhaDaMelhorImagem {
    /// Os tamanhos aceitos, como (lado maior, lado menor).
    public static let tamanhosPadrao: [(maior: Int, menor: Int)] = [(1280, 720), (1920, 1080), (3840, 2160)]

    /// O índice, em `formatos`, da melhor imagem a `fps` quadros por segundo, ou `nil` se nenhum
    /// formato serve. `fps` abaixo de 30 conta como 30 ("a melhor imagem" é a ≥ 30 fps).
    public static func escolher(_ formatos: [FormatoOferecido], fps: Int,
                                aceitarOutrosSubtipos: Bool = false) -> Int? {
        let pedido = Double(max(30, fps))
        func candidatos(_ so420: Bool) -> [Int] {
            formatos.indices.filter { i in
                let f = formatos[i]
                let maior = max(f.largura, f.altura)
                let menor = min(f.largura, f.altura)
                return (!so420 || f.eh420)
                    && tamanhosPadrao.contains { $0.maior == maior && $0.menor == menor }
                    && f.faz(pedido)
            }
        }
        var lista = candidatos(true)
        if lista.isEmpty && aceitarOutrosSubtipos { lista = candidatos(false) }
        // `max(by:)` com "a < b" = "a é pior que b".
        return lista.max { a, b in
            let fa = formatos[a], fb = formatos[b]
            if fa.area != fb.area { return fa.area < fb.area }
            if fa.binned != fb.binned { return fa.binned }
            let va = fa.subtipo == FormatoOferecido.subtipo420v
            let vb = fb.subtipo == FormatoOferecido.subtipo420v
            if va != vb { return !va }
            if fa.eh420 != fb.eh420 { return !fa.eh420 }
            // Empate total: o primeiro da lista vence (a ordem do AVFoundation), para a escolha
            // ser determinística.
            return a > b
        }
    }

    /// A escolha com a queda de taxa: primeiro a taxa pedida; se nenhum formato a faz (60 numa
    /// webcam que só faz 30), a melhor imagem a 30.
    public static func escolherComQueda(_ formatos: [FormatoOferecido], fps: Int,
                                        aceitarOutrosSubtipos: Bool = false) -> (indice: Int, fps: Int)? {
        if let i = escolher(formatos, fps: fps, aceitarOutrosSubtipos: aceitarOutrosSubtipos) {
            return (i, max(30, fps))
        }
        if fps > 30, let i = escolher(formatos, fps: 30, aceitarOutrosSubtipos: aceitarOutrosSubtipos) {
            return (i, 30)
        }
        return nil
    }
}
