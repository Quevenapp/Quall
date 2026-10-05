import Foundation

/// O `Diagnostico` do app, **de mesa**: só o que o `CodificadorH264.swift` chama (`nota` e `falha`),
/// escrevendo no terminal.
///
/// O de verdade (`Comum/Diagnostico.swift`) não compila no MacBook — `os_proc_available_memory()` é
/// só do iOS —, e o `CodificadorH264.swift` passou a chamá-lo no commit 4f00725 sem este roteiro
/// acompanhar: o arnês parou de compilar em silêncio. Este arquivo **não entra em alvo nenhum do
/// app**, pela mesma regra de `main.swift`.
enum Diagnostico {
    static func nota(_ texto: @autoclosure () -> String) {}
    static func falha(_ texto: @autoclosure () -> String) { print("  (diagnóstico) \(texto())") }
}
