import CQuall
import Foundation

/// **O Opus do microfone, pelo núcleo** (R5 fase 4 no Mac, `docs/teleprompter-com-camera.md` §8.9).
///
/// `quall_audio_encoder_new(MICROPHONE, OPUS)`: o preset do encoder e o do fio saem da mesma tabela
/// do núcleo (`TrackKind::preset_de_audio`), a lição do `docs/audio.md` §11 (o `useinbandfec=1` sem
/// LBRR). O comentário velho de `CodificadorPCMU` ("não há encoder de Opus alcançável do Swift")
/// descrevia o Mac antes de a fronteira exportar o encoder; o som de sistema continua em PCMU (outra
/// frente), e o microfone da câmera já nasce em Opus.
///
/// **Uma thread só**: o estado do Opus é preditivo, e o encoder não pode ser chamado de duas
/// (`quall.h`). Quem usa é a fila do áudio do dono.
public final class EncoderDeAudioDoNucleo: @unchecked Sendable {
    public let taxaHz: Int
    public let canais: Int
    public let amostrasPorQuadro: Int
    public let bitrateBps: Int
    public let fec: Bool
    /// Uma linha para o diário: o que o núcleo disse do preset.
    public let resumo: String

    private let encoder: OpaquePointer
    private var pacote = [UInt8](repeating: 0, count: 4000)

    /// `nil` quando o núcleo recusa o preset ou o encoder; o motivo em `ultimoErro`.
    public private(set) static var ultimoErro = ""

    public init?() {
        let especie = QUALL_TRACK_KIND_MICROPHONE
        let json = NucleoDeRede.lerTexto { buf, cap in quall_audio_preset_json(especie, QUALL_AUDIO_CODEC_OPUS, buf, cap) }
        guard let dados = json.data(using: .utf8),
              let p = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let taxa = p["sample_rate_hz"] as? Int, let canais = p["channels"] as? Int,
              let porQuadro = p["frame_samples"] as? Int, taxa > 0, porQuadro > 0 else {
            EncoderDeAudioDoNucleo.ultimoErro = "o núcleo recusou o preset de microfone: \(NucleoDeRede.ultimoErro())"
            return nil
        }
        // Mono: é o que o preset de microfone diz, e o único caso que a casca trata. Um preset que
        // mude isso tem de mudar a casca junto, e a recusa aqui é o que faz isso aparecer.
        guard canais == 1 else {
            EncoderDeAudioDoNucleo.ultimoErro = "preset de microfone com \(canais) canais: só mono é tratado"
            return nil
        }
        guard let e = quall_audio_encoder_new(especie, QUALL_AUDIO_CODEC_OPUS) else {
            EncoderDeAudioDoNucleo.ultimoErro = "quall_audio_encoder_new recusou: \(NucleoDeRede.ultimoErro())"
            return nil
        }
        encoder = e
        taxaHz = taxa
        self.canais = canais
        amostrasPorQuadro = porQuadro
        bitrateBps = p["bitrate_bps"] as? Int ?? 0
        fec = p["fec"] as? Bool ?? false
        resumo = "opus \(taxa) Hz \(canais) ch \(porQuadro) amostras/quadro \(bitrateBps / 1000) kbit/s fec=\(fec)"
    }

    deinit { quall_audio_encoder_free(encoder) }

    /// Codifica **um** quadro (`amostrasPorQuadro` amostras) e entrega o pacote a `enviar`, que
    /// devolve se o núcleo aceitou. `nil` quando o encoder falhou.
    public func codificar(_ quadro: [Int16], enviar: (UnsafeRawBufferPointer) -> Bool) -> Bool? {
        let bytes = quadro.withUnsafeBufferPointer { entrada -> Int in
            pacote.withUnsafeMutableBufferPointer { destino in
                quall_audio_encoder_encode(encoder, entrada.baseAddress, UInt(entrada.count),
                                           destino.baseAddress, UInt(destino.count))
            }
        }
        guard bytes > 0 else { return nil }
        return pacote.withUnsafeBytes { tudo in enviar(UnsafeRawBufferPointer(rebasing: tudo[0..<bytes])) }
    }
}
