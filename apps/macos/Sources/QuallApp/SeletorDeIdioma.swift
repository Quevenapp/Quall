import QuallIdiomaKit
import SwiftUI

/// **O seletor PT | EN** do painel Espelhar, a tela inicial (`docs/traducao.md`, "macOS"): as duas
/// siglas à vista, a da vez em destaque, e um clique troca para a outra. A troca vale na hora — as
/// janelas se redesenham (`NoIdiomaDaVez`) — e fica guardada: vence o idioma do sistema dali em diante.
struct SeletorDeIdioma: View {
    @ObservedObject private var troca = TrocaDeIdioma.compartilhada

    var body: some View {
        Button {
            Registro.compartilhado.linha("tela: idioma \(troca.atual.rawValue) → \(troca.atual == .pt ? "en" : "pt")")
            troca.alternar()
        } label: {
            HStack(spacing: 0) {
                sigla(.pt)
                Text("|").foregroundColor(Estilo.texto3).padding(.horizontal, 5)
                sigla(.en)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Estilo.superficie))
            .overlay(Capsule().strokeBorder(Estilo.contorno, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(EstiloApertado())
        // O contrato (item 1): "Idioma: Português" / "Language: English" — o nome no idioma da vez.
        .accessibilityLabel(troca.atual == .pt ? "Idioma: Português" : "Language: English")
        .accessibilityHint(T("Troca o idioma do Quall Studio"))
        .help(T("Troca o idioma do Quall Studio"))
    }

    private func sigla(_ i: Idioma) -> some View {
        Text(i.sigla).foregroundColor(i == troca.atual ? Estilo.texto : Estilo.texto3)
    }
}

/// **Redesenha a janela inteira quando o idioma troca.** O texto é montado no corpo de cada vista
/// (`T(...)`), e não guardado; trocar a identidade do conteúdo faz o SwiftUI montar tudo de novo no
/// idioma novo. O estado que importa mora nos modelos (`Emissor`, `Receptor`, `Teleprompter`), fora
/// daqui; o que se perde é o miúdo de tela (uma aba escolhida, um painel de números aberto).
///
/// Só envolve o **conteúdo**: os modificadores de quem o usa (o `onAppear` da raiz, o `onDisappear`
/// da janela do controle, que fecha a sessão) ficam por fora e não disparam na troca.
struct NoIdiomaDaVez<Conteudo: View>: View {
    @ObservedObject private var troca = TrocaDeIdioma.compartilhada
    let conteudo: Conteudo

    init(@ViewBuilder conteudo: () -> Conteudo) {
        self.conteudo = conteudo()
    }

    var body: some View {
        conteudo.id(troca.atual)
    }
}
