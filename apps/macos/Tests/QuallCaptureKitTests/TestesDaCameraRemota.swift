import CoreGraphics
import Foundation
import XCTest
@testable import QuallCaptureKit

/// O controle remoto da câmera no Mac (R9b, `docs/controle-remoto-da-camera.md`), a parte pura, **sem
/// câmera e sem rede**: as capacidades que o Mac publica, o pedido aplicado na ordem do contrato, e o painel
/// do receptor desenhado a partir das capacidades de outro aparelho.
final class TestesDaCameraRemota: XCTestCase {

    private let completa = CapacidadesDaCamera(
        exposicaoContinua: true, exposicaoUmaVez: true, exposicaoTravada: true, pontoDeExposicao: true,
        balancoContinuo: true, balancoUmaVez: true, balancoTravado: true,
        focoContinuo: true, focoUmaVez: true, focoTravado: true, pontoDeFoco: true)

    /// Exposição e balanço contínuos com trava, foco fixo, sem ponto.
    private let embutida = CapacidadesDaCamera(
        exposicaoContinua: true, exposicaoTravada: true, balancoContinuo: true, balancoTravado: true)

    private func objeto(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - as capacidades do Mac (§3.2)

    func testAsCapacidadesDoMacSaoOExemploDoContrato() {
        let o = objeto(completa.jsonRemoto(nomeDaCamera: "Câmera FaceTime HD"))
        XCTAssertEqual(o["plataforma"] as? String, "macos")
        XCTAssertEqual(o["nomeDaCamera"] as? String, "Câmera FaceTime HD")
        let controles = o["controles"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(controles.keys), ["travaExposicao", "travaBalanco", "foco", "toque"])
        XCTAssertEqual((controles["foco"] as? [String: Any])?["valores"] as? [String], ["auto", "travado"])
        XCTAssertEqual((controles["travaExposicao"] as? [String: Any])?.count, 0)
        XCTAssertEqual(o["limites"] as? [String: String],
                       ["ev": "macos", "iso": "macos", "obturadorNs": "macos", "kelvin": "macos",
                        "antiCintilacao": "macos", "focoPosicao": "macos"])
    }

    func testAEmbutidaDeFocoFixoESemPontoDizPorQue() {
        let o = objeto(embutida.jsonRemoto(nomeDaCamera: "x"))
        XCTAssertEqual(Set((o["controles"] as? [String: Any] ?? [:]).keys), ["travaExposicao", "travaBalanco"])
        let l = o["limites"] as? [String: String] ?? [:]
        XCTAssertEqual(l["foco"], "foco_fixo")
        XCTAssertEqual(l["toque"], "camera_nao_oferece")
        // Sem a trava, `camera_nao_oferece` — a frase do painel local.
        let semTrava = CapacidadesDaCamera(exposicaoContinua: true, focoContinuo: true)
        let l2 = objeto(semTrava.jsonRemoto(nomeDaCamera: "x"))["limites"] as? [String: String] ?? [:]
        XCTAssertEqual(l2["travaExposicao"], "camera_nao_oferece")
        XCTAssertEqual(l2["travaBalanco"], "camera_nao_oferece")
        XCTAssertEqual(l2["foco"], "camera_nao_oferece", "foco automático que não trava")
    }

    func testONomeDaCameraCabeEm64BytesSemQuebrarCaractere() {
        let nome = String(repeating: "ç", count: 40)  // 80 bytes
        let o = objeto(completa.jsonRemoto(nomeDaCamera: nome))
        let cortado = o["nomeDaCamera"] as? String ?? ""
        XCTAssertEqual(cortado.utf8.count, 64)
        XCTAssertEqual(cortado, String(repeating: "ç", count: 32))
        XCTAssertLessThan(completa.jsonRemoto(nomeDaCamera: nome).utf8.count, 2048)
    }

    // MARK: - o pedido (§6)

    func testOPedidoDoNucleoSeLe() throws {
        let p = try XCTUnwrap(PedidoDaCameraRemota.ler(#"""
            {"n":5,"autor":"OBS no Dell","autor_id":"dell-7f2a","ajuste":{"travaExposicao":true,"foco":"travado"},
             "restaurar":false,"toque":{"x":0.25,"y":0.75,"longo":true}}
            """#))
        XCTAssertEqual(p.n, 5)
        XCTAssertEqual(p.autor, "OBS no Dell")
        XCTAssertEqual(p.travaExposicao, true)
        XCTAssertNil(p.travaBalanco)
        XCTAssertEqual(p.foco, .travado)
        XCTAssertEqual(p.toque, .init(x: 0.25, y: 0.75, longo: true))
        XCTAssertEqual(p.naoAplicaveis, [])
        XCTAssertNil(PedidoDaCameraRemota.ler(#"{"ajuste":{}}"#), "sem n não é pedido")
    }

    func testCampoQueOMacNaoAplicaERecusado() throws {
        let p = try XCTUnwrap(PedidoDaCameraRemota.ler(#"{"n":1,"ajuste":{"iso":800,"travaBalanco":1}}"#))
        XCTAssertEqual(p.naoAplicaveis, ["iso", "travaBalanco"], "1 não é booleano")
        XCTAssertEqual(p.aplicar(sobre: .padrao, completa, pilulaAcesa: false), .recusar("campo_desconhecido"))
    }

    func testAsTravasEOFocoEntram() throws {
        let p = try XCTUnwrap(PedidoDaCameraRemota.ler(#"{"n":2,"ajuste":{"travaExposicao":true,"foco":"travado"}}"#))
        guard case .aplicar(let a, let clique, let ponto, let centro) = p.aplicar(sobre: .padrao, completa, pilulaAcesa: false) else {
            return XCTFail("recusou")
        }
        XCTAssertEqual(a, AjustesDaCamera(travaExposicao: true, foco: .travado))
        XCTAssertNil(clique)
        XCTAssertNil(ponto)
        XCTAssertFalse(centro)
    }

    func testRestaurarVemAntesDosCampos() throws {
        let p = try XCTUnwrap(PedidoDaCameraRemota.ler(#"{"n":3,"restaurar":true,"ajuste":{"travaBalanco":true}}"#))
        let atual = AjustesDaCamera(travaExposicao: true, travaBalanco: false, foco: .travado)
        guard case .aplicar(let a, _, _, let centro) = p.aplicar(sobre: atual, completa, pilulaAcesa: true) else {
            return XCTFail("recusou")
        }
        XCTAssertEqual(a, AjustesDaCamera(travaBalanco: true), "parte do padrão, e o campo vale por cima")
        XCTAssertTrue(centro, "restaurar volta o ponto ao centro")
    }

    func testATravaQueACameraNaoAceitaNaoEntraCalada() throws {
        let p = try XCTUnwrap(PedidoDaCameraRemota.ler(#"{"n":4,"ajuste":{"foco":"travado"}}"#))
        XCTAssertEqual(p.aplicar(sobre: .padrao, embutida, pilulaAcesa: false), .recusar("nao_aplicado"))
    }

    func testOToqueEOCliqueDaPrevia() throws {
        // Toque longo: mede, foca e trava ali, como o ⌥-clique.
        let p = try XCTUnwrap(PedidoDaCameraRemota.ler(#"{"n":6,"toque":{"x":0.2,"y":0.3,"longo":true}}"#))
        guard case .aplicar(let a, let clique, let ponto, _) = p.aplicar(sobre: .padrao, completa, pilulaAcesa: false) else {
            return XCTFail("recusou")
        }
        XCTAssertEqual(ponto, CGPoint(x: 0.2, y: 0.3))
        XCTAssertEqual(clique?.medir, true)
        XCTAssertEqual(clique?.focar, true)
        XCTAssertEqual(a, AjustesDaCamera(travaExposicao: true, foco: .travado))
        XCTAssertEqual(clique?.pilula, TextosDosAjustes.pilulaDasDuas)

        // Toque simples depois da pílula: desfaz as travas dela.
        let simples = try XCTUnwrap(PedidoDaCameraRemota.ler(#"{"n":7,"toque":{"x":0.5,"y":0.5,"longo":false}}"#))
        guard case .aplicar(let b, let c2, _, _) = simples.aplicar(sobre: a, completa, pilulaAcesa: true) else {
            return XCTFail("recusou")
        }
        XCTAssertEqual(b, .padrao)
        XCTAssertNil(c2?.pilula)

        // Sem ponto nenhum: aplica (o recibo sai), sem quadrado.
        guard case .aplicar(let c, let c3, _, _) = simples.aplicar(sobre: .padrao, embutida, pilulaAcesa: false) else {
            return XCTFail("recusou")
        }
        XCTAssertEqual(c, .padrao)
        XCTAssertEqual(c3?.quadrado, false)

        let fora = try XCTUnwrap(PedidoDaCameraRemota.ler(#"{"n":8,"toque":{"x":1.2,"y":0.5,"longo":false}}"#))
        XCTAssertEqual(fora.aplicar(sobre: .padrao, completa, pilulaAcesa: false), .recusar("fora_da_imagem"))
    }

    // MARK: - o painel do receptor (§12)

    /// O estado de um receptor diante de um iPhone filmando: ISO, obturador, Kelvin, foco manual.
    private func estadoDoIphone(situacao: String = "pronto", ajuste: String = #"{"exposicao":"manual","iso":400,"obturadorNs":16666667,"balanco":"kelvin","kelvin":5200,"foco":"manual","focoPosicao":0.5}"#) -> EstadoDaCameraRemota {
        EstadoDaCameraRemota.ler(#"""
            {"situacao":"\#(situacao)","capacidades":{"plataforma":"ios","nomeDaCamera":"Câmera Traseira",
              "controles":{"exposicao":{"valores":["auto","manual"]},"ev":{"min":-2,"max":2,"passo":0.333},
               "travaExposicao":{},"iso":{"min":25,"max":2000,"inteiro":true},
               "obturadorNs":{"min":100000,"max":33333333,"inteiro":true},
               "balanco":{"valores":["auto","incandescente","fluorescente","luzDoDia","nublado","kelvin"]},
               "kelvin":{"min":2000,"max":10000,"passo":100,"inteiro":true},"travaBalanco":{},
               "foco":{"valores":["auto","travado","manual"]},"focoPosicao":{"min":0,"max":1,"passo":0.01},"toque":{}},
              "limites":{"antiCintilacao":"ios_cintilacao"}},
             "ajuste":\#(ajuste),"aplicado":{},"pendente":null,
             "lido":{"iso":400,"obturadorNs":16666667,"kelvin":5150,"abertura":1.8,"divergentes":["kelvin"]},
             "autor":null,"versao":3,"recusa":null,"contadores":{}}
            """#)!
    }

    func testOIphoneFilmandoMostraTudoNoMac() throws {
        let p = try XCTUnwrap(PlanoRemotoDoPainel.de(estadoDoIphone()))
        XCTAssertTrue(p.vivo)
        XCTAssertNil(p.aviso)
        XCTAssertEqual(p.nome, "Câmera Traseira")
        XCTAssertEqual(p.lido, "ISO 400 · 1/60 s · 5150 K · f/1,8")
        XCTAssertEqual(p.divergencias, ["A câmera usou 5150 K em vez de 5200 K."])
        XCTAssertEqual(p.exposicao.map(\.escolhida), [false, true])
        XCTAssertEqual(p.exposicao.map(\.disponivel), [true, true])
        // Com Manual: o EV e a trava apagados, ISO e obturador vivos.
        XCTAssertEqual(p.ev?.disponivel, false)
        XCTAssertEqual(p.travaExposicao?.disponivel, false)
        XCTAssertFalse(p.passeParaManual)
        let iso = try XCTUnwrap(p.iso)
        XCTAssertTrue(iso.disponivel)
        XCTAssertEqual(iso.degraus.first, 25)
        XCTAssertEqual(iso.degraus.last, 2000)
        XCTAssertTrue(iso.degraus.contains(400))
        XCTAssertEqual(iso.texto, "ISO 400")
        let ob = try XCTUnwrap(p.obturador)
        XCTAssertEqual(ob.texto, "1/60 s")
        XCTAssertTrue(ob.textos.contains("1/30 s"))
        XCTAssertFalse(ob.textos.contains("1/24 s"), "acima do teto de 1/30")
        XCTAssertEqual(p.linhaDaAntiCintilacao, "O iOS ajusta a cintilação sozinho.")
        XCTAssertEqual(p.balanco.filter(\.disponivel).count, 6)
        XCTAssertEqual(p.kelvin?.texto, "5200 K")
        XCTAssertNil(p.travaBalanco, "com Kelvin a trava some")
        XCTAssertEqual(p.foco.map(\.disponivel), [true, true, true])
        XCTAssertEqual(p.focoPosicao?.texto, "0,50")
        XCTAssertTrue(p.toqueDisponivel)
    }

    func testComAutoOIsoPedeManual() throws {
        let e = estadoDoIphone(ajuste: #"{"exposicao":"auto","travaExposicao":true,"ev":0}"#)
        let p = try XCTUnwrap(PlanoRemotoDoPainel.de(e))
        XCTAssertTrue(p.passeParaManual)
        XCTAssertEqual(p.ev?.disponivel, false)
        XCTAssertEqual(p.ev?.linha, "Destrave a exposição para compensar.")
        XCTAssertEqual(p.travaExposicao?.disponivel, true)
        XCTAssertEqual(p.travaExposicao?.ligado, true)
        XCTAssertEqual(p.ev?.texto, "0 EV")
    }

    func testNaoPermitidoMostraOsValoresApagados() throws {
        let p = try XCTUnwrap(PlanoRemotoDoPainel.de(estadoDoIphone(situacao: "nao_permitido")))
        XCTAssertFalse(p.vivo)
        XCTAssertEqual(p.aviso, "O aparelho não permite controle remoto da câmera")
        XCTAssertEqual(p.iso?.texto, "ISO 400", "os valores à mostra")
        XCTAssertEqual(p.iso?.disponivel, false)
        XCTAssertFalse(p.exposicao.contains { $0.disponivel })
        XCTAssertFalse(p.toqueDisponivel)
    }

    func testAsOutrasSituacoesNaoMostramControle() {
        for s in ["esperando", "sem_resposta", "sem_camera"] {
            XCTAssertNil(PlanoRemotoDoPainel.de(estadoDoIphone(situacao: s)), s)
        }
    }

    func testOMacFilmandoNoMacRecebendo() throws {
        let caps = completa.jsonRemoto(nomeDaCamera: "Câmera FaceTime HD")
        let e = try XCTUnwrap(EstadoDaCameraRemota.ler(#"{"situacao":"pronto","capacidades":\#(caps),"ajuste":{"exposicao":"auto","travaExposicao":true,"balanco":"auto","travaBalanco":false,"foco":"travado"},"lido":{}}"#))
        let p = try XCTUnwrap(PlanoRemotoDoPainel.de(e))
        XCTAssertNil(p.lido, "o Mac não lê nada")
        XCTAssertEqual(p.exposicao.map(\.disponivel), [false, false], "o Mac não anuncia o modo")
        XCTAssertEqual(p.exposicao.map(\.escolhida), [true, false])
        XCTAssertEqual(p.linhaDaExposicao, "O macOS não oferece ISO e o obturador para câmeras.")
        XCTAssertEqual(p.linhaDoIsoEObturador, "O macOS não oferece ISO e o obturador para câmeras.")
        XCTAssertNil(p.ev)
        XCTAssertEqual(p.linhaDoEv, "O macOS não oferece a compensação de exposição para câmeras.")
        XCTAssertEqual(p.travaExposicao?.disponivel, true)
        XCTAssertEqual(p.travaExposicao?.ligado, true)
        XCTAssertEqual(p.limitesDoBalanco, ["O macOS não oferece os presets de balanço para câmeras.",
                                            "O macOS não oferece o Kelvin para câmeras."])
        XCTAssertEqual(p.foco.map(\.disponivel), [true, true, false])
        XCTAssertEqual(p.foco.map(\.escolhida), [false, true, false])
        XCTAssertEqual(p.limitesDoFoco, ["O macOS não oferece o foco manual para câmeras."])
        XCTAssertEqual(p.linhaDaAntiCintilacao, "O macOS não oferece a anti-cintilação para câmeras.")
    }

    func testOWindowsDizBrilhoGanhoEObturadorEmLog2() throws {
        let e = try XCTUnwrap(EstadoDaCameraRemota.ler(#"""
            {"situacao":"pronto","capacidades":{"plataforma":"windows","nomeDaCamera":"Logi C920",
              "controles":{"exposicao":{"valores":["auto","manual"]},
               "ev":{"min":-64,"max":64,"passo":1,"inteiro":true,"unidade":"brilho","origem":128},
               "iso":{"min":0,"max":255,"passo":1,"inteiro":true,"unidade":"ganho"},
               "obturadorNs":{"min":1000000,"max":33333333,"inteiro":true,"escala":"log2"}},
              "limites":{"foco":"camera_nao_oferece","focoPosicao":"camera_nao_oferece","toque":"camera_nao_oferece"}},
             "ajuste":{"exposicao":"manual","ev":2,"iso":64,"obturadorNs":31250000}}
            """#))
        let p = try XCTUnwrap(PlanoRemotoDoPainel.de(e))
        XCTAssertEqual(PlanoRemotoDoPainel.linhaDoLido(
            LidoRemoto.ler(["iso": 64, "obturadorNs": 31_250_000]), e.capacidades), "Ganho 64 · 1/32 s")
        XCTAssertEqual(p.ev?.titulo, "Brilho")
        XCTAssertEqual(p.ev?.texto, "130", "origem + valor, o número cru do driver")
        XCTAssertEqual(p.tituloDaAbaDoIso, "Ganho e obturador")
        XCTAssertEqual(p.iso?.titulo, "Ganho")
        XCTAssertEqual(p.iso?.texto, "64")
        XCTAssertEqual(p.obturador?.textos, ["1/32 s", "1/64 s", "1/128 s", "1/256 s", "1/512 s"],
                       "2^v de 1/1000 s a 1/30 s, do mais longo ao mais curto")
        XCTAssertEqual(p.obturador?.texto, "1/32 s")
        XCTAssertEqual(p.limitesDoFoco, ["Esta câmera não oferece a trava de foco.",
                                         "Esta câmera não oferece o foco manual."])
        XCTAssertEqual(p.notaDoToque, "Esta câmera não oferece o toque para focar.")
        XCTAssertEqual(p.travaExposicao?.linha, "Este aparelho não oferece a trava de exposição.")
    }

    func testAsRecusasViramAsFrasesDoContrato() {
        let c = estadoDoIphone().capacidades
        XCTAssertEqual(TextosDaCameraRemota.recusa("fora_da_faixa", campo: "iso", c), "Este aparelho não aceitou ISO.")
        XCTAssertEqual(TextosDaCameraRemota.recusa("incoerente", campo: nil, c), "Este aparelho não aceitou o ajuste.")
        XCTAssertEqual(TextosDaCameraRemota.recusa("sem_resposta", campo: nil, c), "O aparelho não respondeu.")
        XCTAssertEqual(TextosDaCameraRemota.recusa("codigo_novo_x", campo: nil, c), "O aparelho não conseguiu aplicar o ajuste.")
        XCTAssertNil(TextosDaCameraRemota.recusa("superado", campo: "iso", c))
        XCTAssertNil(TextosDaCameraRemota.recusa("camera_trocada", campo: nil, c))
        XCTAssertEqual(TextosDaCameraRemota.limite("fabricante", [.iso]),
                       "O fabricante deste aparelho não libera ISO para outros apps.")
        XCTAssertEqual(TextosDaCameraRemota.limite("sem_calibracao", [.kelvin]),
                       "Esta câmera não publica a calibração de cor que o Kelvin precisa.")
        XCTAssertEqual(TextosDaCameraRemota.limite("outro_app", [.iso]),
                       "Outro app está controlando esta câmera. Feche-o para ajustar.")
    }

    func testARecusaApareceNoAlto() throws {
        var e = estadoDoIphone()
        e.recusa = ("fora_da_faixa", "kelvin")
        XCTAssertEqual(PlanoRemotoDoPainel.de(e)?.aviso, "Este aparelho não aceitou o Kelvin.")
    }

    func testOsNumerosComVirgula() {
        XCTAssertEqual(NumerosDaCamera.ev(0.333), "+0,3 EV")
        XCTAssertEqual(NumerosDaCamera.ev(-1), "-1 EV")
        XCTAssertEqual(NumerosDaCamera.ev(0.0001), "0 EV")
        XCTAssertEqual(NumerosDaCamera.obturador(ns: 8_000_000), "1/125 s")
        XCTAssertEqual(NumerosDaCamera.obturador(ns: 2e9), "2 s")
        XCTAssertEqual(NumerosDaCamera.abertura(1.7), "f/1,7")
    }

    func testOPedidoDoDeslizanteLevaInteiroSemPontoZero() throws {
        let iso = try XCTUnwrap(PlanoRemotoDoPainel.de(estadoDoIphone())?.iso)
        let i = try XCTUnwrap(iso.degraus.firstIndex(of: 800))
        XCTAssertEqual(PedidoDoReceptor.json([iso.campo: PedidoDoReceptor.valor(iso, indice: i)]), #"{"iso":800}"#)
        let foco = try XCTUnwrap(PlanoRemotoDoPainel.de(estadoDoIphone())?.focoPosicao)
        XCTAssertEqual(PedidoDoReceptor.json(["focoPosicao": PedidoDoReceptor.valor(foco, indice: 25)]), #"{"focoPosicao":0.25}"#)
    }

    // MARK: - o clique na imagem (§3.4)

    func testOCliqueViraOPontoNoQuadroEATarjaNaoManda() {
        // Vídeo 16:9 numa vista 4:3: tarjas em cima e embaixo.
        let vista = CGSize(width: 800, height: 600), video = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(PontoNoQuadro.doClique(CGPoint(x: 400, y: 300), vista: vista, video: video), CGPoint(x: 0.5, y: 0.5))
        let alto = (600 - 450) / 2.0
        XCTAssertEqual(PontoNoQuadro.doClique(CGPoint(x: 0, y: alto), vista: vista, video: video), CGPoint(x: 0, y: 0))
        XCTAssertNil(PontoNoQuadro.doClique(CGPoint(x: 400, y: 10), vista: vista, video: video), "na tarja")
        XCTAssertNil(PontoNoQuadro.doClique(CGPoint(x: 1, y: 1), vista: vista, video: .zero))
    }
}
