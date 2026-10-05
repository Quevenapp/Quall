import XCTest
@testable import QuallTeleprompterKit

/// **A pergunta do texto e os roteiros guardados** no controle (`docs/contrato-teleprompter.md`
/// §11), sem núcleo e sem janela: as duas chaves do estado, a contagem de palavras, a regra da
/// caixa e os textos literais do pedido de 14/09 à tarde.
final class TestesDaPergunta: XCTestCase {

    /// O exemplo literal da §11.6, com a pergunta aberta e uma cópia.
    func test_as_duas_chaves_da_secao_11_6() throws {
        let json = """
            {"rolando":false,"velocidade":1.0,"contadores":{"estados_enviados":0},
             "pergunta_do_texto":{"aberta":true,"retido_ha_ms":840,"prompter_id":"ipad-a1b2",
              "prompter_nome":"iPad da Maria",
              "meu":{"bytes":10,"resumo":"0123456789abcdef","previa":"Boa noite."},
              "do_prompter":{"bytes":15,"resumo":"fedcba9876543210","previa":"Bom dia a todos"}},
             "copias_do_texto":[{"origem":"prompter","prompter_id":"ipad-a1b2","prompter_nome":"iPad da Maria",
              "quando_ms":1757880000000,"bytes":15,"resumo":"fedcba9876543210","previa":"Bom dia a todos"},
              {"origem":"controle","prompter_id":"a07","prompter_nome":"","quando_ms":1757870000000,
              "bytes":10,"resumo":"0123456789abcdef","previa":"Boa noite."}]}
            """
        let e = try XCTUnwrap(EstadoDoTeleprompter.doJSON(json))
        let p = try XCTUnwrap(e.perguntaDoTexto)
        XCTAssertTrue(p.aberta)
        XCTAssertEqual(p.retidoHaMs, 840)
        XCTAssertEqual(p.prompterId, "ipad-a1b2")
        XCTAssertEqual(p.prompterNome, "iPad da Maria")
        XCTAssertEqual(p.meu, LadoDaPergunta(bytes: 10, resumo: "0123456789abcdef", previa: "Boa noite."))
        XCTAssertEqual(p.doPrompter, LadoDaPergunta(bytes: 15, resumo: "fedcba9876543210", previa: "Bom dia a todos"))
        XCTAssertEqual(e.copiasDoTexto.count, 2)
        XCTAssertEqual(e.copiasDoTexto[0].origem, .prompter)
        XCTAssertEqual(e.copiasDoTexto[0].quandoMs, 1_757_880_000_000)
        XCTAssertEqual(e.copiasDoTexto[0].deOnde, "Do prompter iPad da Maria")
        XCTAssertEqual(e.copiasDoTexto[1].origem, .controle)
        XCTAssertEqual(e.copiasDoTexto[1].deOnde, "Deste aparelho, antes de a07", "sem nome, o device_id")
        XCTAssertEqual(e.copiasDoTexto.map(\.id), ["fedcba9876543210", "0123456789abcdef"], "a chave é o resumo")

        // Comparando: aberta falso e do_prompter nulo. Sem nada retido: null. Sem cópias: [].
        let comparando = try XCTUnwrap(EstadoDoTeleprompter.doJSON(
            #"{"pergunta_do_texto":{"aberta":false,"retido_ha_ms":1200,"prompter_id":"p","prompter_nome":"P","meu":{"bytes":3,"resumo":"aaaa","previa":"Oi."},"do_prompter":null},"copias_do_texto":[]}"#))
        XCTAssertEqual(comparando.perguntaDoTexto?.aberta, false)
        XCTAssertNil(comparando.perguntaDoTexto?.doPrompter)
        XCTAssertEqual(comparando.copiasDoTexto, [])
        let nada = try XCTUnwrap(EstadoDoTeleprompter.doJSON(#"{"pergunta_do_texto":null,"copias_do_texto":[]}"#))
        XCTAssertNil(nada.perguntaDoTexto)
        // Um estado de 13/09, sem as chaves, é o de antes.
        XCTAssertEqual(try XCTUnwrap(EstadoDoTeleprompter.doJSON(#"{"rolando":true}"#)).copiasDoTexto, [])
        // Uma cópia sem resumo não se pode ver, usar nem apagar: fica de fora, sem derrubar as outras.
        let torta = try XCTUnwrap(EstadoDoTeleprompter.doJSON(
            #"{"copias_do_texto":[{"origem":"prompter","bytes":1},{"origem":"prompter","resumo":"bbbb","bytes":2,"previa":"x"}]}"#))
        XCTAssertEqual(torta.copiasDoTexto.map(\.resumo), ["bbbb"])
    }

    /// **Palavra** é a da fonte automática: um trecho sem espaço com pelo menos uma letra ou
    /// algarismo. Travessão, reticências e emoji sozinhos não contam.
    func test_palavras_como_na_fonte_automatica() {
        XCTAssertEqual(Palavras.contar("Boa noite, a todos."), 4)
        XCTAssertEqual(Palavras.contar("  Linha 12:\n\nação — e emoção… 🎬 "), 5, "Linha, 12:, ação, e, emoção…")
        XCTAssertEqual(Palavras.contar("— … 🎬 !!"), 0)
        XCTAssertEqual(Palavras.contar(""), 0)
        XCTAssertEqual(Palavras.contar("a—b"), 1, "sem espaço é uma palavra só")
        XCTAssertEqual(Palavras.contar("responsabilidade\tdesenvolvimento"), 2)
        // Concordância e ponto de milhar em pt-BR, iguais nas quatro telas (o coordenador, 14/09).
        XCTAssertEqual(TextosDaPergunta.palavras(1), "1 palavra")
        XCTAssertEqual(TextosDaPergunta.palavras(2), "2 palavras")
        XCTAssertEqual(TextosDaPergunta.palavras(0), "0 palavras", "texto vazio")
        XCTAssertEqual(TextosDaPergunta.palavras(999), "999 palavras")
        XCTAssertEqual(TextosDaPergunta.palavras(1_000), "1.000 palavras")
        XCTAssertEqual(TextosDaPergunta.palavras(1_234), "1.234 palavras")
        XCTAssertEqual(TextosDaPergunta.palavras(4_260), "4.260 palavras")
        XCTAssertEqual(TextosDaPergunta.palavras(21_345), "21.345 palavras")
        XCTAssertEqual(TextosDaPergunta.palavras(1_234_567), "1.234.567 palavras")
    }

    /// Os textos, literais do pedido — iguais nas quatro telas.
    func test_os_textos_sao_os_do_pedido() {
        XCTAssertEqual(TextosDaPergunta.titulo(prompter: "iPad da Maria"), "O prompter iPad da Maria tem outro roteiro.")
        XCTAssertEqual(TextosDaPergunta.noPrompter, "No prompter")
        XCTAssertEqual(TextosDaPergunta.nesteAparelho, "Neste aparelho")
        XCTAssertEqual(TextosDaPergunta.usarODoPrompter, "Usar o do prompter")
        XCTAssertEqual(TextosDaPergunta.mandarOMeu, "Mandar o meu")
        XCTAssertEqual(TextosDaPergunta.oQueSairFicaGuardado, "O roteiro que sair fica em Roteiros guardados.")
        XCTAssertEqual(TextosDaPergunta.conferindo, "Conferindo o roteiro do prompter…")
        XCTAssertEqual(TextosDaPergunta.oPrompterSaiu, "O prompter saiu. A pergunta volta quando ele voltar.")
        XCTAssertEqual(TextosDaPergunta.oRoteiroMudou, "O roteiro do prompter mudou. Confira de novo.")
        XCTAssertEqual(TextosDaPergunta.roteirosGuardados, "Roteiros guardados")
        XCTAssertEqual(TextosDaPergunta.nenhumRoteiroGuardado, "Nenhum roteiro guardado.")
        XCTAssertEqual(TextosDaPergunta.usarEsteRoteiroTitulo + " " + TextosDaPergunta.usarEsteRoteiroMensagem,
                       "Usar este roteiro? Ele substitui o roteiro atual, também no prompter conectado.")
        XCTAssertEqual(TextosDaPergunta.apagarEsteRoteiro, "Apagar este roteiro guardado?")
        XCTAssertEqual([TextosDaPergunta.ver, TextosDaPergunta.usarEste, TextosDaPergunta.apagar,
                        TextosDaPergunta.usar, TextosDaPergunta.cancelar],
                       ["Ver", "Usar este", "Apagar", "Usar", "Cancelar"])
    }

    private let doPrompter = LadoDaPergunta(bytes: 15, resumo: "fedcba9876543210", previa: "Bom dia a todos")
    private let meu = LadoDaPergunta(bytes: 10, resumo: "0123456789abcdef", previa: "Boa noite.")

    private func pergunta(aberta: Bool, retido: UInt64 = 500, nome: String = "iPad da Maria") -> PerguntaDoTexto {
        PerguntaDoTexto(aberta: aberta, retidoHaMs: retido, prompterId: "ipad-a1b2", prompterNome: nome,
                        meu: meu, doPrompter: aberta ? doPrompter : nil)
    }

    /// **Os estados da caixa** (o pedido, item 3).
    func test_os_estados_da_caixa() {
        typealias C = CaixaDaPergunta
        XCTAssertEqual(C.calcular(pergunta: nil, parVistoHaMs: 10, conectado: true, recusa: nil), .nenhuma)
        // Comparando há pouco: nada na tela; há mais de ~1 s: "Conferindo…", sem botões.
        XCTAssertEqual(C.calcular(pergunta: pergunta(aberta: false, retido: 900), parVistoHaMs: 10, conectado: true, recusa: nil), .nenhuma)
        XCTAssertEqual(C.calcular(pergunta: pergunta(aberta: false, retido: 1_100), parVistoHaMs: 10, conectado: true, recusa: nil), .conferindo)
        XCTAssertFalse(C.conferindo.escolhasLigadas)
        XCTAssertNil(C.conferindo.resumoMostrado)
        // Aberta: as escolhas ligadas, e o resumo mostrado é o do prompter.
        let aberta = C.calcular(pergunta: pergunta(aberta: true), parVistoHaMs: 10, conectado: true, recusa: nil)
        XCTAssertEqual(aberta, .perguntando(prompterNome: "iPad da Maria", doPrompter: doPrompter, meu: meu,
                                            escolhasLigadas: true, aviso: nil))
        XCTAssertEqual(aberta.resumoMostrado, "fedcba9876543210")
        // O prompter sumiu (par_visto_ha_ms nulo), a sessão caiu, ou a escolha deu CLOSED: desligadas.
        for c in [C.calcular(pergunta: pergunta(aberta: true), parVistoHaMs: nil, conectado: true, recusa: nil),
                  C.calcular(pergunta: pergunta(aberta: true), parVistoHaMs: 10, conectado: false, recusa: nil),
                  C.calcular(pergunta: pergunta(aberta: true), parVistoHaMs: 10, conectado: true, recusa: .fechado)] {
            XCTAssertFalse(c.escolhasLigadas)
            XCTAssertEqual(c, .perguntando(prompterNome: "iPad da Maria", doPrompter: doPrompter, meu: meu,
                                           escolhasLigadas: false, aviso: "O prompter saiu. A pergunta volta quando ele voltar."))
        }
        // BUSY: ligadas, com o aviso de conferir de novo.
        XCTAssertEqual(C.calcular(pergunta: pergunta(aberta: true), parVistoHaMs: 10, conectado: true, recusa: .ocupado),
                       .perguntando(prompterNome: "iPad da Maria", doPrompter: doPrompter, meu: meu,
                                    escolhasLigadas: true, aviso: "O roteiro do prompter mudou. Confira de novo."))
        // Sem nome, o device_id (derivado).
        if case .perguntando(let nome, _, _, _, _) = C.calcular(pergunta: pergunta(aberta: true, nome: ""), parVistoHaMs: 1,
                                                                conectado: true, recusa: nil) {
            XCTAssertEqual(nome, "ipad-a1b2")
        } else {
            XCTFail("a caixa não abriu")
        }
        // Aberta sem um dos lados (um estado torto): conferindo, e nunca botões sem o que escolher.
        var torta = pergunta(aberta: true, retido: 5_000)
        torta.doPrompter = nil
        XCTAssertEqual(C.calcular(pergunta: torta, parVistoHaMs: 1, conectado: true, recusa: nil), .conferindo)
    }

    func test_acoes_de_bancada_da_pergunta() {
        let a = AcoesDeBancada.ler("1:escolha=prompter,2:escolha=meu,3:guardados=abrir,4:copia=ver:1,5:copia=usar:2,"
                                   + "6:copia=apagar:3,7:copia=confirmar,8:copia=cancelar,9:copia=voltar,10:guardados=fechar,"
                                   + "11:escolha=nenhuma,12:copia=ver:0,13:copia=ver,14:copia=usar:x,15:guardados=talvez,16:copia=confirmar:1")
        XCTAssertEqual(a.acoes.map(\.acao), [
            .escolha(manterOMeu: false), .escolha(manterOMeu: true), .roteirosGuardados(true),
            .copia(.ver(1)), .copia(.usar(2)), .copia(.apagar(3)), .copia(.confirmar), .copia(.cancelar),
            .copia(.voltar), .roteirosGuardados(false),
        ])
        XCTAssertEqual(a.recusadas, ["11:escolha=nenhuma", "12:copia=ver:0", "13:copia=ver", "14:copia=usar:x",
                                     "15:guardados=talvez", "16:copia=confirmar:1"])
    }
}
