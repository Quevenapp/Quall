import Foundation
import XCTest
@testable import QuallCaptureKit

/// A câmera do próprio Quall fica fora do catálogo (`CameraDoQuall`).
///
/// # O que este teste prova, e o que ele não prova
///
/// Prova a regra: o UUID da extensão, em qualquer caixa, sai; os outros `uniqueID` deste MacBook
/// (UUID ou não) ficam; a ordem das que ficam não muda; e a cópia do UUID neste pacote é
/// a mesma que a extensão publica — lida do arquivo da extensão, para as duas não divergirem em
/// silêncio.
///
/// **Não** prova que o `AVCaptureDevice` da extensão chega com esse `uniqueID`. Isso é pergunta de
/// máquina com a extensão instalada, e foi medido em 18/09/2026 neste Mac com a mesma
/// `DiscoverySession` do catálogo, sem abrir câmera nenhuma (`docs/camera-no-windows.md`).
final class TestesDaCameraDoQuall: XCTestCase {

    private struct Aparelho: Equatable {
        let uniqueID: String
        let nome: String
    }

    func testeOUuidDaExtensaoEhDoQuallEmQualquerCaixa() {
        XCTAssertTrue(CameraDoQuall.ehDoQuall(uniqueID: "9E7B34B1-6C0A-4F3D-9E2A-1C4D5B6A7E80"))
        XCTAssertTrue(CameraDoQuall.ehDoQuall(uniqueID: "9e7b34b1-6c0a-4f3d-9e2a-1c4d5b6a7e80"))
    }

    func testeOutrasCamerasNaoSaoDoQuall() {
        // Os fluxos da extensão (…81, …82) não são o dispositivo.
        XCTAssertFalse(CameraDoQuall.ehDoQuall(uniqueID: "9E7B34B1-6C0A-4F3D-9E2A-1C4D5B6A7E81"))
        // Os `uniqueID` lidos neste MacBook em 18/09 (`docs/camera-no-windows.md`, M25), sem abrir
        // nada: a placa de captura USB não é UUID; a câmera interna, a Visualização da Mesa e a OBS
        // são UUID, mas outro.
        XCTAssertFalse(CameraDoQuall.ehDoQuall(uniqueID: "0x123340032ed3201"))
        XCTAssertFalse(CameraDoQuall.ehDoQuall(uniqueID: "6C707041-05AC-0010-000C-000000000001"))
        XCTAssertFalse(CameraDoQuall.ehDoQuall(uniqueID: "6C707041-05AC-0010-000C-000000000002"))
        XCTAssertFalse(CameraDoQuall.ehDoQuall(uniqueID: "7626645E-4425-469E-9D8B-97E0FA59AC75"))
        XCTAssertFalse(CameraDoQuall.ehDoQuall(uniqueID: ""))
        // O CLSID da fonte do Windows não é o dispositivo do Mac.
        XCTAssertFalse(CameraDoQuall.ehDoQuall(uniqueID: "5C75FE52-9204-45F6-B143-58B1AC8048E5"))
    }

    func testeSepararTiraSoADoQuallESemMudarAOrdem() {
        // A lista deste MacBook, na ordem em que a `DiscoverySession` a devolveu (M25).
        let lista = [
            Aparelho(uniqueID: "0x123340032ed3201", nome: "ezcap GAMEDOCK ULTRA"),
            Aparelho(uniqueID: "6C707041-05AC-0010-000C-000000000001", nome: "Câmera do MacBook Air"),
            Aparelho(uniqueID: "7626645E-4425-469E-9D8B-97E0FA59AC75", nome: "OBS Virtual Camera"),
            Aparelho(uniqueID: "9E7B34B1-6C0A-4F3D-9E2A-1C4D5B6A7E80", nome: "Quall"),
            Aparelho(uniqueID: "6C707041-05AC-0010-000C-000000000002", nome: "Câmera para Visualização da Mesa"),
        ]
        let (nossas, outras) = CatalogoDeFontes.separarADoQuall(lista, uniqueID: \.uniqueID)
        XCTAssertEqual(nossas.map(\.nome), ["Quall"])
        XCTAssertEqual(outras.map(\.nome), [
            "ezcap GAMEDOCK ULTRA", "Câmera do MacBook Air", "OBS Virtual Camera",
            "Câmera para Visualização da Mesa",
        ])
    }

    func testeSemACameraDoQuallNadaSai() {
        let lista = [Aparelho(uniqueID: "6C707041-05AC-0010-000C-000000000001", nome: "Câmera do MacBook Air")]
        let (nossas, outras) = CatalogoDeFontes.separarADoQuall(lista, uniqueID: \.uniqueID)
        XCTAssertTrue(nossas.isEmpty)
        XCTAssertEqual(outras, lista)
    }

    /// A raiz do repositório, a partir deste arquivo.
    private var raiz: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QuallCaptureKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // apps/macos
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // raiz do repositório
    }

    /// **A extensão publica esse UUID nos dois ids.** O `uniqueID` do `AVCaptureDevice` segue o id
    /// do lado do DAL, que é o `legacyDeviceID`; se alguém trocar o `legacyDeviceID` (um padrão comum
    /// de compatibilidade), o filtro cairia calado com todos os outros testes passando (a revisão de
    /// código de 18/09). Lê `DispositivoQuall.swift` e exige os dois.
    func testeAExtensaoPublicaOUuidComoDeviceIDEComoLegacyDeviceID() throws {
        let arquivo = raiz.appendingPathComponent("integrations/camera-macos/Fontes/Extensao/DispositivoQuall.swift")
        let texto = try String(contentsOf: arquivo, encoding: .utf8)
        let semEspaco = texto.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(semEspaco.contains("deviceID:Identidade.idDoDispositivo,"),
                      "DispositivoQuall.swift não passa mais Identidade.idDoDispositivo como deviceID")
        XCTAssertTrue(semEspaco.contains("legacyDeviceID:Identidade.idDoDispositivo.uuidString"),
                      "DispositivoQuall.swift não passa mais o uuidString de Identidade.idDoDispositivo como legacyDeviceID")
    }

    /// **A cópia do UUID é a da extensão.** Lê `Identidade.swift` da extensão de câmera a partir
    /// deste arquivo e procura o literal de `idDoDispositivo`.
    func testeOUuidEhOMesmoQueAExtensaoPublica() throws {
        let identidade = raiz.appendingPathComponent("integrations/camera-macos/Fontes/Comum/Identidade.swift")
        let texto = try String(contentsOf: identidade, encoding: .utf8)
        let linha = texto.split(separator: "\n").first { $0.contains("static let idDoDispositivo") }
        let achada = try XCTUnwrap(linha, "Identidade.swift não declara mais idDoDispositivo")
        XCTAssertTrue(
            achada.contains("\"\(CameraDoQuall.idDoDispositivo.uuidString)\""),
            "CameraDoQuall.idDoDispositivo diverge da extensão: \(achada)")
    }
}
