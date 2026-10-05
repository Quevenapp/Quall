import SwiftUI
import UIKit

/// Leitor local dos avisos consolidados que o Xcode copia da raiz do repositório.
struct FolhaDasLicencas: View {
    let fechar: () -> Void
    @State private var texto = ""
    @State private var erro: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("Licenças de terceiros"))
                    .font(Estilo.corpo(.body, .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(tr("Pronto"), action: fechar)
                    .font(Estilo.corpo(.body, .semibold))
                    .foregroundColor(Estilo.acentoClaro)
            }
            .padding(16)
            if let erro {
                ScrollView {
                    Text(verbatim: erro)
                        .foregroundColor(Estilo.perigoTexto)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                TextoDosAvisos(texto: texto)
            }
        }
        .foregroundColor(Estilo.texto)
        .background(Estilo.fundo.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { carregar() }
    }

    private func carregar() {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") else {
            erro = tr("O arquivo de avisos não foi encontrado no app.")
            return
        }
        do {
            texto = try String(contentsOf: url, encoding: .utf8)
            if texto.isEmpty { erro = tr("O arquivo de avisos está vazio.") }
        } catch {
            erro = tr("Não foi possível ler os avisos de terceiros: %@", error.localizedDescription)
        }
    }
}

/// UITextView mantém seleção e rolagem de um arquivo extenso sem criar uma vista por licença.
private struct TextoDosAvisos: UIViewRepresentable {
    let texto: String

    func makeUIView(context: Context) -> UITextView {
        let vista = UITextView()
        vista.isEditable = false
        vista.isSelectable = true
        vista.backgroundColor = .clear
        vista.textColor = .label
        vista.font = .preferredFont(forTextStyle: .footnote)
        vista.adjustsFontForContentSizeCategory = true
        vista.textContainerInset = UIEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        return vista
    }

    func updateUIView(_ vista: UITextView, context: Context) {
        if vista.text != texto { vista.text = texto }
    }
}
