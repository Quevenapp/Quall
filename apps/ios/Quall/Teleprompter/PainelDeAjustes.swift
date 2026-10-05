import SwiftUI
import UIKit

/// Os ajustes do texto — velocidade, fonte, margem, linha de leitura, espelho —, **os mesmos nas
/// duas telas**: o controle manda para o prompter, e o prompter ajusta a si mesmo. As duas edições
/// valem (vale a última, campo a campo, §3).
///
/// Os controles deslizantes têm passo (`step`) de propósito: cada valor novo é uma edição com
/// carimbo, e sai na hora (§4). Com passo, um arrasto manda uma mensagem por degrau, e não uma por
/// quadro do dedo.
///
/// **No controle, fonte, margem e linha de leitura só saem ao soltar o dedo**: cada uma delas refaz
/// o layout do roteiro inteiro no prompter (até 128 KiB), e um arrasto mandando dez degraus por
/// segundo seria dez layouts por segundo na tela de quem lê. A velocidade sai ao vivo — ela não
/// refaz layout, e é a que se ajusta ouvindo a pessoa falar. No prompter, tudo sai ao vivo: quem
/// arrasta está vendo o texto, e a vista limita o layout a um a cada 300 ms.
struct ControlesDoTexto: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    /// A "Fonte automática" do prompter está ligada (`AjustesLocais`): a fonte à mão fica travada.
    var fonteTravada = false

    private var layoutAoVivo: Bool { modelo.papel == .teleprompter }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            linha(tr("Velocidade"), tr("%.2f linhas/s", modelo.estado.velocidade)) {
                HStack(spacing: 10) {
                    BotaoQueRepete(tr("Mais devagar"), passo: { modelo.definirVelocidade(modelo.estado.velocidade - 0.1) }) {
                        Image(systemName: "minus").font(.body.weight(.semibold)).frame(width: 36, height: 32)
                            .background(Color.secondary.opacity(0.18)).cornerRadius(8)
                    }
                    Deslizante(valor: modelo.estado.velocidade, faixa: 0.05...8, passo: 0.05,
                               aoVivo: true) { modelo.definirVelocidade($0) }
                    BotaoQueRepete(tr("Mais depressa"), passo: { modelo.definirVelocidade(modelo.estado.velocidade + 0.1) }) {
                        Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 36, height: 32)
                            .background(Color.secondary.opacity(0.18)).cornerRadius(8)
                    }
                }
            }
            linha(tr("Fonte"), fonteTravada ? tr("%.0f pt (automática)", modelo.estado.fonte)
                                             : String(format: "%.0f pt", modelo.estado.fonte)) {
                HStack(spacing: 10) {
                    BotaoPequeno(simbolo: "textformat.size.smaller") { modelo.definirFonte(modelo.estado.fonte - 4) }
                    Deslizante(valor: modelo.estado.fonte, faixa: 16...200, passo: 2,
                               aoVivo: layoutAoVivo) { modelo.definirFonte($0) }
                    BotaoPequeno(simbolo: "textformat.size.larger") { modelo.definirFonte(modelo.estado.fonte + 4) }
                }
                .disabled(fonteTravada)
                .opacity(fonteTravada ? 0.45 : 1)
            }
            linha(tr("Margem"), tr("%.0f %% de cada lado", modelo.estado.margem * 100)) {
                Deslizante(valor: modelo.estado.margem, faixa: 0...0.45, passo: 0.01,
                           aoVivo: layoutAoVivo) { modelo.definirMargem($0) }
            }
            linha(tr("Linha de leitura"), tr("%.0f %% do alto", modelo.estado.linhaDeLeitura * 100)) {
                Deslizante(valor: modelo.estado.linhaDeLeitura, faixa: 0...1, passo: 0.01,
                           aoVivo: layoutAoVivo) { modelo.definirLinhaDeLeitura($0) }
            }
            Toggle(isOn: Binding(get: { modelo.estado.espelho }, set: { modelo.definirEspelho($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Espelho")).font(.subheadline.weight(.semibold))
                    Text(tr("Inverte o texto na horizontal, para ler no reflexo do vidro."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func linha<C: View>(_ titulo: String, _ valor: String, @ViewBuilder _ conteudo: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(titulo).font(.subheadline.weight(.semibold))
                Spacer()
                Text(valor).font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
            }
            conteudo()
        }
    }
}

/// Um deslizante que mostra o valor do estado quando ninguém arrasta, e o do dedo enquanto arrasta.
/// `aoVivo`: manda a cada degrau; senão, só ao soltar.
struct Deslizante: View {
    let valor: Double
    let faixa: ClosedRange<Double>
    let passo: Double
    let aoVivo: Bool
    let definir: (Double) -> Void

    @State private var local: Double = 0
    @State private var arrastando = false

    var body: some View {
        Slider(value: Binding(get: { arrastando ? local : min(faixa.upperBound, max(faixa.lowerBound, valor)) },
                              set: { novo in
                                  local = novo
                                  if aoVivo { definir(novo) }
                              }),
               in: faixa, step: passo,
               onEditingChanged: { editando in
                   if editando {
                       local = min(faixa.upperBound, max(faixa.lowerBound, valor))
                       arrastando = true
                   } else {
                       arrastando = false
                       definir(local)
                   }
               })
    }
}

/// **Um botão que repete enquanto pressionado** (`RepeticaoDoBotao`): um toque é um passo (ao
/// soltar); segurando, os passos vêm sozinhos, o primeiro em 0,4 s e os seguintes cada vez mais
/// depressa, até soltar. Para o VoiceOver é um botão comum: um passo por ação.
///
/// **Pode morar numa rolagem** (a folha de Ajustes, a tela do controle): o gesto é simultâneo ao da
/// rolagem, e um dedo que anda mais de 10 pt desiste (é rolagem, não aperto) sem dar passo nenhum —
/// a revisão de 27/09 viu o passo no toque mudar a velocidade do prompter numa rolagem. `@GestureState`
/// volta sozinho quando o sistema cancela o gesto, e a repetição para com ele.
struct BotaoQueRepete<Rotulo: View>: View {
    let rotuloAcessivel: String
    let passo: () -> Void
    let rotulo: Rotulo
    @GestureState private var segurando = false
    @State private var comecou = false
    @State private var desistiu = false
    @State private var repetiu = false
    @State private var vez = 0

    /// Quanto o dedo pode andar e ainda ser um aperto.
    static var folga: CGFloat { 10 }

    init(_ rotuloAcessivel: String, passo: @escaping () -> Void, @ViewBuilder rotulo: () -> Rotulo) {
        self.rotuloAcessivel = rotuloAcessivel
        self.passo = passo
        self.rotulo = rotulo()
    }

    var body: some View {
        rotulo
            .opacity(segurando && !desistiu ? 0.6 : 1)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($segurando) { _, s, _ in s = true }
                    .onChanged { v in
                        if !comecou {
                            comecou = true
                            desistiu = false
                            repetiu = false
                            vez += 1
                            agendar(vez: vez, repeticao: 1)
                        }
                        if !desistiu, hypot(v.translation.width, v.translation.height) > Self.folga {
                            desistiu = true
                            vez += 1
                        }
                    }
                    .onEnded { _ in
                        if comecou, !desistiu, !repetiu { passo() }
                        comecou = false
                        vez += 1
                    })
            .onChange(of: segurando) { s in if !s { comecou = false; vez += 1 } }
            .onDisappear { comecou = false; vez += 1 }
            .accessibilityElement()
            .accessibilityLabel(rotuloAcessivel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { passo() }
    }

    private func agendar(vez v: Int, repeticao n: Int) {
        guard let espera = RepeticaoDoBotao.intervalo(antesDaRepeticao: n) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + espera) {
            guard comecou, !desistiu, vez == v else { return }
            repetiu = true
            passo()
            agendar(vez: v, repeticao: n + 1)
        }
    }
}

struct BotaoPequeno: View {
    let simbolo: String
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.bordered)
    }
}

/// A folha de ajustes do prompter (no controle, os mesmos controles ficam na tela). Tem também o
/// "voltar ao começo", que na barra do iPhone não cabe, e a orientação **deste aparelho**, que o
/// controle não tem (`OrientacaoDoPrompter`).
struct FolhaDeAjustes: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    var voltarAoComeco: (() -> Void)?
    var orientacao: EscolhaDeOrientacao?
    /// A fonte automática e o enquadramento deste aparelho (só o prompter).
    var ajustes: AjustesLocais?
    /// Os ajustes locais da tela "Teleprompter com câmera" (a prévia e o lado do texto), só nela.
    var ajustesDaCamera: AjustesDaTelaComCamera?
    let fechar: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let voltarAoComeco {
                        Button(action: voltarAoComeco) {
                            Label(tr("Voltar ao começo"), systemImage: "backward.end.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    SeletorDaTelaAcesa()
                    if let ajustesDaCamera { SecaoDaTelaComCamera(ajustes: ajustesDaCamera) }
                    if let orientacao { SeletorDeOrientacao(escolha: orientacao) }
                    if let ajustes {
                        SecaoDosAjustesLocais(ajustes: ajustes)
                        ControlesDoTextoDoPrompter(modelo: modelo, ajustes: ajustes)
                    } else {
                        ControlesDoTexto(modelo: modelo)
                    }
                }
                .padding(20)
            }
            .navigationTitle(tr("Ajustes do texto"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(tr("Pronto"), action: fechar) }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// **O editor do roteiro.** `set_text` só ao confirmar (§6, §7) — nunca a cada tecla.
///
/// A regra do texto que chega com o editor aberto está no cabeçalho de `ModeloDoTeleprompter`:
/// o rascunho não é tocado; a faixa oferece **Carregar o novo** ou **Manter o meu**.
struct EditorDoRoteiro: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    let fechar: () -> Void

    @State private var rascunho = ""
    @State private var erro: String?
    @State private var carregou = false

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 10) {
                if modelo.textoMudouDuranteEdicao {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("O roteiro mudou no outro aparelho enquanto você editava."))
                            .font(.subheadline.weight(.semibold))
                        Text(tr("O seu rascunho não foi tocado. Se confirmar, ele vale — é a edição mais recente."))
                            .font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button(tr("Carregar o novo")) {
                                rascunho = modelo.texto
                                modelo.textoMudouDuranteEdicao = false
                                DiarioDoTeleprompter.dizer("editor: a pessoa carregou o texto novo")
                            }
                            .buttonStyle(.borderedProminent)
                            Button(tr("Manter o meu")) {
                                modelo.textoMudouDuranteEdicao = false
                                DiarioDoTeleprompter.dizer("editor: a pessoa manteve o rascunho")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Estilo.aguardando.opacity(0.16))
                    .cornerRadius(10)
                }

                TextEditor(text: $rascunho)
                    .font(.body)
                    .autocorrectionDisabled()
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

                HStack {
                    Button {
                        if let colado = UIPasteboard.general.string { rascunho = colado }
                    } label: { Label(tr("Colar"), systemImage: "doc.on.clipboard") }
                        .buttonStyle(.bordered)
                    if rascunho.isEmpty {
                        Button(tr("Texto de exemplo")) { rascunho = TextoDeExemplo.roteiro }
                            .buttonStyle(.bordered)
                    } else {
                        Button(tr("Limpar"), role: .destructive) { rascunho = "" }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Text(tamanho).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }

                if let erro {
                    Text(erro).font(.callout).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .navigationTitle(tr("Roteiro"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Cancelar"), action: fechar) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Confirmar")) {
                        if let e = modelo.confirmarTexto(rascunho) { erro = e } else { fechar() }
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            guard !carregou else { return }
            carregou = true
            rascunho = modelo.texto
            modelo.textoMudouDuranteEdicao = false
            modelo.editorAberto = true
        }
        .onDisappear { modelo.editorAberto = false }
    }

    private var tamanho: String {
        let bytes = rascunho.utf8.count
        let teto = ReplicaDoTeleprompter.tetoDoTexto
        return tr("%.1f de %ld KiB", Double(bytes) / 1024, teto / 1024)
    }
}

/// Os avisos, empilhados — **também na tela cheia**: o do outro lado sumido é decisão do usuário
/// (§2: "aviso visível nas duas telas até ele voltar").
struct AvisosDoTeleprompter: View {
    @ObservedObject var modelo: ModeloDoTeleprompter

    var body: some View {
        VStack(spacing: 6) {
            if let a = modelo.avisoDeSemPar { faixa(a, cor: Estilo.noArCheio, simbolo: "wifi.exclamationmark") }
            if let a = modelo.avisoDeConfirmacao { faixa(a, cor: .orange, simbolo: "clock.badge.exclamationmark") }
            if let a = modelo.avisoDoProtocolo { faixa(a, cor: .orange, simbolo: "exclamationmark.triangle") }
            if !modelo.aviso.isEmpty { faixa(modelo.aviso, cor: .gray, simbolo: "info.circle") }
        }
        .padding(.horizontal, 12)
    }

    private func faixa(_ texto: String, cor: Color, simbolo: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: simbolo)
            Text(texto).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout.weight(.semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(cor.opacity(0.85))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
    }
}

/// Um roteiro de exemplo, **nosso** — para quem abre o teleprompter pela primeira vez ter o que ler.
enum TextoDeExemplo {
    /// Calculado na hora (e não `static let`): segue o idioma escolhido.
    static var roteiro: String {
        tr("Boa noite, e obrigado por estar aqui.\n\n"
            + "Este é o teleprompter do Quall. O texto sobe devagar, sempre na mesma velocidade, e a linha "
            + "amarela marca onde o olho deve ficar.\n\n"
            + "Do outro aparelho dá para tocar e pausar, mudar a velocidade, voltar ao começo e pular um "
            + "pedaço. O tamanho da letra, a margem e a linha de leitura também mudam de lá — ou daqui.\n\n"
            + "Para usar com um vidro na frente da câmera, ligue o espelho: o texto aparece invertido aqui e "
            + "certo no reflexo.\n\n"
            + "Se o controle perder a conexão, nada muda nesta tela: o texto continua como estava, e um aviso "
            + "fica no alto até o controle voltar.\n\n"
            + "Quando terminar, é só pausar. Boa gravação.")
    }
}
