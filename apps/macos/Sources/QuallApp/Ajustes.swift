// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import AppKit
import QuallCaptureKit
import QuallIdiomaKit
import QuallNetKit
import SwiftUI

/// **Os Ajustes** (`docs/telas-estudio.md` §7.5): a cena `Settings` (⌘,), aberta também pela
/// engrenagem da barra lateral e pela linha da rede do painel Espelhar. É o lugar do que saiu da tela
/// para ela caber em 880 × 580 (§7.1): "Sair pela rede", "Escala da tela estendida", "60 fps na tela
/// estendida"; e os aparelhos pareados com o Esquecer, e a versão.
///
/// Com uma sessão de pé os ajustes de espelhar ficam apagados, como ficavam na tela inicial: valem
/// para a próxima sessão, e mudar o caminho de uma sessão viva não existe.
struct TelaDeAjustes: View {
    @EnvironmentObject private var emissor: Emissor
    @EnvironmentObject private var receptor: Receptor
    @EnvironmentObject private var teleprompter: Teleprompter
    /// Lido do disco ao abrir a janela, e não a cada desenho (ver `Identidade.haParesConhecidos`).
    @State private var haPares = false

    var body: some View {
        #if QUALL_TELA_ESTENDIDA_FUTURA
        PainelDeAjustes(
            redes: opcoesDeRede,
            rede: $emissor.redeEscolhida,
            legendaDaRede: emissor.redeEscolhida == nil
                ? T("O sistema escolhe o caminho a cada sessão.")
                : T("O vídeo sai só por esta rede. Se o outro aparelho não alcançar este Mac por ela, "
                  + "a sessão não sobe — escolha Automática."),
            escala: $emissor.escalaDaTelaEstendida,
            escalaFixada: emissor.escalaFixadaPelaBancada,
            legendaDaEscala: emissor.escalaFixadaPelaBancada
                ? T("Fixada em %@ pelo argumento --tela-estendida desta abertura.", emissor.escalaEfetiva.rawValue)
                : emissor.escalaDaTelaEstendida == .dobro
                ? T("Letra do tamanho da do Mac. Se a tela do aparelho tem menos de 1060 pixels de altura, o "
                  + "macOS não aceita 2x nela: o monitor é desenhado maior e reduzido para a tela, sem sair 1:1.")
                : T("A tela inteira do aparelho como espaço de trabalho, na resolução dela — a letra fica "
                  + "pequena."),
            a60: $emissor.telaEstendidaA60,
            espelharDesligado: emissor.fase != .inicial,
            haPares: haPares,
            esquecerDesligado: !ocioso,
            versao: TelaDeAjustes.versao,
            aoEsquecer: {
                emissor.esquecerPares()
                haPares = Identidade.haParesConhecidos()
            })
        .onAppear { haPares = Identidade.haParesConhecidos() }
        .onChange(of: emissor.fase) { _ in haPares = Identidade.haParesConhecidos() }
        .background(MarcaDaJanelaDeAjustes(tipo: .ajustes))
        #else
        PainelDeAjustes(
            redes: opcoesDeRede,
            rede: $emissor.redeEscolhida,
            legendaDaRede: emissor.redeEscolhida == nil
                ? T("O sistema escolhe o caminho a cada sessão.")
                : T("O vídeo sai só por esta rede. Se o outro aparelho não alcançar este Mac por ela, "
                  + "a sessão não sobe — escolha Automática."),
            espelharDesligado: emissor.fase != .inicial,
            haPares: haPares,
            esquecerDesligado: !ocioso,
            versao: TelaDeAjustes.versao,
            aoEsquecer: {
                emissor.esquecerPares()
                haPares = Identidade.haParesConhecidos()
            })
        .onAppear { haPares = Identidade.haParesConhecidos() }
        .onChange(of: emissor.fase) { _ in haPares = Identidade.haParesConhecidos() }
        .background(MarcaDaJanelaDeAjustes(tipo: .ajustes))
        #endif
    }

    /// Esquecer com uma sessão de pé deixaria o núcleo regravar o par no fim dela.
    private var ocioso: Bool {
        emissor.fase == .inicial && (receptor.fase == .fechado || receptor.fase == .formulario)
            && teleprompter.tela == .fechada
    }

    /// Automática, as redes com endereço, e a escolhida que sumiu (placa USB fora), dita como tal em
    /// vez de o seletor mudar sozinho para outra.
    private var opcoesDeRede: [(rotulo: String, valor: String?)] {
        var o: [(rotulo: String, valor: String?)] = [(T("Automática"), nil)]
        o += emissor.redes.map { ($0.rotulo, $0.bsd) }
        if let bsd = emissor.redeEscolhida, !emissor.redes.contains(where: { $0.bsd == bsd }) {
            o.append((T("%@ — sem endereço agora", bsd), bsd))
        }
        return o
    }

    static var versao: String {
        let info = Bundle.main.infoDictionary
        let curta = info?["CFBundleShortVersionString"] as? String
        let numero = info?["CFBundleVersion"] as? String
        let app = curta.map { v in T("versão %@", numero.map { "\(v) (\($0))" } ?? v) } ?? T("fora do pacote")
        return T("%@ · protocolo %@", app, NucleoDeRede.versaoDoProtocolo())
    }
}

/// **As janelas de ajustes**, marcadas por elas mesmas ao nascer: os Ajustes (⌘,) e os "Ajustes da
/// câmera" (R9). Os atalhos do teleprompter (`AtalhosDoTeleprompter`) pegam as teclas do app inteiro
/// pela `keyWindow`, e sem esta marca o espaço e as setas digitados numa delas tocariam o texto do
/// prompter aberto na janela principal.
///
/// Até o R9 era uma vaga só (`JanelaDosAjustes.atual`): abrir a segunda janela de ajustes tiraria a
/// marca da primeira. Agora é um conjunto, com o tipo de cada uma (a barra de menus esconde a da
/// câmera junto da principal).
enum JanelasDeAjustes {
    enum Tipo: Equatable {
        case ajustes
        case ajustesDaCamera
        /// A câmera do outro lado (R9b): o mesmo painel, aberto pela engrenagem do vídeo recebido.
        case ajustesDaCameraRemota
    }

    private struct Marcada {
        weak var janela: NSWindow?
        let tipo: Tipo
    }

    private static var marcadas: [Marcada] = []

    static func marcar(_ janela: NSWindow, como tipo: Tipo) {
        marcadas.removeAll { $0.janela == nil || $0.janela === janela }
        marcadas.append(Marcada(janela: janela, tipo: tipo))
    }

    /// A janela é uma das de ajustes: as teclas dela são dela.
    static func ehMarcada(_ janela: NSWindow) -> Bool {
        marcadas.contains { $0.janela === janela }
    }

    static func janela(_ tipo: Tipo) -> NSWindow? {
        marcadas.first { $0.tipo == tipo && $0.janela != nil }?.janela
    }
}

/// Marca a janela que a contém como uma das de ajustes (`JanelasDeAjustes`).
struct MarcaDaJanelaDeAjustes: NSViewRepresentable {
    let tipo: JanelasDeAjustes.Tipo

    func makeNSView(context: Context) -> NSView { Vista(tipo: tipo) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Vista: NSView {
        let tipo: JanelasDeAjustes.Tipo
        init(tipo: JanelasDeAjustes.Tipo) {
            self.tipo = tipo
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { JanelasDeAjustes.marcar(w, como: tipo) }
        }

        /// Fundo que não pega clique.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// **Os Ajustes, só a vista** (§7.5), 560 × 460.
struct PainelDeAjustes: View {
    let redes: [(rotulo: String, valor: String?)]
    @Binding var rede: String?
    let legendaDaRede: String
    #if QUALL_TELA_ESTENDIDA_FUTURA
    @Binding var escala: ModoDoMonitorVirtual.Escala
    let escalaFixada: Bool
    let legendaDaEscala: String
    @Binding var a60: Bool
    #endif
    let espelharDesligado: Bool
    let haPares: Bool
    let esquecerDesligado: Bool
    let versao: String
    let aoEsquecer: () -> Void
    @State private var confirmando = false
    @State private var mostrandoErroDosAvisos = false
    @State private var erroDosAvisos = ""
    @State private var mostrandoErroDasGravacoes = false
    @State private var erroDasGravacoes = ""
    @State private var mostrandoErroDoSite = false

    static let tamanho = CGSize(width: 560, height: 460)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RotuloDeSecao(T("Espelhar")).padding(.leading, 4)
            grupo {
                // O menu embaixo da legenda: o nome de uma rede cabeada é comprido ("Ethernet — AX88179B ·
                // 192.168.57.8") e, ao lado, espremeria a legenda.
                linha(T("Sair pela rede"), legendaDaRede, controleEmbaixo: true) {
                    EscolhaEmMenu(titulo: T("Sair pela rede"), opcoes: redes, escolha: $rede)
                }
    #if QUALL_TELA_ESTENDIDA_FUTURA
                divisor
                linha(T("Escala da tela estendida"), legendaDaEscala) {
                    Segmentado(titulo: T("Escala da tela estendida"),
                               opcoes: [("2x", ModoDoMonitorVirtual.Escala.dobro), ("1x", .umPraUm)],
                               escolha: $escala)
                        .disabled(escalaFixada)
                }
                divisor
                linha(T("60 fps na tela estendida"),
                      T("Mais fluido, e o dobro de dados. Aparelho que não decodifica rápido o bastante mostra a "
                        + "imagem quebrando — aí volte para 30.")) {
                    Interruptor(titulo: T("60 fps na tela estendida"), ligado: $a60)
                }
    #endif
            }
            .disabled(espelharDesligado)
            .padding(.top, 8)

            RotuloDeSecao(T("Pareamento")).padding(.leading, 4).padding(.top, 16)
            grupo {
                linha(T("Aparelhos pareados"),
                      haPares ? T("Os aparelhos que já parearam com este Mac entram sem PIN.")
                              : T("Nenhum aparelho pareado com este Mac.")) {
                    Button(T("Esquecer")) { confirmando = true }
                        .buttonStyle(.quall(.perigo, altura: 30))
                        .disabled(!haPares || esquecerDesligado)
                        .help(esquecerDesligado ? T("Pare a sessão para esquecer os aparelhos pareados") : "")
                }
            }
            .padding(.top, 8)

            HStack {
                Button(T("Abrir gravações"), action: abrirGravacoes)
                    .buttonStyle(.quall(.secundario, altura: 30))
                Text(T("A câmera é gravada na pasta de gravações do app."))
                    .font(.system(size: 11.5))
                    .foregroundColor(Estilo.texto2)
            }
            .padding(.top, 16)

            HStack(spacing: 16) {
                Button(T("Política de privacidade")) { abrirSite(pt: "quall/privacidade/", en: "en/quall/privacy/") }
                Button(T("Suporte")) { abrirSite(pt: "quall/suporte/", en: "en/quall/support/") }
            }
            .font(.system(size: 12))
            .foregroundColor(Estilo.acento)
            .buttonStyle(.borderless)
            .padding(.leading, 4)
            .padding(.top, 12)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                MarcaDoQuall(tamanho: 16, comNome: false)
                (Text("Quall Studio").fontWeight(.semibold).foregroundColor(Estilo.texto)
                 + Text(" " + versao).foregroundColor(Estilo.texto2))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(T("Licenças de terceiros"), action: abrirAvisos)
                    .font(.system(size: 12))
                    .foregroundColor(Estilo.acento)
                    .buttonStyle(.borderless)
            }
            .padding(.leading, 4)
        }
        .padding(20)
        .frame(width: Self.tamanho.width, height: Self.tamanho.height, alignment: .topLeading)
        .background(Estilo.fundo)
        .confirmationDialog(T("Esquecer os aparelhos pareados?"), isPresented: $confirmando) {
            Button(T("Esquecer"), role: .destructive, action: aoEsquecer)
            Button(T("Cancelar"), role: .cancel) {}
        } message: {
            Text(T("Da próxima vez, cada aparelho vai pedir o PIN de novo."))
        }
        .alert(T("Não foi possível abrir as licenças."), isPresented: $mostrandoErroDosAvisos) {
            Button(T("Fechar"), role: .cancel) {}
        } message: {
            Text(verbatim: erroDosAvisos)
        }
        .alert(T("Não foi possível abrir as gravações."), isPresented: $mostrandoErroDasGravacoes) {
            Button(T("Fechar"), role: .cancel) {}
        } message: {
            Text(verbatim: erroDasGravacoes)
        }
        .alert(T("Não foi possível abrir o site."), isPresented: $mostrandoErroDoSite) {
            Button(T("Fechar"), role: .cancel) {}
        }
    }

    private func abrirSite(pt: String, en: String) {
        guard let url = URL(string: "https://queven.com.br/" + (Idioma.atual == .pt ? pt : en)),
              NSWorkspace.shared.open(url) else {
            mostrandoErroDoSite = true
            return
        }
    }

    /// O leitor de texto do macOS abre o recurso assinado do app, sem buscar arquivo na rede.
    private func abrirAvisos() {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt"),
              FileManager.default.isReadableFile(atPath: url.path) else {
            erroDosAvisos = T("O arquivo de avisos não foi encontrado no app.")
            mostrandoErroDosAvisos = true
            return
        }
        if !NSWorkspace.shared.open(url) {
            erroDosAvisos = T("O macOS não conseguiu abrir o arquivo de avisos.")
            mostrandoErroDosAvisos = true
        }
    }

    /// A URL é a mesma do gravador. No sandbox ela pode estar no container do app.
    private func abrirGravacoes() {
        let pasta = GravadorLocal.pastaPadrao(Argumentos.lidos())
        do {
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(pasta) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
            }
        } catch {
            erroDasGravacoes = T("Não consegui abrir a pasta %@: %@", pasta.path, error.localizedDescription)
            mostrandoErroDasGravacoes = true
        }
    }

    private var divisor: some View {
        Rectangle().fill(Estilo.contorno).frame(height: 1).padding(.leading, 14)
    }

    private func grupo<C: View>(@ViewBuilder _ conteudo: () -> C) -> some View {
        VStack(spacing: 0) { conteudo() }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Estilo.grupo))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Estilo.contorno, lineWidth: 1))
    }

    private func linha<C: View>(_ titulo: String, _ legenda: String, controleEmbaixo: Bool = false,
                                @ViewBuilder controle: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).font(.system(size: 13, weight: .semibold)).foregroundColor(Estilo.texto)
                Text(legenda)
                    .font(.system(size: 11.5))
                    .foregroundColor(Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
                if controleEmbaixo { controle().padding(.top, 6) }
            }
            Spacer(minLength: 0)
            if !controleEmbaixo { controle() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
