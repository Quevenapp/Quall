import Foundation

/// O idioma da interface: **português ou inglês**, escolhido no seletor "PT | EN" da tela inicial
/// (`docs/traducao.md`, seção iOS).
///
/// # O português é a chave
///
/// O texto-fonte continua em português, no próprio código: `tr("Espelhar")`. Em PT a função devolve
/// a chave como está, sem tabela nenhuma; em EN ela procura a chave nas tabelas `en.lproj/*.strings`
/// de cada pasta (`App.strings`, `Camera.strings`, `Receber.strings`, `Teleprompter.strings`,
/// `ComCamera.strings`, `Comum.strings`,
/// `Extensao.strings`) e, se não achar, devolve o português — um texto esquecido aparece em PT, nunca
/// em branco. `Testes/confere-traducao.py` acusa a chave que falta.
///
/// # Por que não `Localizable.strings` com `NSLocalizedString`
///
/// Porque o `Bundle` escolhe a localização pelo idioma **do sistema**, e o pedido é que o botão vença
/// o sistema, na hora, sem reabrir o app. E porque o SwiftUI consulta `Localizable.strings` sozinho
/// em todo `Text("literal")`: com essa tabela no pacote, um literal esquecido seria traduzido pelo
/// idioma do sistema, contra o botão. Sem ela, o literal esquecido fica em PT e a varredura o acusa.
///
/// # Quem escolhe
///
/// 1. `--idioma pt|en` nos argumentos (bancada e retratos);
/// 2. a escolha do botão, guardada no App Group;
/// 3. o idioma do sistema (o do app, se a pessoa escolheu um em Ajustes › Quall › Idioma): qualquer
///    `pt-*` → PT; qualquer outro → EN.
///
/// **A appex não decide sozinha**: o app grava o idioma **em uso** no App Group ao abrir e a cada
/// troca (`publicarEmUso`), e a appex lê esse (`reler`, no começo de cada transmissão). Sem isso, com
/// o idioma por app dos Ajustes do sistema, ela podia ler outro `Locale.preferredLanguages` que não o
/// do app, e escrever em outra língua o erro e o conselho que o app mostra.
///
/// **Os textos de permissão do sistema** (`InfoPlist.strings`: câmera, microfone, rede local, fotos)
/// não passam por aqui: o iOS os escolhe pelo idioma do sistema (ou o do app em Ajustes › Quall ›
/// Idioma), e o botão não os alcança. Pelo mesmo motivo, quando o texto do app **cita** um nome da
/// interface do sistema ("Iniciar Transmissão", "Ajustes → Quall Studio → Câmera"), esse nome vem de
/// `trSistema`, que segue a língua do pacote e não o botão.
public enum Idioma: String, CaseIterable {
    case pt
    case en

    /// A chave no `UserDefaults` do App Group: a escolha do botão (só existe depois do primeiro toque).
    static let chave = "idioma"
    /// O idioma em uso no app (escolha ou sistema), que a appex segue.
    static let chaveEmUso = "idioma-em-uso"
    /// Postada (na fila principal) quando o botão troca o idioma.
    public static let mudou = Notification.Name("br.com.queven.quall.idioma-mudou")

    private static let trava = NSLock()
    private static var _atual: Idioma?
    /// A tabela EN já montada (chave PT → texto EN); `nil` até a primeira consulta em EN.
    private static var _tabela: [String: String]?
    /// Pastas extras de tabelas (só testes: a árvore de fontes no lugar do pacote).
    private static var _tabelasDeFora: [URL]?

    /// O idioma em vigor. Lido uma vez e guardado; `escolher` e `reler` o trocam.
    public static var atual: Idioma {
        trava.lock(); defer { trava.unlock() }
        if let a = _atual { return a }
        let a = lerEscolha()
        _atual = a
        return a
    }

    /// O idioma do sistema, pela regra do contrato: `pt-*` → PT, o resto → EN.
    public static var doSistema: Idioma {
        let primeiro = Locale.preferredLanguages.first?.lowercased() ?? "pt"
        return primeiro.hasPrefix("pt") ? .pt : .en
    }

    /// O que vale ao abrir: argumento, escolha guardada, sistema.
    private static func lerEscolha() -> Idioma {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--idioma"), i + 1 < args.count,
           let pedido = Idioma(rawValue: args[i + 1].lowercased()) {
            return pedido
        }
        let grupo = UserDefaults(suiteName: Compartilhado.grupo)
        // A appex segue o app: o idioma em uso que ele publicou, e só depois as outras regras.
        if Bundle.main.bundlePath.hasSuffix(".appex"),
           let emUso = grupo?.string(forKey: chaveEmUso), let idioma = Idioma(rawValue: emUso) {
            return idioma
        }
        if let guardado = grupo?.string(forKey: chave), let escolhido = Idioma(rawValue: guardado) {
            return escolhido
        }
        return doSistema
    }

    /// O app diz à appex qual idioma está em uso (ao abrir e a cada troca).
    public static func publicarEmUso() {
        UserDefaults(suiteName: Compartilhado.grupo)?.set(atual.rawValue, forKey: chaveEmUso)
    }

    /// A língua que o **sistema** escolheu para este pacote (a das permissões e do nome da appex):
    /// `pt-BR.lproj` → PT; `en.lproj` (ou a reserva, qualquer outro idioma) → EN.
    public static var doPacote: Idioma {
        (Bundle.main.preferredLocalizations.first ?? "en").lowercased().hasPrefix("pt") ? .pt : .en
    }

    /// O toque no seletor: grava no App Group e avisa as telas.
    public static func escolher(_ novo: Idioma) {
        let grupo = UserDefaults(suiteName: Compartilhado.grupo)
        grupo?.set(novo.rawValue, forKey: chave)
        grupo?.set(novo.rawValue, forKey: chaveEmUso)
        trava.lock()
        _atual = novo
        trava.unlock()
        let avisar = { NotificationCenter.default.post(name: mudou, object: nil) }
        if Thread.isMainThread { avisar() } else { DispatchQueue.main.async(execute: avisar) }
    }

    /// Esquece o que estava guardado em memória e lê de novo (a appex, a cada transmissão: o
    /// processo dela pode ter nascido antes de o botão mudar).
    public static func reler() {
        trava.lock()
        _atual = nil
        trava.unlock()
    }

    /// Só para testes: monta a tabela EN a partir destas pastas `en.lproj` (a árvore de fontes),
    /// no lugar das do pacote, e força o idioma.
    static func usarTabelas(de pastas: [URL], idioma: Idioma) {
        trava.lock()
        _tabelasDeFora = pastas
        _tabela = nil
        _atual = idioma
        trava.unlock()
    }

    /// O texto EN da chave, ou `nil` se a tabela não a tem.
    static func emIngles(_ chave: String) -> String? {
        trava.lock(); defer { trava.unlock() }
        if _tabela == nil { _tabela = montarTabela() }
        return _tabela?[chave]
    }

    /// Junta todas as tabelas `en.lproj/*.strings` do pacote, menos a `InfoPlist.strings` (essa é do
    /// sistema). `NSDictionary(contentsOf:)` lê as duas formas (texto e a compilada pelo Xcode).
    private static func montarTabela() -> [String: String] {
        var urls: [URL] = []
        if let pastas = _tabelasDeFora {
            for pasta in pastas {
                let nomes = (try? FileManager.default.contentsOfDirectory(atPath: pasta.path)) ?? []
                urls += nomes.filter { $0.hasSuffix(".strings") }.map { pasta.appendingPathComponent($0) }
            }
        } else {
            urls = Bundle.main.urls(forResourcesWithExtension: "strings", subdirectory: nil,
                                    localization: "en") ?? []
        }
        var tabela: [String: String] = [:]
        for url in urls where url.lastPathComponent != "InfoPlist.strings" {
            guard let lido = NSDictionary(contentsOf: url) as? [String: String] else { continue }
            tabela.merge(lido) { primeiro, _ in primeiro }
        }
        return tabela
    }
}

/// O texto da interface no idioma escolhido. `chave` é o texto em português, exatamente como
/// aparece em PT; com `args`, ela é um modelo de `String(format:)` (`%@`, `%ld`, `%.1f`; em EN,
/// `%1$@` para reordenar).
///
/// Regras (as mesmas de `docs/traducao.md`): a chave é um literal só (ou literais unidos por `+`),
/// sem `\(…)` dentro; nunca guardar o resultado num `static let` (congelaria o idioma); diário e
/// protocolo não passam por aqui.
public func tr(_ chave: String, _ args: CVarArg...) -> String {
    traduzir(chave, para: Idioma.atual, args)
}

/// Um nome da interface **do sistema** citado num texto do app ("Iniciar Transmissão", "Ajustes",
/// "Privacidade e Segurança"): na língua que o sistema usa para este pacote (`Idioma.doPacote`), e não
/// na do botão — é o que a pessoa vai ler na tela do sistema. Mesmas regras de chave do `tr`.
public func trSistema(_ chave: String, _ args: CVarArg...) -> String {
    traduzir(chave, para: Idioma.doPacote, args)
}

private func traduzir(_ chave: String, para idioma: Idioma, _ args: [CVarArg]) -> String {
    let modelo: String
    if idioma == .en, let ingles = Idioma.emIngles(chave) {
        modelo = ingles
    } else {
        modelo = chave
    }
    return args.isEmpty ? modelo : String(format: modelo, arguments: args)
}
