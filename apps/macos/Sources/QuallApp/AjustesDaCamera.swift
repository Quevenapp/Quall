import AppKit
import QuallCaptureKit
import QuallIdiomaKit
import SwiftUI

/// **A janela "Ajustes da câmera"** (R9, `docs/controles-de-camera.md` §4.2): uma janela própria, como a
/// do "Controle do teleprompter", porque ela precisa falar com o dono vivo — o `DonoDaCamera.vigente`,
/// que é o da câmera comum (Espelhar com uma câmera) ou o da tela R5 (Texto com a câmera); as duas nunca
/// estão abertas juntas.
///
/// - Abre pelo botão redondo "Ajustes da câmera" junto da prévia (`BotaoDosAjustesDaCamera`).
/// - É marcada (`JanelasDeAjustes`, tipo `.ajustesDaCamera`): as teclas digitadas nela não tocam o
///   texto do prompter, e a barra de menus a esconde junto da principal.
/// - Sem câmera aberta, diz isso; com a câmera fechando, volta a dizer.
struct JanelaDosAjustesDaCamera: View {
    static let id = "quall.ajustes-da-camera"
    @StateObject private var modelo = ModeloDosAjustesDaCamera()
    @State private var aba: AbaDosAjustes = .exposicao

    var body: some View {
        VStack(spacing: 0) {
            if let d = modelo.dono, d.montado, let caps = d.capacidades {
                PainelDosAjustesDaCamera(
                    nome: d.nomeDaCamera,
                    plano: PlanoDoPainel.doMac(caps),
                    ajustes: d.ajustes,
                    pilula: d.pilula,
                    recado: d.recadoDosAjustes,
                    controladoPor: d.controladoPor,
                    aba: $aba,
                    aoMudar: { d.mudarAjustes($0, origem: "painel") },
                    aoRestaurar: { d.restaurarAutomatico(origem: "painel") },
                    aoEfeitos: { DonoDaCamera.mostrarEfeitosDeVideoDoSistema() },
                    oferecerMeus: MeusAjustes.oferecer(guardado: d.meusAjustes, corrente: d.ajustes, caps),
                    aoUsarMeus: { d.usarMeusAjustes(origem: "painel") })
            } else {
                VStack(spacing: 10) {
                    Text(TextosDosAjustes.titulo).font(Estilo.titulo(20)).foregroundColor(Estilo.texto)
                    Text(T("Nenhuma câmera aberta. Abra uma câmera em Espelhar ou em Texto com a câmera."))
                        .font(.system(size: 13)).foregroundColor(Estilo.texto2)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(width: PainelDosAjustesDaCamera.largura, height: 200)
            }
            LinhaDoControleRemoto()
        }
        .background(Estilo.fundo)
        // O título no idioma da vez: o `Window` da cena o escreve uma vez só, na abertura.
        .navigationTitle(TextosDosAjustes.titulo)
        .background(JanelaEscura())
        .background(MarcaDaJanelaDeAjustes(tipo: .ajustesDaCamera))
        .onAppear { Registro.compartilhado.linha("APP CAMERA ajustes: a janela abriu (câmera presente=\(modelo.dono != nil))") }
    }
}

/// O dono vigente e as mudanças dele, para a janela (que não tem o `aoMudar`, de quem abriu o dono).
final class ModeloDosAjustesDaCamera: ObservableObject {
    @Published private(set) var dono: DonoDaCamera?
    private var observador: NSObjectProtocol?

    init() {
        dono = DonoDaCamera.vigente
        observador = NotificationCenter.default.addObserver(forName: DonoDaCamera.ajustesMudaram, object: nil,
                                                            queue: .main) { [weak self] _ in
            guard let self else { return }
            // Republica sempre: o dono é o mesmo objeto e as propriedades dele mudaram.
            self.objectWillChange.send()
            self.dono = DonoDaCamera.vigente
        }
    }

    deinit {
        if let observador { NotificationCenter.default.removeObserver(observador) }
    }
}

/// **O painel, só a vista** (§4.3), com valores simples. Quatro abas no alto, sem rolar; "Restaurar
/// automático" no pé de todas. Os controles que o macOS não oferece aparecem apagados com a linha do
/// §3.5; um grupo inteiro sem nada (ISO e obturador) é uma linha só.
struct PainelDosAjustesDaCamera: View {
    static let largura: CGFloat = 440

    let nome: String
    let plano: PlanoDoPainel
    let ajustes: AjustesDaCamera
    let pilula: String?
    let recado: String?
    /// "Controlado por <aparelho>" (R9b): um receptor mudou a câmera há pouco.
    var controladoPor: String? = nil
    @Binding var aba: AbaDosAjustes
    let aoMudar: (AjustesDaCamera) -> Void
    let aoRestaurar: () -> Void
    let aoEfeitos: () -> Void
    /// "Usar meus ajustes" (decisão de 07/10, `MeusAjustes.oferecer`): a câmera abre no automático, e o
    /// botão traz de volta o último ajuste guardado dela. Desligado por padrão (os retratos antigos).
    var oferecerMeus = false
    var aoUsarMeus: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(nome.isEmpty ? TextosDosAjustes.titulo : nome)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Estilo.texto)
                .lineLimit(1)
            // O recado de 3 s (§2.1) e a pílula do ⌥-clique (§4.4).
            Group {
                if let controladoPor {
                    Label(TextosDaCameraRemota.controladoPor(controladoPor), systemImage: "dot.radiowaves.left.and.right")
                        .foregroundColor(Estilo.acentoClaro)
                } else if let recado {
                    Text(recado).foregroundColor(Estilo.aguardandoTexto)
                } else if let pilula {
                    Label(pilula, systemImage: "lock.fill").foregroundColor(Estilo.texto2)
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .frame(height: 18)
            .padding(.top, 2)

            Segmentado(titulo: T("Grupo"), opcoes: AbaDosAjustes.allCases.map { ($0.nome, $0) }, escolha: $aba)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 14) {
                switch aba {
                case .exposicao: abaDaExposicao
                case .isoEObturador: linha(plano.linhaDoIsoEObturador ?? "")
                case .balanco: abaDoBalanco
                case .foco: abaDoFoco
                }
            }
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .padding(.top, 16)

            Divider().overlay(Estilo.contorno)
            HStack(spacing: 10) {
                Button(TextosDosAjustes.restaurar, action: aoRestaurar)
                    .buttonStyle(.quall(.secundario, altura: 32))
                    .disabled(ajustes.ehPadrao && pilula == nil)
                if oferecerMeus {
                    Button(TextosDosAjustes.usarMeus, action: aoUsarMeus)
                        .buttonStyle(.quall(.secundario, altura: 32))
                }
                Spacer(minLength: 0)
                Button(T("Efeitos de vídeo do sistema…"), action: aoEfeitos)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Estilo.acentoClaro)
                    .help(T("O painel do macOS: Centro do palco, Retrato, Luz de estúdio. Vale para a câmera em todos os apps."))
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: Self.largura, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    // MARK: as abas

    @ViewBuilder private var abaDaExposicao: some View {
        controle(T("Exposição"), plano.exposicaoManual) {
            HStack(spacing: 6) {
                opcao(T("Auto"), escolhida: true, disponivel: true) {}
                opcao(T("Manual"), escolhida: false, disponivel: plano.exposicaoManual.disponivel) {}
            }
        }
        controle(T("Compensação (EV)"), plano.ev) {
            Text(T("0 EV")).font(Estilo.mono(12)).foregroundColor(Estilo.texto3)
        }
        controle(TextosDosAjustes.travarExposicao, plano.travaExposicao) {
            Interruptor(titulo: TextosDosAjustes.travarExposicao, ligado: Binding(
                get: { ajustes.travaExposicao },
                set: { v in var a = ajustes; a.travaExposicao = v; aoMudar(a) }), pequeno: true)
        }
        controle(T("Anti-cintilação"), plano.antiCintilacao) {
            HStack(spacing: 6) {
                ForEach([T("Auto"), "50 Hz", "60 Hz", T("Desligada")], id: \.self) { o in
                    opcao(o, escolhida: o == T("Auto"), disponivel: plano.antiCintilacao.disponivel) {}
                }
            }
        }
    }

    @ViewBuilder private var abaDoBalanco: some View {
        let grade = plano.gradeDoBalanco
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<2, id: \.self) { l in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { c in
                        let (o, disponivel) = grade[l * 3 + c]
                        opcao(o.nome, escolhida: o == .auto, disponivel: disponivel, largura: 120) {}
                    }
                }
            }
            ForEach(plano.limitesDoBalanco, id: \.self) { linha($0) }
        }
        controle(TextosDosAjustes.travarBalanco, plano.travaBalanco) {
            Interruptor(titulo: TextosDosAjustes.travarBalanco, ligado: Binding(
                get: { ajustes.travaBalanco },
                set: { v in var a = ajustes; a.travaBalanco = v; aoMudar(a) }), pequeno: true)
        }
    }

    @ViewBuilder private var abaDoFoco: some View {
        if let fixo = plano.linhaDoFocoFixo {
            linha(fixo)
            linha(plano.notaDoToque)
        } else {
            HStack(spacing: 6) {
                opcao(T("Auto"), escolhida: ajustes.foco == .auto, disponivel: true) {
                    var a = ajustes; a.foco = .auto; aoMudar(a)
                }
                opcao(T("Travado"), escolhida: ajustes.foco == .travado, disponivel: plano.focoTravado.disponivel) {
                    var a = ajustes; a.foco = .travado; aoMudar(a)
                }
                opcao(T("Manual"), escolhida: false, disponivel: plano.focoManual.disponivel) {}
            }
            if let l = plano.focoTravado.limite { linha(l) }
            if let l = plano.focoManual.limite { linha(l) }
            linha(plano.notaDoToque, cor: plano.toqueDisponivel ? Estilo.texto2 : Estilo.texto3)
        }
    }

    // MARK: as peças

    private func controle<C: View>(_ titulo: String, _ c: ControleNaTela, @ViewBuilder _ conteudo: () -> C) -> some View {
        PecasDaCamera.controle(titulo, disponivel: c.disponivel, limite: c.limite, conteudo)
    }

    private func linha(_ texto: String, cor: Color = Estilo.texto3) -> some View {
        PecasDaCamera.linha(texto, cor: cor)
    }

    private func opcao(_ rotulo: String, escolhida: Bool, disponivel: Bool, largura: CGFloat? = nil,
                       acao: @escaping () -> Void) -> some View {
        PecasDaCamera.opcao(rotulo, escolhida: escolhida, disponivel: disponivel, largura: largura, acao: acao)
    }
}

/// **As peças dos dois painéis** "Ajustes da câmera": o da câmera deste Mac (R9) e o da câmera do outro lado
/// (R9b, `PainelRemotoDaCamera`). Um controle com título à esquerda e a linha do limite embaixo, a linha de
/// texto e a opção (um botão que fica aceso quando escolhido).
enum PecasDaCamera {
    /// Um controle com título à esquerda; apagado, a linha do limite embaixo.
    static func controle<C: View>(_ titulo: String, disponivel: Bool, limite: String?,
                                  @ViewBuilder _ conteudo: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(titulo).font(.system(size: 13, weight: .medium))
                    .foregroundColor(disponivel ? Estilo.texto : Estilo.texto3)
                Spacer(minLength: 8)
                conteudo().disabled(!disponivel)
            }
            if let limite { linha(limite) }
        }
    }

    static func linha(_ texto: String, cor: Color = Estilo.texto3) -> some View {
        Text(texto).font(.system(size: 12)).foregroundColor(cor).fixedSize(horizontal: false, vertical: true)
    }

    static func opcao(_ rotulo: String, escolhida: Bool, disponivel: Bool, largura: CGFloat? = nil,
                      acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            Text(rotulo)
                .font(.system(size: 12, weight: escolhida ? .semibold : .regular))
                .foregroundColor(escolhida ? .white : (disponivel ? Estilo.texto : Estilo.texto3))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: largura ?? 56, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(escolhida ? Estilo.acento : Estilo.superficieAlta.opacity(disponivel ? 1 : 0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!disponivel)
        .accessibilityLabel(rotulo + (disponivel ? "" : T(", indisponível")))
    }
}

// MARK: - a opção do controle remoto (R9b)

/// **"Permitir controle remoto da câmera"** (R9b, `docs/controle-remoto-da-camera.md` §12, item 1), no pé da
/// janela "Ajustes da câmera" do Mac que filma: é onde a pessoa ajusta a câmera no Mac, e a janela abre pela
/// mesma engrenagem na câmera comum e em Texto com a câmera. Desligada por padrão; vale para as duas.
struct LinhaDoControleRemoto: View {
    /// Nos retratos, o valor de exemplo; no app, o guardado.
    var ligadaNoRetrato: Bool?
    @State private var ligada = PermissaoDoControleRemoto.ligada

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(TextosDaCameraRemota.permitir).font(.system(size: 13, weight: .medium)).foregroundColor(Estilo.texto)
                Spacer(minLength: 8)
                Interruptor(titulo: TextosDaCameraRemota.permitir, ligado: Binding(
                    get: { ligadaNoRetrato ?? ligada },
                    set: { v in
                        ligada = v
                        PermissaoDoControleRemoto.ligada = v
                    }), pequeno: true)
            }
            PecasDaCamera.linha(T("Quem recebe esta câmera (outro aparelho com o Quall Studio, ou o OBS) pode mudar estes "
                                  + "ajustes. Vence quem mexer por último."))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: PainelDosAjustesDaCamera.largura, alignment: .leading)
        .background(Estilo.superficie)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - o botão e a pílula junto da prévia

extension DonoDaCamera {
    /// **O que vai sobre a prévia**, na ordem: "Controlado por <aparelho>" (R9b, enquanto o núcleo disser),
    /// o recado de 3 s (§2.1), a pílula do ⌥-clique (§4.4) e a pouca luz (§3.1).
    var pilulaSobreAPrevia: (texto: String, icone: String)? {
        if let nome = controladoPor { return (TextosDaCameraRemota.controladoPor(nome), "dot.radiowaves.left.and.right") }
        if let r = recadoDosAjustes { return (r, "lock.fill") }
        if let p = pilula { return (p, "lock.fill") }
        if let l = poucaLuz { return (l, "sun.min") }
        return nil
    }
}

/// **O botão "Ajustes da câmera"** (§4.1): redondo, a engrenagem (`gearshape`, decisão do Pessoa Exemplo no §4.1: na R5 ela se distingue do menu de ajustes do teleprompter, que segue com `slider.horizontal.3`), junto da prévia. Abre a
/// janela própria. Sobre a imagem, o vidro preto a 85 % (`docs/telas-estudio.md` §8).
struct BotaoDosAjustesDaCamera: View {
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Estilo.texto)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.black.opacity(0.85)))
                .overlay(Circle().stroke(Estilo.contorno, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(EstiloApertado())
        .accessibilityLabel(TextosDosAjustes.titulo)
        .help(TextosDosAjustes.titulo)
    }
}

/// A pílula do ⌥-clique (§4.4), o recado de 3 s (§2.1) e o "Controlado por" (R9b), sobre a prévia: vidro
/// preto a 85 %.
struct PilulaDaCamera: View {
    let texto: String
    var icone = "lock.fill"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icone).font(.system(size: 10, weight: .bold))
            // A da pouca luz (§3.1) é uma frase inteira: até duas linhas.
            Text(texto).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(Estilo.texto)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 24)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.85)))
        .accessibilityElement(children: .combine)
    }
}
