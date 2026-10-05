import XCTest
@testable import QuallReceptorKit

/// A fluidez é a resposta a uma pergunta que os contadores desta casca não respondiam.
///
/// Em 01/09/2026 o usuário olhou para a tela e disse que faltava fluidez. A média de `fila→tela`
/// da mesma corrida dizia **6,4 ms** e estava certa; o pior caso era **226 ms**. `fps` também
/// estava certo e também não respondia — um segundo com 29 quadros pontuais e um buraco de 200 ms
/// tem o mesmo `fps` de um segundo regular.
///
/// Estes testes fixam o que a aritmética tem de cumprir, e é o que **dá** para provar sem aparelho:
/// a peça é `Foundation` puro sobre instantes que o chamador já leu, e por isso mora em
/// `QuallReceptorKit`, que tem suíte. Que a linha saia com números de uma corrida de verdade, e que
/// a cauda medida aqui seja a cauda que o olho vê, é bancada com dois aparelhos.
///
/// A referência do contrato é `apps/windows/src/fluidez.rs`, e estes casos são os mesmos de lá —
/// de propósito: duas implementações da mesma linha que divergem em silêncio são piores que uma.
final class TestesDaFluidez: XCTestCase {

    /// Um milissegundo, na unidade que a peça come.
    private let umMs: UInt64 = 1_000

    // MARK: - a âncora

    /// **A primeira chamada só ancora.** Não existe intervalo antes do primeiro quadro, e contar o
    /// tempo desde a abertura da sessão como se fosse um poria a subida do ICE e a espera pelo
    /// primeiro IDR dentro da distribuição da imagem — um `max` de segundos em toda corrida
    /// saudável, que é um instrumento que ninguém lê duas vezes.
    func testeAPrimeiraApresentacaoSoAncora() {
        var f = Fluidez()
        f.apresentou(agoraUs: 10_000 * umMs)
        XCTAssertTrue(f.linha.contains("n=0"), f.linha)
        XCTAssertEqual(f.trancos, 0)
    }

    /// Dois quadros, um intervalo — e ele é o **decorrido real**, não um período nominal. A
    /// apresentação acontece quando acontece; qualquer número fixo aqui mediria o cronograma, não
    /// a tela.
    func testeDoisQuadrosDaoUmIntervaloComOMsReal() {
        var f = Fluidez()
        f.apresentou(agoraUs: 10_000 * umMs)
        f.apresentou(agoraUs: 10_033 * umMs)
        let l = f.linha
        XCTAssertTrue(l.contains("n=1"), l)
        XCTAssertTrue(l.contains("p50=33"), l)
        XCTAssertTrue(l.contains("max=33"), l)
        XCTAssertTrue(l.contains("trancos=0"), l)
    }

    /// E a âncora é largada no reinício. Sem isto, o intervalo entre o último quadro de uma sessão
    /// e o primeiro da seguinte — o tempo de a pessoa digitar um endereço — entraria na
    /// distribuição como o maior tranco da corrida. É o mesmo defeito que `Exibidor.reiniciar`
    /// existe para não ter: no receptor iOS, contadores de vida-do-processo ao lado de um
    /// denominador de vida-da-sessão produziram 77,4 fps numa origem de 30.
    func testeReiniciarLargaAAncoraEAsAmostras() {
        var f = Fluidez()
        f.apresentou(agoraUs: 10_000 * umMs)
        f.apresentou(agoraUs: 10_033 * umMs)
        f.reiniciar()
        XCTAssertTrue(f.linha.contains("n=0"), f.linha)

        // Vinte minutos depois, a sessão nova. O primeiro quadro dela só ancora de novo.
        f.apresentou(agoraUs: 1_210_000 * umMs)
        XCTAssertTrue(f.linha.contains("n=0"), f.linha)
        f.apresentou(agoraUs: 1_210_033 * umMs)
        let l = f.linha
        XCTAssertTrue(l.contains("n=1"), l)
        XCTAssertTrue(l.contains("max=33"), "os 20 minutos parados não podem virar o max: \(l)")
    }

    // MARK: - o que a média escondia

    /// **A corrida de 01/09/2026 em miniatura.** Vinte e nove intervalos de 33 ms e um de 226 ms: a
    /// média dá ~39 ms e parece saudável; o `max` mostra o buraco e `trancos` o conta.
    ///
    /// O teste confere as duas coisas — que a média mente e que a distribuição não — porque o
    /// ponto desta peça não é "medir mais", é medir **outra coisa**.
    func testeUmBuracoNoMeioDeUmaSessaoRegularApareceNoMaxENosTrancos() {
        var f = Fluidez()
        var agora: UInt64 = 0
        var intervalos: [UInt64] = []
        f.apresentou(agoraUs: agora)
        for i in 0..<30 {
            let passo: UInt64 = (i == 15) ? 226 : 33
            intervalos.append(passo)
            agora += passo * umMs
            f.apresentou(agoraUs: agora)
        }

        let media = Double(intervalos.reduce(0, +)) / Double(intervalos.count)
        XCTAssertEqual(media, 39.4, accuracy: 0.2,
                       "a média desta sessão é ~39 ms — e é ela que não responde nada")

        let l = f.linha
        XCTAssertTrue(l.contains("n=30"), l)
        XCTAssertTrue(l.contains("p50=33"), l)
        XCTAssertTrue(l.contains("max=226"), l)
        XCTAssertTrue(l.contains("trancos=1"), l)
    }

    // MARK: - o corte

    /// O corte de `trancos` é **estrito**: exatamente no limiar não conta, e um milissegundo acima
    /// conta. Fica fixado para que a comparação entre duas corridas não dependa de arredondamento.
    ///
    /// E o corte é convenção de comparação, **não** afirmação perceptual: não se afirma que 100 ms
    /// é o limiar em que alguém percebe. Quem quiser outro corte tem os percentis ao lado.
    func testeOCorteDoTrancoEEstrito() {
        var f = Fluidez()
        var agora: UInt64 = 0
        f.apresentou(agoraUs: agora)
        agora += Fluidez.trancoMs * umMs
        f.apresentou(agoraUs: agora)
        XCTAssertEqual(f.trancos, 0, "exatamente no limiar não é tranco")

        agora += (Fluidez.trancoMs + 1) * umMs
        f.apresentou(agoraUs: agora)
        XCTAssertEqual(f.trancos, 1, "um milissegundo acima é")
    }

    /// **A porta aparece aqui, e é o ponto.** Segurar um quadro de cadeia condenada não o conserta:
    /// a tela para. Este teste é a forma que isso tem na distribuição — os intervalos em que a
    /// porta reteve três quadros viram um intervalo de quatro tempos.
    ///
    /// É a razão de o intervalo ser medido entre **apresentações** e não entre chegadas: medindo
    /// chegadas, a porta custaria o mesmo e não apareceria em número nenhum.
    func testeAPortaQueSeguraQuadrosApareceComoIntervaloMaior() {
        var f = Fluidez()
        var agora: UInt64 = 0
        f.apresentou(agoraUs: agora)
        for i in 0..<10 {
            // A cada cinco quadros, três ficam retidos: o intervalo seguinte é 4 x 33.
            agora += (i % 5 == 0 ? 33 * 4 : 33) * umMs
            f.apresentou(agoraUs: agora)
        }
        let l = f.linha
        XCTAssertTrue(l.contains("n=10"), l)
        XCTAssertTrue(l.contains("max=132"), l)
        XCTAssertEqual(f.trancos, 2, "dois intervalos de 132 ms passam do corte de 100")
    }

    // MARK: - os casos degenerados

    /// Uma sessão sem quadro nenhum não afirma nada — e não divide por zero. A linha existe, com
    /// `n=0`, porque "não medi" e "medi zero" precisam ser distinguíveis por quem lê o diário.
    func testeSemQuadroNenhumALinhaExisteENaoDividePorZero() {
        let f = Fluidez()
        XCTAssertEqual(f.linha, "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0")
        XCTAssertEqual(f.trancos, 0)
    }

    /// **O teto diz o que descartou.** Passado o limite, a distribuição para de crescer — mas o
    /// `n` não pode se apresentar como a sessão inteira quando não é. É a mesma família de defeito
    /// de `packets_missing`, que esta casa já pagou uma semana para desfazer: um número que se
    /// apresenta como uma coisa e é outra.
    func testeOTetoNaoFingeQueONEASessaoInteira() {
        var f = Fluidez()
        var agora: UInt64 = 0
        f.apresentou(agoraUs: agora)
        for _ in 0..<(Fluidez.maximoDeAmostras + 7) {
            agora += 33 * umMs
            f.apresentou(agoraUs: agora)
        }
        let l = f.linha
        XCTAssertTrue(l.contains("n=\(Fluidez.maximoDeAmostras)"), l)
        XCTAssertTrue(l.contains("(+7 além do teto)"), l)
    }

    // MARK: - o formato, que é o contrato

    /// A linha é literalmente a da peça de referência (`apps/windows/src/fluidez.rs`): mesmos
    /// nomes, mesma ordem, mesma unidade. Duas corridas de plataformas diferentes têm de poder ser
    /// lidas lado a lado sem ninguém traduzir nada — e é por isso que este teste compara a **linha
    /// inteira**, e não pedaços dela.
    ///
    /// De quebra ele fixa por que são **quatro** números e não três: um estouro isolado em vinte
    /// intervalos não move o `p95`, e move o `max`. Quem publicasse só percentis diria que esta
    /// sessão foi limpa.
    func testeAFormaDaLinhaEADoContrato() {
        var f = Fluidez()
        var agora: UInt64 = 0
        f.apresentou(agoraUs: agora)
        for i in 0..<20 {
            agora += (i == 9 ? 241 : 32) * umMs
            f.apresentou(agoraUs: agora)
        }
        XCTAssertEqual(f.linha, "fluidez_ms=[n=20 p50=32 p95=32 max=241] trancos=1")
    }
}
