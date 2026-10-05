import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest

@testable import QuallCaptureKit

/// O que se prova aqui é bitstream, e bitstream se prova no Mac mesmo: `swift test`, sem aparelho e
/// sem simulador. A prova de aparelho — celular emitindo para a câmera virtual do Windows — é outra
/// coisa e está em `docs/bancada.md`.
///
/// Os SPS usados como referência não são inventados: são os três que foram **capturados da rede** em
/// 2026-08-24 com `quall-probe receber-video`, um por emissor.
final class TestesDoRemendoDeSPS: XCTestCase {

    /// macOS VideoToolbox com origem `420v`: 10 bytes, sem VUI nenhum.
    static let spsVideoToolbox420v = bytes("2742001fab402802dc80")
    /// macOS VideoToolbox com origem `420f`: 14 bytes, **com** VUI (faixa cheia, cor 2/2/2) e
    /// `bitstream_restriction_flag = 0`. É o caso que uma regra do tipo "se já tem VUI eu não
    /// encosto" deixaria quebrado.
    static let spsVideoToolbox420f = bytes("2742001fab402802dd3702020202")
    /// **iPhone 7, iOS 15.8.8**, capturado da rede em 2026-08-22 (tela e câmera dão o mesmo SPS).
    /// O VideoToolbox do iOS **não** se comporta como o do macOS: aqui ele emite VUI de 14 bytes e
    /// declara a cor certa (709, faixa limitada) — e mesmo assim deixa
    /// `bitstream_restriction_flag = 0`. É a forma real do caminho 2, achada num arquivo que já
    /// estava no disco, sem custar um toque de bancada.
    static let spsIPhone7 = bytes("2742001fab405a050d3501010102")
    /// Samsung A07, MediaCodec: já declara tudo.
    static let spsMediaCodec = bytes("6742001f8d8d40780b74d40404041e1108d4")
    /// Dell G3, NVENC: já declara a restrição (e não declara cor).
    static let spsNvenc = bytes("6742c01f95a014016e8400000fa00003a9803c70aa80")

    static func bytes(_ hexa: String) -> [UInt8] {
        stride(from: 0, to: hexa.count, by: 2).map {
            let i = hexa.index(hexa.startIndex, offsetBy: $0)
            return UInt8(hexa[i...hexa.index(i, offsetBy: 1)], radix: 16)!
        }
    }
    static func hexa(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func lido(_ b: [UInt8]) -> RemendoDeSPS.Analise? {
        RemendoDeSPS.analisar(RemendoDeSPS.desescapar(Array(b.dropFirst())))
    }

    // MARK: - o conserto em si

    func testSemVuiGanhaVuiInteiro() throws {
        let sinal = RemendoDeSPS.SinalDeVideo(faixaCheia: false, cor: .bt709)
        let novo = try RemendoDeSPS.comVui(Self.spsVideoToolbox420v, sinal: sinal).get()
        let a = try XCTUnwrap(lido(novo))
        XCTAssertTrue(a.temVui)
        XCTAssertEqual(a.maxNumReorderFrames, 0, "é o campo que conserta a latência")
        XCTAssertEqual(a.maxDecFrameBuffering, 1, "tem que seguir max_num_ref_frames, que é 1")
        XCTAssertEqual(a.sinal, sinal)
        // o prefixo passou intacto
        let antes = try XCTUnwrap(lido(Self.spsVideoToolbox420v))
        XCTAssertEqual(a.largura, antes.largura)
        XCTAssertEqual(a.altura, antes.altura)
        XCTAssertEqual(a.perfil, antes.perfil)
        XCTAssertEqual(a.nivel, antes.nivel)
        XCTAssertEqual(a.maxNumRefFrames, antes.maxNumRefFrames)
        XCTAssertEqual(Self.hexa(novo), "2742001fab402802dd3501010107844235")
    }

    func testVuiSemRestricaoGanhaSoARestricao() throws {
        let antes = try XCTUnwrap(lido(Self.spsVideoToolbox420f))
        XCTAssertTrue(antes.temVui)
        XCTAssertNil(antes.maxDecFrameBuffering, "o VideoToolbox escreve VUI e não escreve restrição")

        // De propósito um sinal contraditório com o que já está no fluxo: este caminho não pode
        // escutá-lo. O que o VideoToolbox declarou tem que passar bit a bit.
        let novo = try RemendoDeSPS.comVui(Self.spsVideoToolbox420f,
                                           sinal: .init(faixaCheia: false, cor: .bt709)).get()
        let a = try XCTUnwrap(lido(novo))
        XCTAssertEqual(a.sinal, antes.sinal, "o video_signal_type original tem que sobreviver")
        XCTAssertEqual(a.maxNumReorderFrames, 0)
        XCTAssertEqual(a.maxDecFrameBuffering, 1)
        XCTAssertEqual(a.largura, 1280)
        XCTAssertEqual(a.altura, 720)
    }

    /// O caso de aparelho de verdade: o iPhone 7 já traz VUI com a cor certa e sem a restrição.
    /// O remendo tem de **acrescentar só a restrição** e não encostar na cor — se ele reescrevesse
    /// o `video_signal_type`, trocaria uma declaração correta por uma vinda de outro lugar.
    func testIPhone7GanhaSoARestricao() throws {
        let antes = try XCTUnwrap(lido(Self.spsIPhone7))
        XCTAssertEqual(antes.largura, 720)
        XCTAssertEqual(antes.altura, 1280, "é o retrato que o M4 do Windows ainda não viu de aparelho")
        XCTAssertEqual(antes.sinal, .init(faixaCheia: false, cor: .bt709))
        XCTAssertNil(antes.maxDecFrameBuffering, "o defeito de latência está aqui")

        // Sinal contraditório de propósito: o caminho 2 não pode escutá-lo.
        let novo = try RemendoDeSPS.comVui(Self.spsIPhone7, sinal: .init(faixaCheia: true, cor: nil)).get()
        let a = try XCTUnwrap(lido(novo))
        XCTAssertEqual(a.sinal, antes.sinal, "a cor que o iOS declarou tem de passar intacta")
        XCTAssertEqual(a.largura, 720)
        XCTAssertEqual(a.altura, 1280)
        XCTAssertEqual(a.maxNumReorderFrames, 0)
        XCTAssertEqual(a.maxDecFrameBuffering, 1)
        XCTAssertEqual(Self.hexa(novo), "2742001fab405a050d3501010107844235")
    }

    func testQuemJaDeclaraNaoEhTocado() {
        for (nome, sps) in [("A07 MediaCodec", Self.spsMediaCodec), ("Dell NVENC", Self.spsNvenc)] {
            switch RemendoDeSPS.comVui(sps, sinal: .init(faixaCheia: false, cor: .bt709)) {
            case .success: XCTFail("\(nome): reescreveu um SPS que já declarava a restrição")
            case .failure(let e):
                XCTAssertTrue(e.description.contains("já declara"), "\(nome): \(e.description)")
            }
        }
    }

    func testSemSinalNaoDeclaraCor() throws {
        let novo = try RemendoDeSPS.comVui(Self.spsVideoToolbox420v, sinal: nil).get()
        let a = try XCTUnwrap(lido(novo))
        XCTAssertNil(a.sinal, "não declarar é melhor do que chutar")
        XCTAssertEqual(a.maxDecFrameBuffering, 1, "a restrição sai de qualquer jeito")
    }

    func testFaixaSemCorConhecida() throws {
        let novo = try RemendoDeSPS.comVui(Self.spsVideoToolbox420v,
                                           sinal: .init(faixaCheia: true, cor: nil)).get()
        let a = try XCTUnwrap(lido(novo))
        XCTAssertEqual(a.sinal, .init(faixaCheia: true, cor: nil))
        XCTAssertEqual(a.maxDecFrameBuffering, 1)
    }

    /// `max_dec_frame_buffering >= max_num_ref_frames` é exigência da norma. Como o valor é lido do
    /// próprio SPS, a desigualdade vale por construção — mas vale conferir que vale.
    func testDpbSegueOsQuadrosDeReferencia() throws {
        for refs in 0...8 {
            var w = RemendoDeSPS.Escritor()
            w.u(66, 8); w.u(0, 8); w.u(31, 8); w.ue(0)
            w.ue(1); w.ue(0); w.ue(2)
            w.ue(UInt32(refs)); w.flag(false)
            w.ue(79); w.ue(44); w.flag(true)
            w.flag(true); w.flag(false)
            w.flag(false); w.fecharRbsp()
            let sps = [UInt8(0x27)] + RemendoDeSPS.escapar(w.bytes)
            let novo = try RemendoDeSPS.comVui(sps, sinal: nil).get()
            let a = try XCTUnwrap(lido(novo))
            XCTAssertEqual(a.maxDecFrameBuffering, refs, "refs=\(refs)")
            XCTAssertEqual(a.maxNumReorderFrames, 0, "refs=\(refs)")
        }
    }

    // MARK: - não falhar para o lado ruim

    func testLixoNaoViraSps() {
        for (nome, b) in [("PPS", Self.bytes("68ce3c80")), ("vazio", [UInt8]()),
                          ("truncado", Self.bytes("274200")), ("só cabeçalho", Self.bytes("27"))] {
            if case .success = RemendoDeSPS.comVui(b, sinal: nil) {
                XCTFail("\(nome): aceitou o que não é SPS válido")
            }
        }
    }

    /// A invariante que de fato importa, e que vale para **qualquer** entrada aceita: o prefixo sai
    /// bit a bit igual ao que entrou. É por isso que o remendo copia bits em vez de reserializar
    /// campos — nenhuma sutileza do prefixo depende de eu ter entendido o campo.
    ///
    /// (Um bloco de 0x27 repetido é sintaticamente um SPS: cabeçalho tipo 7 e campos que casam.
    /// Uma primeira versão deste teste exigia que fosse recusado, o que era exigência errada — o
    /// remendo não é validador de fluxo, e o SPS de entrada sempre vem da format description do
    /// VideoToolbox. O que ele deve é não corromper.)
    func testOPrefixoSaiIntacto() throws {
        let entradas: [(String, [UInt8])] = [
            ("VideoToolbox 420v", Self.spsVideoToolbox420v),
            ("VideoToolbox 420f", Self.spsVideoToolbox420f),
            ("iPhone 7", Self.spsIPhone7),
            ("0x27 repetido", [UInt8](repeating: 0x27, count: 40)),
        ]
        for (nome, entrada) in entradas {
            guard case .success(let novo) = RemendoDeSPS.comVui(entrada, sinal: .init(faixaCheia: true, cor: .bt709))
            else { continue }
            let antes = try XCTUnwrap(lido(entrada), nome)
            // No caminho sem VUI a emenda é no flag do VUI; no caminho com VUI, no flag da
            // restrição. Tudo antes do ponto de emenda tem que ser idêntico.
            let corte = antes.temVui ? try XCTUnwrap(antes.bitDoFlagDeRestricao, nome) : antes.bitDoFlagDeVui
            let a = RemendoDeSPS.desescapar(Array(entrada.dropFirst()))
            let b = RemendoDeSPS.desescapar(Array(novo.dropFirst()))
            for k in 0..<corte {
                let bitA = (a[k >> 3] >> (7 - (k & 7))) & 1
                let bitB = (b[k >> 3] >> (7 - (k & 7))) & 1
                XCTAssertEqual(bitA, bitB, "\(nome): o bit \(k) do prefixo mudou")
            }
            XCTAssertEqual(novo.first, entrada.first, "\(nome): o cabeçalho do NAL mudou")
        }
    }

    func testOCacheEDevolucaoDoOriginal() {
        let r = RemendoDeSPS()
        let sinal = RemendoDeSPS.SinalDeVideo(faixaCheia: false, cor: .bt709)
        let a = Self.spsVideoToolbox420v.withUnsafeBytes { r.spsParaEnviar($0, sinal: sinal) }
        let b = Self.spsVideoToolbox420v.withUnsafeBytes { r.spsParaEnviar($0, sinal: sinal) }
        XCTAssertEqual(a, b)
        XCTAssertTrue(r.reescrito)
        // Um SPS que não dá para remendar volta como veio — nunca vazio, nunca truncado.
        let c = Self.spsMediaCodec.withUnsafeBytes { r.spsParaEnviar($0, sinal: sinal) }
        XCTAssertEqual(c, Self.spsMediaCodec)
        XCTAssertFalse(r.reescrito)
    }

    // MARK: - bits

    func testAntiEmulacaoIdaEVolta() {
        let cru: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 2, 0, 0, 3, 0, 0, 4, 0, 0]
        XCTAssertEqual(RemendoDeSPS.desescapar(RemendoDeSPS.escapar(cru)), cru)
    }

    func testExpGolomb() {
        var e = RemendoDeSPS.Escritor()
        let valores: [UInt32] = [0, 1, 2, 16, 255, 65535]
        for v in valores { e.ue(v) }
        e.u(5, 3)
        e.fecharRbsp()
        var l = RemendoDeSPS.Leitor(e.bytes)
        for v in valores { XCTAssertEqual(l.ue(), v) }
        XCTAssertEqual(l.u(3), 5)
    }

    // MARK: - o VideoToolbox de verdade

    /// Não é teste de unidade: é o encoder real desta máquina, com a configuração real dos
    /// emissores, alimentado com um padrão gerado aqui mesmo — nenhuma tela, nenhuma câmera. O que
    /// se afirma é que o remendo pega o SPS que o VideoToolbox **de fato** produz hoje.
    func testContraOVideoToolboxDestaMaquina() throws {
        for (formato, nome) in [(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "420v"),
                                (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "420f")] {
            let (sps, sinal) = try codificarUmIdr(formato: formato)
            let antes = try XCTUnwrap(lido(sps), nome)
            if antes.maxDecFrameBuffering != nil {
                // O VideoToolbox passou a declarar sozinho: o remendo tem que sair de cena, e este
                // teste vira o aviso de que a nota em `RemendoDeSPS` envelheceu.
                XCTAssertNotNil(RemendoDeSPS.comVui(sps, sinal: sinal).failureValue, nome)
                continue
            }
            let novo = try RemendoDeSPS.comVui(sps, sinal: sinal).get()
            let a = try XCTUnwrap(lido(novo), nome)
            XCTAssertEqual(a.maxNumReorderFrames, 0, nome)
            XCTAssertEqual(a.maxDecFrameBuffering, Int(antes.maxNumRefFrames), nome)
            XCTAssertEqual(a.largura, 1280, nome)
            XCTAssertEqual(a.altura, 720, nome)
        }
    }

    private func codificarUmIdr(formato: OSType) throws -> ([UInt8], RemendoDeSPS.SinalDeVideo?) {
        var criada: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(
            allocator: nil, width: 1280, height: 720, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &criada), noErr)
        let s = try XCTUnwrap(criada)
        defer { VTCompressionSessionInvalidate(s) }
        for (k, v) in [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
                       (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
                       (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel),
                       (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 30))] {
            VTSessionSetProperty(s, key: k, value: v)
        }
        VTCompressionSessionPrepareToEncodeFrames(s)

        var px: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, formato, nil, &px)
        let imagem = try XCTUnwrap(px)
        CVPixelBufferLockBaseAddress(imagem, [])
        // padrão sintético, gerado aqui: um gradiente e croma neutro.
        let y = CVPixelBufferGetBaseAddressOfPlane(imagem, 0)!.assumingMemoryBound(to: UInt8.self)
        let passoY = CVPixelBufferGetBytesPerRowOfPlane(imagem, 0)
        for r in 0..<720 { for c in 0..<1280 { y[r * passoY + c] = UInt8((r &+ c) & 0xFF) } }
        let uv = CVPixelBufferGetBaseAddressOfPlane(imagem, 1)!.assumingMemoryBound(to: UInt8.self)
        let passoUV = CVPixelBufferGetBytesPerRowOfPlane(imagem, 1)
        for r in 0..<360 { for c in 0..<1280 { uv[r * passoUV + c] = 128 } }
        CVPixelBufferUnlockBaseAddress(imagem, [])

        let espera = expectation(description: "um IDR")
        var achado: [UInt8]?
        VTCompressionSessionEncodeFrame(
            s, imageBuffer: imagem, presentationTimeStamp: CMTime(value: 0, timescale: 30),
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { estado, _, amostra in
            defer { espera.fulfill() }
            guard estado == noErr, let amostra,
                  let fd = CMSampleBufferGetFormatDescription(amostra) else { return }
            var p: UnsafePointer<UInt8>?
            var tamanho = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fd, parameterSetIndex: 0, parameterSetPointerOut: &p, parameterSetSizeOut: &tamanho,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p else { return }
            achado = [UInt8](UnsafeBufferPointer(start: p, count: tamanho))
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        wait(for: [espera], timeout: 20)
        return (try XCTUnwrap(achado), RemendoDeSPS.SinalDeVideo.doPixelBuffer(imagem))
    }

    // MARK: - as quatro cópias

    /// `RemendoDeSPS.swift` vive em quatro alvos de build diferentes. Se alguém consertar um e
    /// esquecer os outros três, o defeito volta para metade dos emissores — e volta calado.
    func testAsQuatroCopiasSaoIguais() throws {
        let raiz = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuallCaptureKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // raiz do repositório
        let copias = [
            "apps/macos/Sources/QuallCaptureKit/RemendoDeSPS.swift",
            "integrations/camera-macos/Fontes/App/RemendoDeSPS.swift",
            "apps/ios/Quall/Comum/RemendoDeSPS.swift",
            "apps/ios/PortaoAppex/Comum/RemendoDeSPS.swift",
        ]
        let canonica = try Data(contentsOf: raiz.appendingPathComponent(copias[0]))
        for c in copias.dropFirst() {
            let outra = try Data(contentsOf: raiz.appendingPathComponent(c))
            XCTAssertEqual(canonica, outra, "\(c) divergiu de \(copias[0])")
        }
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
