import CoreVideo
import Foundation
import XCTest
@testable import QuallCaptureKit

/// Os controles de câmera do R9 no Mac (`docs/controles-de-camera.md`), a parte pura, **sem câmera**:
/// nada aqui abre aparelho nenhum.
final class TestesDosControlesDaCamera: XCTestCase {

    /// Uma câmera "completa" no que o Mac pode ter.
    private let completa = CapacidadesDaCamera(
        exposicaoContinua: true, exposicaoUmaVez: true, exposicaoTravada: true, pontoDeExposicao: true,
        balancoContinuo: true, balancoUmaVez: true, balancoTravado: true,
        focoContinuo: true, focoUmaVez: true, focoTravado: true, pontoDeFoco: true)

    /// O caso provável da embutida: exposição e balanço contínuos com trava, foco fixo, sem ponto.
    private let embutida = CapacidadesDaCamera(
        exposicaoContinua: true, exposicaoTravada: true, balancoContinuo: true, balancoTravado: true)

    // MARK: - o registro e o JSON (§2)

    func testeOPadraoEhTudoAutomatico() {
        let a = AjustesDaCamera.padrao
        XCTAssertEqual(a.exposicao, .auto)
        XCTAssertFalse(a.travaExposicao)
        XCTAssertEqual(a.balanco, .auto)
        XCTAssertFalse(a.travaBalanco)
        XCTAssertEqual(a.foco, .auto)
        XCTAssertFalse(a.temTrava)
    }

    func testeOJsonUsaOsNomesLiteraisEmCamelCase() {
        let a = AjustesDaCamera(travaExposicao: true, travaBalanco: false, foco: .travado)
        XCTAssertEqual(a.json,
                       #"{"balanco":"auto","exposicao":"auto","foco":"travado","travaBalanco":false,"travaExposicao":true}"#)
        XCTAssertEqual(AjustesDaCamera.doJSON(a.json), a)
    }

    /// A linha "capacidades" do diário leva os estados num campo só, sem JSON (registro seguro), e o
    /// roteiro da bancada procura `travaExposicao:sim|travaBalanco:sim|foco:travado` nele.
    func testeOResumoDeUmCampoDoDiario() {
        let a = AjustesDaCamera(travaExposicao: true, travaBalanco: false, foco: .travado)
        XCTAssertEqual(a.resumoDeUmCampo,
                       "exposicao:auto,travaExposicao:sim,balanco:auto,travaBalanco:não,foco:travado")
        XCTAssertEqual(AjustesDaCamera.padrao.resumoDeUmCampo,
                       "exposicao:auto,travaExposicao:não,balanco:auto,travaBalanco:não,foco:auto")
        for r in [a.resumoDeUmCampo, AjustesDaCamera.padrao.resumoDeUmCampo] {
            XCTAssertFalse(r.contains(" "), "um campo só: \(r)")
            XCTAssertFalse(r.contains("{") || r.contains("\""), "sem JSON: \(r)")
        }
    }

    /// Só os campos que valem no Mac são escritos: nada de `ev`, `iso`, `kelvin`, `focoPosicao`…
    func testeOJsonDoMacNaoEscreveCamposQueOMacNaoAplica() throws {
        let d = try XCTUnwrap(AjustesDaCamera(travaExposicao: true).json.data(using: .utf8))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["exposicao", "travaExposicao", "balanco", "travaBalanco", "foco"])
    }

    /// Um registro escrito por outra plataforma (ou por uma versão futura) não se perde: os campos que o
    /// Mac não conhece são ignorados, e um valor que ele não aplica vira o padrão.
    func testeOJsonDeOutraPlataformaEhLidoSemFalhar() {
        let ios = #"{"exposicao":"manual","ev":0.3,"iso":400,"obturadorNs":16666666,"travaExposicao":true,"#
            + #""balanco":"kelvin","kelvin":5200,"travaBalanco":true,"foco":"manual","focoPosicao":0.4}"#
        let a = AjustesDaCamera.doJSON(ios)
        XCTAssertEqual(a?.exposicao, .auto)
        XCTAssertEqual(a?.balanco, .auto)
        XCTAssertEqual(a?.foco, .auto)
        XCTAssertEqual(a?.travaExposicao, true)
        XCTAssertEqual(a?.travaBalanco, true)
        XCTAssertEqual(AjustesDaCamera.doJSON("{}"), .padrao)
        XCTAssertEqual(AjustesDaCamera.doJSON(#"{"travaExposicao":"sim"}"#), .padrao)
        XCTAssertNil(AjustesDaCamera.doJSON("não é json"))
    }

    func testeAGuardaUsaAChaveDaEspecificacaoEORestaurarNaoApagaOGuardado() throws {
        let dominio = "quall.testes.ajustes.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: dominio))
        defer { d.removePersistentDomain(forName: dominio) }
        let g = GuardaDosAjustes(d)
        XCTAssertEqual(GuardaDosAjustes.chave("0x1424001bcf2284"), "camera.ajustes.0x1424001bcf2284")
        XCTAssertEqual(g.ler("A"), .padrao)
        let travada = AjustesDaCamera(travaExposicao: true, travaBalanco: true, foco: .travado)
        g.gravar(travada, "A")
        g.gravar(AjustesDaCamera(travaBalanco: true), "B")
        XCTAssertEqual(d.string(forKey: "camera.ajustes.A"), travada.json)
        XCTAssertEqual(g.ler("A"), travada)
        // "Restaurar automático" (gravar o padrão) não apaga o guardado (07/10): ele é "meus ajustes".
        g.gravar(.padrao, "A")
        XCTAssertEqual(d.string(forKey: "camera.ajustes.A"), travada.json)
        XCTAssertEqual(g.ler("A"), travada)
        XCTAssertEqual(g.ler("B"), AjustesDaCamera(travaBalanco: true))
        // Um manual novo substitui o guardado, só daquela câmera.
        g.gravar(AjustesDaCamera(foco: .travado), "A")
        XCTAssertEqual(g.ler("A"), AjustesDaCamera(foco: .travado))
        XCTAssertEqual(g.ler("B"), AjustesDaCamera(travaBalanco: true))
        // Um valor estragado volta ao padrão, sem derrubar nada.
        d.set("{", forKey: "camera.ajustes.C")
        XCTAssertEqual(g.ler("C"), .padrao)
    }

    // MARK: abrir no automático e lembrar o último manual (07/10)

    func testeAbrirEhSempreNoAutomatico() {
        XCTAssertEqual(MeusAjustes.aoAbrir(guardado: .padrao), .padrao)
        XCTAssertEqual(MeusAjustes.aoAbrir(guardado: AjustesDaCamera(travaExposicao: true, travaBalanco: true,
                                                                      foco: .travado)), .padrao)
    }

    func testeSoOManualEhGravado() {
        XCTAssertNil(MeusAjustes.paraGravar(.padrao))
        XCTAssertEqual(MeusAjustes.paraGravar(AjustesDaCamera(travaBalanco: true)), AjustesDaCamera(travaBalanco: true))
    }

    func testeUsarMeusAjustesSoQuandoTrazAlgoNovo() {
        let tudo = CapacidadesDaCamera(exposicaoContinua: true, exposicaoTravada: true, balancoContinuo: true,
                                       balancoTravado: true, focoContinuo: true, focoTravado: true)
        let semFoco = CapacidadesDaCamera(exposicaoContinua: true, exposicaoTravada: true, balancoContinuo: true,
                                          balancoTravado: true)
        let meus = AjustesDaCamera(travaExposicao: true, foco: .travado)
        // Abriu no automático com um guardado: oferece, e recuperar traz o guardado inteiro.
        XCTAssertTrue(MeusAjustes.oferecer(guardado: meus, corrente: .padrao, tudo))
        XCTAssertEqual(MeusAjustes.recuperar(meus, tudo), meus)
        // Já está valendo: não oferece.
        XCTAssertFalse(MeusAjustes.oferecer(guardado: meus, corrente: meus, tudo))
        // Sem guardado: não oferece.
        XCTAssertFalse(MeusAjustes.oferecer(guardado: .padrao, corrente: .padrao, tudo))
        XCTAssertFalse(MeusAjustes.oferecer(guardado: .padrao, corrente: AjustesDaCamera(travaBalanco: true), tudo))
        // Corrente diferente do guardado (outra trava): oferece.
        XCTAssertTrue(MeusAjustes.oferecer(guardado: meus, corrente: AjustesDaCamera(travaBalanco: true), tudo))
        // A câmera não trava mais o foco: o guardado vem cortado, e o que sobra é o que conta.
        XCTAssertEqual(MeusAjustes.recuperar(meus, semFoco), AjustesDaCamera(travaExposicao: true))
        XCTAssertFalse(MeusAjustes.oferecer(guardado: meus, corrente: AjustesDaCamera(travaExposicao: true), semFoco))
        XCTAssertFalse(MeusAjustes.oferecer(guardado: AjustesDaCamera(foco: .travado), corrente: .padrao, semFoco))
    }

    func testeOCicloAbrirTravarRestaurarReabrirRecuperar() throws {
        let dominio = "quall.testes.ajustes.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: dominio))
        defer { d.removePersistentDomain(forName: dominio) }
        let g = GuardaDosAjustes(d)
        let c = CapacidadesDaCamera(exposicaoContinua: true, exposicaoTravada: true, balancoContinuo: true,
                                    balancoTravado: true)
        // Primeira abertura: automático, nada guardado, nada a oferecer.
        var corrente = MeusAjustes.aoAbrir(guardado: g.ler("A"))
        XCTAssertEqual(corrente, .padrao)
        XCTAssertFalse(MeusAjustes.oferecer(guardado: g.ler("A"), corrente: corrente, c))
        // A pessoa trava a exposição: grava.
        corrente = AjustesDaCamera(travaExposicao: true)
        g.gravar(corrente, "A")
        // Restaurar automático: o corrente volta, o guardado fica e passa a ser oferecido.
        corrente = .padrao
        g.gravar(corrente, "A")
        XCTAssertEqual(g.ler("A"), AjustesDaCamera(travaExposicao: true))
        XCTAssertTrue(MeusAjustes.oferecer(guardado: g.ler("A"), corrente: corrente, c))
        // Fechar e reabrir: automático de novo, com o guardado oferecido.
        corrente = MeusAjustes.aoAbrir(guardado: g.ler("A"))
        XCTAssertEqual(corrente, .padrao)
        XCTAssertTrue(MeusAjustes.oferecer(guardado: g.ler("A"), corrente: corrente, c))
        // Usar meus ajustes: volta a trava, e o botão some.
        corrente = MeusAjustes.recuperar(g.ler("A"), c)
        g.gravar(corrente, "A")
        XCTAssertEqual(corrente, AjustesDaCamera(travaExposicao: true))
        XCTAssertFalse(MeusAjustes.oferecer(guardado: g.ler("A"), corrente: corrente, c))
    }

    func testeOPedidoEhCortadoPeloQueACameraFaz() {
        let tudo = AjustesDaCamera(travaExposicao: true, travaBalanco: true, foco: .travado)
        XCTAssertEqual(tudo.cortado(por: completa), tudo)
        XCTAssertEqual(tudo.cortado(por: embutida), AjustesDaCamera(travaExposicao: true, travaBalanco: true, foco: .auto))
        XCTAssertEqual(tudo.cortado(por: CapacidadesDaCamera()), .padrao)
    }

    // MARK: - os textos (§3.5)

    func testeAsFrasesDoLimiteSaoAsLiterais() {
        XCTAssertEqual(TextoDoLimite.doMacOS([.compensacao]), "O macOS não oferece a compensação de exposição para câmeras.")
        XCTAssertEqual(TextoDoLimite.doMacOS([.antiCintilacao]), "O macOS não oferece a anti-cintilação para câmeras.")
        XCTAssertEqual(TextoDoLimite.doMacOS([.kelvin]), "O macOS não oferece o Kelvin para câmeras.")
        XCTAssertEqual(TextoDoLimite.doMacOS([.focoManual]), "O macOS não oferece o foco manual para câmeras.")
        XCTAssertEqual(TextoDoLimite.doMacOS([.iso, .obturador]), "O macOS não oferece ISO e o obturador para câmeras.")
        XCTAssertEqual(TextoDoLimite.daCamera(.travaFoco), "Esta câmera não oferece a trava de foco.")
        XCTAssertEqual(TextoDoLimite.focoFixo, "Esta câmera tem foco fixo.")
        XCTAssertEqual(TextoDoLimite.juntar([.iso, .obturador, .kelvin]), "ISO, o obturador e o Kelvin")
    }

    // MARK: - capacidades → painel (§4.3)

    func testeNoMacOsGruposDoSistemaFicamApagadosComOTextoDoMacOS() {
        for c in [completa, embutida, CapacidadesDaCamera()] {
            let p = PlanoDoPainel.doMac(c)
            XCTAssertFalse(p.ev.disponivel)
            XCTAssertEqual(p.ev.limite, "O macOS não oferece a compensação de exposição para câmeras.")
            XCTAssertFalse(p.antiCintilacao.disponivel)
            XCTAssertFalse(p.exposicaoManual.disponivel)
            // ISO e obturador: uma linha só, e não uma lista de linhas apagadas.
            XCTAssertEqual(p.linhaDoIsoEObturador, "O macOS não oferece ISO e o obturador para câmeras.")
            XCTAssertEqual(p.gradeDoBalanco.map(\.0.rawValue),
                           ["Auto", "Incandescente", "Fluorescente", "Luz do dia", "Nublado", "Kelvin"])
            XCTAssertEqual(p.gradeDoBalanco.filter(\.1).map(\.0), [.auto])
            XCTAssertEqual(p.limitesDoBalanco, ["O macOS não oferece os presets de balanço para câmeras.",
                                                "O macOS não oferece o Kelvin para câmeras."])
            XCTAssertFalse(p.focoManual.disponivel)
            XCTAssertFalse(p.linhaDeLeitura)
        }
    }

    func testeAsTravasAcendemSoOndeACameraAceitaLocked() {
        let p = PlanoDoPainel.doMac(completa)
        XCTAssertTrue(p.travaExposicao.disponivel)
        XCTAssertTrue(p.travaBalanco.disponivel)
        XCTAssertTrue(p.focoTravado.disponivel)
        XCTAssertNil(p.linhaDoFocoFixo)
        XCTAssertEqual(p.notaDoToque, "Toque na imagem para focar e medir naquele ponto.")

        let nenhuma = PlanoDoPainel.doMac(CapacidadesDaCamera(exposicaoContinua: true, balancoContinuo: true,
                                                              focoContinuo: true))
        XCTAssertEqual(nenhuma.travaExposicao, .apagado("Esta câmera não oferece a trava de exposição."))
        XCTAssertEqual(nenhuma.travaBalanco, .apagado("Esta câmera não oferece a trava de balanço."))
        XCTAssertEqual(nenhuma.focoTravado, .apagado("Esta câmera não oferece a trava de foco."))
        XCTAssertFalse(nenhuma.toqueDisponivel)
        XCTAssertEqual(nenhuma.notaDoToque, "Esta câmera não oferece o toque para focar.")
    }

    func testeFocoFixoViraUmaLinhaSo() {
        let p = PlanoDoPainel.doMac(embutida)
        XCTAssertEqual(p.linhaDoFocoFixo, "Esta câmera tem foco fixo.")
        XCTAssertFalse(p.focoTravado.disponivel)
        // `.locked` declarado numa câmera sem AF não acende a trava de foco: não há o que travar.
        var c = embutida
        c.focoTravado = true
        XCTAssertFalse(c.podeTravarFoco)
        XCTAssertTrue(PlanoDoPainel.doMac(c).linhaDoFocoFixo != nil)
    }

    // MARK: - o clique na prévia (§4.4)

    func testeCliqueSimplesMedeEFocaSemTravar() {
        let d = DecisaoDoClique.decidir(.padrao, completa, travarAli: false, pilulaAcesa: false)
        XCTAssertTrue(d.medir)
        XCTAssertTrue(d.focar)
        XCTAssertTrue(d.quadrado)
        XCTAssertEqual(d.ajustes, .padrao)
        XCTAssertNil(d.pilula)
    }

    func testeOpcaoCliqueTravaAsDuasComAPilula() {
        let d = DecisaoDoClique.decidir(.padrao, completa, travarAli: true, pilulaAcesa: false)
        XCTAssertTrue(d.medir && d.focar)
        XCTAssertTrue(d.ajustes.travaExposicao)
        XCTAssertEqual(d.ajustes.foco, .travado)
        XCTAssertFalse(d.ajustes.travaBalanco, "o ⌥-clique não mexe no balanço")
        XCTAssertEqual(d.pilula, "Exposição e foco travados")
    }

    func testeComFocoFixoOClicaSoMedeEAPilulaDizSoExposicao() {
        var c = embutida
        c.pontoDeExposicao = true
        let simples = DecisaoDoClique.decidir(.padrao, c, travarAli: false, pilulaAcesa: false)
        XCTAssertTrue(simples.medir)
        XCTAssertFalse(simples.focar)
        let travar = DecisaoDoClique.decidir(.padrao, c, travarAli: true, pilulaAcesa: false)
        XCTAssertEqual(travar.pilula, "Exposição travada")
        XCTAssertEqual(travar.ajustes.foco, .auto)
    }

    func testeSemPontoDeExposicaoSoFocaEAPilulaDizSoFoco() {
        var c = completa
        c.pontoDeExposicao = false
        let d = DecisaoDoClique.decidir(.padrao, c, travarAli: true, pilulaAcesa: false)
        XCTAssertFalse(d.medir)
        XCTAssertTrue(d.focar)
        XCTAssertFalse(d.ajustes.travaExposicao)
        XCTAssertEqual(d.pilula, "Foco travado")
    }

    func testeSemPontoNenhumOClicaNaoFazNadaENaoHaQuadrado() {
        let d = DecisaoDoClique.decidir(.padrao, embutida, travarAli: true, pilulaAcesa: false)
        XCTAssertFalse(d.quadrado)
        XCTAssertEqual(d.ajustes, .padrao)
        XCTAssertNil(d.pilula)
    }

    func testeUmCliqueSimplesDepoisDoOpcaoCliqueDesfazAsDuasTravas() {
        let travado = DecisaoDoClique.decidir(.padrao, completa, travarAli: true, pilulaAcesa: false)
        let depois = DecisaoDoClique.decidir(travado.ajustes, completa, travarAli: false, pilulaAcesa: true)
        XCTAssertTrue(depois.medir && depois.focar)
        XCTAssertFalse(depois.ajustes.travaExposicao)
        XCTAssertEqual(depois.ajustes.foco, .auto)
        XCTAssertNil(depois.pilula)
    }

    /// Travas postas pelo painel (sem pílula) valem como "Manual" para o clique: a exposição travada só
    /// deixa focar, o foco travado só deixa medir, e as duas não deixam nada.
    func testeTravasDoPainelNaoSaoDesfeitasPorUmClique() {
        let exp = DecisaoDoClique.decidir(AjustesDaCamera(travaExposicao: true), completa, travarAli: false, pilulaAcesa: false)
        XCTAssertFalse(exp.medir)
        XCTAssertTrue(exp.focar)
        XCTAssertTrue(exp.ajustes.travaExposicao)
        let foco = DecisaoDoClique.decidir(AjustesDaCamera(foco: .travado), completa, travarAli: false, pilulaAcesa: false)
        XCTAssertTrue(foco.medir)
        XCTAssertFalse(foco.focar)
        let duas = DecisaoDoClique.decidir(AjustesDaCamera(travaExposicao: true, foco: .travado), completa,
                                           travarAli: true, pilulaAcesa: false)
        XCTAssertFalse(duas.quadrado)
        XCTAssertNil(duas.pilula)
    }

    func testeDesligarATravaPeloPainelTiraAPilula() {
        let duas = TextosDosAjustes.pilulaDasDuas
        XCTAssertEqual(DecisaoDoClique.pilulaDepoisDoPainel(acesa: duas, novo: AjustesDaCamera(travaExposicao: true, foco: .travado)), duas)
        XCTAssertNil(DecisaoDoClique.pilulaDepoisDoPainel(acesa: duas, novo: AjustesDaCamera(foco: .travado)))
        XCTAssertNil(DecisaoDoClique.pilulaDepoisDoPainel(acesa: duas, novo: AjustesDaCamera(travaExposicao: true)))
        XCTAssertNil(DecisaoDoClique.pilulaDepoisDoPainel(acesa: TextosDosAjustes.pilulaDoFoco, novo: .padrao))
        // Mexer no balanço não apaga a pílula da exposição.
        XCTAssertEqual(DecisaoDoClique.pilulaDepoisDoPainel(acesa: TextosDosAjustes.pilulaDaExposicao,
                                                            novo: AjustesDaCamera(travaExposicao: true, travaBalanco: true)),
                       TextosDosAjustes.pilulaDaExposicao)
        XCTAssertNil(DecisaoDoClique.pilulaDepoisDoPainel(acesa: nil, novo: AjustesDaCamera(travaExposicao: true)))
    }

    // MARK: - aplicar e reaplicar (§2.1, caso "sem manual")

    /// Ao reabrir, a trava **não** é "trave no que estiver agora": mede e trava sozinha ao convergir
    /// (`.autoExpose`, `.autoWhiteBalance`, `.autoFocus`), e a tela diz.
    func testeReaplicarMedeAntesDeTravar() {
        let a = AjustesDaCamera(travaExposicao: true, travaBalanco: true, foco: .travado)
        let p = PlanoDeAplicar.para(a, completa, reaplicando: true)
        XCTAssertEqual(p, PlanoDeAplicar(exposicao: .medirETravar, balanco: .medirETravar, foco: .medirETravar))
        XCTAssertTrue(p.travaDepoisDeMedir)
    }

    /// Sem o modo "uma vez", espera parar de ajustar e trava (no máximo 3 s).
    func testeSemOModoUmaVezEsperaETrava() {
        let a = AjustesDaCamera(travaExposicao: true, travaBalanco: true)
        let p = PlanoDeAplicar.para(a, embutida, reaplicando: true)
        XCTAssertEqual(p.exposicao, .esperarETravar)
        XCTAssertEqual(p.balanco, .esperarETravar)
        XCTAssertEqual(p.foco, .nada, "foco fixo: não há modo contínuo para pôr")
        XCTAssertTrue(p.travaDepoisDeMedir)
    }

    /// Pelo painel, a cena já está medida: trava na hora.
    func testePeloPainelTravaNaHora() {
        let a = AjustesDaCamera(travaExposicao: true, travaBalanco: false, foco: .travado)
        let p = PlanoDeAplicar.para(a, completa, reaplicando: false)
        XCTAssertEqual(p, PlanoDeAplicar(exposicao: .travarJa, balanco: .automatico, foco: .travarJa))
        XCTAssertFalse(p.travaDepoisDeMedir)
    }

    func testeDestravadoVoltaAoContinuoENadaSemOModo() {
        XCTAssertEqual(PlanoDeAplicar.para(.padrao, completa, reaplicando: true),
                       PlanoDeAplicar(exposicao: .automatico, balanco: .automatico, foco: .automatico))
        XCTAssertFalse(PlanoDeAplicar.para(.padrao, completa, reaplicando: true).travaDepoisDeMedir)
        XCTAssertEqual(PlanoDeAplicar.para(.padrao, CapacidadesDaCamera(), reaplicando: true),
                       PlanoDeAplicar(exposicao: .nada, balanco: .nada, foco: .nada))
    }

    /// Uma trava guardada numa câmera que (agora) não aceita `.locked` não é aplicada, e o registro fica
    /// intacto (quem decide é o dono, que só grava o que a pessoa mudou).
    func testeTravaGuardadaSemSuporteNaoAplicaNada() {
        let a = AjustesDaCamera(travaExposicao: true, travaBalanco: true, foco: .travado)
        let p = PlanoDeAplicar.para(a, CapacidadesDaCamera(exposicaoContinua: true, balancoContinuo: true, focoContinuo: true),
                                    reaplicando: true)
        XCTAssertEqual(p, PlanoDeAplicar(exposicao: .nada, balanco: .nada, foco: .nada))
        XCTAssertFalse(p.travaDepoisDeMedir)
    }

    // MARK: - a luma média (bancada, §5)

    private func quadro420v(_ l: Int, _ a: Int, y: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let atributos = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, l, a, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           atributos, &pb), kCVReturnSuccess)
        let b = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let linha = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        for j in 0..<a { for i in 0..<l { base[j * linha + i] = y(i, j) } }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    func testeALumaMediaDeUmQuadroUniformeEhOValor() throws {
        let b = try quadro420v(64, 36) { _, _ in 120 }
        XCTAssertEqual(try XCTUnwrap(LumaMedia.calcular(b, passo: 8)), 120, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(LumaMedia.calcular(b, passo: 1)), 120, accuracy: 0.0001)
    }

    func testeALumaMediaAcompanhaOBrilho() throws {
        // Metade de cima escura (16), metade de baixo clara (235): a média fica no meio.
        let b = try quadro420v(1280, 720) { _, j in j < 360 ? 16 : 235 }
        let m = try XCTUnwrap(LumaMedia.calcular(b, passo: 8))
        XCTAssertEqual(m, (16 + 235) / 2, accuracy: 0.6)
        let claro = try quadro420v(1280, 720) { _, _ in 200 }
        XCTAssertGreaterThan(try XCTUnwrap(LumaMedia.calcular(claro)), m)
    }

    func testeALumaMediaRecusaFormatoSemPlanoY() throws {
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb), kCVReturnSuccess)
        XCTAssertNil(LumaMedia.calcular(try XCTUnwrap(pb)))
    }

    /// **O custo**, num quadro 1080p 420v sintético (o formato da melhor imagem): a média de 200
    /// cálculos com passo 8. Um quadro a cada 30 a 30 fps é um cálculo por segundo; o orçamento é que
    /// ele não pese na fila da câmera (bem abaixo de 1 ms).
    func testeOCustoDaLumaMediaEm1080p() throws {
        let b = try quadro420v(1920, 1080) { i, j in UInt8((i &+ j) & 0xFF) }
        _ = LumaMedia.calcular(b)
        let n = 200
        let t0 = DispatchTime.now().uptimeNanoseconds
        var s = 0.0
        for _ in 0..<n { s += LumaMedia.calcular(b) ?? 0 }
        let porQuadro = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(n) / 1_000
        print(String(format: "LUMA_MEDIA custo 1920x1080 passo 8: %.1f µs por quadro (média de %d; soma %.0f)", porQuadro, n, s))
        XCTAssertLessThan(porQuadro, 2_000, "a luma média de um quadro 1080p passou de 2 ms")
    }

    // MARK: - a pouca luz (§3.1)

    func testOPisoDoAutomaticoEAMetadeDoFps() {
        XCTAssertEqual(PoucaLuz.piso(faixas: [(1, 30)], fps: 30), 15)
        XCTAssertEqual(PoucaLuz.piso(faixas: [(1, 30)], fps: 15), 10, "a metade de 15 seria 7,5: fica em 10")
        XCTAssertEqual(PoucaLuz.piso(faixas: [(25, 30)], fps: 30), 25, "a faixa não desce de 25")
        XCTAssertEqual(PoucaLuz.piso(faixas: [(30, 30)], fps: 30), 30, "faixa fixa: o fps de antes")
        XCTAssertEqual(PoucaLuz.piso(faixas: [(1, 30)], fps: 60), 60, "nenhuma faixa alcança 60")
    }

    func testAPoucaLuzAcendeEApagaPeloFpsMedido() {
        var v = PoucaLuz.Vigia()
        XCTAssertNil(v.observar(fpsMedido: 15, fps: 30, agora: 0))
        XCTAssertEqual(v.observar(fpsMedido: 15, fps: 30, agora: 1), 15, "acende depois de 1 s")
        XCTAssertEqual(v.observar(fpsMedido: 30, fps: 30, agora: 1.5), 30, "um meio segundo normal não apaga")
        XCTAssertNil(v.observar(fpsMedido: 30, fps: 30, agora: 3.5), "2 s normais apagam")
        var w = PoucaLuz.Vigia()
        _ = w.observar(fpsMedido: 28, fps: 30, agora: 0)
        XCTAssertNil(w.observar(fpsMedido: 28, fps: 30, agora: 5), "28 de 30 é oscilação, não aviso")
    }

    func testOTextoDaPoucaLuz() {
        XCTAssertEqual(PoucaLuz.texto(fpsAgora: 15, fps: 30),
                       "Pouca luz: 15 fps para clarear a imagem. Mais luz no ambiente devolve os 30 fps.")
    }
}
