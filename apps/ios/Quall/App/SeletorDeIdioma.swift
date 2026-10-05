import SwiftUI

/// O idioma em vigor, observável: a `Raiz` o observa e recria as telas quando o seletor troca
/// (`Idioma.mudou`). O texto em si vem de `tr(...)` (`Comum/Idioma.swift`).
final class IdiomaDaTela: ObservableObject {
    @Published private(set) var atual: Idioma = Idioma.atual
    /// Ligado na troca: o seletor recriado pega o foco do VoiceOver (o botão tocado foi destruído
    /// junto com a tela, e sem isto o foco cairia no começo da tela).
    var focarNoSeletor = false
    private var observador: NSObjectProtocol?

    init() {
        Idioma.publicarEmUso()
        observador = NotificationCenter.default.addObserver(forName: Idioma.mudou, object: nil,
                                                            queue: .main) { [weak self] _ in
            self?.focarNoSeletor = true
            self?.atual = Idioma.atual
        }
    }

    deinit {
        if let observador { NotificationCenter.default.removeObserver(observador) }
    }
}

/// **"PT | EN"** no canto superior direito da tela inicial (`docs/traducao.md`): os dois à vista, o
/// atual em destaque; um toque em qualquer ponto troca para o outro. Mesma altura do botão redondo
/// ao lado (40 de desenho, 44 de toque).
struct SeletorDeIdioma: View {
    @EnvironmentObject private var idioma: IdiomaDaTela
    @AccessibilityFocusState private var focado: Bool

    var body: some View {
        Button {
            let novo: Idioma = idioma.atual == .pt ? .en : .pt
            Diagnostico.nota("APP idioma=\(novo.rawValue) (seletor)")
            Idioma.escolher(novo)
        } label: {
            HStack(spacing: 6) {
                sigla("PT", ativo: idioma.atual == .pt)
                Text(verbatim: "|")
                    .font(Estilo.corpo(.footnote))
                    .foregroundColor(Estilo.texto3)
                sigla("EN", ativo: idioma.atual == .en)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Capsule().fill(Estilo.superficie))
            .overlay(Capsule().stroke(Estilo.contorno, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.toque)
        // O nome diz o idioma atual, no próprio idioma: "Idioma: Português" / "Language: English".
        .accessibilityLabel(idioma.atual == .pt ? "Idioma: Português" : "Language: English") // sem-traducao
        .accessibilityHint(tr("Toque para trocar o idioma"))
        .accessibilityFocused($focado)
        .onAppear {
            guard idioma.focarNoSeletor else { return }
            idioma.focarNoSeletor = false
            // Depois de a tela nova assentar; antes disso o VoiceOver ainda não a conhece.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focado = true }
        }
    }

    private func sigla(_ texto: String, ativo: Bool) -> some View {
        Text(verbatim: texto)
            .font(Estilo.corpo(.footnote, ativo ? .bold : .regular))
            .foregroundColor(ativo ? Estilo.texto : Estilo.texto3)
    }
}
