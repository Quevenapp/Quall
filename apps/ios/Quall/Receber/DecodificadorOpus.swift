import Foundation

/// O codec negociado → PCM, uma **ordem de slot** por vez.
///
/// Opus usa a libopus; PCMU expande cada byte G.711 em uma amostra a 8 kHz, mono.
/// O codec vem de `quall_track_audio_codec`, nunca do conteúdo aparente do pacote.
///
/// # O que este arquivo não decide
///
/// Quase tudo. `docs/audio.md` é explícito em que a política é do núcleo e não da casca: a
/// profundidade do jitter buffer, a elegibilidade de FEC, a ordem dos slots e o preenchimento dos
/// buracos já vêm resolvidos quando `quall_track_on_audio` chama. O que sobra para cá é a única
/// coisa que o núcleo deliberadamente não faz — decodificar o codec — porque **PCM é o que o
/// contrato mantém fora do núcleo** (§13: *"`opus_decode` não é configurado por preset nenhum"*).
///
/// No ramo Opus, a tabela é a do header; no ramo PCMU, FRAME expande a tabela G.711 e perdas
/// produzem silêncio linear de 20 ms, pois esse codec não oferece FEC ou PLC.
///
/// | ordem | o que se faz | contador |
/// |---|---|---|
/// | `FRAME` | `opus_decode(pacote, decode_fec: 0)` | `quadros` |
/// | `FEC` **com** LBRR | `opus_decode(socorro, decode_fec: 1)` | `curadosPorFec` |
/// | `FEC` **sem** LBRR (ou `-1`) | ocultação de perda | `socorroSemLbrr` + `ocultados` |
/// | `SILENCE` | ocultação de perda | `ocultados` |
///
/// # As três armadilhas que estão escritas em documento e custam caro por conta própria
///
/// 1. **`fec_has_lbrr` é tri-estado, e `-1` não é `false` por acaso.** Sem LBRR, `opus_decode` com
///    `decode_fec = 1` **cai na ocultação de perda em silêncio e devolve sucesso**. Quem tratasse
///    `-1` como "tenta, vai que" teria um contador de `curadosPorFec` subindo sem nada ter sido
///    curado — um número que mente para sempre, e que ninguém teria como refutar depois. Só `1`
///    autoriza o `decode_fec`.
/// 2. **O `pcm` tem de ter EXATAMENTE a duração de um quadro.** Se for maior, a libopus preenche a
///    diferença com ocultação e só o começo vem do LBRR, sem avisar. Por isso o buffer é
///    dimensionado uma vez, por `amostrasPorQuadro * canais`, e nunca por "o que couber".
/// 3. **A libopus não é robusta a pacote vazio.** `docs/audio.md` §14 avisa em voz alta: *"Quem
///    for acrescentar uma chamada nova à libopus com dado vindo da rede: teste o comprimento zero
///    primeiro."* Aqui um payload de comprimento zero **nunca** chega ao `opus_decode` com
///    `decode_fec` — cai na ocultação, que é o caminho que aceita ponteiro nulo por contrato.
///
/// # Os canais vêm do codec negociado, não da espécie
///
/// `CodecDeAudio::canais_no_fio` existe por causa de um defeito medido em 27/08/2026: uma track de
/// áudio de sistema **pede** estéreo pelo preset, mas se o codec negociado for PCMU o que anda no
/// fio é mono, e quem gravasse declarando 2 canais produziria um arquivo tocando no dobro da
/// velocidade e uma oitava acima — sem erro em lugar nenhum. Quem constrói este decodificador lê
/// os canais do `quall_audio_preset_json` **do codec que a track negociou**, nunca do preset da
/// espécie sozinho. Ver `PresetDeAudioLido`.
final class DecodificadorDeAudio {

    /// Contadores da corrida. Todos monotônicos, todos lidos sob trava pelo relato de 1 Hz.
    struct Instantaneo {
        var slots: UInt64 = 0
        var quadros: UInt64 = 0
        var curadosPorFec: UInt64 = 0
        var socorroSemLbrr: UInt64 = 0
        var ocultados: UInt64 = 0
        var falhas: UInt64 = 0
        /// O último código negativo: libopus ou −1001 para comprimento PCMU inválido.
        var ultimaFalha: Int32 = 0
        /// Amostras por canal efetivamente produzidas. Serve à conferência mais barata que existe
        /// contra o defeito do fator de 6: `amostras / (slots * amostrasPorQuadro)` tem de dar 1.
        var amostras: UInt64 = 0
    }

    let taxaHz: Int32
    let canais: Int
    let codec: QuallAudioCodec
    /// Amostras **por canal** num quadro de 20 ms: Opus 960 a 48 kHz; PCMU 160 a 8 kHz.
    let amostrasPorQuadro: Int

    private var decodificador: OpaquePointer?
    private var aberto = true
    private var pcm: [Int16]
    private let trava = NSLock()
    private var contadores = Instantaneo()

    /// `nil` quando o codec é desconhecido ou seu formato é recusado. O receptor relata a
    /// falha e mantém a exibição de vídeo.
    init?(codec: QuallAudioCodec, taxaHz: Int32, canais: Int, amostrasPorQuadro: Int) {
        guard canais >= 1, canais <= 2, amostrasPorQuadro > 0 else { return nil }
        switch codec {
        case QUALL_AUDIO_CODEC_OPUS:
            var erro: Int32 = 0
            guard let d = opus_decoder_create(taxaHz, Int32(canais), &erro), erro == 0 else {
                return nil
            }
            self.decodificador = d
        case QUALL_AUDIO_CODEC_PCMU:
            // O núcleo fixa slots de 20 ms; G.711 PCMU tem relógio de 8 kHz e um canal.
            guard taxaHz == 8_000, canais == 1, amostrasPorQuadro == 160 else { return nil }
        default:
            // DEFAULT na consulta da track significa "não sei", não autorização para Opus.
            return nil
        }
        self.codec = codec
        self.taxaHz = taxaHz
        self.canais = canais
        self.amostrasPorQuadro = amostrasPorQuadro
        self.pcm = [Int16](repeating: 0, count: amostrasPorQuadro * canais)
    }

    deinit { fechar() }

    func fechar() {
        trava.lock()
        aberto = false
        if let d = decodificador {
            opus_decoder_destroy(d)
            decodificador = nil
        }
        trava.unlock()
    }

    func instantaneo() -> Instantaneo {
        trava.lock(); defer { trava.unlock() }
        return contadores
    }

    /// Traduz um slot em 20 ms de PCM. **Sempre devolve 20 ms**, inclusive quando não havia
    /// pacote: é o contrato do header (*"uma ordem por slot de 20 ms, sempre, sem buraco"*) e é o
    /// que um DAC exige — ele não aceita "pulei este aqui".
    ///
    /// Devolve `nil` quando o codec falhou ou o pacote PCMU tem duração inválida; o chamador precisa produzir
    /// silêncio: um buraco na fila do DAC é um estalo.
    func traduzir(ordem: QuallAudioOrder,
                  payload: UnsafeRawBufferPointer?,
                  temLbrr: Int8) -> [Int16]? {
        trava.lock()
        defer { trava.unlock() }
        guard aberto else { return nil }
        contadores.slots &+= 1

        if codec == QUALL_AUDIO_CODEC_PCMU {
            return traduzirPCMU(ordem: ordem, payload: payload)
        }
        guard let dec = decodificador else { return nil }

        // A decisão, e ela é a tabela do cabeçalho.
        //
        // `usarFec` só com `temLbrr == 1`: o `0` é "não tem" e o `-1` é "não sei", e os dois levam
        // à ocultação. O header do núcleo diz a mesma coisa com outras palavras — *"uma casca que
        // receber `-1` não deve chamar `decode_fec`"* — e o motivo é que a falha do caminho errado
        // é **silenciosa**.
        var usarFec = false
        var dados: UnsafePointer<UInt8>?
        var tamanho: Int32 = 0

        switch ordem {
        case QUALL_AUDIO_ORDER_FRAME:
            guard let p = payload, let base = p.baseAddress, p.count > 0 else {
                contadores.ocultados &+= 1
                break
            }
            dados = base.assumingMemoryBound(to: UInt8.self)
            tamanho = Int32(p.count)
            contadores.quadros &+= 1

        case QUALL_AUDIO_ORDER_FEC:
            guard temLbrr == 1, let p = payload, let base = p.baseAddress, p.count > 0 else {
                // Socorro sem LBRR, ou com LBRR desconhecido: **contado à parte**, porque a
                // diferença entre "perdi e não havia socorro" e "perdi e o socorro não servia" é
                // o que diz se o `useinbandfec` do outro lado está fazendo alguma coisa. Os dois
                // caem na ocultação, mas só um deles acusa o emissor.
                if payload != nil { contadores.socorroSemLbrr &+= 1 }
                contadores.ocultados &+= 1
                break
            }
            dados = base.assumingMemoryBound(to: UInt8.self)
            tamanho = Int32(p.count)
            usarFec = true
            contadores.curadosPorFec &+= 1

        case QUALL_AUDIO_ORDER_SILENCE:
            contadores.ocultados &+= 1

        default:
            // Uma ordem nova no núcleo aparece como falha contada, e não some num `default`
            // silencioso que produziria 20 ms de nada sem ninguém saber.
            contadores.falhas &+= 1
            contadores.ultimaFalha = -1000
            contadores.ocultados &+= 1
        }

        let n = pcm.withUnsafeMutableBufferPointer { saida -> Int32 in
            opus_decode(dec, dados, tamanho, saida.baseAddress,
                        Int32(amostrasPorQuadro), usarFec ? 1 : 0)
        }
        guard n > 0 else {
            contadores.falhas &+= 1
            contadores.ultimaFalha = n
            return nil
        }
        contadores.amostras &+= UInt64(n)
        // `n` pode ser menor que `amostrasPorQuadro` se o outro lado mandar um quadro mais curto.
        // Entregar só o que foi produzido é o certo: completar com zeros seria inventar silêncio
        // que o emissor não mandou, e o carimbo do slot seguinte já não bateria.
        let uteis = Int(n) * canais
        return uteis == pcm.count ? pcm : Array(pcm[0..<uteis])
    }

    /// PCMU não tem FEC nem estado de ocultação. Um buraco vira silêncio linear, mantendo os
    /// 20 ms do slot; o sucessor de um FEC nunca é tocado duas vezes como se curasse a perda.
    private func traduzirPCMU(ordem: QuallAudioOrder,
                             payload: UnsafeRawBufferPointer?) -> [Int16]? {
        switch ordem {
        case QUALL_AUDIO_ORDER_FRAME:
            guard let p = payload, let base = p.baseAddress, p.count == amostrasPorQuadro else {
                contadores.falhas &+= 1
                contadores.ultimaFalha = -1001
                return nil
            }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for i in 0..<amostrasPorQuadro { pcm[i] = Self.linearPCMU(bytes[i]) }
            contadores.quadros &+= 1
        case QUALL_AUDIO_ORDER_FEC:
            if payload != nil { contadores.socorroSemLbrr &+= 1 }
            contadores.ocultados &+= 1
            pcm = [Int16](repeating: 0, count: amostrasPorQuadro)
        case QUALL_AUDIO_ORDER_SILENCE:
            contadores.ocultados &+= 1
            pcm = [Int16](repeating: 0, count: amostrasPorQuadro)
        default:
            contadores.falhas &+= 1
            contadores.ultimaFalha = -1000
            return nil
        }
        contadores.amostras &+= UInt64(amostrasPorQuadro)
        return pcm
    }

    /// Expansão ITU-T G.711 µ-law para PCM linear de 16 bits. Todos os 256 códigos são válidos,
    /// inclusive os dois zeros (0x7f e 0xff); bytes zero não significam silêncio.
    static func linearPCMU(_ byte: UInt8) -> Int16 {
        let v = ~byte
        var t = (Int32(v & 0x0f) << 3) + 0x84
        t <<= Int32((v & 0x70) >> 4)
        return Int16((v & 0x80) != 0 ? 0x84 - t : t - 0x84)
    }
}

/// O preset da track, lido do núcleo em vez de escrito à mão.
///
/// `quall_audio_preset_json` existe justamente para isto, e a §3 é dura no ponto: *"a tabela mora
/// em `TrackKind::preset_de_audio`. A canalização inteira lê dela — não há `if kind == Microphone`
/// espalhado pelo módulo."* Uma casca que fixasse 48 000/2/960 em constantes próprias seria o
/// quinto lugar onde o preset do fio e o do consumidor podem divergir em silêncio, que é
/// exatamente a classe de defeito da §11.
///
/// Decodificação **explícita, campo a campo**, com padrão quando a chave falta — a mesma
/// disciplina de `PedidoDeEspelhamento` em `Compartilhado.swift`, e pelo mesmo motivo: uma chave
/// nova no núcleo não pode fazer a leitura inteira lançar e deixar o produto sem som.
struct PresetDeAudioLido {
    var codec = "opus"
    var taxaHz: Int32 = 48_000
    var canais = 1
    var quadroMs = 20
    var amostrasPorQuadro = 960
    var bitrate = 0
    var fec = false
    var payloadType = 111
    var fmtp = ""

    /// Lê o preset da espécie **com o codec que a track de fato negociou**.
    ///
    /// Os dois argumentos são obrigatórios e a razão está em `CodecDeAudio::canais_no_fio`: pedir
    /// o preset de `SYSTEM_AUDIO` sem dizer o codec devolveria 2 canais mesmo numa sessão que
    /// negociou PCMU, onde o que anda no fio é mono.
    static func ler(especie: QuallTrackKind, codec: QuallAudioCodec) -> PresetDeAudioLido? {
        let precisa = quall_audio_preset_json(especie, codec, nil, 0)
        guard precisa > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(precisa))
        let n = buffer.withUnsafeMutableBufferPointer { p in
            quall_audio_preset_json(especie, codec, p.baseAddress, UInt(p.count))
        }
        guard n > 0 else { return nil }
        guard let dados = String(cString: buffer).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any]
        else { return nil }

        var p = PresetDeAudioLido()
        if let v = obj["codec"] as? String { p.codec = v }
        if let v = obj["sample_rate_hz"] as? Int { p.taxaHz = Int32(v) }
        if let v = obj["channels"] as? Int { p.canais = v }
        if let v = obj["frame_ms"] as? Int { p.quadroMs = v }
        if let v = obj["frame_samples"] as? Int { p.amostrasPorQuadro = v }
        if let v = obj["bitrate_bps"] as? Int { p.bitrate = v }
        if let v = obj["fec"] as? Bool { p.fec = v }
        if let v = obj["payload_type"] as? Int { p.payloadType = v }
        if let v = obj["fmtp"] as? String { p.fmtp = v }
        return p
    }

    var resumo: String {
        "\(codec) \(taxaHz) Hz \(canais)ch quadro=\(quadroMs) ms "
        + "(\(amostrasPorQuadro) amostras/canal) \(bitrate) bit/s fec=\(fec) pt=\(payloadType)"
    }
}
