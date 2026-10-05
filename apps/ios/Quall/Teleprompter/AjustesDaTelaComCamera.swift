import SwiftUI
import UIKit

// ================================================================================================
// Os ajustes locais da tela "Teleprompter com câmera" (R5, `docs/teleprompter-com-camera.md`
// §2.5 e §6). **Locais**, como os do prompter (`AjustesLocais`): `UserDefaults` deste aparelho,
// fora do salvo do núcleo, e nada no fio. O controle remoto não os vê nem os muda.
// ================================================================================================

// `LadoDoTexto`, a conta da lente e a da divisão moram em `DivisaoDaTelaComCamera.swift` desde
// 30/09 (puras, testadas em `Testes/rodar.sh`); aqui fica só a ponte do UIKit.

extension InterfaceDaTela {
    init(_ o: UIInterfaceOrientation) {
        switch o {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        case .unknown: self = .desconhecida
        @unknown default: self = .desconhecida
        }
    }
}

extension LadoDoTexto {
    /// Onde a lente frontal está agora, neste aparelho (`daLente(ipad:interface:)`).
    static func daLente(idioma: UIUserInterfaceIdiom, interface: UIInterfaceOrientation) -> LadoDoTexto {
        daLente(ipad: idioma == .pad, interface: InterfaceDaTela(interface))
    }
}

/// Os ajustes locais da tela com câmera, vivos nela.
final class AjustesDaTelaComCamera: ObservableObject {
    static let chaveDoEspelho = "teleprompter.camera.previa-espelhada"
    static let chaveDoLado = "teleprompter.camera.lado-do-texto"

    /// A chave da fração de cada forma: `teleprompter.camera.divisao.retrato` e `.paisagem` são as
    /// de antes de 30/09, com o mesmo texto (o gravado continua valendo), e `.empilhada-larga` é a
    /// nova (`FormaDaDivisao`).
    static func chaveDaDivisao(_ forma: FormaDaDivisao) -> String { "teleprompter.camera.divisao." + forma.rawValue }

    /// Nenhum dos dois lados fica menor que isto (`DivisaoDaTelaComCamera.minimo`).
    static let minimo = DivisaoDaTelaComCamera.minimo

    /// "Prévia como espelho": **ligado por padrão**. Só a prévia; a rede nunca espelha, e não há
    /// ajuste para isso (§6).
    @Published private(set) var previaEspelhada: Bool
    @Published private(set) var lado: LadoDoTexto
    /// Quanto da tela é do texto, ao longo do eixo da divisão. **50/50 por padrão**, e um valor por
    /// forma (`FormaDaDivisao`): a divisão de retrato não é a de paisagem, e desde 30/09 a do
    /// empilhado na tela larga (o iPhone deitado no automático) tem a sua.
    @Published private(set) var fracoes: [FormaDaDivisao: Double]
    /// Lidos e gravados no `UserDefaults` (o produto), ou só em memória, nos padrões (o retrato de
    /// bancada "r5", 30/09: a foto mostra o automático e o 50/50 qualquer que seja o ajuste guardado
    /// no aparelho, e não muda o ajuste da pessoa).
    private let gravados: Bool

    init(gravados: Bool = true) {
        self.gravados = gravados
        let d = gravados ? UserDefaults.standard : nil
        previaEspelhada = d?.object(forKey: AjustesDaTelaComCamera.chaveDoEspelho) as? Bool ?? true
        lado = d?.string(forKey: AjustesDaTelaComCamera.chaveDoLado).flatMap(LadoDoTexto.init(rawValue:)) ?? .automatico
        var f: [FormaDaDivisao: Double] = [:]
        for forma in FormaDaDivisao.allCases {
            f[forma] = AjustesDaTelaComCamera.limitar(d?.object(forKey: AjustesDaTelaComCamera.chaveDaDivisao(forma)) as? Double ?? 0.5)
        }
        fracoes = f
    }

    static func limitar(_ f: Double) -> Double { DivisaoDaTelaComCamera.limitar(f) }

    func fracaoDoTexto(_ forma: FormaDaDivisao) -> Double { fracoes[forma] ?? 0.5 }

    /// A borda arrastada. Durante o arrasto não grava; ao soltar, grava.
    func dividir(_ f: Double, forma: FormaDaDivisao, gravar: Bool) {
        let v = AjustesDaTelaComCamera.limitar(f)
        if fracoes[forma] != v { fracoes[forma] = v }
        guard gravar else { return }
        if gravados { UserDefaults.standard.set(v, forKey: AjustesDaTelaComCamera.chaveDaDivisao(forma)) }
        DiarioDoTeleprompter.dizer(String(format: "tela com câmera: divisão (%@) em %.0f %% de texto",
                                          forma.nome, v * 100))
    }

    func espelhar(_ ligado: Bool) {
        previaEspelhada = ligado
        if gravados { UserDefaults.standard.set(ligado, forKey: AjustesDaTelaComCamera.chaveDoEspelho) }
        DiarioDoTeleprompter.dizer("tela com câmera: prévia como espelho \(ligado ? "ligada" : "desligada")")
    }

    func escolherLado(_ l: LadoDoTexto) {
        lado = l
        if gravados { UserDefaults.standard.set(l.rawValue, forKey: AjustesDaTelaComCamera.chaveDoLado) }
        DiarioDoTeleprompter.dizer("tela com câmera: lado do texto \(l.nome)")
    }
}

/// A seção da folha de Ajustes que só a tela com câmera tem.
struct SecaoDaTelaComCamera: View {
    @ObservedObject var ajustes: AjustesDaTelaComCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { ajustes.previaEspelhada }, set: { ajustes.espelhar($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Prévia como espelho")).font(.subheadline.weight(.semibold))
                    Text(tr("Só a imagem desta tela. Quem recebe a câmera a vê sempre sem espelho."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("Lado do texto")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker(tr("Lado do texto"), selection: Binding(get: { ajustes.lado },
                                                               set: { ajustes.escolherLado($0) })) {
                        ForEach(LadoDoTexto.allCases) { Text($0.rotulo).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                // 30/09: o automático põe o texto do lado da câmera só com ela em cima ou embaixo; com
                // ela de lado (o iPhone deitado, o iPad em pé), em cima (`LadoDoTexto.doAutomatico`).
                Text(tr("No automático o texto fica junto da câmera, para o olhar de quem lê ficar perto dela; "
                     + "com a câmera de lado (o iPhone deitado, o iPad em pé), o texto fica em cima e a prévia embaixo. "
                     + "Para pôr lado a lado, "
                     + "ou se a câmera deste aparelho estiver em outra borda, escolha aqui."))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A mesma preferência local no espelhamento, na câmera e nas duas telas do prompter.
struct SeletorDaTelaAcesa: View {
    var somenteLeitura = false
    @AppStorage(TelaAcesa.chaveDaPreferencia) private var manterTelaLigada = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $manterTelaLigada) {
                Text(tr("Manter tela ligada"))
                    .font(Estilo.corpo(.subheadline, .semibold))
            }
            Text(tr("Evita o bloqueio automático enquanto o Quall está na tela."))
                .font(Estilo.corpo(.footnote))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .allowsHitTesting(!somenteLeitura)
        .onChange(of: manterTelaLigada) { _ in TelaAcesa.reafirmar() }
    }
}

/// A opção também fica ao alcance de quem já está transmitindo ou gravando com a câmera.
struct MenuDaTelaAcesa: View {
    @AppStorage(TelaAcesa.chaveDaPreferencia) private var manterTelaLigada = true

    var body: some View {
        Menu {
            Toggle(tr("Manter tela ligada"), isOn: $manterTelaLigada)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Estilo.texto)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Estilo.superficie))
                .overlay(Circle().stroke(Estilo.contorno, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(tr("Opções da tela"))
        .onChange(of: manterTelaLigada) { _ in TelaAcesa.reafirmar() }
    }
}

/// **A tela acesa**, com dono. `isIdleTimerDisabled` é um global do app: uma tela que sai não pode
/// apagar o pedido da que entra. A câmera, o espelhamento e o prompter respeitam a preferência;
/// o receptor e o controle mantêm seus pedidos independentes. Só vale no primeiro plano.
enum TelaAcesa {
    static let chaveDaPreferencia = "tela.manterLigada"
    private static var donos = [String: Bool]()
    private static var primeiroPlano = false

    static var manterTelaLigada: Bool {
        UserDefaults.standard.object(forKey: chaveDaPreferencia) as? Bool ?? true
    }

    static func pedir(_ dono: String, respeitandoPreferencia: Bool = true) {
        donos[dono] = respeitandoPreferencia
        reafirmar()
    }

    static func soltar(_ dono: String) {
        donos.removeValue(forKey: dono)
        reafirmar()
    }

    /// O ciclo do app avisa uma vez, para nenhuma tela deixar um pedido ativo no segundo plano.
    static func atualizarPrimeiroPlano(_ ativo: Bool) {
        primeiroPlano = ativo
        reafirmar()
    }

    /// Reaplica na volta ao primeiro plano e quando a preferência muda com uma tela aberta.
    static func reafirmar() {
        UIApplication.shared.isIdleTimerDisabled = primeiroPlano
            && donos.values.contains { !$0 || manterTelaLigada }
    }
}
