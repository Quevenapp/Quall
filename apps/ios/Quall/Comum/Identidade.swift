import Foundation

/// Quem é este aparelho, para o outro lado da rede.
///
/// Duas coisas diferentes, e o núcleo separa as duas de propósito
/// (`QuallDeviceDesc`): o **`device_id`** é o que o pareamento vincula, e o **nome** é o que a
/// pessoa lê na lista. Trocar o nome não pode desfazer o pareamento, senão a promessa do fluxo —
/// "PIN uma vez por par de aparelhos, nunca por sessão" — quebraria na primeira vez que alguém
/// renomeasse o iPhone.
///
/// Sem UIKit aqui, e não é preferência de estilo: este arquivo é compilado **dentro da Broadcast
/// Upload Extension**, onde UIKit não entra (o caminho errado de reescalonamento custou 30 MB
/// contra 0,1 MB numa medição deste projeto, e a regra virou "nada de UIKit, CoreImage, Metal ou
/// GPU na appex"). O nome padrão, que vem de `UIDevice.current.name`, é escrito pelo **app** na
/// primeira abertura; a appex só lê o que já está gravado.
public enum Identidade {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: Compartilhado.grupo) }

    private static let chaveId = "device_id"
    private static let chaveNome = "nome_na_rede"

    /// Identificador estável, sorteado na primeira execução e persistido.
    ///
    /// `identifierForVendor` seria mais curto, mas ele muda quando o usuário desinstala o app —
    /// e nesse caso todos os pareamentos morreriam sem que nada dissesse por quê. Um UUID nosso,
    /// gravado no App Group, sobrevive a atualização e é o que o núcleo pede.
    public static var deviceId: String {
        if let guardado = defaults?.string(forKey: chaveId), !guardado.isEmpty { return guardado }
        let novo = "ios-" + UUID().uuidString.prefix(8).lowercased()
        defaults?.set(novo, forKey: chaveId)
        return novo
    }

    /// Nome com que este aparelho aparece na rede. A tela inicial mostra e deixa editar — é a
    /// primeira coisa que o fluxo pede que a pessoa veja.
    public static var nome: String {
        get {
            let guardado = defaults?.string(forKey: chaveNome) ?? ""
            return guardado.isEmpty ? "iPhone" : guardado
        }
        set {
            let limpo = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults?.set(limpo.isEmpty ? "iPhone" : limpo, forKey: chaveNome)
        }
    }

    /// Escreve o padrão só se ainda não houver nome escolhido. Chamado pelo app, que é quem tem
    /// UIKit à mão para perguntar ao sistema como o aparelho se chama.
    public static func semearNome(_ sugestao: String) {
        let atual = defaults?.string(forKey: chaveNome) ?? ""
        guard atual.isEmpty else { return }
        nome = sugestao
    }
}
