import AppKit
import QuallIdiomaKit
import QuallTeleprompterKit
import SwiftUI

/// **As folhas do controle**: a caixa da pergunta do texto e os "Roteiros guardados"
/// (`docs/contrato-teleprompter.md` §11.7, e o pedido de 14/09 à tarde). Uma folha por vez, pela
/// regra de `Teleprompter.folhaDoControle`. Os textos são os de `TextosDaPergunta`, literais e iguais
/// nas quatro telas.
struct FolhasDoControle: ViewModifier {
    @ObservedObject var tp: Teleprompter

    func body(content: Content) -> some View {
        content.background(
            Color.clear.sheet(item: Binding(get: { tp.folhaDoControle }, set: { if $0 == nil { tp.fecharFolha() } })) { folha in
                switch folha {
                case .pergunta: CaixaDaPerguntaNaTela().environmentObject(tp)
                case .roteiros: RoteirosGuardadosNaTela().environmentObject(tp)
                }
            }
        )
    }
}

/// **A caixa da pergunta** — "usar o do prompter ou mandar o meu". Uma folha, e não uma faixa no
/// painel: é uma decisão que segura o roteiro, e a folha não mexe no tamanho dos botões do modo
/// segurar (*derivado*). Nenhum dos dois botões é o padrão do Return: escolher é gesto de propósito.
struct CaixaDaPerguntaNaTela: View {
    @EnvironmentObject private var tp: Teleprompter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch tp.caixaDaPergunta {
            case .nenhuma:
                EmptyView()
            case .conferindo:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(TextosDaPergunta.conferindo).font(.title3.weight(.medium))
                }
                saida
            case .perguntando(let nome, let doPrompter, let meu, let ligadas, let aviso):
                Text(TextosDaPergunta.titulo(prompter: nome))
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 14) {
                    bloco(TextosDaPergunta.noPrompter, doPrompter)
                    bloco(TextosDaPergunta.nesteAparelho, meu)
                }
                if let aviso {
                    Text(aviso)
                        .font(.callout.weight(.semibold))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Estilo.aguardando.opacity(0.22))
                        .cornerRadius(8)
                }
                // **O resumo que esta caixa mostra** é o que a escolha leva: capturado aqui, no desenho,
                // e nunca relido na hora do clique (§11.4).
                let visto = doPrompter.resumo
                HStack(spacing: 12) {
                    // A saída também com o aviso de roteiro mudado: um prompter que anuncia um texto
                    // que nunca chega devolveria BUSY a todo toque (revisão de 14/09).
                    if !ligadas || aviso != nil { saida }
                    Spacer()
                    Button(TextosDaPergunta.usarODoPrompter) {
                        tp.escolherTexto(manterOMeu: false, resumoVisto: visto, porque: "botão")
                    }
                    .disabled(!ligadas)
                    Button(TextosDaPergunta.mandarOMeu) {
                        tp.escolherTexto(manterOMeu: true, resumoVisto: visto, porque: "botão")
                    }
                    .disabled(!ligadas)
                }
                .controlSize(.large)
                Text(TextosDaPergunta.oQueSairFicaGuardado)
                    .font(.caption)
                    .foregroundColor(Estilo.texto2)
            }
        }
        .padding(22)
        .frame(width: 680)
        // **O Esc não fecha a caixa** (revisão de 14/09): fechada assim, a folha não voltaria — o item
        // continua `.pergunta` — e o roteiro ficaria retido sem ninguém ver a pergunta.
        .interactiveDismissDisabled()
    }

    /// Com as escolhas desligadas (o prompter saiu, ou conferindo sem fim), a folha precisa de uma
    /// saída: ela prende a janela (*derivado*).
    private var saida: some View {
        Button(T("Desconectar")) { tp.desconectar() }
            .help(T("Volta ao formulário; a pergunta volta na próxima conexão com este prompter."))
    }

    private func bloco(_ titulo: String, _ lado: LadoDaPergunta) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(titulo).font(.headline)
                Spacer()
                Text(tp.palavras[lado.resumo].map(TextosDaPergunta.palavras) ?? "…")
                    .font(.callout.monospacedDigit())
                    .foregroundColor(Estilo.texto2)
            }
            ScrollView {
                Text(lado.previa)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 150)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Estilo.superficie)
        .cornerRadius(10)
    }
}

/// **"Roteiros guardados"**: as cópias do roteiro (`"copias_do_texto"`, a mais nova primeiro), com
/// "Ver", "Usar este" e "Apagar"; os dois últimos confirmam num alerta.
struct RoteirosGuardadosNaTela: View {
    @EnvironmentObject private var tp: Teleprompter

    /// A data no formato do idioma da vez (o seletor troca na hora).
    private static var hora: DateFormatter { Idioma.atual == .pt ? horaPT : horaEN }
    private static let horaPT = formatador("pt_BR")
    private static let horaEN = formatador("en_US")

    private static func formatador(_ local: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: local)
        f.setLocalizedDateFormatFromTemplate("ddMMyyyyHHmm")
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(TextosDaPergunta.roteirosGuardados).font(.title2.weight(.semibold))
                Spacer()
                Button(T("Fechar")) { tp.fecharRoteiros() }
                    .keyboardShortcut(.cancelAction)
            }
            if let vista = tp.copiaVista {
                Text(vista.deOnde).font(.headline)
                // Um `NSTextView` só leitura, e não um `Text` do SwiftUI: com 128 KB, o `Text` monta o
                // texto inteiro de uma vez, na main (revisão de 14/09).
                TextoSoLeitura(texto: vista.texto)
                    .frame(minHeight: 320)
                    .border(Estilo.bordaDeCampo)
                HStack {
                    Button(T("Voltar")) { tp.fecharCopiaVista() }
                    Spacer()
                    Button(TextosDaPergunta.usarEste) { tp.pedirUsarCopia(vista.resumo) }
                }
            } else if tp.estado.copiasDoTexto.isEmpty {
                Text(TextosDaPergunta.nenhumRoteiroGuardado)
                    .font(.callout)
                    .foregroundColor(Estilo.texto2)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(tp.estado.copiasDoTexto) { c in item(c) }
                    }
                }
                .frame(minHeight: 320)
            }
        }
        .padding(20)
        .frame(width: 640)
        .alert(tituloDoAlerta, isPresented: Binding(get: { tp.confirmacaoDaCopia != nil },
                                                   set: { if !$0 { tp.cancelarCopia() } }),
               presenting: tp.confirmacaoDaCopia) { c in
            switch c {
            case .usar:
                Button(TextosDaPergunta.usar) { tp.confirmarCopia() }
            case .apagar:
                Button(TextosDaPergunta.apagar, role: .destructive) { tp.confirmarCopia() }
            }
            Button(TextosDaPergunta.cancelar, role: .cancel) { tp.cancelarCopia() }
        } message: { c in
            if case .usar = c { Text(TextosDaPergunta.usarEsteRoteiroMensagem) }
        }
    }

    private var tituloDoAlerta: String {
        switch tp.confirmacaoDaCopia {
        case .usar?: return TextosDaPergunta.usarEsteRoteiroTitulo
        case .apagar?: return TextosDaPergunta.apagarEsteRoteiro
        case nil: return ""
        }
    }

    private func item(_ c: CopiaDoTexto) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.deOnde).font(.headline)
            HStack(spacing: 8) {
                Text(RoteirosGuardadosNaTela.hora.string(from: Date(timeIntervalSince1970: Double(c.quandoMs) / 1000)))
                Text("·")
                Text(tp.palavras[c.resumo].map(TextosDaPergunta.palavras) ?? "…")
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(Estilo.texto2)
            Text(c.previa)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button(TextosDaPergunta.ver) { tp.verCopia(c.resumo) }
                Button(TextosDaPergunta.usarEste) { tp.pedirUsarCopia(c.resumo) }
                Spacer()
                Button(TextosDaPergunta.apagar) { tp.pedirApagarCopia(c.resumo) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Estilo.superficie)
        .cornerRadius(10)
    }
}

/// O texto inteiro de uma cópia, **só leitura** e selecionável, num `NSTextView` — o motor de texto
/// do AppKit diagrama por partes e não trava a main com um roteiro de 128 KB.
struct TextoSoLeitura: NSViewRepresentable {
    let texto: String

    func makeNSView(context: Context) -> NSScrollView {
        let rolagem = NSTextView.scrollableTextView()
        if let v = rolagem.documentView as? NSTextView {
            v.isEditable = false
            v.isSelectable = true
            v.isRichText = false
            v.font = NSFont.systemFont(ofSize: 14)
            v.textContainerInset = NSSize(width: 6, height: 6)
            v.string = texto
        }
        return rolagem
    }

    func updateNSView(_ rolagem: NSScrollView, context: Context) {
        guard let v = rolagem.documentView as? NSTextView, v.string != texto else { return }
        v.string = texto
    }
}
