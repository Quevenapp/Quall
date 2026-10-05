import AppKit
import QuallIdiomaKit
import QuallTeleprompterKit
import SwiftUI

/// **O modo "Segurar para rolar" do controle** (`docs/contrato-teleprompter.md` §12.5): a tela fica
/// só com dois botões grandes, um em cima do outro, e o texto rola enquanto um deles está apertado,
/// na velocidade ajustada. Soltou, o texto para.
///
/// - O mouse: `hold` no `mouseDown`; `release` no `mouseUp`, ao sair do botão com o botão do mouse
///   apertado, ao perder o foco da janela e ao fechar (`VistaDoBotaoDeSegurar`, e o modelo).
/// - O teclado (Mac e Windows): ↑ e ↓ seguram os dois botões — os passadores de slide mandam setas.
///   A repetição automática da tecla não faz nada (`Teleprompter.teclaDoSegurar`).
/// - Os botões só funcionam com o prompter dizendo que entende (`"par_entende_segurar": true`); sem
///   isso, "Atualize o app do prompter para usar este modo".
/// - Sair do modo é o "Sair do modo" pequeno no canto de cima, longe dos botões (e nenhuma tecla o
///   aperta: no modo o teclado é só ↑ e ↓).
/// - **"Inverter botões"**, o interruptor pequeno ao lado do "Sair do modo": o de cima avança e o de
///   baixo volta, as legendas trocam junto, e ↑ ↓ seguem os botões. Não troca com um botão de rolar
///   apertado. O sentido de cada botão sai de um lugar só (`BotaoDeSegurar.paraTras(invertido:)`).
struct ModoSegurar: View {
    @EnvironmentObject private var tp: Teleprompter

    var body: some View {
        VStack(spacing: 12) {
            barra
            avisos
            BotaoGrandeDeSegurar(botao: .cima)
            BotaoGrandeDeSegurar(botao: .baixo)
            Text(T("Segure um botão, ou a seta ↑ ou ↓ do teclado (o passador de slides também serve). Soltou, o texto para."))
                .font(.caption2)
                .foregroundColor(Estilo.texto2)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        // A tela do modo sumiu (saiu do modo, a janela fechou, o controle voltou ao formulário):
        // nenhum botão continua seguro sem estar na tela.
        .onDisappear { tp.soltarTudoDoSegurar(porque: "o modo saiu da tela") }
    }

    private var barra: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tp.fase == .conectado && !tp.avisos.parSumido ? Estilo.conectado : Estilo.aguardando)
                .frame(width: 10, height: 10)
            Text(situacao)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            // Só para ler: mudar a velocidade é fora do modo.
            Text(T("Velocidade %@ linhas/s", String(format: "%.2f", tp.estado.velocidade)))
                .font(.callout.monospacedDigit())
                .foregroundColor(Estilo.texto2)
                .help(T("A velocidade ajustada. Para mudá-la, saia do modo."))
            // "Inverter botões" (14/09 à tarde): pequeno, no canto, perto do "Sair do modo", com o estado
            // à mostra. **Desligado com um botão de rolar apertado** — a troca espera soltar.
            Toggle(isOn: Binding(get: { tp.segurar.invertido }, set: { tp.definirInversao($0) })) {
                Text(T("Inverter botões")).font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!tp.segurar.podeInverter)
            .padding(.leading, 12)
            .help(tp.segurar.podeInverter
                  ? T("Troca o que os dois botões fazem (e as setas ↑ ↓), para quando o espelho do suporte deixa o texto andando ao contrário da seta.")
                  : T("Solte o botão de rolar para trocar."))
            Button(T("Sair do modo")) { tp.segurarParaRolar = false }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.leading, 12)
                .help(T("Volta à tela do controle com todos os comandos"))
        }
    }

    private var situacao: String {
        switch tp.fase {
        case .conectado: return tp.avisos.parSumido ? T("%@ não responde", tp.par) : T("Controlando %@", tp.par)
        case .encerrando: return T("Saindo…")
        default: return T("Conexão perdida")
        }
    }

    /// **As faixas num espaço de altura fixa**, com ou sem aviso: o tamanho dos botões nunca muda
    /// no meio de um aperto. Sem isto, a faixa "O texto parou" sumindo no aperto seguinte subia a
    /// borda de baixo de "Rolar para cima" em ~49 pt, e o primeiro tremor do trackpad virava "o mouse
    /// saiu do botão" — um release que ninguém pediu (revisão de 14/09).
    private var avisos: some View {
        VStack(spacing: 6) {
            if let t = tp.segurar.avisoDoTextoParado(posicao: tp.estado.posicao) { faixa(t, cor: Estilo.aguardando) }
            if let aviso { faixa(aviso.texto, cor: aviso.cor) }
        }
        .frame(height: 2 * ModoSegurar.alturaDaFaixa + 6, alignment: .top)
    }

    static let alturaDaFaixa: CGFloat = 40

    /// Por que os botões estão desligados, quando estão.
    private var aviso: (texto: String, cor: Color)? {
        switch tp.disponibilidadeDoSegurar {
        case .pronto: return nil
        case .semSessao:
            return ((tp.tentativas > 1 ? T("Sem conexão com o prompter — tentando de novo (tentativa %@).", tp.tentativas)
                                       : T("Sem conexão com o prompter — tentando de novo."))
                    + " " + T("Os botões voltam com ele."), Estilo.aguardando)
        case .esperandoOPrompter: return (T("Esperando o prompter responder…"), Estilo.aguardandoTexto)
        case .prompterSumido: return (T("O prompter não responde há mais de 2,5 s. Os botões voltam quando ele responder."), Estilo.aguardando)
        case .prompterAntigo: return (T("Atualize o app do prompter para usar este modo"), Estilo.noAr)
        }
    }

    private func faixa(_ texto: String, cor: Color) -> some View {
        Text(texto)
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: ModoSegurar.alturaDaFaixa, maxHeight: ModoSegurar.alturaDaFaixa)
            .background(cor.opacity(0.25))
            .cornerRadius(10)
    }
}

/// Um dos dois botões grandes: o desenho no SwiftUI, e por cima a vista AppKit que recebe o mouse.
struct BotaoGrandeDeSegurar: View {
    @EnvironmentObject private var tp: Teleprompter
    let botao: BotaoDeSegurar

    var body: some View {
        let ligado = tp.disponibilidadeDoSegurar.botoesLigados
        let apertado = tp.segurar.botaoAtivo == botao
        let rolando = apertado && tp.segurar.seguro
        // A seta e o rótulo ficam no lugar; a legenda diz o que o botão faz, com ou sem inversão.
        let legenda = tp.segurar.legenda(botao)
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(cor(ligado: ligado, apertado: apertado, rolando: rolando))
            VStack(spacing: 6) {
                Image(systemName: botao.simbolo)
                    .font(.system(size: 64, weight: .bold))
                Text(botao.rotulo)
                    .font(.system(size: 34, weight: .bold))
                Text(legenda)
                    .font(.system(size: 15, weight: .medium))
                    .opacity(0.8)
            }
            .foregroundColor(.white.opacity(ligado ? 1 : 0.45))
            .allowsHitTesting(false)
            CapturaDoMouseDoSegurar(modelo: tp, botao: botao)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(botao.rotulo), \(legenda)")
        .accessibilityAddTraits(.isButton)
    }

    private func cor(ligado: Bool, apertado: Bool, rolando: Bool) -> Color {
        guard ligado else { return Estilo.superficieAlta }
        if rolando { return Estilo.acento }
        // Apertado sem rolar: o texto parou sozinho (a queda, o silêncio, a pausa no prompter).
        if apertado { return Estilo.aguardando.opacity(0.75) }
        return Estilo.acento.opacity(0.55)
    }
}

/// A ponte da vista AppKit do botão para o SwiftUI.
struct CapturaDoMouseDoSegurar: NSViewRepresentable {
    let modelo: Teleprompter
    let botao: BotaoDeSegurar

    func makeNSView(context: Context) -> VistaDoBotaoDeSegurar {
        let v = VistaDoBotaoDeSegurar(botao: botao)
        v.aoApertar = { [weak modelo] b in modelo?.apertarDoSegurar(b, por: .mouse) }
        v.aoSoltar = { [weak modelo] b, porque in modelo?.soltarDoSegurar(b, por: .mouse, porque: porque) }
        modelo.registrar(vistaDoSegurar: v)
        return v
    }

    func updateNSView(_ nsView: VistaDoBotaoDeSegurar, context: Context) {}
}

/// **O mouse num botão do segurar**, em AppKit: o SwiftUI não diz "o botão do mouse desceu" e
/// "subiu" separados, nem "saiu do botão com ele apertado". Transparente; o desenho é do SwiftUI.
///
/// `release` em quatro caminhos: o `mouseUp`; o `mouseDragged` fora do botão (sair do botão com o
/// botão do mouse apertado — voltar para dentro não aperta de novo, *derivado*: é o toque cancelado
/// das telas de toque); a vista saindo da janela; e, no modelo, a janela perdendo o foco.
final class VistaDoBotaoDeSegurar: NSView {
    let botao: BotaoDeSegurar
    var aoApertar: ((BotaoDeSegurar) -> Void)?
    var aoSoltar: ((BotaoDeSegurar, String) -> Void)?
    private(set) var apertado = false

    init(botao: BotaoDeSegurar) {
        self.botao = botao
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override var isOpaque: Bool { false }
    /// Uma vista transparente deixaria o arrasto mover a janela: aqui o arrasto é "sair do botão".
    override var mouseDownCanMoveWindow: Bool { false }
    /// O primeiro clique com a janela em segundo plano já aperta: é um botão de segurar, e quem
    /// aperta espera o texto andar.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        apertado = true
        aoApertar?(botao)
    }

    override func mouseDragged(with e: NSEvent) {
        guard apertado else { return }
        if !bounds.contains(convert(e.locationInWindow, from: nil)) {
            apertado = false
            aoSoltar?(botao, "o mouse saiu do botão")
        }
    }

    override func mouseUp(with e: NSEvent) {
        guard apertado else { return }
        apertado = false
        aoSoltar?(botao, "soltou o botão do mouse")
    }

    override func viewWillMove(toWindow novaJanela: NSWindow?) {
        super.viewWillMove(toWindow: novaJanela)
        if novaJanela == nil, apertado {
            apertado = false
            aoSoltar?(botao, "o botão saiu da janela")
        }
    }

    /// Bancada: um gesto com um evento sintético, **entregue à janela** (`sendEvent`) — é a janela
    /// que acha a vista pelo `hitTest` da hierarquia do SwiftUI e segue mandando o arrasto e a soltura
    /// para a vista que recebeu o clique, como no mouse de verdade (revisão de 14/09: chamar os
    /// métodos direto não provava que o clique chega aqui). Devolve o que aconteceu, para o registro.
    func simular(_ gesto: GestoDoMouse) -> String {
        guard let w = window, bounds.width > 0, bounds.height > 0 else { return "sem janela" }
        let ponto = gesto == .sai
            ? NSPoint(x: bounds.midX, y: bounds.maxY + bounds.height)
            : NSPoint(x: bounds.midX, y: bounds.midY)
        let tipo: NSEvent.EventType = gesto == .desce ? .leftMouseDown : (gesto == .sobe ? .leftMouseUp : .leftMouseDragged)
        let naJanela = convert(ponto, to: nil)
        guard let e = NSEvent.mouseEvent(with: tipo, location: naJanela, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: gesto == .sobe ? 0 : 1)
        else { return "sem evento" }
        let alvo = w.contentView?.hitTest(w.contentView?.superview?.convert(naJanela, from: nil) ?? naJanela)
        w.sendEvent(e)
        let quem = alvo === self ? "esta vista" : (alvo.map { String(describing: type(of: $0)) } ?? "nenhuma")
        return String(format: "botão de %.0fx%.0f pt, hitTest=%@, apertado=%@", bounds.width, bounds.height,
                      quem, apertado ? "sim" : "não")
    }
}

/// Uma referência fraca num dicionário.
final class ReferenciaFraca<T: AnyObject> {
    weak var objeto: T?
    init(_ objeto: T) { self.objeto = objeto }
}
