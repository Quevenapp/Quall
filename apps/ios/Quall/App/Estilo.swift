import SwiftUI
import UIKit

/// **As peças da tela** do Quall no iOS: o "Estúdio de bolso" de `docs/telas-estudio.md` (30/09/2026).
///
/// A especificação é comum às quatro plataformas, e cada uma tem **um arquivo de peças** do qual as
/// telas usam: aqui, no Android `ui/PecasDaTela.kt`, no Mac `apps/macos/.../Estilo.swift`, no Windows
/// `estilo.rs`. Os nomes dos tokens são os mesmos nas quatro (§2), para uma tela poder ser conferida
/// contra a outra de olho.
///
/// # Por que este arquivo mora em `App/`, e não em `Comum/` como a especificação escreve
///
/// `Comum/` é compilado **também dentro da Broadcast Upload Extension** (`project.yml`), cujo teto de
/// jetsam é de 50,00 MB no iPhone 7 e no X, e onde a regra medida do projeto é "nada de UIKit" (ver
/// `IdentidadeDaTela.swift`). Um arquivo de SwiftUI em `Comum/` faria a appex linkar o SwiftUI sem
/// usar nada dele — o tipo de peso que o `provar.sh` existe para pegar. `App/`, `Receber/` e
/// `Teleprompter/` entram só no alvo do app, e as três pastas enxergam o que está aqui.
///
/// # O que é peça e o que é tela
///
/// Peça é só desenho: recebe texto e valores simples, devolve toque. Nenhuma peça lê o `Emissor`, a
/// `Recepcao` ou o modelo do teleprompter — quem adapta o estado à peça é a tela. É o que deixa as
/// peças serem conferidas em retrato sem sessão nenhuma de pé.
///
/// # A letra acompanha o Tipo Dinâmico, até um teto (§11.1)
///
/// Os tipos são estilos de texto do sistema com `design:` (`.rounded` no título, `.monospaced` nos
/// dígitos), e não pontos fixos: na escala padrão eles caem na escala da especificação (título 28,
/// cartão 22, corpo 15–17, legenda 13, rótulo 12), e com letra maior crescem. O teto é
/// `.dynamicTypeSize(...(.xxLarge))` em cada tela do escopo (`Estilo.tetoDaLetra`). A conta de altura
/// do R16 é feita na escala padrão; acima dela a tela pode rolar (`TelaQueCabe`).
enum Estilo {

    // MARK: - As cores (§2)

    /// Fundo de toda tela.
    static let fundo = Color(rgb: 0x0B0B0F)
    /// Cartões, campos, botões redondos.
    static let superficie = Color(rgb: 0x16161D)
    /// Botão secundário, item escolhido de lista.
    static let superficieAlta = Color(rgb: 0x20202A)
    /// Os grupos da folha de Ajustes (§6.3): um pouco mais claros que a superfície.
    static let superficieDoGrupo = Color(rgb: 0x1C1C24)
    /// A borda de 1 pt dos cartões.
    static let contorno = Color.white.opacity(0.08)
    /// A borda dos campos e das casas do PIN.
    static let bordaDoCampo = Color.white.opacity(0.10)
    /// O vidro sobre a imagem (o cartão da câmera, a barra do vídeo): preto a 85 %, porque a 55 % o
    /// contraste cai abaixo de 2:1 numa cena clara (§11.1). Por cima dele, só `texto` e `texto2`.
    static let vidro = Color.black.opacity(0.85)

    static let texto = Color(rgb: 0xF5F5F7)
    /// Texto secundário.
    static let texto2 = Color(rgb: 0xA1A1AE)
    /// Rótulo de seção e legenda. Nunca mais escuro que isto em letra pequena.
    static let texto3 = Color(rgb: 0x8B8B99)

    /// O "violeta Quall": fundo do botão principal e do cartão Espelhar (texto branco, 4,7:1).
    static let acento = Color(rgb: 0x6A5AF9)
    /// Ícone e texto violeta sobre o escuro.
    static let acentoClaro = Color(rgb: 0xA99FFF)
    /// Fundo do ícone dos cartões, do chip "Usar o último", do item escolhido.
    static let acentoFundo = Color(rgb: 0x6A5AF9).opacity(0.16)

    /// A luz de estúdio acesa: bolinha "no ar", botão de gravar.
    static let noAr = Color(rgb: 0xFF453A)
    /// Fundo da pílula NO AR / REC / SEM CÂMERA (texto branco).
    static let noArCheio = Color(rgb: 0xD93025)
    /// Aguardando, e aviso.
    static let aguardando = Color(rgb: 0xFFB340)
    static let aguardandoTexto = Color(rgb: 0xFFC870)
    /// Conectado, rede presente.
    static let conectado = Color(rgb: 0x32D74B)
    static let conectadoTexto = Color(rgb: 0x6BE07F)
    /// Parar, Esquecer.
    static let perigoTexto = Color(rgb: 0xFF8A80)
    static let perigoFundo = Color(rgb: 0xFF453A).opacity(0.18)

    // MARK: - Os tipos (§3, com a emenda da §11.1)

    /// Título: SF Pro Rounded, pesado. `.largeTitle` na marca (34), `.title` no título de tela (28),
    /// `.title2` no de cartão (22).
    static func titulo(_ estilo: Font.TextStyle = .title) -> Font {
        .system(estilo, design: .rounded).weight(.heavy)
    }

    /// Corpo: SF Pro. `.body` 17, `.callout` 16, `.subheadline` 15, `.footnote` 13 (legenda),
    /// `.caption` 12.
    static func corpo(_ estilo: Font.TextStyle = .body, _ peso: Font.Weight = .regular) -> Font {
        .system(estilo).weight(peso)
    }

    /// Dígitos (PIN, IP): SF Mono.
    static func mono(_ estilo: Font.TextStyle = .body, _ peso: Font.Weight = .medium) -> Font {
        .system(estilo, design: .monospaced).weight(peso)
    }

    /// O teto do Tipo Dinâmico nas telas do escopo (§11.1).
    static let tetoDaLetra = DynamicTypeSize.xxLarge

    // MARK: - Medidas

    /// A margem lateral das telas de celular.
    static let margem: CGFloat = 20
    /// A largura máxima do conteúdo no iPad em pé: a tela é a do celular, centrada.
    static let larguraMaxima: CGFloat = 480

    // MARK: - Textos que várias telas repetem

    /// "482 719": seis dígitos corridos são lidos errado em voz alta, e ler em voz alta é o que
    /// acontece com um PIN mostrado num aparelho para ser digitado noutro. Era uma cópia em cada uma
    /// de quatro telas (espera, câmera, prompter, prompter com câmera).
    static func pinEspacado(_ pin: String) -> String {
        let d = Array(pin)
        guard d.count == 6 else { return pin }
        return String(d[0...2]) + " " + String(d[3...5])
    }

    /// "PIN 4 8 2 7 1 9", para o leitor de tela dizer dígito a dígito.
    static func pinSoletrado(_ pin: String) -> String {
        "PIN " + pin.map { String($0) }.joined(separator: " ")
    }

    /// "iPhone" ou "iPad": o nome do modelo para os textos que diziam "iPhone" fixo e apareciam no
    /// iPad. `UIDevice.model` não segue o idioma do aparelho — é o nome do produto.
    static var modeloDoAparelho: String { UIDevice.current.model }

    /// O nome da appex como a folha do sistema o mostra ("Quall Tela"): lido do pacote dela, na língua
    /// que o sistema escolheu (`docs/traducao.md`), e não na do botão PT | EN.
    static var nomeDaAppex: String {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let pacote = Bundle(url: plugins.appendingPathComponent("Difusao.appex")) else { return "Quall Studio Tela" }
        return pacote.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? pacote.infoDictionary?["CFBundleDisplayName"] as? String
            ?? "Quall Studio Tela"
    }

    /// A caixa alta das pílulas e dos rótulos de seção segue o idioma da interface (o "i" e os acentos
    /// do português; o inglês sem regra especial).
    static var localDaCaixaAlta: Locale {
        Locale(identifier: Idioma.atual == .pt ? "pt_BR" : "en_US")
    }

    /// O ícone de espelhar, com o aparelho certo desenhado.
    static var iconeDeEspelhar: String {
        modeloDoAparelho == "iPad" ? "ipad.and.arrow.forward" : "iphone.and.arrow.forward"
    }

    // MARK: - A aparência do UIKit que o SwiftUI não alcança

    /// O segmentado nativo tingido do violeta (§4): o `.tint` do SwiftUI não chega ao
    /// `UISegmentedControl`. Chamado uma vez, na abertura do app.
    static func aplicarAparencia() {
        let segmentado = UISegmentedControl.appearance()
        segmentado.selectedSegmentTintColor = UIColor(acento)
        segmentado.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        segmentado.setTitleTextAttributes([.foregroundColor: UIColor(texto2)], for: .normal)
    }
}

fileprivate extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: 1)
    }
}

// =================================================================================================
// MARK: - A marca
// =================================================================================================

/// Marca aprovada do produto; geometria pertence ao overlay privado de marca.
struct MarcaDoQuall: View {
    var comNome = true
    @ScaledMetric(relativeTo: .largeTitle) private var lado: CGFloat = 30

    var body: some View {
        HStack(spacing: lado * 0.34) {
            simbolo
            if comNome {
                Text(verbatim: "Quall Studio")
                    .font(Estilo.titulo(.largeTitle))
                    .tracking(-0.6)
                    .foregroundColor(Estilo.texto)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Quall Studio"))
    }

    private var simbolo: some View {
        let u = lado / 32
        return ZStack(alignment: .topLeading) {
            Circle()
                .stroke(Estilo.texto, lineWidth: 3.6 * u)
                .frame(width: 21 * u, height: 21 * u)
                .offset(x: 4.5 * u, y: 4.5 * u)
            Circle()
                .fill(Estilo.noAr)
                .frame(width: 9.2 * u, height: 9.2 * u)
                .offset(x: 20.6 * u, y: 20.6 * u)
        }
        .frame(width: lado, height: lado, alignment: .topLeading)
    }
}

// =================================================================================================
// MARK: - Fundo e moldura
// =================================================================================================

/// O fundo de toda tela, com o brilho opcional de §2: um degradê radial no alto que some até 60 % da
/// altura. Violeta nas telas de escolha, âmbar na espera, vermelho no ar.
struct FundoDoQuall: View {
    var brilho: Color? = nil
    var intensidade: Double = 0.2

    var body: some View {
        ZStack {
            Estilo.fundo
            if let brilho {
                GeometryReader { g in
                    RadialGradient(colors: [brilho.opacity(intensidade), brilho.opacity(0)],
                                   center: UnitPoint(x: 0.5, y: -0.06),
                                   startRadius: 0,
                                   endRadius: max(g.size.height * 0.6, g.size.width * 0.7))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// **A tela cabe inteira no menor aparelho** (o R16: iPhone 7, na escala de letra padrão) e, quando
/// não cabe — letra grande, teclado aberto, um aviso a mais —, rola em vez de cortar (§11.1: "R16 é
/// caber, não tirar a rolagem").
///
/// O conteúdo ganha no mínimo a altura da tela, então os `Spacer` dele continuam empurrando o botão
/// para o pé quando sobra espaço. Em retrato e em paisagem, na escala padrão, a conta de altura de
/// cada tela do escopo (no comentário dela) fecha abaixo da altura útil do iPhone 7: não há o que
/// rolar.
struct TelaQueCabe<Conteudo: View>: View {
    @ViewBuilder let conteudo: () -> Conteudo

    var body: some View {
        GeometryReader { g in
            ScrollView(.vertical, showsIndicators: false) {
                conteudo()
                    .frame(width: g.size.width)
                    .frame(minHeight: g.size.height, alignment: .top)
            }
        }
    }
}

// =================================================================================================
// MARK: - Botões
// =================================================================================================

/// O miolo comum dos três botões grandes (§4): altura 56, cantos 16, texto semibold 17 (`.body`),
/// ícone opcional à esquerda (pelo `Label` de quem usa). Apertado, 90 % de opacidade; desligado, 40 %.
private struct CorpoDoBotao: View {
    let configuration: ButtonStyleConfiguration
    let fundo: Color
    let frente: Color
    var comParar = false
    var pequeno = false
    var largo = true
    @Environment(\.isEnabled) private var ligado

    var body: some View {
        HStack(spacing: 8) {
            if comParar {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .frame(width: pequeno ? 11 : 13, height: pequeno ? 11 : 13)
                    .accessibilityHidden(true)
            }
            configuration.label
        }
        .font(pequeno ? Estilo.corpo(.subheadline, .semibold) : Estilo.corpo(.body, .semibold))
        .foregroundColor(frente)
        .lineLimit(1)
        .minimumScaleFactor(pequeno ? 0.7 : 0.8)
        .padding(.horizontal, pequeno ? 12 : 14)
        .frame(maxWidth: largo ? .infinity : nil, minHeight: pequeno ? 40 : 56)
        .background(RoundedRectangle(cornerRadius: pequeno ? 12 : 16, style: .continuous).fill(fundo))
        .contentShape(RoundedRectangle(cornerRadius: pequeno ? 12 : 16, style: .continuous))
        .opacity(!ligado ? 0.4 : (configuration.isPressed ? 0.9 : 1))
    }
}

/// Fundo `acento`, texto branco.
struct BotaoPrincipal: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CorpoDoBotao(configuration: configuration, fundo: Estilo.acento, frente: .white)
    }
}

/// Fundo `superficieAlta`, texto `texto`. `pequeno`: altura 40, cantos 12, texto 15 — os dois botões
/// de baixo do formulário do controle, o socorro da espera. `largo` falso: do tamanho do texto (a
/// barra do vídeo).
struct BotaoSecundario: ButtonStyle {
    var pequeno = false
    var largo = true
    var fundo: Color = Estilo.superficieAlta
    func makeBody(configuration: Configuration) -> some View {
        CorpoDoBotao(configuration: configuration, fundo: fundo, frente: Estilo.texto,
                     pequeno: pequeno, largo: largo)
    }
}

/// Vermelho a 18 %, texto `#FF8A80`, o quadradinho de parar à esquerda.
struct BotaoDePerigo: ButtonStyle {
    var pequeno = false
    var largo = true
    func makeBody(configuration: Configuration) -> some View {
        CorpoDoBotao(configuration: configuration, fundo: Estilo.perigoFundo, frente: Estilo.perigoTexto,
                     comParar: true, pequeno: pequeno, largo: largo)
    }
}

/// O toque dos cartões e ladrilhos: um leve esmaecer, sem mudar a geometria.
struct EstiloDeToque: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

extension ButtonStyle where Self == BotaoPrincipal {
    static var principal: BotaoPrincipal { BotaoPrincipal() }
}

extension ButtonStyle where Self == BotaoSecundario {
    static var secundario: BotaoSecundario { BotaoSecundario() }
    static var secundarioPequeno: BotaoSecundario { BotaoSecundario(pequeno: true) }
}

extension ButtonStyle where Self == BotaoDePerigo {
    static var perigo: BotaoDePerigo { BotaoDePerigo() }
}

extension ButtonStyle where Self == EstiloDeToque {
    static var toque: EstiloDeToque { EstiloDeToque() }
}

/// **O botão redondo** (§4): 40 de desenho, círculo `superficie` com `contorno`, só o ícone (voltar,
/// engrenagem, ⓘ), e **44 de área de toque** (§11.1). O rótulo vai só para a acessibilidade.
///
/// `ponto`: a bolinha no canto (a acusação da imagem no ⓘ do vídeo, §6.6).
struct BotaoRedondo: View {
    let icone: String
    let rotulo: String
    var ponto: Color? = nil
    var fundo: Color = Estilo.superficie
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(systemName: icone)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Estilo.texto)
                .frame(width: 40, height: 40)
                .background(Circle().fill(fundo))
                .overlay(Circle().stroke(Estilo.contorno, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if let ponto {
                        Circle().fill(ponto)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Estilo.fundo, lineWidth: 2))
                            .offset(x: 1, y: -1)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.toque)
        .accessibilityLabel(rotulo)
    }
}

/// O cabeçalho das telas de dentro (§6.2, §6.6, §6.7): botão redondo à esquerda · título no centro
/// (17 semibold) · botão redondo à direita (ou nada). A esquerda pode ser um texto
/// ("Cancelar" enquanto conecta).
struct CabecalhoDaTela<Esquerda: View, Direita: View>: View {
    let titulo: String
    @ViewBuilder let esquerda: () -> Esquerda
    @ViewBuilder let direita: () -> Direita

    var body: some View {
        ZStack {
            Text(titulo)
                .font(Estilo.corpo(.body, .semibold))
                .foregroundColor(Estilo.texto)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack {
                esquerda()
                Spacer(minLength: 0)
                direita()
            }
        }
        .frame(minHeight: 44)
    }
}

// =================================================================================================
// MARK: - Cartões e ladrilhos
// =================================================================================================

/// **O cartão de papel** (§4): os dois grandes do Início. Cantos 22, padding 16, ícone num quadrado de
/// 44 com cantos 13, título de cartão (`.title2`, 22 pesado) e uma linha de explicação (13).
///
/// `destaque` (Espelhar): fundo `acento` e ícone em branco a 18 %. Sem destaque (Exibir): `superficie`
/// com `contorno` e ícone em `acentoFundo`/`acentoClaro`.
struct CartaoDePapel: View {
    let icone: String
    let titulo: String
    let texto: String
    var destaque = false
    var alturaMinima: CGFloat = 150
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icone)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(destaque ? .white : Estilo.acentoClaro)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(destaque ? Color.white.opacity(0.18) : Estilo.acentoFundo))
                Spacer(minLength: 14)
                Text(titulo)
                    .font(Estilo.titulo(.title2))
                    .foregroundColor(destaque ? .white : Estilo.texto)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(texto)
                    .font(Estilo.corpo(.footnote))
                    .foregroundColor(destaque ? Color.white.opacity(0.9) : Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: alturaMinima, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(destaque ? Estilo.acento : Estilo.superficie))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(destaque ? Color.clear : Estilo.contorno, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.toque)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(titulo)
        .accessibilityHint(texto)
        .accessibilityAddTraits(.isButton)
    }
}

/// **O ladrilho** (§4): cantos 18, `superficie` com `contorno`, ícone num quadrado de 34 (cantos 10,
/// `acentoFundo`, ícone `acentoClaro`), título semibold (`.subheadline`) e legenda (`.caption`) em
/// `texto2`.
///
/// Escolhido: fundo `acento` a 14 %, borda de 2 em `acento` e o selo redondo com ✓ no canto.
/// `deitado`: o ícone à esquerda.
struct Ladrilho: View {
    let icone: String
    let titulo: String
    var legenda: String? = nil
    var escolhido = false
    var deitado = false
    var alturaMinima: CGFloat = 0
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Group {
                if deitado {
                    HStack(spacing: 12) { quadrado; textos }
                } else {
                    VStack(alignment: .leading, spacing: 8) { quadrado; textos }
                }
            }
            .padding(12)
            .padding(.trailing, escolhido && deitado ? 20 : 0)
            .frame(maxWidth: .infinity, minHeight: alturaMinima, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(escolhido ? Estilo.acento.opacity(0.14) : Estilo.superficie))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(escolhido ? Estilo.acento : Estilo.contorno, lineWidth: escolhido ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if escolhido {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Estilo.acento))
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.toque)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(titulo)
        .accessibilityHint(legenda ?? "")
        .accessibilityAddTraits(escolhido ? [.isButton, .isSelected] : .isButton)
    }

    private var quadrado: some View {
        Image(systemName: icone)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(escolhido ? Color(red: 0.88, green: 0.86, blue: 1) : Estilo.acentoClaro)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(escolhido ? Estilo.acento.opacity(0.3) : Estilo.acentoFundo))
    }

    private var textos: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(titulo)
                .font(Estilo.corpo(.subheadline, .semibold))
                .foregroundColor(Estilo.texto)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let legenda {
                Text(legenda)
                    .font(Estilo.corpo(.caption))
                    .foregroundColor(Estilo.texto2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

// =================================================================================================
// MARK: - Estado, PIN, endereço
// =================================================================================================

/// **A pílula de estado** (§4): a luz de estúdio. Altura 28, cápsula, bolinha de 8 e a palavra em
/// `.caption` bold, caixa alta e espaçada.
///
/// NO AR / REC / SEM CÂMERA: fundo `noArCheio`, texto e bolinha brancos. AGUARDANDO: âmbar a 16 % e
/// `#FFC870`. CONECTADO: verde a 14 % e `#6BE07F`. `girando` troca a bolinha por um indicador
/// (ABRINDO, ENCERRANDO).
struct PilulaDeEstado: View {
    enum Tom { case noAr, aguardando, conectado }

    let tom: Tom
    let palavra: String
    var girando = false
    /// A palavra em mono (REC 00:12): os dígitos não dançam enquanto o tempo corre.
    var mono = false

    var body: some View {
        HStack(spacing: 8) {
            if girando {
                ProgressView()
                    .tint(bolinha)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else {
                Circle().fill(bolinha).frame(width: 8, height: 8)
            }
            Text(palavra.uppercased(with: Estilo.localDaCaixaAlta))
                .font(mono ? Estilo.mono(.caption, .bold) : Estilo.corpo(.caption, .bold))
                .tracking(mono ? 0.3 : 0.96)
                .lineLimit(1)
        }
        .foregroundColor(frente)
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(Capsule().fill(fundo))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(palavra)
    }

    private var fundo: Color {
        switch tom {
        case .noAr: return Estilo.noArCheio
        case .aguardando: return Estilo.aguardando.opacity(0.16)
        case .conectado: return Estilo.conectado.opacity(0.14)
        }
    }

    private var frente: Color {
        switch tom {
        case .noAr: return .white
        case .aguardando: return Estilo.aguardandoTexto
        case .conectado: return Estilo.conectadoTexto
        }
    }

    private var bolinha: Color {
        switch tom {
        case .noAr: return .white
        case .aguardando: return Estilo.aguardando
        case .conectado: return Estilo.conectado
        }
    }
}

/// Uma casa do letreiro: `superficie` com borda branca a 10 %, cantos 12, o dígito em mono bold.
///
/// A largura é flexível entre 30 pt e a de desenho: numa coluna estreita (o iPad em Slide Over, ~280
/// pt) as seis casas encolhem em vez de passar da borda. A altura é a de desenho vezes a escala da
/// letra (`FileiraDoPin`), e o dígito (`.largeTitle`) encolhe se não couber na casa.
private struct CasaDoPin: View {
    let digito: String
    let tamanho: CGSize
    var daVez = false

    var body: some View {
        Text(digito)
            .font(Estilo.mono(.largeTitle, .bold))
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .foregroundColor(Estilo.texto)
            .frame(minWidth: min(30, tamanho.width), idealWidth: tamanho.width, maxWidth: tamanho.width)
            .frame(height: tamanho.height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Estilo.superficie))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(daVez ? Estilo.acento : Estilo.bordaDoCampo, lineWidth: daVez ? 2 : 1))
    }
}

/// As seis casas em dois grupos de três: 7 de espaço entre casas e 10 a mais entre os grupos (§4).
/// As casas crescem com a letra do sistema (§11.1), até o teto de cada tela, e encolhem na largura
/// quando falta espaço (`CasaDoPin`).
private struct FileiraDoPin: View {
    let digitos: [String]
    let tamanho: CGSize
    var daVez: Int? = nil
    /// Quanto a letra do sistema está acima da padrão, medido no título.
    @ScaledMetric(relativeTo: .title) private var escala: CGFloat = 1

    var body: some View {
        let casa = CGSize(width: tamanho.width * escala, height: tamanho.height * escala)
        HStack(spacing: 7) {
            ForEach(0..<6, id: \.self) { i in
                if i == 3 { Color.clear.frame(width: 3, height: 1) }
                CasaDoPin(digito: i < digitos.count ? digitos[i] : "", tamanho: casa, daVez: daVez == i)
            }
        }
    }
}

/// **O letreiro do PIN** (§4): seis casas de 44 × 60 no celular, o dígito em mono bold. O leitor de
/// tela diz "PIN 4 8 2 7 1 9".
struct LetreiroDoPin: View {
    let pin: String
    var casa = CGSize(width: 44, height: 60)

    var body: some View {
        FileiraDoPin(digitos: pin.map { String($0) }, tamanho: casa)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Estilo.pinSoletrado(pin))
    }
}

/// **As casas do PIN para digitar** (Exibir, Controlar): as mesmas do letreiro, com a casa da vez em
/// borda de 2 no `acento` enquanto o teclado está aberto.
///
/// Por baixo do desenho há um `TextField` de teclado numérico, com o texto e o cursor transparentes,
/// que **não recebe toque** (`allowsHitTesting(false)`): quem recebe é a fileira, e o toque só dá o
/// foco. Com o toque no campo, o iOS punha o cursor escondido perto do dígito tocado — depois de um
/// "PIN errado", tocar na primeira casa deixava o cursor na posição 0, o Apagar não apagava nada e o
/// "5" digitado virava "548271". Sem toque, o foco chega pelo `FocusState` e o cursor fica sempre no
/// fim. O leitor de tela vê um elemento só, "PIN", com os dígitos como valor.
///
/// Aceita só dígitos, no máximo seis, e **fecha o teclado quando o sexto entra** (o teclado numérico
/// não tem tecla de fechar, e cobre o Conectar no iPhone 7 — §11.2).
struct CasasDoPin<Campo: Hashable>: View {
    @Binding var pin: String
    var foco: FocusState<Campo?>.Binding
    let campo: Campo
    var casa = CGSize(width: 44, height: 60)
    /// Muda quando o campo guardou algo que o filtro cortou (um sétimo dígito, um espaço colado):
    /// o `pin` não muda, e sem refazer o campo o texto escondido dele ficaria diferente do desenhado.
    @State private var geracao = 0

    var body: some View {
        let digitos = pin.map { String($0) }
        let focado = foco.wrappedValue == campo
        FileiraDoPin(digitos: digitos, tamanho: casa, daVez: focado ? min(digitos.count, 5) : nil)
            .overlay(
                TextField("", text: Binding(get: { pin }, set: aceitar))
                    .keyboardType(.numberPad)
                    .foregroundColor(.clear)
                    .accentColor(.clear)
                    .tint(.clear)
                    .focused(foco, equals: campo)
                    .allowsHitTesting(false)
                    .id(geracao)
            )
            .contentShape(Rectangle())
            .onTapGesture { foco.wrappedValue = campo }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "PIN"))
            .accessibilityValue(pin.isEmpty ? tr("vazio") : pin.map { String($0) }.joined(separator: " "))
            .accessibilityHint(tr("Toque duas vezes para digitar"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { foco.wrappedValue = campo }
    }

    private func aceitar(_ novo: String) {
        let limpo = String(novo.filter(\.isNumber).prefix(6))
        let completou = limpo.count == 6 && pin.count != 6
        let cortou = limpo != novo
        pin = limpo
        // O teclado fecha quando o sexto dígito entra — não a cada toque num PIN já completo, que
        // é o jeito de corrigir um dígito (apagar e digitar de novo).
        if completou || cortou {
            let f = foco
            DispatchQueue.main.async {
                if cortou { geracao += 1 }
                if limpo.count == 6 { f.wrappedValue = nil }
            }
        }
    }
}

/// **O chip de endereço** (§4): cápsula de 40, `superficie` com `contorno`, o endereço em mono e o
/// ícone de copiar; o toque copia e diz "Copiado". Sem endereço, "sem rede" em âmbar e nada a copiar.
struct ChipDeEndereco: View {
    let endereco: String?
    var fundo: Color = Estilo.superficie
    @State private var copiado = false

    var body: some View {
        Button(action: copiar) {
            HStack(spacing: 10) {
                Text(endereco ?? tr("sem rede"))
                    .font(Estilo.mono(.callout))
                    .foregroundColor(endereco == nil ? Estilo.aguardandoTexto : Estilo.texto)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if endereco != nil {
                    if copiado {
                        Text(tr("Copiado"))
                            .font(Estilo.corpo(.footnote, .semibold))
                            .foregroundColor(Estilo.acentoClaro)
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Estilo.acentoClaro)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(Capsule().fill(fundo))
            .overlay(Capsule().stroke(Estilo.contorno, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.toque)
        .disabled(endereco == nil)
        .accessibilityLabel(endereco.map { tr("Copiar o endereço %@", $0) } ?? tr("Sem rede"))
        .accessibilityValue(copiado ? tr("Copiado") : "")
    }

    private func copiar() {
        guard let endereco else { return }
        UIPasteboard.general.string = endereco
        withAnimation(.easeOut(duration: 0.15)) { copiado = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.15)) { copiado = false }
        }
    }
}

// =================================================================================================
// MARK: - Aviso, rótulo, campo
// =================================================================================================

/// **O aviso** (§4): cantos 14, ícone e texto (`.footnote`). Âmbar (`#FFB340` a 12 % / `#FFC870`),
/// vermelho (16 % / `#FF8A80`) ou informação (`superficie` / `texto2`, ícone `acentoClaro`); ação
/// opcional em semibold. Substitui o `Aviso` que morava em `TelaInicial` — a chamada de antes
/// (`texto:acao:aoTocar:`) continua valendo, em âmbar.
struct Aviso: View {
    enum Tom { case ambar, vermelho, informacao }

    let texto: String
    var tom: Tom = .ambar
    var icone: String? = nil
    var acao: String? = nil
    var aoTocar: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icone ?? iconePadrao)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(corDoIcone)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(texto)
                    .font(Estilo.corpo(.footnote))
                    .foregroundColor(frente)
                    .fixedSize(horizontal: false, vertical: true)
                if let acao, let aoTocar {
                    Button(acao, action: aoTocar)
                        .font(Estilo.corpo(.footnote, .semibold))
                        .foregroundColor(tom == .informacao ? Estilo.acentoClaro : frente)
                }
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fundo))
        .accessibilityElement(children: .combine)
    }

    private var iconePadrao: String {
        switch tom {
        case .ambar: return "exclamationmark.triangle.fill"
        case .vermelho: return "exclamationmark.octagon.fill"
        case .informacao: return "info.circle.fill"
        }
    }

    private var fundo: Color {
        switch tom {
        case .ambar: return Estilo.aguardando.opacity(0.12)
        case .vermelho: return Estilo.noAr.opacity(0.16)
        case .informacao: return Estilo.superficie
        }
    }

    private var frente: Color {
        switch tom {
        case .ambar: return Estilo.aguardandoTexto
        case .vermelho: return Estilo.perigoTexto
        case .informacao: return Estilo.texto2
        }
    }

    private var corDoIcone: Color {
        switch tom {
        case .ambar: return Estilo.aguardando
        case .vermelho: return Estilo.perigoTexto
        case .informacao: return Estilo.acentoClaro
        }
    }
}

/// Um aviso como dado, para as pilhas que recolhem o excesso em "+N".
struct ItemDeAviso: Identifiable {
    let id: String
    let texto: String
    var tom: Aviso.Tom = .ambar
    var icone: String? = nil
    var acao: String? = nil
    var aoTocar: (() -> Void)? = nil
}

/// **Os avisos de uma tela, no máximo `maximo` à vista** (§11.1: um nas telas de formulário; dois na
/// câmera, §6.5). O resto recolhe num "+N" que abre e fecha. A ordem é a de quem monta a lista: o
/// que importa mais vem primeiro.
struct PilhaDeAvisos: View {
    let itens: [ItemDeAviso]
    var maximo = 1
    @State private var abertos = false

    var body: some View {
        VStack(spacing: 10) {
            ForEach(abertos ? itens : Array(itens.prefix(maximo))) { a in
                Aviso(texto: a.texto, tom: a.tom, icone: a.icone, acao: a.acao, aoTocar: a.aoTocar)
            }
            if itens.count > maximo {
                let resto = itens.count - maximo
                Button(action: { withAnimation(.easeOut(duration: 0.2)) { abertos.toggle() } }) {
                    Text(abertos ? tr("Recolher") : (resto == 1 ? tr("+1 aviso") : tr("+%ld avisos", resto)))
                        .font(Estilo.corpo(.footnote, .semibold))
                        .foregroundColor(Estilo.acentoClaro)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 28)
                        .background(Capsule().fill(Estilo.acentoFundo))
                }
                .buttonStyle(.toque)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// **O rótulo de seção** (§4): `.caption` semibold (12), caixa alta, +0,08 em, `texto3`.
struct RotuloDeSecao: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }

    var body: some View {
        Text(texto.uppercased(with: Estilo.localDaCaixaAlta))
            .font(Estilo.corpo(.caption, .semibold))
            .tracking(0.96)
            .foregroundColor(Estilo.texto3)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// **O campo** (§4): altura 52, cantos 14, `superficie`, borda branca a 10 %. Endereço sempre em mono
/// (`.title3`, 20).
struct EstiloDeCampo: ViewModifier {
    var mono = false

    func body(content: Content) -> some View {
        content
            .font(mono ? Estilo.mono(.title3) : Estilo.corpo(.body))
            .foregroundColor(Estilo.texto)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Estilo.superficie))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Estilo.bordaDoCampo, lineWidth: 1))
    }
}

extension View {
    func estiloDeCampo(mono: Bool = false) -> some View {
        modifier(EstiloDeCampo(mono: mono))
    }

    /// A coluna das telas de celular: margem de 20 dos lados e, no iPad em pé, no máximo 480 de
    /// largura, centrada. `larga`: sem o teto de largura (as duas colunas da paisagem).
    func colunaDoQuall(larga: Bool = false) -> some View {
        frame(maxWidth: larga ? .infinity : Estilo.larguraMaxima)
            .padding(.horizontal, Estilo.margem)
            .frame(maxWidth: .infinity)
    }
}

/// O chip pequeno de cápsula (32 de altura): "Usar o último · {endereço}" em `acentoFundo`, e o da
/// qualidade "{resolução} · {fps} ›" em `superficie`.
struct ChipPequeno: View {
    let texto: String
    var detalheMono: String? = nil
    /// O texto todo em mono (o chip da qualidade: "1080p · 30").
    var mono = false
    var icone: String? = nil
    var iconeDepois: String? = nil
    var violeta = false
    var apagado = false
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 6) {
                if let icone {
                    Image(systemName: icone).font(.system(size: 12, weight: .semibold))
                }
                Text(texto)
                    .font(mono ? Estilo.mono(.footnote) : Estilo.corpo(.footnote, violeta ? .medium : .regular))
                    .lineLimit(1)
                if let detalheMono {
                    Text(detalheMono).font(Estilo.mono(.footnote)).lineLimit(1)
                }
                if let iconeDepois {
                    Image(systemName: iconeDepois).font(.system(size: 11, weight: .bold))
                        .foregroundColor(violeta ? nil : Estilo.texto3)
                }
            }
            .minimumScaleFactor(0.7)
            .foregroundColor(violeta ? Color(red: 0.79, green: 0.76, blue: 1) : Estilo.texto)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Capsule().fill(violeta ? Estilo.acentoFundo : Estilo.superficie))
            .overlay(Capsule().stroke(violeta ? Color.clear : Estilo.contorno, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(apagado ? 0.45 : 1)
        }
        .buttonStyle(.toque)
        .disabled(apagado)
    }
}
