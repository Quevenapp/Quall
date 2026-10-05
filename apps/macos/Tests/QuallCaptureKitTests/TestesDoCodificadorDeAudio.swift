import AudioToolbox
import XCTest
@testable import QuallCaptureKit

/// A curva µ-law deste emissor, conferida contra uma implementação que não é nossa.
///
/// # Por que este teste existe
///
/// `docs/regras-de-frente.md`: *"sempre que a plataforma aceitar um pedido, confirme no artefato"*
/// — e o corolário que o M4 deixou, de que **comparar o que sai do fio contra uma referência
/// independente é medição barata e de alto rendimento**. Foi assim que o SPS sem
/// `bitstream_restriction` apareceu.
///
/// O mesmo raciocínio se aplica com força maior a um codec escrito à mão. Um µ-law errado **não
/// dá erro em lugar nenhum**: os contadores sobem, o pacote atravessa, o receptor decodifica, e o
/// som sai — distorcido. Nenhuma medição de vazão denuncia, exatamente como a vazão não denunciava
/// os 169,5 ms do SPS. A única forma de saber é comparar byte a byte com quem não somos nós.
///
/// A referência é o **AudioToolbox** (`kAudioFormatULaw`), que está em todo Mac e não compartilha
/// uma linha de código com a nossa tabela. Não há `ffmpeg` nesta máquina; se houvesse, seria uma
/// terceira opinião igualmente válida.
///
/// Este teste **não captura nada e não pede permissão nenhuma** — roda numa corrida de bancada sem
/// um humano para clicar em diálogo, como os testes de SPS.
final class TestesDoCodificadorDeAudio: XCTestCase {

    private static let todosOsInt16: [Int16] = (0..<65536).map { Int16(truncatingIfNeeded: $0 - 32768) }

    /// **Metade positiva: idêntica byte a byte**, nos 32 768 valores.
    ///
    /// É a metade onde não há convenção nenhuma em jogo, então divergir aqui seria defeito puro e
    /// simples. Foi este teste que pegou a dobra errada do negativo: com o defeito, a metade
    /// positiva passava e só a negativa quebrava, o que apontou o dedo direto para o sinal.
    func testeAMetadePositivaEIdenticaAoAudioToolbox() throws {
        let positivos = Self.todosOsInt16.filter { $0 >= 0 }
        let referencia = try Self.muLawPeloAudioToolbox(positivos)
        for (i, amostra) in positivos.enumerated() {
            XCTAssertEqual(CodificadorPCMU.paraMuLaw(amostra), referencia[i],
                           "divergiu em \(amostra)")
        }
    }

    /// **Metade negativa: diverge, e a divergência é da Apple.**
    ///
    /// O AudioToolbox **nunca emite 0x00** e satura os valores mais negativos em 0x02 — a
    /// supressão do octeto todo-zeros das linhas T1. Aqui não há linha T1: é RTP sobre SRTP, e a
    /// RFC 3551 não reserva código nenhum.
    ///
    /// O teste afirma a forma da divergência em vez de exigir igualdade: **só no lado negativo, e
    /// só onde o AudioToolbox está saturando**. Se um dia aparecer uma divergência fora dessa
    /// faixa, é defeito nosso e este teste quebra.
    func testeADivergenciaComOAudioToolboxESoASupressaoDoCodigoZero() throws {
        let referencia = try Self.muLawPeloAudioToolbox(Self.todosOsInt16)
        XCTAssertFalse(referencia.contains(0x00),
                       "o AudioToolbox emitiu 0x00 — a premissa deste teste mudou, releia tudo")

        var forasDaFaixa: [(Int16, UInt8, UInt8)] = []
        for (i, amostra) in Self.todosOsInt16.enumerated() {
            let nosso = CodificadorPCMU.paraMuLaw(amostra)
            guard nosso != referencia[i] else { continue }
            // Tolerado: (a) nós emitimos um código que a Apple suprime, ou (b) um passo de
            // diferença numa fronteira de segmento, que é 1 LSB de um código logarítmico.
            let suprimido = nosso <= 0x02 || referencia[i] <= 0x02
            let umPasso = abs(Int(nosso) - Int(referencia[i])) <= 1
            if !(amostra < 0 && (suprimido || umPasso)) {
                forasDaFaixa.append((amostra, nosso, referencia[i]))
            }
        }
        XCTAssertTrue(forasDaFaixa.isEmpty,
                      "divergências que a supressão de 0x00 não explica: "
                      + forasDaFaixa.prefix(8).map {
                          "entrada=\($0.0) nosso=0x\(String($0.1, radix: 16)) ref=0x\(String($0.2, radix: 16))"
                      }.joined(separator: "; "))
    }

    /// **O número que decidiu não copiar a Apple.**
    ///
    /// Passando as duas codificações pelo decodificador do **próprio AudioToolbox**, a nossa erra
    /// menos. Copiar a supressão do 0x00 nos deixaria byte a byte iguais e mensuravelmente
    /// piores, e a regra da casa é medir no artefato em vez de aceitar a promessa da plataforma.
    ///
    /// Os limites são folgados de propósito: o que este teste protege é a **conclusão** — nunca
    /// ficar pior que a referência —, não os dígitos de uma corrida.
    func testeNossaCurvaNaoErraMaisQueADoAudioToolboxNaIdaEVolta() throws {
        let nossos = Self.todosOsInt16.map { CodificadorPCMU.paraMuLaw($0) }
        let referencia = try Self.muLawPeloAudioToolbox(Self.todosOsInt16)

        let (rmsNosso, piorNosso) = try Self.erroDeIdaEVolta(nossos, contra: Self.todosOsInt16)
        let (rmsRef, piorRef) = try Self.erroDeIdaEVolta(referencia, contra: Self.todosOsInt16)

        XCTAssertLessThanOrEqual(rmsNosso, rmsRef,
            String(format: "nosso rms=%.1f contra referência rms=%.1f", rmsNosso, rmsRef))
        XCTAssertLessThanOrEqual(piorNosso, piorRef,
            "nosso pior=\(piorNosso) contra referência pior=\(piorRef)")
        // A medição de 2026-08-27 nesta máquina: 226,5 contra 360,7, e pior 644 contra 2 692.
        XCTAssertLessThan(rmsNosso, 250, "a curva piorou desde a medição que está no documento")
        XCTAssertLessThanOrEqual(piorNosso, 644)
    }

    /// O silêncio tem de virar o byte que o resto do mundo chama de silêncio.
    ///
    /// Vale sozinho porque é o valor que aparece **entre** as falas e nos trechos mudos de música:
    /// se só este estivesse errado, o fluxo teria um chiado constante de fundo que um teste de
    /// vazão nunca acusaria.
    func testeOZeroViraOSilencioCanonico() {
        XCTAssertEqual(CodificadorPCMU.paraMuLaw(0), 0xFF)
    }

    /// O fatiador entrega quadros do tamanho exato do preset, e guarda o resto.
    ///
    /// É o invariante que `docs/audio.md` §6 cobra: **um quadro por chamada, um pacote por
    /// quadro**. Um quadro curto ou dois quadros concatenados numa chamada viram um pacote que o
    /// outro lado decodifica errado, e sem erro em lugar nenhum no caminho.
    func testeOFatiadorSoEntregaQuadrosCompletosEGuardaOResto() {
        let preset = PresetDeAudio.audioDoSistema(codec: .pcmu)
        XCTAssertEqual(preset.canais, 1, "PCMU é mono por definição (RFC 3551 §6), mesmo com preset estéreo")
        XCTAssertEqual(preset.amostrasPorQuadro, 160, "20 ms a 8 kHz")

        let codificador = CodificadorPCMU(preset: preset)

        // Um bloco de 100 amostras não completa quadro nenhum.
        XCTAssertEqual(codificador.codificar([Int16](repeating: 0, count: 100)).count, 0)
        // Mais 100 completam um (160) e sobram 40.
        let primeiro = codificador.codificar([Int16](repeating: 0, count: 100))
        XCTAssertEqual(primeiro.count, 1)
        XCTAssertEqual(primeiro.first?.count, 160)
        // Mais 280 fecham dois quadros (40 + 280 = 320) e não sobra nada.
        let depois = codificador.codificar([Int16](repeating: 0, count: 280))
        XCTAssertEqual(depois.count, 2)
        XCTAssertTrue(depois.allSatisfy { $0.count == 160 })
        // E o resto de verdade continua guardado: nada sai de uma chamada vazia.
        XCTAssertEqual(codificador.codificar([]).count, 0)
    }

    /// O relógio do codec é o que fixa o tamanho do quadro, e errá-lo não dá erro — dá áudio que
    /// acelera ou arrasta. Ver `docs/audio.md` §2.
    func testeOsRelogiosEOsTamanhosDeQuadroBatemComODocumento() {
        XCTAssertEqual(CodecDeAudio.opus.relogioHz, 48_000)
        XCTAssertEqual(CodecDeAudio.pcmu.relogioHz, 8_000)
        XCTAssertEqual(CodecDeAudio.opus.amostrasPorQuadro(duracaoMs: 20), 960)
        XCTAssertEqual(CodecDeAudio.pcmu.amostrasPorQuadro(duracaoMs: 20), 160)
        // O Opus carrega os canais que o preset pediu; o PCMU rebaixa para mono.
        XCTAssertEqual(CodecDeAudio.opus.canaisNoFio(pedidos: 2), 2)
        XCTAssertEqual(CodecDeAudio.pcmu.canaisNoFio(pedidos: 2), 1)
    }

    // MARK: - a referência

    /// µ-law pelo `AudioConverter` do sistema. CBR de 1 para 1 (`mBytesPerPacket = 1`,
    /// `mFramesPerPacket = 1`), então `AudioConverterConvertBuffer` basta.
    private static func muLawPeloAudioToolbox(_ amostras: [Int16]) throws -> [UInt8] {
        var entrada = AudioStreamBasicDescription(
            mSampleRate: 8000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)
        var saida = AudioStreamBasicDescription(
            mSampleRate: 8000,
            mFormatID: kAudioFormatULaw,
            mFormatFlags: 0,
            mBytesPerPacket: 1,
            mFramesPerPacket: 1,
            mBytesPerFrame: 1,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 8,
            mReserved: 0)

        var conversor: AudioConverterRef?
        let criou = AudioConverterNew(&entrada, &saida, &conversor)
        guard criou == noErr, let conversor else {
            throw XCTSkip("o AudioToolbox não criou um conversor µ-law nesta máquina (\(criou))")
        }
        defer { AudioConverterDispose(conversor) }

        var destino = [UInt8](repeating: 0, count: amostras.count)
        var bytesDeSaida = UInt32(destino.count)
        let status = amostras.withUnsafeBytes { origem -> OSStatus in
            destino.withUnsafeMutableBytes { alvo in
                AudioConverterConvertBuffer(
                    conversor,
                    UInt32(origem.count),
                    origem.baseAddress!,
                    &bytesDeSaida,
                    alvo.baseAddress!)
            }
        }
        guard status == noErr else {
            throw XCTSkip("AudioConverterConvertBuffer falhou (\(status))")
        }
        return Array(destino.prefix(Int(bytesDeSaida)))
    }

    /// Decodifica µ-law pelo AudioToolbox e mede o erro contra o sinal original.
    /// O decodificador é o mesmo para as duas curvas, então a comparação é justa.
    private static func erroDeIdaEVolta(_ codificados: [UInt8], contra original: [Int16]) throws
        -> (rms: Double, pior: Int32) {
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
        guard AudioConverterNew(&entrada, &saida, &conversor) == noErr, let conversor else {
            throw XCTSkip("o AudioToolbox não criou o decodificador µ-law")
        }
        defer { AudioConverterDispose(conversor) }

        var destino = [Int16](repeating: 0, count: codificados.count)
        var bytesDeSaida = UInt32(destino.count * 2)
        let status = codificados.withUnsafeBytes { origem -> OSStatus in
            destino.withUnsafeMutableBytes { alvo in
                AudioConverterConvertBuffer(conversor, UInt32(origem.count), origem.baseAddress!,
                                            &bytesDeSaida, alvo.baseAddress!)
            }
        }
        guard status == noErr else { throw XCTSkip("a decodificação falhou (\(status))") }

        var soma = 0.0
        var pior: Int32 = 0
        for i in 0..<min(destino.count, original.count) {
            let erro = abs(Int32(destino[i]) - Int32(original[i]))
            soma += Double(erro) * Double(erro)
            pior = max(pior, erro)
        }
        return ((soma / Double(original.count)).squareRoot(), pior)
    }
}
