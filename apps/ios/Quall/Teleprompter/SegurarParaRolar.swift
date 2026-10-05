import SwiftUI
import UIKit

// ================================================================================================
// "Segurar para rolar", no controle (`docs/contrato-teleprompter.md` §12; pedido do usuário, 14/09)
//
// Literal: "no aparelho controlador colocar uma opção que o usuário seleciona e fica apenas dois
// botões grandes Rolar para cima / Rolar para baixo, duas setas que ele fique segurando pressionado
// e vai rolando soltou o texto para". Respostas dele: **na velocidade ajustada**; **se a conexão cair
// com o dedo no botão, o texto para** (quem para é o núcleo, nos dois lados, §12.4).
// ================================================================================================

/// A opção ligada é **ajuste local do controle**, guardado neste aparelho — e "Inverter botões"
/// junto com ela: vale para qualquer prompter.
enum SegurarParaRolar {
    static let chave = "teleprompter.segurar-para-rolar"
    static let chaveInverter = "teleprompter.segurar-inverter"
}

/// **O que liga os dedos ao núcleo.** O painel de toque (`PainelDeToqueDeSegurar`) e a bancada
/// (`BancadaDoSegurar`) chamam as mesmas funções — ``encostou(_:em:)``, ``moveu(_:para:)``,
/// ``tirou(_:)`` —, e as regras dos dedos são as de `DedosNosBotoes`: vale o último botão apertado,
/// e `release` só quando nenhum dedo sobra num botão.
final class ControleDeSegurar: ObservableObject {
    /// Por que o texto parou sem ninguém soltar.
    enum Parada: Equatable {
        /// A queda, o silêncio de 2,5 s, a pausa no prompter: "O texto parou. Solte e aperte de novo."
        case parou
        /// Segurando o botão que avança até o fim do texto: o prompter parou ali (`chegouAoFim`).
        case fimDoTexto
        /// O núcleo não aceitou o aperto (sem sessão, ou outro motivo).
        case recusado
    }

    /// O botão que segura agora (o do dedo).
    @Published private(set) var ativo: BotaoDeSegurar?
    /// O texto parou sem ninguém soltar. **Nada aperta de novo sozinho**: os dedos que estavam nos
    /// botões morrem (`DedosNosBotoes.pararTodos`) até sair da tela. Some quando eles saem.
    @Published private(set) var parada: Parada?
    /// Dedos na tela que não contam: os que estavam nos botões quando o texto parou, e os que
    /// encostaram com os botões desligados. "Solte e aperte de novo."
    @Published private(set) var dedosMortos = 0
    /// O núcleo recusou o aperto com `PROTOCOL`: o prompter não entende o segurar.
    @Published private(set) var recusado = false
    /// "Inverter botões": o de cima avança e o de baixo volta (`BotaoDeSegurar.paraTras`). Guardado
    /// neste aparelho, junto com a opção do modo.
    @Published private(set) var invertido = UserDefaults.standard.bool(forKey: SegurarParaRolar.chaveInverter)
    /// Sem dedo nenhum num botão de rolar (`DedosNosBotoes.podeInverter`): só assim a troca vale.
    @Published private(set) var podeInverter = true

    private var dedos = DedosNosBotoes()
    private var segurou = false
    private weak var modelo: ModeloDoTeleprompter?

    func ligar(_ m: ModeloDoTeleprompter) { modelo = m }

    /// **A troca de "Inverter botões"**, a mesma para o botão da tela e para a bancada. Com um dedo
    /// num botão de rolar, não vale (devolve `false`): fica desligada até soltar.
    @discardableResult
    func trocarInversao(para novo: Bool? = nil, porque: String) -> Bool {
        let alvo = novo ?? !invertido
        guard dedos.podeInverter else {
            DiarioDoTeleprompter.dizer("segurar: inverter botões recusado (\(porque)) — há dedo num botão de rolar; "
                + "segue \(invertido ? "invertido" : "normal")")
            return false
        }
        guard alvo != invertido else { return true }
        invertido = alvo
        UserDefaults.standard.set(alvo, forKey: SegurarParaRolar.chaveInverter)
        DiarioDoTeleprompter.dizer("segurar: inverter botões \(alvo ? "ligado" : "desligado") (\(porque)) — "
            + "cima \(BotaoDeSegurar.cima.legenda(invertido: alvo)), baixo \(BotaoDeSegurar.baixo.legenda(invertido: alvo))")
        return true
    }

    /// Os botões valem: há sessão, o outro lado está falando, e o último estado dele diz que entende.
    func habilitado(_ m: ModeloDoTeleprompter) -> Bool {
        m.fase.conectada && m.avisoDeSemPar == nil && m.estado.parVistoHaMs != nil
            && m.estado.parEntendeSegurar && !recusado
    }

    // --- o caminho do toque -----------------------------------------------------------------------

    func encostou(_ dedo: Int, em b: BotaoDeSegurar?) {
        guard let m = modelo else { return }
        guard habilitado(m) else {
            if b != nil {
                // Não conta nem quando os botões ligarem com ele ainda na tela.
                dedos.encostouSemValer(dedo)
                atualizarMortos()
                DiarioDoTeleprompter.dizer("segurar: toque ignorado — botões desligados (\(motivoDesligado(m)))")
            }
            return
        }
        dedos.encostou(dedo, em: b)
        aplicar(porque: "encostou em \(b?.rawValue ?? "nenhum botão")")
    }

    func moveu(_ dedo: Int, para b: BotaoDeSegurar?) {
        dedos.moveu(dedo, para: b)
        aplicar(porque: "o dedo saiu do botão")
    }

    func tirou(_ dedo: Int) {
        dedos.tirou(dedo)
        aplicar(porque: "tirou o dedo")
    }

    /// Tudo solto: o segundo plano, a tela fechando, a saída do modo. **Manda o `release`** — só
    /// com a sessão ainda de pé, ou depois do `peer_lost` (a tela fechando: ver `TelaDoControle`).
    func soltarTudo(porque: String) {
        dedos.soltarTudo()
        aplicar(porque: porque)
    }

    /// O modo saiu da tela (a fase mudou, a tela fechou): esquece os dedos **sem editar nada** — a
    /// sessão já acabou com `peer_lost`, ou a saída do modo já soltou. Um dedo que ficou no vidro
    /// não pode voltar a valer se o UIKit não entregar o fim do toque a uma vista que saiu.
    func esquecerDedos(porque: String) {
        guard ativo != nil || dedos.quantos > 0 || dedos.mortosNaTela > 0 else { return }
        dedos.soltarTudo()
        ativo = nil
        segurou = false
        parada = nil
        atualizarMortos()
        DiarioDoTeleprompter.dizer("segurar: dedos esquecidos (\(porque)), sem edição")
    }

    private func atualizarMortos() {
        if dedosMortos != dedos.mortosNaTela { dedosMortos = dedos.mortosNaTela }
        if podeInverter != dedos.podeInverter { podeInverter = dedos.podeInverter }
        // A parada some quando nenhum dedo sobra na tela: a pessoa soltou, e pode apertar de novo.
        if parada != nil, dedos.mortosNaTela == 0, dedos.quantos == 0 { parada = nil }
    }

    private func aplicar(porque: String) {
        defer { atualizarMortos() }
        let novo = dedos.ativo
        guard novo != ativo else { return }
        ativo = novo
        guard let m = modelo else { return }
        if let b = novo {
            parada = nil
            let st = m.replica.segurar(paraTras: b.paraTras(invertido: invertido))
            segurou = st == QUALL_STATUS_OK
            DiarioDoTeleprompter.dizer("segurar: \(b.rotulo), \(b.legenda(invertido: invertido))"
                + (invertido ? " (invertido)" : "") + " (\(porque)) → \(SessaoDoTeleprompter.nome(st))")
            if st != QUALL_STATUS_OK {
                // Recusado: os dedos morrem, para nenhum deles apertar sozinho quando a sessão voltar.
                if st == QUALL_STATUS_PROTOCOL { recusado = true }
                dedos.pararTodos()
                ativo = nil
                parada = .recusado
            }
        } else {
            let st = m.replica.soltar()
            DiarioDoTeleprompter.dizer("segurar: soltou (\(porque)) → \(SessaoDoTeleprompter.nome(st))")
            segurou = false
        }
        m.recarregar()
    }

    /// O estado mudou: `segurando` caiu com o dedo no botão?
    func estadoMudou(_ e: EstadoDoTeleprompter) {
        if let b = ativo, segurou, !e.segurando {
            segurou = false
            dedos.pararTodos()
            ativo = nil
            // O fim do texto só desliga `rolando` segurando o botão que **avança** — o de baixo, ou
            // o de cima com a inversão.
            parada = (!b.paraTras(invertido: invertido) && e.posicao >= 0.999) ? .fimDoTexto : .parou
            atualizarMortos()
            DiarioDoTeleprompter.dizer("segurar: o texto parou com o dedo em \(b.rotulo) (segurando voltou a false"
                + (parada == .fimDoTexto ? ", no fim do texto" : "") + "); os dedos não voltam a valer até sair")
        }
        // Um prompter que passou a entender (atualizado, ou outro) destrava o modo.
        if recusado, e.parEntendeSegurar, ativo == nil { recusado = false }
    }

    func motivoDesligado(_ m: ModeloDoTeleprompter) -> String {
        if !m.fase.conectada || m.avisoDeSemPar != nil { return "sem sessão" }
        if m.estado.parVistoHaMs == nil { return "esperando o prompter" }
        if !m.estado.parEntendeSegurar || recusado { return "o prompter não entende o segurar" }
        return "?"
    }
}

/// **O painel de toque dos dois botões**, em UIKit: vários dedos de uma vez, e o toque cancelado
/// pelo sistema — o que o SwiftUI não dá com essa precisão. Cada `UITouch` é um dedo; a metade de
/// cima é "Rolar para cima", a de baixo "Rolar para baixo", com uma faixa morta no meio.
final class PainelDeToqueDeSegurar: UIView {
    weak var controle: ControleDeSegurar?
    var espaco: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("só por código") }

    private func botao(em p: CGPoint) -> BotaoDeSegurar? {
        guard bounds.contains(p) else { return nil }
        if p.y < bounds.midY - espaco / 2 { return .cima }
        if p.y > bounds.midY + espaco / 2 { return .baixo }
        return nil
    }

    private func dedo(_ t: UITouch) -> Int { ObjectIdentifier(t).hashValue }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { controle?.encostou(dedo(t), em: botao(em: t.location(in: self))) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { controle?.moveu(dedo(t), para: botao(em: t.location(in: self))) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { controle?.tirou(dedo(t)) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { controle?.tirou(dedo(t)) }
    }
}

struct PainelDeToque: UIViewRepresentable {
    let controle: ControleDeSegurar
    let espaco: CGFloat

    func makeUIView(context: Context) -> PainelDeToqueDeSegurar {
        let v = PainelDeToqueDeSegurar(frame: .zero)
        v.controle = controle
        v.espaco = espaco
        return v
    }

    func updateUIView(_ v: PainelDeToqueDeSegurar, context: Context) {
        v.controle = controle
        v.espaco = espaco
    }
}

/// **O modo "Segurar para rolar"**: só dois botões grandes, um em cima do outro, ocupando a tela;
/// no alto, o estado da conexão, a velocidade ajustada (só para ler), uma saída pequena e, logo
/// abaixo dela, "Inverter botões" — os dois pedem um segundo toque, para não trocar sem querer.
struct ModoSegurar: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    @ObservedObject var controle: ControleDeSegurar
    let sair: () -> Void
    @State private var confirmandoSaida = false
    @State private var confirmandoInversao = false

    private static let espaco: CGFloat = 16

    var body: some View {
        let ligado = controle.habilitado(modelo)
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(modelo.fase.conectada && modelo.avisoDeSemPar == nil ? Estilo.conectado : Estilo.noAr)
                        .frame(width: 10, height: 10)
                    Text(tituloDaConexao).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Button(confirmandoSaida ? tr("Sair do modo?") : tr("Sair")) {
                        if confirmandoSaida { sair() } else {
                            confirmandoSaida = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmandoSaida = false }
                        }
                    }
                    .font(.footnote.weight(confirmandoSaida ? .semibold : .regular))
                    .foregroundColor(confirmandoSaida ? Estilo.aguardandoTexto : .secondary)
                    .accessibilityHint(confirmandoSaida ? tr("Toque de novo para sair do modo segurar")
                                                        : tr("Pede confirmação antes de sair do modo segurar"))
                }
                HStack(spacing: 8) {
                    Text(tr("%.2f linhas/s", modelo.estado.velocidade))
                        .font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
                    Spacer()
                    botaoInverter
                }
            }
            // **Altura fixa**: uma faixa que entrasse ou saísse empurraria os botões sob o dedo, e um
            // dedo parado perto do meio cairia na faixa morta — um soltar que ninguém fez.
            Text(mensagem(ligado: ligado) ?? " ")
                .font(.callout.weight(.semibold)).foregroundColor(Estilo.aguardandoTexto)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
                .accessibilityHidden(mensagem(ligado: ligado) == nil)
            ZStack {
                VStack(spacing: ModoSegurar.espaco) {
                    visual(.cima, ligado: ligado)
                    visual(.baixo, ligado: ligado)
                }
                PainelDeToque(controle: controle, espaco: ModoSegurar.espaco)
            }
        }
        .padding(16)
        .onChange(of: modelo.estado) { controle.estadoMudou($0) }
        // A fase mudou (queda que virou falha, desconectar) ou a tela fechou: sem edição nenhuma aqui
        // — o `peer_lost` já veio, ou a saída do modo já soltou.
        .onDisappear { controle.esquecerDedos(porque: "o modo saiu da tela") }
    }

    /// **"Inverter botões"** (pedido de 14/09 à tarde): pequeno, no canto, perto do "Sair", com a
    /// marca de ligado. Protegido como o "Sair": o primeiro toque pergunta ("Trocar os botões?"), o
    /// segundo, em até 3 s, troca. **Com um dedo num botão de rolar, fica desligado até soltar** — e a
    /// pergunta pendente cai.
    private var botaoInverter: some View {
        let pode = controle.podeInverter
        return Button {
            guard pode else { return }
            if confirmandoInversao {
                confirmandoInversao = false
                controle.trocarInversao(porque: "o botão da tela")
            } else {
                confirmandoInversao = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmandoInversao = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: controle.invertido ? "checkmark.square.fill" : "square")
                Text(confirmandoInversao ? tr("Trocar os botões?") : tr("Inverter botões"))
            }
        }
        .font(.footnote.weight(confirmandoInversao || controle.invertido ? .semibold : .regular))
        .foregroundColor(confirmandoInversao ? Estilo.aguardandoTexto : (controle.invertido ? Estilo.acentoClaro : .secondary))
        .disabled(!pode)
        .opacity(pode ? 1 : 0.4)
        .onChange(of: pode) { if !$0 { confirmandoInversao = false } }
        .accessibilityLabel(tr("Inverter botões"))
        .accessibilityValue(controle.invertido ? tr("ligado") : tr("desligado"))
        .accessibilityHint(confirmandoInversao ? tr("Toque de novo para trocar o sentido dos dois botões")
                                               : tr("Pede confirmação antes de trocar o sentido dos dois botões"))
    }

    private var tituloDaConexao: String {
        switch modelo.fase {
        case let .conectada(par): return modelo.avisoDeSemPar == nil ? (par.isEmpty ? tr("Conectado") : par) : tr("Prompter sem sinal")
        case .semPar: return tr("Conexão perdida — tentando de novo")
        default: return tr("Conectando…")
        }
    }

    /// Uma frase só, a mais importante primeiro. **Os textos da tabela da §6** (`docs/teleprompter-
    /// ajustes-locais.md`, literais nas quatro telas): "Atualize o app do prompter para usar este
    /// modo", "O texto parou. Solte e aperte de novo." e "O texto chegou ao fim.". Os outros são
    /// desta tela, para casos que a tabela não cobre.
    private func mensagem(ligado: Bool) -> String? {
        let e = modelo.estado
        switch controle.parada {
        case .fimDoTexto: return tr("O texto chegou ao fim.")
        case .parou: return tr("O texto parou. Solte e aperte de novo.")
        case .recusado where ligado: return tr("O prompter não aceitou o aperto. Solte e aperte de novo.")
        default: break
        }
        if !ligado {
            if !modelo.fase.conectada || modelo.avisoDeSemPar != nil { return tr("Sem conexão com o prompter: os botões voltam quando ela voltar.") }
            if e.parVistoHaMs == nil { return tr("Esperando o prompter…") }
            return tr("Atualize o app do prompter para usar este modo")
        }
        // Os avisos do núcleo que o painel mostra (o relógio adiantado, a outra versão, o comando
        // que não chegou): no modo, eles explicariam um botão apertado sem o texto andar.
        if let a = modelo.avisoDoProtocolo { return a }
        if let a = modelo.avisoDeConfirmacao { return a }
        if controle.dedosMortos > 0, controle.ativo == nil { return tr("Solte e aperte de novo.") }
        // Um play normal (do painel ou do prompter) segue rolando dentro do modo: soltar não o para,
        // porque ninguém está segurando. Apertar e soltar um botão para.
        if e.rolando, !e.segurando, controle.ativo == nil {
            return tr("O texto está rolando pelo play normal. Aperte e solte um botão para parar.")
        }
        // Segurando "Rolar para cima" no começo, o texto para ali com `rolando` até soltar: sem
        // aviso (a assimetria aceita da §6 — muda só o aviso).
        return nil
    }

    private func visual(_ b: BotaoDeSegurar, ligado: Bool) -> some View {
        let apertado = controle.ativo == b
        // A seta e o rótulo ficam; a legenda diz o que o botão faz agora (com ou sem a inversão).
        let legenda = b.legenda(invertido: controle.invertido)
        return VStack(spacing: 8) {
            Image(systemName: b.simbolo).font(.system(size: 64, weight: .bold))
            Text(b.rotulo).font(.title2.weight(.bold))
            Text(legenda).font(.footnote.weight(controle.invertido ? .semibold : .regular)).opacity(0.85)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(apertado ? Estilo.acento : Estilo.acento.opacity(ligado ? 0.55 : 0.18))
        .cornerRadius(22)
        .opacity(ligado ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([b.rotulo, legenda].joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(ligado ? (apertado ? tr("segurando") : "") : tr("desligado"))
        // Com o VoiceOver, segurar é "toque duas vezes e segure" (o toque passa direto ao ponto do
        // botão). Não provado com o VoiceOver ligado.
        .accessibilityHint(tr("Toque duas vezes e segure para rolar; solte para parar"))
    }
}

/// A opção, no painel do controle.
struct OpcaoSegurarParaRolar: View {
    @Binding var ligada: Bool

    var body: some View {
        Toggle(isOn: $ligada) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Segurar para rolar")).font(.subheadline.weight(.semibold))
                Text(tr("A tela fica só com dois botões grandes: segure para rolar, solte para parar. "
                        + "Na velocidade ajustada. Fica guardado neste aparelho."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// **A bancada do segurar**, no controle, pelo mesmo caminho do toque (`ControleDeSegurar`):
///
/// - `--segurar-bancada baixo:1500,cima:1500`: liga o modo e, com a sessão de pé e o prompter
///   falando, aperta cada botão pelo tempo dado — `encostou` e `tirou`, as funções que o painel de
///   toque chama —, com o estado no diário antes e depois;
/// - `--segurar-velocidade V`: antes, a velocidade (uma edição de fora do modo, para a posição andar
///   à vista). Sozinha, sem `--segurar-bancada`, só põe a velocidade (para devolvê-la depois);
/// - `--segurar-sair`: o último aperto termina com o app saindo com o dedo no botão (`exit`): o
///   prompter tem de parar;
/// - `--segurar-fechar`: o último aperto termina com **a tela do controle fechando** com o dedo no
///   botão (o "Voltar"): o `peer_lost` vem antes de qualquer outra edição, e o prompter para;
/// - `--segurar-play`: as duas regras do play (`ModeloDoTeleprompter.pedirRolando`) — antes dos
///   apertos, "Rolar" duas vezes (a segunda, com o texto já rolando, não pode sair) e "Pausar"; no
///   meio de cada aperto, "Rolar" e "Pausar" (nenhum pode sair durante o segurar);
/// - `--segurar-modo ligado|desligado`: só grava a opção (para devolver o aparelho como estava);
/// - `--segurar-inverter sim|nao`: "Inverter botões", pela mesma troca do botão da tela
///   (`ControleDeSegurar.trocarInversao`), antes de tudo;
/// - `--segurar-trocar-segurando`: no meio de cada aperto, tenta trocar a inversão com o dedo no
///   botão — não pode valer, e o sentido segue o mesmo.
///
/// **O que ela não prova**: o dedo de verdade no vidro — os toques do UIKit, dois dedos, o toque
/// cancelado pelo sistema.
enum BancadaDoSegurar {
    private static var consumida = false

    static func ligar(_ m: ModeloDoTeleprompter, _ c: ControleDeSegurar, modo: @escaping (Bool) -> Void,
                      fecharTela: @escaping () -> Void) {
        guard !consumida else { return }
        consumida = true
        let args = CommandLine.arguments
        func valor(_ chave: String) -> String? {
            guard let i = args.firstIndex(of: chave), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let v = valor("--segurar-modo"), v == "ligado" || v == "desligado" {
            modo(v == "ligado")
            DiarioDoTeleprompter.dizer("bancada: segurar para rolar \(v)")
        }
        if let v = valor("--segurar-inverter"), v == "sim" || v == "nao" {
            c.trocarInversao(para: v == "sim", porque: "--segurar-inverter")
            DiarioDoTeleprompter.dizer("bancada: inverter botões \(c.invertido ? "ligado" : "desligado")")
        }
        let trocar = args.contains("--segurar-trocar-segurando")
        let roteiro = valor("--segurar-bancada")
        let velocidade = valor("--segurar-velocidade").flatMap { Double($0) }
        guard roteiro != nil || velocidade != nil else { return }
        // "baixo:1500" é um dedo; "baixo+cima:5000" são dois — o segundo sai primeiro.
        let passos: [([BotaoDeSegurar], Double)] = (roteiro ?? "").split(separator: ",").compactMap { p in
            let partes = p.split(separator: ":")
            guard partes.count == 2, let ms = Double(partes[1]) else { return nil }
            let bs = partes[0].split(separator: "+").compactMap { BotaoDeSegurar(rawValue: String($0)) }
            guard bs.count == 1 || bs.count == 2 else { return nil }
            return (bs, ms / 1000)
        }
        let sair = args.contains("--segurar-sair")
        let fechar = args.contains("--segurar-fechar")
        let play = args.contains("--segurar-play")
        if roteiro != nil { modo(true) }
        DiarioDoTeleprompter.dizer("bancada: segurar \(passos.map { "\($0.0.map(\.rawValue).joined(separator: "+")) \($0.1) s" })"
            + (sair ? ", saindo do app no último" : "") + (fechar ? ", fechando a tela no último" : "")
            + (play ? ", com o play de fora" : "") + (trocar ? ", tentando trocar a inversão no meio" : "")
            + (c.invertido ? " — botões invertidos" : ""))
        let t = Thread { [weak m, weak c] in
            func estado() -> String {
                var s = ""
                DispatchQueue.main.sync {
                    guard let e = m?.replica.estado() else { return }
                    s = String(format: "rolando=%@ para_tras=%@ segurando=%@ posicao=%.4f par_entende_segurar=%@ sem_confirmacao=%@",
                               "\(e.rolando)", "\(e.paraTras)", "\(e.segurando)", e.posicao, "\(e.parEntendeSegurar)",
                               e.semConfirmacaoHaMs.map { "\($0) ms" } ?? "nulo")
                }
                return s
            }
            // A sessão de pé e o outro lado falando (até 60 s).
            let limite = Date().addingTimeInterval(60)
            var pronto = false
            while Date() < limite, !pronto {
                DispatchQueue.main.sync { pronto = (m?.fase.conectada ?? false) && m?.replica.estado()?.parVistoHaMs != nil }
                if !pronto { Thread.sleep(forTimeInterval: 0.1) }
            }
            Thread.sleep(forTimeInterval: 1.5)
            if let velocidade { DispatchQueue.main.sync { m?.definirVelocidade(velocidade) } ; Thread.sleep(forTimeInterval: 1) }
            DiarioDoTeleprompter.dizer("bancada: segurar: pronto=\(pronto); \(estado())")
            if play {
                for (v, rotulo) in [(true, "Rolar"), (true, "Rolar de novo, já rolando"), (false, "Pausar")] {
                    DispatchQueue.main.sync { m?.pedirRolando(v) }
                    Thread.sleep(forTimeInterval: 0.6)
                    DiarioDoTeleprompter.dizer("bancada: segurar: play de fora: \(rotulo); \(estado())")
                }
                Thread.sleep(forTimeInterval: 1)
            }
            for (i, (bs, s)) in passos.enumerated() {
                let dedo = 900 + i
                if bs.count == 2 {
                    // Dois dedos (a revisão adversarial de 14/09): o segundo vale; se o texto parar
                    // sozinho no meio, tirar o segundo não pode fazer o primeiro apertar de novo.
                    let (a, b) = (bs[0], bs[1])
                    DispatchQueue.main.sync { c?.encostou(dedo, em: a) }
                    Thread.sleep(forTimeInterval: 0.3)
                    DispatchQueue.main.sync { c?.encostou(dedo + 50, em: b) }
                    Thread.sleep(forTimeInterval: 0.3)
                    DiarioDoTeleprompter.dizer("bancada: segurar: dois dedos, \(a.rotulo) e depois \(b.rotulo); \(estado())")
                    Thread.sleep(forTimeInterval: max(0, s - 0.6))
                    DiarioDoTeleprompter.dizer("bancada: segurar: dois dedos, antes de tirar o segundo; \(estado())")
                    DispatchQueue.main.sync { c?.tirou(dedo + 50) }
                    Thread.sleep(forTimeInterval: 1.0)
                    DiarioDoTeleprompter.dizer("bancada: segurar: tirou o segundo (\(b.rotulo)), o primeiro segue em \(a.rotulo); \(estado())")
                    DispatchQueue.main.sync { c?.tirou(dedo) }
                    Thread.sleep(forTimeInterval: 0.6)
                    DiarioDoTeleprompter.dizer("bancada: segurar: tirou o primeiro; \(estado())")
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }
                let b = bs[0]
                DispatchQueue.main.sync { c?.encostou(dedo, em: b) }
                Thread.sleep(forTimeInterval: 0.3)
                DiarioDoTeleprompter.dizer("bancada: segurar: apertou \(b.rotulo); \(estado())")
                if play || trocar {
                    Thread.sleep(forTimeInterval: max(0, s / 2 - 0.3))
                    if play {
                        DispatchQueue.main.sync { m?.pedirRolando(true); m?.pedirRolando(false) }
                        DiarioDoTeleprompter.dizer("bancada: segurar: Rolar e Pausar de fora, segurando; \(estado())")
                    }
                    if trocar {
                        var valeu = false
                        DispatchQueue.main.sync { valeu = c?.trocarInversao(porque: "bancada, com o dedo em \(b.rotulo)") ?? false }
                        DiarioDoTeleprompter.dizer("bancada: segurar: trocar a inversão com o dedo no botão "
                            + "\(valeu ? "VALEU (errado)" : "não valeu"); \(estado())")
                    }
                    Thread.sleep(forTimeInterval: max(0, s / 2))
                } else {
                    Thread.sleep(forTimeInterval: max(0, s - 0.3))
                }
                DiarioDoTeleprompter.dizer("bancada: segurar: antes de soltar \(b.rotulo); \(estado())")
                if sair, i == passos.count - 1 {
                    DiarioDoTeleprompter.dizer("bancada: segurar: saindo do app com o dedo em \(b.rotulo)")
                    Thread.sleep(forTimeInterval: 0.2)
                    exit(0)
                }
                if fechar, i == passos.count - 1 {
                    DiarioDoTeleprompter.dizer("bancada: segurar: fechando a tela do controle com o dedo em \(b.rotulo)")
                    DispatchQueue.main.sync { fecharTela() }
                    Thread.sleep(forTimeInterval: 1.0)
                    DiarioDoTeleprompter.dizer("bancada: segurar: 1 s depois de fechar; \(estado())")
                    break
                }
                DispatchQueue.main.sync { c?.tirou(dedo) }
                Thread.sleep(forTimeInterval: 0.6)
                DiarioDoTeleprompter.dizer("bancada: segurar: soltou \(b.rotulo); \(estado())")
                Thread.sleep(forTimeInterval: 1.0)
                DiarioDoTeleprompter.dizer("bancada: segurar: 1 s depois; \(estado())")
            }
            DiarioDoTeleprompter.dizer("bancada: segurar terminado")
        }
        t.name = "quall.teleprompter.segurar"
        t.start()
    }
}
