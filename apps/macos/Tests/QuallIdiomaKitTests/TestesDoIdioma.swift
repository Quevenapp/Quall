import Foundation
import XCTest
@testable import QuallIdiomaKit

/// **A tradução sem app** (`docs/traducao.md`, "macOS"): a tabela inglesa sai do pacote de recursos, as
/// lacunas batem entre as duas línguas, toda chave usada no código tem tradução e toda tradução tem quem
/// a use, e o texto de tela que ainda está literal no código é acusado pelo nome.
final class TestesDoIdioma: XCTestCase {
    override func tearDown() {
        Idioma.atual = .pt
        super.tearDown()
    }

    // MARK: - o pacote e a tabela

    func testOPacoteDeRecursosEAchadoEATabelaCarrega() {
        XCTAssertNotNil(Traducoes.pacote, "o pacote QuallCapture_QuallIdiomaKit.bundle não foi achado")
        XCTAssertGreaterThan(Traducoes.ingles.count, 400)
        XCTAssertEqual(T("Espelhar", em: .en), "Mirror")
        XCTAssertEqual(T("Espelhar", em: .pt), "Espelhar")
    }

    /// Sob o XCTest o padrão é o texto-fonte: os testes que comparam frases em português não dependem do
    /// idioma do Mac.
    func testSobOXCTestOPadraoEOPortugues() {
        XCTAssertEqual(Idioma.resolvido(ambiente: [:], guardado: "en", preferidos: ["en-US"], sobXCTest: true), .pt)
    }

    // MARK: - a ordem do padrão (contrato, item 2)

    func testOIdiomaDoSistemaDecideQuandoNaoHaEscolha() {
        XCTAssertEqual(Idioma.doSistema(["pt-BR", "en-US"]), .pt)
        XCTAssertEqual(Idioma.doSistema(["pt-PT"]), .pt)
        XCTAssertEqual(Idioma.doSistema(["pt"]), .pt)
        XCTAssertEqual(Idioma.doSistema(["en-US", "pt-BR"]), .en)
        XCTAssertEqual(Idioma.doSistema(["es-ES"]), .en)
        XCTAssertEqual(Idioma.doSistema(["ja"]), .en)
        XCTAssertEqual(Idioma.resolvido(ambiente: [:], guardado: nil, preferidos: ["pt-BR"], sobXCTest: false), .pt)
        XCTAssertEqual(Idioma.resolvido(ambiente: [:], guardado: nil, preferidos: ["de-DE"], sobXCTest: false), .en)
    }

    func testAEscolhaGuardadaVenceOSistemaEOAmbienteVenceTudo() {
        XCTAssertEqual(Idioma.resolvido(ambiente: [:], guardado: "en", preferidos: ["pt-BR"], sobXCTest: false), .en)
        XCTAssertEqual(Idioma.resolvido(ambiente: [:], guardado: "pt", preferidos: ["en-US"], sobXCTest: false), .pt)
        XCTAssertEqual(Idioma.resolvido(ambiente: [:], guardado: "xx", preferidos: ["en-US"], sobXCTest: false), .en)
        XCTAssertEqual(Idioma.resolvido(ambiente: ["QUALL_IDIOMA": "en"], guardado: "pt", preferidos: ["pt-BR"],
                                        sobXCTest: true), .en)
        XCTAssertEqual(Idioma.resolvido(ambiente: ["QUALL_IDIOMA": "PT"], guardado: "en", preferidos: ["en"],
                                        sobXCTest: false), .pt)
    }

    // MARK: - a troca

    func testATrocaValeNaHoraENaoPrecisaGuardar() {
        let troca = TrocaDeIdioma()
        troca.escolher(.en, guardar: false)
        XCTAssertEqual(Idioma.atual, .en)
        XCTAssertEqual(troca.atual, .en)
        XCTAssertEqual(T("Espelhar"), "Mirror")
        troca.alternar() // guarda: grava no domínio do xctest, que não é o do app
        XCTAssertEqual(troca.atual, .pt)
        XCTAssertEqual(T("Espelhar"), "Espelhar")
        UserDefaults.standard.removeObject(forKey: Idioma.chaveDaEscolha)
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }

    func testLacunasNaOrdemENumIdiomaSoComPorcentagem() {
        Idioma.atual = .pt
        XCTAssertEqual(T("Espelhando para %@", "iPad"), "Espelhando para iPad")
        XCTAssertEqual(T("%@ e %@", "ISO", "o obturador"), "ISO e o obturador")
        Idioma.atual = .en
        XCTAssertEqual(T("Espelhando para %@", "iPad"), "Mirroring to iPad")
        XCTAssertEqual(T("%@ aparelhos", 3), "3 devices")
        // Sem lacuna, o `%` não é formato.
        XCTAssertEqual(T("Pular 5% para trás (← pula 2%, ⇧← 10%)"), "Jump back 5% (← jumps 2%, ⇧← 10%)")
        // Chave sem tradução volta em português.
        XCTAssertEqual(T("frase que não existe"), "frase que não existe")
    }

    func testRetraduzidoVaiENaoVolta() {
        Idioma.atual = .en
        XCTAssertEqual(retraduzido("Não consegui reservar uma porta de rede neste Mac."),
                       "Couldn't reserve a network port on this Mac.")
        XCTAssertEqual(retraduzido("Couldn't reserve a network port on this Mac."),
                       "Couldn't reserve a network port on this Mac.")
        Idioma.atual = .pt
        XCTAssertEqual(retraduzido("Couldn't reserve a network port on this Mac."),
                       "Não consegui reservar uma porta de rede neste Mac.")
        XCTAssertEqual(retraduzido("iPad do Pessoa Exemplo saiu."), "iPad do Pessoa Exemplo saiu.")
    }

    func testComecaComoReconheceOAvisoNasDuasLinguas() {
        XCTAssertTrue(comecaComo("sem som: a saída está sendo remontada", "sem som: %@"))
        XCTAssertTrue(comecaComo("no audio: the output is being rebuilt", "sem som: %@"))
        XCTAssertTrue(comecaComo("Connection lost (BUSY) — trying again.", "Conexão perdida"))
        XCTAssertFalse(comecaComo("som: tocando, volume 80%", "sem som: %@"))
        XCTAssertFalse(comecaComo("audio: playing, volume 80%", "sem som: %@"))
    }

    // MARK: - a paridade (contrato, item 7)

    /// As lacunas (`%@`, `%.1f`, `%%`…) são as mesmas nas duas línguas — a ordem pode trocar com `%1$@`.
    func testAsLacunasBatemEntreAsDuasLinguas() {
        var erradas: [String] = []
        for (pt, en) in Traducoes.ingles where TestesDoIdioma.lacunas(pt) != TestesDoIdioma.lacunas(en) {
            erradas.append("\"\(pt)\" → \"\(en)\": \(TestesDoIdioma.lacunas(pt)) ≠ \(TestesDoIdioma.lacunas(en))")
        }
        XCTAssertEqual(erradas, [], "lacunas diferentes:\n" + erradas.joined(separator: "\n"))
        for (pt, en) in Traducoes.ingles {
            XCTAssertFalse(en.trimmingCharacters(in: .whitespaces).isEmpty && !pt.trimmingCharacters(in: .whitespaces).isEmpty,
                           "tradução vazia para \"\(pt)\"")
        }
    }

    /// Toda chave usada no código (`T("...")`) tem tradução, e toda tradução tem quem a use.
    func testTodaChaveDoCodigoTemTraducaoENenhumaSobra() throws {
        let usadas = try TestesDoIdioma.chavesDoCodigo()
        XCTAssertGreaterThan(usadas.count, 400, "a varredura não achou os fontes")
        let faltam = usadas.subtracting(Traducoes.ingles.keys).sorted()
        let sobram = Set(Traducoes.ingles.keys).subtracting(usadas).sorted()
        XCTAssertEqual(faltam, [], "chaves sem tradução em en.lproj/Localizable.strings:\n" + faltam.joined(separator: "\n"))
        XCTAssertEqual(sobram, [], "traduções que nenhum T(...) usa:\n" + sobram.joined(separator: "\n"))
    }

    /// **A varredura**: texto de tela ainda literal no código — `Text("…")`, `Button("…")`, `.help("…")`,
    /// `titulo: "…"` e companhia com letra dentro — é acusado com arquivo e linha.
    func testNenhumTextoDeTelaFicouLiteral() throws {
        let achados = try TestesDoIdioma.literaisDeTela()
        XCTAssertEqual(achados, [], "texto de tela fora de T(...):\n" + achados.joined(separator: "\n"))
    }

    /// A varredura acusa o que deve e deixa o que pode: sem isto, um padrão quebrado passaria calado.
    func testAVarreduraAcusaUmTextoDeExemplo() throws {
        XCTAssertEqual(try TestesDoIdioma.literaisDeTela(na: #"Text("Olá, mundo").font(.title)"#), ["Olá, mundo"])
        XCTAssertEqual(try TestesDoIdioma.literaisDeTela(na: #"Button("Parar") { }.help("Para tudo")"#), ["Parar", "Para tudo"])
        XCTAssertEqual(try TestesDoIdioma.literaisDeTela(na: #"Aviso(texto: "Sem rede", tipo: .ambar)"#), ["Sem rede"])
        XCTAssertEqual(try TestesDoIdioma.literaisDeTela(na: #"Text(T("Olá, mundo"))"#), [])
        XCTAssertEqual(try TestesDoIdioma.literaisDeTela(na: #"Text("\(n) × \(m)")"#), [])
        XCTAssertEqual(try TestesDoIdioma.literaisDeTela(na: #"Text("PIN")"#), [])
        XCTAssertEqual(try TestesDoIdioma.literaisDeTela(na: #"linha("Sair pela rede", legenda) {"#), ["Sair pela rede"])
        XCTAssertEqual(try TestesDoIdioma.literaisDeTela(na: #"Registro.compartilhado.linha("tela: abriu")"#), [])
    }

    /// A frase dos diálogos de permissão (`Empacotar/*.lproj/InfoPlist.strings`): as mesmas chaves nas duas
    /// línguas, e o português igual ao `Info.plist`.
    func testOInfoPlistTemAsDuasLinguas() throws {
        let empacotar = TestesDoIdioma.raizDoPacote.appendingPathComponent("Empacotar")
        let info = try XCTUnwrap(NSDictionary(contentsOf: empacotar.appendingPathComponent("Info.plist")) as? [String: Any])
        let pt = try XCTUnwrap(NSDictionary(contentsOf: empacotar.appendingPathComponent("pt.lproj/InfoPlist.strings")) as? [String: String])
        let en = try XCTUnwrap(NSDictionary(contentsOf: empacotar.appendingPathComponent("en.lproj/InfoPlist.strings")) as? [String: String])
        XCTAssertEqual(Set(pt.keys), Set(en.keys))
        for chave in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSLocalNetworkUsageDescription"] {
            XCTAssertEqual(pt[chave], info[chave] as? String, "\(chave): o pt.lproj diverge do Info.plist")
            XCTAssertNotNil(en[chave], "\(chave) sem inglês")
            XCTAssertNotEqual(en[chave], pt[chave], "\(chave) igual nas duas línguas")
        }
        let linguas = info["CFBundleLocalizations"] as? [String]
        XCTAssertEqual(Set(linguas ?? []), ["pt", "en"])
        XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "pt")
    }

    // MARK: - as ferramentas da varredura

    /// `apps/macos`, a partir deste arquivo.
    static let raizDoPacote = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func lacunas(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:@|\.?\d*(?:ll|l)?[dfu])|%%"#)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
            .sorted()
    }

    /// Os arquivos futuros são os mesmos excluídos de QuallCaptureKit em Package.swift.
    static let fontesFuturas: Set<String> = ["QuallCaptureKit/MonitorVirtual.swift",
                                            "QuallCaptureKit/MonitorVirtualAuxiliar.swift",
                                            "QuallCaptureKit/TabelaDeIndices.swift"]

    /// Mantém os números de linha e lê só os ramos que o produto compila: o símbolo futuro
    /// não é definido na primeira release. Condicionais de plataforma continuam sendo varridos.
    static func linhasDoProduto(_ texto: String) -> [String] {
        var pilha: [(paiAtivo: Bool, futuro: Bool)] = []
        var ativo = true
        return texto.components(separatedBy: "\n").map { linha in
            let limpa = linha.trimmingCharacters(in: .whitespaces)
            if limpa.hasPrefix("#if ") {
                let futuro = limpa == "#if QUALL_TELA_ESTENDIDA_FUTURA"
                pilha.append((ativo, futuro))
                ativo = ativo && !futuro
                return ""
            }
            if limpa == "#else", let topo = pilha.last {
                ativo = topo.paiAtivo
                return ""
            }
            if limpa == "#endif", let topo = pilha.popLast() {
                ativo = topo.paiAtivo
                return ""
            }
            return !ativo || limpa.hasPrefix("//") ? "" : linha
        }
    }

    func testAVarreduraSegueOGateDaReleaseENaoTraducoesFuturas() throws {
        let exemplo = """
        Text(T("Atual"))
        #if QUALL_TELA_ESTENDIDA_FUTURA
        #if os(macOS)
        Text(T("Futuro"))
        #endif
        #else
        Text(T("Monitores existentes"))
        #endif
        """
        let linhas = TestesDoIdioma.linhasDoProduto(exemplo)
        XCTAssertEqual(linhas.count, exemplo.components(separatedBy: "\n").count)
        XCTAssertFalse(linhas.joined().contains("Futuro"))
        XCTAssertTrue(linhas.joined().contains("Monitores existentes"))
        let nomes = Set(try TestesDoIdioma.fontes().map(\.nome))
        XCTAssertTrue(nomes.isDisjoint(with: TestesDoIdioma.fontesFuturas))
    }

    /// Os `.swift` dos alvos de produto, sem comentários, arquivos excluídos ou ramos futuros.
    static func fontes() throws -> [(nome: String, linhas: [String])] {
        let raiz = raizDoPacote.appendingPathComponent("Sources")
        let alvos = ["QuallApp", "QuallBarraDeMenusKit", "QuallCaptureKit", "QuallNetKit", "QuallReceptorKit",
                     "QuallTeleprompterKit"]
        var r: [(String, [String])] = []
        for alvo in alvos {
            let pasta = raiz.appendingPathComponent(alvo)
            let itens = try FileManager.default.contentsOfDirectory(atPath: pasta.path).filter { $0.hasSuffix(".swift") }.sorted()
            for item in itens {
                guard !fontesFuturas.contains("\(alvo)/\(item)") else { continue }
                let texto = try String(contentsOf: pasta.appendingPathComponent(item), encoding: .utf8)
                let linhas = linhasDoProduto(texto)
                r.append(("\(alvo)/\(item)", linhas))
            }
        }
        return r
    }

    static func desescapar(_ s: String) -> String {
        var r = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let d = it.next() else { r.append(c); continue }
            switch d {
            case "n": r.append("\n")
            case "t": r.append("\t")
            default: r.append(d)
            }
        }
        return r
    }

    /// As chaves de `T("...")` (e de `eh("...")`, a pílula das duas línguas), com as cadeias `"a" + "b"`
    /// juntadas, mais o `rawValue` dos `enum` que se traduzem por `T(rawValue)`.
    static func chavesDoCodigo() throws -> Set<String> {
        let literal = #""(?:[^"\\\n]|\\.)*""#
        let chamada = try NSRegularExpression(pattern: #"(?<![\w.])(?:T|eh)\(\s*((?:"# + literal + #"\s*\+?\s*)+)"#)
        let umLiteral = try NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        let enumComT = try NSRegularExpression(pattern: #"enum \w+: String[^{]*\{(.*?)\n\}"#, options: .dotMatchesLineSeparators)
        let caso = try NSRegularExpression(pattern: #"case \w+ = "([^"]*)""#)
        var chaves = Set<String>()
        for (_, linhas) in try fontes() {
            let texto = linhas.joined(separator: "\n")
            let ns = texto as NSString
            for m in chamada.matches(in: texto, range: NSRange(location: 0, length: ns.length)) {
                let cadeia = ns.substring(with: m.range(at: 1))
                let cns = cadeia as NSString
                let partes = umLiteral.matches(in: cadeia, range: NSRange(location: 0, length: cns.length))
                    .map { desescapar(cns.substring(with: $0.range(at: 1))) }
                chaves.insert(partes.joined())
            }
            guard texto.contains("T(rawValue)") else { continue }
            for b in enumComT.matches(in: texto, range: NSRange(location: 0, length: ns.length)) {
                let corpo = ns.substring(with: b.range(at: 1))
                guard corpo.contains("T(rawValue)") else { continue }
                let corpoNS = corpo as NSString
                for c in caso.matches(in: corpo, range: NSRange(location: 0, length: corpoNS.length)) {
                    chaves.insert(corpoNS.substring(with: c.range(at: 1)))
                }
            }
        }
        return chaves
    }

    /// O que não é texto de tela, ou não se traduz, e por isso pode ficar literal: a marca, o PIN, e o
    /// rótulo das tracks (vai pelo protocolo para o outro aparelho).
    static let literaisPermitidos: Set<String> = ["Quall", "Quall Studio", "Quall ", "Quall — ", "Quall Studio — ", "PIN", "PIN  ",
                                                  "Som de \\(nomeDoAparelho)", "Microfone de \\(nomeDoAparelho)"]
    /// Arquivos de bancada e de diário: os retratos (dados de exemplo), a bancada dos ajustes e os
    /// relatos de diário que usam `rotulo`/`detalhe` como nome de campo.
    static let arquivosForaDaVarredura: Set<String> = ["QuallApp/Retratos.swift", "QuallApp/BancadaDosAjustesDaCamera.swift",
                                                       "QuallApp/MicrofoneParaOpus.swift", "QuallCaptureKit/VigiaDeMonitor.swift",
                                                       "QuallCaptureKit/TransmissaoAoVivo.swift"]

    static func literaisDeTela() throws -> [String] {
        var achados: [String] = []
        for (nome, linhas) in try fontes() where !arquivosForaDaVarredura.contains(nome) {
            for (i, linha) in linhas.enumerated() {
                achados += try literaisDeTela(na: linha).map { "\(nome):\(i + 1): \"\($0)\"" }
            }
        }
        return achados
    }

    static func literaisDeTela(na linha: String) throws -> [String] {
        let chamadas = "Text|Button|Label|Toggle|Picker|Menu|TextField|RotuloDeSecao|RotuloDeBotao|ProgressView|Window"
            + "|confirmationDialog|alert|navigationTitle|help|accessibilityLabel|accessibilityHint|setAccessibilityLabel"
        let campos = "rotulo|titulo|palavra|acao|texto|legenda|detalhe|title|messageText|informativeText|toolTip|mensagem"
            + "|conselho|recado|accessibilityDescription"
        // `linha(` só a de vista (a dos Ajustes, a dos ajustes da câmera); a do `Registro` vem com ponto.
        let re = try NSRegularExpression(pattern: #"(?:\b(?:"# + chamadas + #")\(|(?<![.\w])linha\(|\b(?:"# + campos
                                         + #")(?::| =) )"((?:[^"\\\n]|\\.)*)""#)
        let interpolacao = try NSRegularExpression(pattern: #"\\\([^)]*\)"#)
        var achados: [String] = []
        let ns = linha as NSString
        for m in re.matches(in: linha, range: NSRange(location: 0, length: ns.length)) {
            let conteudo = ns.substring(with: m.range(at: 1))
            if literaisPermitidos.contains(conteudo) { continue }
            let semInterpolacao = interpolacao.stringByReplacingMatches(
                in: conteudo, range: NSRange(location: 0, length: (conteudo as NSString).length), withTemplate: "")
            guard semInterpolacao.rangeOfCharacter(from: .letters) != nil else { continue }
            achados.append(conteudo)
        }
        return achados
    }
}
