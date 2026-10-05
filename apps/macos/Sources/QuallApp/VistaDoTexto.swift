import AppKit
import CoreText
import QuartzCore
import QuallTeleprompterKit
import SwiftUI

/// **A vista do texto do prompter**: o roteiro rolando em velocidade constante, com a linha de
/// leitura, a margem e o espelho.
///
/// # Como rola sem saltos
///
/// - O texto é quebrado **uma vez** pelo CoreText (`TextoDiagramado`) a cada troca de texto, fonte,
///   margem ou largura — nunca por quadro.
/// - Ele é pintado em **blocos** (uma `CALayer` por faixa de ~380 pt), cada um desenhado uma vez
///   quando entra na área visível e jogado fora quando sai dela. Rolar é **mover** os blocos: a
///   composição é da GPU, e nenhum pixel de texto é redesenhado por quadro.
/// - O passo de cada quadro vem do relógio da tela (`CADisplayLink` da própria vista, no macOS 14 ou
///   mais novo): `deslocamento += velocidade × altura da linha × dt`, com o `dt` de verdade entre os
///   instantes em que dois quadros vão aparecer (`Rolagem`). Velocidade constante em linhas por
///   segundo, a 60 ou a 120 Hz, e o relógio só roda enquanto o texto rola.
///
/// # O espelho
///
/// Horizontal, na **vista do texto**: uma transformação `scaleX = −1` na camada do palco, que é
/// dona dos blocos e da marca da linha de leitura. O `isFlipped` do AppKit inverte na vertical e
/// não serve (`QuallReceptorKit/VistaDeVideo.swift`); e o espelho não encosta em vídeo nenhum (§3).
///
/// # Por que "layer-hosting"
///
/// A vista cria a própria camada antes de `wantsLayer` e é dona de todas as subcamadas: o AppKit não
/// reposiciona nem redesenha nada por conta própria. O custo é que ela não hospeda subvistas — os
/// avisos que precisam aparecer espelhados ficam no SwiftUI, por cima, com o mesmo espelho.
final class VistaDoTexto: NSView {
    var aoRelatarPosicao: ((Double) -> Void)?
    var aoChegarAoFim: (() -> Void)?
    var aoRegistrar: ((String) -> Void)?

    private let raiz = CALayer()
    private let palco = CALayer()
    private let faixa = CALayer()
    private let seta = CAShapeLayer()
    /// As duas setas do "Enquadramento", no alto das bordas da coluna, apontando para baixo; e a
    /// guia fina que aparece enquanto uma delas é arrastada.
    private let marcasDoQuadro = CAShapeLayer()
    private let guiaDoQuadro = CAShapeLayer()
    /// **Na tela com câmera (R5), as marcas vão ao pé do texto** e as guias só aparecem no arrasto:
    /// nada entre o texto e a lente (`docs/teleprompter-com-camera.md` §8.5, item 2; no Mac, a lente
    /// fica em cima). O prompter comum não muda.
    var marcasNoPe = false {
        didSet { if marcasNoPe != oldValue { posicionar() } }
    }
    private var blocos: [Int: BlocoDeTexto] = [:]

    private var texto = ""
    private var diagramado = TextoDiagramado.vazio
    private var rolagem = Rolagem()
    private var estado = EstadoDoTeleprompter()
    private var larguraDiagramada: CGFloat = -1
    private var precisaRediagramar = true
    private var rediagramacaoAgendada = false
    /// Um salto pedido antes de haver layout (a vista ainda sem tamanho): aplicado depois.
    private var posicaoPendente: Double?
    private var escala: CGFloat = 2
    private var fimAvisado = false

    private var ultimoInstante: CFTimeInterval?
    private var ultimoRelato: CFTimeInterval = 0
    private var ligacaoDeQuadro: AnyObject?
    private var temporizador: Timer?

    // Os números que vão para o registro: é a testemunha de "sem saltos" que não depende de olhar
    // a tela.
    private(set) var quadros = 0
    private(set) var maiorIntervaloMs = 0.0
    /// Quadros que chegaram mais de 1,5 período da tela depois do anterior — cada um é um passo
    /// maior que o normal na tela. Contados só com o texto rolando.
    private(set) var quadrosAtrasados = 0
    var posicao: Double { diagramado.geometria.posicao(paraDeslocamento: rolagem.deslocamento) }
    var quantasLinhas: Int { diagramado.geometria.quantasLinhas }
    var blocosVivos: Int { blocos.count }

    private static let alturaDoBloco: Double = 380
    private static let corDoTexto = CGColor(gray: 1, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        raiz.backgroundColor = CGColor(gray: 0, alpha: 1)
        raiz.masksToBounds = true
        layer = raiz
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        palco.masksToBounds = true
        raiz.addSublayer(palco)

        faixa.backgroundColor = CGColor(gray: 1, alpha: 0.07)
        faixa.zPosition = 10
        palco.addSublayer(faixa)
        seta.fillColor = CGColor(red: 1, green: 0.62, blue: 0.1, alpha: 0.95)
        seta.zPosition = 11
        palco.addSublayer(seta)
        marcasDoQuadro.fillColor = CGColor(red: 1, green: 0.62, blue: 0.1, alpha: 0.95)
        marcasDoQuadro.zPosition = 11
        palco.addSublayer(marcasDoQuadro)
        guiaDoQuadro.strokeColor = CGColor(red: 1, green: 0.62, blue: 0.1, alpha: 0.6)
        guiaDoQuadro.lineWidth = 1
        guiaDoQuadro.zPosition = 11
        guiaDoQuadro.isHidden = true
        palco.addSublayer(guiaDoQuadro)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: - a janela e o relógio da tela

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pararRelogio()
        guard window != nil else { return }
        escala = window?.backingScaleFactor ?? 2
        raiz.contentsScale = escala
        if #available(macOS 14.0, *) {
            // O relógio **desta vista**: acompanha a tela em que a janela está (a do vidro, se ela
            // for levada para lá), sem thread própria — o seletor roda na main.
            let l = displayLink(target: self, selector: #selector(quadro(_:)))
            l.add(to: .main, forMode: .common)
            l.isPaused = true
            ligacaoDeQuadro = l
        }
        atualizarRelogio()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let nova = window?.backingScaleFactor ?? 2
        guard nova != escala else { return }
        escala = nova
        raiz.contentsScale = nova
        // A tela Retina e o monitor do vidro têm escalas diferentes: os blocos são refeitos na nova.
        descartarBlocos()
        posicionar()
    }

    /// Solta o relógio (o `CADisplayLink` segura a vista: sem isto ela nunca iria embora).
    func pararRelogio() {
        if #available(macOS 14.0, *) {
            (ligacaoDeQuadro as? CADisplayLink)?.invalidate()
        }
        ligacaoDeQuadro = nil
        temporizador?.invalidate()
        temporizador = nil
    }

    private func atualizarRelogio() {
        let rolar = estado.rolando && window != nil
        if !rolar { ultimoInstante = nil }
        if #available(macOS 14.0, *), let l = ligacaoDeQuadro as? CADisplayLink {
            if l.isPaused == rolar { l.isPaused = !rolar }
            return
        }
        // macOS 13: um temporizador na main, com o `dt` medido — a velocidade continua constante,
        // só o compasso não é o da tela.
        if rolar, temporizador == nil, window != nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.passo(instante: CACurrentMediaTime(), periodo: 1.0 / 60)
            }
            RunLoop.main.add(t, forMode: .common)
            temporizador = t
        } else if !rolar {
            temporizador?.invalidate()
            temporizador = nil
        }
    }

    @available(macOS 14.0, *)
    @objc private func quadro(_ l: CADisplayLink) {
        // O instante em que **este** quadro vai aparecer: é contra ele que a posição é calculada.
        passo(instante: l.targetTimestamp, periodo: max(0.001, l.targetTimestamp - l.timestamp))
    }

    private func passo(instante t: CFTimeInterval, periodo: CFTimeInterval) {
        guard estado.rolando else {
            atualizarRelogio()
            return
        }
        let dt = ultimoInstante.map { t - $0 } ?? 0
        ultimoInstante = t
        if dt > 0 {
            quadros += 1
            maiorIntervaloMs = max(maiorIntervaloMs, dt * 1000)
            if dt > periodo * 1.5 { quadrosAtrasados += 1 }
        }
        if precisaRediagramar { rediagramar() }
        let g = diagramado.geometria
        if estado.paraTras {
            // "Segurar para rolar" para trás (§12.5): a mesma velocidade, e **para no começo sem
            // mudar `rolando`** — o texto fica ali até o controle soltar. O relato segue igual.
            let chegouAoComeco = rolagem.recuar(dt: dt, velocidade: estado.velocidade, geometria: g)
            if !rolagem.noFim(g) { fimAvisado = false }
            posicionar()
            if chegouAoComeco {
                aoRegistrar?("para trás: chegou ao começo — parado ali, rolando=\(estado.rolando)")
                aoRelatarPosicao?(posicao)
                ultimoRelato = t
            } else if t - ultimoRelato >= 0.1 {
                ultimoRelato = t
                aoRelatarPosicao?(posicao)
            }
            return
        }
        let chegou = rolagem.avancar(dt: dt, velocidade: estado.velocidade, geometria: g)
        posicionar()
        if t - ultimoRelato >= 0.1 {
            ultimoRelato = t
            aoRelatarPosicao?(posicao)
        }
        if chegou || (rolagem.noFim(g) && !fimAvisado) {
            fimAvisado = true
            aoRelatarPosicao?(posicao)
            aoChegarAoFim?()
        }
    }

    // MARK: - o que o modelo manda

    func aplicar(estado novo: EstadoDoTeleprompter) {
        let antes = estado
        estado = novo
        if novo.fonte != antes.fonte || novo.margem != antes.margem { agendarRediagramacao() }
        if novo.margem != antes.margem { pedirFonteAutomatica() }
        if novo.espelho != antes.espelho || novo.linhaDeLeitura != antes.linhaDeLeitura { posicionar() }
        if novo.linhaDeLeitura != antes.linhaDeLeitura { window?.invalidateCursorRects(for: self) }
        if novo.rolando != antes.rolando {
            fimAvisado = false
            // Tocar com o texto já no fim: não há o que rolar, e os dois lados precisam ver isso.
            // **Para trás não**: "Rolar para cima" segurado no fim é justamente o que tira o texto
            // de lá (§12.5).
            if novo.rolando, !novo.paraTras, rolagem.noFim(diagramado.geometria) {
                fimAvisado = true
                DispatchQueue.main.async { [weak self] in self?.aoChegarAoFim?() }
            }
            atualizarRelogio()
            aoRelatarPosicao?(posicao)
        }
        if novo.paraTras != antes.paraTras {
            aoRegistrar?("sentido: \(novo.paraTras ? "para trás" : "para a frente") (rolando=\(novo.rolando), "
                         + String(format: "posição %.4f)", posicao))
        }
    }

    func trocarTexto(_ novo: String) {
        guard novo != texto else { return }
        texto = novo
        agendarRediagramacao()
        pedirFonteAutomatica()
    }

    /// Vai ao salto (`_JUMP`, ou o salto daqui) e mantém `rolando` como está.
    func saltar(para p: Double) {
        guard diagramado.geometria.quantasLinhas > 0, !precisaRediagramar else {
            posicaoPendente = p
            return
        }
        rolagem.ir(para: diagramado.geometria.deslocamento(paraPosicao: p), geometria: diagramado.geometria)
        fimAvisado = rolagem.noFim(diagramado.geometria)
        ultimoInstante = nil
        posicionar()
    }

    /// O trackpad ou a roda do mouse, no Mac do prompter: o operador põe o texto onde quiser, e
    /// isso é relatado como posição (é o prompter dizendo onde o texto está). Rolando, o texto segue
    /// dali na mesma velocidade.
    override func scrollWheel(with e: NSEvent) {
        let g = diagramado.geometria
        guard g.quantasLinhas > 0 else { return }
        let dy = Double(e.scrollingDeltaY)
        let passo = e.hasPreciseScrollingDeltas ? dy : dy * g.alturaDaLinha
        rolagem.ir(para: rolagem.deslocamento - passo, geometria: g)
        fimAvisado = rolagem.noFim(g)
        posicionar()
        aoRelatarPosicao?(posicao)
    }

    // MARK: - a linha de leitura, arrastada

    /// **Arrastar a faixa ou a seta move a linha de leitura** — pedido do usuário em 14/09: acertar a
    /// linha na altura da lente, para os olhos de quem lê ficarem na linha da câmera. O valor vai
    /// para o modelo (`definirLinhaDeLeitura`, que limita o envio e sempre manda o último), e a vista
    /// segue o mouse na hora, sem esperar a volta do estado. O espelho é horizontal: não mexe no y.
    var aoArrastarLinha: ((Double) -> Void)?
    private var arrastandoLinha = false

    /// A distância, em pontos, dentro da qual um clique pega a linha: a faixa inteira, e no mínimo
    /// 16 pt para cada lado — com fonte pequena a faixa é fina demais para o mouse.
    private var alcanceDaLinha: Double { max(diagramado.geometria.alturaDaLinha / 2, 16) }

    /// O y do mouse medido do topo, que é como a linha de leitura é guardada (fração da altura).
    private func yDoTopo(_ e: NSEvent) -> Double {
        Double(bounds.height) - Double(convert(e.locationInWindow, from: nil).y)
    }

    enum LadoDoQuadro { case esquerda, direita }
    private var arrastandoQuadro: LadoDoQuadro?
    /// Meia largura, em pontos, da faixa que pega uma seta lateral (a borda inteira, de alto a baixo).
    private static let alcanceDoQuadro = 14.0

    /// O x do mouse **no espaço do texto**: com espelho, a tela está invertida na horizontal.
    private func xNoTexto(_ e: NSEvent) -> Double {
        let x = Double(convert(e.locationInWindow, from: nil).x)
        return estado.espelho ? Double(bounds.width) - x : x
    }

    /// A seta lateral sob o mouse, se houver (a mais perto, dentro do alcance).
    private func ladoDoQuadro(_ e: NSEvent) -> LadoDoQuadro? {
        let W = Double(bounds.width)
        let x = xNoTexto(e)
        let de = abs(x - enquadramento.esquerda * W), dd = abs(x - enquadramento.direita * W)
        guard min(de, dd) <= VistaDoTexto.alcanceDoQuadro else { return nil }
        return de <= dd ? .esquerda : .direita
    }

    override func mouseDown(with e: NSEvent) {
        let H = Double(bounds.height)
        guard H > 0 else { return super.mouseDown(with: e) }
        // A linha de leitura tem a vez: é ela que a pessoa acerta na altura da lente.
        if abs(yDoTopo(e) - estado.linhaDeLeitura * H) <= alcanceDaLinha {
            arrastandoLinha = true
            NSCursor.resizeUpDown.push()
            return
        }
        if let lado = ladoDoQuadro(e) {
            arrastandoQuadro = lado
            NSCursor.resizeLeftRight.push()
            posicionar()
            return
        }
        super.mouseDown(with: e)
    }

    override func mouseDragged(with e: NSEvent) {
        guard bounds.height > 0 else { return super.mouseDragged(with: e) }
        if arrastandoLinha {
            let fracao = min(1, max(0, yDoTopo(e) / Double(bounds.height)))
            estado.linhaDeLeitura = fracao
            posicionar()
            aoArrastarLinha?(fracao)
            return
        }
        if let lado = arrastandoQuadro {
            let f = xNoTexto(e) / Double(bounds.width)
            if lado == .esquerda {
                definirEnquadramento(f, enquadramento.direita)
            } else {
                definirEnquadramento(enquadramento.esquerda, f)
            }
            posicionar()
            return
        }
        super.mouseDragged(with: e)
    }

    override func mouseUp(with e: NSEvent) {
        if arrastandoLinha {
            arrastandoLinha = false
            NSCursor.pop()
            window?.invalidateCursorRects(for: self)
            aoArrastarLinha?(estado.linhaDeLeitura)
            return
        }
        if arrastandoQuadro != nil {
            arrastandoQuadro = nil
            NSCursor.pop()
            window?.invalidateCursorRects(for: self)
            posicionar()
            aoMudarEnquadramento?(enquadramento.esquerda, enquadramento.direita)
            return
        }
        super.mouseUp(with: e)
    }

    /// Bancada: o gesto inteiro com eventos sintéticos, pelos mesmos três métodos do mouse — pega a
    /// linha onde ela está e solta em `fracao`. Devolve o que aconteceu, para o registro.
    func simularArrastoDaLinha(ate fracao: Double) -> String {
        guard let w = window, bounds.height > 0 else { return "sem janela" }
        let H = Double(bounds.height)
        func evento(_ tipo: NSEvent.EventType, _ yTopo: Double) -> NSEvent? {
            let noQuadro = NSPoint(x: Double(bounds.midX), y: H - yTopo)
            return NSEvent.mouseEvent(with: tipo, location: convert(noQuadro, to: nil), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let de = estado.linhaDeLeitura * H
        let ate = min(1, max(0, fracao)) * H
        guard let baixo = evento(.leftMouseDown, de), let cima = evento(.leftMouseUp, ate) else { return "sem evento" }
        mouseDown(with: baixo)
        guard arrastandoLinha else { return "o clique não pegou a linha" }
        for k in 1...10 {
            if let e = evento(.leftMouseDragged, de + (ate - de) * Double(k) / 10) { mouseDragged(with: e) }
        }
        mouseUp(with: cima)
        return String(format: "linha na vista = %.4f", estado.linhaDeLeitura)
    }

    override func resetCursorRects() {
        let H = Double(bounds.height), W = Double(bounds.width)
        guard H > 0, W > 0 else { return }
        for f in [enquadramento.esquerda, enquadramento.direita] {
            let xTexto = f * W
            let x = estado.espelho ? W - xTexto : xTexto
            let r = NSRect(x: x - VistaDoTexto.alcanceDoQuadro, y: 0, width: 2 * VistaDoTexto.alcanceDoQuadro, height: H)
            addCursorRect(r.intersection(bounds), cursor: .resizeLeftRight)
        }
        // Por último: onde as duas se cruzam, a linha de leitura vence, como no clique.
        let y = H - estado.linhaDeLeitura * H
        let r = NSRect(x: 0, y: y - alcanceDaLinha, width: W, height: 2 * alcanceDaLinha)
        addCursorRect(r.intersection(bounds), cursor: .resizeUpDown)
    }

    /// Bancada: arrasta uma seta lateral com eventos sintéticos, pelos mesmos três métodos do mouse,
    /// fora da faixa da linha de leitura. Devolve o que aconteceu, para o registro.
    func simularArrastoDoQuadro(_ lado: LadoDoQuadro, ate fracao: Double) -> String {
        guard let w = window, bounds.height > 0 else { return "sem janela" }
        let H = Double(bounds.height), W = Double(bounds.width)
        // Longe da linha de leitura: no alto da vista, onde ficam as setas laterais.
        let yTopo = estado.linhaDeLeitura > 0.2 ? 20.0 : H - 20
        func evento(_ tipo: NSEvent.EventType, _ xTexto: Double) -> NSEvent? {
            let xTela = estado.espelho ? W - xTexto : xTexto
            return NSEvent.mouseEvent(with: tipo, location: convert(NSPoint(x: xTela, y: H - yTopo), to: nil),
                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let de = (lado == .esquerda ? enquadramento.esquerda : enquadramento.direita) * W
        let ate = min(1, max(0, fracao)) * W
        guard let baixo = evento(.leftMouseDown, de), let cima = evento(.leftMouseUp, ate) else { return "sem evento" }
        mouseDown(with: baixo)
        guard arrastandoQuadro == lado else { arrastandoLinha = false; return "o clique não pegou a seta" }
        for k in 1...10 {
            if let e = evento(.leftMouseDragged, de + (ate - de) * Double(k) / 10) { mouseDragged(with: e) }
        }
        mouseUp(with: cima)
        return String(format: "enquadramento = %.3f / %.3f, coluna de %.0f pt", enquadramento.esquerda,
                      enquadramento.direita, coluna.largura)
    }

    // MARK: - o enquadramento e a fonte automática (ajustes locais, docs/teleprompter-ajustes-locais.md)

    /// As duas setas laterais, em fração da largura da vista, **no espaço do texto** (antes do
    /// espelho: com espelho, a da esquerda aparece à direita). Padrão: a largura inteira.
    private(set) var enquadramento: (esquerda: Double, direita: Double) = (0, 1)
    /// A menor coluna entre as setas, em fração da largura.
    static let menorQuadro = 0.1
    var aoMudarEnquadramento: ((Double, Double) -> Void)?

    func definirEnquadramento(_ esquerda: Double, _ direita: Double, avisar: Bool = false) {
        var e = min(max(0, esquerda), 1 - VistaDoTexto.menorQuadro)
        var d = min(max(0, direita), 1)
        if d - e < VistaDoTexto.menorQuadro { d = min(1, e + VistaDoTexto.menorQuadro); e = d - VistaDoTexto.menorQuadro }
        guard e != enquadramento.esquerda || d != enquadramento.direita else { return }
        enquadramento = (e, d)
        window?.invalidateCursorRects(for: self)
        agendarRediagramacao()
        pedirFonteAutomatica()
        if avisar { aoMudarEnquadramento?(e, d) }
    }

    /// A coluna de texto: o quadro entre as setas, menos a `margem` sincronizada de cada lado (a
    /// margem é fração **do quadro**, que é a "vista do texto" do contrato).
    private var coluna: (x: Double, largura: Double) {
        let W = Double(bounds.width)
        let quadro = max(40, (enquadramento.direita - enquadramento.esquerda) * W)
        let margem = estado.margem * quadro
        return (enquadramento.esquerda * W + margem, max(40, quadro - 2 * margem))
    }

    /// A "Fonte automática": ligada, a vista acha a maior fonte com pelo menos duas palavras por
    /// linha (`FonteAutomatica`) numa fila de fundo e a entrega por `aoEscolherFonte`; vale o último
    /// pedido. Recalcula quando mudam o texto, a largura, a margem ou o enquadramento.
    var fonteAutomatica = false {
        didSet { if fonteAutomatica, !oldValue { pedirFonteAutomatica() } }
    }
    var aoEscolherFonte: ((Double) -> Void)?
    private let filaDaFonte = DispatchQueue(label: "br.com.queven.quall.teleprompter.fonte-automatica", qos: .userInitiated)
    private let pedidosDaFonte = ContadorDePedidosDaFonte()

    private func pedirFonteAutomatica() {
        guard fonteAutomatica, !texto.isEmpty, bounds.width > 20 else { return }
        let g = pedidosDaFonte.proximo()
        let (t, largura) = (texto, CGFloat(coluna.largura))
        let pedidos = pedidosDaFonte
        let registrar = aoRegistrar
        filaDaFonte.async { [weak self] in
            guard pedidos.atual == g else { return }
            let comeco = CFAbsoluteTimeGetCurrent()
            let f = FonteAutomatica.maiorFonte(texto: t, largura: largura,
                                               criarFonte: { NSFont.systemFont(ofSize: $0, weight: .medium) as CTFont },
                                               deveParar: { pedidos.atual != g })
            let ms = (CFAbsoluteTimeGetCurrent() - comeco) * 1000
            DispatchQueue.main.async {
                guard let self, pedidos.atual == g, self.fonteAutomatica else { return }
                registrar?(String(format: "fonte automática: %@ na coluna de %.0f pt (%.0f ms fora da main)",
                                  f.map { String(format: "%.0f pt", $0) } ?? "sem resposta", largura, ms))
                if let f, Double(f) != self.estado.fonte { self.aoEscolherFonte?(Double(f)) }
            }
        }
    }

    /// O mouse está sobre a vista: as guias do enquadramento aparecem, finas (no vidro, sem mouse, não).
    private var mouseDentro = false
    private var areaDoMouse: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = areaDoMouse { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        areaDoMouse = a
    }

    override func mouseEntered(with event: NSEvent) { mouseDentro = true; posicionar() }
    override func mouseExited(with event: NSEvent) { mouseDentro = false; posicionar() }

    private func desenharMarcasDoQuadro(W: Double, H: Double) {
        // Do tamanho da seta da linha de leitura: no Android, pequenas e coladas na borda, o usuário
        // não as achou (14/09).
        let lado = 26.0
        let caminho = CGMutablePath()
        for x in [enquadramento.esquerda * W, enquadramento.direita * W] {
            let cx = min(max(x, lado / 2 + 2), W - lado / 2 - 2)
            if marcasNoPe {
                // No pé, apontando para cima (y das camadas cresce para cima).
                caminho.move(to: CGPoint(x: cx - lado / 2, y: 2))
                caminho.addLine(to: CGPoint(x: cx + lado / 2, y: 2))
                caminho.addLine(to: CGPoint(x: cx, y: 2 + lado * 0.8))
            } else {
                caminho.move(to: CGPoint(x: cx - lado / 2, y: H - 2))
                caminho.addLine(to: CGPoint(x: cx + lado / 2, y: H - 2))
                caminho.addLine(to: CGPoint(x: cx, y: H - 2 - lado * 0.8))
            }
            caminho.closeSubpath()
        }
        marcasDoQuadro.path = caminho
        if arrastandoQuadro != nil || (mouseDentro && !marcasNoPe) {
            let guia = CGMutablePath()
            for f in [enquadramento.esquerda, enquadramento.direita] {
                let x = min(max(f * W, 1), W - 1)
                guia.move(to: CGPoint(x: x, y: 0))
                guia.addLine(to: CGPoint(x: x, y: H))
            }
            guiaDoQuadro.path = guia
            guiaDoQuadro.opacity = arrastandoQuadro != nil ? 1 : 0.5
            guiaDoQuadro.isHidden = false
        } else {
            guiaDoQuadro.isHidden = true
        }
    }

    // MARK: - layout

    override func setFrameSize(_ novo: NSSize) {
        super.setFrameSize(novo)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        raiz.frame = bounds
        palco.bounds = CGRect(origin: .zero, size: bounds.size)
        palco.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        if abs(bounds.width - larguraDiagramada) > 0.5 {
            agendarRediagramacao()
            pedirFonteAutomatica()
        } else {
            posicionar()
        }
    }

    /// Várias mudanças no mesmo instante (fonte e margem juntas, um controle deslizante) refazem o
    /// layout **uma** vez, na volta seguinte da main.
    private func agendarRediagramacao() {
        precisaRediagramar = true
        guard !rediagramacaoAgendada else { return }
        rediagramacaoAgendada = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rediagramacaoAgendada = false
            if self.precisaRediagramar { self.rediagramar() }
        }
    }

    private func rediagramar() {
        guard bounds.width > 20, bounds.height > 20 else { return }
        precisaRediagramar = false
        let geometriaAntes = diagramado.geometria
        let ponto = geometriaAntes.pontoDeLeitura(noDeslocamento: rolagem.deslocamento)
        let fonte = NSFont.systemFont(ofSize: CGFloat(estado.fonte), weight: .medium) as CTFont
        let largura = CGFloat(coluna.largura)
        diagramado = TextoDiagramado.diagramar(texto, fonte: fonte, cor: VistaDoTexto.corDoTexto, largura: largura)
        larguraDiagramada = bounds.width
        let g = diagramado.geometria
        if let p = posicaoPendente {
            posicaoPendente = nil
            rolagem.ir(para: g.deslocamento(paraPosicao: p), geometria: g)
        } else if geometriaAntes.quantasLinhas > 0 {
            // Quem lê não perde o lugar: o caractere que estava na linha de leitura continua nela.
            rolagem.ir(para: g.deslocamento(paraPonto: ponto), geometria: g)
        } else {
            rolagem.ir(para: rolagem.deslocamento, geometria: g)
        }
        fimAvisado = rolagem.noFim(g)
        descartarBlocos()
        posicionar()
        aoRegistrar?("layout: \(g.quantasLinhas) linhas de \(String(format: "%.1f", g.alturaDaLinha)) pt, "
                     + "largura \(Int(largura)) pt, fonte \(estado.fonte), \(texto.utf8.count) bytes, "
                     + String(format: "%.1f ms", diagramado.custoMs))
        aoRelatarPosicao?(posicao)
    }

    private func descartarBlocos() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for b in blocos.values { b.removeFromSuperlayer() }
        CATransaction.commit()
        blocos.removeAll()
    }

    /// Põe os blocos visíveis (e meia tela antes e depois) no lugar, cria os que faltam e descarta o
    /// resto. Coordenadas das camadas com y para cima; as contas da geometria, com y para baixo a
    /// partir do topo — a conversão é `y_camada = altura − y_topo`.
    private func posicionar() {
        guard bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        palco.transform = estado.espelho ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity

        let H = Double(bounds.height)
        let W = Double(bounds.width)
        let g = diagramado.geometria
        let h = g.alturaDaLinha
        let yLeitura = estado.linhaDeLeitura * H
        let margemX = coluna.x

        faixa.frame = CGRect(x: 0, y: H - yLeitura - h / 2, width: W, height: h)
        let lado = min(28.0, max(12.0, h * 0.45))
        let caminho = CGMutablePath()
        let xSeta = max(4, margemX - lado - 8)
        caminho.move(to: CGPoint(x: xSeta, y: H - yLeitura + lado / 2))
        caminho.addLine(to: CGPoint(x: xSeta + lado * 0.8, y: H - yLeitura))
        caminho.addLine(to: CGPoint(x: xSeta, y: H - yLeitura - lado / 2))
        caminho.closeSubpath()
        seta.path = caminho
        desenharMarcasDoQuadro(W: W, H: H)

        guard g.quantasLinhas > 0 else {
            if !blocos.isEmpty { for b in blocos.values { b.removeFromSuperlayer() }; blocos.removeAll() }
            return
        }
        let linhasPorBloco = max(1, Int(VistaDoTexto.alturaDoBloco / h))
        let d = rolagem.deslocamento
        let visiveis = g.linhasVisiveis(deslocamento: d, yLeitura: yLeitura, alturaVisivel: H)
        let folga = Int(H / 2 / h) + 1
        let primeira = max(0, visiveis.lowerBound - folga)
        let ultima = min(g.quantasLinhas, visiveis.upperBound + folga)
        let blocoInicial = primeira / linhasPorBloco
        let blocoFinal = max(blocoInicial, (max(ultima, primeira + 1) - 1) / linhasPorBloco)

        for (k, b) in blocos where k < blocoInicial || k > blocoFinal {
            b.removeFromSuperlayer()
            blocos[k] = nil
        }
        let topoDoTexto = yLeitura - h / 2 - d
        for k in blocoInicial...blocoFinal {
            let a = k * linhasPorBloco
            guard a < g.quantasLinhas else { break }
            let z = min(g.quantasLinhas, a + linhasPorBloco)
            let bloco: BlocoDeTexto
            if let existente = blocos[k] {
                bloco = existente
            } else {
                bloco = BlocoDeTexto()
                bloco.linhas = Array(diagramado.linhas[a..<z])
                bloco.recuos = z <= diagramado.recuos.count ? Array(diagramado.recuos[a..<z]) : []
                bloco.alturaDaLinha = CGFloat(h)
                bloco.baseDesdeOTopo = diagramado.baseDesdeOTopo
                bloco.contentsScale = escala
                bloco.anchorPoint = .zero
                bloco.bounds = CGRect(x: 0, y: 0, width: diagramado.largura + 2, height: CGFloat(Double(z - a) * h))
                bloco.setNeedsDisplay()
                palco.addSublayer(bloco)
                blocos[k] = bloco
            }
            bloco.position = CGPoint(x: margemX, y: H - (topoDoTexto + Double(z) * h))
        }
    }
}

/// Um bloco de linhas, pintado uma vez. Fundo preto opaco: o texto sai com o antisserrilhado de
/// fundo conhecido, e a composição não precisa misturar transparência.
final class BlocoDeTexto: CALayer {
    var linhas: [CTLine] = []
    /// O recuo de cada linha, para centralizar (`TextoDiagramado.recuos`).
    var recuos: [CGFloat] = []
    var alturaDaLinha: CGFloat = 1
    var baseDesdeOTopo: CGFloat = 0

    override init() {
        super.init()
        isOpaque = true
        backgroundColor = CGColor(gray: 0, alpha: 1)
        needsDisplayOnBoundsChange = false
        actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let outro = layer as? BlocoDeTexto {
            linhas = outro.linhas
            recuos = outro.recuos
            alturaDaLinha = outro.alturaDaLinha
            baseDesdeOTopo = outro.baseDesdeOTopo
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override func draw(in ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(bounds)
        ctx.textMatrix = .identity
        ctx.setShouldAntialias(true)
        // O contexto de uma camada tem y para cima: a linha i fica a `i × altura` do topo.
        for (i, linha) in linhas.enumerated() {
            let y = bounds.height - (CGFloat(i) * alturaDaLinha + baseDesdeOTopo)
            ctx.textPosition = CGPoint(x: 1 + (i < recuos.count ? recuos[i] : 0), y: y)
            CTLineDraw(linha, ctx)
        }
    }
}

/// A vista no SwiftUI. Ela se registra no modelo ao nascer: o modelo manda o texto, o estado e os
/// saltos direto para ela, sem passar pela comparação do SwiftUI a cada quarto de segundo.
struct VistaDoTextoRepresentavel: NSViewRepresentable {
    let modelo: Teleprompter

    func makeNSView(context: Context) -> VistaDoTexto {
        let v = VistaDoTexto(frame: .zero)
        modelo.registrar(vista: v)
        return v
    }

    func updateNSView(_ nsView: VistaDoTexto, context: Context) {}

    static func dismantleNSView(_ nsView: VistaDoTexto, coordinator: ()) {
        nsView.pararRelogio()
    }
}

extension Teleprompter {
    func registrar(vista v: VistaDoTexto) {
        vista = v
        v.aoRelatarPosicao = { [weak self] p in self?.relatarPosicao(p) }
        v.aoChegarAoFim = { [weak self] in self?.chegouAoFim() }
        v.aoRegistrar = { linha in Registro.compartilhado.linha("teleprompter: vista: " + linha) }
        v.aoArrastarLinha = { [weak self] f in self?.definirLinhaDeLeitura(f) }
        v.definirEnquadramento(enquadramentoGuardado.esquerda, enquadramentoGuardado.direita)
        v.aoMudarEnquadramento = { [weak self] e, d in self?.guardarEnquadramento(e, d) }
        v.aoEscolherFonte = { [weak self] f in self?.definirFonteAutomatica(escolhida: f) }
        v.fonteAutomatica = fonteAutomatica
        v.marcasNoPe = comCamera
        v.trocarTexto(texto)
        v.aplicar(estado: estado)
    }
}

/// "Vale o último pedido" da fonte automática, lido da fila de fundo.
final class ContadorDePedidosDaFonte: @unchecked Sendable {
    private let trava = NSLock()
    private var n = 0
    func proximo() -> Int { trava.lock(); defer { trava.unlock() }; n += 1; return n }
    var atual: Int { trava.lock(); defer { trava.unlock() }; return n }
}
