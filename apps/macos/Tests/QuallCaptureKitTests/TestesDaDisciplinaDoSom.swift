import XCTest
@testable import QuallCaptureKit

/// §19.6 do `som-no-receptor.md`: a disciplina da deriva no Mac (`LinhaDoSomDoMac`), com o
/// reamostrador e o portão. Cada caso tem o controle (a regra desligada, ou a de antes).
///
/// O SCK de mentira entrega blocos de 960 amostras (20 ms a 48 kHz, como o medido), que o
/// conversor leva a 160 a 8 kHz. O dispositivo anda com a deriva pedida contra o host. O PTS segue
/// uma das duas hipóteses do N1: **A**, tempo de mídia (a contagem desde o primeiro); **B**, a hora
/// do host. A entrega é a hora do host mais 42,5 ms, mais um dente de serra de 0 a 8 ms com período
/// de 4 s (o medido), mais um jitter sempre positivo. A testemunha é a hora verdadeira da primeira
/// amostra de cada bloco contra o carimbo que a linha deu a ela.
final class TestesDaDisciplinaDoSom: XCTestCase {

    struct Lcg {
        var s: UInt64
        mutating func unif() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(UInt64(1) << 53)
        }
        mutating func gauss(_ sigma: Double) -> Double {
            let u1 = max(unif(), 1e-300), u2 = unif()
            return sigma * (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    struct Cenario {
        var minutos: Double
        var ppm: Double
        var hipoteseB = false
        var disciplina = true
        var portaoAberto = false
        var degrauNasLacunas = true
        /// Blocos perdidos (a hora e o PTS dos seguintes seguem certos).
        var perdidos: Set<Int> = []
        /// A entrega fica mais lenta por este tanto (µs) a partir deste minuto.
        var latenciaExtra: (minuto: Double, us: Double)?
        /// Amostras a mais no conteúdo (o gancho de bancada), em ppm.
        var ganchoPpm = 0.0
        /// Uma reabertura: neste minuto, o PTS e a hora saltam este tanto (µs).
        var reabertura: (minuto: Double, us: Double)?
        /// Uma pausa de tantos blocos neste minuto, e o PTS volta **reancorado na hora do host**
        /// (sob A, o SCK teria refeito a âncora do tempo de mídia; não medido).
        var reancoragemDoPts: (minuto: Double, blocos: Int)?
        /// Uma pausa de tantos blocos neste minuto, com o PTS seguindo no tempo dele.
        var pausa: (minuto: Double, blocos: Int)?
        /// Um bloco com PTS inválido (o `MonotonicClock` dá 0) neste minuto.
        var ptsInvalidoNoMinuto: Double?
        /// Deste minuto em diante, o PTS volta este tanto (µs), e a hora segue (sob A).
        var ptsVolta: (minuto: Double, us: Double)?
        /// A saída e a entrada contadas deste minuto em diante.
        var marcoMinuto: Double?
    }

    struct Resultado {
        var finalUs = 0.0
        var piorDepoisDe20MinUs = 0.0
        /// O erro a cada 10 blocos (200 ms): (s desde o começo, µs).
        var serie: [(t: Double, e: Double)] = []
        var portaoAbriuAosS: Double?
        var incrementosErrados = 0
        var carimbosParaTras = 0
        var entradaDepoisDoMarco = 0
        var saidaDepoisDoMarco = 0
        var linha: LinhaDoSomDoMac
    }

    func correr(_ c: Cenario) -> Resultado {
        var linha = LinhaDoSomDoMac(taxa: 8_000, canais: 1, disciplina: c.disciplina,
                                    portaoAberto: c.portaoAberto, degrauNasLacunas: c.degrauNasLacunas,
                                    soContar: true)
        let codificador = CodificadorPCMU(preset: .audioDoSistema(codec: .pcmu))
        var r = Resultado(linha: linha)
        var rnd = Lcg(s: 11)
        let t0 = 10_000_000_000.0
        let d = c.ppm * 1e-6
        let blocos = Int(c.minutos * 60 * 50)
        var extraAcumulado = 0.0
        var ultimoCarimbo: UInt64?
        var degrausAntes = 0
        var saltoReabertura = 0.0
        var reancoraDoPts = 0.0
        for n in 0..<blocos {
            var host = t0 + Double(n) * 20_000 / (1 + d)
            if let (m, us) = c.reabertura, Double(n) >= m * 3_000 {
                if saltoReabertura == 0 { saltoReabertura = us; linha.pedirReancoragem() }
                host += us
            }
            if c.perdidos.contains(n) { continue }
            if let (m, k) = c.pausa, n >= Int(m * 3_000), n < Int(m * 3_000) + k { continue }
            if let (m, k) = c.reancoragemDoPts {
                let n0 = Int(m * 3_000)
                if n >= n0 && n < n0 + k { continue }
                if n == n0 + k { reancoraDoPts = host - (t0 + Double(n) * 20_000) }
            }
            var pts = c.hipoteseB ? host : t0 + Double(n) * 20_000 + saltoReabertura + reancoraDoPts
            if let (m, us) = c.ptsVolta, n >= Int(m * 3_000) { pts -= us }
            if let m = c.ptsInvalidoNoMinuto, n == Int(m * 3_000) { pts = 0 }
            let serra = (host.truncatingRemainder(dividingBy: 4_000_000)) / 4_000_000 * 8_000
            var entrega = host + 42_500 + serra + abs(rnd.gauss(8_000))
            if let (m, us) = c.latenciaExtra, host - t0 >= m * 60e6 { entrega += us }
            var quadros = 160
            extraAcumulado += 160 * c.ganchoPpm * 1e-6
            if extraAcumulado >= 1 { extraAcumulado -= 1; quadros += 1 }
            let (saidas, descartar) = linha.blocoContado(ptsUs: UInt64(pts), amostras48: 960,
                                                         agoraUs: UInt64(entrega), quadros: quadros,
                                                         pendentesDoFatiador: codificador.pendentes)
            if descartar { codificador.descartarSobra() }
            if let m = c.marcoMinuto, n >= Int(m * 3_000) {
                r.entradaDepoisDoMarco += quadros
                r.saidaDepoisDoMarco += saidas
            }
            let erro = host - linha.ultimoSUs
            r.finalUs = erro
            if n % 10 == 0 { r.serie.append(((host - t0) / 1e6, erro)) }
            if host - t0 > 20 * 60e6 { r.piorDepoisDe20MinUs = max(r.piorDepoisDe20MinUs, abs(erro)) }
            if r.portaoAbriuAosS == nil && linha.portao.aberto { r.portaoAbriuAosS = (host - t0) / 1e6 }
            for _ in codificador.codificar([Int16](repeating: 0, count: saidas)) {
                let carimbo = linha.carimboDoProximoQuadro(duracaoUs: 20_000)
                if let u = ultimoCarimbo {
                    if carimbo < u { r.carimbosParaTras += 1 }
                    else if carimbo - u != 20_000 && linha.degraus == degrausAntes { r.incrementosErrados += 1 }
                }
                degrausAntes = linha.degraus
                ultimoCarimbo = carimbo
            }
        }
        r.linha = linha
        return r
    }

    // MARK: - o laço, com o controle

    func testSemDisciplinaA300ppmOCarimboDeriva18msPorMinuto() {
        var c = Cenario(minutos: 10, ppm: 300)
        c.disciplina = false
        let r = correr(c)
        XCTAssertGreaterThan(abs(r.finalUs), 150_000, "o controle: \(r.finalUs)")
    }

    /// Os dois sinais: a referência da entrega (o mínimo da primeira janela) é tirada com a deriva
    /// correndo, e o mínimo cai na ponta que o sinal escolhe. Sem corrigir, a +300 ppm o carimbo
    /// assentava 1,8 ms à frente, e a −300 ppm em cima do host (medido no teste).
    ///
    /// **As duas hipóteses dão números idênticos por construção**: o PTS não entra no laço, só na
    /// lacuna. Este teste prova isso (e que o PTS andando contra a contagem, sob B, não vira lacuna);
    /// a diferença entre A e B só aparece nos testes de lacuna.
    func testComDisciplinaA300ppmOPortaoAbreEOCarimboSegueOHost() {
        for (ppm, b) in [(300.0, false), (300.0, true), (-300.0, false)] {
            var c = Cenario(minutos: 40, ppm: ppm)
            c.hipoteseB = b
            let r = correr(c)
            let hip = "\(ppm) ppm, hipótese \(b ? "B" : "A")"
            XCTAssertNotNil(r.portaoAbriuAosS, "hipótese \(hip)")
            XCTAssertLessThan(r.portaoAbriuAosS ?? 1e9, 180, "hipótese \(hip)")
            XCTAssertLessThan(r.piorDepoisDe20MinUs, 1_000, "hipótese \(hip): \(r.piorDepoisDe20MinUs)")
            XCTAssertEqual(r.linha.fPpm, ppm, accuracy: 3, "hipótese \(hip)")
            XCTAssertEqual(r.linha.lacunas, 0, "hipótese \(hip): o PTS andando contra a contagem não é lacuna")
            XCTAssertEqual(r.linha.degraus, 0)
            XCTAssertEqual(r.incrementosErrados + r.carimbosParaTras, 0)
            print("\(hip): portão aos \(r.portaoAbriuAosS ?? -1) s, pior depois de 20 min \(r.piorDepoisDe20MinUs) µs, f \(r.linha.fPpm) ppm, correção da referência \(r.linha.correcaoDaReferenciaUs) µs")
        }
    }

    // MARK: - o portão (N4)

    func testA0ppmOPortaoNaoAbreEUmaLatenciaQueMudaNaoPassaAoCarimbo() {
        var c = Cenario(minutos: 30, ppm: 0)
        c.latenciaExtra = (10, 5_000)
        let r = correr(c)
        XCTAssertFalse(r.linha.portao.aberto)
        XCTAssertEqual(r.linha.ajustePpm, 0)
        XCTAssertLessThan(abs(r.finalUs), 50, "\(r.finalUs)")
        // O controle: o portão forçado aberto passa a mudança de latência ao carimbo.
        c.portaoAberto = true
        let a = correr(c)
        print("latência +5 ms, portão forçado: erro final \(a.finalUs) µs")
        XCTAssertGreaterThan(abs(a.finalUs), 2_000, "\(a.finalUs)")
    }

    /// O portão tem de abrir para uma deriva pequena de verdade: 5 ppm dão 150 ms em 8,3 h. E
    /// não pode abrir a 0 ppm com degraus de latência (o N4 lista +1, +3, +5 e +10 ms).
    func testOPortaoAbreA5ppmENaoAbreComDegrausDeLatencia() {
        for ppm in [5.0, -5.0] {
            let r = correr(Cenario(minutos: 40, ppm: ppm))
            print("portão a \(ppm) ppm: abriu aos \(r.portaoAbriuAosS.map { "\($0) s" } ?? "nunca"), inclinação \(r.linha.portao.inclinacaoPpm)")
            XCTAssertLessThan(r.portaoAbriuAosS ?? 1e9, 30 * 60, "\(ppm)")
        }
        for degrau in [1_000.0, 3_000.0, 5_000.0, 10_000.0] {
            var c = Cenario(minutos: 60, ppm: 0)
            c.latenciaExtra = (20, degrau)
            let r = correr(c)
            print("portão a 0 ppm com +\(degrau) µs aos 20 min: \(r.linha.portao.aberto ? "abriu" : "fechado"), inclinação \(r.linha.portao.inclinacaoPpm)")
            XCTAssertFalse(r.linha.portao.aberto, "+\(degrau) µs")
            XCTAssertLessThan(abs(r.finalUs), 50, "+\(degrau) µs")
        }
    }

    // MARK: - a lacuna e a reabertura

    func testUmBlocoPerdidoEUmDegrauDoTamanhoDele() {
        var c = Cenario(minutos: 10, ppm: 0)
        c.perdidos = [15_000]
        let r = correr(c)
        XCTAssertEqual(r.linha.lacunas, 1)
        XCTAssertEqual(r.linha.degraus, 1)
        XCTAssertEqual(r.linha.maiorLacunaUs, 20_000)
        XCTAssertLessThan(abs(r.finalUs), 100, "\(r.finalUs)")
        XCTAssertEqual(r.carimbosParaTras, 0)
        // O controle (a regra de antes de 19/09): sem degrau, o carimbo fica 20 ms atrás.
        c.degrauNasLacunas = false
        let a = correr(c)
        XCTAssertEqual(a.finalUs, 20_000, accuracy: 200)
    }

    func testAReaberturaReancoraParaAFrente() {
        var c = Cenario(minutos: 5, ppm: 0)
        c.reabertura = (2, 3_000_000)
        let r = correr(c)
        XCTAssertEqual(r.linha.reancoragens, 1)
        XCTAssertEqual(r.carimbosParaTras, 0)
        XCTAssertLessThan(abs(r.finalUs), 100, "\(r.finalUs)")
    }

    /// O pior erro (µs) entre `de` e `ate` segundos.
    func pior(_ r: Resultado, de: Double, ate: Double = .infinity) -> Double {
        r.serie.filter { $0.t >= de && $0.t < ate }.map { abs($0.e) }.max() ?? 0
    }

    /// §19.6.6, teste 4: um bloco perdido com o laço rodando dá o degrau do tamanho dele, sem mexer
    /// em `f`, nas duas hipóteses e nos dois sinais (a correção acumulada aos 20 min é de ±360 ms).
    func testUmBlocoPerdidoComOLacoRodandoNaoMexeEmF() {
        for (ppm, b) in [(300.0, false), (-300.0, false), (300.0, true), (-300.0, true)] {
            var c = Cenario(minutos: 30, ppm: ppm)
            c.hipoteseB = b
            c.perdidos = [20 * 3_000]
            let r = correr(c)
            let rotulo = "\(ppm) ppm, hipótese \(b ? "B" : "A")"
            print("bloco perdido, \(rotulo): pior depois da lacuna \(pior(r, de: 1_199)) µs, f \(r.linha.fPpm)")
            XCTAssertEqual(r.linha.lacunas, 1, rotulo)
            XCTAssertEqual(r.linha.degraus, 1, rotulo)
            XCTAssertEqual(r.linha.socorros, 0, rotulo)
            XCTAssertEqual(r.linha.conferenciasDeLacuna, 0, rotulo)
            XCTAssertLessThan(pior(r, de: 1_199), 3_000, rotulo)
            XCTAssertEqual(r.linha.fPpm, ppm, accuracy: 3, rotulo)
            XCTAssertEqual(r.incrementosErrados + r.carimbosParaTras, 0, rotulo)
        }
    }

    /// §19.6.6, teste 4: sob A, o SCK reancora o PTS na hora do host depois de uma pausa (não
    /// medido). O salto do PTS carrega a correção acumulada (±360 ms em 1 h a 100 ppm), e ela não
    /// pode virar degrau: nem o carimbo à frente com a entrada cortada, nem 20 s atrás.
    func testOPtsReancoradoPeloSckNaoViraDegrauDaCorrecao() {
        for ppm in [100.0, -100.0] {
            var c = Cenario(minutos: 70, ppm: ppm)
            c.reancoragemDoPts = (60, 100)
            let r = correr(c)
            let volta = 3_602.0
            print("PTS reancorado, \(ppm) ppm: lacunas \(r.linha.lacunas), degraus \(r.linha.degraus), socorros \(r.linha.socorros), conferências \(r.linha.conferenciasDeLacuna), pior nos 12 s \(pior(r, de: volta, ate: volta + 12)) µs, pior depois \(pior(r, de: volta + 12)) µs, f \(r.linha.fPpm)")
            XCTAssertEqual(r.linha.lacunas, 1, "\(ppm)")
            XCTAssertEqual(r.linha.socorros, 0, "\(ppm): nada de entrada cortada")
            XCTAssertLessThan(pior(r, de: volta + 12), 3_000, "\(ppm)")
            XCTAssertEqual(r.linha.fPpm, ppm, accuracy: 5, "\(ppm)")
            XCTAssertEqual(r.incrementosErrados + r.carimbosParaTras, 0, "\(ppm)")
        }
    }

    // MARK: - a revisão do código (21/09): A, B e C

    /// A: a primeira atualização depois de uma lacuna longa usava `dt` = a lacuna inteira, e
    /// `f ← f − ε·dt/T²` multiplicava o erro de uma janela pela duração dela (a revisão mediu, sob
    /// A, `f` de 50 a 119 ppm e um socorro depois de 1 h).
    func testUmaLacunaLongaNaoPuxaOF() {
        for (b, horas) in [(true, 8.0), (false, 1.0)] {
            var c = Cenario(minutos: 20 + horas * 60 + 20, ppm: 50)
            c.hipoteseB = b
            c.pausa = (20, Int(horas * 3_600 * 50))
            let r = correr(c)
            let volta = 20 * 60 + horas * 3_600
            let rotulo = "hipótese \(b ? "B" : "A"), lacuna de \(horas) h"
            print("\(rotulo): f fim \(r.linha.fPpm), pior no 1º min \(pior(r, de: volta, ate: volta + 60)) µs, pior depois de 10 min \(pior(r, de: volta + 600)) µs, socorros \(r.linha.socorros), degraus \(r.linha.degraus)")
            XCTAssertEqual(r.linha.socorros, 0, rotulo)
            XCTAssertEqual(r.linha.fPpm, 50, accuracy: 3, rotulo)
            XCTAssertEqual(r.incrementosErrados + r.carimbosParaTras, 0, rotulo)
        }
    }

    /// B: um bloco com PTS inválido (0) virava um salto para trás do tamanho da sessão, cortado da
    /// entrada sem teto: nenhuma saída nos 10 min seguintes (a revisão). E um PTS que volta 5 s
    /// não pode cortar 5 s de som.
    func testUmPtsInvalidoOuQueVoltaNaoViraSilencio() {
        var c = Cenario(minutos: 15, ppm: 0)
        c.ptsInvalidoNoMinuto = 5
        c.marcoMinuto = 5
        var r = correr(c)
        print("PTS inválido aos 5 min: saída \(r.saidaDepoisDoMarco) de \(r.entradaDepoisDoMarco), cortadas \(r.linha.amostrasCortadas), inválidos \(r.linha.ptsInvalidos), socorros \(r.linha.socorros)")
        XCTAssertGreaterThan(r.saidaDepoisDoMarco, r.entradaDepoisDoMarco - 400)
        XCTAssertEqual(r.linha.amostrasCortadas, 0)
        XCTAssertEqual(r.linha.socorros, 0)
        XCTAssertEqual(r.linha.lacunas, 0)
        XCTAssertLessThan(abs(r.finalUs), 1_000, "\(r.finalUs)")

        c = Cenario(minutos: 15, ppm: 0)
        c.ptsVolta = (5, 5_000_000)
        c.marcoMinuto = 5
        r = correr(c)
        print("PTS volta 5 s aos 5 min: saída \(r.saidaDepoisDoMarco) de \(r.entradaDepoisDoMarco), cortadas \(r.linha.amostrasCortadas), reancoragens \(r.linha.reancoragens), socorros \(r.linha.socorros)")
        XCTAssertGreaterThan(r.saidaDepoisDoMarco, r.entradaDepoisDoMarco - 400)
        XCTAssertEqual(r.linha.amostrasCortadas, 0)
        XCTAssertEqual(r.linha.socorros, 0)
        XCTAssertLessThan(abs(r.finalUs), 1_000, "\(r.finalUs)")
        XCTAssertEqual(r.carimbosParaTras, 0)
    }

    /// C: sob A reancorado, com o dispositivo mais rápido que o host (c < 0), uma pausa mais curta
    /// que a correção acumulada dá um salto de PTS para trás. Ele caía no ramo "nunca visto", que
    /// cortava ~270 ms de entrada e deixava o socorro puxar o `f` de 100 para 62 ppm (a revisão).
    func testOPtsReancoradoNumaPausaCurtaNaoCortaSomNemPuxaF() {
        for pausa in [5, 15] {
            var c = Cenario(minutos: 62, ppm: 100)
            c.reancoragemDoPts = (60, pausa)
            let r = correr(c)
            let volta = 3_600.0 + Double(pausa) * 0.02
            print("PTS reancorado depois de uma pausa de \(pausa * 20) ms a +100 ppm: lacunas \(r.linha.lacunas), cortadas \(r.linha.amostrasCortadas), socorros \(r.linha.socorros), conferências \(r.linha.conferenciasDeLacuna), pior nos 30 s \(pior(r, de: volta, ate: volta + 30)) µs, pior depois \(pior(r, de: volta + 30)) µs, f \(r.linha.fPpm)")
            XCTAssertEqual(r.linha.socorros, 0, "\(pausa)")
            XCTAssertEqual(r.linha.amostrasCortadas, 0, "\(pausa)")
            XCTAssertEqual(r.linha.lacunas, 1, "\(pausa)")
            XCTAssertEqual(r.linha.fPpm, 100, accuracy: 3, "\(pausa)")
            XCTAssertLessThan(pior(r, de: volta + 30), 3_000, "\(pausa)")
            XCTAssertEqual(r.incrementosErrados + r.carimbosParaTras, 0, "\(pausa)")
        }
    }

    // MARK: - fora do alcance (teste 7)

    /// Além de 1 000 ppm a razão não alcança, e o socorro dá o degrau (para a frente) ou corta a
    /// entrada (nunca para trás). Depois dele, a janela seguinte tem de ver o erro zerado.
    func testForaDoAlcanceOSocorroNaoOscila() {
        for ppm in [1_500.0, -1_500.0] {
            let r = correr(Cenario(minutos: 30, ppm: ppm))
            print("fora do alcance, \(ppm) ppm: socorros \(r.linha.socorros), pior depois de 2 min \(pior(r, de: 120)) µs, f \(r.linha.fPpm), ajuste \(r.linha.ajustePpm)")
            XCTAssertGreaterThan(r.linha.socorros, 0, "\(ppm)")
            // A razão fica ~1 000 ppm aquém (f limitado a 500, e u anda 20 ppm por janela): o erro
            // cresce 1 ms/s. No Mac o socorro confirma em duas janelas de 10 s, e o mínimo da janela
            // atrasa uma: 40 ms + 30 s × 1 ms/s = 70 ms (no Windows, com 1 s, 40,5 ms).
            XCTAssertLessThan(r.linha.socorros, 40, "\(ppm)")
            XCTAssertLessThan(pior(r, de: 120), 80_000, "\(ppm)")
            XCTAssertEqual(r.incrementosErrados + r.carimbosParaTras, 0, "\(ppm)")
        }
    }

    // MARK: - o gancho de bancada (N2): o laço vê o conteúdo

    func testOGanchoNoConteudoAbreOPortaoEOLacoOTira() {
        var c = Cenario(minutos: 30, ppm: 0)
        c.ganchoPpm = 300
        let r = correr(c)
        XCTAssertTrue(r.linha.portao.aberto)
        XCTAssertLessThan(r.piorDepoisDe20MinUs, 3_000, "\(r.piorDepoisDe20MinUs)")
        c.disciplina = false
        let a = correr(c)
        XCTAssertGreaterThan(abs(a.finalUs), 400_000, "o controle: \(a.finalUs)")
    }

    // MARK: - o reamostrador

    func testOSincA8kHzGuardaOTom() {
        // O `Int16` com amplitude de 16 000 limita em ~92 dB (±0,5 LSB). A 3,4 kHz, 0,425 da taxa cai
        // na borda da banda de transição do núcleo: 60 dB medidos, contra ~38 dB do µ-law.
        for (f, minimo) in [(1_000.0, 85.0), (3_400.0, 55.0)] {
            for u in [500e-6, -500e-6] {
                var s = ReamostradorSinc(taxaEntrada: 8_000, taxaSaida: 8_000, canais: 1)
                s.definirAjuste(u)
                let x = (0..<16_000).map { Int16((sin(2 * Double.pi * f * Double($0) / 8_000) * 16_000).rounded()) }
                var y: [Int16] = []
                for pedaco in stride(from: 0, to: x.count, by: 80) {
                    s.empurrar(Array(x[pedaco..<min(x.count, pedaco + 80)]))
                    s.produzir(&y)
                }
                var (sinal, erro) = (0.0, 0.0)
                for k in 500..<min(12_000, y.count) {
                    let ideal = sin(2 * Double.pi * f * Double(k) * s.passo / 8_000) * 16_000
                    sinal += ideal * ideal
                    erro += pow(Double(y[k]) - ideal, 2)
                }
                let db = 10 * log10(sinal / erro)
                print("sinc a 8 kHz, \(f) Hz, u \(u): \(db) dB")
                XCTAssertGreaterThan(db, minimo, "\(f) Hz, \(u)")
            }
        }
    }

    func testComRazaoUmOSincDevolveAEntrada() {
        var s = ReamostradorSinc(taxaEntrada: 8_000, taxaSaida: 8_000, canais: 1)
        let x = (0..<2_000).map { Int16(($0 * 37) % 20_000 - 10_000) }
        var y: [Int16] = []
        s.empurrar(x)
        s.produzir(&y)
        XCTAssertGreaterThan(y.count, 1_900)
        XCTAssertEqual(Array(y[100..<1_900]), Array(x[100..<1_900]))
    }

    // MARK: - o laço sozinho

    func testALacoConvergeNaRampa() {
        var d = DisciplinaDaDeriva()
        var e = 0.0
        for k in 1...720 {
            d.atualizar(agoraS: Double(k) * 10, eUs: e)
            e += ((1 + d.u) / (1 + 100e-6) - 1) * 10 * 1e6
        }
        XCTAssertEqual(d.fPpm, 100, accuracy: 0.5)
        XCTAssertLessThan(abs(e), 100)
    }
}
