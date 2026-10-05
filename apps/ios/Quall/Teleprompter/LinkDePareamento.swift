import Foundation

/// O que a pessoa digitou ou colou, virado em **endereço e PIN** para o controle.
///
/// # Por que existe
///
/// O iPhone não lista aparelhos (o entitlement de multicast segue pendente na Apple), então o
/// controle entra por endereço digitado. O `endereco_manual` do núcleo exige `host:porta` e põe a
/// porta do espelhamento quando falta; quem completa com a porta do teleprompter é esta função.
///
/// # O link `quall://`
///
/// Até 24/09/2026 as telas mostravam um QR com `quall://<pin>@<host>:<porta>` e o controle o lia
/// pela câmera. O QR saiu (decisão do Pessoa Exemplo), e nenhuma tela gera mais o link. A leitura dele
/// **fica**: é barata, está testada, e um link colado de uma versão antiga, ou passado pela bancada
/// (`--controle`), continua servindo. O `endereco_manual` do núcleo **não** entende `quall://`
/// (achado 11 do contrato), então quem lê o link é a casca, e entrega ao núcleo só `host:porta`.
///
/// # A porta que falta
///
/// Sem porta, vale a **do teleprompter deste app** (`portaPadrao`, 7979), e não a 7877 que o
/// `endereco_manual` do núcleo acrescentaria: a 7877 é a do espelhamento, e um prompter iOS que a
/// usasse brigaria pela porta com a transmissão da tela do mesmo aparelho (a appex vive fora do
/// app). Quem digita o que a tela do prompter mostra digita a porta junto; isto é só para quem não
/// digitou.
///
/// Função pura, sem sistema nenhum: testada no MacBook por `Testes/rodar.sh`.
enum LinkDePareamento {
    /// A porta em que o prompter deste app hospeda quando ninguém escolhe outra.
    static let portaPadrao: UInt16 = 7979

    struct Alvo: Equatable {
        /// `host:porta`, pronto para `quall_connect_with_role`.
        let endereco: String
        /// Seis dígitos, quando o link trouxe. `nil` quando a pessoa só digitou o endereço.
        let pin: String?
    }

    /// `nil` quando não há endereço que se aproveite, ou quando o link traz um PIN que não é de
    /// seis dígitos — um link quebrado não pode virar tentativa de PIN errado no prompter, que
    /// trocaria o PIN dele.
    static func ler(_ entrada: String) -> Alvo? {
        var resto = entrada.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resto.isEmpty else { return nil }
        var pin: String?

        if resto.lowercased().hasPrefix("quall://") {
            resto = String(resto.dropFirst("quall://".count))
            // Caminho ou consulta de um leitor genérico que acrescente `/` ou `?`: fora.
            if let corte = resto.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                resto = String(resto[..<corte])
            }
            guard let arroba = resto.firstIndex(of: "@") else { return nil }
            let digitos = String(resto[..<arroba])
            guard digitos.count == 6, digitos.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            pin = digitos
            resto = String(resto[resto.index(after: arroba)...])
        }

        guard let endereco = comPorta(resto) else { return nil }
        return Alvo(endereco: endereco, pin: pin)
    }

    /// `host:porta`, acrescentando a do teleprompter quando falta.
    static func comPorta(_ host: String) -> String? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !h.contains(" ") else { return nil }
        // `[v6]:porta` ou `[v6]`.
        if h.hasPrefix("[") {
            guard let fecha = h.firstIndex(of: "]") else { return nil }
            let depois = h[h.index(after: fecha)...]
            if depois.isEmpty { return "\(h):\(portaPadrao)" }
            guard depois.hasPrefix(":"), UInt16(depois.dropFirst()) != nil else { return nil }
            return h
        }
        let doisPontos = h.filter { $0 == ":" }.count
        // IPv6 sem colchetes: não há como separar a porta. Vai inteiro, entre colchetes.
        if doisPontos > 1 { return "[\(h)]:\(portaPadrao)" }
        if doisPontos == 1 {
            let partes = h.split(separator: ":", omittingEmptySubsequences: false)
            guard partes.count == 2, !partes[0].isEmpty, let p = UInt16(partes[1]), p > 0 else {
                return nil
            }
            return h
        }
        return "\(h):\(portaPadrao)"
    }
}
