import SwiftUI
import UIKit

/// **O prompter**: mostra o texto e hospeda, com papel `"teleprompter"`.
///
/// # O que a tela garante
///
/// - **Manter tela ligada**, por padrão, enquanto ela está aberta; a preferência é local, nos
///   Ajustes, compartilhada com o espelhamento e a câmera.
/// - **Tela cheia** num toque no texto (e no botão): sem barras, sem barra de status, sem indicador
///   de início. Outro toque devolve os controles. **O aviso de controle sumido fica também na tela
///   cheia** — é decisão do usuário (§2).
/// - **O PIN e o endereço** ficam no alto enquanto há controles à mostra: é o que um controle
///   novo — ou o mesmo, de volta de uma queda — precisa digitar. O botão ao lado abre os dois em
///   letra grande (`FolhaDoEndereco`), para ler de longe. O QR que ficava ali saiu em 24/09/2026, por
///   decisão do Pessoa Exemplo.
/// - **Quando o controle cai, o texto continua como estava** (rolando segue rolando) e o prompter
///   hospeda de novo na mesma porta e com o mesmo PIN — tudo isso é da sessão e do núcleo; a tela só
///   mostra o aviso.
struct TelaDoPrompter: View {
    @StateObject private var modelo: ModeloDoTeleprompter
    /// A orientação deste aparelho (`OrientacaoDoPrompter`): presa enquanto a tela está aberta.
    @StateObject private var orientacao = EscolhaDeOrientacao()
    /// O enquadramento e a fonte automática deste aparelho (`AjustesLocais`).
    @StateObject private var ajustes = AjustesLocais()
    let voltar: () -> Void

    @State private var telaCheia = false
    @State private var folha: Folha?
    /// O topo da barra de baixo, em coordenadas globais: as marcas do enquadramento ficam acima dele.
    @State private var topoDaBarra = CGFloat.greatestFiniteMagnitude
    /// O fundo da faixa do PIN e dos avisos, em coordenadas globais: as marcas ficam logo abaixo.
    @State private var fundoDoAlto = CGFloat.zero
    @State private var comecou = false
    private static let donoDaTelaAcesa = "teleprompter"
    @Environment(\.scenePhase) private var etapa
    @Environment(\.horizontalSizeClass) private var classeHorizontal

    enum Folha: String, Identifiable {
        case ajustes, editor, endereco
        var id: String { rawValue }
    }

    init(voltar: @escaping () -> Void) {
        self.voltar = voltar
        // O `StateObject` é criado uma vez por tela: é aqui que os argumentos de bancada são
        // consumidos, e não no `body` de quem abre a tela.
        _modelo = StateObject(wrappedValue: ModeloDoTeleprompter(
            papel: .teleprompter, bancada: BancadaDoTeleprompter.consumir()))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // As setas da linha de leitura por cima das marcas do enquadramento: onde as zonas se
            // cruzarem, a linha vence (`EnquadramentoDoTexto.alturaDaMarca`).
            VistaDoRoteiro(modelo: modelo, ajustes: ajustes, aoTocar: alternarTelaCheia)
                .overlay(EnquadramentoDoTexto(modelo: modelo, ajustes: ajustes, guias: !telaCheia || folha == .ajustes,
                                              fundoDoAlto: fundoDoAlto, topoDaBarra: topoDaBarra,
                                              giro: orientacao.giroDoTexto))
                .overlay(AlcasDaLinhaDeLeitura(modelo: modelo))
                .modifier(GiroDoTexto(escolha: orientacao))
                .ignoresSafeArea(edges: telaCheia ? .all : [])

            VStack(spacing: 8) {
                VStack(spacing: 8) {
                    if !telaCheia { faixaDeCima }
                    AvisosDoTeleprompter(modelo: modelo)
                    AvisoDaFonteAutomatica(ajustes: ajustes)
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: FundoDoAltoDoPrompter.self, value: g.frame(in: .global).maxY)
                })
                Spacer(minLength: 0)
                if !telaCheia {
                    barraDeBaixo.background(GeometryReader { g in
                        // A legenda de velocidade fica 16 pt acima da barra: conta como barra.
                        Color.clear.preference(key: TopoDaBarraDoPrompter.self, value: g.frame(in: .global).minY - 22)
                    })
                }
            }
            .padding(.top, telaCheia ? 8 : 0)
            .onPreferenceChange(TopoDaBarraDoPrompter.self) { topoDaBarra = $0 }
            .onPreferenceChange(FundoDoAltoDoPrompter.self) { fundoDoAlto = $0 }
        }
        .statusBar(hidden: telaCheia)
        .modifier(IndicadorDeInicio(escondido: telaCheia))
        .preferredColorScheme(.dark)
        .sheet(item: $folha) { f in
            switch f {
            case .ajustes: FolhaDeAjustes(modelo: modelo, voltarAoComeco: { modelo.voltarAoComeco() },
                                          orientacao: orientacao, ajustes: ajustes) { folha = nil }
            case .editor: EditorDoRoteiro(modelo: modelo) { folha = nil }
            case .endereco: FolhaDoEndereco(modelo: modelo) { folha = nil }
            }
        }
        .onAppear {
            TelaAcesa.pedir(TelaDoPrompter.donoDaTelaAcesa)
            // A orientação a cada aparição (a saída a solta); a da bancada, uma vez por vida do app.
            if BancadaDaOrientacao.consumir(), let o = BancadaDaOrientacao.escolha() {
                orientacao.escolher(o, por: "--orientacao")
            } else {
                orientacao.aplicar(por: "a tela abriu")
            }
            guard !comecou else { return }
            comecou = true
            // "Segurar para rolar" (§12.5): a vista rola para trás com `para_tras` e para quando
            // `rolando` cai — só por isso a tela diz ao núcleo que entende.
            let st = modelo.replica.habilitarSegurar()
            DiarioDoTeleprompter.dizer("prompter: segurar para rolar ligado (\(SessaoDoTeleprompter.nome(st)))")
            BancadaDaOrientacao.ligar(modelo, orientacao) { folha = .endereco }
            let b = modelo.bancada
            // A porta da bancada (`--porta`), quando dada; senão, a do núcleo, uma vez por tela (§11.7).
            if let porta = b?.porta {
                modelo.hospedar(porta: porta, pin: b?.pin)
                DiarioDoTeleprompter.dizer("tela: prompter aberto (porta \(porta), da bancada)")
            } else {
                modelo.hospedarNaPortaDoTeleprompter(pin: b?.pin)
                DiarioDoTeleprompter.dizer("tela: prompter aberto (porta escolhida pelo núcleo)")
            }
            BancadaDoTeleprompter.ligarNoPrompter(modelo, opcoes: b)
            if b?.telaCheia == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { telaCheia = true }
            }
        }
        .onDisappear {
            TelaAcesa.soltar(TelaDoPrompter.donoDaTelaAcesa)
            orientacao.soltar()
            modelo.sair()
        }
        .onChange(of: etapa) { nova in
            // No segundo plano o prompter solta a sessão e a porta (o iOS pode recolher o socket de
            // escuta de um app suspenso); na volta, hospeda de novo com o mesmo PIN.
            if nova == .background { modelo.aoIrParaOSegundoPlano() }
            if nova == .active {
                TelaAcesa.reafirmar()
                orientacao.aplicar(por: "a tela voltou ao primeiro plano")
                modelo.aoVoltarAoPrimeiroPlano()
            }
        }
    }

    private func alternarTelaCheia() {
        withAnimation(.easeInOut(duration: 0.2)) { telaCheia.toggle() }
        DiarioDoTeleprompter.dizer("tela cheia: \(telaCheia ? "entrou" : "saiu")")
    }

    // --- o alto ---------------------------------------------------------------------------------

    private var faixaDeCima: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(corDoEstado).frame(width: 9, height: 9)
                    Text(textoDoEstado).font(.subheadline.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                HStack(spacing: 10) {
                    Text(verbatim: "PIN \(pinEspacado)").font(.system(.subheadline, design: .monospaced).weight(.bold))
                    Text(modelo.enderecoParaDigitar ?? tr("sem rede"))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(modelo.enderecoParaDigitar == nil ? Estilo.aguardandoTexto : .white)
                }
                .lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
            if modelo.enderecoParaDigitar != nil, !modelo.pin.isEmpty {
                Button { folha = .endereco } label: {
                    Image(systemName: "textformat.size").font(.title2)
                }
                .accessibilityLabel(tr("Mostrar o endereço e o PIN em letra grande"))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Estilo.superficie.opacity(0.94))
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var pinEspacado: String { Estilo.pinEspacado(modelo.pin) }

    private var corDoEstado: Color {
        switch modelo.fase {
        case .conectada: return modelo.avisoDeSemPar == nil ? Estilo.conectado : Estilo.noAr
        case .semPar: return Estilo.noAr
        case .falhou: return Estilo.aguardando
        default: return Estilo.aguardando
        }
    }

    private var textoDoEstado: String {
        switch modelo.fase {
        case .parada: return tr("Parado")
        case .esperando, .conectando: return tr("Esperando o controle")
        case let .conectada(par): return par.isEmpty ? tr("Controle conectado") : tr("Controlado por %@", par)
        case .semPar: return tr("Controle desconectado")
        case let .falhou(motivo): return motivo
        }
    }

    // --- o pé -----------------------------------------------------------------------------------

    /// **A barra cabe na largura, sempre.** A primeira versão tinha nove botões `.bordered` lado a
    /// lado: no iPhone X (375 pt) a barra pedia ~450 pt, o `ZStack` inteiro alargava para 536 pt, e
    /// a vista do texto e a faixa do alto saíam cortadas dos dois lados (captura do aparelho, 13/09).
    /// Agora os botões são flexíveis e sem largura mínima própria, e na largura compacta (iPhone)
    /// ficam sete: "voltar ao começo" e o espelho moram na folha de Ajustes.
    private var barraDeBaixo: some View {
        HStack(spacing: 4) {
            botao("xmark", tr("Sair")) { voltar() }
            botao("pencil", tr("Editar")) { folha = .editor }
            botao("slider.horizontal.3", tr("Ajustes")) { folha = .ajustes }
            if classeHorizontal == .regular {
                botao("backward.end.fill", tr("Voltar ao começo")) { modelo.voltarAoComeco() }
            }
            botaoQueRepete("tortoise.fill", tr("Mais devagar")) { modelo.definirVelocidade(modelo.estado.velocidade - 0.1) }
            // Largura própria e limitada: com `layoutPriority` ele engolia a barra e espremia os
            // outros botões até o ícone (captura do iPhone X, 13/09).
            // O que o botão mostra é o que ele manda (`pedirRolando`): nada de alternar na hora do toque.
            Button(action: { [rolando = modelo.estado.rolando] in modelo.pedirRolando(!rolando) }) {
                Image(systemName: modelo.estado.rolando ? "pause.fill" : "play.fill")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 56, maxWidth: 96, minHeight: 44)
                    .background(Estilo.acento)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(modelo.estado.rolando ? tr("Pausar") : tr("Rolar"))
            botaoQueRepete("hare.fill", tr("Mais depressa")) { modelo.definirVelocidade(modelo.estado.velocidade + 0.1) }
            if classeHorizontal == .regular {
                botao("arrow.left.and.right.righttriangle.left.righttriangle.right", tr("Espelho")) {
                    modelo.definirEspelho(!modelo.estado.espelho)
                }
            }
            botao("arrow.up.left.and.arrow.down.right", tr("Tela cheia")) { alternarTelaCheia() }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        // Quase opaca: o texto rola por baixo da barra, e com 10 % de branco as letras apareciam
        // entre os botões.
        .background(Estilo.superficie.opacity(0.94))
        .cornerRadius(14)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .overlay(alignment: .top) {
            Text(tr("%.2f linhas/s · %.0f pt · %.0f %%", modelo.estado.velocidade,
                     modelo.estado.fonte, modelo.estado.posicao * 100))
                .font(.caption2.monospacedDigit())
                .foregroundColor(Estilo.texto3)
                .offset(y: -16)
        }
    }

    /// O botão da barra que repete enquanto pressionado (a velocidade; `BotaoQueRepete`).
    private func botaoQueRepete(_ simbolo: String, _ rotulo: String, passo: @escaping () -> Void) -> some View {
        BotaoQueRepete(rotulo, passo: passo) {
            Image(systemName: simbolo)
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.14))
                .cornerRadius(10)
        }
    }

    private func botao(_ simbolo: String, _ rotulo: String, acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.14))
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rotulo)
    }
}

/// O endereço e o PIN em letra grande, para quem vai controlar ler de longe e digitar.
///
/// Era a folha do QR (o código ao lado dos dois números) até 24/09/2026, quando o QR saiu por
/// decisão do Pessoa Exemplo. Os números por extenso sempre foram o caminho garantido: o prompter anuncia pelo
/// `mDNSResponder` (`AnuncianteBonjour`), mas mDNS não é garantido (multicast bloqueado, AP isolation),
/// e um controle iPhone não lista aparelhos — chega aqui pelo IP digitado.
struct FolhaDoEndereco: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    let fechar: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(tr("Controlar este teleprompter")).font(.title3.weight(.semibold))
            VStack(spacing: 6) {
                Text(tr("No outro aparelho, abra o Quall → Teleprompter → Controlar, e digite:"))
                    .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(modelo.enderecoParaDigitar ?? tr("sem rede"))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .foregroundColor(modelo.enderecoParaDigitar == nil ? Estilo.aguardandoTexto : Estilo.texto)
                    .lineLimit(1).minimumScaleFactor(0.4)
                Text(verbatim: "PIN \(modelo.pin)")
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .accessibilityLabel("PIN " + modelo.pin.map { String($0) }.joined(separator: " ")) // sem-traducao
            }
            Button(tr("Fechar"), action: fechar).buttonStyle(.bordered)
        }
        .padding(24)
    }
}
