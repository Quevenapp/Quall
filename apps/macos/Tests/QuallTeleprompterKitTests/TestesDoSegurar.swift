import XCTest
@testable import QuallTeleprompterKit

/// **O "Segurar para rolar" do controle** (`docs/contrato-teleprompter.md` §12.5): a regra dos
/// apertos, sem janela e sem núcleo.
final class TestesDoSegurar: XCTestCase {

    /// O mapeamento da §12.5, num lugar só: "Rolar para cima" é `hold(t, true)` e volta o texto; ↑ e
    /// ↓ seguem os botões.
    func test_o_mapeamento_e_o_do_contrato() {
        XCTAssertTrue(BotaoDeSegurar.cima.paraTras(invertido: false))
        XCTAssertFalse(BotaoDeSegurar.baixo.paraTras(invertido: false))
        XCTAssertEqual(BotaoDeSegurar.cima.rotulo, "Rolar para cima")
        XCTAssertEqual(BotaoDeSegurar.baixo.rotulo, "Rolar para baixo")
        XCTAssertEqual(BotaoDeSegurar.cima.legenda(invertido: false), "volta o texto")
        XCTAssertEqual(BotaoDeSegurar.baixo.legenda(invertido: false), "avança o texto")
        XCTAssertEqual(BotaoDeSegurar.daTecla(126), .cima, "↑")
        XCTAssertEqual(BotaoDeSegurar.daTecla(125), .baixo, "↓")
        XCTAssertNil(BotaoDeSegurar.daTecla(123), "← não segura")
        XCTAssertNil(BotaoDeSegurar.daTecla(124), "→ não segura")
        for b in BotaoDeSegurar.allCases { XCTAssertEqual(BotaoDeSegurar.daTecla(b.codigoDaTecla), b) }
    }

    /// **"Inverter botões"** (pedido de 14/09 à tarde): o de cima avança (`para_tras=false`) e o de
    /// baixo volta (`true`); as setas e os rótulos ficam no lugar, e as legendas trocam com a ação.
    func test_inverter_troca_o_sentido_e_a_legenda_e_nao_o_rotulo() throws {
        XCTAssertFalse(BotaoDeSegurar.cima.paraTras(invertido: true))
        XCTAssertTrue(BotaoDeSegurar.baixo.paraTras(invertido: true))
        XCTAssertEqual(BotaoDeSegurar.cima.legenda(invertido: true), "avança o texto")
        XCTAssertEqual(BotaoDeSegurar.baixo.legenda(invertido: true), "volta o texto")
        XCTAssertEqual(BotaoDeSegurar.cima.rotulo, "Rolar para cima", "o rótulo fica")
        XCTAssertEqual(BotaoDeSegurar.cima.simbolo, "arrow.up", "a seta fica")
        XCTAssertEqual(BotaoDeSegurar.baixo.rotulo, "Rolar para baixo")
        XCTAssertEqual(BotaoDeSegurar.baixo.simbolo, "arrow.down")

        var s = SegurarParaRolar(invertido: true)
        XCTAssertEqual(s.legenda(.cima), "avança o texto")
        XCTAssertEqual(s.legenda(.baixo), "volta o texto")
        XCTAssertEqual(s.apertar(.cima, por: .mouse), .segurar(paraTras: false), "o de cima avança")
        XCTAssertEqual(s.soltar(.cima, por: .mouse), .soltar)
        XCTAssertEqual(s.apertar(.baixo, por: .mouse), .segurar(paraTras: true), "o de baixo volta")
        XCTAssertEqual(s.soltar(.baixo, por: .mouse), .soltar)
        // As setas são os botões de cima e de baixo: seguem a inversão sem regra própria.
        let seta = try XCTUnwrap(BotaoDeSegurar.daTecla(126))
        XCTAssertEqual(s.apertar(seta, por: .tecla), .segurar(paraTras: false), "↑ faz o que o de cima faz: avança")
        s.segurou(aceito: true)
        XCTAssertEqual(s.apertar(.baixo, por: .tecla), .segurar(paraTras: true), "↓ volta, e vale o último")
        s.segurou(aceito: true)
        XCTAssertEqual(s.soltar(.baixo, por: .tecla), .segurar(paraTras: false), "sobrou ↑: avança de novo")
        XCTAssertEqual(s.soltar(.cima, por: .tecla), .soltar)
        // Sair do modo solta tudo e **não** desliga a inversão: é ajuste do aparelho.
        _ = s.sairDoModo()
        XCTAssertTrue(s.invertido)
    }

    /// **Com um dedo num botão de rolar, a troca não vale** — fica desligada até soltar, e nada sai.
    func test_inverter_com_um_botao_apertado_nao_vale() {
        var s = SegurarParaRolar()
        XCTAssertTrue(s.podeInverter)
        XCTAssertEqual(s.apertar(.baixo, por: .mouse), .segurar(paraTras: false))
        s.segurou(aceito: true)
        XCTAssertFalse(s.podeInverter)
        XCTAssertFalse(s.definirInversao(true), "com o mouse no botão")
        XCTAssertFalse(s.invertido)
        XCTAssertEqual(s.apertar(.cima, por: .tecla), .segurar(paraTras: true), "o sentido de sempre")
        s.segurou(aceito: true)
        XCTAssertFalse(s.definirInversao(true), "com o mouse e a seta")
        XCTAssertEqual(s.soltar(.cima, por: .tecla), .segurar(paraTras: false))
        s.segurou(aceito: true)
        XCTAssertFalse(s.definirInversao(true), "ainda com o mouse")
        XCTAssertEqual(s.soltar(.baixo, por: .mouse), .soltar)
        XCTAssertTrue(s.podeInverter)
        XCTAssertTrue(s.definirInversao(true), "soltou tudo: troca")
        XCTAssertTrue(s.invertido)
        XCTAssertEqual(s.apertar(.baixo, por: .mouse), .segurar(paraTras: true), "trocado, o de baixo volta")
        XCTAssertFalse(s.definirInversao(false), "apertado de novo: não troca")
        XCTAssertTrue(s.invertido)
        // O texto que parou sozinho com o dedo no botão também segura a troca até soltar.
        s.segurou(aceito: true)
        XCTAssertTrue(s.observar(segurando: false))
        XCTAssertFalse(s.definirInversao(false))
        _ = s.soltarTudo()
        XCTAssertTrue(s.definirInversao(false))
    }

    /// Com a inversão, quem avança é o de cima: o aviso do fim do texto segue o sentido, não o botão.
    func test_o_fim_do_texto_segue_o_sentido_com_a_inversao() {
        var s = SegurarParaRolar(invertido: true)
        _ = s.apertar(.cima, por: .mouse)
        s.segurou(aceito: true)
        XCTAssertTrue(s.observar(segurando: false))
        XCTAssertEqual(s.paraTrasQuandoParou, false)
        XCTAssertEqual(s.avisoDoTextoParado(posicao: 1), "O texto chegou ao fim.")
        var b = SegurarParaRolar(invertido: true)
        _ = b.apertar(.baixo, por: .mouse)
        b.segurou(aceito: true)
        _ = b.observar(segurando: false)
        XCTAssertEqual(b.avisoDoTextoParado(posicao: 1), "O texto parou. Solte e aperte de novo.")
    }

    /// Apertou: `hold` na hora. Soltou: `release`.
    func test_apertar_segura_e_soltar_solta() {
        var s = SegurarParaRolar()
        XCTAssertEqual(s.apertar(.baixo, por: .mouse), .segurar(paraTras: false))
        s.segurou(aceito: true)
        XCTAssertTrue(s.seguro)
        XCTAssertEqual(s.botaoAtivo, .baixo)
        XCTAssertEqual(s.soltar(.baixo, por: .mouse), .soltar)
        XCTAssertFalse(s.seguro)
        XCTAssertNil(s.botaoAtivo)
        XCTAssertEqual(s.apertar(.cima, por: .tecla), .segurar(paraTras: true))
        XCTAssertEqual(s.soltar(.cima, por: .tecla), .soltar)
        XCTAssertNil(s.soltar(.cima, por: .tecla), "soltar o que não está apertado não manda nada")
    }

    /// A repetição automática da tecla (e um `mouseDown` a mais) não manda nada.
    func test_a_repeticao_nao_faz_nada() {
        var s = SegurarParaRolar()
        XCTAssertNotNil(s.apertar(.cima, por: .tecla))
        s.segurou(aceito: true)
        for _ in 0..<30 { XCTAssertNil(s.apertar(.cima, por: .tecla)) }
        XCTAssertEqual(s.apertos.count, 1)
        XCTAssertEqual(s.soltar(.cima, por: .tecla), .soltar)
    }

    /// **Dois "dedos"** (o mouse e uma seta, ou as duas setas): vale o último apertado, e o
    /// `release` só sai quando nenhum sobrar. Soltar o que valia volta ao que sobrou (derivado).
    func test_dois_apertos_vale_o_ultimo_e_solta_quando_nenhum_sobra() {
        var s = SegurarParaRolar()
        XCTAssertEqual(s.apertar(.baixo, por: .mouse), .segurar(paraTras: false))
        s.segurou(aceito: true)
        XCTAssertEqual(s.apertar(.cima, por: .tecla), .segurar(paraTras: true), "o último vale")
        s.segurou(aceito: true)
        XCTAssertEqual(s.botaoAtivo, .cima)
        XCTAssertEqual(s.soltar(.cima, por: .tecla), .segurar(paraTras: false), "sobrou o mouse no Rolar para baixo")
        s.segurou(aceito: true)
        XCTAssertEqual(s.soltar(.baixo, por: .mouse), .soltar)

        // Soltar o que **não** valia não muda nada.
        var t = SegurarParaRolar()
        _ = t.apertar(.baixo, por: .mouse)
        t.segurou(aceito: true)
        _ = t.apertar(.cima, por: .tecla)
        t.segurou(aceito: true)
        XCTAssertNil(t.soltar(.baixo, por: .mouse))
        XCTAssertEqual(t.botaoAtivo, .cima)
        XCTAssertEqual(t.soltar(.cima, por: .tecla), .soltar)

        // As duas setas.
        var u = SegurarParaRolar()
        _ = u.apertar(.cima, por: .tecla)
        u.segurou(aceito: true)
        XCTAssertEqual(u.apertar(.baixo, por: .tecla), .segurar(paraTras: false))
        u.segurou(aceito: true)
        XCTAssertEqual(u.soltar(.baixo, por: .tecla), .segurar(paraTras: true))
        u.segurou(aceito: true)
        XCTAssertEqual(u.soltar(.cima, por: .tecla), .soltar)
    }

    /// O mesmo botão pelas duas fontes: soltar uma não muda o sentido, e não manda nada.
    func test_o_mesmo_botao_por_duas_fontes() {
        var s = SegurarParaRolar()
        _ = s.apertar(.baixo, por: .mouse)
        s.segurou(aceito: true)
        XCTAssertEqual(s.apertar(.baixo, por: .tecla), .segurar(paraTras: false))
        s.segurou(aceito: true)
        XCTAssertNil(s.soltar(.baixo, por: .tecla), "o mouse ainda segura o mesmo botão")
        XCTAssertEqual(s.soltar(.baixo, por: .mouse), .soltar)
    }

    /// O ponteiro é um só: um `mouseDown` num botão substitui um aperto de mouse que ficou preso.
    func test_o_mouse_e_um_so() {
        var s = SegurarParaRolar()
        _ = s.apertar(.baixo, por: .mouse)
        s.segurou(aceito: true)
        XCTAssertEqual(s.apertar(.cima, por: .mouse), .segurar(paraTras: true))
        XCTAssertEqual(s.apertos.count, 1)
        XCTAssertNil(s.soltar(.baixo, por: .mouse), "o aperto antigo já tinha acabado")
        XCTAssertEqual(s.soltar(.cima, por: .mouse), .soltar)
    }

    /// **O texto parou sozinho** com o dedo no botão (a queda, o silêncio, a pausa no prompter): a
    /// tela avisa, e nada aperta de novo sozinho — nem a repetição, nem soltar um de dois apertos.
    func test_o_texto_parou_e_nada_aperta_de_novo_sozinho() {
        var s = SegurarParaRolar()
        _ = s.apertar(.baixo, por: .mouse)
        s.segurou(aceito: true)
        XCTAssertFalse(s.observar(segurando: true))
        XCTAssertFalse(s.textoParou)
        _ = s.apertar(.cima, por: .tecla)
        s.segurou(aceito: true)
        XCTAssertTrue(s.observar(segurando: false), "segurando caiu com dois apertos de pé")
        XCTAssertTrue(s.textoParou)
        XCTAssertFalse(s.observar(segurando: false), "avisa uma vez")
        XCTAssertNil(s.apertar(.cima, por: .tecla), "a repetição da tecla não aperta de novo")
        XCTAssertNil(s.soltar(.cima, por: .tecla), "soltar um de dois não segura o que sobrou")
        XCTAssertTrue(s.textoParou)
        XCTAssertEqual(s.soltar(.baixo, por: .mouse), .soltar, "soltar o último solta (e não faz mal)")
        XCTAssertTrue(s.textoParou, "o aviso fica até o próximo aperto")
        XCTAssertEqual(s.apertar(.baixo, por: .mouse), .segurar(paraTras: false), "o aperto novo é da pessoa")
        XCTAssertFalse(s.textoParou)
    }

    /// O aviso é o literal do pedido — menos com "Rolar para baixo" no fim do texto, onde o prompter
    /// para pela regra de sempre e "aperte de novo" não adianta (derivado, revisão de 14/09).
    func test_o_aviso_do_texto_parado_e_o_fim_do_texto() {
        var s = SegurarParaRolar()
        XCTAssertNil(s.avisoDoTextoParado(posicao: 1))
        _ = s.apertar(.baixo, por: .mouse)
        s.segurou(aceito: true)
        XCTAssertTrue(s.observar(segurando: false))
        XCTAssertEqual(s.paraTrasQuandoParou, false)
        XCTAssertEqual(s.avisoDoTextoParado(posicao: 0.4), "O texto parou. Solte e aperte de novo.")
        XCTAssertEqual(s.avisoDoTextoParado(posicao: 1.0), "O texto chegou ao fim.")
        // "Rolar para cima" nunca é fim: para trás o prompter fica no começo sem parar `rolando`.
        var c = SegurarParaRolar()
        _ = c.apertar(.cima, por: .tecla)
        c.segurou(aceito: true)
        _ = c.observar(segurando: false)
        XCTAssertEqual(c.avisoDoTextoParado(posicao: 1.0), "O texto parou. Solte e aperte de novo.")
        _ = c.apertar(.cima, por: .mouse)
        XCTAssertNil(c.paraTrasQuandoParou, "o aperto novo apaga o aviso")
    }

    /// **O aviso some quando o texto volta a rolar sem aperto daqui** (o play no prompter): "o texto
    /// parou" deixou de ser verdade (revisão de 14/09). O `rolando` do próprio `hold` não apaga nada.
    func test_o_aviso_some_quando_o_texto_volta_a_rolar_por_outro_caminho() {
        var s = SegurarParaRolar()
        _ = s.apertar(.baixo, por: .mouse)
        s.segurou(aceito: true)
        XCTAssertFalse(s.observar(segurando: true, rolando: true))
        XCTAssertTrue(s.observar(segurando: false, rolando: false), "a pausa no prompter")
        XCTAssertTrue(s.textoParou)
        XCTAssertFalse(s.observar(segurando: false, rolando: false))
        XCTAssertTrue(s.textoParou, "parado continua parado")
        XCTAssertFalse(s.observar(segurando: false, rolando: true), "o play no prompter")
        XCTAssertFalse(s.textoParou)
        XCTAssertNil(s.paraTrasQuandoParou)
        XCTAssertEqual(s.soltar(.baixo, por: .mouse), .soltar, "soltar depois ainda solta (e não faz mal)")
    }

    /// Sem `hold` aceito não há o que parar: a recusa (`PROTOCOL`, `CLOSED`) e o `segurando` que
    /// cai depois de soltar não acendem o aviso.
    func test_sem_hold_aceito_nao_ha_texto_parado() {
        var s = SegurarParaRolar()
        _ = s.apertar(.baixo, por: .mouse)
        s.segurou(aceito: false)
        XCTAssertFalse(s.observar(segurando: false))
        XCTAssertFalse(s.textoParou)
        XCTAssertNil(s.soltar(.baixo, por: .tecla))
        XCTAssertEqual(s.soltar(.baixo, por: .mouse), .soltar)

        var t = SegurarParaRolar()
        _ = t.apertar(.cima, por: .mouse)
        t.segurou(aceito: true)
        _ = t.soltar(.cima, por: .mouse)
        XCTAssertFalse(t.observar(segurando: false), "soltou antes: o segurando que cai é o soltar")
        XCTAssertFalse(t.textoParou)
        // Um aceito sem aperto nenhum (o dedo saiu entre o aperto e a resposta) não fica seguro.
        t.segurou(aceito: true)
        XCTAssertFalse(t.seguro)
    }

    /// Soltar tudo (o foco, a tela fechando, desconectar) e sair do modo.
    func test_soltar_tudo_e_sair_do_modo() {
        var s = SegurarParaRolar()
        XCTAssertNil(s.soltarTudo(), "sem aperto nenhum, nada sai")
        _ = s.apertar(.baixo, por: .mouse)
        _ = s.apertar(.cima, por: .tecla)
        s.segurou(aceito: true)
        XCTAssertEqual(s.soltarTudo(), .soltar)
        XCTAssertTrue(s.apertos.isEmpty)
        XCTAssertFalse(s.seguro)

        _ = s.apertar(.baixo, por: .mouse)
        s.segurou(aceito: true)
        _ = s.observar(segurando: false)
        XCTAssertTrue(s.textoParou)
        XCTAssertEqual(s.sairDoModo(), .soltar)
        XCTAssertFalse(s.textoParou, "sair do modo apaga o aviso")
        XCTAssertNil(s.sairDoModo())
    }

    /// Os botões só funcionam com o prompter dizendo que entende, e com a sessão de pé.
    func test_a_disponibilidade() {
        var e = EstadoDoTeleprompter()
        typealias D = DisponibilidadeDoSegurar
        XCTAssertEqual(D.calcular(conectado: false, parSumido: false, estado: e, recusouPorProtocolo: false), .semSessao)
        XCTAssertEqual(D.calcular(conectado: true, parSumido: false, estado: e, recusouPorProtocolo: false),
                       .esperandoOPrompter, "o prompter ainda não disse nada: não pisca o aviso de atualizar")
        XCTAssertEqual(D.calcular(conectado: true, parSumido: false, estado: e, recusouPorProtocolo: true), .prompterAntigo)
        e.parVistoHaMs = 40
        XCTAssertEqual(D.calcular(conectado: true, parSumido: false, estado: e, recusouPorProtocolo: false),
                       .prompterAntigo, "o prompter falou e não disse que entende")
        e.parEntendeSegurar = true
        XCTAssertEqual(D.calcular(conectado: true, parSumido: false, estado: e, recusouPorProtocolo: false), .pronto)
        XCTAssertEqual(D.calcular(conectado: true, parSumido: true, estado: e, recusouPorProtocolo: false), .prompterSumido)
        XCTAssertEqual(D.calcular(conectado: false, parSumido: false, estado: e, recusouPorProtocolo: false), .semSessao)
        XCTAssertTrue(D.pronto.botoesLigados)
        for d in [D.semSessao, .esperandoOPrompter, .prompterSumido, .prompterAntigo] { XCTAssertFalse(d.botoesLigados) }
    }
}
