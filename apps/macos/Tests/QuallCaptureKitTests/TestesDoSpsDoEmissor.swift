import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest

@testable import QuallCaptureKit

/// **O que este emissor declara no fio**, medido no caminho de produção e não no papel.
///
/// `TestesDoRemendoDeSPS` prova o remendo contra SPS de referência capturados da rede — ele
/// responde "dado este SPS, a reescrita está certa?". Este arquivo responde a outra pergunta, que
/// nenhum teste do projeto respondia: **o SPS que o `H264Encoder` do app de fato emite chega ao
/// outro lado declarando a restrição?** Entre uma coisa e outra há três peças que podem se
/// desencontrar em silêncio — a configuração da `VTCompressionSession`, o `AnnexB.convert` que
/// decide quando chamar o remendo, e o remendo em si.
///
/// A regra que isto defende está em `docs/regras-de-frente.md`: *fazer a coisa certa e não
/// declarar custa o mesmo que fazer errado*. O VideoToolbox é configurado com
/// `AllowFrameReordering = false` em todos os emissores Apple do Quall — não reordena quadro
/// nenhum —, mas o SPS que ele emite tem **10 bytes e nenhum VUI**. O decodificador do outro
/// lado, sem `bitstream_restriction`, é obrigado a assumir o teto do nível e segura ~5 quadros
/// antes de entregar o primeiro: **169,5 ms de p50 contra 0,55 ms**. E a vazão não denuncia — 30
/// fps limpos de qualquer jeito. Só a latência muda, e ela some numa medição de throughput.
///
/// # Por que isto pode rodar aqui, e a captura não
///
/// Não há captura nenhuma neste teste: o quadro de entrada é um `CVPixelBuffer` fabricado. Logo
/// não há TCC de Gravação de Tela nem de Câmera, e `swift test` roda sem um humano para clicar em
/// diálogo nenhum. É a única prova de bitstream do emissor macOS que não depende de permissão —
/// e, por tabela, a única que não tem como esbarrar na regra de nunca renderizar um quadro cuja
/// origem seja a tela do usuário.
final class TestesDoSpsDoEmissor: XCTestCase {

    /// Um quadro com conteúdo, e **em faixa de vídeo (`420v`)** — que é o que
    /// `ScreenCapturer`/`CameraCapturer` pedem às respectivas APIs. O pixel format importa: o
    /// VideoToolbox deriva a sinalização VUI de faixa de cor do buffer de entrada, não de uma
    /// propriedade da sessão. Pedir `420f` aqui testaria um caminho que o produto não usa.
    ///
    /// `IOSurface` é obrigatório: sem ele o VideoToolbox recusa o encoder de hardware e o teste
    /// passaria a medir o encoder de software, que é outro programa.
    private func quadroDeTeste(largura: Int, altura: Int, semente: Int) -> CVPixelBuffer? {
        var pixels: CVPixelBuffer?
        let atributos: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, largura, altura,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            atributos as CFDictionary, &pixels) == kCVReturnSuccess,
            let buffer = pixels else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        // Luma: um degradê que anda com a semente. Conteúdo chapado faria o encoder produzir
        // quadros degenerados e um IDR minúsculo — o SPS sairia igual, mas o teste estaria
        // medindo um caso que o produto nunca vê.
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let passo = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let bytes = luma.assumingMemoryBound(to: UInt8.self)
            for y in 0..<altura {
                for x in 0..<largura {
                    // Faixa limitada de verdade: 16..235, não 0..255.
                    bytes[y * passo + x] = UInt8(16 + ((x + y + semente * 7) % 220))
                }
            }
        }
        if let croma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let passo = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let bytes = croma.assumingMemoryBound(to: UInt8.self)
            for y in 0..<(altura / 2) {
                for x in 0..<largura {
                    bytes[y * passo + x] = UInt8(16 + ((x * 3 + semente) % 200))
                }
            }
        }
        return buffer
    }

    /// Extrai o primeiro NAL de tipo 7 (SPS) de um Annex-B, já sem o start code.
    private func spsDe(_ fluxo: Data) -> [UInt8]? {
        let b = [UInt8](fluxo)
        var i = 0
        var inicios: [Int] = []
        while i + 3 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 1 {
                inicios.append(i + 4)
                i += 4
            } else {
                i += 1
            }
        }
        for (n, comeco) in inicios.enumerated() {
            guard comeco < b.count else { continue }
            guard (b[comeco] & 0x1F) == 7 else { continue }
            let fim = n + 1 < inicios.count ? inicios[n + 1] - 4 : b.count
            return Array(b[comeco..<fim])
        }
        return nil
    }

    func testeOSpsEmitidoDeclaraQueNaoHaReordenacao() throws {
        let largura = 640, altura = 360, fps: Int32 = 30

        let encoder: H264Encoder
        do {
            encoder = try H264Encoder(width: Int32(largura), height: Int32(altura), fps: fps, preset: .screen)
        } catch {
            throw XCTSkip("VideoToolbox não criou sessão de compressão nesta máquina: \(error)")
        }

        let trava = NSLock()
        var saidas: [Data] = []
        let esperando = expectation(description: "o encoder entregou pelo menos um IDR")
        esperando.assertForOverFulfill = false

        for n in 0..<6 {
            guard let quadro = quadroDeTeste(largura: largura, altura: altura, semente: n) else {
                XCTFail("não consegui fabricar o CVPixelBuffer de entrada")
                return
            }
            let pts = CMTime(value: CMTimeValue(n), timescale: fps)
            encoder.encode(pixelBuffer: quadro, presentationTimeStamp: pts,
                           duration: CMTime(value: 1, timescale: fps)) { dados, _, ehChave in
                trava.lock()
                saidas.append(dados)
                trava.unlock()
                if ehChave { esperando.fulfill() }
            }
        }
        encoder.finish()
        wait(for: [esperando], timeout: 10)

        trava.lock()
        let todas = saidas
        trava.unlock()
        XCTAssertFalse(todas.isEmpty, "o encoder não entregou quadro nenhum")

        // O SPS vem do **primeiro** quadro entregue com parameter sets, que é o IDR de abertura —
        // exatamente o que atravessa a rede antes da primeira imagem.
        guard let sps = todas.compactMap({ spsDe($0) }).first else {
            XCTFail("nenhum SPS no fluxo Annex-B produzido — sem ele o receptor não monta imagem")
            return
        }

        // `analisar` trabalha sobre o RBSP desescapado e **sem** o byte de cabeçalho do NAL.
        guard let analise = RemendoDeSPS.analisar(RemendoDeSPS.desescapar(Array(sps.dropFirst()))) else {
            XCTFail("não consegui reler o SPS emitido (\(sps.count) bytes)")
            return
        }

        XCTAssertEqual(analise.largura, largura, "o SPS descreve outra largura")
        XCTAssertEqual(analise.altura, altura, "o SPS descreve outra altura")

        // O coração do teste. Não basta o VUI existir: a pergunta certa não é "tem VUI?", é
        // "declara a restrição?" — a primeira versão do remendo errou exatamente nisso e deixou
        // metade do defeito de pé, porque o VideoToolbox com origem `420f` **escreve** um VUI com
        // `bitstream_restriction_flag = 0`.
        XCTAssertNotNil(analise.bitDoFlagDeRestricao,
                        "o SPS emitido não declara bitstream_restriction — o decodificador do "
                        + "outro lado vai assumir o teto do nível e segurar quadros")
        XCTAssertEqual(analise.maxNumReorderFrames, 0,
                       "este emissor não reordena quadro nenhum (AllowFrameReordering = false); "
                       + "o SPS tem de dizer isso")
        XCTAssertEqual(analise.maxDecFrameBuffering, 1,
                       "sem isto o receptor empilha até o teto do nível antes da primeira imagem")

        XCTAssertTrue(encoder.resumoDoSPS.contains("reescrito"),
                      "o remendo desistiu em silêncio: \(encoder.resumoDoSPS)")
    }

    /// O encoder do produto tem de sair no bloco de mídia, não na CPU. Se cair para software, o
    /// número de latência do projeto inteiro passa a medir outra coisa — e a queda é silenciosa.
    func testeOEncoderDoProdutoSaiEmHardware() throws {
        let encoder: H264Encoder
        do {
            encoder = try H264Encoder(width: 1280, height: 720, fps: 30, preset: .screen)
        } catch {
            throw XCTSkip("VideoToolbox não criou sessão de compressão nesta máquina: \(error)")
        }
        defer { encoder.finish() }
        XCTAssertEqual(encoder.backend, .hardware,
                       "encoder resolvido: \(encoder.encoderName)")
    }
}
