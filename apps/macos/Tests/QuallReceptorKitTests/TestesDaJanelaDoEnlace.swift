import XCTest
@testable import QuallReceptorKit

/// A janela do enlace é o **único** número que o controlador de taxa do emissor come. Se ela
/// mentir, o emissor age sobre uma mentira — e a forma mais cara de errar aqui não é o relato não
/// sair, é o relato sair errado: um denominador trocado ou um delta negativo mandam o bitrate
/// para o lado oposto do que a perda pedia.
///
/// Estes testes afirmam as cinco coisas que a aritmética precisa cumprir, e são o que **dá** para
/// provar sem aparelho e sem rede: a peça é `Foundation` puro sobre números que o chamador já
/// leu, e por isso mora em `QuallReceptorKit`, que tem suíte. Que o relato de fato saia no fio, e
/// que o controlador do outro lado acorde, só a bancada com dois aparelhos prova.
final class TestesDaJanelaDoEnlace: XCTestCase {

    private let periodo: UInt64 = 500
    private let umMs: UInt64 = 1_000

    // MARK: - a âncora

    /// **A primeira chamada só ancora.** Uma sessão que já rodou meio segundo antes de a primeira
    /// janela abrir carrega o arranque nos acumulados — o primeiro IDR, a subida do ICE —, e
    /// relatar isso como dano da janela entregaria ao controlador um pico que não é do regime.
    func testeAPrimeiraChamadaSoAncora() {
        var j = JanelaDoEnlace()
        let a = j.fechar(agoraUs: 10_000 * umMs, periodoMs: periodo,
                         vistosAcum: 4_000, perdidosAcum: 120,
                         suspeitosAcum: 30, idrsQuebradosAcum: 7)
        XCTAssertNil(a, "a primeira chamada não pode relatar o acumulado da sessão")
    }

    /// E o que ela ancorou é o que a **segunda** janela desconta: os 4 000 pacotes de antes do
    /// arranque não aparecem em lugar nenhum da primeira amostra.
    func testeOAcumuladoDeAntesDaAncoraNaoEntraNaPrimeiraAmostra() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 10_000 * umMs, periodoMs: periodo,
                     vistosAcum: 4_000, perdidosAcum: 120,
                     suspeitosAcum: 30, idrsQuebradosAcum: 7)
        let a = j.fechar(agoraUs: 10_500 * umMs, periodoMs: periodo,
                         vistosAcum: 4_200, perdidosAcum: 130,
                         suspeitosAcum: 33, idrsQuebradosAcum: 8)
        XCTAssertEqual(a?.perdidos, 10)
        XCTAssertEqual(a?.suspeitos, 3)
        XCTAssertEqual(a?.idrsQuebrados, 1)
        XCTAssertEqual(a?.pacotes, 210, "200 vistos + 10 perdidos, e não os 4 200 acumulados")
    }

    // MARK: - a derivada

    /// A derivada entre duas janelas: cada campo é a diferença, e `ms` é a duração **real**.
    ///
    /// `ms` nominal seria 500; o laço acorda quando acorda (uma volta custa o `next_event` de
    /// 50 ms **mais** o `Thread.sleep(0.05)`, ~100 ms), então a janela fecha em 620 e é 620 que
    /// tem de sair. Dividir por 500 daria uma taxa sistematicamente alta.
    func testeADerivadaEntreDuasJanelas() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 1_000 * umMs, periodoMs: periodo,
                     vistosAcum: 1_000, perdidosAcum: 10,
                     suspeitosAcum: 2, idrsQuebradosAcum: 1)
        let a = j.fechar(agoraUs: 1_620 * umMs, periodoMs: periodo,
                         vistosAcum: 1_240, perdidosAcum: 22,
                         suspeitosAcum: 9, idrsQuebradosAcum: 3)
        XCTAssertEqual(a?.ms, 620, "a duração é a real, não a nominal")
        XCTAssertEqual(a?.perdidos, 12)
        XCTAssertEqual(a?.suspeitos, 7)
        XCTAssertEqual(a?.idrsQuebrados, 2)
    }

    /// Três janelas seguidas: nenhuma carrega nada da anterior. É o que separa a derivada da
    /// integral — uma sessão que perdeu tudo no primeiro segundo tem de voltar a relatar zero.
    func testeUmaJanelaLimpaDepoisDeUmaSujaRelataZero() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 0, periodoMs: periodo,
                     vistosAcum: 0, perdidosAcum: 0, suspeitosAcum: 0, idrsQuebradosAcum: 0)
        let suja = j.fechar(agoraUs: 500 * umMs, periodoMs: periodo,
                            vistosAcum: 900, perdidosAcum: 100,
                            suspeitosAcum: 40, idrsQuebradosAcum: 5)
        XCTAssertEqual(suja?.perdidos, 100)
        let limpa = j.fechar(agoraUs: 1_000 * umMs, periodoMs: periodo,
                             vistosAcum: 1_900, perdidosAcum: 100,
                             suspeitosAcum: 40, idrsQuebradosAcum: 5)
        XCTAssertEqual(limpa?.perdidos, 0, "a perda da janela anterior não pode reaparecer")
        XCTAssertEqual(limpa?.pacotes, 1_000)
        XCTAssertEqual(limpa?.perdaPct, 0.0)
    }

    // MARK: - o denominador

    /// **`pacotes` é `vistos + perdidos`: o que o emissor mandou.**
    ///
    /// Dividir pelo que chegou responde outra pergunta. Em 31/08/2026 esta bancada quase publicou
    /// a conclusão oposta sobre a perda de regime porque um instrumento dividia pelo que chegou:
    /// o braço que parecia o melhor da matriz era o pior, e o laudo já estava escrito.
    ///
    /// Os números abaixo tornam os dois denominadores distinguíveis de propósito: 100 perdidos em
    /// 900 vistos é **10,00 %** do que o emissor mandou e 11,11 % do que chegou.
    func testeODenominadorEOQueOEmissorMandou() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 0, periodoMs: periodo,
                     vistosAcum: 0, perdidosAcum: 0, suspeitosAcum: 0, idrsQuebradosAcum: 0)
        let a = j.fechar(agoraUs: 500 * umMs, periodoMs: periodo,
                         vistosAcum: 900, perdidosAcum: 100,
                         suspeitosAcum: 0, idrsQuebradosAcum: 0)
        XCTAssertEqual(a?.pacotes, 1_000, "900 vistos + 100 perdidos")
        XCTAssertEqual(a?.perdaPct ?? -1, 10.0, accuracy: 0.0001)
        XCTAssertNotEqual(a?.pacotes, 900, "o denominador não é o que chegou")
    }

    /// Janela em que nada chegou: `perdaPct` é 0 e **não** uma divisão por zero. Acontece de
    /// verdade — meio segundo sem um pacote existe em toda sessão que congela.
    func testeJanelaVaziaNaoDividePorZero() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 0, periodoMs: periodo,
                     vistosAcum: 7, perdidosAcum: 1, suspeitosAcum: 0, idrsQuebradosAcum: 0)
        let a = j.fechar(agoraUs: 500 * umMs, periodoMs: periodo,
                         vistosAcum: 7, perdidosAcum: 1, suspeitosAcum: 0, idrsQuebradosAcum: 0)
        XCTAssertEqual(a?.pacotes, 0)
        XCTAssertEqual(a?.perdaPct, 0.0)
    }

    // MARK: - a saturação

    /// **Contador que regride é track recriada, não perda negativa.**
    ///
    /// Numa subtração de `UInt64` sem guarda, `20 - 130` publica dezoito quintilhões; num `Int`,
    /// publica −110. As duas mentiras alimentam o controlador, e a segunda é pior: perda negativa
    /// manda subir o bitrate exatamente quando não se deve. A resposta certa é zero, nas quatro
    /// grandezas.
    func testeContadorQueRegrideSatura() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 0, periodoMs: periodo,
                     vistosAcum: 5_000, perdidosAcum: 130,
                     suspeitosAcum: 44, idrsQuebradosAcum: 9)
        let a = j.fechar(agoraUs: 500 * umMs, periodoMs: periodo,
                         vistosAcum: 12, perdidosAcum: 0,
                         suspeitosAcum: 0, idrsQuebradosAcum: 0)
        XCTAssertEqual(a?.pacotes, 0)
        XCTAssertEqual(a?.perdidos, 0)
        XCTAssertEqual(a?.suspeitos, 0)
        XCTAssertEqual(a?.idrsQuebrados, 0)
        XCTAssertEqual(a?.perdaPct, 0.0)
    }

    /// E depois de regredir a janela se reancora no valor novo: a janela **seguinte** volta a
    /// contar certo a partir da track recriada, em vez de ficar entulhada até passar do valor
    /// antigo.
    func testeDepoisDeRegredirAJanelaSeguinteContaCerto() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 0, periodoMs: periodo,
                     vistosAcum: 5_000, perdidosAcum: 130,
                     suspeitosAcum: 44, idrsQuebradosAcum: 9)
        _ = j.fechar(agoraUs: 500 * umMs, periodoMs: periodo,
                     vistosAcum: 12, perdidosAcum: 0, suspeitosAcum: 0, idrsQuebradosAcum: 0)
        let a = j.fechar(agoraUs: 1_000 * umMs, periodoMs: periodo,
                         vistosAcum: 212, perdidosAcum: 4,
                         suspeitosAcum: 1, idrsQuebradosAcum: 0)
        XCTAssertEqual(a?.pacotes, 204, "200 vistos + 4 perdidos, contados da track nova")
        XCTAssertEqual(a?.perdidos, 4)
    }

    // MARK: - a janela que ainda não fechou

    /// O laço chama a cada ~100 ms e quem decide o que é uma janela é esta função: enquanto não
    /// completou o período, ela devolve `nil`.
    func testeAJanelaQueAindaNaoFechouNaoRelata() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 0, periodoMs: periodo,
                     vistosAcum: 0, perdidosAcum: 0, suspeitosAcum: 0, idrsQuebradosAcum: 0)
        XCTAssertNil(j.fechar(agoraUs: 300 * umMs, periodoMs: periodo,
                              vistosAcum: 100, perdidosAcum: 5,
                              suspeitosAcum: 1, idrsQuebradosAcum: 0))
        XCTAssertNil(j.fechar(agoraUs: 499 * umMs, periodoMs: periodo,
                              vistosAcum: 180, perdidosAcum: 8,
                              suspeitosAcum: 2, idrsQuebradosAcum: 0))
    }

    /// **E não relatar não pode mexer na âncora.** Se cada chamada de meio caminho reancorasse, a
    /// janela que fecha relataria só o último trecho e o dano das voltas anteriores sumiria — uma
    /// rajada de perda entre dois relatos ficaria invisível para o controlador. Os 180 pacotes da
    /// volta de 499 ms têm de aparecer na amostra de 500 ms.
    func testeAChamadaQueNaoFechaNaoMexeNaAncora() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 0, periodoMs: periodo,
                     vistosAcum: 0, perdidosAcum: 0, suspeitosAcum: 0, idrsQuebradosAcum: 0)
        _ = j.fechar(agoraUs: 300 * umMs, periodoMs: periodo,
                     vistosAcum: 100, perdidosAcum: 5, suspeitosAcum: 1, idrsQuebradosAcum: 0)
        _ = j.fechar(agoraUs: 499 * umMs, periodoMs: periodo,
                     vistosAcum: 180, perdidosAcum: 8, suspeitosAcum: 2, idrsQuebradosAcum: 0)
        let a = j.fechar(agoraUs: 520 * umMs, periodoMs: periodo,
                         vistosAcum: 190, perdidosAcum: 9,
                         suspeitosAcum: 2, idrsQuebradosAcum: 1)
        XCTAssertEqual(a?.ms, 520)
        XCTAssertEqual(a?.pacotes, 199, "190 vistos + 9 perdidos, desde a abertura da janela")
        XCTAssertEqual(a?.perdidos, 9)
        XCTAssertEqual(a?.suspeitos, 2)
        XCTAssertEqual(a?.idrsQuebrados, 1)
    }

    /// Período zero não relata nunca. A guarda existe porque `periodoMs` chega de uma constante
    /// que alguém pode zerar, e uma divisão de janela por zero seria uma amostra com `ms=0` — que
    /// o controlador leria como taxa infinita.
    func testePeriodoZeroNaoRelata() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 0, periodoMs: 0,
                     vistosAcum: 0, perdidosAcum: 0, suspeitosAcum: 0, idrsQuebradosAcum: 0)
        XCTAssertNil(j.fechar(agoraUs: 5_000 * umMs, periodoMs: 0,
                              vistosAcum: 900, perdidosAcum: 100,
                              suspeitosAcum: 0, idrsQuebradosAcum: 0))
    }

    // MARK: - os acumulados que vêm do núcleo

    /// **`packets_lost_for_real`, e não `packets_missing_upper_bound`.** O segundo cobra
    /// reordenação como perda: numa corrida com 486 nele tinham sumido cinquenta pacotes, e o
    /// erro medido vai de 1,3× a 44× (`docs/contador-nas-cascas.md`). Um controlador alimentado
    /// por ele reduziria o bitrate por causa de pacotes que chegaram.
    func testeOsAcumuladosLeemOContadorExatoENaoOTeto() {
        let json = """
        {"frames_dropped":3,"frames_ready":1139,"idrs_broken":4,"idrs_ready":31,
         "packets_lost_for_real":50,"packets_missing_upper_bound":486,
         "packets_seen":27729,"packets_too_late":0}
        """
        let a = JanelaDoEnlace.acumulados(json)
        XCTAssertEqual(a?.vistos, 27_729)
        XCTAssertEqual(a?.perdidos, 50, "o exato, não o teto de 486")
        XCTAssertEqual(a?.idrsQuebrados, 4)
    }

    /// **JSON ilegível devolve `nil`, e `nil` não é zero.** Zerar aqui zeraria a âncora, e a
    /// janela seguinte entregaria ao controlador a sessão inteira como dano de 500 ms. Custa um
    /// tique; a âncora fica de pé.
    func testeJsonIlegivelNaoViraZero() {
        XCTAssertNil(JanelaDoEnlace.acumulados("{ isto não é json"))
    }

    /// E **uma** chave que falte já é leitura falha: uma resposta com dois dos três números não é
    /// meia janela, é nenhuma.
    func testeChaveQueFaltaELeituraFalha() {
        XCTAssertNil(JanelaDoEnlace.acumulados("{}"))
        XCTAssertNil(JanelaDoEnlace.acumulados(
            "{\"packets_seen\":100,\"packets_lost_for_real\":5}"), "falta idrs_broken")
        XCTAssertNil(JanelaDoEnlace.acumulados(
            "{\"packets_seen\":100,\"idrs_broken\":1}"), "falta packets_lost_for_real")
    }

    /// O nome velho **não** vale. `packets_missing` foi renomeado sem alias em 29/08/2026 para
    /// tirar a armadilha do caminho; se alguém o ressuscitar em algum lugar, esta janela continua
    /// não o lendo — e continua lendo o exato, que aqui é zero.
    func testeONomeVelhoNaoEAceito() {
        let a = JanelaDoEnlace.acumulados(
            "{\"packets_missing\":486,\"packets_seen\":100,"
            + "\"packets_lost_for_real\":0,\"idrs_broken\":0}")
        XCTAssertEqual(a?.perdidos, 0, "486 está em `packets_missing`, que não é lido")
        XCTAssertEqual(a?.vistos, 100)
    }

    // MARK: - a linha de diário

    /// A linha tem os cinco números do contrato, com os nomes fixados. Ela é o instrumento e o
    /// sinal ao mesmo tempo: é por ela que uma corrida de bancada mede a curva de resposta, e é a
    /// mesma amostra que atravessa até o emissor. O formato é o do receptor iOS, para que duas
    /// corridas possam ser lidas lado a lado.
    func testeALinhaTemOsCincoNumerosComOsNomesDoContrato() {
        var j = JanelaDoEnlace()
        _ = j.fechar(agoraUs: 0, periodoMs: periodo,
                     vistosAcum: 0, perdidosAcum: 0, suspeitosAcum: 0, idrsQuebradosAcum: 0)
        let linha = j.fechar(agoraUs: 500 * umMs, periodoMs: periodo,
                             vistosAcum: 900, perdidosAcum: 100,
                             suspeitosAcum: 12, idrsQuebradosAcum: 2)?.linha ?? ""
        XCTAssertTrue(linha.hasPrefix("janela_do_enlace "), linha)
        XCTAssertTrue(linha.contains("ms=500"), linha)
        XCTAssertTrue(linha.contains("pacotes=1000"), linha)
        XCTAssertTrue(linha.contains("perdidos=100"), linha)
        XCTAssertTrue(linha.contains("suspeitos=12"), linha)
        XCTAssertTrue(linha.contains("idrs_quebrados=2"), linha)
        // `String(format:)` formata em POSIX mesmo com a interface em português; os dois são
        // aceitos porque quem muda isso é o `Locale` do processo, não este arquivo.
        XCTAssertTrue(linha.contains("(10,00%)") || linha.contains("(10.00%)"), linha)
    }
}
