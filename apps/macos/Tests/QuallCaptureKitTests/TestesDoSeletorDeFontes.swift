import CoreGraphics
import XCTest
@testable import QuallCaptureKit

/// A escolha no seletor "O que transmitir" com as duas metades do catálogo (`SeletorDeFontes`).
///
/// O primeiro teste é a sequência que o registro deste MacBook mostra em 10/09 às 16:51:42: "Tela
/// estendida" escolhida, Atualizar, as câmeras voltando 13 ms antes das telas. Antes do conserto a
/// escolha virava "Câmera do MacBook Air" (a revisão de código de 18/09, achado 1 do catálogo).
final class TestesDoSeletorDeFontes: XCTestCase {

    private let painel = FonteDeCaptura(id: "tela:1", tipo: .tela(1), nome: "Tela interna", detalhe: "2560 × 1664")
    private let tv = FonteDeCaptura(id: "tela:4", tipo: .tela(4), nome: "LG TV", detalhe: "1920 × 1080")
    private let estendida = FonteDeCaptura(id: "tela-estendida", tipo: .tela(99), nome: "Tela estendida", detalhe: "")
    private let camera = FonteDeCaptura(
        id: "camera:6C707041-05AC-0010-000C-000000000001",
        tipo: .camera("6C707041-05AC-0010-000C-000000000001"),
        nome: "Câmera do MacBook Air", detalhe: "1920 × 1080")

    /// A abertura: as duas metades, e o padrão é a primeira tela.
    private func aberto(telas: [FonteDeCaptura], cameras: [FonteDeCaptura]) -> SeletorDeFontes {
        var s = SeletorDeFontes()
        s.pedirAsDuas()
        _ = s.receber(telas, saoTelas: true)
        _ = s.receber(cameras, saoTelas: false)
        return s
    }

    func testeOAtualizarDe10DeSetembroNaoTrocaATelaPelaCamera() {
        var s = aberto(telas: [painel, estendida], cameras: [camera])
        s.escolher(estendida)
        s.pedirAsDuas()
        // As câmeras chegam primeiro: nada muda, porque a lista ainda não está inteira.
        XCTAssertEqual(s.receber([camera], saoTelas: false), .nenhuma)
        XCTAssertEqual(s.escolhida?.id, "tela-estendida")
        // As telas chegam: a escolha continua a tela estendida.
        XCTAssertEqual(s.receber([painel, estendida], saoTelas: true), .nenhuma)
        XCTAssertEqual(s.escolhida?.id, "tela-estendida")
        XCTAssertNil(s.sumida)
    }

    func testeOCasoInversoACameraEscolhidaNaoViraTela() {
        var s = aberto(telas: [painel], cameras: [camera])
        s.escolher(camera)
        s.pedirAsDuas()
        XCTAssertEqual(s.receber([painel], saoTelas: true), .nenhuma)
        XCTAssertEqual(s.receber([camera], saoTelas: false), .nenhuma)
        XCTAssertEqual(s.escolhida?.id, camera.id)
    }

    func testeATvQueSaiEVoltaVoltaEscolhida() {
        var s = aberto(telas: [painel, tv], cameras: [camera])
        s.escolher(tv)
        // A TV sai (só a metade das telas é pedida).
        s.pedirMaisUma()
        XCTAssertEqual(s.receber([painel], saoTelas: true), .sumiu(tv))
        XCTAssertNil(s.escolhida, "nunca a tela interna no lugar da TV")
        // Outra mudança sem a TV: continua sem escolha.
        s.pedirMaisUma()
        XCTAssertEqual(s.receber([painel], saoTelas: true), .nenhuma)
        XCTAssertNil(s.escolhida)
        // A TV volta, pelo mesmo id.
        s.pedirMaisUma()
        XCTAssertEqual(s.receber([painel, tv], saoTelas: true), .voltou(tv))
        XCTAssertEqual(s.escolhida?.id, tv.id)
        XCTAssertNil(s.sumida)
    }

    func testeUmaTelaSoQueSomeEVolta() {
        var s = aberto(telas: [painel], cameras: [])
        XCTAssertEqual(s.escolhida?.id, painel.id)
        s.pedirMaisUma()
        XCTAssertEqual(s.receber([], saoTelas: true), .sumiu(painel))
        s.pedirMaisUma()
        XCTAssertEqual(s.receber([painel], saoTelas: true), .voltou(painel))
    }

    func testeAPessoaEscolheOutraEASumidaNaoVoltaPorCimaDela() {
        var s = aberto(telas: [painel, tv], cameras: [])
        s.escolher(tv)
        s.pedirMaisUma()
        _ = s.receber([painel], saoTelas: true)
        s.escolher(painel)
        s.pedirMaisUma()
        XCTAssertEqual(s.receber([painel, tv], saoTelas: true), .nenhuma)
        XCTAssertEqual(s.escolhida?.id, painel.id)
    }

    func testeOPadraoDaAberturaEATelaNuncaACamera() {
        // As câmeras chegam antes (o caso raro): nada é escolhido ainda, e a câmera nunca.
        var s = SeletorDeFontes()
        s.pedirAsDuas()
        XCTAssertEqual(s.receber([camera], saoTelas: false), .nenhuma)
        XCTAssertNil(s.escolhida)
        XCTAssertEqual(s.receber([painel], saoTelas: true), .padrao(painel))
        // Sem tela nenhuma (Gravação de Tela negada): sem escolha, e não a câmera.
        let semTela = aberto(telas: [], cameras: [camera])
        XCTAssertNil(semTela.escolhida)
    }

    /// A reconferência de 18/09: o padrão esperava as câmeras, e na primeira abertura elas esperam a
    /// pessoa responder o diálogo de permissão. Agora a primeira tela é escolhida quando as telas
    /// chegam, com as câmeras ainda pendentes.
    func testeOPadraoNaoEsperaAsCameras() {
        var s = SeletorDeFontes()
        s.pedirAsDuas()
        XCTAssertEqual(s.receber([painel, tv], saoTelas: true), .padrao(painel))
        XCTAssertFalse(s.completo, "as câmeras ainda não voltaram")
        XCTAssertEqual(s.escolhida?.id, painel.id)
        XCTAssertEqual(s.receber([camera], saoTelas: false), .nenhuma)
        XCTAssertEqual(s.escolhida?.id, painel.id)
    }

    /// O Sidecar sai como `tela:64` e volta como `tela:66` (registro de 10/09): não é escolhido (pode
    /// ser outro aparelho com o mesmo nome), mas o aviso de que ele sumiu seria falso.
    func testeOMesmoNomeComOutroIdNaoEscolheMasAvisa() {
        let sidecar64 = FonteDeCaptura(id: "tela:64", tipo: .tela(64), nome: "Sidecar Display (AirPlay)", detalhe: "")
        let sidecar66 = FonteDeCaptura(id: "tela:66", tipo: .tela(66), nome: "Sidecar Display (AirPlay)", detalhe: "")
        var s = aberto(telas: [painel, sidecar64], cameras: [])
        s.escolher(sidecar64)
        s.pedirMaisUma()
        XCTAssertEqual(s.receber([painel], saoTelas: true), .sumiu(sidecar64))
        s.pedirMaisUma()
        XCTAssertEqual(s.receber([painel, sidecar66], saoTelas: true), .reapareceu(sidecar66))
        XCTAssertNil(s.escolhida)
    }

    /// No Windows o id de monitor é da saída de vídeo; aqui a regra é a mesma: mesmo id com outro nome
    /// não é a que sumiu.
    func testeOMesmoIdComOutroNomeNaoVolta() {
        let projetor = FonteDeCaptura(id: "tela:4", tipo: .tela(4), nome: "EPSON PJ", detalhe: "")
        var s = aberto(telas: [painel, tv], cameras: [])
        s.escolher(tv)
        s.pedirMaisUma()
        _ = s.receber([painel], saoTelas: true)
        s.pedirMaisUma()
        XCTAssertEqual(s.receber([painel, projetor], saoTelas: true), .nenhuma)
        XCTAssertNil(s.escolhida)
    }

    /// Um Atualizar por cima de uma metade de telas ainda em voo: a lista só fica inteira quando as
    /// câmeras voltarem (antes, `pendentes = 2` a dava por inteira cedo).
    func testeOAtualizarPorCimaDeUmaMetadeEmVoo() {
        var s = aberto(telas: [painel], cameras: [camera])
        s.escolher(camera)
        s.pedirMaisUma()
        s.pedirAsDuas()
        XCTAssertEqual(s.receber([painel], saoTelas: true), .nenhuma)
        XCTAssertEqual(s.receber([painel], saoTelas: true), .nenhuma)
        XCTAssertFalse(s.completo)
        // A câmera foi desplugada: a metade das câmeras chega sem ela.
        XCTAssertEqual(s.receber([], saoTelas: false), .sumiu(camera))
        XCTAssertTrue(s.completo)
    }

    /// O motivo do fim de uma sessão fica quando o aviso sai.
    func testeOMotivoDoFimFicaQuandoOAvisoSai() {
        let motivo = "A captura parou sozinha."
        let aviso = "\"LG TV\" não está mais disponível. Escolha outra fonte."
        let junto = SeletorDeFontes.comOAviso(motivo, aviso)
        XCTAssertEqual(junto, "\(motivo) \(aviso)")
        XCTAssertEqual(SeletorDeFontes.semOAviso(junto, aviso), motivo)
        XCTAssertEqual(SeletorDeFontes.semOAviso(SeletorDeFontes.comOAviso("", aviso), aviso), "")
        // O motivo chegou depois e escreveu por cima do aviso: nada a tirar.
        XCTAssertEqual(SeletorDeFontes.semOAviso(motivo, aviso), motivo)
    }

    func testeASumidaSemVoltaNuncaViraOutra() {
        var s = aberto(telas: [painel, tv], cameras: [camera])
        s.escolher(tv)
        s.pedirAsDuas()
        _ = s.receber([camera], saoTelas: false)
        XCTAssertEqual(s.receber([painel], saoTelas: true), .sumiu(tv))
        // Um Atualizar inteiro depois, ainda sem a TV: nada é escolhido por conta própria.
        s.pedirAsDuas()
        _ = s.receber([painel], saoTelas: true)
        XCTAssertEqual(s.receber([camera], saoTelas: false), .nenhuma)
        XCTAssertNil(s.escolhida)
    }
}
