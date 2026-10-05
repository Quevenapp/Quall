import CoreText
import SwiftUI
import UIKit

// ================================================================================================
// Os ajustes locais do prompter: "Enquadramento" e "Fonte automática"
// (`docs/teleprompter-ajustes-locais.md` §2, §3 e §5, decisões do usuário em 14/09/2026).
//
// **Local**: guardado só neste aparelho (`UserDefaults`), fora do salvo do núcleo; o controle não
// o vê nem o muda; nenhuma mensagem nova no fio. A fonte automática **escolhe** uma fonte, e essa
// escolha vai ao núcleo por `definirFonte` como qualquer outra — o controle vê a fonte em uso.
// ================================================================================================

/// As duas marcas do enquadramento, como fração da largura da vista (0 = borda esquerda).
struct Enquadramento: Equatable {
    var esquerda = 0.0
    var direita = 1.0

    /// A coluna nunca fica mais estreita que isto (fração da largura da vista).
    static let colunaMinima = 0.25
    static let inteiro = Enquadramento()
}

/// O enquadramento **por orientação**: o de paisagem não é o de retrato (§2). A orientação é a da
/// vista do texto — mais larga que alta é paisagem —, o que vale também com o texto girado dentro
/// da vista (`GiroDoTexto`).
struct EnquadramentosPorOrientacao: Equatable {
    var retrato = Enquadramento.inteiro
    var paisagem = Enquadramento.inteiro

    func para(largura: Double, altura: Double) -> Enquadramento { largura > altura ? paisagem : retrato }

    /// `"0.1000,0.9000;0.0000,1.0000"` (retrato; paisagem).
    var texto: String {
        String(format: "%.4f,%.4f;%.4f,%.4f", retrato.esquerda, retrato.direita, paisagem.esquerda, paisagem.direita)
    }

    init() {}

    init?(texto: String) {
        let n = texto.split(whereSeparator: { $0 == "," || $0 == ";" }).compactMap { Double($0) }
        guard n.count == 4, n.allSatisfy({ (0...1).contains($0) }), n[1] - n[0] >= Enquadramento.colunaMinima - 1e-9,
              n[3] - n[2] >= Enquadramento.colunaMinima - 1e-9 else { return nil }
        retrato = Enquadramento(esquerda: n[0], direita: n[1])
        paisagem = Enquadramento(esquerda: n[2], direita: n[3])
    }
}

/// **Os ajustes deste aparelho**, vivos na tela do prompter.
final class AjustesLocais: ObservableObject {
    static let chaveDoEnquadramento = "teleprompter.enquadramento"
    static let chaveDaFonteAutomatica = "teleprompter.fonte-automatica"

    @Published private(set) var enquadramentos: EnquadramentosPorOrientacao
    @Published private(set) var fonteAutomatica: Bool
    /// "Fonte automática desligada: o controle mudou a fonte" (§5), por alguns segundos.
    @Published private(set) var aviso: String?
    /// A conta da fonte automática em curso, e o último resultado.
    @Published private(set) var calculando = false
    @Published private(set) var ultimoResultado: MotorDaFonteAutomatica.Resultado?

    /// O tamanho da vista do texto agora (a camada das marcas o grava): diz se o enquadramento em uso
    /// é o de retrato ou o de paisagem, também com o texto girado dentro da vista.
    var tamanhoDaVista = CGSize.zero
    var paisagemAgora: Bool { tamanhoDaVista.width > tamanhoDaVista.height }

    /// A última fonte que a automática mandou ao núcleo: uma fonte diferente dela, com a
    /// automática ligada, veio de fora (o controle) — a da própria folha fica travada.
    private var ultimaFonteAutomatica: Double?
    private let motor = MotorDaFonteAutomatica()
    private weak var modelo: ModeloDoTeleprompter?

    init() {
        let d = UserDefaults.standard
        enquadramentos = d.string(forKey: AjustesLocais.chaveDoEnquadramento)
            .flatMap(EnquadramentosPorOrientacao.init(texto:)) ?? EnquadramentosPorOrientacao()
        fonteAutomatica = d.bool(forKey: AjustesLocais.chaveDaFonteAutomatica)
    }

    func ligar(_ m: ModeloDoTeleprompter) { modelo = m }

    // --- Enquadramento ----------------------------------------------------------------------------

    /// Muda o enquadramento da orientação `paisagem`. Durante o arrasto não grava; ao soltar, grava.
    func enquadrar(_ e: Enquadramento, paisagem: Bool, gravar: Bool) {
        var novo = enquadramentos
        if paisagem { novo.paisagem = e } else { novo.retrato = e }
        if novo != enquadramentos { enquadramentos = novo }
        if gravar {
            UserDefaults.standard.set(enquadramentos.texto, forKey: AjustesLocais.chaveDoEnquadramento)
            DiarioDoTeleprompter.dizer(String(format: "enquadramento (%@): %.4f a %.4f da largura", paisagem ? "paisagem" : "retrato",
                                              e.esquerda, e.direita))
        }
    }

    // --- Fonte automática -------------------------------------------------------------------------

    func definirFonteAutomatica(_ ligada: Bool, por quem: String) {
        fonteAutomatica = ligada
        UserDefaults.standard.set(ligada, forKey: AjustesLocais.chaveDaFonteAutomatica)
        if ligada { aviso = nil }
        ultimaFonteAutomatica = nil
        DiarioDoTeleprompter.dizer("fonte automática: \(ligada ? "ligada" : "desligada") (\(quem))")
    }

    /// O texto, o enquadramento, a orientação ou a margem mudaram: a conta de novo, se ligada.
    func recalcular(texto: String, largura: CGFloat, porque: String) {
        guard fonteAutomatica, !texto.isEmpty, largura > 20 else { return }
        calculando = true
        let pedidoEm = CACurrentMediaTime()
        motor.calcular(texto: texto, largura: largura) { [weak self] r in
            guard let self, self.fonteAutomatica else { return }
            self.calculando = false
            self.ultimoResultado = r
            self.ultimaFonteAutomatica = r.fonte
            self.modelo?.definirFonte(r.fonte)
            DiarioDoTeleprompter.dizer(String(format: "fonte automática: %.0f pt (%@; largura %.0f pt, %d bytes, %d provas, "
                                              + "%d rejeitadas pela amostra de %d bytes; %.0f ms fora da principal, %.0f ms "
                                              + "depois do pedido)", r.fonte, porque, Double(largura), r.bytes, r.provas,
                                              r.rejeitadasPelaAmostra, r.bytesDaAmostra, r.ms,
                                              (CACurrentMediaTime() - pedidoEm) * 1000))
        } conferencia: { c in
            DiarioDoTeleprompter.dizer(c)
        }
    }

    /// A fonte do estado mudou. Com a automática ligada, uma fonte que não é a dela veio do
    /// controle: desliga, com aviso (§5). Vale o último que mudou.
    func fonteMudou(_ f: Double) {
        guard fonteAutomatica, let minha = ultimaFonteAutomatica, abs(f - minha) > 0.05 else { return }
        definirFonteAutomatica(false, por: String(format: "o controle mudou a fonte para %.1f", f))
        mostrarAviso(tr("Fonte automática desligada: o controle mudou a fonte"))
    }

    private func mostrarAviso(_ a: String) {
        aviso = a
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.aviso == a { self?.aviso = nil }
        }
    }
}

/// **A conta da fonte automática, fora da thread principal**, pelo mesmo motor de quebra de linha
/// da vista (`DiagramaDoRoteiro`, CoreText): busca binária de 8 a 400 pt, de 1 em 1.
///
/// # A amostra
///
/// Cada prova quebra primeiro **o começo do roteiro** — até o fim do primeiro parágrafo depois de
/// ``tamanhoDaAmostra`` caracteres. A quebra é gulosa a partir do início, e um parágrafo inteiro
/// quebra igual sozinho ou no meio do roteiro: uma violação na amostra é uma violação no roteiro, e
/// a prova para ali (é o que corta o custo das fontes grandes demais). Uma prova que passa na
/// amostra **confere o roteiro inteiro**: a regra vale no texto todo, nunca só na amostra.
final class MotorDaFonteAutomatica {
    struct Resultado: Equatable {
        var fonte: Double
        var provas: Int
        var rejeitadasPelaAmostra: Int
        var bytes: Int
        var bytesDaAmostra: Int
        /// Tempo da busca, na fila, em ms.
        var ms: Double
    }

    static let tamanhoDaAmostra = 6_000

    private let fila = DispatchQueue(label: "br.com.queven.quall.teleprompter.fonte-automatica", qos: .userInitiated)
    private let pedidos = ContadorDePedidos()

    /// A conta; `pronto` na principal, só se nenhum pedido mais novo chegou. `conferencia` (na
    /// principal, depois) diz o que a regra viu na fonte escolhida e na seguinte.
    func calcular(texto: String, largura: CGFloat, pronto: @escaping (Resultado) -> Void,
                  conferencia: @escaping (String) -> Void) {
        let g = pedidos.proximo()
        let pedidos = self.pedidos
        fila.async {
            guard pedidos.atual == g else { return }
            let comeco = CACurrentMediaTime()
            let ns = texto as NSString
            var corte = ns.length
            if ns.length > MotorDaFonteAutomatica.tamanhoDaAmostra {
                let fimDoParagrafo = ns.rangeOfCharacter(from: .newlines, options: [],
                                                         range: NSRange(location: MotorDaFonteAutomatica.tamanhoDaAmostra,
                                                                        length: ns.length - MotorDaFonteAutomatica.tamanhoDaAmostra))
                if fimDoParagrafo.location != NSNotFound { corte = fimDoParagrafo.location + 1 }
            }
            let amostra = corte < ns.length ? ns.substring(to: corte) : nil
            var cancelado = false
            var rejeitadas = 0

            func diagrama(_ t: String, _ f: Double) -> DiagramaDoRoteiro? {
                let fonte = UIFont.systemFont(ofSize: CGFloat(f), weight: .semibold) as CTFont
                let d = DiagramaDoRoteiro.diagramar(t, fonte: fonte, tamanho: f, largura: largura, alturaDaLinha: f * 1.2,
                                                    geracao: g, deveParar: { pedidos.atual != g })
                if d == nil { cancelado = true }
                return d
            }
            func violacao(_ d: DiagramaDoRoteiro, _ t: NSString) -> Int? {
                RegraDaFonteAutomatica.violacao(inicios: d.tabela.inicios, texto: t)
            }
            let r = RegraDaFonteAutomatica.maior { f in
                if cancelado || pedidos.atual != g { cancelado = true; return false }
                if let amostra {
                    guard let da = diagrama(amostra, f) else { return false }
                    if violacao(da, amostra as NSString) != nil { rejeitadas += 1; return false }
                }
                guard let d = diagrama(texto, f) else { return false }
                return violacao(d, ns) == nil
            }
            guard !cancelado, pedidos.atual == g else { return }
            let resultado = Resultado(fonte: r.fonte, provas: r.provas, rejeitadasPelaAmostra: rejeitadas,
                                      bytes: texto.utf8.count, bytesDaAmostra: amostra?.utf8.count ?? texto.utf8.count,
                                      ms: (CACurrentMediaTime() - comeco) * 1000)
            DispatchQueue.main.async { if pedidos.atual == g { pronto(resultado) } }

            // A conferência, depois de entregar (não atrasa a fonte): a regra na tabela de linhas do
            // diagrama do roteiro inteiro, na fonte escolhida e na seguinte.
            guard let d = diagrama(texto, r.fonte) else { return }
            var fimDeParagrafo = 0, longas = 0, sozinhas = 0, partidas = 0
            let n = d.tabela.quantas
            for i in 0..<n {
                switch RegraDaFonteAutomatica.linha(i, inicios: d.tabela.inicios, texto: ns) {
                case .ok: break
                case .fimDeParagrafo: fimDeParagrafo += 1
                case .palavraLonga: longas += 1
                case .sozinha: sozinhas += 1
                case .partida: partidas += 1
                }
            }
            var acima = "a fonte máxima"
            if r.fonte < RegraDaFonteAutomatica.maximo, let d1 = diagrama(texto, r.fonte + 1) {
                if let i = violacao(d1, ns) {
                    let a = d1.tabela.inicios[i], b = i + 1 < d1.tabela.quantas ? d1.tabela.inicios[i + 1] : ns.length
                    if RegraDaFonteAutomatica.linha(i, inicios: d1.tabela.inicios, texto: ns) == .partida {
                        acima = String(format: "a %.0f pt a linha %d (de %d) acabaria no meio de uma palavra (\"%@\")",
                                       r.fonte + 1, i, d1.tabela.quantas, ns.substring(with: NSRange(location: a, length: b - a)))
                    } else {
                        let letras = RegraDaFonteAutomatica.letras(ns.substring(with: NSRange(location: a, length: b - a)))
                        acima = String(format: "a %.0f pt a linha %d (de %d) ficaria com uma palavra só, de %d letras",
                                       r.fonte + 1, i, d1.tabela.quantas, letras)
                    }
                } else {
                    acima = String(format: "a %.0f pt também passaria (a busca supõe a regra monótona)", r.fonte + 1)
                }
            }
            let texto = String(format: "fonte automática: conferência a %.0f pt — %d linhas, %d com uma palavra no fim de "
                               + "parágrafo, %d com uma palavra de 12 letras ou mais, %d com uma palavra curta sozinha "
                               + "e %d partidas no meio de uma palavra (violações); %@",
                               r.fonte, n, fimDeParagrafo, longas, sozinhas, partidas, acima)
            DispatchQueue.main.async { conferencia(texto) }
        }
    }
}

// ================================================================================================
// As marcas do enquadramento
// ================================================================================================

/// O arrasto de uma marca: o reconhecedor chama ``mover(lado:deX:paraX:largura:paisagem:)`` e
/// ``soltar(lado:deX:paraX:largura:paisagem:)``; a bancada chama os mesmos.
final class ArrastoDoEnquadramento: ObservableObject {
    enum Lado { case esquerda, direita }

    @Published private(set) var lado: Lado?
    private var inicial = Enquadramento.inteiro
    private weak var ajustes: AjustesLocais?

    func ligar(_ a: AjustesLocais) { ajustes = a }

    private func valor(_ l: Lado, deX: CGFloat, paraX: CGFloat, largura: CGFloat) -> Enquadramento {
        var e = inicial
        let d = Double((paraX - deX) / max(1, largura))
        switch l {
        case .esquerda: e.esquerda = min(e.direita - Enquadramento.colunaMinima, max(0, inicial.esquerda + d))
        case .direita: e.direita = max(e.esquerda + Enquadramento.colunaMinima, min(1, inicial.direita + d))
        }
        return e
    }

    func mover(lado l: Lado, deX: CGFloat, paraX: CGFloat, largura: CGFloat, paisagem: Bool) {
        guard let a = ajustes, largura > 1 else { return }
        if lado == nil {
            lado = l
            inicial = paisagem ? a.enquadramentos.paisagem : a.enquadramentos.retrato
        }
        a.enquadrar(valor(l, deX: deX, paraX: paraX, largura: largura), paisagem: paisagem, gravar: false)
    }

    func soltar(lado l: Lado, deX: CGFloat, paraX: CGFloat, largura: CGFloat, paisagem: Bool) {
        guard let a = ajustes, largura > 1 else { return }
        if lado == nil { inicial = paisagem ? a.enquadramentos.paisagem : a.enquadramentos.retrato }
        a.enquadrar(valor(l, deX: deX, paraX: paraX, largura: largura), paisagem: paisagem, gravar: true)
        lado = nil
    }
}

/// **As duas marcas do "Enquadramento"** (§2), por cima da vista do texto e com o mesmo quadro:
/// um triângulo no alto de cada borda da coluna, apontando para baixo — distinto das setas da
/// linha de leitura, e cedendo a elas (ver
/// ``alturaDaMarca(altura:quadro:fundoDoAlto:topoDaBarra:linhaDeLeitura:giro:)``) —, e uma guia
/// vertical fina em cada borda enquanto a barra ou a folha de ajustes estão à mostra e durante o
/// arrasto. Cada uma anda sozinha, na horizontal; a zona de toque (60 × 72 pt) é maior que o
/// desenho, e o resto da camada não é tocável: arrastar o texto não mexe no enquadramento.
///
/// **Com espelho, as marcas espelham junto com o texto** (a da esquerda na tela é a da direita no
/// vidro): a camada inteira é espelhada, e o arrasto mede dentro dela.
///
/// É também daqui que sai o pedido da fonte automática: esta camada vê o texto, a largura da vista
/// e o enquadramento — tudo o que muda a largura da coluna.
struct EnquadramentoDoTexto: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    @ObservedObject var ajustes: AjustesLocais
    /// As guias verticais nas duas bordas: com a barra ou a folha de ajustes à mostra.
    var guias = false
    /// O fundo do que cobre o alto da tela — a faixa do PIN e os avisos —, em coordenadas globais.
    var fundoDoAlto: CGFloat = 0
    /// O topo da barra de baixo, em coordenadas globais (`.greatestFiniteMagnitude`: sem barra).
    var topoDaBarra: CGFloat = .greatestFiniteMagnitude
    /// O giro do texto dentro da vista (`GiroDoTexto`), em graus.
    var giro: Double = 0
    /// **As marcas no pé da vista**, e não no alto: na tela com câmera, quando o alto do texto é o
    /// lado da lente (pedido do Pessoa Exemplo, 24/09: nada entre o texto e a lente, nem sobre as primeiras
    /// linhas do lado dela). Só com o texto sem giro; girado, a conta de sempre.
    var noPe = false
    @StateObject private var arrasto = ArrastoDoEnquadramento()

    static let zona = CGSize(width: 60, height: 72)
    /// O triângulo: do tamanho das setas da linha de leitura (12 × 12 pt), um pouco mais largo.
    static let marca = CGSize(width: 16, height: 13)

    /// **Onde as marcas ficam: no alto, apontando para baixo** — como no Android, no Mac e no
    /// Windows: é o mesmo controle nos quatro aparelhos, e o usuário alterna entre eles no suporte
    /// (decisão de 14/09, que desfez a primeira ida delas para o pé). Devolve a altura do centro do
    /// triângulo, na vista (`h` de altura, `quadro` em coordenadas globais).
    ///
    /// - **Logo abaixo do que cobre o alto** (a faixa do PIN e os avisos, `fundoDoAlto`): com um
    ///   aviso no alto, as marcas descem para logo abaixo dele — nunca ficam sob ele (no iOS, o
    ///   aviso vermelho as escondia, a 84 pt fixos do alto).
    /// - **Nunca sob a barra** de baixo.
    /// - **A linha de leitura vence**: onde a zona de uma marca cruzaria a das setas da linha, a marca
    ///   vai para logo abaixo delas (ou logo acima, se abaixo não couber); e a camada das setas fica
    ///   por cima desta, então no que sobrar de sobreposição é ela que pega o toque.
    ///
    /// Com o texto girado 180°, a mesma conta, espelhada; girado 90° ou 270°, as bordas da coluna
    /// ficam no alto e no pé da tela, sob a faixa e a barra fora da tela cheia — ali as marcas vão ao
    /// meio, e só a tela cheia as deixa livres.
    static func alturaDaMarca(altura h: CGFloat, quadro: CGRect, fundoDoAlto: CGFloat, topoDaBarra: CGFloat,
                              linhaDeLeitura: Double, giro: Double, noPe: Bool = false) -> CGFloat {
        guard giro == 0 || giro == 180 else { return h / 2 }
        if noPe && giro == 0 {
            // O espelho da conta de baixo: logo acima do pé (ou da barra), e a linha de leitura
            // vence — a marca vai para logo acima da zona das setas, ou logo abaixo se não couber.
            let de = max(0, fundoDoAlto - quadro.minY)
            let ate = min(h, topoDaBarra - quadro.minY)
            let meiaZona = zona.height / 2
            let meiaDaLinha = AlcasDaLinhaDeLeitura.zonaDaSeta.height / 2
            let yLinha = CGFloat(min(1, max(0, linhaDeLeitura))) * h
            var y = ate - 6 - marca.height / 2
            if abs(y - yLinha) < meiaZona + meiaDaLinha {
                let acima = yLinha - meiaDaLinha - meiaZona
                let abaixo = yLinha + meiaDaLinha + meiaZona
                if abaixo + marca.height / 2 + 4 <= ate {
                    y = abaixo
                } else if acima - marca.height / 2 >= de {
                    y = acima
                }
            }
            return max(marca.height / 2 + 2, min(h - marca.height / 2 - 2, y))
        }
        // Tudo em "altura na tela a partir do alto da vista"; com o texto girado 180°, o alto da tela
        // é o pé da vista, e a conversão volta no fim.
        let de = max(0, fundoDoAlto - quadro.minY)
        let ate = min(h, topoDaBarra - quadro.minY)
        let meiaZona = zona.height / 2
        let meiaDaLinha = AlcasDaLinhaDeLeitura.zonaDaSeta.height / 2
        let linha = CGFloat(min(1, max(0, linhaDeLeitura))) * h
        let yLinha = giro == 180 ? h - linha : linha
        var y = de + 6 + marca.height / 2
        if abs(y - yLinha) < meiaZona + meiaDaLinha {
            let abaixo = yLinha + meiaDaLinha + meiaZona
            let acima = yLinha - meiaDaLinha - meiaZona
            if abaixo + marca.height / 2 + 4 <= ate {
                y = abaixo
            } else if acima - marca.height / 2 >= de {
                y = acima
            }
        }
        y = min(y, ate - marca.height / 2 - 4)
        y = max(marca.height / 2 + 2, min(h - marca.height / 2 - 2, y))
        return giro == 180 ? h - y : y
    }

    /// A largura da coluna de texto (a mesma conta de `VistaDoRoteiroUIKit.larguraDoTexto`).
    static func larguraDaColuna(largura: CGFloat, enquadramento e: Enquadramento, margem: Double) -> CGFloat {
        max(1, largura * CGFloat((e.direita - e.esquerda) * (1 - 2 * margem)))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let paisagem = w > h
            let e = ajustes.enquadramentos.para(largura: Double(w), altura: Double(h))
            let coluna = EnquadramentoDoTexto.larguraDaColuna(largura: w, enquadramento: e, margem: modelo.estado.margem)
            let y = EnquadramentoDoTexto.alturaDaMarca(altura: h, quadro: geo.frame(in: .global),
                                                        fundoDoAlto: fundoDoAlto, topoDaBarra: topoDaBarra,
                                                        linhaDeLeitura: modelo.estado.linhaDeLeitura, giro: giro,
                                                        noPe: noPe)
            ZStack(alignment: .topLeading) {
                if guias || arrasto.lado != nil {
                    // As guias: a borda da coluna na altura inteira, presa para dentro da tela.
                    ForEach([ArrastoDoEnquadramento.Lado.esquerda, .direita], id: \.self) { l in
                        let x = CGFloat(l == .esquerda ? e.esquerda : e.direita) * w
                        Rectangle().fill(Color.cyan.opacity(arrasto.lado == l ? 0.8 : 0.4)).frame(width: 1.5, height: h)
                            .position(x: min(w - 1, max(1, x)), y: h / 2).allowsHitTesting(false)
                    }
                }
                marca(.esquerda, x: CGFloat(e.esquerda) * w, y: y, largura: w, paisagem: paisagem)
                marca(.direita, x: CGFloat(e.direita) * w, y: y, largura: w, paisagem: paisagem)
            }
            .coordinateSpace(name: "enquadramento")
            // As marcas espelham com o texto; o rótulo, abaixo, não (é para quem mexe).
            .scaleEffect(x: modelo.estado.espelho ? -1 : 1, y: 1)
            .overlay(alignment: .topLeading) {
                if arrasto.lado != nil {
                    Text(tr("Enquadramento: %.0f %% a %.0f %%", e.esquerda * 100, e.direita * 100))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundColor(.black)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.cyan.opacity(0.92)).cornerRadius(8)
                        .position(x: w / 2, y: (giro == 180 || (noPe && giro == 0)) ? y - 40 : y + 40)
                        .allowsHitTesting(false)
                }
            }
            .preference(key: TamanhoDaVistaDoTexto.self, value: geo.size)
            .onAppear {
                ajustes.tamanhoDaVista = geo.size
                arrasto.ligar(ajustes)
                ajustes.ligar(modelo)
                BancadaDosAjustes.ligar(modelo, ajustes, arrasto)
                ajustes.recalcular(texto: modelo.texto, largura: coluna, porque: "a tela abriu")
            }
            .onChange(of: "\(modelo.versaoDoTexto)|\(Int(coluna.rounded()))|\(ajustes.fonteAutomatica)") { _ in
                ajustes.recalcular(texto: modelo.texto, largura: coluna, porque: "texto, enquadramento, margem ou orientação")
            }
            .onChange(of: modelo.estado.fonte) { ajustes.fonteMudou($0) }
        }
        // O tamanho da vista, pelo caminho de preferência: um `onChange(of: geo.size)` dentro do
        // `GeometryReader` não acompanhou o giro do iPhone X (14/09) — a bancada leu o tamanho da
        // abertura, e o enquadramento mexido foi o da outra orientação.
        .onPreferenceChange(TamanhoDaVistaDoTexto.self) { t in
            let virou = (t.width > t.height) != ajustes.paisagemAgora
            ajustes.tamanhoDaVista = t
            if virou {
                DiarioDoTeleprompter.dizer("enquadramento: a vista do texto está em \(Int(t.width))x\(Int(t.height)) "
                                           + "(\(t.width > t.height ? "paisagem" : "retrato"))")
            }
        }
    }

    private func marca(_ l: ArrastoDoEnquadramento.Lado, x: CGFloat, y: CGFloat, largura w: CGFloat,
                       paisagem: Bool) -> some View {
        // O desenho fica inteiro na tela (a posição continua 0 e 1), e a zona de toque também —
        // numa marca encostada na borda, a zona anda para dentro e o triângulo fica na ponta dela.
        let m = EnquadramentoDoTexto.marca
        let meia = EnquadramentoDoTexto.zona.width / 2
        let xDesenho = min(w - m.width / 2 - 2, max(m.width / 2 + 2, x))
        let xZona = min(w - meia, max(meia, x))
        return ZStack {
            Color.clear.contentShape(Rectangle())
            Triangulo()
                .fill(Color.cyan.opacity(arrasto.lado == l ? 1 : 0.9))
                .frame(width: m.width, height: m.height)
                // Aponta para baixo, para o texto (com o texto girado 180°, para cima na vista).
                .rotationEffect(.degrees(giro == 180 ? 180 : 0))
                .offset(x: xDesenho - xZona, y: 0)
        }
        .frame(width: EnquadramentoDoTexto.zona.width, height: EnquadramentoDoTexto.zona.height)
        .position(x: xZona, y: y)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("enquadramento"))
            .onChanged { v in arrasto.mover(lado: l, deX: v.startLocation.x, paraX: v.location.x, largura: w, paisagem: paisagem) }
            .onEnded { v in arrasto.soltar(lado: l, deX: v.startLocation.x, paraX: v.location.x, largura: w, paisagem: paisagem) })
        .accessibilityElement()
        .accessibilityLabel(l == .esquerda ? tr("Enquadramento, borda esquerda") : tr("Enquadramento, borda direita"))
    }
}

/// O fundo do que cobre o alto do prompter — a faixa do PIN e os avisos —, em coordenadas globais:
/// as marcas do enquadramento ficam logo abaixo dele.
struct FundoDoAltoDoPrompter: PreferenceKey {
    static var defaultValue = CGFloat.zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// O topo da barra de baixo do prompter (com a legenda de velocidade que fica sobre ela), em
/// coordenadas globais: as marcas do enquadramento ficam acima dele. Sem barra (tela cheia), o
/// padrão — nenhum limite.
struct TopoDaBarraDoPrompter: PreferenceKey {
    static var defaultValue = CGFloat.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// O tamanho da vista do texto, subindo da camada das marcas.
struct TamanhoDaVistaDoTexto: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Um triângulo apontando para baixo.
struct Triangulo: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// O aviso da fonte automática, junto dos outros avisos — visível também na tela cheia.
struct AvisoDaFonteAutomatica: View {
    @ObservedObject var ajustes: AjustesLocais

    var body: some View {
        if let a = ajustes.aviso {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "textformat.size")
                Text(a).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.callout.weight(.semibold))
            // Preto sobre o âmbar do estúdio (`docs/telas-estudio.md` §6.8): branco sobre âmbar
            // não se lê.
            .foregroundColor(.black)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Estilo.aguardando.opacity(0.92))
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A parte da folha de ajustes que é só deste aparelho: a fonte automática e o enquadramento.
struct SecaoDosAjustesLocais: View {
    @ObservedObject var ajustes: AjustesLocais

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { ajustes.fonteAutomatica },
                                 set: { ajustes.definirFonteAutomatica($0, por: "ajustes") })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Fonte automática")).font(.subheadline.weight(.semibold))
                    Text(legendaDaFonte).font(.caption).foregroundColor(.secondary)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Enquadramento")).font(.subheadline.weight(.semibold))
                    Text(tr("Arraste os triângulos do alto para enquadrar o texto. Só deste aparelho."))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(tr("Largura inteira")) {
                    ajustes.enquadrar(.inteiro, paisagem: ajustes.paisagemAgora, gravar: true)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var legendaDaFonte: String {
        guard ajustes.fonteAutomatica else {
            return tr("A maior fonte em que cada linha tem pelo menos duas palavras. Só deste aparelho.")
        }
        if ajustes.calculando { return tr("Calculando…") }
        if let r = ajustes.ultimoResultado { return tr("Agora: %.0f pt. Só deste aparelho.", r.fonte) }
        return tr("Ligada. Só deste aparelho.")
    }
}

/// Os controles do texto, na folha do prompter: com a fonte automática ligada, a fonte à mão fica
/// travada — é o que deixa saber que uma fonte nova, com ela ligada, veio do controle.
struct ControlesDoTextoDoPrompter: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    @ObservedObject var ajustes: AjustesLocais

    var body: some View {
        ControlesDoTexto(modelo: modelo, fonteTravada: ajustes.fonteAutomatica)
    }
}

// ================================================================================================
// A bancada, sem toque
// ================================================================================================

/// **A bancada dos ajustes locais** — lida uma vez:
///
/// - `--fonte-automatica sim|nao`: vale como a escolha da pessoa (é gravada);
/// - `--roteiro-palavras curtas|longas|grande`: faz chegar um roteiro sintético **nosso** — frases
///   de palavras curtas, frases com palavras longas, ou 128 KB do roteiro da varredura —, pelo
///   caminho de sempre (a réplica numa thread que não é a principal, e `recarregar`);
/// - `--enquadrar 0.15,0.8`: arrasta a marca esquerda até 0,15 e a direita até 0,8, pelas mesmas
///   funções que o reconhecedor chama, com `bancada: ajustes: foto N` depois de cada passo;
/// - `--ajustes-rolando`: o texto rolando a 2,5 linhas/s o tempo todo, e depois do enquadramento a
///   margem vai a 0,05 e o outro roteiro chega — cada coisa, uma conta nova da fonte automática.
///
/// **O que ela não prova**: o dedo de verdade nas marcas.
enum BancadaDosAjustes {
    private static var consumida = false

    static func ligar(_ m: ModeloDoTeleprompter, _ a: AjustesLocais, _ arr: ArrastoDoEnquadramento) {
        guard !consumida else { return }
        consumida = true
        let args = CommandLine.arguments
        func valor(_ chave: String) -> String? {
            guard let i = args.firstIndex(of: chave), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let f = valor("--fonte-automatica") { a.definirFonteAutomatica(f == "sim", por: "--fonte-automatica") }
        let roteiro = valor("--roteiro-palavras")
        let alvos = valor("--enquadrar").map { $0.split(separator: ",").compactMap { Double($0) } }
        let rolando = args.contains("--ajustes-rolando")
        guard roteiro != nil || alvos != nil || rolando else { return }
        let t = Thread { [weak m, weak a, weak arr] in
            var foto = 0
            func fotografar(_ o_que: String) {
                foto += 1
                DiarioDoTeleprompter.dizer("bancada: ajustes: foto \(foto) (\(o_que))")
            }
            Thread.sleep(forTimeInterval: 2.5)
            if rolando { DispatchQueue.main.sync { m?.definirVelocidade(2.5); m?.definirRolando(true) } }
            if let roteiro {
                chegar(m, roteiro)
                Thread.sleep(forTimeInterval: 4)
                fotografar("roteiro de palavras \(roteiro)")
                Thread.sleep(forTimeInterval: 2)
            }
            if let alvos, alvos.count == 2 {
                for (lado, alvo) in [(ArrastoDoEnquadramento.Lado.esquerda, alvos[0]), (.direita, alvos[1])] {
                    var tam = CGSize.zero
                    var de: CGFloat = 0
                    DispatchQueue.main.sync {
                        tam = a?.tamanhoDaVista ?? .zero
                        let paisagem = tam.width > tam.height
                        let e = paisagem ? a?.enquadramentos.paisagem : a?.enquadramentos.retrato
                        // O dedo pousa 6 pt para dentro da marca.
                        de = CGFloat(lado == .esquerda ? (e?.esquerda ?? 0) : (e?.direita ?? 1)) * tam.width
                            + (lado == .esquerda ? 6 : -6)
                    }
                    let paisagem = tam.width > tam.height
                    DiarioDoTeleprompter.dizer("bancada: arrastando a marca \(lado == .esquerda ? "esquerda" : "direita") "
                                               + "até \(alvo), vista \(Int(tam.width))x\(Int(tam.height)) "
                                               + "(\(paisagem ? "paisagem" : "retrato"))")
                    let partida = de + (lado == .esquerda ? -6 : 6)
                    let para = de + (CGFloat(alvo) * tam.width - partida)
                    for i in 1...48 {
                        let x = de + (para - de) * CGFloat(i) / 48
                        DispatchQueue.main.sync { arr?.mover(lado: lado, deX: de, paraX: x, largura: tam.width, paisagem: paisagem) }
                        Thread.sleep(forTimeInterval: 1.0 / 60)
                    }
                    DispatchQueue.main.sync { arr?.soltar(lado: lado, deX: de, paraX: para, largura: tam.width, paisagem: paisagem) }
                    Thread.sleep(forTimeInterval: 3.5)
                    fotografar("marca \(lado == .esquerda ? "esquerda" : "direita") em \(alvo)")
                    Thread.sleep(forTimeInterval: 2)
                }
            }
            if rolando {
                DispatchQueue.main.sync { m?.definirMargem(0.05) }
                Thread.sleep(forTimeInterval: 4)
                fotografar("margem 0,05")
                chegar(m, roteiro == "longas" ? "curtas" : "longas")
                Thread.sleep(forTimeInterval: 4)
                fotografar("o outro roteiro chegou")
                DispatchQueue.main.sync { m?.definirRolando(false) }
            }
            DiarioDoTeleprompter.dizer("bancada: ajustes terminados")
        }
        t.name = "quall.teleprompter.ajustes"
        t.start()
    }

    private static func chegar(_ m: ModeloDoTeleprompter?, _ tipo: String) {
        guard let m else { return }
        let texto: String
        switch tipo {
        case "curtas": texto = curtas(10_000)
        case "longas": texto = longas(10_000)
        default: texto = BancadaDoTeleprompter.sintetico(128_000)
        }
        m.replica.definirTexto(texto)
        DiarioDoTeleprompter.dizer("bancada: roteiro de palavras \(tipo) chegando (\(texto.utf8.count) bytes)")
        DispatchQueue.main.async { m.recarregar() }
    }

    /// Frases de palavras curtas, **nossas**.
    static func curtas(_ bytes: Int) -> String {
        var s = "", i = 1
        while s.utf8.count < bytes {
            s += "Parte \(i). Vai e vem, sim ou não, lá e cá, dia a dia, pé ante pé, de vez em quando.\n"
            i += 1
        }
        return s
    }

    /// Frases com palavras longas, **nossas**: a palavra longa sozinha na linha não conta, mas a
    /// palavra curta que ficar sozinha antes dela conta.
    static func longas(_ bytes: Int) -> String {
        var s = "", i = 1
        while s.utf8.count < bytes {
            s += "Parte \(i). O otorrinolaringologista, extraordinariamente responsabilizado, "
                + "desproporcionalmente inconstitucionalíssimo, chegou.\n"
            i += 1
        }
        return s
    }
}
