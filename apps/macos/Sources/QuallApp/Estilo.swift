import AppKit
import QuallIdiomaKit
import SwiftUI

/// **As peças do "Estúdio de bolso"** (`docs/telas-estudio.md` §2–§4): os tokens de cor, os tipos e
/// as peças que as telas usam. As telas só usam o que está aqui — cor solta em tela é o jeito de a
/// janela do Mac sair diferente da do Windows, que lê a mesma tabela (`apps/windows/src/estilo.rs`).
///
/// # Os retratos
///
/// As peças que embrulham um controle nativo (campo, interruptor, segmentado, menu, deslizante,
/// roda de espera, rolagem) olham `\.emRetrato`: ligado (só em `--retratos-de-bancada`), desenham
/// uma imitação em SwiftUI, porque o `ImageRenderer` não desenha vista do AppKit e poria um
/// retângulo amarelo no lugar. No produto a chave está sempre desligada.
enum Estilo {
    // MARK: - as cores (§2)

    static let fundo = Color(rgb: 0x0B0B0F)
    static let superficie = Color(rgb: 0x16161D)
    static let superficieAlta = Color(rgb: 0x20202A)
    static let contorno = Color.white.opacity(0.08)
    /// A borda das casas do PIN e dos campos (branco a 10 %).
    static let bordaDeCampo = Color.white.opacity(0.10)
    static let texto = Color(rgb: 0xF5F5F7)
    static let texto2 = Color(rgb: 0xA1A1AE)
    static let texto3 = Color(rgb: 0x8B8B99)
    static let acento = Color(rgb: 0x6A5AF9)
    static let acentoClaro = Color(rgb: 0xA99FFF)
    static let acentoFundo = Color(rgb: 0x6A5AF9, opacidade: 0.16)
    static let noAr = Color(rgb: 0xFF453A)
    static let noArCheio = Color(rgb: 0xD93025)
    static let aguardando = Color(rgb: 0xFFB340)
    static let aguardandoTexto = Color(rgb: 0xFFC870)
    static let conectado = Color(rgb: 0x32D74B)
    static let conectadoTexto = Color(rgb: 0x6BE07F)
    static let perigoTexto = Color(rgb: 0xFF8A80)
    static let perigoFundo = Color(rgb: 0xFF453A, opacidade: 0.18)

    // Da barra lateral (§7): o fundo dela, o item escolhido e o apagado.
    static let barraLateral = Color(rgb: 0x131319)
    static let itemEscolhido = Color(rgb: 0x6A5AF9, opacidade: 0.22)
    static let iconeEscolhido = Color(rgb: 0xC9C2FF)
    static let itemComum = Color(rgb: 0xD6D6DE)
    static let itemApagado = Color(rgb: 0x6E6E7C)
    /// Os grupos dos Ajustes (§6.3): a superfície um pouco mais clara.
    static let grupo = Color(rgb: 0x1C1C24)

    // MARK: - os tipos (§3)

    /// SF Pro Rounded, o tipo de título e da marca.
    static func titulo(_ tamanho: CGFloat, peso: Font.Weight = .heavy) -> Font {
        .system(size: tamanho, weight: peso, design: .rounded)
    }

    /// SF Mono, para dígitos (PIN, endereço, contadores).
    static func mono(_ tamanho: CGFloat, peso: Font.Weight = .medium) -> Font {
        .system(size: tamanho, weight: peso, design: .monospaced)
    }

    static func corpo(_ tamanho: CGFloat = 14, peso: Font.Weight = .regular) -> Font {
        .system(size: tamanho, weight: peso)
    }

    // MARK: - o PIN por extenso

    /// Seis dígitos em dois grupos de três ("482 719"): seis corridos são lidos errado em voz alta, e
    /// ler em voz alta é o que acontece com um PIN mostrado num aparelho para ser digitado noutro.
    /// Uma função só para as telas que antes tinham três cópias dela.
    static func pinEspacado(_ pin: String) -> String {
        let d = Array(pin)
        guard d.count == 6 else { return pin }
        return String(d[0...2]) + " " + String(d[3...5])
    }

    /// A acessibilidade do PIN (§11.1): "PIN 4 8 2 7 1 9".
    static func pinFalado(_ pin: String) -> String {
        "PIN " + pin.map { String($0) }.joined(separator: " ")
    }
}

extension Text {
    /// **Uma frase traduzida com palavras em destaque**: o modelo traz `%@` onde cada destaque entra, na
    /// ordem (`T("Abra o Quall em %@ e escolha %@.")`), e cada destaque é desenhado por `forte`. A frase
    /// inteira é uma chave só — a ordem das palavras é da língua, e não da costura dos pedaços.
    static func comDestaques(_ modelo: String, _ destaques: [String], _ forte: (String) -> Text) -> Text {
        let pedacos = modelo.components(separatedBy: "%@")
        var t = Text(pedacos[0])
        for (i, resto) in pedacos.dropFirst().enumerated() {
            t = t + (i < destaques.count ? forte(destaques[i]) : Text("")) + Text(resto)
        }
        return t
    }
}

extension Color {
    /// Uma cor sRGB a partir do hexadecimal da especificação (`0x6A5AF9`).
    init(rgb: UInt32, opacidade: Double = 1) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: opacidade)
    }
}

// MARK: - o retrato e os Ajustes (chaves do ambiente)

private struct ChaveDoRetrato: EnvironmentKey {
    static let defaultValue = false
}

private struct ChaveDosAjustes: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Ligado só nos retratos de bancada: as peças nativas desenham uma imitação (ver o tipo).
    var emRetrato: Bool {
        get { self[ChaveDoRetrato.self] }
        set { self[ChaveDoRetrato.self] = newValue }
    }

    /// Abre a janela de Ajustes (a engrenagem e a linha da rede). Posto na raiz por `ComAbrirAjustes`.
    var abrirAjustes: () -> Void {
        get { self[ChaveDosAjustes.self] }
        set { self[ChaveDosAjustes.self] = newValue }
    }
}

/// Põe no ambiente o jeito de abrir os Ajustes (§11.4): `openSettings` no macOS 14 ou mais novo, e o
/// seletor `showSettingsWindow:` no 13 — no 14 o seletor só escreve um aviso e não abre nada.
struct ComAbrirAjustes<Conteudo: View>: View {
    let conteudo: Conteudo

    init(@ViewBuilder conteudo: () -> Conteudo) {
        self.conteudo = conteudo()
    }

    var body: some View {
        if #available(macOS 14, *) {
            AbrirAjustesNo14(conteudo: conteudo)
        } else {
            conteudo.environment(\.abrirAjustes) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}

@available(macOS 14, *)
private struct AbrirAjustesNo14<Conteudo: View>: View {
    @Environment(\.openSettings) private var abrir
    let conteudo: Conteudo

    var body: some View {
        conteudo.environment(\.abrirAjustes) { abrir() }
    }
}

// MARK: - a janela escura

/// **A barra de título na cor do fundo** (§1, "escuro sempre"): transparente, com o fundo da janela
/// em `fundo`. Só a cor: sem `fullSizeContentView`, o conteúdo continua embaixo da barra, na mesma
/// geometria de antes — o prompter e a tela com câmera não ganham nada entre o texto e a lente.
struct JanelaEscura: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Vista() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Vista: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.titlebarAppearsTransparent = true
            w.backgroundColor = NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0F / 255, alpha: 1)
        }
    }
}

// MARK: - a marca

/// Placeholder geométrico original do snapshot público; mantém o nome e o espaço do cabeçalho.
struct MarcaDoQuall: View {
    var tamanho: CGFloat = 24
    var comNome = true

    var body: some View {
        HStack(spacing: tamanho * 0.34) {
            Canvas { ctx, size in
                let u = size.width / 32
                let moldura = Path(CGRect(x: 6 * u, y: 6 * u, width: 20 * u, height: 20 * u))
                ctx.stroke(moldura, with: .color(Estilo.texto), lineWidth: 4 * u)
                let indicador = Path(CGRect(x: 14 * u, y: 14 * u, width: 4 * u, height: 4 * u))
                ctx.fill(indicador, with: .color(Estilo.noAr))
            }
            .frame(width: tamanho, height: tamanho)
            if comNome {
                Text("Quall Studio")
                    .font(Estilo.titulo(tamanho * 0.92))
                    .foregroundColor(Estilo.texto)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quall Studio")
    }
}

// MARK: - os botões (§4)

/// Os três botões de texto: principal (violeta), secundário e de perigo. Altura 44 e cantos 12 no Mac;
/// apertado, 90 % de opacidade; desligado, 40 %.
struct EstiloDeBotao: ButtonStyle {
    enum Tipo { case principal, secundario, perigo }
    var tipo: Tipo
    var altura: CGFloat = 44
    var largo = false

    func makeBody(configuration: Configuration) -> some View {
        CorpoDoBotao(configuration: configuration, tipo: tipo, altura: altura, largo: largo)
    }

    private struct CorpoDoBotao: View {
        let configuration: ButtonStyleConfiguration
        let tipo: Tipo
        let altura: CGFloat
        let largo: Bool
        @Environment(\.isEnabled) private var ligado

        var body: some View {
            let pequeno = altura < 40
            configuration.label
                .font(.system(size: pequeno ? 13 : 15, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(frente)
                .padding(.horizontal, pequeno ? 14 : 22)
                .frame(maxWidth: largo ? .infinity : nil)
                .frame(height: altura)
                .background(RoundedRectangle(cornerRadius: pequeno ? 10 : 12, style: .continuous).fill(fundo))
                .contentShape(RoundedRectangle(cornerRadius: pequeno ? 10 : 12, style: .continuous))
                .opacity(!ligado ? 0.4 : (configuration.isPressed ? 0.9 : 1))
        }

        private var frente: Color {
            switch tipo {
            case .principal: return .white
            case .secundario: return Estilo.texto
            case .perigo: return Estilo.perigoTexto
            }
        }

        private var fundo: Color {
            switch tipo {
            case .principal: return Estilo.acento
            case .secundario: return Estilo.superficieAlta
            case .perigo: return Estilo.perigoFundo
            }
        }
    }
}

extension ButtonStyle where Self == EstiloDeBotao {
    static func quall(_ tipo: EstiloDeBotao.Tipo, altura: CGFloat = 44, largo: Bool = false) -> EstiloDeBotao {
        EstiloDeBotao(tipo: tipo, altura: altura, largo: largo)
    }
}

/// O que vai dentro de um botão de texto: ícone opcional à esquerda (ou o quadradinho de parar), o
/// texto, e o atalho do teclado apagado à direita ("↩", "esc").
struct RotuloDeBotao: View {
    let texto: String
    var icone: String?
    var parar = false
    var atalho: String?

    init(_ texto: String, icone: String? = nil, parar: Bool = false, atalho: String? = nil) {
        self.texto = texto
        self.icone = icone
        self.parar = parar
        self.atalho = atalho
    }

    var body: some View {
        HStack(spacing: 9) {
            if parar {
                RoundedRectangle(cornerRadius: 3, style: .continuous).frame(width: 12, height: 12)
            } else if let icone {
                Image(systemName: icone).font(.system(size: 15, weight: .semibold))
            }
            Text(texto)
            if let atalho {
                Text(atalho).font(.system(size: 11, weight: .medium)).opacity(0.7)
            }
        }
    }
}

/// **O botão redondo** (§4): 40 × 40, círculo `superficie` com `contorno`, só ícone; o rótulo vai na
/// acessibilidade e na dica do mouse.
struct BotaoRedondo: View {
    let icone: String
    let rotulo: String
    var tamanho: CGFloat = 40
    var ponto: Color?
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(systemName: icone)
                .font(.system(size: tamanho * 0.4, weight: .medium))
                .foregroundColor(Estilo.texto)
                .frame(width: tamanho, height: tamanho)
                .background(Circle().fill(Estilo.superficie))
                .overlay(Circle().stroke(Estilo.contorno, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if let ponto {
                        Circle().fill(ponto).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Estilo.fundo, lineWidth: 1.5))
                            .offset(x: 1, y: -1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(EstiloApertado())
        .accessibilityLabel(rotulo)
        .help(rotulo)
    }
}

/// Um botão sem desenho próprio que só escurece ao apertar e apaga desligado.
struct EstiloApertado: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Corpo(configuration: configuration)
    }

    private struct Corpo: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var ligado
        var body: some View {
            configuration.label.opacity(!ligado ? 0.4 : (configuration.isPressed ? 0.85 : 1))
        }
    }
}

// MARK: - o ladrilho (§4)

/// **O ladrilho de origem**: ícone num quadrado, título e legenda; escolhido, fundo violeta a 14 %,
/// borda de 2 e o selo com ✓.
struct Ladrilho: View {
    let icone: String
    let titulo: String
    let detalhe: String
    var detalheMono = false
    let escolhido: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 12) {
                Image(systemName: icone)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(escolhido ? Color(rgb: 0xE0DBFF) : Estilo.acentoClaro)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(escolhido ? Color(rgb: 0x6A5AF9, opacidade: 0.3) : Estilo.acentoFundo))
                VStack(alignment: .leading, spacing: 2) {
                    Text(titulo)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Estilo.texto)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !detalhe.isEmpty {
                        Text(detalhe)
                            .font(detalheMono ? Estilo.mono(12) : .system(size: 12))
                            .foregroundColor(Estilo.texto2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(escolhido ? Color(rgb: 0x6A5AF9, opacidade: 0.14) : Estilo.superficie))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(escolhido ? Estilo.acento : Estilo.contorno, lineWidth: escolhido ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // O selo no canto, por fora do texto: nome comprido não perde espaço para ele.
            .overlay(alignment: .topTrailing) {
                if escolhido {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Estilo.acento))
                        .overlay(Circle().stroke(Estilo.fundo, lineWidth: 2))
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(EstiloApertado())
        .accessibilityLabel("\(titulo), \(detalhe)")
        .accessibilityAddTraits(escolhido ? .isSelected : [])
    }
}

// MARK: - a pílula de estado (§4)

/// A luz de estúdio: vermelho no ar (ou gravando), âmbar aguardando, verde conectado.
enum Luz: Equatable {
    case noAr, aguardando, conectado

    var cor: Color {
        switch self {
        case .noAr: return Estilo.noAr
        case .aguardando: return Estilo.aguardando
        case .conectado: return Estilo.conectado
        }
    }
}

/// **A pílula**: altura 28, bolinha de 8 e a palavra em caixa alta espaçada.
struct PilulaDeEstado: View {
    let luz: Luz
    let palavra: String
    var mono = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(luz == .noAr ? Color.white : luz.cor).frame(width: 8, height: 8)
            Text(palavra.uppercased())
                .font(mono ? Estilo.mono(12, peso: .bold) : .system(size: 12, weight: .bold))
                .tracking(mono ? 0.3 : 0.96)
                .lineLimit(1)
        }
        .foregroundColor(frente)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(fundo))
        .accessibilityElement(children: .combine)
    }

    private var frente: Color {
        switch luz {
        case .noAr: return .white
        case .aguardando: return Estilo.aguardandoTexto
        case .conectado: return Estilo.conectadoTexto
        }
    }

    private var fundo: Color {
        switch luz {
        case .noAr: return Estilo.noArCheio
        case .aguardando: return Estilo.aguardando.opacity(0.16)
        case .conectado: return Estilo.conectado.opacity(0.14)
        }
    }
}

// MARK: - o letreiro do PIN (§4)

/// **O letreiro do PIN**: seis casas de dígito monoespaçado, em dois grupos de três. 54 × 70 no
/// computador; as casas de digitar (`EntradaDoPin`) têm o mesmo desenho.
struct LetreiroDoPin: View {
    let pin: String
    var casa = CGSize(width: 54, height: 70)
    var fonte: CGFloat = 38

    var body: some View {
        let d = Array(pin)
        CasasDoPin(digitos: d.count == 6 ? d.map { String($0) } : Array(repeating: "–", count: 6),
                   casa: casa, fonte: fonte, vez: nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Estilo.pinFalado(pin))
    }
}

/// As seis casas, com a casa da vez (a de digitar) em borda de 2 violeta.
struct CasasDoPin: View {
    let digitos: [String]
    let casa: CGSize
    let fonte: CGFloat
    let vez: Int?

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<6, id: \.self) { i in
                if i == 3 { Color.clear.frame(width: 10, height: 1) }
                Text(i < digitos.count ? digitos[i] : "")
                    .font(Estilo.mono(fonte, peso: .bold))
                    .foregroundColor(Estilo.texto)
                    .frame(width: casa.width, height: casa.height)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Estilo.superficie))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(vez == i ? Estilo.acento : Estilo.bordaDeCampo, lineWidth: vez == i ? 2 : 1))
            }
        }
    }
}

/// **O PIN para digitar** (Exibir, Controlar): as mesmas casas, e por cima um campo quase
/// transparente que recebe o teclado (e o colar).
///
/// **O filtro é lógica nova desta rodada** (antes o campo aceitava qualquer texto): só os dígitos de
/// 0 a 9, no máximo seis. O que o campo guarda é sempre o que as casas mostram — um sétimo dígito ou
/// uma letra saem do campo na hora, e não ficam escondidos nele —, e o cursor fica sempre no fim:
/// o clique em qualquer ponto das casas só dá o foco, não põe o cursor no meio do PIN.
struct EntradaDoPin: View {
    @Binding var texto: String
    var casa = CGSize(width: 46, height: 58)
    var fonte: CGFloat = 30
    /// Nos retratos, a casa da vez aparece como se o campo tivesse o foco.
    var focoNoRetrato = false
    var aoConfirmar: () -> Void = {}
    @FocusState private var focado: Bool
    /// O que está no campo de verdade; limpo a cada mudança, e só então passado a `texto`.
    @State private var noCampo = ""
    @Environment(\.emRetrato) private var emRetrato

    static func limpo(_ s: String) -> String {
        String(s.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }

    var body: some View {
        let digitos = Array(texto.prefix(6)).map { String($0) }
        let comFoco = emRetrato ? focoNoRetrato : focado
        CasasDoPin(digitos: digitos, casa: casa, fonte: fonte, vez: comFoco ? min(digitos.count, 5) : nil)
            .accessibilityHidden(true)
            .overlay {
                if !emRetrato {
                    TextField("", text: $noCampo)
                        .textFieldStyle(.plain)
                        .focused($focado)
                        .onSubmit(aoConfirmar)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(0.011)
                        // O clique é das casas (abaixo): o campo só recebe o teclado.
                        .allowsHitTesting(false)
                        .accessibilityLabel("PIN")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focado = true; CursorNoFim.agora() }
            .onAppear { noCampo = texto }
            .onChange(of: noCampo) { novo in
                let l = EntradaDoPin.limpo(novo)
                if l != novo { noCampo = l }
                if texto != l { texto = l }
                if focado { CursorNoFim.agora() }
            }
            // O PIN mudado por fora (o "Usar o último" não mexe nele, mas a bancada preenche).
            .onChange(of: texto) { novo in if novo != noCampo { noCampo = EntradaDoPin.limpo(novo) } }
            .onChange(of: focado) { if $0 { CursorNoFim.agora() } }
            .fixedSize()
    }
}

/// Põe o cursor no fim do campo que está com o foco (o AppKit seleciona tudo ao dar o foco).
enum CursorNoFim {
    static func agora() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let fim = (editor.string as NSString).length
            if editor.selectedRange() != NSRange(location: fim, length: 0) {
                editor.setSelectedRange(NSRange(location: fim, length: 0))
            }
        }
    }
}

// MARK: - o chip de endereço (§4)

/// **O chip de endereço**: cápsula de 40 com o endereço em mono e o ícone de copiar; tocar copia e
/// diz "Copiado". Sem rede, diz "sem rede" em âmbar e não copia nada.
struct ChipDeEndereco: View {
    let endereco: String?
    var tamanho: CGFloat = 15
    @State private var copiado = false

    var body: some View {
        Button {
            guard let endereco else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(endereco, forType: .string)
            copiado = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiado = false }
        } label: {
            HStack(spacing: 10) {
                Text(endereco ?? T("sem rede"))
                    .font(Estilo.mono(tamanho))
                    .foregroundColor(endereco == nil ? Estilo.aguardandoTexto : Estilo.texto)
                    .lineLimit(1)
                if endereco != nil {
                    if copiado {
                        Text(T("Copiado")).font(.system(size: 12, weight: .semibold)).foregroundColor(Estilo.acentoClaro)
                    } else {
                        Image(systemName: "doc.on.doc").font(.system(size: 13, weight: .medium))
                            .foregroundColor(Estilo.acentoClaro)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Capsule().fill(Estilo.superficie))
            .overlay(Capsule().strokeBorder(Estilo.contorno, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(EstiloApertado())
        .disabled(endereco == nil)
        .accessibilityLabel(endereco.map { T("Copiar o endereço %@", $0) } ?? T("Sem rede"))
        .help(endereco == nil ? T("Sem rede") : T("Copiar o endereço"))
    }
}

// MARK: - o aviso (§4)

/// **O aviso**: ícone e texto, âmbar, vermelho ou de informação, com uma ação opcional. A ação só
/// aparece quando ela é a coisa certa a oferecer — ver `Emissor.ofereceDesparear` e a dívida 22.
struct Aviso: View {
    enum Tipo { case ambar, vermelho, info }
    let texto: String
    var tipo: Tipo = .ambar
    var acao: String?
    var aoTocar: () -> Void = {}
    /// Com ele, um X no canto dispensa o aviso.
    var aoFechar: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icone)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tipo == .info ? Estilo.acentoClaro : frente)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(texto)
                    .font(.system(size: 13))
                    .foregroundColor(frente)
                    .fixedSize(horizontal: false, vertical: true)
                if let acao {
                    Button(action: aoTocar) {
                        Text(acao).font(.system(size: 13, weight: .semibold)).foregroundColor(frenteDaAcao)
                    }
                    .buttonStyle(EstiloApertado())
                }
            }
            Spacer(minLength: 0)
            if let aoFechar {
                Button(action: aoFechar) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(frente)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(EstiloApertado())
                .accessibilityLabel(T("Dispensar o aviso"))
                .help(T("Dispensar o aviso"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fundo))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(tipo == .info ? Estilo.contorno : .clear, lineWidth: 1))
    }

    private var icone: String {
        switch tipo {
        case .ambar: return "exclamationmark.triangle"
        case .vermelho: return "xmark.octagon"
        case .info: return "info.circle"
        }
    }

    private var frente: Color {
        switch tipo {
        case .ambar: return Estilo.aguardandoTexto
        case .vermelho: return Estilo.perigoTexto
        case .info: return Estilo.texto2
        }
    }

    private var frenteDaAcao: Color {
        tipo == .info ? Estilo.acentoClaro : frente
    }

    private var fundo: Color {
        switch tipo {
        case .ambar: return Estilo.aguardando.opacity(0.12)
        case .vermelho: return Estilo.noAr.opacity(0.16)
        case .info: return Estilo.superficie
        }
    }
}

/// Um aviso da lista, com a ação dele.
struct ItemDeAviso: Identifiable {
    let id: String
    let texto: String
    var tipo: Aviso.Tipo = .ambar
    var acao: String?
    var aoTocar: () -> Void = {}
    var aoFechar: (() -> Void)?
}

/// **No máximo `limite` avisos à vista** (§11.1); o resto recolhe em "+N", que abre e fecha.
struct ListaDeAvisos: View {
    let itens: [ItemDeAviso]
    var limite = 1
    @State private var abertos = false

    var body: some View {
        let visiveis = abertos ? itens : Array(itens.prefix(limite))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visiveis) { a in
                Aviso(texto: a.texto, tipo: a.tipo, acao: a.acao, aoTocar: a.aoTocar, aoFechar: a.aoFechar)
            }
            if itens.count > limite {
                Button { abertos.toggle() } label: {
                    Text(abertos ? T("Mostrar menos") : itens.count - limite == 1 ? T("+1 aviso") : T("+%@ avisos", itens.count - limite))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Estilo.acentoClaro)
                }
                .buttonStyle(EstiloApertado())
            }
        }
    }
}

// MARK: - rótulo de seção, cartão de número, brilho

/// **O rótulo de seção** (§4): 12 semibold, caixa alta, +0,08 em, `texto3`.
struct RotuloDeSecao: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }

    var body: some View {
        Text(texto.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.96)
            .foregroundColor(Estilo.texto3)
            .lineLimit(1)
    }
}

/// Um cartão de número do "no ar" (§7.4): a chave em caixa alta e o valor.
struct CartaoDeNumero: View {
    let chave: String
    let valor: String
    var mono = false
    var cor: Color = Estilo.texto

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chave.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.66)
                .foregroundColor(Estilo.texto3)
            Text(valor)
                .font(mono ? Estilo.mono(15, peso: .semibold) : .system(size: 16, weight: .semibold))
                .foregroundColor(cor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Estilo.superficie))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Estilo.contorno, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// O brilho de fundo (§2): um degradê radial da cor no alto, sumindo até 60 % da altura.
struct BrilhoDeFundo: View {
    var cor: Color = Estilo.acento
    var intensidade: Double = 0.18
    var centro = UnitPoint(x: 0.7, y: -0.1)

    var body: some View {
        GeometryReader { g in
            RadialGradient(colors: [cor.opacity(intensidade), cor.opacity(0)], center: centro,
                           startRadius: 0, endRadius: max(g.size.width, g.size.height) * 0.6)
        }
        .background(Estilo.fundo)
        .allowsHitTesting(false)
    }
}

// MARK: - as peças nativas (com imitação nos retratos)

/// **O campo** (§4): altura 44, cantos 10, `superficie`, borda branca a 10 %; endereço em mono.
struct Campo: View {
    let dica: String
    @Binding var texto: String
    var mono = true
    var tamanho: CGFloat = 17
    var altura: CGFloat = 44
    var aoConfirmar: () -> Void = {}
    @Environment(\.emRetrato) private var emRetrato
    @FocusState private var focado: Bool

    var body: some View {
        Group {
            if emRetrato {
                Text(texto.isEmpty ? dica : texto)
                    .foregroundColor(texto.isEmpty ? Estilo.texto3 : Estilo.texto)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(dica, text: $texto)
                    .textFieldStyle(.plain)
                    .disableAutocorrection(true)
                    .focused($focado)
                    .onSubmit(aoConfirmar)
            }
        }
        .font(mono ? Estilo.mono(tamanho) : .system(size: tamanho))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: altura)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Estilo.superficie))
        // Com o foco, a borda violeta de 2 — a mesma da casa da vez no PIN.
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focado ? Estilo.acento : Estilo.bordaDeCampo, lineWidth: focado ? 2 : 1))
        // O campo do AppKit tem só a altura da letra: o clique no resto da moldura também dá o foco,
        // com o cursor no fim (e não o texto todo selecionado).
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            guard !emRetrato else { return }
            focado = true
            CursorNoFim.agora()
        }
    }
}

/// **O interruptor** (§4): o nativo, tingido de `acento`. O título vai na acessibilidade; quem usa
/// escreve o título e a legenda ao lado.
struct Interruptor: View {
    let titulo: String
    @Binding var ligado: Bool
    var pequeno = false
    @Environment(\.emRetrato) private var emRetrato
    @Environment(\.isEnabled) private var habilitado

    var body: some View {
        if emRetrato {
            let l: CGFloat = pequeno ? 32 : 38
            let a: CGFloat = pequeno ? 18 : 22
            ZStack(alignment: ligado ? .trailing : .leading) {
                Capsule().fill(ligado ? Estilo.acento : Color.white.opacity(0.18))
                Circle().fill(Color.white).padding(2)
            }
            .frame(width: l, height: a)
            .opacity(habilitado ? 1 : 0.4)
        } else {
            Toggle(titulo, isOn: $ligado)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(pequeno ? .small : .regular)
                .tint(Estilo.acento)
        }
    }
}

/// **O segmentado** (§4): o nativo, no escuro, tingido de `acento`.
struct Segmentado<Valor: Hashable>: View {
    let titulo: String
    let opcoes: [(rotulo: String, valor: Valor)]
    @Binding var escolha: Valor
    @Environment(\.emRetrato) private var emRetrato
    @Environment(\.isEnabled) private var habilitado

    var body: some View {
        if emRetrato {
            HStack(spacing: 2) {
                ForEach(Array(opcoes.enumerated()), id: \.offset) { _, o in
                    Text(o.rotulo)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Estilo.texto)
                        .frame(minWidth: 44)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(o.valor == escolha ? Color.white.opacity(0.22) : .clear))
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
            .opacity(habilitado ? 1 : 0.4)
        } else {
            Picker(titulo, selection: $escolha) {
                ForEach(Array(opcoes.enumerated()), id: \.offset) { _, o in Text(o.rotulo).tag(o.valor) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Uma escolha num menu (o "Sair pela rede" dos Ajustes). Nos retratos, o rótulo da escolhida.
struct EscolhaEmMenu<Valor: Hashable>: View {
    let titulo: String
    let opcoes: [(rotulo: String, valor: Valor)]
    @Binding var escolha: Valor
    @Environment(\.emRetrato) private var emRetrato
    @Environment(\.isEnabled) private var habilitado

    var body: some View {
        if emRetrato {
            HStack(spacing: 6) {
                Text(opcoes.first { $0.valor == escolha }?.rotulo ?? "")
                    .font(.system(size: 13))
                    .foregroundColor(Estilo.texto)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Estilo.texto2)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            .opacity(habilitado ? 1 : 0.4)
        } else {
            Picker(titulo, selection: $escolha) {
                ForEach(Array(opcoes.enumerated()), id: \.offset) { _, o in Text(o.rotulo).tag(o.valor) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// O deslizante nativo, tingido; nos retratos, um trilho desenhado.
struct Deslizante: View {
    @Binding var valor: Float
    var largura: CGFloat = 100
    @Environment(\.emRetrato) private var emRetrato
    @Environment(\.isEnabled) private var habilitado

    var body: some View {
        if emRetrato {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                Capsule().fill(Estilo.acento).frame(width: largura * CGFloat(valor), height: 4)
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .offset(x: max(0, largura * CGFloat(valor) - 7))
            }
            .frame(width: largura, height: 16)
            .opacity(habilitado ? 1 : 0.4)
        } else {
            Slider(value: $valor, in: 0...1)
                .tint(Estilo.acento)
                .frame(width: largura)
        }
    }
}

/// A roda de espera, pequena.
struct Carregando: View {
    var cor: Color = Estilo.texto2
    @Environment(\.emRetrato) private var emRetrato

    var body: some View {
        if emRetrato {
            Circle().trim(from: 0.1, to: 0.8)
                .stroke(cor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 14, height: 14)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// **A lista que rola só quando não cabe**: até `visiveis` linhas ela é uma pilha comum; passou,
/// vira rolagem com a altura de `visiveis` linhas. Nos retratos, sempre a pilha.
struct PilhaQueRola<Conteudo: View>: View {
    let quantas: Int
    let visiveis: Int
    let alturaDaLinha: CGFloat
    var espaco: CGFloat = 8
    @ViewBuilder let conteudo: () -> Conteudo
    @Environment(\.emRetrato) private var emRetrato

    var body: some View {
        if quantas <= visiveis || emRetrato {
            conteudo()
        } else {
            ScrollView { conteudo() }
                .frame(height: CGFloat(visiveis) * alturaDaLinha + CGFloat(visiveis - 1) * espaco
                       + alturaDaLinha * 0.5)
        }
    }
}

/// O lugar de uma ilha AppKit (vídeo, prévia da câmera) nos retratos: um retângulo com o nome.
struct LugarDaIlha: View {
    let nome: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(rgb: 0x2A2A38), Color(rgb: 0x15151C)], startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                Image(systemName: "rectangle.dashed").font(.system(size: 22))
                Text(nome).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(Estilo.texto3)
        }
    }
}

// MARK: - os controles redondos da câmera (§6.5)

/// O microfone na tela, em palavras curtas; as frases longas ficam na dica e no aviso.
enum MicrofoneNaTela: Equatable {
    case desligado, ligando, ligado, semAcesso, naoAbriu

    var legenda: String {
        switch self {
        case .desligado: return T("Mic desligado")
        case .ligando: return T("Ligando…")
        case .ligado: return T("Mic ligado")
        case .semAcesso: return T("Sem acesso")
        case .naoAbriu: return T("Não abriu")
        }
    }
}

/// A gravação na tela: parada, começando, gravando desde (o relógio do sistema) ou fechando.
enum GravacaoNaTela: Equatable {
    case parada, abrindo, gravando(desde: TimeInterval), fechando

    var ocupada: Bool { self != .parada }
    var gravando: Bool { if case .gravando = self { return true }; return false }
}

/// **Os três controles redondos** (§6.5 e §7.4): microfone (56), gravar (78) e parar (56), com a
/// legenda embaixo de cada um.
struct ControlesRedondos: View {
    let microfone: MicrofoneNaTela
    let gravacao: GravacaoNaTela
    let semSom: Bool
    let montada: Bool
    let rotuloDoParar: String
    var pararDesligado = false
    var dicaDoMicrofone = ""
    let aoMicrofone: () -> Void
    let aoGravar: () -> Void
    let aoParar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            controle(legenda: microfone.legenda) {
                Button(action: aoMicrofone) {
                    ZStack {
                        Circle().fill(fundoDoMicrofone)
                        if microfone == .ligando {
                            Carregando(cor: .white)
                        } else {
                            Image(systemName: microfone == .ligado ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(microfone == .semAcesso || microfone == .naoAbriu ? .black : .white)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
                }
                .buttonStyle(EstiloApertado())
                .disabled(!montada)
                .accessibilityLabel(microfone == .ligado ? T("Desligar o microfone") : T("Ligar o microfone"))
                .help(dicaDoMicrofone)
            }

            controle(legenda: legendaDoGravar, mono: gravacao.gravando) {
                Button(action: aoGravar) {
                    ZStack {
                        Circle().strokeBorder(Color.white, lineWidth: 4)
                        if gravacao.gravando {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Estilo.noAr)
                                .frame(width: 30, height: 30)
                        } else if gravacao == .parada {
                            Circle().fill(Estilo.noAr).padding(9)
                        } else {
                            Carregando(cor: .white)
                        }
                    }
                    .frame(width: 78, height: 78)
                    .contentShape(Circle())
                }
                .buttonStyle(EstiloApertado())
                .disabled(!montada || gravacao == .fechando)
                .accessibilityLabel(gravacao.ocupada ? T("Parar a gravação") : T("Gravar"))
                .help(gravacao.ocupada ? T("Parar a gravação (o arquivo fica na pasta de gravações)")
                      : T("Gravar a câmera, sem o texto, na pasta de gravações (o microfone só se estiver ligado)"))
            }

            controle(legenda: rotuloDoParar) {
                Button(action: aoParar) {
                    ZStack {
                        Circle().fill(Estilo.noAr.opacity(0.24))
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Estilo.perigoTexto)
                            .frame(width: 18, height: 18)
                    }
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
                }
                .buttonStyle(EstiloApertado())
                .disabled(pararDesligado)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(rotuloDoParar)
            }
        }
    }

    private var fundoDoMicrofone: Color {
        switch microfone {
        case .ligado: return Estilo.noAr.opacity(0.85)
        case .semAcesso, .naoAbriu: return Estilo.aguardando
        default: return Color.white.opacity(0.16)
        }
    }

    private var legendaDoGravar: String {
        switch gravacao {
        case .parada: return T("Gravar")
        case .abrindo: return T("Começando…")
        case .fechando: return T("Fechando…")
        case .gravando: return ""
        }
    }

    @ViewBuilder
    private func controle<C: View>(legenda: String, mono: Bool = false, @ViewBuilder _ botao: () -> C) -> some View {
        VStack(spacing: 8) {
            botao().frame(height: 78)
            if mono, case .gravando(let desde) = gravacao {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(GravadorLocal.duracaoLegivel(ProcessInfo.processInfo.systemUptime - desde)
                         + (semSom ? T(" · SEM SOM") : ""))
                        .font(Estilo.mono(12, peso: .semibold))
                        .foregroundColor(semSom ? Estilo.aguardandoTexto : Estilo.texto)
                        .lineLimit(1)
                        .fixedSize()
                }
            } else {
                Text(legenda)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Estilo.texto2)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minWidth: 72)
    }
}
