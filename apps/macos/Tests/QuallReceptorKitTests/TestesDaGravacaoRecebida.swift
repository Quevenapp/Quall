import AVFoundation
import CoreMedia
import XCTest
@testable import QuallReceptorKit

final class TestesDaGravacaoRecebida: XCTestCase {
    func testTelaRetomaEStopNaoRepeteIntervaloParado() async throws {
        let q = try XCTUnwrap(TestesDoDecodificador.codificar(quadros: 1, largura: 320, altura: 180).first)
        let base = ProcessInfo.processInfo.environment["QUALL_REC_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let pasta = base.appendingPathComponent("tela-retoma-\(UUID().uuidString)")
        let r = GravadorRecebido(), abriu = expectation(description: "armou"), fechou = expectation(description: "salvou")
        var armado = false, salvo = false, resultado = GravadorRecebido.Estado()
        r.aoEstado = { e in
            resultado = e
            if e.ativo, !armado { armado = true; abriu.fulfill() }
            if !e.ativo, !e.fechando, !e.arquivos.isEmpty, !salvo { salvo = true; fechou.fulfill() }
        }
        r.iniciar(nome: "tela-retoma", pasta: pasta, canais: nil)
        await fulfillment(of: [abriu], timeout: 3)
        q.bytes.withUnsafeBytes { r.quadro($0, timestampUs: 1_000_000, idr: true) }
        try await Task.sleep(nanoseconds: 500_000_000)
        q.bytes.withUnsafeBytes { r.quadro($0, timestampUs: 1_500_000, idr: true) }
        try await Task.sleep(nanoseconds: 20_000_000)
        r.parar(receberSomAtrasado: false)
        await fulfillment(of: [fechou], timeout: 10)
        let asset = AVURLAsset(url: try XCTUnwrap(resultado.arquivos.first))
        let duracao = try await asset.load(.duration)
        XCTAssertGreaterThan(duracao.seconds, 0.5)
        XCTAssertLessThan(duracao.seconds, 0.8, "the 500 ms pause belongs only to the previous frame")
    }

    func testTelaEstaticaMantemUltimoQuadroEAudioAteParar() async throws {
        let quadro = try XCTUnwrap(TestesDoDecodificador.codificar(quadros: 1, largura: 320, altura: 180).first)
        let base = ProcessInfo.processInfo.environment["QUALL_REC_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let pasta = base.appendingPathComponent("tela-estatica-\(UUID().uuidString)")
        let r = GravadorRecebido(), abriu = expectation(description: "armou"), fechou = expectation(description: "salvou")
        var armado = false, salvo = false, resultado = GravadorRecebido.Estado()
        r.aoEstado = { e in
            resultado = e
            if e.ativo, !armado { armado = true; abriu.fulfill() }
            if !e.ativo, !e.fechando, !e.arquivos.isEmpty, !salvo { salvo = true; fechou.fulfill() }
        }
        r.iniciar(nome: "tela-estatica", pasta: pasta, canais: 1)
        await fulfillment(of: [abriu], timeout: 3)
        r.relogios(video: 0, audio: 0)
        quadro.bytes.withUnsafeBytes { r.quadro($0, timestampUs: 1_000_000, idr: true) }
        let onda = (0..<960).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.25 }
        for i in 0..<800 {
            onda.withUnsafeBufferPointer { r.som($0.baseAddress!, amostras: $0.count, timestampUs: 1_000_000+UInt64(i)*20_000) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        r.parar(receberSomAtrasado: false)
        await fulfillment(of: [fechou], timeout: 10)
        let url = try XCTUnwrap(resultado.arquivos.first, resultado.mensagem)
        let asset = AVURLAsset(url: url)
        let duracao = try await asset.load(.duration)
        XCTAssertGreaterThan(duracao.seconds, 15.9)
        XCTAssertLessThan(duracao.seconds, 18.5, "saving must not add its 2-second audio grace period")
        let som = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(som.count, 1)
        let audioDuracao = try await som[0].load(.timeRange)
        XCTAssertGreaterThan(audioDuracao.duration.seconds, 15.9)
    }

    func testSomNegociadoDepoisCriaParteComAudio() async throws {
        let quadros = try TestesDoDecodificador.codificar(quadros: 60, largura: 320, altura: 180)
        let base = ProcessInfo.processInfo.environment["QUALL_REC_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let pasta = base.appendingPathComponent("som-tardio-\(UUID().uuidString)")
        let r = GravadorRecebido(), abriu = expectation(description: "armou"), fechou = expectation(description: "salvou")
        var armado = false, salvo = false, resultado = GravadorRecebido.Estado()
        r.aoEstado = { e in
            resultado = e
            if e.ativo, !armado { armado = true; abriu.fulfill() }
            if !e.ativo, !e.fechando, !e.arquivos.isEmpty, !salvo { salvo = true; fechou.fulfill() }
        }
        r.iniciar(nome: "som-tardio", pasta: pasta, canais: nil)
        await fulfillment(of: [abriu], timeout: 3)
        r.relogios(video: 0, audio: 0)
        var tempo: UInt64 = 1_000_000
        for etapa in 0..<2 {
            if etapa == 1 { r.configurarSom(canais: 1, atrasoAudioUs: 0) }
            for q in quadros {
                q.bytes.withUnsafeBytes { r.quadro($0, timestampUs: tempo, idr: q.idr) }
                if etapa == 1 {
                    let onda = (0..<960).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.25 }
                    onda.withUnsafeBufferPointer { r.som($0.baseAddress!, amostras: $0.count, timestampUs: tempo) }
                }
                tempo += 33_333
                try await Task.sleep(nanoseconds: 12_000_000)
            }
        }
        r.parar(receberSomAtrasado: false)
        await fulfillment(of: [fechou], timeout: 10)
        XCTAssertEqual(resultado.arquivos.count, 2, resultado.mensagem)
        guard resultado.arquivos.count == 2 else { return }
        let primeira = try await AVURLAsset(url: resultado.arquivos[0]).loadTracks(withMediaType: .audio)
        let segunda = try await AVURLAsset(url: resultado.arquivos[1]).loadTracks(withMediaType: .audio)
        XCTAssertTrue(primeira.isEmpty); XCTAssertEqual(segunda.count, 1)
    }

    func testPassagemH264AudioEPartesPorFormato() async throws {
        let primeiro = try TestesDoDecodificador.codificar(quadros: 60, largura: 320, altura: 180)
        let segundo = try TestesDoDecodificador.codificar(quadros: 60, largura: 480, altura: 270)
        let base = ProcessInfo.processInfo.environment["QUALL_REC_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let pasta = base.appendingPathComponent("recebido-\(UUID().uuidString)")
        let r = GravadorRecebido(), abriu = expectation(description: "armou"), fechou = expectation(description: "salvou")
        var armado = false, salvo = false, resultado = GravadorRecebido.Estado()
        r.aoEstado = { e in
            resultado = e
            if e.ativo, !armado { armado = true; abriu.fulfill() }
            if !e.ativo, !e.fechando, !e.arquivos.isEmpty, !salvo { salvo = true; fechou.fulfill() }
        }
        r.iniciar(nome: "emissor/sintético", pasta: pasta, canais: 1)
        await fulfillment(of: [abriu], timeout: 3)
        // Different rebased track clocks, same physical capture epoch. Audio must align by source.
        r.relogios(video: 50_000, audio: -950_000)
        var somTs: UInt64 = 2_000_000
        var tempo: UInt64 = 1_000_000
        for q in primeiro + segundo {
            q.bytes.withUnsafeBytes { r.quadro($0, timestampUs: tempo, idr: q.idr) }
            while somTs <= tempo + 1_000_000 {
                let onda = (0..<960).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.25 }
                onda.withUnsafeBufferPointer { r.som($0.baseAddress!, amostras: $0.count, timestampUs: somTs) }
                somTs += 20_000
            }
            tempo += 33_333
            try await Task.sleep(nanoseconds: 12_000_000)
        }
        r.parar()
        await fulfillment(of: [fechou], timeout: 10)
        XCTAssertEqual(resultado.arquivos.count, 2, resultado.mensagem)
        for (i, url) in resultado.arquivos.enumerated() {
            let a = AVURLAsset(url: url)
            let v = try await a.loadTracks(withMediaType: .video)
            let som = try await a.loadTracks(withMediaType: .audio)
            XCTAssertEqual(v.count, 1); XCTAssertEqual(som.count, 1)
            let tamanho = try await v[0].load(.naturalSize)
            XCTAssertEqual(Int(tamanho.width), i == 0 ? 320 : 480)
            let duracao = try await a.load(.duration)
            XCTAssertGreaterThan(duracao.seconds, 1.9)
            let leitor = try AVAssetReader(asset: a)
            let saida = AVAssetReaderTrackOutput(track: v[0], outputSettings: nil)
            leitor.add(saida); XCTAssertTrue(leitor.startReading())
            var n = 0, chaves = 0
            while let amostra = saida.copyNextSampleBuffer() {
                // AVAssetReader exposes fragment/edit-list empty samples too; those have no H264 AU.
                guard CMSampleBufferGetTotalSampleSize(amostra) > 0 else { continue }
                n += 1
                let anexo = (CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: false) as? [[String: Any]])?.first
                if (anexo?[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true { chaves += 1 }
            }
            XCTAssertEqual(n, 60, "every source frame must be stored without recoding")
            XCTAssertEqual(chaves, 2, "only IDR samples are seek points")
            XCTAssertEqual(leitor.status, .completed)
        }
        print("RECEIVED_RECORDING_SYNTHETIC_FILES=\(resultado.arquivos.map(\.path))")
    }

    func testPerdaDaReferenciaAguardaIdr() throws {
        let quadros = try TestesDoDecodificador.codificar(quadros: 60, largura: 320, altura: 180)
        var sps = Data(), fatias: [[Data]] = []
        for q in quadros {
            var f: [Data] = []
            q.bytes.withUnsafeBytes { b in DecodificadorH264.percorrerNals(b) { ini, n in
                let nal = Data(b[ini..<ini+n]), tipo = b[ini] & 31
                if tipo == 7 { sps = nal }; if tipo == 1 || tipo == 5 { f.append(nal) }
            }}
            fatias.append(f)
        }
        var guarda = ReferenciasH264Recebidas(sps: sps)
        for i in 0..<10 { XCTAssertFalse(guarda.rompeu(fatias[i], idr: quadros[i].idr)) }
        XCTAssertTrue(guarda.rompeu(fatias[11], idr: false), "a skipped reference must not enter the file")
        XCTAssertFalse(guarda.rompeu(fatias[30], idr: true))
        XCTAssertFalse(guarda.rompeu(fatias[31], idr: false))
        var invalido = ReferenciasH264Recebidas(sps: Data([0x67]))
        XCTAssertTrue(invalido.rompeu(fatias[1], idr: false))
    }
}
