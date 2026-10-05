import SwiftUI
import UIKit

/// **A orientação do prompter** — um ajuste deste aparelho, e só dele.
///
/// # Por que existe (14/09/2026)
///
/// O usuário pôs um aparelho deitado, com a tela para cima, num suporte de teleprompter de verdade
/// (vidro a 45° sobre a câmera). Deitado, o sensor não decide a orientação: a tela ficou em
/// retrato e o texto saiu de lado no vidro. No iPhone deitado acontece o mesmo. Com a escolha
/// presa, a interface gira para ela sem depender do sensor nem do bloqueio de rotação.
///
/// # As opções — nomes literais, os mesmos do Android
///
/// | opção | a interface | o aparelho, visto por quem olha a tela |
/// |---|---|---|
/// | Automática (padrão) | a do sensor: retrato e as duas paisagens (as quatro no iPad) | — |
/// | Retrato | `.portrait` | em pé |
/// | Paisagem | `.landscapeRight` | topo à esquerda, botão de início à direita |
/// | Paisagem invertida | `.landscapeLeft` | topo à direita |
///
/// # Local, e não do teleprompter
///
/// Gravada no `UserDefaults` deste app (``OrientacaoDoPrompter/chave``), **fora** do salvo do
/// núcleo: decisão do usuário — "ajuste no aparelho local". O controle não a vê nem a muda, e ela
/// não viaja pelo fio: o mesmo roteiro pode estar num prompter deitado e noutro em pé.
///
/// # A trava
///
/// `Orientacao.prender`, o mesmo caminho da tela cheia do receptor: a máscara que o `DelegadoDoApp`
/// responde ao sistema passa a ser **só** a escolhida, e a cena pede o giro — no iOS 16,
/// `requestGeometryUpdate`; no iOS 15, a orientação do aparelho por KVC seguida de
/// `attemptRotationToDeviceOrientation` (não há API pública lá). Ao sair da tela do prompter a
/// máscara volta à do `Info.plist`, e o resto do app não herda a escolha.
///
/// O giro refaz o layout do roteiro inteiro (a largura muda): ver `VistaDoRoteiro`.
enum OrientacaoDoPrompter: String, CaseIterable, Identifiable {
    case automatica
    case retrato
    case paisagem
    case paisagemInvertida = "paisagem-invertida"

    var id: String { rawValue }

    /// Os nomes na tela, literais.
    var nome: String {
        switch self {
        case .automatica: return "Automática"
        case .retrato: return "Retrato"
        case .paisagem: return "Paisagem"
        case .paisagemInvertida: return "Paisagem invertida"
        }
    }

    /// O nome na tela, no idioma escolhido (`nome` fica em PT: é o que o diário e a bancada leem).
    var rotulo: String {
        switch self {
        case .automatica: return tr("Automática")
        case .retrato: return tr("Retrato")
        case .paisagem: return tr("Paisagem")
        case .paisagemInvertida: return tr("Paisagem invertida")
        }
    }

    /// `nil`: não prende — vale a do `Info.plist`, e o sensor decide.
    var mascara: UIInterfaceOrientationMask? {
        switch self {
        case .automatica: return nil
        case .retrato: return .portrait
        case .paisagem: return .landscapeRight
        case .paisagemInvertida: return .landscapeLeft
        }
    }

    var preferida: UIInterfaceOrientation? {
        switch self {
        case .automatica: return nil
        case .retrato: return .portrait
        case .paisagem: return .landscapeRight
        case .paisagemInvertida: return .landscapeLeft
        }
    }

    /// A chave no `UserDefaults` deste app.
    static let chave = "teleprompter.orientacao"

    /// A chave da tela "Teleprompter com câmera" (R5): a escolha dela é **outra**. O prompter comum
    /// costuma ficar deitado sob o vidro, preso em Paisagem; a tela com câmera fica de pé, na mão ou
    /// no tripé, e herdar aquela trava a abriria de lado.
    static let chaveDaTelaComCamera = "teleprompter.camera.orientacao"

    /// A escolha gravada neste aparelho; sem nenhuma, a automática.
    static var gravada: OrientacaoDoPrompter { gravada(chave: chave) }

    static func gravada(chave: String) -> OrientacaoDoPrompter {
        UserDefaults.standard.string(forKey: chave).flatMap(OrientacaoDoPrompter.init(rawValue:)) ?? .automatica
    }

    /// Onde a interface está agora, para o diário: é a testemunha de que o giro aconteceu, ao lado
    /// da captura da tela.
    static func interfaceAgora() -> String {
        let cenas = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let cena = cenas.first { $0.activationState == .foregroundActive } ?? cenas.first
        let nome: String
        switch cena?.interfaceOrientation {
        case .portrait?: nome = "retrato (.portrait)"
        case .portraitUpsideDown?: nome = "retrato invertido (.portraitUpsideDown)"
        case .landscapeRight?: nome = "paisagem, topo à esquerda (.landscapeRight)"
        case .landscapeLeft?: nome = "paisagem invertida, topo à direita (.landscapeLeft)"
        default: nome = "desconhecida"
        }
        let tela = cena?.windows.first?.bounds.size ?? .zero
        return "\(nome), janela \(Int(tela.width))x\(Int(tela.height)), aparelho=\(UIDevice.current.orientation.rawValue)"
    }
}

/// A escolha viva da tela do prompter: a folha de ajustes a mostra, e a bancada a move.
///
/// # Quando o sistema recusa
///
/// Medido em 14/09 no iPad A16 (iPadOS 26.6): as três travas voltaram recusadas com *"The current
/// windowing mode does not allow for programmatic changes to interface orientation"* — no modo de
/// janelas do iPadOS, um app que aceita multitarefa não escolhe a orientação. Decisão do usuário,
/// no mesmo dia: **gira-se só o texto** (``giroDoTexto``, `GiroDoTexto`), relativo à orientação
/// que a interface tem; os botões seguem o aparelho. A recusa também aparece no seletor
/// (``recusada``), e não só no diário.
final class EscolhaDeOrientacao: ObservableObject {
    /// Onde a escolha fica gravada: a do prompter comum, ou a da tela com câmera.
    let chave: String
    @Published private(set) var atual: OrientacaoDoPrompter
    /// A última escolha que o sistema recusou, se a recusa ainda vale.
    @Published private(set) var recusada: OrientacaoDoPrompter?
    /// Quanto a vista do texto gira dentro da tela (graus, horário) porque o sistema recusou a
    /// escolha: ver `GiroDoTexto`. Zero enquanto a trava do sistema funciona.
    @Published private(set) var giroDoTexto: Double = 0

    /// `inicial`: começa nesta escolha **sem gravá-la** (o retrato de bancada da R5, 30/09, que usa
    /// uma chave de jogar fora); sem ela, a gravada na chave.
    init(chave: String = OrientacaoDoPrompter.chave, inicial: OrientacaoDoPrompter? = nil) {
        self.chave = chave
        atual = inicial ?? OrientacaoDoPrompter.gravada(chave: chave)
    }

    /// A pessoa escolheu (ou a bancada, por ela): grava neste aparelho e aplica na hora.
    func escolher(_ o: OrientacaoDoPrompter, por quem: String) {
        atual = o
        UserDefaults.standard.set(o.rawValue, forKey: chave)
        aplicar(por: quem)
    }

    /// Ao abrir a tela, e ao voltar do segundo plano.
    ///
    /// A recusa anterior **não** é apagada no pedido, só quando o sistema mostrar que girou (ou com
    /// a Automática, que não pede nada): apagá-la e esperar a recusa nova deixaria o texto piscar
    /// na orientação errada entre um e outro.
    func aplicar(por quem: String) {
        if let presa = presaPelaGravacao {
            // Gravando, a interface fica onde estava (§5.2): a escolha da pessoa vale ao parar.
            Orientacao.prender(EscolhaDeOrientacao.mascara(de: presa), preferida: presa) { [weak self] porque in
                DispatchQueue.main.async {
                    // Ainda gravando (uma recusa atrasada depois de parar não acende o aviso).
                    guard let self, self.presaPelaGravacao != nil else { return }
                    let primeira = !self.gravandoSemTrava
                    self.gravandoSemTrava = true
                    DiarioDoTeleprompter.dizer("orientação: gravando, o sistema não prendeu a interface — \(porque)"
                        + (primeira ? "; a interface segue o aparelho e o arquivo fica no ângulo do começo (§8.12.2)" : ""))
                }
            }
            DiarioDoTeleprompter.dizer("orientação: gravando, presa em \(presa.rawValue) (\(quem)); a escolha "
                                       + "\(atual.nome) vale ao parar")
            return
        }
        let o = atual
        if o.preferida == nil { recusada = nil; reavaliarGiro() }
        let recusa: (String) -> Void = { [weak self] porque in
            DispatchQueue.main.async {
                if self?.atual == o { self?.recusada = o; self?.reavaliarGiro() }
                DiarioDoTeleprompter.dizer("orientação: o sistema não girou para \(o.nome) — \(porque)")
            }
        }
        if let m = o.mascara, let p = o.preferida {
            Orientacao.prender(m, preferida: p, aoRecusar: recusa)
        } else {
            Orientacao.soltar(aoRecusar: recusa)
        }
        DiarioDoTeleprompter.dizer("orientação: \(o.nome) (\(quem)); máscara \(Orientacao.descricao); "
                                   + "interface agora: \(OrientacaoDoPrompter.interfaceAgora())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if self.atual == o, let p = o.preferida, EscolhaDeOrientacao.interface() == p, self.recusada != nil {
                // O sistema girou (a pessoa mudou de modo de janelas, ou girou o aparelho até lá).
                self.recusada = nil
                self.reavaliarGiro()
            }
            DiarioDoTeleprompter.dizer("orientação: 1 s depois, interface: \(OrientacaoDoPrompter.interfaceAgora())"
                                       + (self.giroDoTexto != 0 ? String(format: "; o texto gira %.0f° dentro da vista",
                                                                         self.giroDoTexto) : ""))
        }
    }

    /// O ângulo da vista do texto, de novo: a escolha recusada, relativa à interface **agora**.
    func reavaliarGiro() {
        var novo = 0.0
        if let o = recusada, let pedida = o.preferida {
            novo = GiroDoTexto.giro(pedida: pedida, interface: EscolhaDeOrientacao.interface())
        }
        guard novo != giroDoTexto else { return }
        giroDoTexto = novo
        DiarioDoTeleprompter.dizer(String(format: "orientação: o texto gira %.0f° dentro da vista (pedida %@, "
                                          + "interface %@)", novo, recusada?.nome ?? "nenhuma",
                                          OrientacaoDoPrompter.interfaceAgora()))
    }

    private static func interface() -> UIInterfaceOrientation {
        let cenas = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let cena = cenas.first { $0.activationState == .foregroundActive } ?? cenas.first
        return cena?.interfaceOrientation ?? .portrait
    }

    // --- a trava da gravação (R5 fase 3, `docs/teleprompter-com-camera.md` §5.2) ------------------

    /// A orientação da interface quando a gravação começou; `nil` sem gravação.
    private(set) var presaPelaGravacao: UIInterfaceOrientation?

    /// **Gravando, o sistema recusou a trava** (o iPad no modo de janelas do iPadOS 26, bancada de
    /// 27/09, §8.12.2). O comportamento fica definido: a interface segue o aparelho como qualquer app
    /// nesse modo (a prévia junto, o texto do lado da lente), e **o arquivo e a rede ficam no ângulo
    /// do toque em Gravar** (`DonoDaCaptura.congelarAngulo`, que não depende da trava). A faixa diz
    /// isso enquanto grava e a interface estiver fora do ângulo do começo (`textoSemTrava`).
    @Published private(set) var gravandoSemTrava = false

    static var textoSemTrava: String {
        tr("O iPad não deixa travar a tela neste modo de janelas: a gravação continua no "
           + "ângulo do começo, e a imagem gravada fica de lado até o iPad voltar.")
    }

    /// **Gravando, a orientação trava** onde a interface está (decisão do Pessoa Exemplo, 24/09: um arquivo
    /// só, de tamanho fixo). A escolha da pessoa não muda (nem é gravada por isto); volta a valer em
    /// `soltarDaGravacao`. No iPad em modo de janelas o sistema pode recusar a trava: o ângulo da
    /// conexão está congelado do mesmo jeito (`DonoDaCaptura.congelarAngulo`), e o arquivo não muda
    /// de tamanho — só a interface gira.
    func prenderPelaGravacao() {
        let agora = EscolhaDeOrientacao.interface()
        presaPelaGravacao = agora
        aplicar(por: "a gravação começou")
    }

    func soltarDaGravacao() {
        guard presaPelaGravacao != nil else { return }
        presaPelaGravacao = nil
        gravandoSemTrava = false
        aplicar(por: "a gravação parou")
    }

    static func mascara(de o: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch o {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    /// A tela do prompter saiu: o resto do app volta ao `Info.plist`. A escolha gravada fica.
    func soltar() {
        presaPelaGravacao = nil
        gravandoSemTrava = false
        recusada = nil
        giroDoTexto = 0
        Orientacao.soltar { porque in
            DispatchQueue.main.async { DiarioDoTeleprompter.dizer("orientação: o sistema não soltou — \(porque)") }
        }
    }
}

/// O seletor "Orientação", na folha de ajustes **do prompter** (o controle não tem).
struct SeletorDeOrientacao: View {
    @ObservedObject var escolha: EscolhaDeOrientacao

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("Orientação")).font(.subheadline.weight(.semibold))
                Spacer()
                Picker(tr("Orientação"), selection: Binding(get: { escolha.atual },
                                                        set: { escolha.escolher($0, por: "ajustes") })) {
                    ForEach(OrientacaoDoPrompter.allCases) { Text($0.rotulo).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Text(tr("Só deste aparelho. Deitado sob o vidro o sensor não decide: escolha Paisagem "
                    + "(topo à esquerda) ou Paisagem invertida (topo à direita)."))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let o = escolha.recusada {
                Text(tr("Neste modo de janelas o iPad não deixa o app girar a tela para %@: o texto foi "
                        + "girado dentro da vista, e os botões seguem o aparelho.", o.rotulo))
                    .font(.caption.weight(.semibold)).foregroundColor(Estilo.aguardandoTexto)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// **A bancada da orientação**, sem toque — lida uma vez, pela primeira tela do prompter:
///
/// - `--orientacao automatica|retrato|paisagem|paisagem-invertida`: vale **como a escolha da
///   pessoa**, e por isso é gravada — ao contrário dos argumentos de `BancadaDoTeleprompter`. É o
///   que deixa provar, numa segunda abertura **sem** o argumento, que a escolha ficou no aparelho.
/// - `--girar paisagem,paisagem-invertida,retrato`: um roteiro sintético de 100 KB, parado, sem
///   espelho, fonte 48, salto para 0,3; depois, a cada 7 s, a próxima orientação da lista, com a
///   linha `bancada: orientação: foto N (…)` antes de cada captura (`idevicescreenshot`), para ler
///   pelos pixels ("Linha N") onde a linha de leitura ficou. `--girar-rolando`: o mesmo, com o
///   texto rolando a 2,5 linhas/s, para contar quadros perdidos no giro.
/// - `--mostrar-endereco`: abre a folha do endereço e do PIN 2 s depois de a tela aparecer. (Era
///   `--mostrar-qr` até o QR sair, em 24/09/2026.)
enum BancadaDaOrientacao {
    private static var consumida = false

    private static func valor(_ chave: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: chave), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// A orientação pedida por `--orientacao`, se houver.
    static func escolha() -> OrientacaoDoPrompter? {
        valor("--orientacao").flatMap(OrientacaoDoPrompter.init(rawValue:))
    }

    /// Uma vez por vida do app: devolve `false` depois da primeira.
    static func consumir() -> Bool {
        defer { consumida = true }
        return !consumida
    }

    static func ligar(_ m: ModeloDoTeleprompter, _ e: EscolhaDeOrientacao, abrirEndereco: @escaping () -> Void) {
        let args = CommandLine.arguments
        if args.contains("--mostrar-endereco") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { abrirEndereco() }
        }
        guard let lista = valor("--girar") else { return }
        let giros = lista.split(separator: ",").compactMap { OrientacaoDoPrompter(rawValue: String($0)) }
        let rolando = args.contains("--girar-rolando")
        DiarioDoTeleprompter.dizer("bancada: giros \(giros.map(\.nome)) \(rolando ? "com o texto rolando" : "com o texto parado")")
        let t = Thread { [weak m, weak e] in
            Thread.sleep(forTimeInterval: 2.5)
            DispatchQueue.main.sync {
                m?.definirRolando(false)
                m?.definirEspelho(false)
                m?.definirFonte(48)
                m?.definirMargem(0.1)
            }
            if let m {
                let marca = "Corrida \(Int(Date().timeIntervalSince1970 * 1000))\n"
                let roteiro = marca + BancadaDoTeleprompter.sintetico(100_000 - marca.utf8.count)
                m.replica.definirTexto(roteiro)
                DispatchQueue.main.async { m.recarregar() }
            }
            Thread.sleep(forTimeInterval: 2.5)
            DispatchQueue.main.sync {
                m?.saltar(0.3)
                if rolando { m?.definirVelocidade(2.5); m?.definirRolando(true) }
            }
            Thread.sleep(forTimeInterval: 2.5)
            DiarioDoTeleprompter.dizer("bancada: orientação: foto 1 (antes dos giros, \(e?.atual.nome ?? "?"))")
            DispatchQueue.main.sync { CapturaDaBancada.tirar("orientacao-1") }
            for (i, o) in giros.enumerated() {
                Thread.sleep(forTimeInterval: 4)
                DispatchQueue.main.sync { e?.escolher(o, por: "--girar") }
                Thread.sleep(forTimeInterval: 3)
                DiarioDoTeleprompter.dizer("bancada: orientação: foto \(i + 2) (\(o.nome))")
                DispatchQueue.main.sync { CapturaDaBancada.tirar("orientacao-\(i + 2)") }
            }
            Thread.sleep(forTimeInterval: 4)
            if rolando { DispatchQueue.main.async { m?.definirRolando(false) } }
            DiarioDoTeleprompter.dizer("bancada: giros terminados")
        }
        t.name = "quall.teleprompter.giros"
        t.start()
    }
}
