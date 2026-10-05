import XCTest
@testable import QuallReceptorKit

/// A linha de perda é o número que a bancada fotografa. Até 29/08/2026 toda casca desta casa
/// mostrava `packets_missing` como se fosse perda — e ele **nunca foi perda**: numa corrida com
/// 486 nele tinham sumido cinquenta pacotes. O erro medido vai de 1,3x a 44x, e contaminou os
/// laudos.
///
/// Estes testes afirmam as três coisas que impedem a linha de mentir de novo: os três números
/// aparecem **juntos**, chave ausente sai como `?` e nunca como zero, e a janela curta se
/// **denuncia**.
final class TestesDoResumoDePerda: XCTestCase {

    func testeOsTresNumerosAparecemJuntos() {
        let linha = ResumoDePerda.de([
            "packets_lost_for_real": 50,
            "packets_missing_upper_bound": 486,
            "packets_too_late": 0,
            "packets_seen": 27729,
        ])
        XCTAssertTrue(linha.contains("perda exata 50"), linha)
        XCTAssertTrue(linha.contains("teto 486"), linha)
        XCTAssertTrue(linha.contains("tarde demais 0"), linha)
        XCTAssertTrue(linha.contains("vistos 27729"), linha)
    }

    /// As duas taxas são calculadas sobre `v / (v + vistos)`, e são **duas**, não uma. Os números
    /// abaixo são os da corrida MacBook → A10s de 29/08 registrada no header do núcleo.
    func testeAsDuasTaxas() {
        let linha = ResumoDePerda.de([
            "packets_lost_for_real": 50,
            "packets_missing_upper_bound": 486,
            "packets_too_late": 0,
            "packets_seen": 27729,
        ])
        // 50/28215 = 0,180% e 486/28215 = 1,722%. O `String(format:)` do Swift formata em POSIX
        // (ponto decimal) mesmo com a interface em português — os dois são aceitos porque quem
        // muda isso é o `Locale` do processo, não este arquivo.
        XCTAssertTrue(linha.contains("(0,180%)") || linha.contains("(0.180%)"), linha)
        XCTAssertTrue(linha.contains("(1,722%)") || linha.contains("(1.722%)"), linha)
    }

    /// **Chave ausente sai como `?`, nunca como zero.** Um `0` diria "medi e não perdi nada", que é
    /// a afirmação mais perigosa que este relatório pode fazer por engano — e é exatamente o que
    /// um leitor não migrado veria depois de `packets_missing` ter sido renomeado sem alias.
    func testeChaveAusenteSaiComoInterrogacaoENaoComoZero() {
        let linha = ResumoDePerda.de(["packets_seen": 100])
        XCTAssertTrue(linha.contains("perda exata ?"), linha)
        XCTAssertFalse(linha.contains("perda exata 0"), linha)
    }

    /// O nome velho **não** vale. Se alguém reintroduzir `packets_missing` como alias em algum
    /// lugar, este teste continua exigindo que a linha diga `?` — a renomeação existe justamente
    /// para tirar a armadilha, e um alias a traria de volta.
    func testeONomeVelhoNaoEAceito() {
        let linha = ResumoDePerda.de(["packets_missing": 486, "packets_seen": 100])
        XCTAssertTrue(linha.contains("teto ?"), linha)
    }

    /// `packets_seen == 0` quer dizer que nenhum pacote chegou ainda: aí **não se afirma nada**.
    func testeSemPacoteNenhumNaoSeAfirmaNada() {
        let linha = ResumoDePerda.de(["packets_seen": 0, "packets_lost_for_real": 0])
        XCTAssertTrue(linha.contains("nada a afirmar"), linha)
        XCTAssertFalse(linha.contains("perda exata"), linha)
    }

    /// A janela de reordenação tem 128 posições. Um pacote que chega depois de a posição dele já
    /// ter saído dela é cobrado como perda que não era — e a leitura precisa dizer isso, senão a
    /// "perda exata" deixa de ser exata em silêncio.
    func testeJanelaCurtaSeDenuncia() {
        let linha = ResumoDePerda.de([
            "packets_lost_for_real": 12,
            "packets_missing_upper_bound": 20,
            "packets_too_late": 7,
            "packets_seen": 1000,
        ])
        XCTAssertTrue(linha.contains("JANELA CURTA"), linha)
        XCTAssertTrue(linha.contains("superestimada em até 7"), linha)
    }

    /// Um JSON ilegível vira uma frase que **diz** que não deu para ler. Um resumo de perda que
    /// some do relatório é pior que um que se declara ausente.
    func testeJsonIlegivelSeDeclara() {
        XCTAssertEqual(ResumoDePerda.formatar("{isto não é json"),
                       "perda: contadores do núcleo ilegíveis")
        XCTAssertEqual(ResumoDePerda.formatar(""),
                       "perda: contadores do núcleo ilegíveis")
    }

    /// O caminho de verdade: o texto sai do JSON como a fronteira C o entrega.
    func testeFormataDoJsonCru() {
        let json = """
        {"frames_ready":1201,"frames_dropped":0,"sequence_anomalies":0,\
        "packets_missing_upper_bound":0,"reorder_events":0,"packets_seen":8321,\
        "packets_lost_for_real":0,"packets_too_late":0,"idr_requests":1,"jitter_us":null}
        """
        let linha = ResumoDePerda.formatar(json)
        XCTAssertTrue(linha.contains("perda exata 0"), linha)
        XCTAssertTrue(linha.contains("vistos 8321"), linha)
        XCTAssertFalse(linha.contains("JANELA CURTA"), linha)
    }
}
