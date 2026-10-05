import AVFoundation
import XCTest
@testable import QuallReceptorKit

/// O som do receptor macOS contra um DAC simulado (S4 do `docs/som-no-receptor.md`).
///
/// Sem rede e sem o `.a`: a porta puxada é uma fonte falsa que numera cada slot, e o "dispositivo"
/// é quem chama o render — ora o ``MontadorDeSaida`` direto, com o quantum que o teste escolhe, ora
/// o ``Tocador`` em modo manual (fonte → `AUVarispeed`), **sem unidade de E/S nenhuma**: estes testes
/// não passam pela checagem de microfone do TCC, que o `AVAudioEngine` disparava (crítica 9, M1).
final class TestesDoSomPuxado: XCTestCase {

    // MARK: - a espécie decide, e não a ordem

    func testeSomDoSistemaNuncaViraVideo() {
        XCTAssertEqual(destinoDaTrack(EspecieDeTrack(bruto: 3), jaTemVideo: false, jaTemAudio: false), .audio,
                       "som do sistema chegando primeiro é som, e não vídeo (crítica 2, M1)")
        XCTAssertEqual(destinoDaTrack(EspecieDeTrack(bruto: 2), jaTemVideo: false, jaTemAudio: false), .audio)
        XCTAssertEqual(destinoDaTrack(EspecieDeTrack(bruto: 0), jaTemVideo: false, jaTemAudio: true), .video)
        XCTAssertEqual(destinoDaTrack(EspecieDeTrack(bruto: 1), jaTemVideo: false, jaTemAudio: false), .video)
        guard case .largar = destinoDaTrack(EspecieDeTrack(bruto: 0), jaTemVideo: true, jaTemAudio: false) else {
            return XCTFail("a segunda track de vídeo é largada")
        }
        guard case .largar = destinoDaTrack(EspecieDeTrack(bruto: 3), jaTemVideo: true, jaTemAudio: true) else {
            return XCTFail("a segunda track de som é largada")
        }
        guard case .largar = destinoDaTrack(EspecieDeTrack(bruto: 7), jaTemVideo: false, jaTemAudio: false) else {
            return XCTFail("espécie desconhecida é largada, e não vira vídeo")
        }
    }

    // MARK: - µ-law

    /// Os valores são os da G.711, literais: um teste que lesse a tabela que confere não conferiria
    /// nada.
    func testeMuLawBateComAG711() {
        XCTAssertEqual(MuLaw.linear(0xFF), 0)
        XCTAssertEqual(MuLaw.linear(0x7F), 0)
        XCTAssertEqual(MuLaw.linear(0x80), 32124)
        XCTAssertEqual(MuLaw.linear(0x00), -32124)
        XCTAssertEqual(MuLaw.linear(0xFE), 8)
        XCTAssertEqual(MuLaw.linear(0xFD), 16)
        XCTAssertEqual(MuLaw.linear(0x7D), -16)
        XCTAssertEqual(MuLaw.tabela.count, 256)
        // Monótona dentro de cada metade: de 0x80 (maior) a 0xFF (zero), e de 0x00 a 0x7F.
        for u in 0x80..<0xFF { XCTAssertGreaterThan(MuLaw.linear(UInt8(u)), MuLaw.linear(UInt8(u + 1))) }
        for u in 0x00..<0x7F { XCTAssertLessThan(MuLaw.linear(UInt8(u)), MuLaw.linear(UInt8(u + 1))) }
    }

    // MARK: - de 8 para 48 kHz

    /// Energia de `x` na frequência `f` (Goertzel), a `taxa` Hz.
    private func goertzel(_ x: [Float], _ f: Double, _ taxa: Double) -> Double {
        let w = 2 * Double.pi * f / taxa
        let c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(x.count * x.count) * 4
    }

    /// O PCMU chega ao motor a 48 kHz, interpolado pela casca: ganho 1 na banda, e a imagem do
    /// tom (8 kHz − f) atenuada. Sem o filtro, o esticamento por 6 deixaria a imagem com a mesma
    /// energia do tom.
    func testeOInterpoladorLevaOTomDe8Para48kHzSemImagem() {
        // (tom, imagem em 8 kHz − tom, atenuação mínima da imagem em dB, ganho mínimo do tom)
        let casos: [(Double, Double, Double, Double)] = [(1000, 7000, 60, 0.97), (3150, 4850, 40, 0.8)]
        for (tom, imagem, minimaDb, ganhoMinimo) in casos {
            var interp = InterpoladorPor6()
            defer { interp.liberar() }
            let n8 = 1600 // 200 ms
            let entrada = UnsafeMutablePointer<Float>.allocate(capacity: n8)
            let saida = UnsafeMutablePointer<Float>.allocate(capacity: n8 * 6)
            defer { entrada.deallocate(); saida.deallocate() }
            for i in 0..<n8 { entrada[i] = 0.5 * sin(2 * .pi * Float(tom) * Float(i) / 8000) }
            // Em dois pedaços, como dois slots: a história do filtro atravessa a emenda.
            interp.processar(entrada, 800, saida)
            interp.processar(entrada.advanced(by: 800), 800, saida.advanced(by: 4800))
            let x = Array(UnsafeBufferPointer(start: saida.advanced(by: 960), count: n8 * 6 - 960))
            let a = sqrt(goertzel(x, tom, 48_000))
            let b = sqrt(goertzel(x, imagem, 48_000))
            let db = 20 * log10(b / a)
            print(String(format: "interpolador: tom %.0f Hz sai com %.3f (entrou 0,5); imagem em %.0f Hz a %.1f dB",
                         tom, a, imagem, db))
            XCTAssertGreaterThan(a, 0.5 * ganhoMinimo, "o tom de \(tom) Hz passa")
            XCTAssertLessThan(a, 0.52)
            XCTAssertLessThan(db, -minimaDb, "a imagem de \(tom) Hz fica \(minimaDb) dB abaixo")
        }
        // DC: uma constante sai constante, com ganho 1; e o atraso de grupo é o declarado.
        var dc = InterpoladorPor6()
        defer { dc.liberar() }
        let e = UnsafeMutablePointer<Float>.allocate(capacity: 160)
        let s = UnsafeMutablePointer<Float>.allocate(capacity: 960)
        defer { e.deallocate(); s.deallocate() }
        for i in 0..<160 { e[i] = 0.25 }
        dc.processar(e, 160, s)
        XCTAssertEqual(s[900], 0.25, accuracy: 1e-3)
        XCTAssertEqual(InterpoladorPor6.atrasoUs, 71.5 / 48_000 * 1_000_000, accuracy: 0.01)
    }

    // MARK: - o montador

    /// Uma porta falsa: o slot `k` tem as amostras `k * 1000 + i` (por canal), para a continuidade
    /// ser conferida amostra a amostra. Guarda o atraso e a razão de cada puxada.
    final class PortaFalsa {
        var puxadas: [(atraso: UInt32, razao: Double)] = []
        var noDac: [UInt64] = []
        var ordem: (Int) -> OrdemPuxada = { _ in .quadro }
        let porSlot: Int
        let canais: Int
        init(porSlot: Int, canais: Int) { self.porSlot = porSlot; self.canais = canais }

        var fonte: FonteDeSlots {
            { atraso, noDac, razao, destino, cap in
                let k = self.puxadas.count
                self.puxadas.append((atraso, razao))
                self.noDac.append(noDac)
                let o = self.ordem(k)
                if o == .ocioso { return SlotPuxado(ordem: .ocioso, amostrasPorCanal: 0, timestampUs: 0) }
                for i in 0..<self.porSlot {
                    for c in 0..<self.canais {
                        destino[i * self.canais + c] = Float(k * 1000 + i) + Float(c) * 0.5
                    }
                }
                XCTAssertGreaterThanOrEqual(cap, self.porSlot * self.canais)
                return SlotPuxado(ordem: o, amostrasPorCanal: self.porSlot, timestampUs: UInt64(k) * 20_000)
            }
        }
    }

    /// O "DAC": chama o render com `quadros` por ciclo, `ciclos` vezes, e devolve a saída de cada
    /// canal emendada.
    private func tocar(_ m: MontadorDeSaida, quadros: Int, ciclos: Int, atrasoUs: Double = 10_000,
                       razao: Double = 1) -> [[Float]] {
        var saida = Array(repeating: [Float](), count: m.canais)
        let buffers = (0..<m.canais).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: quadros) }
        defer { buffers.forEach { $0.deallocate() } }
        let ponteiros = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: m.canais)
        defer { ponteiros.deallocate() }
        for c in 0..<m.canais { ponteiros[c] = buffers[c] }
        for _ in 0..<ciclos {
            m.render(quadros: quadros, saida: UnsafeMutableBufferPointer(start: ponteiros, count: m.canais),
                     atrasoDaSaidaUs: atrasoUs, razaoAplicada: razao)
            for c in 0..<m.canais { saida[c].append(contentsOf: UnsafeBufferPointer(start: buffers[c], count: quadros)) }
        }
        return saida
    }

    /// Quantum de 512 quadros a 48 kHz (o do Mac): uma puxada a cada ~1,9 render, nenhuma amostra
    /// perdida nem repetida, e o atraso de cada puxada é o do render mais o que já foi escrito nele.
    func testeOMontadorPuxaNaCadenciaDoDispositivoSemPerderAmostra() {
        let porta = PortaFalsa(porSlot: 960, canais: 2)
        let m = MontadorDeSaida(canais: 2, taxaHz: 48_000, amostrasPorSlot: 960, agoraUs: { 0 }, fonte: porta.fonte)
        let ciclos = 1_875 // 20 s
        let saida = tocar(m, quadros: 512, ciclos: ciclos)
        XCTAssertEqual(porta.puxadas.count, (ciclos * 512 + 959) / 960, "uma puxada por slot consumido")
        for (j, v) in saida[0].enumerated() {
            let esperado = Float((j / 960) * 1000 + j % 960)
            guard v == esperado else { return XCTFail("amostra \(j): \(v), esperado \(esperado)") }
        }
        XCTAssertEqual(saida[1][10], saida[0][10] + 0.5, "o segundo canal é o segundo canal do slot")
        // Os atrasos: 10 ms mais as amostras já escritas neste render, a 48 kHz. Nunca mais que um
        // render inteiro acima dos 10 ms.
        for p in porta.puxadas {
            XCTAssertGreaterThanOrEqual(p.atraso, 10_000)
            XCTAssertLessThan(p.atraso, 10_000 + 10_667)
        }
        let r = m.retrato()
        XCTAssertEqual(r.maiorRender, 512)
        XCTAssertEqual(r.menorRender, 512)
        XCTAssertEqual(r.puxadas, UInt64(porta.puxadas.count))
    }

    /// Quantum de 4 096 quadros (o iOS com a tela travada): 4 ou 5 puxadas por render, cada uma com
    /// o atraso da anterior mais 20 ms. É a rajada que o núcleo mede para k (§3.3).
    func testeQuantumGrandeFazRajadaComAtrasoCrescente() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let m = MontadorDeSaida(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960, agoraUs: { 0 }, fonte: porta.fonte)
        let saida = tocar(m, quadros: 4096, ciclos: 60)
        XCTAssertEqual(porta.puxadas.count, (60 * 4096 + 959) / 960)
        for (j, v) in saida[0].enumerated() where v != Float((j / 960) * 1000 + j % 960) {
            return XCTFail("amostra \(j) fora do lugar")
        }
        // Dentro de um render, as puxadas seguintes vêm 20 ms depois uma da outra.
        var degraus = 0
        for k in 1..<porta.puxadas.count where porta.puxadas[k].atraso > porta.puxadas[k - 1].atraso {
            XCTAssertEqual(Double(porta.puxadas[k].atraso - porta.puxadas[k - 1].atraso), 20_000, accuracy: 2)
            degraus += 1
        }
        XCTAssertGreaterThan(degraus, 150, "a maioria das puxadas de uma rajada está 20 ms depois da anterior")
    }

    /// Com o Varispeed acelerando, cada amostra da fonte dura menos: o atraso das puxadas no meio
    /// do render é contado a `taxa × razão`.
    func testeARazaoEntraNoAtraso() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let m = MontadorDeSaida(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960, agoraUs: { 0 }, fonte: porta.fonte)
        _ = tocar(m, quadros: 4096, ciclos: 3, atrasoUs: 0, razao: 2)
        let passos = zip(porta.puxadas.dropFirst(), porta.puxadas).map { Int($0.atraso) - Int($1.atraso) }
        XCTAssertTrue(passos.contains { abs($0 - 10_000) <= 1 }, "a razão 2 faz 20 ms de fonte durarem 10 ms: \(passos)")
        XCTAssertTrue(porta.puxadas.allSatisfy { $0.razao == 2 }, "a razão aplicada vai para a porta")
    }

    /// `IDLE` são zeros, e não a ocultação: não há fluxo tocando. E o ocioso ocupa um slot inteiro,
    /// para a cadência das puxadas não mudar.
    func testeOciosoSaoZerosEOcupamUmSlot() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        porta.ordem = { k in k < 3 ? .ocioso : .quadro }
        let m = MontadorDeSaida(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960, agoraUs: { 0 }, fonte: porta.fonte)
        let saida = tocar(m, quadros: 480, ciclos: 8)
        XCTAssertTrue(saida[0][0..<2880].allSatisfy { $0 == 0 }, "três slots ociosos: zeros")
        XCTAssertEqual(saida[0][2880], 3000, "o quarto slot é o primeiro quadro")
        XCTAssertEqual(m.retrato().ociosas, 3)
        XCTAssertEqual(porta.puxadas.count, 4)
    }

    /// O lado do som do Δ: o último slot de quadro, com a hora do host em que ele sai no DAC.
    func testeOUltimoQuadroGuardaAHoraDoDac() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let m = MontadorDeSaida(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960, atrasoInternoUs: 1_500,
                                agoraUs: { 5_000_000 }, fonte: porta.fonte)
        _ = tocar(m, quadros: 960, ciclos: 3, atrasoUs: 30_000)
        let r = m.retrato()
        XCTAssertTrue(r.temUltimo)
        XCTAssertEqual(r.ultimoCarimboUs, 40_000, "o terceiro slot")
        XCTAssertEqual(r.ultimoNoDacUs, 5_031_500, "agora mais o atraso mais o filtro")
        XCTAssertEqual(porta.noDac.last, 5_031_500, "a fonte recebe a mesma hora, lida uma vez")
        XCTAssertEqual(porta.puxadas.last?.atraso, 31_500)
    }

    // MARK: - o volume (D1 e D3)

    func testeAVontadeDoSom() {
        XCTAssertEqual(VontadeDoSom().ganho, 1, "D1: ligado por padrão")
        XCTAssertNil(VontadeDoSom().porQueCalado)
        XCTAssertEqual(VontadeDoSom(mudo: true).ganho, 0)
        XCTAssertEqual(VontadeDoSom(volume: 0.3).ganho, 0.3, accuracy: 1e-6)
        XCTAssertEqual(VontadeDoSom(volume: 3).ganho, 1, "o volume é limitado")
    }

    /// A leitura da D3 (§12.1, decisão do coordenador de 18/09): o CoreMediaIO não separa o app que
    /// alimenta a câmera do Quall de quem assiste, então **rodando é em uso, e cala** — com o
    /// `QuallCamera.app` alimentando ou não; a pergunta nem é feita. A chave da janela desfaz; o
    /// mudo continua valendo com ela.
    func testeODTresCalaSempreQueACameraRoda() {
        XCTAssertEqual(EstadoDaCameraDoQuall(rodando: nil), .ausente)
        XCTAssertEqual(EstadoDaCameraDoQuall(rodando: false), .livre)
        XCTAssertEqual(EstadoDaCameraDoQuall(rodando: true), .emUso)

        let emUso = VontadeDoSom(camera: EstadoDaCameraDoQuall(rodando: true))
        XCTAssertTrue(emUso.caladoPelaCamera)
        XCTAssertEqual(emUso.ganho, 0, "a câmera rodando cala, numa chamada ou alimentada pelo app dela")
        XCTAssertEqual(emUso.porQueCalado, "mudo: a câmera do Quall está ligada (numa chamada, ou pelo app dela)")

        var comChave = VontadeDoSom(camera: .emUso, tocarComACamera: true)
        XCTAssertFalse(comChave.caladoPelaCamera)
        XCTAssertEqual(comChave.ganho, 1, "a chave da janela toca mesmo com a câmera em uso")
        XCTAssertNil(comChave.porQueCalado)
        comChave.mudo = true
        XCTAssertEqual(comChave.ganho, 0, "o mudo continua valendo")
        XCTAssertEqual(comChave.porQueCalado, "mudo")

        XCTAssertEqual(VontadeDoSom(camera: .livre).ganho, 1)
        XCTAssertEqual(VontadeDoSom(camera: .ausente).ganho, 1, "sem a câmera instalada, toca")
        XCTAssertEqual(VontadeDoSom(volume: 0.4, camera: .emUso).ganho, 0, "o volume não fura o D3")
    }

    // MARK: - o Δ

    func testeODeltaCancelaORelogioDoHost() {
        // Som: capturado em 1 000 000 no relógio da sessão, sai no host em 9 150 000.
        // Imagem: capturada em 1 000 000, sai no host em 9 100 000. Som 50 ms atrasado.
        XCTAssertEqual(Delta.us(som: (1_000_000, 9_150_000), imagem: (1_000_000, 9_100_000)), 50_000)
        // Capturas diferentes: o que conta é a latência de cada lado.
        XCTAssertEqual(Delta.us(som: (2_000_000, 9_150_000), imagem: (1_000_000, 8_100_000)), 50_000)
        XCTAssertEqual(Delta.us(som: (1_000_000, 9_070_000), imagem: (1_000_000, 9_100_000)), -30_000)
        XCTAssertEqual(Delta.resumo([]), "[n=0]")
        XCTAssertTrue(Delta.resumo([10_000, 20_000, 30_000]).hasPrefix("[n=3 p05=10.1 p50=20.1 p95=30.1"),
                      Delta.resumo([10_000, 20_000, 30_000]))
    }

    /// O Δ de uma sessão inteira em memória fixa (crítica 9, miúdo 9): os percentis do histograma
    /// batem com os da lista ordenada a menos de uma caixa (0,2 ms), com 300 mil amostras.
    func testeOAcumuladorDoDeltaBateComAListaOrdenada() {
        var a = Delta.Acumulador()
        var lista: [Int64] = []
        var x: UInt64 = 42
        for _ in 0..<300_000 {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            let v = Int64(x >> 33) % 120_000 + 20_000 // 20 a 140 ms
            a.somar(v)
            lista.append(v)
        }
        lista.sort()
        func q(_ p: Double) -> Double { Double(lista[Int((p * Double(lista.count - 1)).rounded())]) / 1000 }
        for p in [0.05, 0.5, 0.95] {
            XCTAssertEqual(a.percentilMs(p), q(p), accuracy: 0.2, "p\(Int(p * 100))")
        }
        XCTAssertEqual(a.n, 300_000)
        a.somar(9_000_000)
        XCTAssertEqual(a.foraDaFaixa, 1)
        XCTAssertEqual(Double(a.maximoUs), 9_000_000, "o máximo é exato mesmo fora da faixa")
    }

    // MARK: - o motor inteiro contra um DAC simulado

    /// Um tom de 1 kHz na fonte de 48 kHz, para a saída ter energia conferível.
    private func fonteComTom(_ porta: PortaFalsa, taxa: Double) -> FonteDeSlots {
        { atraso, noDac, razao, destino, cap in
            let s = porta.fonte(atraso, noDac, razao, destino, cap)
            let k = porta.puxadas.count - 1
            for i in 0..<porta.porSlot {
                let v = 0.5 * sin(2 * Float.pi * 1000 * Float(k * porta.porSlot + i) / Float(taxa))
                for c in 0..<porta.canais { destino[i * porta.canais + c] = v }
            }
            return s
        }
    }

    /// A cadeia de verdade — a fonte, o `AUVarispeed` — puxada como se fosse a saída, sem
    /// dispositivo nenhum. 48 kHz na fonte (o que a porta entrega, PCMU inclusive): 50 puxadas por
    /// segundo de saída, e o tom sai.
    func testeOMotorPuxaCinquentaSlotsPorSegundoEOSomSai() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let t = Tocador(formato: .init(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960), manual: true,
                        fonte: fonteComTom(porta, taxa: 48_000))
        XCTAssertTrue(t.iniciar(), t.retrato().ultimaFalha)
        var energia: Float = 0
        for _ in 0..<(48_000 * 2 / 480) {
            guard let b = t.renderizarManual(quadros: 480) else { return XCTFail("o render manual falhou") }
            for v in b[0] { energia += v * v }
            XCTAssertEqual(b[1][7], b[0][7], "mono vai aos dois canais")
        }
        t.parar()
        XCTAssertGreaterThanOrEqual(porta.puxadas.count, 100)
        XCTAssertLessThanOrEqual(porta.puxadas.count, 103)
        XCTAssertGreaterThan(energia, 1_000, "o tom tinha de sair do Varispeed")
        XCTAssertEqual(t.retrato().razao, 1)
    }

    /// **Crítica 9, M6**: numa saída de 44,1 kHz, o conversor do `AVAudioEngine` pediria 557
    /// quadros por ciclo em vez de 557,28 (−500,5 ppm, no teto). A conversão agora é do Varispeed,
    /// que carrega a fração: em 60 s de saída, o consumo da fonte fica a menos de 20 ppm do
    /// esperado. Com a razão em +500 ppm, o consumo sobe 500 ppm.
    func testeNumaSaidaA44kHzAFonteNaoDeriva() {
        for (razao, esperadoPpm) in [(1.0, 0.0), (1.0005, 500.0)] {
            let porta = PortaFalsa(porSlot: 960, canais: 1)
            let t = Tocador(formato: .init(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960), manual: true,
                            taxaDaSaidaManual: 44_100, fonte: porta.fonte)
            XCTAssertTrue(t.iniciar(), t.retrato().ultimaFalha)
            t.ajustarRazao(razao)
            // Um ciclo de aquecimento, para o parâmetro chegar ao Varispeed.
            _ = t.renderizarManual(quadros: 512)
            let antes = t.montador.retrato().quadrosPedidos
            let ciclos = 44_100 * 60 / 512
            for _ in 0..<ciclos {
                guard t.renderizarManual(quadros: 512) != nil else { return XCTFail("o render manual falhou") }
            }
            let pedidos = Double(t.montador.retrato().quadrosPedidos - antes)
            let esperado = Double(ciclos * 512) * 48_000 / 44_100 * Double(Float(razao))
            let ppm = (pedidos / esperado - 1) * 1e6
            let taxaReal = (pedidos / (Double(ciclos * 512) * 48_000 / 44_100) - 1) * 1e6
            print(String(format: "saída a 44,1 kHz, razão %.4f: consumo %+.1f ppm do esperado (%+.1f ppm do nominal)",
                         razao, ppm, taxaReal))
            XCTAssertEqual(taxaReal, esperadoPpm, accuracy: 20, "razão \(razao)")
            t.parar()
        }
    }

    /// **O Varispeed consome a razão que o Mac informa ao núcleo** (rodada de 22/09, item 2, H2): o
    /// estimador de deriva do núcleo desconta da inclinação do nível o consumo a mais que a casca diz
    /// ter aplicado. Se o `AUVarispeed` consumisse outra coisa, o `ed_drift_ppm` erraria por essa
    /// diferença. A 48 kHz, nas razões do controle 6 (+100 ppm) e da S4 (+223 ppm), 60 s de saída
    /// em render manual: o consumo da fonte contra `ciclos × 512 × Float(r)`. **Não cobre** o
    /// Varispeed em tempo real, ligado ao dispositivo.
    func testeOVarispeedConsomeARazaoQueOMacInforma() {
        for razao in [1.0, 1.0001, 1.000223] {
            let porta = PortaFalsa(porSlot: 960, canais: 1)
            let t = Tocador(formato: .init(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960), manual: true,
                            fonte: porta.fonte)
            XCTAssertTrue(t.iniciar(), t.retrato().ultimaFalha)
            t.ajustarRazao(razao)
            _ = t.renderizarManual(quadros: 512)
            let antes = t.montador.retrato().quadrosPedidos
            let ciclos = 48_000 * 60 / 512
            for _ in 0..<ciclos {
                guard t.renderizarManual(quadros: 512) != nil else { return XCTFail("o render manual falhou") }
            }
            let pedidos = Double(t.montador.retrato().quadrosPedidos - antes)
            let informada = t.razaoAplicada
            let esperado = Double(ciclos * 512) * informada
            let ppm = (pedidos / esperado - 1) * 1e6
            print(String(format: "Varispeed a 48 kHz, razão informada %.7f: consumo %+.3f ppm da informada",
                         informada, ppm))
            XCTAssertEqual(ppm, 0, accuracy: 1, "razão \(razao)")
            t.parar()
        }
    }

    /// **Crítica 9, M5**: com o ganho em zero **antes** de ligar, o primeiro ciclo já sai mudo — sem
    /// a rampa de 1 para 0 da primeira versão —, e a porta continua sendo puxada na mesma cadência.
    func testeMudoAntesDeLigarSaiMudoDesdeOPrimeiroCiclo() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let t = Tocador(formato: .init(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960), manual: true,
                        fonte: fonteComTom(porta, taxa: 48_000))
        t.aplicarGanho(0)
        XCTAssertTrue(t.iniciar(), t.retrato().ultimaFalha)
        var maior: Float = 0
        for _ in 0..<100 {
            guard let b = t.renderizarManual(quadros: 480) else { return XCTFail("o render manual falhou") }
            for v in b[0] { maior = max(maior, abs(v)) }
        }
        XCTAssertEqual(maior, 0, "mudo desde a primeira amostra")
        XCTAssertGreaterThanOrEqual(porta.puxadas.count, 50, "e a porta continua puxada: 1 s de saída")
        // Voltar o som: sobe em rampa, dentro de um ciclo, sem reancorar.
        t.aplicarGanho(1)
        guard let b = t.renderizarManual(quadros: 480), let c = t.renderizarManual(quadros: 480) else {
            return XCTFail("o render manual falhou")
        }
        XCTAssertLessThan(abs(b[0][0]), 0.05, "a rampa começa perto de zero")
        XCTAssertGreaterThan(c[0].map(abs).max() ?? 0, 0.4, "e no ciclo seguinte o tom está inteiro")
        t.parar()
    }

    /// **Crítica 9, G1**: uma troca de saída que chega depois do `parar()` não religa nada.
    func testeATrocaDeSaidaDepoisDoPararNaoReliga() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let t = Tocador(formato: .init(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960), manual: true,
                        fonte: porta.fonte)
        XCTAssertTrue(t.iniciar())
        XCTAssertNotNil(t.renderizarManual(quadros: 480))
        t.simularTrocaDeSaida()
        XCTAssertTrue(t.ligado, "com o motor ligado, a troca remonta e religa")
        XCTAssertEqual(t.retrato().religamentos, 1)
        XCTAssertNotNil(t.renderizarManual(quadros: 480))
        t.parar()
        let puxadas = porta.puxadas.count
        t.simularTrocaDeSaida()
        XCTAssertFalse(t.ligado, "parado, a troca não religa")
        XCTAssertEqual(t.retrato().religamentos, 1, "e nem conta como religamento")
        XCTAssertNil(t.renderizarManual(quadros: 480), "nenhum render depois do parar")
        XCTAssertEqual(porta.puxadas.count, puxadas, "e nenhuma puxada")
    }

    /// **Crítica 9, M7**: a saída que não liga tenta de novo sozinha (0,2 s, depois 0,5 s), e
    /// enquanto isso o retrato diz desligado, com o motivo.
    func testeASaidaQueNaoLigaTentaDeNovo() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let t = Tocador(formato: .init(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960), manual: true,
                        fonte: porta.fonte)
        t.falhasForcadasAoLigar = 2
        XCTAssertFalse(t.iniciar(), "a primeira tentativa falha")
        XCTAssertFalse(t.ligado)
        XCTAssertTrue(t.retrato().ultimaFalha.contains("forçada"))
        let limite = Date().addingTimeInterval(3)
        while !t.ligado && Date() < limite { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(t.ligado, "a terceira tentativa liga")
        XCTAssertEqual(t.retrato().tentativasFalhas, 2)
        XCTAssertEqual(t.retrato().ultimaFalha, "")
        t.parar()
    }

    /// **Reconferência da S4, miúdo 1** (o rascunho `ZzRevisaoRetry` do revisor, agora teste): o
    /// `iniciar` falha e agenda uma nova tentativa para 0,2 s; antes disso uma troca de saída liga.
    /// A tentativa velha, quando dispara, **não** pode desmontar a saída que já toca.
    func testeATentativaVelhaNaoDesmontaASaidaQueJaToca() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let t = Tocador(formato: .init(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960), manual: true,
                        fonte: porta.fonte)
        var linhas: [String] = []
        let trava = NSLock()
        t.aoRegistrar = { l in trava.lock(); linhas.append(l); trava.unlock() }
        t.falhasForcadasAoLigar = 1
        XCTAssertFalse(t.iniciar(), "falha, e agenda a nova tentativa para daqui a 0,2 s")
        t.simularTrocaDeSaida()
        XCTAssertTrue(t.ligado, "a troca remonta e liga já")
        XCTAssertNotNil(t.renderizarManual(quadros: 480))
        Thread.sleep(forTimeInterval: 0.7)
        trava.lock()
        let ligadas = linhas.filter { $0.contains("saída ligada") }.count
        trava.unlock()
        XCTAssertEqual(ligadas, 1, "só a troca ligou; a tentativa velha não remontou nada")
        XCTAssertTrue(t.ligado)
        XCTAssertEqual(t.retrato().religamentos, 1)
        t.parar()
    }

    /// **Reconferência da S4, miúdo 4**: o retrato não zera o pico da saída (a janela também o
    /// chama); só `tirarPicoNaSaida()` zera.
    func testeORetratoNaoZeraOPico() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let t = Tocador(formato: .init(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960), manual: true,
                        fonte: fonteComTom(porta, taxa: 48_000))
        XCTAssertTrue(t.iniciar())
        for _ in 0..<20 { _ = t.renderizarManual(quadros: 480) }
        // No modo manual não há unidade de saída, e o aviso dela não roda: o pico fica em zero.
        // O que se confere é a regra: o retrato lê sem zerar, e a leitura do relato zera.
        let antes = t.retrato().picoNaSaida
        XCTAssertEqual(t.retrato().picoNaSaida, antes, "duas leituras do retrato dão o mesmo")
        XCTAssertEqual(t.tirarPicoNaSaida(), antes)
        XCTAssertEqual(t.tirarPicoNaSaida(), 0, "a leitura do relato zera")
        t.parar()
    }

    /// **Crítica 9, M8**: o atraso de cada puxada inclui a latência do Varispeed e o atraso interno
    /// da porta (o filtro do PCMU).
    func testeOAtrasoIncluiOVarispeedEOFiltro() {
        let porta = PortaFalsa(porSlot: 960, canais: 1)
        let t = Tocador(formato: .init(canais: 1, taxaHz: 48_000, amostrasPorSlot: 960, atrasoInternoUs: 1_490),
                        manual: true, fonte: porta.fonte)
        XCTAssertTrue(t.iniciar())
        _ = t.renderizarManual(quadros: 480)
        let latencia = t.retrato().latenciaDeSaidaMs * 1000
        print(String(format: "latência declarada no modo manual (só o Varispeed): %.1f µs", latencia))
        XCTAssertGreaterThanOrEqual(Double(porta.puxadas[0].atraso), 1_490 + latencia - 1)
        t.parar()
    }

    // MARK: - nunca `inputNode`

    /// **O motor do receptor nunca toca em `inputNode`**: pelo SDK, o nó nasce sob demanda e daí em
    /// diante o indicador de microfone aparece sempre que o motor roda (`AVAudioEngine.h`). Confere
    /// o texto de todo fonte do pacote: nenhum acesso `.inputNode`.
    func testeNenhumFonteAcessaInputNode() throws {
        let fontes = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let e = FileManager.default.enumerator(at: fontes, includingPropertiesForKeys: nil)
        var conferidos = 0
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let texto = try String(contentsOf: url, encoding: .utf8)
            conferidos += 1
            XCTAssertFalse(texto.contains(".inputNode"), "\(url.lastPathComponent) acessa inputNode")
        }
        XCTAssertGreaterThan(conferidos, 20, "a varredura achou os fontes")
    }

    /// **O receptor não usa `AVAudioEngine`** nem unidade de E/S de entrada: o motor é a
    /// `DefaultOutput`, só de saída, com o Varispeed (crítica 9, M6 e M8). A checagem prévia de
    /// microfone do TCC não é daqui: ela vem da primeira chamada ao HAL, em qualquer cliente
    /// (§17.8). Confere o texto dos fontes do lado que recebe.
    func testeOReceptorNaoUsaAVAudioEngine() throws {
        let fontes = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let arquivos = ["QuallReceptorKit/Tocador.swift", "QuallReceptorKit/SomPuxado.swift",
                        "QuallNetKit/PortaDeSom.swift", "QuallNetKit/NucleoReceptor.swift",
                        "QuallApp/Receptor.swift"]
        for a in arquivos {
            let texto = try String(contentsOf: fontes.appendingPathComponent(a), encoding: .utf8)
            let codigo = texto.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            XCTAssertFalse(codigo.contains { $0.contains("AVAudioEngine") || $0.contains("HALOutput") },
                           "\(a) usa AVAudioEngine ou uma unidade de E/S de entrada")
        }
    }

    /// Crítica 10, M9: a testemunha de fora da deriva acha a taxa de um DAC simulado a +37 ppm, com
    /// os pontos lidos uma vez por segundo em ciclos de 512 quadros, e dá uma barra de erro que
    /// cobre a verdade. Uma volta para trás (a saída religou) recomeça a série.
    func testeATestemunhaDaDerivaAchaATaxaDoDac() throws {
        let taxa = 48_000.0, ppm = 37.0
        let real = taxa * (1 + ppm * 1e-6)
        var t = TestemunhaDaDeriva()
        var quadros: UInt64 = 0
        var proximaLeitura = 0.0
        // 30 s de ciclos de 512 quadros; o relato de 1 Hz lê o último ciclo com hora, com um
        // tremor de ±3 µs na hora que o HAL dá.
        var k = 0
        var ultimo: (hora: UInt64, quadros: UInt64) = (0, 0)
        while Double(quadros) / real < 30 {
            let hora = Double(quadros) / real
            if hora >= proximaLeitura {
                let tremor = Double((k * 7919) % 7) - 3
                ultimo = (UInt64(5_000_000 + hora * 1e6 + tremor), quadros)
                t.adicionar(horaUs: ultimo.hora, quadros: ultimo.quadros)
                proximaLeitura += 1
            }
            quadros += 512
            k += 1
        }
        let r = try XCTUnwrap(t.dacContraHost(taxaNominalHz: taxa))
        XCTAssertEqual(r.ppm, ppm, accuracy: 0.5, "a taxa do DAC")
        XCTAssertLessThan(r.erro, 0.5, "a barra de erro")
        XCTAssertLessThanOrEqual(abs(r.ppm - ppm), 4 * r.erro + 0.05, "a barra cobre a verdade")
        // O mesmo ciclo lido duas vezes não conta; uma volta para trás recomeça.
        let n = t.n
        XCTAssertGreaterThan(n, 25)
        t.adicionar(horaUs: ultimo.hora, quadros: ultimo.quadros)
        XCTAssertEqual(t.n, n, "o mesmo ciclo lido duas vezes conta uma")
        t.adicionar(horaUs: 5_000_001, quadros: 0)
        XCTAssertEqual(t.n, 1, "um ponto para trás recomeça a série")
        XCTAssertNil(t.dacContraHost(taxaNominalHz: taxa), "com menos de 5 pontos, nada")
    }

    /// Reconferência da S4, miúdo 7: a série tem teto, e a inclinação sobrevive ao desbaste.
    func testeATestemunhaDaDerivaTemTeto() throws {
        let taxa = 48_000.0, ppm = -12.0
        var t = TestemunhaDaDeriva()
        let n = TestemunhaDaDeriva.maximoDePontos * 2 + 100
        for k in 0..<n {
            let segundos = Double(k)
            t.adicionar(horaUs: UInt64(1_000_000 + segundos * 1e6),
                        quadros: UInt64(segundos * taxa * (1 + ppm * 1e-6)))
        }
        XCTAssertLessThanOrEqual(t.n, TestemunhaDaDeriva.maximoDePontos)
        XCTAssertGreaterThan(t.n, TestemunhaDaDeriva.maximoDePontos / 4)
        let r = try XCTUnwrap(t.dacContraHost(taxaNominalHz: taxa))
        XCTAssertEqual(r.ppm, ppm, accuracy: 0.05)
    }
}
