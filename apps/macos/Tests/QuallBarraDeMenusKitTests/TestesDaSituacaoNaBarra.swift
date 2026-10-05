import XCTest
@testable import QuallBarraDeMenusKit

/// **As frases do menu do ícone e a cor da bolinha**, a partir de valores simples — os mesmos que o app
/// monta lendo o `Emissor`, o `Receptor` e o `Teleprompter`.
final class TestesDaSituacaoNaBarra: XCTestCase {

    func test_sem_nada_de_pe_diz_pronto() {
        let s = SituacaoNaBarra()
        XCTAssertEqual(s.linhas, ["Pronto"])
        XCTAssertFalse(s.noAr)
    }

    #if QUALL_TELA_ESTENDIDA_FUTURA
    /// A tela estendida do pedido de 01/10: o Mac → tablet e A07.
    func test_tela_estendida_com_dois_aparelhos() {
        let s = SituacaoNaBarra(emissao: .noAr(.telaEstendida, aparelhos: ["Galaxy Tab S9", "Galaxy A07"]))
        XCTAssertEqual(s.linhas, ["Tela estendida: 2 aparelhos"])
        XCTAssertTrue(s.noAr)
    }

    func test_tela_estendida_com_um_aparelho_diz_o_nome() {
        let s = SituacaoNaBarra(emissao: .noAr(.telaEstendida, aparelhos: ["iPad"]))
        XCTAssertEqual(s.linhas, ["Tela estendida: iPad"])
    }

    #endif
    func test_espelhando_e_camera_no_ar() {
        XCTAssertEqual(SituacaoNaBarra(emissao: .noAr(.tela, aparelhos: ["iPad"])).linhas, ["Espelhando para iPad"])
        XCTAssertEqual(SituacaoNaBarra(emissao: .noAr(.camera, aparelhos: ["Dell"])).linhas, ["Câmera indo para Dell"])
        XCTAssertTrue(SituacaoNaBarra(emissao: .noAr(.camera, aparelhos: ["Dell"])).noAr)
    }

    /// Sem nome do núcleo, "outro aparelho" — o mesmo da janela; espaço em branco também não é nome.
    func test_par_sem_nome_vira_outro_aparelho() {
        XCTAssertEqual(SituacaoNaBarra(emissao: .noAr(.tela, aparelhos: [""])).linhas, ["Espelhando para outro aparelho"])
        XCTAssertEqual(SituacaoNaBarra(emissao: .noAr(.tela, aparelhos: [])).linhas, ["Espelhando para outro aparelho"])
        XCTAssertEqual(SituacaoNaBarra(exibicao: .exibindo("  ")).linhas, ["Exibindo outro aparelho"])
    }

    /// Esperando alguém conectar não é vermelho: nada saiu deste Mac ainda.
    func test_esperando_nao_e_no_ar() {
        for origem in [SituacaoNaBarra.Origem.tela, .camera] {
            let s = SituacaoNaBarra(emissao: .esperando(origem))
            XCTAssertFalse(s.noAr, "\(origem)")
            XCTAssertEqual(s.linhas.count, 1)
        }
        #if QUALL_TELA_ESTENDIDA_FUTURA
        XCTAssertEqual(SituacaoNaBarra(emissao: .esperando(.telaEstendida)).linhas, ["Tela estendida: esperando um aparelho"])
        #endif
        XCTAssertEqual(SituacaoNaBarra(emissao: .esperando(.tela)).linhas, ["Espelhar: esperando um aparelho"])
        XCTAssertFalse(SituacaoNaBarra(emissao: .encerrando).noAr)
    }

    /// Exibir, mostrar o texto e controlar não mandam nada deste Mac: a bolinha não fica vermelha.
    func test_receber_e_o_teleprompter_nao_sao_no_ar() {
        XCTAssertFalse(SituacaoNaBarra(exibicao: .exibindo("iPhone X")).noAr)
        XCTAssertEqual(SituacaoNaBarra(exibicao: .exibindo("iPhone X")).linhas, ["Exibindo iPhone X"])
        XCTAssertFalse(SituacaoNaBarra(prompter: .controladoPor("iPhone")).noAr)
        XCTAssertFalse(SituacaoNaBarra(controle: .controlando("iPad")).noAr)
    }

    /// O "Texto com a câmera": duas sessões, duas linhas; a câmera indo é vermelho.
    func test_texto_com_a_camera_tem_duas_linhas() {
        let s = SituacaoNaBarra(prompter: .controladoPor("iPhone"), cameraDoTexto: .noAr("Dell"))
        XCTAssertEqual(s.linhas, ["Teleprompter: controlado por iPhone", "Texto com a câmera: indo para Dell"])
        XCTAssertTrue(s.noAr)
        XCTAssertFalse(SituacaoNaBarra(prompter: .esperandoOControle, cameraDoTexto: .esperando).noAr)
    }

    /// O M4: a janela principal exibe o vídeo de um aparelho e a do controle mexe no texto de outro.
    func test_m4_exibindo_e_controlando_ao_mesmo_tempo() {
        let s = SituacaoNaBarra(exibicao: .exibindo("iPhone X"), controle: .controlando("iPad"))
        XCTAssertEqual(s.linhas, ["Exibindo iPhone X", "Controlando o texto de iPad"])
    }

    /// "Sessão de pé" é tudo o que não diz "Pronto" — inclusive esperar um aparelho, exibir e o prompter
    /// com a espera parada; o formulário (que vira `.parada`/`.fechado`) não conta.
    func test_sessao_de_pe_e_tudo_o_que_nao_e_pronto() {
        let casos: [SituacaoNaBarra] = [
            SituacaoNaBarra(), SituacaoNaBarra(emissao: .esperando(.tela)),
            SituacaoNaBarra(emissao: .noAr(.tela, aparelhos: ["iPad"])), SituacaoNaBarra(emissao: .encerrando),
            SituacaoNaBarra(exibicao: .exibindo("iPhone")), SituacaoNaBarra(exibicao: .conectando),
            SituacaoNaBarra(prompter: .parado), SituacaoNaBarra(cameraDoTexto: .esperando),
            SituacaoNaBarra(controle: .semConexao),
        ]
        for s in casos {
            XCTAssertEqual(s.sessaoDePe, s.linhas != [SituacaoNaBarra.pronto], "\(s.linhas)")
        }
        XCTAssertFalse(SituacaoNaBarra().sessaoDePe)
        XCTAssertTrue(SituacaoNaBarra(emissao: .esperando(.tela)).sessaoDePe, "esperar um aparelho já segura")
    }

    func test_as_fases_intermediarias() {
        XCTAssertEqual(SituacaoNaBarra(exibicao: .conectando).linhas, ["Exibir: conectando…"])
        XCTAssertEqual(SituacaoNaBarra(exibicao: .esperandoImagem(de: "A07")).linhas, ["Exibir: esperando a imagem de A07"])
        XCTAssertEqual(SituacaoNaBarra(exibicao: .encerrando).linhas, ["Parando de exibir…"])
        XCTAssertEqual(SituacaoNaBarra(prompter: .semOControle).linhas, ["Teleprompter: sem o controle"])
        XCTAssertEqual(SituacaoNaBarra(prompter: .parado).linhas, ["Teleprompter: a espera parou"])
        XCTAssertEqual(SituacaoNaBarra(controle: .semConexao).linhas, ["Controlar: sem conexão"])
        XCTAssertEqual(SituacaoNaBarra(emissao: .encerrando).linhas, ["Encerrando a transmissão…"])
    }
}

/// **As duas regras**: o que o minimizar faz com cada janela, e quando o Dock some.
final class TestesDaRegraDaBarra: XCTestCase {

    func test_a_principal_vai_para_a_barra() {
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: true, emTelaCheia: false, comFolha: false), .esconderNaBarra)
    }

    func test_a_principal_em_tela_cheia_nao_minimiza() {
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: true, emTelaCheia: true, comFolha: false), .nada)
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: true, emTelaCheia: true, comFolha: true), .nada)
    }

    /// Com o editor do roteiro (uma folha) aberto, ou sem o ícone à vista: o minimizar de sempre.
    func test_com_folha_ou_sem_icone_vai_para_o_dock() {
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: true, emTelaCheia: false, comFolha: true), .minimizarNoDock)
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: true, emTelaCheia: false, comFolha: false, iconeAVista: false),
                       .minimizarNoDock)
    }

    /// O ⌘M no "Controle do teleprompter" ou nos Ajustes minimiza aquela janela, para o Dock.
    func test_as_outras_janelas_minimizam_para_o_dock() {
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: false, emTelaCheia: false, comFolha: false), .minimizarNoDock)
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: false, emTelaCheia: false, comFolha: false, minimizavel: false),
                       .nada)
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: false, emTelaCheia: true, comFolha: false), .nada)
    }

    /// A janela mostrando o texto do prompter minimiza para o Dock; em tela cheia, nada, como sempre.
    func test_o_prompter_vai_para_o_dock() {
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: true, emTelaCheia: false, comFolha: false, mostraOTexto: true),
                       .minimizarNoDock)
        XCTAssertEqual(RegraDaBarra.minimizar(ehAPrincipal: true, emTelaCheia: true, comFolha: false, mostraOTexto: true),
                       .nada)
    }

    /// O entalhe, com os números medidos neste MacBook em 01/10: painel de 1470 pt, área da direita de
    /// 825 a 1470 (32 de altura), o ícone em x 895–933 com 33 de altura.
    func test_o_icone_medido_esta_a_vista() {
        let direita = CGRect(x: 825, y: 924, width: 645, height: 32)
        XCTAssertFalse(RegraDaBarra.atrasDoEntalhe(icone: CGRect(x: 895, y: 923, width: 38, height: 33), ladoDireito: direita),
                       "um ponto a mais de altura não pode virar 'fora de vista'")
        // Sob o entalhe (de 646 a 825) e à esquerda dele: fora de vista.
        XCTAssertTrue(RegraDaBarra.atrasDoEntalhe(icone: CGRect(x: 716, y: 923, width: 38, height: 33), ladoDireito: direita))
        XCTAssertTrue(RegraDaBarra.atrasDoEntalhe(icone: CGRect(x: 300, y: 923, width: 38, height: 33), ladoDireito: direita))
        // Sem entalhe (os monitores virtuais, um Mac sem entalhe), ou sem quadro: não há o que dizer.
        XCTAssertFalse(RegraDaBarra.atrasDoEntalhe(icone: CGRect(x: 716, y: 923, width: 38, height: 33), ladoDireito: nil))
        XCTAssertFalse(RegraDaBarra.atrasDoEntalhe(icone: .zero, ladoDireito: direita))
    }

    /// A janela que estava no monitor virtual que sumiu volta no meio da área útil da principal.
    func test_a_janela_fora_de_qualquer_tela_volta_no_meio() throws {
        let painel = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let util = CGRect(x: 0, y: 65, width: 1470, height: 858)
        let tablet = CGRect(x: 337, y: 956, width: 960, height: 600)
        // Estava no tablet, e o tablet saiu da lista.
        let noTablet = CGRect(x: 380, y: 970, width: 880, height: 580)
        let volta = try XCTUnwrap(RegraDaBarra.quadroDeVolta(noTablet, telas: [painel], areaUtil: util))
        XCTAssertEqual(volta.size, noTablet.size)
        XCTAssertEqual(volta.midX, util.midX, accuracy: 1)
        XCTAssertEqual(volta.midY, util.midY, accuracy: 1)
        XCTAssertTrue(util.contains(volta))
        // Com o tablet ainda lá, ela fica onde estava.
        XCTAssertNil(RegraDaBarra.quadroDeVolta(noTablet, telas: [painel, tablet], areaUtil: util))
        // Maior que a área útil: encolhe para caber.
        let grande = CGRect(x: 5000, y: 5000, width: 1900, height: 1100)
        let encolhida = try XCTUnwrap(RegraDaBarra.quadroDeVolta(grande, telas: [painel], areaUtil: util))
        XCTAssertEqual(encolhida, util)
    }

    /// O App Nap: segura ao sair de "Pronto", solta ao voltar, e não mexe no meio.
    func test_o_app_nap_segue_a_sessao_de_pe() {
        XCTAssertEqual(RegraDaBarra.atividade(segurando: false, sessaoDePe: true), .segurar)
        XCTAssertEqual(RegraDaBarra.atividade(segurando: true, sessaoDePe: false), .soltar)
        XCTAssertEqual(RegraDaBarra.atividade(segurando: true, sessaoDePe: true), .manter)
        XCTAssertEqual(RegraDaBarra.atividade(segurando: false, sessaoDePe: false), .manter)
    }

    func test_o_dock_so_some_sem_janela_nenhuma_a_mostra() {
        XCTAssertEqual(RegraDaBarra.dock(principalNaBarra: true, outrasJanelas: 0), .soNaBarra)
        XCTAssertEqual(RegraDaBarra.dock(principalNaBarra: true, outrasJanelas: 1), .comIcone, "o controle à mostra")
        XCTAssertEqual(RegraDaBarra.dock(principalNaBarra: false, outrasJanelas: 0), .comIcone, "fechada no X: o de hoje")
        XCTAssertEqual(RegraDaBarra.dock(principalNaBarra: true, outrasJanelas: 0, iconeAVista: false), .comIcone)
    }
}
