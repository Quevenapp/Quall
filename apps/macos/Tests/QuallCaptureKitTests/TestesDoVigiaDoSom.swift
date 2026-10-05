import XCTest
@testable import QuallCaptureKit

/// O M3 do Mac (crítica 15): a sessão cujo som falha sozinha deixa de ser dona e candidata, e o som
/// passa. O vigia decide; o `DonoDoSom` passa.
final class TestesDoVigiaDoSom: XCTestCase {
    typealias L = VigiaDoSomDasSessoes.Leitura

    /// Uma leitura por segundo de cada sessão, com as amostras que `amostras(id, segundo)` disser.
    /// `fase` desloca as leituras de cada sessão, como os relatos fora de fase do app.
    private func correr(_ v: inout VigiaDoSomDasSessoes, ids: [Int], de: Int, ate: Int,
                        fase: [Int: UInt64] = [:], amostras: (Int, Int) -> Int,
                        recusados: (Int, Int) -> Int = { _, _ in 0 },
                        enviados: (Int, Int) -> Int = { _, s in s * 50 }) -> [(Int, VigiaDoSomDasSessoes.Falta)] {
        var todas: [(Int, VigiaDoSomDasSessoes.Falta)] = []
        for s in de...ate {
            let leituras = ids.map { id in
                L(id: id, ms: UInt64(s) * 1000 + (fase[id] ?? 0), amostras: amostras(id, s),
                  recusados: recusados(id, s), enviados: enviados(id, s))
            }
            let agora = UInt64(s) * 1000 + 999
            for f in v.observar(leituras, agoraMs: agora).faltas { todas.append((s, f)) }
        }
        return todas
    }

    func testeASessaoSemCapturaEnquantoAOutraTrazSomFicaSemSomUmaVezSo() {
        var v = VigiaDoSomDasSessoes()
        let faltas = correr(&v, ids: [1, 2], de: 1, ate: 20) { id, s in id == 1 ? 0 : s * 8000 }
        XCTAssertEqual(faltas.map(\.1.id), [1], "só a sessão sem amostras, e uma vez só")
        let (quando, falta) = faltas[0]
        XCTAssertGreaterThanOrEqual(quando, 7, "não julga no arranque: janela inteira no ar antes da janela julgada")
        XCTAssertLessThanOrEqual(quando, 8)
        XCTAssertTrue(falta.motivo.contains("#2"), falta.motivo)
        XCTAssertEqual(v.semSom, [1])
    }

    func testeSilencioEmTodasNaoTiraOSomDeNinguem() {
        // Não está medido que o SCK entrega blocos no silêncio: se não entrega, todas param juntas.
        var v = VigiaDoSomDasSessoes()
        let faltas = correr(&v, ids: [1, 2, 3], de: 1, ate: 30) { _, s in s < 10 ? s * 8000 : 80_000 }
        XCTAssertTrue(faltas.isEmpty, "\(faltas)")
    }

    func testeUmaSessaoSozinhaNaoEJulgadaPelaCaptura() {
        var v = VigiaDoSomDasSessoes()
        XCTAssertTrue(correr(&v, ids: [1], de: 1, ate: 30) { _, _ in 0 }.isEmpty)
    }

    func testeSomQueComecaNaBordaNaoPareceFalha() {
        // O som começa aos 10,0 s. A sessão 1 lê aos x,05; a 2, aos x,95 (fora de fase). Na leitura
        // da 1 às 9,05 ela ainda tem zero, e a 2 às 10,95 já tem som: a 2 não trouxe som DENTRO da
        // janela da 1, então nada muda. Depois as duas trazem.
        var v = VigiaDoSomDasSessoes()
        let faltas = correr(&v, ids: [1, 2], de: 1, ate: 20, fase: [1: 50, 2: 950]) { id, s in
            let ms = s * 1000 + (id == 1 ? 50 : 950)
            return ms < 10_000 ? 0 : (ms - 10_000) * 8
        }
        XCTAssertTrue(faltas.isEmpty, "\(faltas)")
    }

    func testeATrackQueRecusaTudoTiraOSomDaDona() {
        var v = VigiaDoSomDasSessoes()
        let faltas = correr(&v, ids: [1, 2], de: 1, ate: 12,
                            amostras: { _, s in s * 8000 },
                            recusados: { id, s in id == 1 && s >= 5 ? (s - 4) * 50 : 0 },
                            enviados: { id, s in id == 1 ? min(s, 4) * 50 : s * 50 })
        XCTAssertEqual(faltas.map(\.1.id), [1])
        XCTAssertTrue(faltas[0].1.motivo.contains("recusou"), faltas[0].1.motivo)
    }

    func testeOPrimeiroQuadroRecusadoNaoContaComoFalha() {
        var v = VigiaDoSomDasSessoes()
        let faltas = correr(&v, ids: [1], de: 1, ate: 12, amostras: { _, s in s * 8000 },
                            recusados: { _, _ in 1 }, enviados: { _, s in s * 50 })
        XCTAssertTrue(faltas.isEmpty)
    }

    func testeQuemSaiEEsquecidoEQuemEntraDeNovoEJulgadoDoZero() {
        var v = VigiaDoSomDasSessoes()
        _ = correr(&v, ids: [1, 2], de: 1, ate: 10) { id, s in id == 1 ? 0 : s * 8000 }
        XCTAssertEqual(v.semSom, [1])
        _ = v.observar([L(id: 2, ms: 11_000, amostras: 88_000, recusados: 0, enviados: 550)], agoraMs: 11_000)
        XCTAssertEqual(v.semSom, [], "a 1 saiu: esquecida")
    }

    func testeASessaoSemSomPassaOSomAoProximoQueToca() {
        // O fio inteiro do Emissor: o vigia diz, o DonoDoSom passa.
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a")
        d.conectou(2, toca: true, aparelho: "mac-b")
        XCTAssertEqual(d.dono, 1)
        var v = VigiaDoSomDasSessoes()
        let faltas = correr(&v, ids: [1, 2], de: 1, ate: 10) { id, s in id == 1 ? 0 : s * 8000 }
        for f in faltas.map(\.1) { d.naoToca(f.id) }
        XCTAssertEqual(d.dono, 2, "o som passou a quem ainda traz som")
        XCTAssertEqual(d.saiu(2), nil, "a 1, sem som, não é candidata")
        XCTAssertNil(d.dono)
    }

    /// Crítica 18, F2: a borda de silêncio para som, com o SCK sem blocos no silêncio. A sessão 1 é
    /// a dona e lê 30 ms depois da 2; o som chega à 2 aos 9,99 s e à 1 aos 10,09 s. Na leitura da 1
    /// aos 10,03 s a 2 já cresceu e ela ainda não: a 1 é julgada sem som. Na leitura seguinte ela
    /// volta a ser candidata, sem tomar o som; e quando a 2 sai, o som é dela.
    func testeASessaoJulgadaNaBordaVoltaASerCandidataSemTomarOSom() {
        var d = DonoDoSom(passar: true)
        d.conectou(1, toca: true, aparelho: "android-a")
        d.conectou(2, toca: true, aparelho: "mac-b")
        var v = VigiaDoSomDasSessoes()
        var faltas: [(Int, Int)] = [], voltas: [(Int, Int)] = []
        for s in 1...20 {
            let ms2 = UInt64(s) * 1000, ms1 = ms2 + 30
            let a2 = ms2 >= 9990 ? Int(ms2 - 9990) * 8 : 0
            let a1 = ms1 >= 10090 ? Int(ms1 - 10090) * 8 : 0
            let r = v.observar([L(id: 1, ms: ms1, amostras: a1, recusados: 0, enviados: s * 50),
                                L(id: 2, ms: ms2, amostras: a2, recusados: 0, enviados: s * 50)], agoraMs: ms1 + 1)
            for f in r.faltas { faltas.append((s, f.id)); d.naoToca(f.id) }
            for id in r.voltas { voltas.append((s, id)); d.voltouOSom(id, toca: true) }
        }
        XCTAssertEqual(faltas.map(\.1), [1], "a borda julgou a 1 sem som (é o caso do revisor)")
        XCTAssertEqual(voltas.map(\.1), [1], "e ela voltou")
        XCTAssertEqual(voltas.first?.0, (faltas.first?.0 ?? 0) + 1, "na leitura seguinte")
        XCTAssertEqual(d.dono, 2, "a volta não toma o som de quem o ganhou")
        XCTAssertTrue(v.semSom.isEmpty)
        XCTAssertEqual(d.saiu(2), 1, "a 2 sai: o som é da 1, que voltou a ser candidata")
    }

    func testeAFaltaPelaTrackNaoVolta() {
        var v = VigiaDoSomDasSessoes()
        var voltas: [Int] = []
        for s in 1...20 {
            let leituras = [L(id: 1, ms: UInt64(s) * 1000, amostras: s * 8000,
                              recusados: s >= 5 && s < 10 ? (s - 4) * 50 : max(0, 5 * 50),
                              enviados: s < 5 ? s * 50 : (s < 10 ? 200 : 200 + (s - 9) * 50)),
                            L(id: 2, ms: UInt64(s) * 1000, amostras: s * 8000, recusados: 0, enviados: s * 50)]
            voltas += v.observar(leituras, agoraMs: UInt64(s) * 1000 + 1).voltas
        }
        XCTAssertEqual(v.semSom, [1], "a track recusou tudo: sem som, e as amostras que crescem não trazem de volta")
        XCTAssertTrue(voltas.isEmpty)
    }
}
