import Foundation

/// Alias público da descoberta v3. Nome pessoal e identidade persistente são
/// enviados somente depois do pareamento autenticado, pelo núcleo.
enum NomeDaInstancia {
    static func novoToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func tokenValido(_ token: String) -> Bool {
        token.utf8.count == 32 && token.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func montar(token: String) -> String? {
        guard tokenValido(token) else { return nil }
        return "Quall \(token)"
    }

    static func host(token: String) -> String? {
        guard tokenValido(token) else { return nil }
        return "quall-\(token).local."
    }
}
