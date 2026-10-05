import Foundation

/// **O fecho de uma tela que é dona de câmera e de sessão, sem depender do `onDisappear`.**
///
/// # O defeito (27/09, iPad A16, iPadOS 26.6.2, o ramo `02be8a1`)
///
/// O Pessoa Exemplo fechou a tela "Teleprompter com câmera" no X, o app voltou à tela de escolha do Quall, e
/// **a câmera (60 fps) e o prompter na 7979 seguiram vivos por ~45 min sem tela nenhuma** — o iPad
/// lento, e nenhuma linha `tela com câmera: fechada` no diário. O X faz `papel.voltar()`, a raiz troca
/// de tela, e o fecho morava **só** no `onDisappear` da tela R5: ele não correu. Por que o SwiftUI não
/// o chamou no iPad (o modo de janelas, uma folha aberta por cima) **não está medido**; a regra que
/// sai daqui é não depender dele.
///
/// # A regra
///
/// A tela registra o próprio fecho ao abrir (`registrar`), e **três caminhos** o chamam — o que chegar
/// primeiro fecha, os outros não fazem nada:
///
/// 1. o X da tela, antes de voltar;
/// 2. a raiz, quando o papel deixa de ser o da tela (`Raiz.onChange(of: papel.escolha)`);
/// 3. o `onDisappear`, como antes.
///
/// Uma tela nova registrada depois não é fechada pelo registro velho (`esquecer(vez:)` só apaga o
/// próprio). Só na principal.
final class FechoDaTela {
    static let comCamera = FechoDaTela()

    private var vez = 0
    private var atual: (vez: Int, fechar: (String) -> Void)?

    /// Há um fecho registrado (a tela está aberta, pelo que ela mesma disse).
    var aberta: Bool { atual != nil }

    /// Registra o fecho da tela que abriu agora (e substitui um anterior que tenha ficado). Devolve a
    /// vez, para a própria tela esquecer só o dela.
    @discardableResult
    func registrar(_ fechar: @escaping (String) -> Void) -> Int {
        // Uma tela anterior ainda registrada é fechada antes: nenhuma fica só com o `onDisappear`.
        if let a = atual {
            atual = nil
            a.fechar("substituída por outra tela")
        }
        vez += 1
        atual = (vez, fechar)
        return vez
    }

    /// Fecha a tela registrada, uma vez. Devolve se havia o que fechar.
    @discardableResult
    func fechar(motivo: String) -> Bool {
        guard let a = atual else { return false }
        atual = nil
        a.fechar(motivo)
        return true
    }

    /// A tela fechou por dentro: tira o registro, se ainda for o dela.
    func esquecer(vez v: Int) {
        if atual?.vez == v { atual = nil }
    }
}
