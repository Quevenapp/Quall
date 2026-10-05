// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import XCTest
@testable import QuallTeleprompterKit

/// O estado lido do JSON do núcleo — com o JSON **literal** da §6 do contrato.
final class TestesDoEstado: XCTestCase {

    /// O exemplo da §6, byte a byte como está no contrato.
    static let doContrato = """
        {"rolando":false,"velocidade":1.0,"fonte":48.0,"margem":0.1,"linha_de_leitura":0.3,
         "espelho":false,"posicao":0.0,"salto":null,"texto_bytes":0,"par_visto_ha_ms":null,
         "sem_confirmacao_ha_ms":null,"contadores":{"estados_enviados":0,"textos_enviados":0,
         "recebidas":0,"invalidas":0,"de_outro_app":0,"de_outra_versao":0,"campos_recusados":0,
         "carimbos_do_futuro":0,"mensagens_impossiveis":0,"reenvios_desistidos":0}}
        """

    func test_o_json_do_contrato_da_o_padrao_da_tabela() throws {
        let e = try XCTUnwrap(EstadoDoTeleprompter.doJSON(Self.doContrato))
        XCTAssertEqual(e, EstadoDoTeleprompter(), "o exemplo da §6 é o estado padrão da §3")
        XCTAssertNil(e.salto)
        XCTAssertNil(e.parVistoHaMs)
        XCTAssertNil(e.semConfirmacaoHaMs)
    }

    func test_campos_preenchidos_sao_lidos_pelos_nomes_do_contrato() throws {
        let json = """
            {"rolando":true,"velocidade":2.5,"fonte":64.0,"margem":0.2,"linha_de_leitura":0.45,
             "espelho":true,"posicao":0.25,"salto":0.5,"texto_bytes":100000,"par_visto_ha_ms":812,
             "sem_confirmacao_ha_ms":1600,"contadores":{"estados_enviados":7,"textos_enviados":1,
             "recebidas":9,"invalidas":0,"de_outro_app":2,"de_outra_versao":3,"campos_recusados":4,
             "carimbos_do_futuro":5,"mensagens_impossiveis":6,"reenvios_desistidos":1}}
            """
        let e = try XCTUnwrap(EstadoDoTeleprompter.doJSON(json))
        XCTAssertTrue(e.rolando)
        XCTAssertEqual(e.velocidade, 2.5)
        XCTAssertEqual(e.fonte, 64)
        XCTAssertEqual(e.margem, 0.2)
        XCTAssertEqual(e.linhaDeLeitura, 0.45)
        XCTAssertTrue(e.espelho)
        XCTAssertEqual(e.posicao, 0.25)
        XCTAssertEqual(e.salto, 0.5)
        XCTAssertEqual(e.textoBytes, 100_000)
        XCTAssertEqual(e.parVistoHaMs, 812)
        XCTAssertEqual(e.semConfirmacaoHaMs, 1600)
        XCTAssertEqual(e.contadores.estadosEnviados, 7)
        XCTAssertEqual(e.contadores.deOutroApp, 2)
        XCTAssertEqual(e.contadores.deOutraVersao, 3)
        XCTAssertEqual(e.contadores.camposRecusados, 4)
        XCTAssertEqual(e.contadores.carimbosDoFuturo, 5)
        XCTAssertEqual(e.contadores.mensagensImpossiveis, 6)
        XCTAssertEqual(e.contadores.reenviosDesistidos, 1)
    }

    /// O cabeçalho da fronteira mostra os contadores **sem** os dois últimos, e o contrato os
    /// mostra com; um campo que falta fica no padrão, e um desconhecido é ignorado. Um booleano no
    /// lugar de um número (e vice-versa) não vira 1,0 nem `true`.
    func test_leitura_tolerante_campo_a_campo() throws {
        let json = """
            {"rolando":1,"velocidade":true,"fonte":"grande","margem":null,"campo_novo":{"x":1},
             "texto_bytes":12,"contadores":{"estados_enviados":3}}
            """
        let e = try XCTUnwrap(EstadoDoTeleprompter.doJSON(json))
        XCTAssertFalse(e.rolando, "um número não é booleano")
        XCTAssertEqual(e.velocidade, 1.0, "um booleano não é número")
        XCTAssertEqual(e.fonte, 48.0)
        XCTAssertEqual(e.margem, 0.1)
        XCTAssertEqual(e.textoBytes, 12)
        XCTAssertEqual(e.contadores.estadosEnviados, 3)
        XCTAssertEqual(e.contadores.reenviosDesistidos, 0)
    }

    func test_texto_que_nao_e_objeto_nao_e_estado() {
        XCTAssertNil(EstadoDoTeleprompter.doJSON(""))
        XCTAssertNil(EstadoDoTeleprompter.doJSON("[1,2]"))
        XCTAssertNil(EstadoDoTeleprompter.doJSON("{"))
    }

    /// Os bits são ABI (§6). A ponte traduz pelas constantes do `quall.h`; esta tabela é a do
    /// contrato, e um valor trocado aqui mudaria o nome que o registro escreve.
    func test_os_bits_sao_os_do_contrato() {
        XCTAssertEqual(MudancasDoTeleprompter.texto.rawValue, 1)
        XCTAssertEqual(MudancasDoTeleprompter.rolando.rawValue, 2)
        XCTAssertEqual(MudancasDoTeleprompter.velocidade.rawValue, 4)
        XCTAssertEqual(MudancasDoTeleprompter.fonte.rawValue, 8)
        XCTAssertEqual(MudancasDoTeleprompter.margem.rawValue, 16)
        XCTAssertEqual(MudancasDoTeleprompter.linhaDeLeitura.rawValue, 32)
        XCTAssertEqual(MudancasDoTeleprompter.espelho.rawValue, 64)
        XCTAssertEqual(MudancasDoTeleprompter.posicao.rawValue, 128)
        XCTAssertEqual(MudancasDoTeleprompter.salto.rawValue, 256)
        XCTAssertEqual(MudancasDoTeleprompter.par.rawValue, 512)
        XCTAssertEqual(MudancasDoTeleprompter(rawValue: 1 | 256 | 512).nomes, ["texto", "salto", "par"])
        // §11.6: `_TEXT_QUESTION = 1024` e `_TEXT_COPY = 2048`; um bit que ninguém conhece ainda
        // aparece por número.
        XCTAssertEqual(MudancasDoTeleprompter.perguntaDoTexto.rawValue, 1024)
        XCTAssertEqual(MudancasDoTeleprompter.copiaDoTexto.rawValue, 2048)
        XCTAssertEqual(MudancasDoTeleprompter(rawValue: 1024 | 2048).nomes, ["pergunta", "copia"])
        XCTAssertEqual(MudancasDoTeleprompter(rawValue: 16384).nomes, ["desconhecido(16384)"])
        // §12.7: `QUALL_TELEPROMPTER_CHANGE_HOLD = 4096`.
        XCTAssertEqual(MudancasDoTeleprompter.segurar.rawValue, 4096)
        XCTAssertEqual(MudancasDoTeleprompter(rawValue: 2 | 4096).nomes, ["rolando", "segurar"])
        // §13: `QUALL_TELEPROMPTER_CHANGE_RECORDING = 8192`.
        XCTAssertEqual(MudancasDoTeleprompter.gravacao.rawValue, 8192)
        XCTAssertEqual(MudancasDoTeleprompter(rawValue: 512 | 8192).nomes, ["par", "gravacao"])
    }

    /// O exemplo do `quall.h` de 14/09, com os campos do segurar: o padrão é "ninguém segura".
    func test_os_campos_do_segurar_sao_lidos_pelos_nomes_do_contrato() throws {
        let doHeader = """
            {"rolando":false,"velocidade":1.0,"fonte":48.0,"margem":0.1,"linha_de_leitura":0.3,
             "espelho":false,"posicao":0.0,"salto":null,"texto_bytes":0,"par_visto_ha_ms":null,
             "sem_confirmacao_ha_ms":null,"contadores":{"estados_enviados":0,"textos_enviados":0,
             "recebidas":0,"invalidas":0,"de_outro_app":0,"de_outra_versao":0,"campos_recusados":0,
             "carimbos_do_futuro":0,"mensagens_impossiveis":0,"reenvios_desistidos":0},
             "pergunta_do_texto":null,"copias_do_texto":[],"para_tras":false,"segurando":false,
             "par_entende_segurar":false}
            """
        XCTAssertEqual(try XCTUnwrap(EstadoDoTeleprompter.doJSON(doHeader)), EstadoDoTeleprompter())
        let segurando = try XCTUnwrap(EstadoDoTeleprompter.doJSON(
            #"{"rolando":true,"para_tras":true,"segurando":true,"par_entende_segurar":true}"#))
        XCTAssertTrue(segurando.rolando)
        XCTAssertTrue(segurando.paraTras)
        XCTAssertTrue(segurando.segurando)
        XCTAssertTrue(segurando.parEntendeSegurar)
        // O núcleo de 13/09 não manda as chaves: ninguém segura, e o prompter não entende.
        let velho = try XCTUnwrap(EstadoDoTeleprompter.doJSON(#"{"rolando":true}"#))
        XCTAssertFalse(velho.paraTras)
        XCTAssertFalse(velho.segurando)
        XCTAssertFalse(velho.parEntendeSegurar)
        // Um número no lugar do booleano não liga nada.
        XCTAssertFalse(try XCTUnwrap(EstadoDoTeleprompter.doJSON(#"{"para_tras":1}"#)).paraTras)
    }

    // MARK: - os avisos

    func test_controle_sumido_so_depois_que_houve_sessao() {
        var e = EstadoDoTeleprompter()
        e.parVistoHaMs = nil
        XCTAssertFalse(AvisosDaTela.calcular(estado: e, ligacao: .semSessao, agora: 100).parSumido,
                       "esperando o primeiro controle não é controle sumido")
        XCTAssertTrue(AvisosDaTela.calcular(estado: e, ligacao: .caiu, agora: 100).parSumido)
    }

    /// `par_visto_ha_ms` nulo logo depois de conectar é "ainda não chegou nada", não "sumiu".
    func test_nulo_logo_depois_de_conectar_nao_pisca_o_aviso() {
        var e = EstadoDoTeleprompter()
        e.parVistoHaMs = nil
        let primeira = LigacaoDaTela.conectada(desde: 100, depoisDeQueda: false)
        XCTAssertFalse(AvisosDaTela.calcular(estado: e, ligacao: primeira, agora: 100.2).parSumido)
        XCTAssertFalse(AvisosDaTela.calcular(estado: e, ligacao: primeira, agora: 102.4).parSumido)
        XCTAssertTrue(AvisosDaTela.calcular(estado: e, ligacao: primeira, agora: 102.6).parSumido,
                      "2,5 s de sessão sem mensagem nenhuma é sumido")
        e.parVistoHaMs = 2_400
        XCTAssertFalse(AvisosDaTela.calcular(estado: e, ligacao: primeira, agora: 100).parSumido)
        e.parVistoHaMs = 2_600
        XCTAssertTrue(AvisosDaTela.calcular(estado: e, ligacao: primeira, agora: 100).parSumido)
    }

    /// Depois de uma queda, o aviso só some com a **primeira mensagem** do controle de volta (§2).
    func test_depois_da_queda_o_aviso_some_com_a_primeira_mensagem() {
        var e = EstadoDoTeleprompter()
        e.parVistoHaMs = nil
        let volta = LigacaoDaTela.conectada(desde: 100, depoisDeQueda: true)
        XCTAssertTrue(AvisosDaTela.calcular(estado: e, ligacao: volta, agora: 100.05).parSumido,
                      "o TCP subiu, mas o controle ainda não disse nada")
        e.parVistoHaMs = 3
        XCTAssertFalse(AvisosDaTela.calcular(estado: e, ligacao: volta, agora: 100.1).parSumido)
    }

    func test_sem_confirmacao_acima_de_um_segundo_e_meio() {
        var e = EstadoDoTeleprompter()
        e.parVistoHaMs = 10
        e.semConfirmacaoHaMs = 1_400
        let ligada = LigacaoDaTela.conectada(desde: 0, depoisDeQueda: false)
        XCTAssertFalse(AvisosDaTela.calcular(estado: e, ligacao: ligada, agora: 9).semConfirmacao)
        e.semConfirmacaoHaMs = 1_600
        XCTAssertTrue(AvisosDaTela.calcular(estado: e, ligacao: ligada, agora: 9).semConfirmacao)
        e.contadores.deOutraVersao = 1
        e.contadores.carimbosDoFuturo = 2
        e.contadores.reenviosDesistidos = 1
        let a = AvisosDaTela.calcular(estado: e, ligacao: ligada, agora: 9)
        XCTAssertTrue(a.atualizeOApp)
        XCTAssertTrue(a.relogioErrado)
        XCTAssertTrue(a.textoNaoPassou)
    }

    // MARK: - endereço

    func test_endereco_digitado_e_o_link_quall_antigo() {
        XCTAssertEqual(EnderecoDoPrompter.ler(" 192.168.57.20:7979 "),
                       EnderecoDoPrompter(endereco: "192.168.57.20:7979", pin: nil))
        XCTAssertEqual(EnderecoDoPrompter.ler("quall://424242@192.168.57.20:7979"),
                       EnderecoDoPrompter(endereco: "192.168.57.20:7979", pin: "424242"))
        XCTAssertEqual(EnderecoDoPrompter.ler("QUALL://424242@[fe80::1]:7979/"),
                       EnderecoDoPrompter(endereco: "[fe80::1]:7979", pin: "424242"))
        XCTAssertNil(EnderecoDoPrompter.ler("   "))
        XCTAssertNil(EnderecoDoPrompter.ler("quall://424242@"))
    }

    // MARK: - a lista do controle

    /// Só quem anuncia `"papel": "teleprompter"`, com endereço, e nunca este aparelho. Um anúncio
    /// sem papel (vídeo) e um papel desconhecido ficam de fora (§2).
    func test_a_lista_do_controle_filtra_pelo_papel() {
        let json = """
            [{"device_id":"tv","display_name":"TV da sala","protocol_version":2,
              "capabilities":{"screen_source":false,"camera_source":false,"sink":true},"endpoint":"192.168.56.9:7000"},
             {"device_id":"ipad","display_name":"iPad do estúdio","protocol_version":2,
              "capabilities":{"screen_source":false,"camera_source":false,"sink":false},"endpoint":"192.168.56.20:7979",
              "papel":"teleprompter"},
             {"device_id":"eu","display_name":"Este Mac","protocol_version":2,
              "capabilities":{"screen_source":false,"camera_source":false,"sink":false},"endpoint":"192.168.56.2:7979",
              "papel":"teleprompter"},
             {"device_id":"sem-endereco","display_name":"Tablet","protocol_version":2,
              "capabilities":{"screen_source":false,"camera_source":false,"sink":false},"endpoint":null,
              "papel":"teleprompter"},
             {"device_id":"futuro","display_name":"Outro","protocol_version":2,
              "capabilities":{"screen_source":false,"camera_source":false,"sink":false},"endpoint":"192.168.56.30:1",
              "papel":"painel_de_luz"},
             {"device_id":"android","display_name":"","protocol_version":2,
              "capabilities":{"screen_source":false,"camera_source":false,"sink":false},"endpoint":"192.168.56.21:7979",
              "papel":"teleprompter"}]
            """
        let lista = PrompterAchado.lista(doJSON: json, excluindo: "eu")
        XCTAssertEqual(lista.map(\.deviceId), ["android", "ipad"], "ordenada pelo nome; o sem nome mostra o endereço")
        XCTAssertEqual(lista.first?.nome, "192.168.56.21:7979")
        XCTAssertEqual(PrompterAchado.lista(doJSON: "não é json", excluindo: "eu"), [])
    }

    // MARK: - ações de bancada

    func test_acoes_de_bancada() {
        let a = AcoesDeBancada.ler("4:espelho=1,3:fonte=64, 3:margem=0.2,5:texto=@roteiro.txt,6:texto+=Linha nova,"
                                   + "7:pular=-0.05,8:salto=0,9:rolando=0,x:fonte=1,10:cor=azul,11:velocidade",
                                   lerArquivo: { $0 == "roteiro.txt" ? "Boa noite." : nil })
        XCTAssertEqual(a.acoes.map(\.segundos), [3, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(a.acoes.map(\.acao), [.fonte(64), .margem(0.2), .espelho(true), .texto("Boa noite."),
                                            .acrescentar("Linha nova"), .pular(-0.05), .salto(0), .rolando(false)])
        XCTAssertEqual(a.recusadas, ["x:fonte=1", "10:cor=azul", "11:velocidade"])

        let e = AcoesDeBancada.ler("2:editor=abrir,2.5:rascunho+=Linha minha,5:editor=manter-meu,6:editor=confirmar,"
                                   + "7:editor=usar-novo,8:editor=fechar")
        XCTAssertEqual(e.acoes.map(\.acao), [.editor(.abrir), .rascunho("Linha minha"), .editor(.manterMeu),
                                            .editor(.confirmar), .editor(.usarNovo)])
        XCTAssertEqual(e.recusadas, ["8:editor=fechar"])
    }

    /// As ações do "segurar para rolar": o modo, os três gestos do mouse, as três da tecla e o foco.
    func test_acoes_de_bancada_do_segurar() {
        let a = AcoesDeBancada.ler("1:modo-segurar=1,2:mouse-desce=baixo,3:mouse-sobe=baixo,4:mouse-sai=cima,"
                                   + "5:tecla-desce=cima,5.1:tecla-repete=cima,6:tecla-sobe=cima,7:foco=0,8:modo-segurar=0,"
                                   + "9:mouse-desce=lado,10:tecla-pula=cima,11:foco=1,12:mouse-desce=")
        XCTAssertEqual(a.acoes.map(\.acao), [
            .modoSegurar(true), .mouseDoSegurar(.desce, .baixo), .mouseDoSegurar(.sobe, .baixo),
            .mouseDoSegurar(.sai, .cima), .teclaDoSegurar(.desce, .cima), .teclaDoSegurar(.repete, .cima),
            .teclaDoSegurar(.sobe, .cima), .perderOFoco, .modoSegurar(false),
        ])
        XCTAssertEqual(a.recusadas, ["9:mouse-desce=lado", "10:tecla-pula=cima", "11:foco=1", "12:mouse-desce="])

        let i = AcoesDeBancada.ler("1:inverter=1,2:inverter=0,3:inverter=sim")
        XCTAssertEqual(i.acoes.map(\.acao), [.inverterBotoes(true), .inverterBotoes(false)])
        XCTAssertEqual(i.recusadas, ["3:inverter=sim"])
    }

    /// A gravação (§13.7): as quatro chaves do estado para a tela, literais do contrato.
    func test_os_campos_da_gravacao_sao_lidos_pelos_nomes_do_contrato() throws {
        let parado = try XCTUnwrap(EstadoDoTeleprompter.doJSON(
            #"{"gravando_ha_ms":null,"pedido_de_gravacao":null,"gravacao_recusada":null,"par_entende_gravar":false}"#))
        XCTAssertNil(parado.gravandoHaMs)
        XCTAssertNil(parado.pedidoDeGravacao)
        XCTAssertNil(parado.gravacaoRecusada)
        XCTAssertFalse(parado.parEntendeGravar)

        let e = try XCTUnwrap(EstadoDoTeleprompter.doJSON(
            #"{"gravando_ha_ms":12345,"pedido_de_gravacao":{"n":1790272721890,"gravar":false,"ha_ms":40},"#
            + #""gravacao_recusada":{"n":1790272721889,"gravar":true,"motivo":"sem espaço: sobram 312 MB"},"#
            + #""par_entende_gravar":true}"#))
        XCTAssertEqual(e.gravandoHaMs, 12345)
        XCTAssertEqual(e.pedidoDeGravacao, .init(n: 1790272721890, gravar: false, haMs: 40))
        XCTAssertEqual(e.gravacaoRecusada, .init(n: 1790272721889, gravar: true, motivo: "sem espaço: sobram 312 MB"))
        XCTAssertTrue(e.parEntendeGravar)

        // Um pedido sem `gravar` legível não é pedido (a casca não decide o que não leu).
        let torto = try XCTUnwrap(EstadoDoTeleprompter.doJSON(#"{"pedido_de_gravacao":{"n":3,"gravar":1}}"#))
        XCTAssertNil(torto.pedidoDeGravacao)
    }
}
