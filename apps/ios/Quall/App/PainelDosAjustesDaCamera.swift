import SwiftUI
import AVFoundation
import UIKit

/// **O painel "Ajustes da câmera"** (R9, `docs/controles-de-camera.md` §4.2–§4.3): uma vista própria
/// por cima da tela, na mesma janela, **sem véu e sem diálogo**. Não é a `.sheet` (que no iOS 15 ocupa
/// a altura toda, e cujo toque fora fecha em vez de chegar à prévia) nem a `folhaEscura` (que escurece
/// a prévia que a pessoa está julgando). O fundo é opaco (`Estilo.fundo`); fora dele, nada.
///
/// Quem o põe na tela decide onde (§4.2): na câmera comum, na metade de baixo em pé e na metade
/// direita deitado; na R5, em cima da metade do texto. Fecha pelo "Pronto" ou pelo ícone de novo.
///
/// **Não rola**: os quatro grupos são abas, e cada aba cabe no iPhone 7 em pé (375 × 667 pt: a metade
/// de baixo tem ~333 pt). Por isso **o texto tem tamanho fixo** (`.system(size:)`, sem tipo dinâmico):
/// o espaço é contado. A conta, em pé, na metade de baixo: margens 10 + leitura 14 + 6 + abas 30 + 8 +
/// a aba mais alta (Exposição: escolha 30 + 8 + EV 34 + 8 + trava 30 + 8 + anti-cintilação 30 + 2 +
/// linha 13 = 163) + 8 + pé 32 + 10 ≈ 281 pt. Na R5 do iPhone 7 o texto tem ~277 pt no 50/50, e o
/// painel não desce abaixo de 280 (`alturaMinima`).
///
/// **Um painel para dois lados** (R9b, `docs/controle-remoto-da-camera.md` §12): o mesmo painel serve
/// à câmera deste aparelho (`ControlesDaCamera`) e à câmera de quem filma, vista do receptor
/// (`ControleRemotoDaCamera`). Ele não lê mais as capacidades do `AVCaptureDevice`: lê o
/// `MoldeDoPainel` do modelo (o que a câmera oferece, as faixas e quem limita), que o local monta
/// da câmera (`MoldeDoPainel.local`, o painel de sempre) e o remoto das capacidades que chegaram.
struct PainelDaCamera<Modelo: ModeloDoPainelDaCamera>: View {
    @ObservedObject var controles: Modelo
    let fechar: () -> Void

    @State private var aba: Aba

    /// `abaInicial`: o retrato de bancada abre cada aba sem toque.
    init(controles: Modelo, abaInicial: Aba = .exposicao, fechar: @escaping () -> Void) {
        self.controles = controles
        self.fechar = fechar
        _aba = State(initialValue: abaInicial)
    }

    /// A altura abaixo da qual o painel não cabe sem rolar (a conta do cabeçalho, com folga).
    static var alturaMinima: CGFloat { AbaDoPainelDaCamera.alturaMinima }

    typealias Aba = AbaDoPainelDaCamera

    private typealias R = RegrasDosControles
    private var a: AjustesDaCamera { controles.ajustes }
    private var m: MoldeDoPainel { controles.molde }
    /// O miolo apagado: a câmera ainda não montou, ou o aparelho que filma não permite o controle
    /// remoto (os valores continuam à vista).
    private var apagado: Bool { !controles.prontos || controles.bloqueio != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            linhaDoAlto
                .padding(.bottom, 6)
            abas
                .padding(.bottom, 8)
            Group {
                switch aba {
                case .exposicao: abaDaExposicao
                case .isoEObturador: abaDoIsoEObturador
                case .balanco: abaDoBalanco
                case .foco: abaDoFoco
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(apagado)
            .opacity(controles.bloqueio != nil ? 0.5 : 1)
            pe
                .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundColor(Estilo.texto)
        .background(Estilo.fundo.ignoresSafeArea())
        .overlay(alignment: .top) { Rectangle().fill(Estilo.contorno).frame(height: 1) }
        // O espaço é contado: nenhum tipo dinâmico aqui dentro (os `.system(size:)` já não escalam;
        // isto pega o que vier do sistema, como o `Toggle`).
        .environment(\.dynamicTypeSize, .large)
        .onAppear {
            controles.lerDeVolta(true)
            Diagnostico.nota("APP CAMERA painel dos ajustes: aberto")
        }
        .onDisappear {
            controles.lerDeVolta(false)
            Diagnostico.nota("APP CAMERA painel dos ajustes: fechado")
        }
        .onChange(of: aba) { Diagnostico.nota("APP CAMERA painel dos ajustes: aba \($0.rawValue)") }
    }

    // --- as fontes, fixas ------------------------------------------------------------------------

    private static func letra(_ tamanho: CGFloat, _ peso: Font.Weight = .regular) -> Font {
        .system(size: tamanho, weight: peso)
    }

    // --- o alto: o que a câmera diz ter usado (§3.6) ----------------------------------------------

    @ViewBuilder
    private var linhaDoAlto: some View {
        if let t = controles.bloqueio ?? controles.aviso ?? controles.divergencia ?? controles.poucaLuz {
            Text(t)
                .font(Self.letra(11, .semibold))
                .foregroundColor(Estilo.aguardandoTexto)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 14)
        } else {
            Text(controles.prontos ? R.linhaDaLeitura(controles.leitura) : controles.textoAntesDePronto)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Estilo.texto2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 14)
                .accessibilityLabel(tr("A câmera está usando %@", R.linhaDaLeitura(controles.leitura)))
        }
    }

    private var abas: some View {
        HStack(spacing: 4) {
            ForEach(Aba.allCases, id: \.self) { x in
                Button(action: { aba = x }) {
                    Text(x == .isoEObturador ? m.tituloDaAbaDoIso : x.rotulo)
                        .font(Self.letra(12, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundColor(aba == x ? .white : Estilo.texto2)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(aba == x ? Estilo.acento : Estilo.superficie))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.toque)
                .accessibilityAddTraits(aba == x ? [.isSelected] : [])
            }
        }
    }

    /// O pé: "Restaurar automático", "Usar meus ajustes" quando há o que recuperar (§2, 07/10: a
    /// câmera abre no automático e o último manual fica guardado), e o "Pronto". Os dois textos
    /// encolhem a letra antes de quebrar: o pé tem a altura contada (32 pt), e no iPhone 7 em pé, ou na
    /// metade do texto da R5 deitada, os três juntos encostam na largura.
    private var pe: some View {
        HStack(spacing: 12) {
            Button(action: { controles.restaurar() }) {
                Text(tr("Restaurar automático"))
                    .font(Self.letra(13, .semibold))
                    .foregroundColor(Estilo.acentoClaro)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.toque)
            .disabled(apagado)
            if controles.meusAjustesDisponiveis {
                Button(action: { controles.usarMeusAjustes() }) {
                    Text(tr("Usar meus ajustes"))
                        .font(Self.letra(13, .semibold))
                        .foregroundColor(Estilo.acentoClaro)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.toque)
                .disabled(apagado)
            }
            Spacer(minLength: 8)
            Button(action: fechar) {
                Text(tr("Pronto"))
                    .font(Self.letra(14, .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 32)
                    .background(Capsule().fill(Estilo.acento))
            }
            .buttonStyle(.toque)
            .fixedSize()
        }
    }

    // --- Exposição ------------------------------------------------------------------------------

    private var abaDaExposicao: some View {
        VStack(alignment: .leading, spacing: 8) {
            Escolha(opcoes: [tr("Auto"), tr("Manual")],
                    escolhida: a.exposicao == .auto ? 0 : 1,
                    apagadas: m.exposicaoManual ? [] : [1]) { i in
                if i == 1 {
                    controles.passarParaManual()
                    aba = .isoEObturador
                } else {
                    controles.mudar([.exposicao]) { $0.exposicao = .auto }
                }
            }
            if a.exposicao == .auto {
                if a.travaExposicao {
                    Rotulado(titulo: m.tituloDoEv, valor: m.textoDoEv(a.ev),
                             apagado: true, linha: R.textoDoEvTravado) { EmptyView() }
                } else {
                    let escala = m.escalaDoEv()
                    Rotulado(titulo: m.tituloDoEv, valor: m.textoDoEv(a.ev),
                             apagado: m.limite(.compensacao) != nil, linha: m.limite(.compensacao)) {
                        Degraus(quantos: escala.count, indice: indiceMaisPerto(escala, a.ev)) { i in
                            controles.mudar([.exposicao]) { $0.ev = escala[i] }
                        }
                    }
                }
                Interruptor(titulo: tr("Travar exposição"), ligado: a.travaExposicao,
                            linha: m.limite(.travaExposicao)) { controles.travarExposicao($0) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Anti-cintilação")).font(Self.letra(12, .medium)).foregroundColor(Estilo.texto3)
                // No iOS sem API (o sistema cuida sozinho): apagada, com a linha do §3.5. Numa câmera
                // remota, os valores que ela oferece (o Android tem os quatro).
                let valores = ["auto", "50", "60", "desligada"]
                Escolha(opcoes: [tr("Auto"), "50 Hz", "60 Hz", tr("Desligada")],
                        escolhida: valores.firstIndex(of: a.antiCintilacao.rawValue) ?? 0,
                        apagadas: Set(valores.indices.filter { !m.antiCintilacao.contains(valores[$0]) })) { i in
                    guard let v = AjustesDaCamera.AntiCintilacao(rawValue: valores[i]) else { return }
                    controles.mudar([.exposicao]) { $0.antiCintilacao = v }
                }
                if let linha = m.limite(.antiCintilacao) {
                    Text(linha).font(Self.letra(11)).foregroundColor(Estilo.texto3)
                }
            }
        }
    }

    // --- ISO e obturador ------------------------------------------------------------------------

    @ViewBuilder
    private var abaDoIsoEObturador: some View {
        if let limite = m.limite(.iso), m.obturador == nil {
            // Um grupo em que nada se aplica é uma linha só (§3.5).
            Text(limite).font(Self.letra(13)).foregroundColor(Estilo.texto2)
                .fixedSize(horizontal: false, vertical: true)
        } else if a.exposicao == .auto {
            VStack(alignment: .leading, spacing: 12) {
                Text(R.textoDePassarParaManual)
                    .font(Self.letra(13))
                    .foregroundColor(Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: { controles.passarParaManual() }) {
                    Text(tr("Passar para Manual"))
                        .font(Self.letra(14, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(Estilo.acento))
                }
                .buttonStyle(.toque)
                .disabled(!m.exposicaoManual)
            }
        } else {
            let isos = m.escalaDoIso()
            let isoAplicado = m.isoAplicado(a.iso)
            // A sugestão contra cintilação é das frações de 1/N s: na escala de 2^v (Windows) não há
            // 1/60 nem 1/120 (R9 §3.1).
            let sugestao = m.obturadorLog2 ? nil
                : R.sugestaoContraCintilacao(a.antiCintilacao, regiao: Locale.current.regionCode)
            let obturadores = m.escalaDoObturador(marcados: sugestao?.fracoes ?? [])
            let nsAplicado = m.obturadorAplicado(a.obturadorNs)
            let iObt = indiceMaisPerto(obturadores.map { Double($0.ns) }, Double(nsAplicado))
            VStack(alignment: .leading, spacing: 10) {
                Rotulado(titulo: m.tituloDoIso, valor: m.iso == nil ? "" : m.textoDoIso(isoAplicado),
                         apagado: m.iso == nil, linha: m.limite(.iso)) {
                    Degraus(quantos: isos.count, indice: indiceMaisPerto(isos, isoAplicado)) { i in
                        controles.mudar([.exposicao]) { $0.iso = isos[i] }
                    }
                }
                Rotulado(titulo: tr("Obturador"),
                         valor: m.obturador == nil ? "" : (m.obturadorLog2 && obturadores.indices.contains(iObt)
                                                            ? obturadores[iObt].texto : R.textoDoObturador(ns: nsAplicado))
                            + ((obturadores.indices.contains(iObt) && obturadores[iObt].semCintilacao) ? " •" : ""),
                         apagado: m.obturador == nil, linha: m.limite(.obturador) ?? sugestao.map { "• " + $0.legenda }) {
                    Degraus(quantos: obturadores.count, indice: iObt) { i in
                        controles.mudar([.exposicao]) { $0.obturadorNs = obturadores[i].ns }
                    }
                }
            }
        }
    }

    // --- Balanço --------------------------------------------------------------------------------

    private var abaDoBalanco: some View {
        let ordem: [AjustesDaCamera.Balanco] = [.auto, .incandescente, .fluorescente, .luzDoDia, .nublado, .kelvin]
        let nomes = [tr("Auto"), tr("Incandescente"), tr("Fluorescente"), tr("Luz do dia"), tr("Nublado"), "Kelvin"]
        let semPresets = m.limite(.presets) != nil
        let semKelvin = m.limite(.kelvin) != nil
        return VStack(alignment: .leading, spacing: 8) {
            // A grade de 2 × 3 (§4.2): o que a câmera não tem fica apagado, e a linha vai embaixo.
            VStack(spacing: 6) {
                ForEach(0..<2) { linha in
                    HStack(spacing: 6) {
                        ForEach(0..<3) { coluna in
                            let i = linha * 3 + coluna
                            let b = ordem[i]
                            Casa(titulo: nomes[i], escolhida: a.balanco == b,
                                 apagada: !m.balanco.contains(b.rawValue)) {
                                controles.escolherBalanco(b)
                            }
                        }
                    }
                }
            }
            if semPresets || semKelvin {
                Text(m.limite(semPresets ? .presets : .kelvin) ?? "")
                    .font(Self.letra(11)).foregroundColor(Estilo.texto3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if a.balanco == .kelvin {
                let escala = m.escalaDoKelvin()
                let pedido = a.kelvin ?? 5500
                let k = escala.min(by: { abs($0 - pedido) < abs($1 - pedido) }) ?? pedido
                Rotulado(titulo: "Kelvin", valor: "\(k) K", apagado: escala.isEmpty, linha: nil) {  // sem-traducao
                    Degraus(quantos: escala.count, indice: escala.firstIndex(of: k) ?? 0) { i in
                        controles.mudar([.balanco]) { $0.kelvin = escala[i] }
                    }
                }
            } else if a.balanco == .auto {
                Interruptor(titulo: tr("Travar balanço"), ligado: a.travaBalanco,
                            linha: m.limite(.travaBalanco)) { controles.travarBalanco($0) }
            }
        }
    }

    // --- Foco -----------------------------------------------------------------------------------

    @ViewBuilder
    private var abaDoFoco: some View {
        if m.focoFixo && controles.prontos {
            Text(R.textoDoFocoFixo).font(Self.letra(13)).foregroundColor(Estilo.texto2)
        } else {
            let semTrava = m.limite(.travaFoco)
            let semManual = m.limite(.focoManual)
            VStack(alignment: .leading, spacing: 8) {
                Escolha(opcoes: [tr("Auto"), tr("Travado"), tr("Manual")],
                        escolhida: [.auto, .travado, .manual].firstIndex(of: a.foco) ?? 0,
                        apagadas: Set([semTrava == nil ? nil : 1, semManual == nil ? nil : 2].compactMap { $0 })) { i in
                    controles.escolherFoco([.auto, .travado, .manual][i])
                }
                if let l = semManual ?? semTrava {
                    Text(l).font(Self.letra(11)).foregroundColor(Estilo.texto3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if a.foco == .manual {
                    // "Perto ↔ Longe": o perto à esquerda. `focoPosicao` 1 é o mais perto (§2), então o
                    // deslizante anda do maior para o menor, de 0,01 em 0,01. Sem metros: o iOS não tem
                    // calibração de distância (§1).
                    let escala = m.escalaDoFoco()
                    let p = a.focoPosicao ?? 0
                    Rotulado(titulo: tr("Perto ↔ Longe"), valor: m.textoDoFoco(p), apagado: false, linha: nil) {
                        Degraus(quantos: escala.count, indice: indiceMaisPerto(escala, p)) { i in
                            controles.mudar([.foco]) { $0.focoPosicao = escala[i] }
                        }
                    }
                }
                if m.limite(.toque) == nil {
                    Text(R.notaDoToque).font(Self.letra(11)).foregroundColor(Estilo.texto3)
                }
            }
        }
    }

    private func indiceMaisPerto(_ v: [Double], _ x: Double) -> Int {
        guard !v.isEmpty else { return 0 }
        return v.indices.min(by: { abs(v[$0] - x) < abs(v[$1] - x) }) ?? 0
    }
}

/// O painel do filmador: a câmera deste aparelho (o nome de antes, para os chamadores do R9).
typealias PainelDosAjustesDaCamera = PainelDaCamera<ControlesDaCamera>

/// As quatro abas (R16), fora do tipo genérico: o retrato de bancada e as telas as nomeiam.
enum AbaDoPainelDaCamera: String, CaseIterable {
    case exposicao = "Exposição"
    case isoEObturador = "ISO e obturador"
    case balanco = "Balanço"
    case foco = "Foco"

    /// O nome na aba, no idioma da interface (o `rawValue` vai ao diário). A de ISO muda com a câmera
    /// ("Ganho e obturador" no Windows): o painel usa `MoldeDoPainel.tituloDaAbaDoIso`.
    var rotulo: String {
        switch self {
        case .exposicao: return tr("Exposição")
        case .isoEObturador: return tr("ISO e obturador")
        case .balanco: return tr("Balanço")
        case .foco: return tr("Foco")
        }
    }

    /// A altura abaixo da qual o painel não cabe sem rolar (a conta do cabeçalho, com folga).
    static let alturaMinima: CGFloat = 288
}

/// **O que o painel precisa de quem ele mostra** (R9b): o filmador (`ControlesDaCamera`, a câmera
/// deste aparelho) e o receptor (`ControleRemotoDaCamera`, a câmera do outro, por pedido). As ações
/// têm o nome das do R9; no receptor cada uma vira um pedido com **só** o que a pessoa mexeu.
extension ModeloDoPainelDaCamera {
    var poucaLuz: String? { nil }
    /// O receptor não mostra "Usar meus ajustes": os ajustes guardados são do aparelho que filma, e
    /// quem os recupera é ele (§2, 07/10).
    var meusAjustesDisponiveis: Bool { false }
    func usarMeusAjustes() {}
}

protocol ModeloDoPainelDaCamera: ObservableObject {
    /// O registro mostrado (no receptor: o aplicado, com o pendente por cima).
    var ajustes: AjustesDaCamera { get }
    /// O que a câmera oferece, as faixas e quem limita.
    var molde: MoldeDoPainel { get }
    /// Há o que mostrar (a câmera montou; no receptor, a câmera do outro respondeu).
    var prontos: Bool { get }
    /// A linha do alto enquanto não está pronto ("Abrindo a câmera…").
    var textoAntesDePronto: String { get }
    var leitura: RegrasDosControles.Leitura { get }
    var divergencia: String? { get }
    var aviso: String? { get }
    /// "Pouca luz: 15 fps…" (§3.1). Só o filmador sabe; no receptor, nula.
    var poucaLuz: String? { get }
    /// Tudo apagado, **com os valores**, e esta linha no alto (o receptor com o controle remoto não
    /// permitido pelo aparelho que filma). Sempre nula no filmador.
    var bloqueio: String? { get }

    func mudar(_ grupos: Set<ControlesDaCamera.Grupo>, _ f: (inout AjustesDaCamera) -> Void)
    func passarParaManual()
    func travarExposicao(_ sim: Bool)
    func travarBalanco(_ sim: Bool)
    func escolherFoco(_ f: AjustesDaCamera.Foco)
    func escolherBalanco(_ b: AjustesDaCamera.Balanco)
    func restaurar()
    /// "Usar meus ajustes" (§2, 07/10): há guardado diferente do padrão e do registro de agora. Só o
    /// filmador; no receptor, sempre `false` (a implementação padrão).
    var meusAjustesDisponiveis: Bool { get }
    /// Aplica o guardado desta câmera pelo caminho de um gesto. No receptor, nada.
    func usarMeusAjustes()
    /// A leitura de volta de 4 Hz, com o painel aberto (§3.6).
    func lerDeVolta(_ sim: Bool)
}

// MARK: - As peças do painel (tamanho fixo)

/// Uma fila de opções exclusivas, no desenho das abas, com opções apagadas (o `Picker` segmentado não
/// apaga uma opção só).
private struct Escolha: View {
    let opcoes: [String]
    let escolhida: Int
    var apagadas: Set<Int> = []
    let escolher: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(opcoes.indices, id: \.self) { i in
                Button(action: { if i != escolhida { escolher(i) } }) {
                    Text(opcoes[i])
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundColor(i == escolhida ? .white : Estilo.texto2)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(i == escolhida ? Estilo.superficieAlta : Estilo.superficie))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(i == escolhida ? Estilo.acentoClaro : Estilo.contorno, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.toque)
                .disabled(apagadas.contains(i))
                .opacity(apagadas.contains(i) ? 0.4 : 1)
                .accessibilityAddTraits(i == escolhida ? [.isSelected] : [])
            }
        }
    }
}

/// Uma casa da grade do balanço.
private struct Casa: View {
    let titulo: String
    let escolhida: Bool
    let apagada: Bool
    let tocar: () -> Void

    var body: some View {
        Button(action: tocar) {
            Text(titulo)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(escolhida ? .white : Estilo.texto2)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(escolhida ? Estilo.superficieAlta : Estilo.superficie))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(escolhida ? Estilo.acentoClaro : Estilo.contorno, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.toque)
        .disabled(apagada)
        .opacity(apagada ? 0.4 : 1)
        .accessibilityAddTraits(escolhida ? [.isSelected] : [])
    }
}

/// Um controle com o título à esquerda e o valor à direita, numa linha, e o controle embaixo; apagado
/// com a linha do §3.5.
private struct Rotulado<Controle: View>: View {
    let titulo: String
    let valor: String
    let apagado: Bool
    let linha: String?
    @ViewBuilder let controle: () -> Controle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(titulo).font(.system(size: 12, weight: .medium)).foregroundColor(Estilo.texto3)
                Spacer(minLength: 4)
                Text(valor).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(apagado ? Estilo.texto3 : Estilo.texto)
            }
            controle()
                .disabled(apagado)
                .opacity(apagado ? 0.4 : 1)
            if let linha {
                Text(linha).font(.system(size: 11)).foregroundColor(Estilo.texto3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Um deslizante **por degrau** (§3.1, §3.2): o índice numa escala, e não um número contínuo.
private struct Degraus: View {
    let quantos: Int
    let indice: Int
    let mudar: (Int) -> Void

    var body: some View {
        if quantos > 1 {
            Slider(value: Binding(get: { Double(max(0, min(indice, quantos - 1))) },
                                  set: { novo in
                                      let i = max(0, min(Int(novo.rounded()), quantos - 1))
                                      if i != indice { mudar(i) }
                                  }),
                   in: 0...Double(quantos - 1), step: 1)
                .tint(Estilo.acento)
                .frame(height: 22)
        } else {
            Color.clear.frame(height: 22)
        }
    }
}

/// Uma trava, com a linha do §3.5 quando a câmera não a oferece.
private struct Interruptor: View {
    let titulo: String
    let ligado: Bool
    let linha: String?
    let mudar: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { ligado }, set: { mudar($0) })) {
                Text(titulo).font(.system(size: 14, weight: .medium))
            }
            .tint(Estilo.acento)
            .frame(minHeight: 30)
            .disabled(linha != nil)
            .opacity(linha != nil ? 0.4 : 1)
            if let linha {
                Text(linha).font(.system(size: 11)).foregroundColor(Estilo.texto3)
            }
        }
    }
}
