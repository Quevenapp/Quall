import Foundation

/// A tradução PT/EN (`Comum/Idioma.swift`, `docs/traducao.md`): o PT devolve a própria chave, o EN
/// sai das tabelas `en.lproj/*.strings` da árvore de fontes (o binário de teste não tem pacote), a
/// chave sem tradução cai no PT, e o formato com argumentos funciona nos dois. A paridade das
/// chaves e a varredura de literais são do `confere-traducao.py`, que o `rodar.sh` chama.
extension Testes {
    static func rodarTraducao() {
        print("Idioma — tr() em PT e em EN")
        let raiz = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pastas = ["App", "Receber", "Teleprompter", "Comum", "Extensao"]
            .map { raiz.appendingPathComponent($0).appendingPathComponent("en.lproj") }

        Idioma.usarTabelas(de: pastas, idioma: .pt)
        conferir(tr("Espelhar") == "Espelhar", "PT devolve a chave (o texto-fonte)")
        conferir(tr("Ajustes") == "Ajustes", "PT não consulta tabela nenhuma")

        Idioma.usarTabelas(de: pastas, idioma: .en)
        conferir(tr("Espelhar") == "Mirror", "EN: Espelhar → Mirror (\(tr("Espelhar")))")
        conferir(tr("Exibir") == "Receive", "EN: Exibir → Receive, como Receber nas outras plataformas")
        let semTabela = "frase que não existe em tabela nenhuma" // sem-traducao
        conferir(tr(semTabela) == semTabela, "EN sem tradução cai no PT, nunca em branco")
        conferir(tr("A tela deste %@", "iPhone") == "This iPhone's screen",
                 "EN com argumento: \(tr("A tela deste %@", "iPhone"))")

        Idioma.usarTabelas(de: pastas, idioma: .pt)
        conferir(tr("A tela deste %@", "iPhone") == "A tela deste iPhone", "PT com argumento")
        conferir(Idioma(rawValue: "en") == .en && Idioma(rawValue: "pt") == .pt && Idioma(rawValue: "fr") == nil,
                 "o valor guardado no App Group é pt ou en; o resto é ignorado")
        // Os outros testes comparam textos em PT: o idioma fica em PT daqui em diante.
    }
}

/// O `Compartilhado` de mesa: o de verdade fala com o núcleo (FFI) e não compila no MacBook; o
/// `Idioma` só precisa do nome do App Group (o mesmo padrão do `DiagnosticoDeMesa`).
enum Compartilhado {
    static let grupo = "group.br.com.queven.quall"
}
