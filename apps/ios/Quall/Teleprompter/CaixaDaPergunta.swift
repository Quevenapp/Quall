import SwiftUI
import UIKit

// ================================================================================================
// "A pergunta do texto" e "Roteiros guardados", no controle (`docs/contrato-teleprompter.md` §11.7;
// o pedido de 14/09, fim da tarde). A parte pura — o estado, as palavras, o que a caixa mostra e os
// textos literais — está em `PerguntaDoTexto.swift`.
// ================================================================================================

/// **O que liga a caixa ao núcleo.** O botão da caixa e a bancada (`BancadaDaPergunta`) chamam o
/// mesmo ``escolher(manterOMeu:resumoMostrado:porque:)``, com o resumo **que a caixa mostrou**.
final class ControleDaPergunta: ObservableObject {
    /// A última resposta do núcleo que a caixa diz (`BUSY`, `CLOSED`).
    @Published private(set) var resposta: RespostaDaEscolha?
    /// O `"resumo"` de `"do_prompter"` que a caixa está mostrando: o que a escolha da bancada leva.
    @Published private(set) var resumoMostrado: String?
    /// As palavras de cada lado, contadas no texto inteiro (§5 dos ajustes locais).
    @Published private(set) var palavrasDoPrompter: Int?
    @Published private(set) var palavrasMinhas: Int?

    private var resumoContadoDoPrompter = ""
    private var resumoContadoMeu = ""
    private weak var modelo: ModeloDoTeleprompter?

    func ligar(_ m: ModeloDoTeleprompter) {
        modelo = m
        estadoMudou(m.estado)
    }

    func estadoDaCaixa(_ m: ModeloDoTeleprompter) -> EstadoDaCaixa {
        EstadoDaCaixa.de(pergunta: m.estado.perguntaDoTexto, prompterVisto: m.estado.parVistoHaMs != nil,
                         resposta: resposta)
    }

    /// A caixa desenhou esta pergunta: é o resumo que a escolha leva.
    func mostrou(_ p: PerguntaDoTexto) {
        if resumoMostrado != p.doPrompter?.resumo { resumoMostrado = p.doPrompter?.resumo }
    }

    /// A cada estado novo: recontar quando um dos textos mudou, e esquecer a resposta velha quando a
    /// pergunta fecha ou recomeça (a sessão nova começa comparando, §11.4).
    func estadoMudou(_ e: EstadoDoTeleprompter) {
        guard let m = modelo else { return }
        let p = e.perguntaDoTexto
        if p == nil || p?.aberta == false {
            if resposta != nil { resposta = nil }
            if resumoMostrado != nil { resumoMostrado = nil }
        }
        if let d = p?.doPrompter {
            if d.resumo != resumoContadoDoPrompter {
                resumoContadoDoPrompter = d.resumo
                palavrasDoPrompter = m.replica.textoDaPergunta().map(ContaDePalavras.de)
            }
        } else if !resumoContadoDoPrompter.isEmpty {
            resumoContadoDoPrompter = ""
            palavrasDoPrompter = nil
        }
        if let meu = p?.meu {
            if meu.resumo != resumoContadoMeu {
                resumoContadoMeu = meu.resumo
                palavrasMinhas = ContaDePalavras.de(m.replica.texto())
            }
        } else if !resumoContadoMeu.isEmpty {
            resumoContadoMeu = ""
            palavrasMinhas = nil
        }
    }

    /// **A escolha** (§11.4): `resolve_text` com o resumo que a caixa mostrou — nunca um relido na
    /// hora do toque. `OK`: grava o salvo (a cópia do que saiu, §11.5). `BUSY`: "O roteiro do prompter
    /// mudou. Confira de novo.", e a caixa se atualiza com o bit. `CLOSED`: "O prompter saiu…".
    func escolher(manterOMeu: Bool, resumoMostrado: String, porque: String) {
        guard let m = modelo else { return }
        resposta = nil
        let st = m.replica.resolverTexto(manterOMeu: manterOMeu, resumoVisto: resumoMostrado)
        DiarioDoTeleprompter.dizer("pergunta: \(manterOMeu ? TextosDaPergunta.mandarOMeu : TextosDaPergunta.usarODoPrompter)"
            + " (\(porque); resumo mostrado \(resumoMostrado)) → \(SessaoDoTeleprompter.nome(st))")
        switch st {
        case QUALL_STATUS_OK: m.replica.salvar(motivo: "escolha da pergunta do texto")
        case QUALL_STATUS_BUSY: resposta = .roteiroMudou
        case QUALL_STATUS_CLOSED: resposta = .prompterSaiu
        default: break
        }
        m.recarregar()
        DiarioDoTeleprompter.dizer("pergunta: depois da escolha, texto daqui \(m.texto.utf8.count) bytes "
            + "resumo \(ResumoDoTexto.de(m.texto)); " + ModeloDoTeleprompter.descrever(m.estado.perguntaDoTexto))
    }
}

/// **A caixa da pergunta**, uma só, por cima da tela do controle.
struct CaixaDaPerguntaView: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    @ObservedObject var controle: ControleDaPergunta

    var body: some View {
        let estado = controle.estadoDaCaixa(modelo)
        switch estado {
        case .escondida:
            EmptyView()
        case .conferindo:
            fundo(bloqueia: false) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(TextosDaPergunta.conferindo).font(.headline)
                }
                .padding(20)
            }
        case let .pergunta(p, botoes, aviso):
            fundo(bloqueia: botoes) { pergunta(p, botoes: botoes, aviso: aviso) }
                .onAppear { controle.mostrou(p) }
                .onChange(of: p) { controle.mostrou($0) }
        }
    }

    /// Com os botões ligados, a caixa pede a escolha e segura a tela. **Sem botões** (conferindo, ou o
    /// prompter saiu) ela só informa: fica no alto e deixa o toque passar — a pessoa não pode ficar
    /// presa numa caixa que nada fecha (o "Desconectar" e o "Voltar" continuam ao alcance).
    @ViewBuilder
    private func fundo<C: View>(bloqueia: Bool, @ViewBuilder _ conteudo: () -> C) -> some View {
        ZStack(alignment: bloqueia ? .center : .top) {
            Color.black.opacity(bloqueia ? 0.4 : 0.12).ignoresSafeArea()
            conteudo()
                .background(Estilo.superficie)
                .cornerRadius(16)
                .shadow(radius: 12)
                .padding(18)
                .frame(maxWidth: 560)
        }
        .allowsHitTesting(bloqueia)
    }

    private func pergunta(_ p: PerguntaDoTexto, botoes: Bool, aviso: String?) -> some View {
        // A escolha leva o resumo **deste** desenho.
        let resumo = p.doPrompter?.resumo ?? ""
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(TextosDaPergunta.titulo(p.prompterNome))
                    .font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if let aviso {
                    Text(aviso).font(.callout.weight(.semibold)).foregroundColor(Estilo.aguardandoTexto)
                        .fixedSize(horizontal: false, vertical: true)
                }
                bloco(TextosDaPergunta.noPrompter, previa: p.doPrompter?.previa ?? "", palavras: controle.palavrasDoPrompter)
                bloco(TextosDaPergunta.nesteAparelho, previa: p.meu?.previa ?? "", palavras: controle.palavrasMinhas)
                VStack(spacing: 10) {
                    Button {
                        controle.escolher(manterOMeu: false, resumoMostrado: resumo, porque: "toque")
                    } label: {
                        Text(TextosDaPergunta.usarODoPrompter).font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        controle.escolher(manterOMeu: true, resumoMostrado: resumo, porque: "toque")
                    } label: {
                        Text(TextosDaPergunta.mandarOMeu).font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(!botoes)
                .opacity(botoes ? 1 : 0.45)
                Text(TextosDaPergunta.ficaGuardado).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(maxHeight: 620)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func bloco(_ titulo: String, previa: String, palavras: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(titulo).font(.subheadline.weight(.semibold))
                Spacer()
                Text(palavras.map(TextosDaPergunta.palavras) ?? "…")
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            Text(previa.isEmpty ? " " : previa).font(.footnote).lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(10)
    }
}

// ================================================================================================
// "Roteiros guardados"
// ================================================================================================

/// **A lista das cópias** (§11.5): ver, usar e apagar, com as confirmações. O botão da lista e a
/// bancada chamam os mesmos métodos.
final class ControleDosGuardados: ObservableObject {
    enum Confirmacao: Identifiable, Equatable {
        case usar(CopiaDoTexto)
        case apagar(CopiaDoTexto)
        var id: String {
            switch self {
            case let .usar(c): return "usar-" + c.resumo
            case let .apagar(c): return "apagar-" + c.resumo
            }
        }
    }

    struct Aberto: Identifiable, Equatable {
        let copia: CopiaDoTexto
        let texto: String
        var id: String { copia.resumo }
    }

    @Published var confirmacao: Confirmacao?
    @Published var vendo: Aberto?
    @Published var erro: String?
    /// As palavras de cada cópia, pelo resumo (contadas no texto inteiro, uma vez).
    @Published private(set) var palavras: [String: Int] = [:]
    private weak var modelo: ModeloDoTeleprompter?

    func ligar(_ m: ModeloDoTeleprompter) { modelo = m }

    func contar(_ copias: [CopiaDoTexto]) {
        guard let m = modelo else { return }
        var novo = palavras
        for c in copias where novo[c.resumo] == nil {
            if let t = m.replica.copiaDoTexto(resumo: c.resumo) { novo[c.resumo] = ContaDePalavras.de(t) }
        }
        if novo != palavras { palavras = novo }
    }

    func ver(_ c: CopiaDoTexto, porque: String) {
        guard let m = modelo else { return }
        guard let t = m.replica.copiaDoTexto(resumo: c.resumo) else {
            erro = tr("Esse roteiro não está mais guardado.")
            DiarioDoTeleprompter.dizer("guardados: ver item (\(porque)) — não está mais na lista")
            return
        }
        vendo = Aberto(copia: c, texto: t)
        DiarioDoTeleprompter.dizer("guardados: ver item (\(porque)) — \(t.utf8.count) bytes")
    }

    /// "Usar este", depois da confirmação: `set_text` pelo caminho do editor (grava o salvo). Quem
    /// fecha a confirmação é o próprio alerta (o botão dele), antes de chamar isto.
    func usar(_ c: CopiaDoTexto, porque: String) {
        guard let m = modelo else { return }
        guard let t = m.replica.copiaDoTexto(resumo: c.resumo) else {
            erro = tr("Esse roteiro não está mais guardado.")
            return
        }
        erro = m.confirmarTexto(t)
        DiarioDoTeleprompter.dizer("guardados: usar item (\(porque)) — "
            + (erro == nil ? "o roteiro agora é esse (\(t.utf8.count) bytes, resumo \(ResumoDoTexto.de(t)))" : "recusado"))
    }

    /// "Apagar", depois da confirmação. Grava o salvo: a lista apagada tem de sobreviver a fechar o app.
    func apagar(_ c: CopiaDoTexto, porque: String) {
        guard let m = modelo else { return }
        let st = m.replica.esquecerCopia(resumo: c.resumo)
        m.recarregar()
        m.replica.salvar(motivo: "roteiro guardado apagado")
        DiarioDoTeleprompter.dizer("guardados: apagar item (\(porque)) → \(SessaoDoTeleprompter.nome(st)); "
            + "sobram: " + ModeloDoTeleprompter.descrever(m.estado.copiasDoTexto))
    }
}

/// A folha "Roteiros guardados": a mais nova primeiro (a ordem do núcleo).
struct FolhaDosGuardados: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    @ObservedObject var controle: ControleDosGuardados
    let fechar: () -> Void

    /// No formato do idioma escolhido (calculado na hora: um `static let` congelaria o idioma).
    private static var hora: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: Idioma.atual == .en ? "en_US" : "pt_BR")
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }

    var body: some View {
        let copias = modelo.estado.copiasDoTexto
        NavigationView {
            Group {
                if copias.isEmpty {
                    Text(TextosDaPergunta.nenhumGuardado).font(.body).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(copias) { c in item(c) }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(TextosDaPergunta.roteirosGuardados)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Fechar"), action: fechar) } }
        }
        .navigationViewStyle(.stack)
        .onAppear { controle.contar(copias) }
        .onChange(of: copias) { controle.contar($0) }
        .onChange(of: controle.confirmacao) { if let c = $0 { tituloDaConfirmacao = FolhaDosGuardados.titulo(c) } }
        // O alerta de iOS 15 com `presenting:`: o `Alert(item:)` antigo, trocado de "usar" para
        // "apagar" em seguida, mostrou o texto do primeiro na bancada de 14/09.
        .alert(tituloDaConfirmacao, isPresented: confirmando, presenting: controle.confirmacao) { conf in
            switch conf {
            case let .usar(c):
                Button(TextosDaPergunta.usar) { controle.usar(c, porque: "toque") }
            case let .apagar(c):
                Button(TextosDaPergunta.apagar, role: .destructive) { controle.apagar(c, porque: "toque") }
            }
            Button(TextosDaPergunta.cancelar, role: .cancel) {}
        }
        .sheet(item: $controle.vendo) { aberto in
            NavigationView {
                ScrollView {
                    Text(aberto.texto).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .navigationTitle(aberto.copia.deOnde)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Fechar")) { controle.vendo = nil } } }
            }
            .navigationViewStyle(.stack)
        }
    }

    private var confirmando: Binding<Bool> {
        Binding(get: { controle.confirmacao != nil }, set: { if !$0 { controle.confirmacao = nil } })
    }

    /// O título guarda o último pedido: fechando, o alerta não pisca vazio.
    @State private var tituloDaConfirmacao = ""

    private static func titulo(_ c: ControleDosGuardados.Confirmacao) -> String {
        switch c {
        case .usar: return TextosDaPergunta.confirmaUsar
        case .apagar: return TextosDaPergunta.confirmaApagar
        }
    }

    private func item(_ c: CopiaDoTexto) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.deOnde).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(FolhaDosGuardados.hora.string(from: c.quando) + " · "
                 + (controle.palavras[c.resumo].map(TextosDaPergunta.palavras) ?? "…"))
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Text(c.previa).font(.footnote).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button(TextosDaPergunta.ver) { controle.ver(c, porque: "toque") }.buttonStyle(.bordered)
                Button(TextosDaPergunta.usarEste) { controle.confirmacao = .usar(c) }.buttonStyle(.bordered)
                Spacer()
                Button(TextosDaPergunta.apagar, role: .destructive) { controle.confirmacao = .apagar(c) }
                    .buttonStyle(.bordered)
            }
            if let erro = controle.erro {
                Text(erro).font(.caption).foregroundColor(Estilo.aguardandoTexto)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }
}

/// O botão "Roteiros guardados", na tela do controle — também sem conexão.
struct BotaoDosGuardados: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    /// O botão secundário pequeno do formulário do controle (`docs/telas-estudio.md` §6.7). No painel,
    /// o de sempre (só as cores mudam, §6.8).
    var pequeno = false
    let abrir: () -> Void

    var body: some View {
        if pequeno {
            // Sem o ícone: ao lado de "Colar endereço", na metade da largura do iPhone 7, o texto
            // com o ícone era cortado.
            Button(action: abrir) { Text(texto) }
                .buttonStyle(.secundarioPequeno)
        } else {
            Button(action: abrir) { Label(texto, systemImage: "tray.full").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }
    }

    private var texto: String {
        TextosDaPergunta.roteirosGuardados
            + (modelo.estado.copiasDoTexto.isEmpty ? "" : " (\(modelo.estado.copiasDoTexto.count))")
    }
}

// ================================================================================================
// A bancada
// ================================================================================================

/// **A bancada da pergunta**, pelos mesmos métodos dos botões:
///
/// - `--escolha prompter|meu` (com `--escolha-apos S`, padrão 3): quando a caixa mostra a pergunta
///   com os botões ligados, espera S segundos (para a captura) e escolhe, com o resumo **que a caixa
///   mostrou**. Uma vez por pergunta aberta. **`--roteiro-de-bancada` sem `--escolha` responde
///   "meu"** em 0,5 s: a bancada que dá texto ao controle não pode ficar parada esperando um dedo
///   (§11.7);
/// - `--controle-sem-roteiro`: antes de conectar, o roteiro do controle fica vazio (a linha "vazio"
///   da §11.2);
/// - `--guardados abrir,ver:1,usar:1,apagar:2,fechar`: "Roteiros guardados", um passo a cada ~3 s —
///   a confirmação aparece na tela antes de a bancada confirmar, pelo mesmo método do botão.
enum BancadaDaPergunta {
    private static var consumida = false

    static func ligar(_ m: ModeloDoTeleprompter, _ p: ControleDaPergunta, _ g: ControleDosGuardados,
                      abrirGuardados: @escaping () -> Void, fecharFolha: @escaping () -> Void) {
        guard !consumida else { return }
        consumida = true
        let args = CommandLine.arguments
        func valor(_ chave: String) -> String? {
            guard let i = args.firstIndex(of: chave), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("--controle-sem-roteiro") {
            let erro = m.confirmarTexto("")
            DiarioDoTeleprompter.dizer("bancada: o roteiro do controle ficou vazio antes de conectar"
                + (erro.map { " — ERRO \($0)" } ?? ""))
        }
        var escolha = valor("--escolha")
        var apos = valor("--escolha-apos").flatMap { Double($0) } ?? 3
        if escolha == nil, args.contains("--roteiro-de-bancada") { escolha = "meu"; apos = 0.5 }
        if let escolha, escolha == "prompter" || escolha == "meu" {
            DiarioDoTeleprompter.dizer("bancada: a pergunta do texto responde \"\(escolha)\" \(apos) s depois de aparecer")
            responder(m, p, manterOMeu: escolha == "meu", apos: apos)
        }
        if let roteiro = valor("--guardados") {
            guardados(m, g, passos: roteiro.split(separator: ",").map(String.init),
                      abrir: abrirGuardados, fechar: fecharFolha)
        }
    }

    /// Espera a caixa com os botões ligados, e escolhe com o resumo que ela mostrou.
    private static func responder(_ m: ModeloDoTeleprompter, _ p: ControleDaPergunta, manterOMeu: Bool, apos: Double) {
        let t = Thread { [weak m, weak p] in
            var respondidas = 0
            while m != nil, p != nil, respondidas < 20 {
                var pronta: String?
                DispatchQueue.main.sync {
                    guard let m, let p, case .pergunta(_, botoes: true, aviso: _) = p.estadoDaCaixa(m) else { return }
                    pronta = p.resumoMostrado
                }
                guard let resumo = pronta else { Thread.sleep(forTimeInterval: 0.1); continue }
                DiarioDoTeleprompter.dizer("bancada: a caixa mostra a pergunta (resumo \(resumo)); respondendo em \(apos) s")
                Thread.sleep(forTimeInterval: apos)
                DispatchQueue.main.sync {
                    guard let m, let p, case .pergunta(_, botoes: true, aviso: _) = p.estadoDaCaixa(m), let r = p.resumoMostrado else { return }
                    p.escolher(manterOMeu: manterOMeu, resumoMostrado: r, porque: "bancada --escolha")
                }
                respondidas += 1
                // A próxima só quando esta tiver fechado (ou mudado para outra).
                let limite = Date().addingTimeInterval(10)
                while Date() < limite {
                    var aindaEla = false
                    DispatchQueue.main.sync {
                        guard let m, let p, case .pergunta(_, botoes: true, aviso: _) = p.estadoDaCaixa(m) else { return }
                        aindaEla = p.resumoMostrado == resumo && p.resposta == nil
                    }
                    if !aindaEla { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        t.name = "quall.teleprompter.pergunta"
        t.start()
    }

    private static func guardados(_ m: ModeloDoTeleprompter, _ g: ControleDosGuardados, passos: [String],
                                  abrir: @escaping () -> Void, fechar: @escaping () -> Void) {
        let t = Thread { [weak m, weak g] in
            func lista() -> [CopiaDoTexto] {
                var c: [CopiaDoTexto] = []
                DispatchQueue.main.sync { c = m?.estado.copiasDoTexto ?? [] }
                return c
            }
            Thread.sleep(forTimeInterval: 2.5)
            DiarioDoTeleprompter.dizer("bancada: guardados: \(lista().count) na lista — " + ModeloDoTeleprompter.descrever(lista()))
            for passo in passos {
                let partes = passo.split(separator: ":")
                let acao = String(partes.first ?? "")
                let n = partes.count > 1 ? Int(partes[1]) ?? 1 : 1
                let copias = lista()
                let c = (n >= 1 && n <= copias.count) ? copias[n - 1] : nil
                DiarioDoTeleprompter.dizer("bancada: guardados: passo \(passo)")
                switch acao {
                case "abrir":
                    DispatchQueue.main.sync { abrir() }
                case "fechar":
                    DispatchQueue.main.sync { g?.vendo = nil; g?.confirmacao = nil }
                    Thread.sleep(forTimeInterval: 1)
                    DispatchQueue.main.sync { fechar() }
                case "ver":
                    guard let c else { DiarioDoTeleprompter.dizer("bancada: guardados: não há o item \(n)"); continue }
                    DispatchQueue.main.sync { g?.ver(c, porque: "bancada") }
                    Thread.sleep(forTimeInterval: 3)
                    DispatchQueue.main.sync { g?.vendo = nil }
                case "usar", "apagar":
                    guard let c else { DiarioDoTeleprompter.dizer("bancada: guardados: não há o item \(n)"); continue }
                    // A confirmação na tela, como o botão faz; depois, o que o botão dela faz.
                    DispatchQueue.main.sync { g?.confirmacao = acao == "usar" ? .usar(c) : .apagar(c) }
                    DiarioDoTeleprompter.dizer("bancada: guardados: confirmação de \(acao) na tela")
                    Thread.sleep(forTimeInterval: 3)
                    // Como o botão do alerta: o alerta fecha, e então a ação.
                    DispatchQueue.main.sync { g?.confirmacao = nil }
                    Thread.sleep(forTimeInterval: 1)
                    DispatchQueue.main.sync {
                        if acao == "usar" { g?.usar(c, porque: "bancada, depois da confirmação") }
                        else { g?.apagar(c, porque: "bancada, depois da confirmação") }
                    }
                default:
                    DiarioDoTeleprompter.dizer("bancada: guardados: passo desconhecido \(passo)")
                }
                Thread.sleep(forTimeInterval: 3)
                DiarioDoTeleprompter.dizer("bancada: guardados: \(lista().count) na lista — " + ModeloDoTeleprompter.descrever(lista()))
            }
            DiarioDoTeleprompter.dizer("bancada: guardados terminado")
        }
        t.name = "quall.teleprompter.guardados"
        t.start()
    }
}
