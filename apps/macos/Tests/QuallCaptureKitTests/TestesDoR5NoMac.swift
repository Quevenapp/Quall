import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import QuallCaptureKit

/// As peças puras da fase 4 do R5 no Mac (`docs/teleprompter-com-camera.md` §8.9), testadas **sem
/// câmera e sem microfone**: nada aqui abre aparelho nenhum.
final class TestesDoR5NoMac: XCTestCase {

    // MARK: - a melhor imagem

    private func f(_ l: Int, _ a: Int, _ sub: UInt32 = FormatoOferecido.subtipo420v,
                   _ faixas: [(Double, Double)] = [(1, 30)]) -> FormatoOferecido {
        FormatoOferecido(largura: l, altura: a, subtipo: sub,
                         faixas: faixas.map { FormatoOferecido.Faixa(minima: $0.0, maxima: $0.1) })
    }

    func testeAMelhorImagemEhOMaiorTamanhoPadraoA30() {
        let lista = [f(640, 480), f(1280, 720), f(1920, 1080), f(1760, 1328), f(4032, 3024)]
        XCTAssertEqual(EscolhaDaMelhorImagem.escolher(lista, fps: 30), 2)
    }

    func testeSemFormatoA30NaoHaEscolha() {
        let lista = [f(1920, 1080, FormatoOferecido.subtipo420v, [(1, 15)])]
        XCTAssertNil(EscolhaDaMelhorImagem.escolher(lista, fps: 30))
        XCTAssertNil(EscolhaDaMelhorImagem.escolherComQueda(lista, fps: 60))
    }

    func testeA60CaiPara30QuandoNinguemFaz60() {
        let lista = [f(1280, 720, FormatoOferecido.subtipo420v, [(1, 60)]), f(1920, 1080)]
        XCTAssertEqual(EscolhaDaMelhorImagem.escolherComQueda(lista, fps: 60)?.indice, 0)
        let so30 = [f(1920, 1080)]
        let r = EscolhaDaMelhorImagem.escolherComQueda(so30, fps: 60)
        XCTAssertEqual(r?.indice, 0)
        XCTAssertEqual(r?.fps, 30)
    }

    /// A regra a mais do Mac: uma webcam USB sem 420 do tamanho padrão entra pelos outros subtipos
    /// (a saída converte); com um 420 do mesmo tamanho, o 420 vence.
    func testeNoMacOutroSubtipoEntraSoSemNenhum420() {
        let yuvs: UInt32 = 0x7975_7673 // 'yuvs'
        let mjpeg: UInt32 = 0x6A70_6567 // 'jpeg'
        let usb = [f(1920, 1080, yuvs), f(1280, 720, mjpeg)]
        XCTAssertNil(EscolhaDaMelhorImagem.escolher(usb, fps: 30))
        XCTAssertEqual(EscolhaDaMelhorImagem.escolher(usb, fps: 30, aceitarOutrosSubtipos: true), 0)
        let misto = [f(1920, 1080, yuvs), f(1280, 720)]
        // Existe 420 do tamanho padrão (720p): ele vence, mesmo menor.
        XCTAssertEqual(EscolhaDaMelhorImagem.escolher(misto, fps: 30, aceitarOutrosSubtipos: true), 1)
    }

    func testeNoEmpateVence420vEDepoisOPrimeiro() {
        let lista = [f(1920, 1080, FormatoOferecido.subtipo420f), f(1920, 1080), f(1920, 1080)]
        XCTAssertEqual(EscolhaDaMelhorImagem.escolher(lista, fps: 30), 1)
    }

    /// A lista de tamanhos padrão é a mesma do arquivo do iOS (a cópia não diverge em silêncio).
    func testeOsTamanhosPadraoSaoOsDoIOS() throws {
        let raiz = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ios = raiz.appendingPathComponent("ios/Quall/App/EscolhaDaMelhorImagem.swift")
        let texto = try String(contentsOf: ios, encoding: .utf8)
        XCTAssertTrue(texto.contains("[(1280, 720), (1920, 1080), (3840, 2160)]"),
                      "a lista de tamanhos do iOS mudou: mude a do Mac junto")
        XCTAssertEqual(EscolhaDaMelhorImagem.tamanhosPadrao.map { "\($0.maior)x\($0.menor)" },
                       ["1280x720", "1920x1080", "3840x2160"])
    }

    // MARK: - a política do microfone (G5)

    private let embutido = AparelhoDeAudio(uniqueID: "BuiltInMicrophoneDevice", nome: "Microfone do MacBook Air",
                                           transporte: AparelhoDeAudio.embutido)
    private let blackhole = AparelhoDeAudio(uniqueID: "BlackHole2ch_UID", nome: "BlackHole 2ch",
                                            transporte: AparelhoDeAudio.virtual)
    private let usb = AparelhoDeAudio(uniqueID: "AppleUSBAudioEngine:x", nome: "Microfone USB",
                                      transporte: AparelhoDeAudio.usb)
    private let agregado = AparelhoDeAudio(uniqueID: "agregado-1", nome: "Agregado",
                                           transporte: AparelhoDeAudio.agregado)

    func testeABancadaSemArgumentoNaoAbreNada() {
        let d = PoliticaDoMicrofone.decidir(.bancada(pedido: nil), aparelhos: [embutido, blackhole])
        guard case .recusar(let m) = d else { return XCTFail("abriu \(d)") }
        XCTAssertTrue(m.contains("--microfone="))
        guard case .recusar = PoliticaDoMicrofone.decidir(.bancada(pedido: ""), aparelhos: [blackhole]) else {
            return XCTFail("o vazio abriu")
        }
    }

    /// **O G5**: nem pedido pelo `uniqueID` o microfone do MacBook abre na bancada.
    func testeABancadaRecusaOEmbutidoMesmoPedido() {
        let d = PoliticaDoMicrofone.decidir(.bancada(pedido: embutido.uniqueID), aparelhos: [embutido, blackhole])
        guard case .recusar(let m) = d else { return XCTFail("o embutido abriu na bancada: \(d)") }
        XCTAssertTrue(m.contains("bltn"))
        XCTAssertTrue(m.contains("G5"))
    }

    func testeABancadaRecusaUsbAgregadoEDesconhecido() {
        for a in [usb, agregado, AparelhoDeAudio(uniqueID: "x", nome: "x", transporte: 0)] {
            let d = PoliticaDoMicrofone.decidir(.bancada(pedido: a.uniqueID), aparelhos: [a])
            guard case .recusar = d else { return XCTFail("\(a.nome) abriu na bancada") }
        }
    }

    func testeABancadaAceitaOVirtualPedidoSoComOLacoFechado() {
        XCTAssertEqual(PoliticaDoMicrofone.decidir(.bancada(pedido: blackhole.uniqueID, laco: blackhole.uniqueID),
                                                   aparelhos: [embutido, blackhole]),
                       .usar(blackhole))
        // Virtual, mas sem o nosso gerador tocando nele (um Krisp, um Loopback): recusado.
        guard case .recusar(let m) = PoliticaDoMicrofone.decidir(.bancada(pedido: blackhole.uniqueID),
                                                                aparelhos: [blackhole]) else {
            return XCTFail("um virtual sem o laço fechado abriu")
        }
        XCTAssertTrue(m.contains("--tom-no-dispositivo"))
        guard case .recusar = PoliticaDoMicrofone.decidir(.bancada(pedido: "sumiu"), aparelhos: [blackhole]) else {
            return XCTFail("um uid que não existe abriu")
        }
    }

    func testeNoProdutoOEscolhidoOuOPadrao() {
        XCTAssertEqual(PoliticaDoMicrofone.decidir(.produto(escolhido: usb.uniqueID), aparelhos: [embutido, usb]),
                       .usar(usb))
        XCTAssertEqual(PoliticaDoMicrofone.decidir(.produto(escolhido: "sumiu"), aparelhos: [embutido]),
                       .padraoDoSistema)
        XCTAssertEqual(PoliticaDoMicrofone.decidir(.produto(escolhido: nil), aparelhos: [embutido]), .padraoDoSistema)
    }

    func testeOsNomesDosTransportes() {
        XCTAssertEqual(embutido.nomeDoTransporte, "bltn")
        XCTAssertEqual(blackhole.nomeDoTransporte, "virt")
        XCTAssertEqual(usb.nomeDoTransporte, "usb")
        XCTAssertEqual(AparelhoDeAudio.nome(doTransporte: 0), "desconhecido")
    }

    // MARK: - a disciplina do carimbo do microfone

    /// Alimenta a disciplina com `segundos` de som a 48 kHz, em buffers de `bloco` amostras, com o
    /// PTS de cada buffer vindo de `pts(i)` (o índice da primeira amostra), e devolve os carimbos.
    private func correr(_ d: inout DisciplinaDoMicrofone, amostras total: Int, bloco: Int = 480,
                        pts: (Int) -> Double) -> [Int64] {
        var carimbos: [Int64] = []
        var i = 0
        while i < total {
            let n = min(bloco, total - i)
            let p = pts(i)
            _ = d.conferirContinuidade(pts: p, taxaDeEntrada: 48_000)
            d.acrescentar(pts: p, amostrasDeEntrada: n, taxaDeEntrada: 48_000,
                          convertidas: [Int16](repeating: 1, count: n))
            while let q = d.proximoQuadro() {
                XCTAssertEqual(q.quadro.count, 960)
                carimbos.append(q.carimboUs)
            }
            i += n
        }
        return carimbos
    }

    func testeOCarimboAnda20msExatosComOSomNoRelogio() {
        var d = DisciplinaDoMicrofone()
        let c = correr(&d, amostras: 48_000 * 3) { 100.0 + Double($0) / 48_000 }
        XCTAssertGreaterThan(c.count, 140)
        XCTAssertEqual(c.first, 100_000_000)
        for k in 1..<c.count { XCTAssertEqual(c[k] - c[k - 1], 20_000) }
        XCTAssertEqual(d.contadores.degraus, 0)
        XCTAssertEqual(d.contadores.inseridas, 0)
        XCTAssertEqual(d.contadores.tiradas, 0)
        XCTAssertLessThan(d.contadores.erroMaximoUs, 1)
    }

    /// O botão desligado e ligado (um buraco de 3 s no PTS): descontinuidade, e o carimbo pula **para
    /// a frente**, nunca para trás.
    func testeUmBuracoReancoraParaAFrente() {
        var d = DisciplinaDoMicrofone()
        let c = correr(&d, amostras: 48_000 * 4) { i in
            let t = Double(i) / 48_000
            return 10.0 + (t >= 2 ? t + 3 : t)
        }
        XCTAssertEqual(d.contadores.descontinuidades, 1)
        for k in 1..<c.count { XCTAssertGreaterThanOrEqual(c[k] - c[k - 1], 20_000) }
        XCTAssertTrue(c.contains { $0 >= 15_000_000 }, "o carimbo não seguiu o som depois do buraco")
    }

    /// O relógio do microfone 1 000 ppm mais lento que o da câmera: a correção de uma amostra por
    /// quadro segura o erro abaixo de ~1 ms, sem degrau.
    func testeADerivaEhTiradaPeloConteudo() {
        var d = DisciplinaDoMicrofone()
        _ = correr(&d, amostras: 48_000 * 20) { 5.0 + Double($0) / 48_000 * 1.001 }
        XCTAssertEqual(d.contadores.degraus, 0)
        XCTAssertGreaterThan(d.contadores.inseridas, 0)
        XCTAssertLessThan(abs(d.contadores.erroUs), 1_000)
    }

    func testeOCarimboNuncaVoltaNumRecomeco() {
        var d = DisciplinaDoMicrofone()
        let a = correr(&d, amostras: 48_000) { 50.0 + Double($0) / 48_000 }
        d.recomecar()
        // Um PTS **atrás** do último carimbo (um relógio que recuou): o carimbo não volta.
        let b = correr(&d, amostras: 48_000 * 3) { 49.0 + Double($0) / 48_000 }
        XCTAssertGreaterThan(b.first ?? 0, a.last ?? .max)
    }

    // MARK: - o tom de quatro notas

    func testeAsNotasSaoAsDaSondaEContinuasNaEmenda() {
        XCTAssertEqual(TomDeQuatroNotas.notasHz, [400, 500, 800, 1000])
        XCTAssertEqual(TomDeQuatroNotas.quadrosPorNota, 25)
        // O quadro por índice e a amostra por número absoluto dão o mesmo sinal.
        let q = TomDeQuatroNotas.quadro(indice: 30, amostrasPorCanal: 960, taxaHz: 48_000)
        for i in stride(from: 0, to: 960, by: 97) {
            let v = TomDeQuatroNotas.amostra(Int64(30 * 960 + i))
            XCTAssertEqual(Double(q[i]), Double(v) * Double(Int16.max), accuracy: 2)
        }
        // A troca de nota a cada 25 quadros: o quadro 24 é 400 Hz, o 25 é 500 Hz (cruzamentos).
        func cruzamentos(_ x: [Int16]) -> Int { zip(x, x.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count }
        XCTAssertEqual(cruzamentos(TomDeQuatroNotas.quadro(indice: 24, amostrasPorCanal: 960, taxaHz: 48_000)), 16, accuracy: 1)
        XCTAssertEqual(cruzamentos(TomDeQuatroNotas.quadro(indice: 25, amostrasPorCanal: 960, taxaHz: 48_000)), 20, accuracy: 1)
    }

    // MARK: - a gravação

    func testeATaxaEh14MbitsA1080p30() {
        XCTAssertEqual(TomadaDeGravacao.bitrate(largura: 1920, altura: 1080, fps: 30), 14_000_000)
        XCTAssertEqual(TomadaDeGravacao.bitrate(largura: 1280, altura: 720, fps: 30), 6_222_222)
        XCTAssertEqual(TomadaDeGravacao.bitrate(largura: 3840, altura: 2160, fps: 30), 50_000_000)
        XCTAssertEqual(TomadaDeGravacao.bitrate(largura: 640, altura: 480, fps: 30), 6_000_000)
    }

    // MARK: - o relógio do som

    /// O buffer de PCM nasce com o PTS pedido, e o deslocamento muda só os tempos (as amostras e a
    /// duração intactas): é a cópia que leva o som ao relógio da câmera.
    func testeDeslocarMudaSoOsTempos() throws {
        let pcm = (0..<1024).map { Int16($0 % 100) }
        let pts = CMTime(value: 480_000, timescale: 48_000)
        let b = try XCTUnwrap(DonoDaCamera.bufferDePCM(pcm, pts: pts, taxa: 48_000))
        XCTAssertEqual(CMSampleBufferGetNumSamples(b), 1024)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(b), pts)
        let d = try XCTUnwrap(DonoDaCamera.deslocar(b, por: CMTime(value: 3, timescale: 1000)))
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(d)), 10.003, accuracy: 1e-9)
        XCTAssertEqual(CMSampleBufferGetNumSamples(d), 1024)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetDuration(d)), CMTimeGetSeconds(CMSampleBufferGetDuration(b)),
                       accuracy: 1e-9)
        // O mesmo relógio dos dois lados: nenhum deslocamento.
        let host = CMClockGetHostTimeClock()
        let igual = try XCTUnwrap(DonoDaCamera.converter(b, de: host, para: host))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(igual), pts)
    }
}
