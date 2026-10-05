import AVFoundation
import XCTest
@testable import QuallCaptureKit

/// O caminho que refaz o `AVAudioConverter` quando o formato da origem muda no meio da sessão.
///
/// # Por que este teste existe
///
/// Porque aquela linha foi **escrita por raciocínio e nunca executada**, e o modo de falhar dela é
/// o pior que este projeto conhece: `docs/audio.md` §2 — *"não dá erro; dá áudio que acelera ou
/// arrasta sem contador nenhum acusando"*. Uma troca de dispositivo de saída no meio de uma
/// transmissão (um adaptador USB-HDMI plugado, um fone, a TV que some) é exatamente o evento que
/// percorre essa linha, e ele acontece uma vez a cada muitas horas de bancada — cedo demais para
/// confiar, tarde demais para descobrir.
///
/// **O que este teste NÃO substitui**: ele prova que a remontagem está correta *quando acontece*.
/// Ele não prova que o ScreenCaptureKit de fato muda o formato numa troca de dispositivo — isso é
/// pergunta de máquina, medida com o cabo na mão, e está registrada em `docs/app-macos.md`.
///
/// Nada aqui captura, toca ou grava som: as duas origens são senoides fabricadas em memória.
final class TestesDoConversorDeAudio: XCTestCase {

    private static let preset = PresetDeAudio.audioDoSistema(codec: .pcmu)

    // MARK: - o achado

    /// **A remontagem acontece, é contada, e o som continua certo do outro lado.**
    ///
    /// A origem muda de "48 kHz, 2 canais, float32, não intercalado" — o que o ScreenCaptureKit
    /// entrega — para "44,1 kHz, 1 canal", que é o que um dispositivo de saída diferente pode
    /// impor. As duas tocam **a mesma nota**. Se a remontagem não acontecesse, o conversor
    /// continuaria dividindo por 48 000 um fluxo que agora corre a 44 100, e a nota sairia
    /// deslocada em ~9% — audível, e invisível em todo contador que existe.
    func testeARemontagemAcontecEOTomSobreviveATrocaDeFormato() throws {
        let conversor = try XCTUnwrap(ConversorDeAudio(preset: Self.preset))
        var frequencias: [Double] = []
        conversor.aoRefazer = { de, para in
            XCTAssertNotEqual(de, para, "remontou sem o formato ter mudado")
        }

        let antes = try Self.senoide(hz: 440, formato: Self.formato(taxa: 48_000, canais: 2), segundos: 0.5)
        let saidaAntes = conversor.converter(antes)
        XCTAssertEqual(conversor.reconstrucoes, 0, "a primeira montagem não é uma remontagem")
        XCTAssertEqual(conversor.falhas, 0)
        XCTAssertFalse(saidaAntes.isEmpty)
        frequencias.append(Self.frequencia(saidaAntes, taxa: Self.preset.taxaDeAmostragem))

        // A troca. É esta chamada que percorre a linha que nunca tinha rodado.
        let depois = try Self.senoide(hz: 440, formato: Self.formato(taxa: 44_100, canais: 1), segundos: 0.5)
        let saidaDepois = conversor.converter(depois)
        XCTAssertEqual(conversor.reconstrucoes, 1, "o formato mudou e o conversor NÃO foi refeito")
        XCTAssertEqual(conversor.falhas, 0, "a remontagem falhou e o silêncio seria mudo")
        XCTAssertFalse(saidaDepois.isEmpty, "depois da remontagem não saiu amostra nenhuma")
        frequencias.append(Self.frequencia(saidaDepois, taxa: Self.preset.taxaDeAmostragem))

        // A nota tem de ser a mesma nas duas, porque foi a mesma nota nas duas origens.
        for (i, f) in frequencias.enumerated() {
            XCTAssertEqual(f, 440, accuracy: 12,
                           "bloco \(i): saiu \(f) Hz para um tom de 440 — o relógio da conversão está errado")
        }
    }

    /// **Voltar ao formato de antes conta como outra remontagem.**
    ///
    /// É o caso real: o cabo é plugado (uma troca) e depois puxado (outra). Um conversor que só
    /// se refizesse "para formatos que nunca viu" ficaria preso no formato do meio.
    func testeVoltarAoFormatoAnteriorTambemRefaz() throws {
        let conversor = try XCTUnwrap(ConversorDeAudio(preset: Self.preset))
        let a = Self.formato(taxa: 48_000, canais: 2)
        let b = Self.formato(taxa: 44_100, canais: 1)

        _ = conversor.converter(try Self.senoide(hz: 1000, formato: a, segundos: 0.3))
        _ = conversor.converter(try Self.senoide(hz: 1000, formato: b, segundos: 0.3))
        let volta = conversor.converter(try Self.senoide(hz: 1000, formato: a, segundos: 0.3))

        XCTAssertEqual(conversor.reconstrucoes, 2)
        XCTAssertEqual(conversor.falhas, 0)
        // A segunda frequência de prova, e ela não é decoração: `docs/app-macos.md` §7b registra
        // que a primeira versão do medidor de frequência *confirmava a expectativa* com um tom só
        // e se denunciava com dois. Um instrumento novo é exercitado com dois valores.
        XCTAssertEqual(Self.frequencia(volta, taxa: Self.preset.taxaDeAmostragem), 1000, accuracy: 25)
    }

    /// **Um bloco no mesmo formato não refaz nada.**
    ///
    /// Importa porque a comparação é por campo e não pelo dicionário `settings`: refazer o
    /// conversor a cada bloco jogaria fora o estado do reamostrador 50 vezes por segundo, o que
    /// produz um estalo por bloco — e nenhum contador acusaria isso também.
    func testeBlocosNoMesmoFormatoNaoRefazemOConversor() throws {
        let conversor = try XCTUnwrap(ConversorDeAudio(preset: Self.preset))
        let formato = Self.formato(taxa: 48_000, canais: 2)
        for _ in 0..<20 {
            _ = conversor.converter(try Self.senoide(hz: 440, formato: formato, segundos: 0.02))
        }
        XCTAssertEqual(conversor.reconstrucoes, 0)
        XCTAssertEqual(conversor.falhas, 0)
    }

    /// A comparação de formatos, no nível em que ela decide.
    func testeMesmoFormatoOlhaAsQuatroCoisasQueImportam() {
        let base = Self.formato(taxa: 48_000, canais: 2)
        XCTAssertTrue(ConversorDeAudio.mesmoFormato(base, Self.formato(taxa: 48_000, canais: 2)))
        XCTAssertFalse(ConversorDeAudio.mesmoFormato(base, Self.formato(taxa: 44_100, canais: 2)))
        XCTAssertFalse(ConversorDeAudio.mesmoFormato(base, Self.formato(taxa: 48_000, canais: 1)))
    }

    // MARK: - as origens sintéticas

    /// O formato que o ScreenCaptureKit entrega: float32 não intercalado.
    private static func formato(taxa: Double, canais: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: taxa, channels: canais)!
    }

    private static func senoide(hz: Double, formato: AVAudioFormat, segundos: Double) throws -> AVAudioPCMBuffer {
        let quadros = AVAudioFrameCount(formato.sampleRate * segundos)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: quadros))
        buffer.frameLength = quadros
        let canais = try XCTUnwrap(buffer.floatChannelData)
        let passo = 2 * Double.pi * hz / formato.sampleRate
        for c in 0..<Int(formato.channelCount) {
            for i in 0..<Int(quadros) {
                canais[c][i] = Float(sin(passo * Double(i))) * 0.25
            }
        }
        return buffer
    }

    /// Frequência por disparador de Schmitt — a mesma forma que `TransmissaoAoVivo` usa, e pela
    /// mesma razão: contar trocas de sinal com limiar de silêncio descarta justamente os
    /// cruzamentos, que numa senoide são pequenos por definição (`docs/app-macos.md` §7b).
    private static func frequencia(_ amostras: [Int16], taxa: Double) -> Double {
        let limiar: Int16 = 2000
        var acima = false
        var subidas = 0
        var primeira = -1
        var ultima = -1
        for (i, v) in amostras.enumerated() {
            if !acima, v > limiar {
                acima = true
                subidas += 1
                if primeira < 0 { primeira = i }
                ultima = i
            } else if acima, v < -limiar {
                acima = false
            }
        }
        guard subidas > 1, ultima > primeira else { return 0 }
        let ciclos = Double(subidas - 1)
        let segundos = Double(ultima - primeira) / taxa
        return ciclos / segundos
    }
}
