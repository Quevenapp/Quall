import XCTest
@testable import QuallCaptureKit

/// O que segura a cópia.
///
/// `TetoDoEmissor` é um **porte declarado** de `crates/quall-core/src/teto.rs` — a regra canônica
/// mora no núcleo, e esta casca não a consulta pela fronteira C por uma decisão de dependência
/// que o `Package.swift` já tinha tomado (ver o cabeçalho de `TetoDoEmissor`). Uma cópia sem
/// amarra é uma divergência esperando o calendário.
///
/// A amarra é a **tabela de vetores abaixo**, que é a mesma dos testes do núcleo. Se alguém mexer
/// num dos dois lados, isto fica vermelho — em vez de a divergência aparecer numa bancada seis
/// meses depois, que foi exatamente como o preset de áudio, o piso do PLI e a curva µ-law
/// cobraram o seu preço neste projeto.
///
/// **Como conferir contra o núcleo, à mão**, quando estes vetores mudarem:
///
///     cargo test -p quall-core --lib teto
///     cargo run -p quall-core --example teto
final class TestesDoTetoDoEmissor: XCTestCase {

    /// Os vetores compartilhados: entrada -> saída esperada. Cada linha é uma tela real desta
    /// bancada, ou um caso de borda que já mordeu.
    private struct Vetor {
        let porque: String
        let entrada: (Int, Int, Int32)
        let saida: (Int, Int, Int32)
        /// O teto de taxa, em bps, que o núcleo devolve para **esta saída**. Entrou em
        /// 02/09/2026: a geometria e a taxa são a mesma decisão, e mantê-las em tabelas separadas
        /// foi exatamente o que deixou o teto de taxa para trás quando o de resolução subiu.
        let taxa: Int
    }

    private let vetores: [Vetor] = [
        // **Vetores do nível 4.0, tirados do próprio núcleo em 01/09/2026.** Seis dos sete passam
        // inteiros agora; no 3.1 cinco encolhiam. O único que ainda é cortado é o MacBook.
        Vetor(porque: "720p30, que era o teto exato do 3.1, agora passa com folga de mais do dobro",
              entrada: (1280, 720, 30), saida: (1280, 720, 30), taxa: 4_000_000),
        Vetor(porque: "o mesmo tamanho a 60 fps: no 3.1 quem cortava era o MaxMBPS, no 4.0 é a política fpsMaximo",
              entrada: (1280, 720, 60), saida: (1280, 720, 30), taxa: 4_000_000),
        Vetor(porque: "a tela do Dell: 8160 macroblocos, cabe nos 8192 — o caso que a mudança existe para permitir",
              entrada: (1920, 1080, 30), saida: (1920, 1080, 30), taxa: 9_000_000),
        Vetor(porque: "a tela deste MacBook a 60 fps: 16640 macroblocos estouram até o 4.0, e continuam cortados",
              entrada: (2560, 1664, 60), saida: (1780, 1156, 30), taxa: 8_930_902),
        Vetor(porque: "o A10s alongado: 4275 macroblocos não cabiam no 3.1 e cabem no 4.0, sai nativo",
              entrada: (720, 1520, 30), saida: (720, 1520, 30), taxa: 4_750_000),
        Vetor(porque: "a tela do iPhone 7, em pé: 3948 macroblocos, passa nativa",
              entrada: (750, 1334, 30), saida: (750, 1334, 30), taxa: 4_342_447),
        Vetor(porque: "câmera pequena: sai como entrou, porque ampliar gastaria banda por nada",
              entrada: (640, 480, 30), saida: (640, 480, 30), taxa: 1_333_333),
    ]

    func testOsVetoresBatemComOsDoNucleo() {
        for v in vetores {
            let s = TetoDoEmissor.ajustar(largura: v.entrada.0, altura: v.entrada.1, fps: v.entrada.2)
            XCTAssertEqual([s.largura, s.altura, Int(s.fps)],
                           [v.saida.0, v.saida.1, Int(v.saida.2)],
                           "\(v.entrada.0)x\(v.entrada.1)@\(v.entrada.2): \(v.porque)")
            XCTAssertEqual(s.tetoDeTaxaBps, v.taxa,
                           "taxa de \(v.entrada.0)x\(v.entrada.1)@\(v.entrada.2): \(v.porque)")
        }
    }

    /// A frente de 02/09/2026 em duas linhas: 720p30 continua recebendo o valor de produto de
    /// sempre — a sessão que não cresceu é a mesma de antes —, e 1080p30 recebe os 2,25x que
    /// faltaram subir quando o teto de resolução subiu.
    func testATaxaAcompanhaAResolucao() {
        XCTAssertEqual(TetoDoEmissor.tetoDeTaxa(largura: 1280, altura: 720, fps: 30), 4_000_000)
        XCTAssertEqual(TetoDoEmissor.tetoDeTaxa(largura: 1920, altura: 1080, fps: 30), 9_000_000)
        // O MaxBR do nível é limite de norma: passar dele violaria o profile-level-id anunciado.
        XCTAssertEqual(TetoDoEmissor.tetoDeTaxa(largura: 3840, altura: 2160, fps: 30), 20_000_000)
        // E o piso do controlador, por baixo.
        XCTAssertEqual(TetoDoEmissor.tetoDeTaxa(largura: 160, altura: 120, fps: 15), 400_000)
    }

    /// O nível que o registro imprime tem de ser o nível que o SDP anuncia. `levelIdc` ficou em
    /// 31 por um dia enquanto `maxFS` e `maxMBPS` já eram os do 4.0 — registro que mente sobre o
    /// próprio nível é pior que registro nenhum.
    func testONivelDoRelatoEhODoTeto() {
        XCTAssertEqual(TetoDoEmissor.levelIdc, 40)
        let s = TetoDoEmissor.ajustar(largura: 1920, altura: 1080, fps: 30)
        let linha = TetoDoEmissor.relato(capturaLargura: 1920, capturaAltura: 1080,
                                         fpsPedido: 30, saida: s)
        XCTAssertTrue(linha.contains("4.0"), "o relato disse: \(linha)")
        XCTAssertTrue(linha.contains("9000 kbps"), "o relato disse: \(linha)")
    }

    /// O invariante inteiro, varrido sobre formas reais e absurdas. É o que impede um caso de
    /// borda de voltar em silêncio.
    func testASaidaSempreCabeEhParENuncaAmplia() {
        let larguras = [2, 320, 640, 720, 750, 1080, 1280, 1334, 1512, 1920, 2560, 3840, 5120]
        let alturas = [2, 240, 480, 720, 1080, 1280, 1520, 1664, 2160, 2880]
        for l in larguras {
            for a in alturas {
                let s = TetoDoEmissor.ajustar(largura: l, altura: a, fps: 60)
                let onde = "\(l)x\(a)"
                XCTAssertEqual(s.largura % 2, 0, "\(onde): largura ímpar não existe em 4:2:0")
                XCTAssertEqual(s.altura % 2, 0, "\(onde): altura ímpar não existe em 4:2:0")
                XCTAssertLessThanOrEqual(s.macroblocos, TetoDoEmissor.maxFS,
                                         "\(onde) -> \(s.largura)x\(s.altura) estourou o MaxFS")
                XCTAssertLessThanOrEqual(s.macroblocos * Int(s.fps), TetoDoEmissor.maxMBPS,
                                         "\(onde) estourou o MaxMBPS")
                XCTAssertLessThanOrEqual(s.largura, l, "\(onde) ampliou a largura")
                XCTAssertLessThanOrEqual(s.altura, a, "\(onde) ampliou a altura")
                XCTAssertGreaterThanOrEqual(s.fps, 1)
                XCTAssertLessThanOrEqual(s.fps, TetoDoEmissor.fpsMaximo)
            }
        }
    }

    /// A proporção é o que o receptor não tem como desfazer. Meio por cento de folga cobre o
    /// arredondamento para par; mais que isso é deformação.
    func testAProporcaoEhPreservada() {
        for (l, a) in [(1920, 1080), (2560, 1664), (720, 1520), (750, 1334), (1512, 982)] {
            let s = TetoDoEmissor.ajustar(largura: l, altura: a, fps: 30)
            let entrada = Double(l) / Double(a)
            let saida = Double(s.largura) / Double(s.altura)
            XCTAssertEqual(saida, entrada, accuracy: entrada * 0.01,
                           "\(l)x\(a) saiu \(s.largura)x\(s.altura), deformado")
        }
    }

    /// O ponto da conta em macroblocos contra a caixa de 1280x720, na tela que motivou a troca.
    /// A caixa daria 606x1280 = 38x80 = 3040 macroblocos; a conta da norma aproveita mais.
    func testATelaAlongadaAproveitaMaisQueACaixa() {
        let s = TetoDoEmissor.ajustar(largura: 720, altura: 1520, fps: 30)
        XCTAssertGreaterThan(s.macroblocos, 3_040)
        XCTAssertLessThanOrEqual(s.macroblocos, TetoDoEmissor.maxFS)
    }

    /// Dimensão que não é múltipla de 16 é o **caso comum**, e o teto tem de avisar em vez de
    /// deixar o roteiro de prova tropeçar nela — foi o que quase reprovou o iPhone X por estar
    /// certo.
    func testOAvisoDeRecorteEhHonesto() {
        // 1280x720: 80x45 macroblocos exatos, sem recorte.
        XCTAssertFalse(TetoDoEmissor.ajustar(largura: 1280, altura: 720, fps: 30).exigeRecorte)
        // 720x1520: 45x95 exatos — e **desde o nível 4.0 sai nativo**, então também não recorta.
        // No 3.1 ele encolhia para 652x1378 e recortava; o caso mudou de lado com o teto.
        XCTAssertFalse(TetoDoEmissor.ajustar(largura: 720, altura: 1520, fps: 30).exigeRecorte)
        // **O caso comum de recorte passou a ser o 1080p**, que o teto de 4.0 acabou de liberar:
        // 1080 / 16 = 67,5, o codificador emite 1088 e sinaliza `frame_cropping`. Quem não honrar
        // mostra 8 linhas de lixo no rodapé.
        XCTAssertTrue(TetoDoEmissor.ajustar(largura: 1920, altura: 1080, fps: 30).exigeRecorte)
    }

    func testEntradaImpossivelCaiNoConservador() {
        let s = TetoDoEmissor.ajustar(largura: 0, altura: 0, fps: 30)
        // O maior 16:9 inteiro que cabe no MaxFS do 4.0: 1792x1008 = 112x63 = 7056 macroblocos.
        XCTAssertEqual([s.largura, s.altura], [1792, 1008])
    }
}
