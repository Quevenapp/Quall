// SPDX-License-Identifier: MPL-2.0
/// Política conservadora da espera: WRONG_PIN e PAIRING renovam o PIN.
/// PAIRING não informa estágio nem modo e pode incluir retomada interrompida.
/// A rotação não altera vínculos; sucesso e outros statuses mantêm o PIN.
public enum RenovacaoDoPin {
    public static func exigida(apos status: QuallStatus) -> Bool {
        status == QUALL_STATUS_WRONG_PIN || status == QUALL_STATUS_PAIRING
    }

    public static func valido(_ pin: String) -> Bool {
        let bytes = Array(pin.utf8)
        return bytes.count == 6 && bytes.allSatisfy { (48...57).contains($0) }
    }

    /// O sorteio continua no núcleo. Não repete o PIN anterior, nem um valor de
    /// bancada fixo. Falha de RNG ou repetição persistente encerra a espera.
    public static func novo(diferenteDe anterior: String, sortear: () -> String) -> String? {
        for _ in 0..<8 {
            let candidato = sortear()
            guard valido(candidato) else { return nil }
            if candidato != anterior { return candidato }
        }
        return nil
    }
}
