import AudioToolbox
import Foundation
import Darwin

/// Testa o decoder do produto iOS contra o encoder do produto Mac e o AudioToolbox independente.
/// Não abre dispositivo de áudio, rede, câmera ou microfone, nem grava amostras.
@main
enum TestesDoAudio {
    private static var verificacoes = 0

    private static func conferir(_ condicao: @autoclosure () -> Bool, _ mensagem: String) {
        verificacoes += 1
        guard condicao() else { fatalError("FALHA: \(mensagem)") }
    }

    private static func pcm(_ decoder: DecodificadorDeAudio, _ bytes: [UInt8],
                            ordem: QuallAudioOrder = QUALL_AUDIO_ORDER_FRAME,
                            lbrr: Int8 = -1) -> [Int16]? {
        bytes.withUnsafeBytes { decoder.traduzir(ordem: ordem, payload: $0, temLbrr: lbrr) }
    }

    static func main() throws {
        setbuf(stdout, nil)
        // O cenário que falhava: a espécie SYSTEM_AUDIO, sozinha, resolve para Opus; o codec
        // anunciado pelo Mac muda relógio, canais e tamanho do slot do receptor.
        let presumido = PresetDeAudioLido.ler(especie: QUALL_TRACK_KIND_SYSTEM_AUDIO,
                                               codec: QUALL_AUDIO_CODEC_DEFAULT)!
        let p = PresetDeAudioLido.ler(especie: QUALL_TRACK_KIND_SYSTEM_AUDIO,
                                       codec: QUALL_AUDIO_CODEC_PCMU)!
        conferir(presumido.codec == "opus" && presumido.taxaHz == 48_000,
                 "controle negativo: DEFAULT não descreve PCMU")
        conferir(p.codec == "pcmu" && p.taxaHz == 8_000 && p.canais == 1
                 && p.amostrasPorQuadro == 160, "preset PCMU deve ser 8kHz/mono/160")
        conferir(DecodificadorDeAudio(codec: QUALL_AUDIO_CODEC_DEFAULT, taxaHz: 48_000,
                                      canais: 2, amostrasPorQuadro: 960) == nil,
                 "codec desconhecido deve recusar em vez de presumir Opus")
        conferir(DecodificadorDeAudio(codec: QUALL_AUDIO_CODEC_PCMU, taxaHz: 48_000,
                                      canais: 2, amostrasPorQuadro: 960) == nil,
                 "PCMU com formato de Opus deve recusar")
        let decoder = DecodificadorDeAudio(codec: QUALL_AUDIO_CODEC_PCMU, taxaHz: p.taxaHz,
                                           canais: p.canais, amostrasPorQuadro: p.amostrasPorQuadro)!

        // TODOS os octetos G.711 contra outra implementação, inclusive 0x00, 0x7f e 0xff.
        let octetos = (0...255).map(UInt8.init)
        let referencia = try expandirPeloAudioToolbox(octetos)
        conferir(referencia.count == 256, "referência deve devolver todas as amostras")
        for (i, byte) in octetos.enumerated() {
            conferir(DecodificadorDeAudio.linearPCMU(byte) == referencia[i],
                     "G.711 divergiu do AudioToolbox no octeto \(byte)")
        }
        conferir(pcm(decoder, [UInt8](repeating: 0xff, count: 160)) == [Int16](repeating: 0, count: 160),
                 "0xff é silêncio PCMU, com 160 amostras")
        conferir(pcm(decoder, [UInt8](repeating: 0x00, count: 160))?.allSatisfy { $0 == -32124 } == true,
                 "octetos zero são nível negativo alto, não silêncio")

        // PCMU pode ter um TOC aparentemente válido. O SDP determina o codec; inspeção Opus
        // não pode classificar este pacote como Opus nem remontar o consumidor para 48kHz/2ch.
        var enganaTOC = [UInt8](repeating: 0xff, count: 160)
        enganaTOC[0] = 0xfc
        enganaTOC.withUnsafeBufferPointer { b in
            conferir(opus_packet_get_nb_channels(b.baseAddress) == 2
                     && opus_packet_get_nb_frames(b.baseAddress, Int32(b.count)) > 0
                     && opus_packet_get_samples_per_frame(b.baseAddress, 48_000) > 0,
                     "controle negativo PCMU deve passar pela inspeção TOC Opus")
        }
        let foiPCMU = pcm(decoder, enganaTOC)!
        conferir(foiPCMU.count == 160 && foiPCMU[0] == referencia[0xfc]
                 && foiPCMU.dropFirst().allSatisfy { $0 == 0 },
                 "payload com TOC aparente deve continuar PCMU mono/8kHz")
        print("ok: negociação explícita e 256 octetos G.711 contra AudioToolbox")

        // O emissor real do Mac entrega as quatro notas sintéticas; mede-se o vetor decodificado
        // pelo iOS. Errar o relógio por 6, tocar silêncio ou repetir a última nota reprova.
        let encoderMac = CodificadorPCMU(preset: .audioDoSistema(codec: .pcmu))
        let analisador = AnalisadorDeTom(taxaHz: 8_000, canais: 1)
        let presumiuOpus = DecodificadorDeAudio(codec: QUALL_AUDIO_CODEC_OPUS, taxaHz: 48_000,
                                               canais: 2, amostrasPorQuadro: 960)!
        defer { presumiuOpus.fechar() }
        let tomErrado = AnalisadorDeTom(taxaHz: 48_000, canais: 2)
        var falhasDaPresuncao = 0
        for indice in 0..<100 {
            let origem = TomSintetico.quadro(indice: indice, amostrasPorCanal: 160,
                                             taxaHz: 8_000, canais: 1)
            let pacotes = encoderMac.codificar(origem)
            conferir(pacotes.count == 1 && pacotes[0].count == 160,
                     "encoder Mac deve produzir um slot PCMU de 160 bytes")
            let resultado = pacotes[0].withUnsafeBytes {
                decoder.traduzir(ordem: QUALL_AUDIO_ORDER_FRAME, payload: $0, temLbrr: -1)
            }!
            conferir(resultado.count == 160, "decoder iOS deve manter a duração 20ms a 8kHz")
            analisador.medir(resultado)
            pacotes[0].withUnsafeBytes {
                if let erro = presumiuOpus.traduzir(ordem: QUALL_AUDIO_ORDER_FRAME, payload: $0, temLbrr: -1) {
                    tomErrado.medir(erro)
                } else { falhasDaPresuncao += 1 }
            }
        }
        let tom = analisador.instantaneo()
        conferir(tom.verde && tom.notasVistas == 4 && tom.trocas == 3, "quatro notas do Mac devem chegar")
        conferir(!tomErrado.instantaneo().verde, "presumir Opus para PCMU deve reprovar o controle negativo")
        print(String(format: "ok: Mac PCMU → decoder iOS; 100 slots, notas=%d trocas=%llu razão=%.4f rms=%.4f",
                     tom.notasVistas, tom.trocas, tom.razaoMedia, tom.rms))
        print("ok: controle negativo PCMU interpretado como Opus reprovou; falhas_decode=\(falhasDaPresuncao)/100")

        // Perda PCMU não reproduz o sucessor duas vezes e não inventa FEC. Os tamanhos inválidos
        // voltam como falha ao chamador, que mantém o DAC com silêncio explícito do mesmo slot.
        let silencio = decoder.traduzir(ordem: QUALL_AUDIO_ORDER_SILENCE, payload: nil, temLbrr: -1)!
        conferir(silencio.count == 160 && silencio.allSatisfy { $0 == 0 }, "perda PCMU vira silêncio de 20ms")
        let fec = pcm(decoder, enganaTOC, ordem: QUALL_AUDIO_ORDER_FEC, lbrr: 1)!
        conferir(fec.count == 160 && fec.allSatisfy { $0 == 0 }, "PCMU não tem FEC")
        for tamanho in [0, 159, 161] {
            conferir(pcm(decoder, [UInt8](repeating: 0xff, count: tamanho)) == nil,
                     "comprimento PCMU inválido \(tamanho) deve ser contado e recusado")
        }
        let c = decoder.instantaneo()
        conferir(c.falhas == 3 && c.ultimaFalha == -1001 && c.curadosPorFec == 0
                 && c.ocultados == 2 && c.socorroSemLbrr == 1, "contadores PCMU devem descrever perdas e falhas")
        decoder.fechar()
        decoder.fechar()
        conferir(pcm(decoder, enganaTOC) == nil, "decoder fechado não pode reutilizar PCM")
        print("ok: perda, FEC indisponível, pacotes vazios/curtos/longos e fechamento PCMU")

        // Regressão do codec usado pelo Android/iOS e pelo microfone Mac: o encoder do núcleo
        // e o decoder do produto iOS mantêm Opus nos formatos mono e estéreo.
        for especie in [QUALL_TRACK_KIND_MICROPHONE, QUALL_TRACK_KIND_SYSTEM_AUDIO] {
            let o = PresetDeAudioLido.ler(especie: especie, codec: QUALL_AUDIO_CODEC_OPUS)!
            let d = DecodificadorDeAudio(codec: QUALL_AUDIO_CODEC_OPUS, taxaHz: o.taxaHz,
                                        canais: o.canais, amostrasPorQuadro: o.amostrasPorQuadro)!
            let encoder = quall_audio_encoder_new(especie, QUALL_AUDIO_CODEC_OPUS)!
            defer { quall_audio_encoder_free(encoder); d.fechar() }
            let detector = AnalisadorDeTom(taxaHz: Double(o.taxaHz), canais: o.canais)
            for indice in 0..<100 {
                let origem = TomSintetico.quadro(indice: indice, amostrasPorCanal: o.amostrasPorQuadro,
                                                 taxaHz: Double(o.taxaHz), canais: o.canais)
                var pacote = [UInt8](repeating: 0, count: 4000)
                let n = origem.withUnsafeBufferPointer { entrada in
                    pacote.withUnsafeMutableBufferPointer { saida in
                        quall_audio_encoder_encode(encoder, entrada.baseAddress, UInt(entrada.count),
                                                   saida.baseAddress, UInt(saida.count))
                    }
                }
                conferir(n > 0, "encoder Opus do núcleo deve produzir pacote")
                pacote.removeSubrange(Int(n)..<pacote.count)
                let resultado = pcm(d, pacote)!
                conferir(resultado.count == o.amostrasPorQuadro * o.canais, "duração/canais Opus devem permanecer")
                detector.medir(resultado)
                if indice == 99 {
                    let antes = d.instantaneo()
                    let ocultacao = pcm(d, pacote, ordem: QUALL_AUDIO_ORDER_FEC, lbrr: -1)!
                    conferir(ocultacao.count == resultado.count && d.instantaneo().curadosPorFec == antes.curadosPorFec,
                             "LBRR desconhecido não pode contar como cura")
                    conferir(pcm(d, [])?.count == resultado.count, "Opus vazio deve usar PLC sem chamar decode_fec")
                }
            }
            conferir(detector.instantaneo().verde, "regressão Opus \(o.canais)ch deve manter as quatro notas")
            conferir(d.instantaneo().falhas == 0, "Opus não deve registrar falha de decode")
            print("ok: Opus \(o.canais)ch/\(o.taxaHz)Hz/\(o.amostrasPorQuadro) amostras, 100 slots")
        }
        print("PASSOU: \(verificacoes) verificações; sem rede ou dispositivo de áudio")
    }

    private static func expandirPeloAudioToolbox(_ bytes: [UInt8]) throws -> [Int16] {
        var entrada = AudioStreamBasicDescription(
            mSampleRate: 8000, mFormatID: kAudioFormatULaw, mFormatFlags: 0,
            mBytesPerPacket: 1, mFramesPerPacket: 1, mBytesPerFrame: 1,
            mChannelsPerFrame: 1, mBitsPerChannel: 8, mReserved: 0)
        var saida = AudioStreamBasicDescription(
            mSampleRate: 8000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var conversor: AudioConverterRef?
        let criou = AudioConverterNew(&entrada, &saida, &conversor)
        guard criou == noErr, let conversor else { throw NSError(domain: "AudioConverterNew", code: Int(criou)) }
        defer { AudioConverterDispose(conversor) }
        var resultado = [Int16](repeating: 0, count: bytes.count)
        var tamanho = UInt32(resultado.count * 2)
        let estado = bytes.withUnsafeBytes { origem in
            resultado.withUnsafeMutableBytes { destino in
                AudioConverterConvertBuffer(conversor, UInt32(origem.count), origem.baseAddress!,
                                            &tamanho, destino.baseAddress!)
            }
        }
        guard estado == noErr else { throw NSError(domain: "AudioConverterConvertBuffer", code: Int(estado)) }
        return Array(resultado.prefix(Int(tamanho) / 2))
    }
}
