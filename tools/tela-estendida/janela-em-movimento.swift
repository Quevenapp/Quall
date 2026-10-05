import AppKit
import CoreGraphics
import QuartzCore
// Conteúdo **sintético nosso** para o monitor da tela estendida: listras que andam e texto que rola,
// numa janela sem borda que cobre só esse monitor. Existe para medir o decodificador do tablet com
// carga de verdade sem pôr nada da vida do usuário na captura.
let segundos = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
// 3º argumento opcional: o id do monitor (vários monitores do Quall ao mesmo tempo).
let alvo = CommandLine.arguments.dropFirst(3).first.flatMap { UInt32($0) }
// 4º argumento opcional: `leve` desenha só as listras, sem o texto. Existe porque em 11/09 a captura
// recebia ~29 quadros novos por segundo com a carga desenhando 30, e os que faltavam chegavam como
// "ocioso" (nada mudou): suspeita de que o próprio desenho, texto em CPU na tela inteira, passasse do
// tempo de um quadro.
let leve = CommandLine.arguments.dropFirst(4).first == "leve"
// `ca`: o mesmo movimento feito pelo **Core Animation** (animações de camada, que o servidor de
// composição roda sozinho a cada atualização), e não por um `draw` por tique do app. Existe porque
// em 11/09 a carga de `draw` deixava ~1 atualização por segundo sem imagem nova no monitor virtual,
// nos dois receptores, com o desenho levando ~1 ms: a suspeita é o caminho app → composição.
// (~~Que um vídeo ou uma rolagem de sistema não percorrem~~: a rolagem é o `camadas`, abaixo.)
let modoCA = CommandLine.arguments.dropFirst(4).first == "ca"
// `camadas`: as mesmas camadas do `ca`, mas quem as move é o **app**, a cada tique, numa transação
// sem animação — como uma rolagem, em que o app manda a posição nova a cada quadro. Existe porque em
// 11/09, sem o Sidecar, o `draw` chegava ao monitor virtual na metade do ritmo em trechos e o `ca`
// nunca: separa "o jeito de desenhar" de "o app mandar uma atualização por quadro".
let modoCamadas = CommandLine.arguments.dropFirst(4).first == "camadas"
let modoDeCamadas = modoCA || modoCamadas
func online() -> [CGDirectDisplayID] {
    var n: UInt32 = 0; CGGetOnlineDisplayList(0, nil, &n)
    var l = [CGDirectDisplayID](repeating: 0, count: Int(n)); CGGetOnlineDisplayList(n, &l, &n)
    return Array(l.prefix(Int(n)))
}
func monitorDoQuall() -> CGDirectDisplayID? {
    // Com id no 3º argumento, **qualquer** monitor — inclusive a tela do próprio Mac, para ver a
    // carga sem o Quall no meio (pedido do usuário, 11/09). Sem id, o primeiro monitor do Quall.
    online().first { d in alvo.map { d == $0 } ?? (CGDisplayVendorNumber(d) == 0x458C) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let id = monitorDoQuall(),
      let tela = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id })
else { print("monitor do Quall não achado"); exit(1) }
final class Vista: NSView {
    var t = 0.0
    var desenhos = 0
    // A fonte sai **uma vez**, e não a cada desenho. Montada dentro do `draw`, ela derrubou a carga
    // três vezes em 11/09 (09:03, 10:38, 14:06) com `NSInvalidArgumentException` do CoreText — "attempt
    // to insert nil object" ao aplicar a fonte —, e a corrida D1 perdeu 90 dos 240 s por isso.
    let atributos: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.black,
    ]
    /// Quanto cada desenho levou, em ms, neste segundo — a testemunha de que a carga cabe num quadro.
    var duracoesMs: [Double] = []
    override func draw(_ r: NSRect) {
        let comeco = CACurrentMediaTime()
        defer { duracoesMs.append((CACurrentMediaTime() - comeco) * 1000) }
        desenhos += 1
        let w = bounds.width, h = bounds.height
        NSColor.white.setFill(); bounds.fill()
        // No modo `ca` quem desenha são as camadas; a vista só pinta o fundo. Sem isto o desenho de
        // um tique ficava por baixo das camadas, com o texto dobrado (foto do usuário, 11/09).
        if modoDeCamadas { return }
        for i in 0..<24 {
            let x = (Double(i) * 80 + t * 240).truncatingRemainder(dividingBy: w + 80) - 80
            NSColor(hue: CGFloat(i) / 24, saturation: 0.6, brightness: 0.95, alpha: 1).setFill()
            NSRect(x: x, y: 0, width: 36, height: h * 0.35).fill()
        }
        if leve { return }
        var y = h * 0.37 - (t * 90).truncatingRemainder(dividingBy: 16)
        var n = Int(t * 90 / 16)
        while y < h {
            ("\(n)  Quall · tela estendida · texto sintético rolando para medir o decodificador · 0123456789 abcdefghij" as NSString)
                .draw(at: NSPoint(x: 12, y: y), withAttributes: atributos)
            y += 16; n += 1
        }
    }
}
let janela = NSWindow(contentRect: tela.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: tela)
janela.level = .floating
let vista = Vista(frame: NSRect(origin: .zero, size: tela.frame.size))
janela.contentView = vista
janela.setFrame(tela.frame, display: true)
janela.orderFrontRegardless()
// **Sem emenda visível**: cada laço anda exatamente um período do desenho, e não um passo. As
// listras repetem a cor a cada 24 (24 × 80 = 1920 pt, a 240 pt/s = 8 s); o texto numera as linhas
// de 0 a 9 e anda 10 linhas (160 pt, a 90 pt/s). Andando só um passo, a cor e o número voltavam a
// cada laço e a carga parecia "mais rápida" (usuário, 11/09).
let periodoDasListras: CGFloat = 24 * 80
let periodoDoTexto: CGFloat = 10 * 16
/// As duas camadas que andam, e onde nasceram — o modo `camadas` as move a partir daí a cada tique.
var faixaQueAnda: CALayer?, blocoQueAnda: CALayer?
var origemDaFaixa = CGPoint.zero, origemDoBloco = CGPoint.zero
if modoDeCamadas {
    // Listras e texto em camadas. No `ca` andam por animações que se repetem sem fim, e o app não
    // desenha nada depois disto: quem move é o servidor de composição. No `camadas`, quem move é o
    // relógio lá embaixo.
    vista.wantsLayer = true
    let raiz = vista.layer!
    raiz.backgroundColor = NSColor.white.cgColor
    let w = vista.bounds.width, h = vista.bounds.height
    let faixa = CALayer()
    faixa.frame = CGRect(x: -periodoDasListras, y: 0, width: w + periodoDasListras + 80, height: h * 0.35)
    for i in 0..<(Int((w + periodoDasListras + 80) / 80) + 1) {
        let l = CALayer()
        l.frame = CGRect(x: CGFloat(i) * 80, y: 0, width: 36, height: h * 0.35)
        l.backgroundColor = NSColor(hue: CGFloat(i % 24) / 24, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor
        faixa.addSublayer(l)
    }
    raiz.addSublayer(faixa)
    // **Uma camada por linha**, cada uma com 16 pt, e não um `CATextLayer` com o texto todo: esse
    // espaça as linhas pela fonte (~14 pt), o laço de 160 pt não fechava com 10 linhas, e o texto
    // "reiniciava do 0 deixando um espaço em branco" (usuário, 11/09). E dentro de uma janela
    // recortada a partir de 37 % da altura, como o texto do `draw`, para não passar sobre as listras.
    let recorte = CALayer()
    recorte.frame = CGRect(x: 0, y: h * 0.37, width: w, height: h * 0.63)
    recorte.masksToBounds = true
    raiz.addSublayer(recorte)
    let linhas = Int((h * 0.63 + periodoDoTexto) / 16) + 2
    let bloco = CALayer()
    bloco.frame = CGRect(x: 12, y: -periodoDoTexto, width: w - 24, height: CGFloat(linhas) * 16)
    for k in 0..<linhas {
        let linha = CATextLayer()
        linha.contentsScale = janela.backingScaleFactor
        linha.font = NSFont(name: "Menlo", size: 12); linha.fontSize = 12
        linha.foregroundColor = NSColor.black.cgColor
        linha.string = "\(k % 10)  Quall · tela estendida · texto sintético rolando (Core Animation) · 0123456789 abcdefghij"
        linha.frame = CGRect(x: 0, y: CGFloat(k) * 16, width: w - 24, height: 16)
        bloco.addSublayer(linha)
    }
    recorte.addSublayer(bloco)
    if modoCA {
        let anda = CABasicAnimation(keyPath: "position.x")
        anda.byValue = periodoDasListras; anda.duration = Double(periodoDasListras) / 240; anda.repeatCount = .infinity
        faixa.add(anda, forKey: "anda")
        let rola = CABasicAnimation(keyPath: "position.y")
        rola.byValue = periodoDoTexto; rola.duration = Double(periodoDoTexto) / 90; rola.repeatCount = .infinity
        bloco.add(rola, forKey: "rola")
    }
    faixaQueAnda = faixa; blocoQueAnda = bloco
    origemDaFaixa = faixa.position; origemDoBloco = bloco.position
}
let inicio = Date()
var tiques = 0
// **Um desenho por atualização do monitor**, pelo `displayLink` da própria vista, e não por um
// relógio solto na mesma taxa: com o relógio, dois desenhos caíam às vezes na mesma atualização e a
// captura recebia 17–26 quadros/s de uma carga que desenhava 30 (11/09). O 2º argumento (hz) ficou
// só como documentação — quem manda é a taxa do monitor.
final class Relogio: NSObject {
    let acao: () -> Void
    init(_ acao: @escaping () -> Void) { self.acao = acao }
    @objc func tique(_ link: CADisplayLink) { acao() }
}
let relogio = Relogio {
    tiques += 1
    vista.t = Date().timeIntervalSince(inicio); if !modoDeCamadas { vista.needsDisplay = true }
    if modoCamadas, let faixa = faixaQueAnda, let bloco = blocoQueAnda {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        faixa.position.x = origemDaFaixa.x + CGFloat(vista.t * 240).truncatingRemainder(dividingBy: periodoDasListras)
        bloco.position.y = origemDoBloco.y + CGFloat(vista.t * 90).truncatingRemainder(dividingBy: periodoDoTexto)
        CATransaction.commit()
    }
    // O monitor saiu (a sessão acabou): sai também, em vez de derrubar o AppKit desenhando no nada.
    if vista.t > segundos || !online().contains(id) { exit(0) }
}
vista.displayLink(target: relogio, selector: #selector(Relogio.tique(_:))).add(to: .main, forMode: .common)
// **A testemunha da própria carga**, uma linha por segundo: quantos tiques do relógio e quantos
// desenhos saíram, se a janela está visível, e onde ela está contra o monitor dela. Separa "a carga
// parou de mudar" de "a captura parou de receber" (11/09). Só geometria e contagem — nada de pixel.
func quadro(_ r: NSRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    let minha = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    let d = vista.duracoesMs.sorted()
    let p95 = d.isEmpty ? 0 : d[min(d.count - 1, Int(Double(d.count) * 0.95))]
    print(String(format: "t=%.0f tiques=%d desenhos=%d desenho_ms_p50=%.1f p95=%.1f max=%.1f visivel=%@ janela=%@ monitor=%@ tela_da_janela=%@%@",
                 vista.t, tiques, vista.desenhos, d.isEmpty ? 0 : d[d.count / 2], p95, d.last ?? 0,
                 janela.occlusionState.contains(.visible) ? "sim" : "NAO", quadro(janela.frame),
                 minha.map { quadro($0.frame) } ?? "sumiu",
                 (janela.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { "\($0)" } ?? "nenhuma",
                 leve ? " modo=leve" : (modoCA ? " modo=ca" : (modoCamadas ? " modo=camadas" : ""))))
    fflush(stdout)
    tiques = 0; vista.desenhos = 0; vista.duracoesMs.removeAll(keepingCapacity: true)
}
app.run()
