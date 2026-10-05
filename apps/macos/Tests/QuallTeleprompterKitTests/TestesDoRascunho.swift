import XCTest
@testable import QuallTeleprompterKit

/// **A regra do texto que chega com o editor aberto** (item 3 da frente; `RascunhoDoTexto`).
final class TestesDoRascunho: XCTestCase {

    func test_sem_alteracao_o_texto_novo_entra_sozinho() {
        var r = RascunhoDoTexto(textoAtual: "Boa noite.")
        r.chegou(textoNovo: "Boa noite, Brasil.")
        XCTAssertFalse(r.emConflito)
        XCTAssertEqual(r.rascunho, "Boa noite, Brasil.")
        XCTAssertTrue(r.atualizadoPeloOutroLado)
        XCTAssertNil(r.paraConfirmar(textoDaReplica: "Boa noite, Brasil."), "nada a mandar")
    }

    func test_com_alteracao_o_rascunho_nao_e_tocado_e_a_pessoa_escolhe() {
        var r = RascunhoDoTexto(textoAtual: "Boa noite.")
        r.rascunho = "Boa noite, meu povo."
        r.chegou(textoNovo: "Boa tarde.")
        XCTAssertTrue(r.emConflito)
        XCTAssertEqual(r.rascunho, "Boa noite, meu povo.", "o que a pessoa digitou não muda sob o cursor")
        XCTAssertEqual(r.textoNovoDoOutroLado, "Boa tarde.")
        // Um segundo texto chegando antes da escolha: vale o mais novo.
        r.chegou(textoNovo: "Boa tarde, Brasil.")
        XCTAssertEqual(r.textoNovoDoOutroLado, "Boa tarde, Brasil.")
    }

    func test_usar_o_texto_novo_devolve_o_rascunho_descartado() {
        var r = RascunhoDoTexto(textoAtual: "A")
        r.rascunho = "A editado"
        r.chegou(textoNovo: "B")
        XCTAssertEqual(r.usarOTextoNovo(), "A editado", "vai para a área de transferência")
        XCTAssertEqual(r.rascunho, "B")
        XCTAssertFalse(r.emConflito)
        XCTAssertFalse(r.alterado)
        XCTAssertNil(r.usarOTextoNovo(), "sem conflito, nada a descartar")
    }

    /// "Manter o meu": confirmar manda o rascunho, que vence por ser a edição mais recente — mesmo
    /// que ele seja igual ao texto de quando o editor abriu.
    func test_manter_o_meu_e_confirmar_manda_o_rascunho() {
        var r = RascunhoDoTexto(textoAtual: "A")
        r.rascunho = "A editado"
        r.chegou(textoNovo: "B")
        r.manterOMeu()
        XCTAssertFalse(r.emConflito)
        XCTAssertEqual(r.paraConfirmar(textoDaReplica: "B"), "A editado")
        // Um terceiro texto depois de "manter o meu" volta a perguntar.
        r.chegou(textoNovo: "C")
        XCTAssertTrue(r.emConflito)
        // Desfazer até o original, com o outro lado tendo mudado: ainda é preciso mandar.
        var s = RascunhoDoTexto(textoAtual: "A")
        s.rascunho = "A2"
        s.chegou(textoNovo: "B")
        s.manterOMeu()
        s.rascunho = "A"
        XCTAssertEqual(s.paraConfirmar(textoDaReplica: "B"), "A")
    }

    func test_o_outro_lado_chegou_ao_mesmo_texto() {
        var r = RascunhoDoTexto(textoAtual: "A")
        r.rascunho = "A B"
        r.chegou(textoNovo: "A B")
        XCTAssertFalse(r.emConflito, "sem o que escolher")
        XCTAssertNil(r.paraConfirmar(textoDaReplica: "A B"))
    }

    func test_nul_e_tirado_ao_confirmar() {
        var r = RascunhoDoTexto(textoAtual: "")
        r.rascunho = "a\u{0}b"
        XCTAssertEqual(r.paraConfirmar(textoDaReplica: ""), "ab")
        XCTAssertEqual(r.bytes, 3)
    }
}
