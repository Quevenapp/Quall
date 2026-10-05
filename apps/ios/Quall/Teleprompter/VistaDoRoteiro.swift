import CoreText
import SwiftUI
import UIKit

/// O texto do prompter, rolando. É a peça que a pessoa lê — no vidro, ou no reflexo dele.
///
/// # O layout sai da thread principal (14/09/2026)
///
/// A primeira versão era um `UITextView` em TextKit 1 com o layout inteiro (a altura exata é o que
/// dá a fração do percurso do contrato, §3). Medido no iPhone X com o texto rolando, pelo
/// `MedidorDoRoteiro`: cada roteiro que chegava, e cada troca de fonte, **parava a rolagem** —
/// 13–14 quadros perdidos com 100 KB, 25 com 128 KB a 96 pt (424 ms), e no iPhone 7 até 28. Quase
/// todo o tempo era o `attributedText` do `UITextView`, que faz o layout do texto inteiro ali mesmo.
///
/// A sonda de pilhas (`SondaDePilhas`) mediu as alternativas com o mesmo roteiro, e decidiu:
///
/// - **o TextKit 1 fora da principal custa o mesmo** (198 contra 199 ms, 100 KB): o texto novo
///   chegaria 200–400 ms depois, e o `UITextView` ainda refaria o layout dele na principal;
/// - **"só a parte visível" (TextKit 2)** custa 1–2 ms, mas a altura é **estimada** e muda enquanto
///   rola (1,8 % em 100 KB): a fração do percurso mudaria sozinha, e a altura exata custa o layout
///   inteiro de novo (200–350 ms);
/// - **o CoreText** quebra o mesmo texto no mesmo número de linhas em um quarto do tempo (35 ms os
///   índices, 100 KB, iPhone X), e é seguro fora da principal. É o que o Mac já faz.
///
/// Então: a quebra roda na fila do diagrama (`DiagramaDoRoteiro`); a principal só **troca** o
/// diagrama pronto e pinta as linhas que aparecem, em blocos de ~380 pt (~1,5 ms cada, a 3x), que
/// rolam com o `UIScrollView` sem ser redesenhados. Enquanto o diagrama novo não chega, o velho
/// continua rolando: quem lê vê o texto novo 20–160 ms depois do pedido (medido de 10 a 128 KB, 32
/// a 96 pt, no iPhone X e no 7), sem a rolagem parar: 0 quadro perdido nos 81 eventos com o texto
/// rolando das duas varreduras (antes: 3 a 28 em cada um), e nos roteiros que a `quall-probe`
/// mandou do Mac, 0 em 7 e 1 quadro em 2 (antes: 4 a 20) — o piso daquela corrida, sem evento
/// nenhum, também perdeu 1.
///
/// # O lugar de quem lê não pula
///
/// Na troca, a vista guarda o **ponto de leitura** (o caractere que abre a linha que está na linha
/// de leitura, `LinhasDoRoteiro`) e põe essa linha de volta na linha de leitura do layout novo — a
/// regra do Mac. A vista de antes guardava a fração, e a fração cai noutra frase quando a fonte
/// muda (medido: 50–200 linhas com 100–128 KB; pelos pixels, a frase lida ia de 492 para 481 e
/// para 524). A posição relatada ao controle é recalculada no
/// layout novo (§3: a posição é do layout de cada aparelho).
///
/// # Rolagem sem saltos
///
/// Um `CADisplayLink` anda `velocidade × altura da linha × dt` a cada quadro, com `dt` tirado do
/// `targetTimestamp` (o instante em que o quadro vai à tela, e não o do callback, que treme). O
/// acumulado fica num `Double` à parte e só o que vai para a vista é arredondado ao pixel — texto
/// parado entre dois pixels fica borrado. Um `dt` maior que 100 ms (um engasgo do aparelho) anda
/// só 100 ms: melhor atrasar um instante que pular linhas na frente de quem lê.
///
/// # O espelho
///
/// `scaleX: -1` no contêiner do texto (o texto e o marcador da linha de leitura), para ler no
/// reflexo do vidro. **Não** encosta no vídeo nem no `isVideoMirrored` da câmera (§3), e não
/// espelha os avisos, que são para quem opera o aparelho.
final class VistaDoRoteiroUIKit: UIView, UIScrollViewDelegate {

    // --- o que a tela manda ---------------------------------------------------------------------

    var aoRelatarPosicao: (Double) -> Void = { _ in }
    var aoChegarAoFim: () -> Void = {}
    var aoTocar: () -> Void = {}
    /// De onde vêm os saltos (do controle e dos botões daqui). Consumida no começo de cada quadro.
    var caixaDeSalto: CaixaDeSalto?

    // --- as peças -------------------------------------------------------------------------------

    private let conteiner = UIView()
    private let rolador = RoladorDoRoteiro()
    /// O conteúdo do rolador: as folgas e os blocos de texto, em coordenadas do conteúdo.
    private let palco = UIView()
    private var blocos: [Int: BlocoDoRoteiro] = [:]
    private var faixaDosBlocos: ClosedRange<Int>?
    private let marcador = CAShapeLayer()
    private let vazio = UILabel()
    private var link: CADisplayLink?

    /// A altura de um bloco pintado de uma vez, em pontos (a mesma do Mac).
    static let alturaDoBloco: Double = 380

    // --- o estado da vista ----------------------------------------------------------------------

    private var versaoDoTexto = -1
    private var conteudo = ""
    private var fonte: Double = 48
    private var margem: Double = 0.1
    /// O "Enquadramento" deste aparelho (`AjustesLocais`): a coluna de texto fica entre as duas
    /// marcas, e é ela a "vista do texto" do contrato — a `margem` é fração dela, de cada lado.
    private var enquadramentos = EnquadramentosPorOrientacao()
    private var enquadramento: Enquadramento {
        enquadramentos.para(largura: Double(bounds.width), altura: Double(bounds.height))
    }
    private var linhaDeLeitura: Double = 0.3
    private var espelho = false
    private var rolando = false
    /// "Segurar para rolar" (§12): com `rolando`, rola para trás, na velocidade de sempre, e para no
    /// começo **sem mudar `rolando`** — é o controle que solta. A tela diz que faz isso
    /// (`ReplicaDoTeleprompter.habilitarSegurar`, em `TelaDoPrompter`).
    private var paraTras = false
    private var velocidade: Double = 1

    private var diagrama: DiagramaDoRoteiro?
    private var geometria: GeometriaDoRoteiro?
    /// O deslocamento acumulado, em pontos, sem arredondar.
    private var y: Double = 0
    /// A fração do percurso em que o texto está: é o que se relata, e o que vale antes de haver
    /// diagrama (um salto pedido antes do primeiro layout).
    private var posicaoAtual: Double = 0
    private var ultimoRelato: Double = -1
    private var ultimoInstante: CFTimeInterval = 0
    private var tamanhoDoLayout = CGSize.zero
    private var escala: CGFloat { window?.screen.scale ?? UIScreen.main.scale }

    // --- a fila do diagrama ---------------------------------------------------------------------

    private let fila = DispatchQueue(label: "br.com.queven.quall.teleprompter.diagrama", qos: .userInitiated)
    private let pedidos = ContadorDePedidos()
    /// Um pedido que não pôde sair porque a vista ainda não tinha tamanho.
    private var diagramaPendente = true

    // --- o instrumento (MedidorDoRoteiro) ------------------------------------------------------------

    private let medidor = MedidorDoRoteiro()
    /// O fim da última troca, esperando o commit do Core Animation que a desenha.
    private var fimDoLayout: CFTimeInterval?
    private var observadorDoCommit: CFRunLoopObserver?
    private var ultimoPiso: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        conteiner.backgroundColor = .black
        addSubview(conteiner)

        rolador.backgroundColor = .black
        rolador.showsVerticalScrollIndicator = false
        rolador.showsHorizontalScrollIndicator = false
        rolador.contentInsetAdjustmentBehavior = .never
        rolador.alwaysBounceVertical = true
        rolador.scrollsToTop = false
        rolador.delegate = self
        palco.backgroundColor = .black
        rolador.addSubview(palco)
        conteiner.addSubview(rolador)

        marcador.fillColor = UIColor.systemYellow.withAlphaComponent(0.85).cgColor
        marcador.strokeColor = UIColor.systemYellow.withAlphaComponent(0.25).cgColor
        marcador.lineWidth = 1
        conteiner.layer.addSublayer(marcador)

        vazio.text = tr("Sem roteiro.\nToque em Editar, ou mande o texto pelo controle.")
        vazio.numberOfLines = 0
        vazio.textAlignment = .center
        vazio.textColor = UIColor(white: 0.6, alpha: 1)
        vazio.font = .preferredFont(forTextStyle: .title3)
        conteiner.addSubview(vazio)

        let toque = UITapGestureRecognizer(target: self, action: #selector(tocou))
        rolador.addGestureRecognizer(toque)
        rolador.textoParaLer = { [weak self] in self?.textoNaLeitura() }
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("só por código") }

    @objc private func tocou() { aoTocar() }

    // --- o relógio de quadro -----------------------------------------------------------------------

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            guard link == nil else { return }
            let l = CADisplayLink(target: AlvoFraco(self), selector: #selector(AlvoFraco.quadro(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            ligarObservadorDoCommit()
        } else {
            parar()
        }
    }

    func parar() {
        link?.invalidate()
        link = nil
        if let o = observadorDoCommit {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes)
            observadorDoCommit = nil
        }
    }

    /// O desenho dos blocos acontece **dentro** do commit do Core Animation (o observador de ordem
    /// 2 000 000 do run loop principal, antes de dormir). Um observador logo depois dele (2 000 500,
    /// antes do de UIKit em 2 001 000) marca o fim do commit: a diferença para o fim da troca é o
    /// desenho e a entrega do quadro ao servidor de renderização.
    private func ligarObservadorDoCommit() {
        guard observadorDoCommit == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                   true, 2_000_500) { [weak self] _, _ in
            guard let self, let fim = self.fimDoLayout else { return }
            self.fimDoLayout = nil
            let agora = CACurrentMediaTime()
            self.medidor.etapa("desenho", ms: (agora - fim) * 1000, agora: agora)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observadorDoCommit = o
    }

    /// O `CADisplayLink` segura o alvo com força: sem o intermediário, a vista nunca sairia da memória.
    private final class AlvoFraco: NSObject {
        weak var vista: VistaDoRoteiroUIKit?
        init(_ v: VistaDoRoteiroUIKit) { vista = v }
        @objc func quadro(_ l: CADisplayLink) { vista?.quadro(l) }
    }

    private var comDedo: Bool { rolador.isTracking || rolador.isDragging || rolador.isDecelerating }

    // --- o compasso quente (§8.12.12) --------------------------------------------------------------

    /// **Quente, o texto rola a 30 Hz regulares** (bancada de 27/09, iPhone 7 em `.serious`: "rolando em
    /// socos" — janelas de 10 s com 2–11 quadros perdidos e intervalos de 35–88 ms a 60 Hz, cada perda um
    /// salto de meia linha a 2,9 linhas/s). A posição já anda pelo relógio (`dt` do `targetTimestamp`),
    /// então nada acumula; o que muda é a cadência: 30 quadros iguais parecem mais lisos que 60 com
    /// buracos, e a principal ganha folga. A mesma histerese da rede: vai na hora em `.serious`, volta
    /// com 60 s abaixo.
    private var calorDoCompasso = RedeReduzidaPeloCalor()
    private var ultimaLeituraDoCalor: CFTimeInterval = 0
    private var compassoQuente = false

    private func acompanharCompasso(_ l: CADisplayLink) {
        guard l.timestamp - ultimaLeituraDoCalor >= 1 else { return }
        ultimaLeituraDoCalor = l.timestamp
        guard calorDoCompasso.observar(termico: ProcessInfo.processInfo.thermalState.rawValue, agora: l.timestamp)
        else { return }
        compassoQuente = calorDoCompasso.reduzida
        l.preferredFrameRateRange = compassoQuente ? CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30) : .default
        DiarioDoTeleprompter.dizer("rolagem: compasso " + (compassoQuente ? "30 Hz (aparelho quente)"
                                                                              : "da tela (esfriou há 60 s)"))
    }

    fileprivate func quadro(_ l: CADisplayLink) {
        let agora = l.targetTimestamp
        let dt = ultimoInstante > 0 ? min(0.1, max(0, agora - ultimoInstante)) : 0
        ultimoInstante = agora
        let dedo = comDedo
        acompanharCompasso(l)
        // O período **real** do link neste quadro (o intervalo entre o `timestamp` e o `targetTimestamp`):
        // a 30 Hz é 33 ms, a 60 é 16,7 — o medidor conta perda contra o que a tela está fazendo, e não
        // contra o pedido (revisão de 27/09, M6).
        let periodo = max(l.duration, l.targetTimestamp - l.timestamp)
        if let j = medidor.quadro(timestamp: l.timestamp, periodo: periodo, contando: rolando && !dedo) {
            DiarioDoTeleprompter.dizer(j.linha())
        }
        if l.timestamp - ultimoPiso >= 10, !medidor.temJanelaAberta {
            if ultimoPiso > 0, rolando {
                DiarioDoTeleprompter.dizer(medidor.lerPiso() + " compasso_pedido=\(compassoQuente ? "30" : "tela")"
                    + String(format: " periodo_real=%.1f ms", periodo * 1000))
            } else { _ = medidor.lerPiso() }
            ultimoPiso = l.timestamp
        }
        // O salto primeiro: antes de calcular e relatar qualquer posição (ver `CaixaDeSalto`).
        if let alvo = caixaDeSalto?.tomar() { irPara(alvo) }
        guard let g = geometria else { return }

        // O dedo manda: enquanto a pessoa arrasta (ou o arrasto desacelera), o relógio não mexe.
        if dedo {
            y = Double(rolador.contentOffset.y)
            posicaoAtual = g.posicao(deslocamento: y)
            relatar(posicaoAtual)
            return
        }
        guard rolando, g.percurso > 0 else { return }
        if paraTras {
            // Para trás: no começo (posição 0) o texto fica, e `rolando` fica como está.
            y = max(g.y0, y - g.pontosPorSegundo(velocidade: velocidade) * dt)
            posicaoAtual = g.posicao(deslocamento: y)
            aplicarDeslocamento()
            relatar(posicaoAtual)
            return
        }
        y += g.pontosPorSegundo(velocidade: velocidade) * dt
        if y >= g.y1 {
            y = g.y1
            posicaoAtual = 1
            aplicarDeslocamento()
            relatar(1)
            aoChegarAoFim()
            return
        }
        posicaoAtual = g.posicao(deslocamento: y)
        aplicarDeslocamento()
        relatar(posicaoAtual)
    }

    private func aplicarDeslocamento() {
        let alvo = CGFloat(GeometriaDoRoteiro.noPixel(y, escala: Double(escala)))
        if rolador.contentOffset.y != alvo {
            rolador.contentOffset = CGPoint(x: 0, y: alvo)
        }
    }

    /// Só quando a fração muda na resolução do contrato (0,0001): o núcleo limita o envio a 4 Hz,
    /// mas o cadeado dele não precisa ser tocado 60 vezes por segundo com o mesmo número.
    private func relatar(_ p: Double) {
        let q = (p * 10_000).rounded() / 10_000
        guard q != ultimoRelato else { return }
        ultimoRelato = q
        aoRelatarPosicao(q)
    }

    // --- o que vem do modelo -----------------------------------------------------------------------

    func aplicar(texto novo: String, versao: Int, estado e: EstadoDoTeleprompter,
                 enquadramentos novos: EnquadramentosPorOrientacao = EnquadramentosPorOrientacao()) {
        let agora = CACurrentMediaTime()
        var rediagramar = false
        if novos != enquadramentos {
            let antes = enquadramento
            enquadramentos = novos
            if enquadramento != antes { rediagramar = true; medidor.abrir("enquadramento", agora: agora) }
        }
        if versao != versaoDoTexto {
            versaoDoTexto = versao
            conteudo = novo
            rediagramar = true
            medidor.abrir("texto", agora: agora)
        }
        if e.fonte != fonte { fonte = e.fonte; rediagramar = true; medidor.abrir("fonte", agora: agora) }
        if e.margem != margem { margem = e.margem; rediagramar = true; medidor.abrir("margem", agora: agora) }
        if e.linhaDeLeitura != linhaDeLeitura {
            linhaDeLeitura = e.linhaDeLeitura
            medidor.abrir("linha", agora: agora)
            refazerGeometria(motivo: "linha de leitura")
        }
        if e.espelho != espelho {
            espelho = e.espelho
            conteiner.transform = espelho ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        }
        if rolando != e.rolando || velocidade != e.velocidade || paraTras != e.paraTras {
            // Retoma o relógio sem somar o tempo parado.
            if !rolando && e.rolando { ultimoInstante = 0 }
            rolando = e.rolando
            velocidade = e.velocidade
            paraTras = e.paraTras
        }
        if rediagramar { pedirDiagrama() }
    }

    /// `_JUMP`: vai até o alvo e relata a posição com ele; `rolando` fica como está (§6).
    private func irPara(_ alvo: Double) {
        posicaoAtual = min(1, max(0, alvo))
        // Um arrasto desacelerando seguiria depois do salto: para ele aqui.
        rolador.setContentOffset(rolador.contentOffset, animated: false)
        if let g = geometria {
            y = g.deslocamento(posicao: posicaoAtual)
            aplicarDeslocamento()
        }
        ultimoRelato = -1
        relatar(posicaoAtual)
    }

    // --- o layout: pedido na principal, feito na fila, trocado na principal -------------------------

    override func layoutSubviews() {
        super.layoutSubviews()
        // O contêiner é transformado (espelho): mexe-se em `bounds` e `center`, nunca em `frame`.
        conteiner.bounds = CGRect(origin: .zero, size: bounds.size)
        conteiner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        rolador.frame = conteiner.bounds
        vazio.frame = conteiner.bounds.insetBy(dx: 24, dy: 24)
        guard bounds.width > 1, bounds.height > 1 else { return }
        if bounds.size != tamanhoDoLayout {
            let mudouALargura = bounds.width != tamanhoDoLayout.width
            tamanhoDoLayout = bounds.size
            // A altura nova vale já (a tela cheia entra e sai assim, sem layout de texto nenhum);
            // a largura nova pede outro diagrama, e até ele chegar o velho continua na tela.
            refazerGeometria(motivo: "tamanho da vista")
            if mudouALargura || diagrama == nil { pedirDiagrama() }
        } else if diagramaPendente {
            pedirDiagrama()
        }
    }

    /// A largura da coluna de texto: a área do enquadramento menos as margens (a mesma conta de
    /// `EnquadramentoDoTexto.larguraDaColuna`, que a fonte automática usa).
    private var larguraDoTexto: CGFloat {
        let e = enquadramento
        return max(1, bounds.width * CGFloat((e.direita - e.esquerda) * (1 - 2 * margem)))
    }

    /// Onde a coluna de texto começa, a partir da esquerda da vista.
    private var xDaColuna: CGFloat {
        let e = enquadramento
        return bounds.width * CGFloat(e.esquerda + (e.direita - e.esquerda) * margem)
    }

    /// Manda o texto, a fonte e a largura para a fila do diagrama. **Vale o último pedido**: um
    /// diagrama que termina depois de um pedido mais novo é descartado, e um que ainda nem começou
    /// não começa.
    private func pedirDiagrama() {
        guard bounds.width > 1, bounds.height > 1 else { diagramaPendente = true; return }
        diagramaPendente = false
        let g = pedidos.proximo()
        let texto = conteudo
        let tamanho = fonte
        let largura = larguraDoTexto
        let f = UIFont.systemFont(ofSize: CGFloat(tamanho), weight: .semibold)
        // Altura de linha **fixa**: toda linha tem a mesma altura, com emoji ou sem, e a "linha" da
        // velocidade é um número só.
        let alturaDaLinha = GeometriaDoRoteiro.noPixel(Double(f.lineHeight) * 1.2, escala: Double(escala))
        let ct = f as CTFont
        let pedidoEm = CACurrentMediaTime()
        let pedidos = self.pedidos
        fila.async { [weak self] in
            guard pedidos.atual == g else { return }
            guard let d = DiagramaDoRoteiro.diagramar(texto, fonte: ct, tamanho: tamanho, largura: largura,
                                                      alturaDaLinha: alturaDaLinha, geracao: g,
                                                      deveParar: { pedidos.atual != g })
            else { return }
            DispatchQueue.main.async { self?.receber(d, pedidoEm: pedidoEm) }
        }
    }

    /// O ponto de leitura agora, no diagrama que está na tela.
    private func pontoDeLeituraAgora() -> PontoDeLeitura? {
        guard let d = diagrama, let g = geometria else { return nil }
        return d.tabela.pontoDeLeitura(noTexto: g.leituraNoTexto(deslocamento: y))
    }

    /// Quantas linhas o caractere `c` está da linha de leitura agora (positivo: abaixo dela). É a
    /// conferência do instrumento, do deslocamento que **foi aplicado** ao rolador.
    private func linhasAteALeitura(_ c: Int) -> Double? {
        guard let d = diagrama, let g = geometria, d.tabela.quantas > 0 else { return nil }
        let leitura = g.leituraNoTexto(deslocamento: Double(rolador.contentOffset.y))
        let centro = (Double(d.tabela.linha(doCaractere: c)) + 0.5) * d.tabela.alturaDaLinha
        return (centro - leitura) / d.tabela.alturaDaLinha
    }

    /// A troca: o diagrama pronto entra, com a linha que estava na leitura de volta nela.
    private func receber(_ d: DiagramaDoRoteiro, pedidoEm: CFTimeInterval) {
        guard d.geracao == pedidos.atual else { return }
        let inicio = CACurrentMediaTime()
        let ponto = pontoDeLeituraAgora()
        let antes = ponto.flatMap { p in linhasAteALeitura(p.caractere) }
        diagrama = d
        montarGeometria(ponto: ponto, diagramaNovo: true)
        let fim = CACurrentMediaTime()
        medidor.etapa("trocar", ms: (fim - inicio) * 1000, agora: fim)
        fimDoLayout = fim
        medidor.nota("bytes=\(d.bytes)")
        medidor.nota(String(format: "fonte=%.0f", d.fonte))
        medidor.nota(String(format: "fundo_ms=%.1f", d.custoMs))
        medidor.nota(String(format: "espera_ms=%.1f", (fim - pedidoEm) * 1000))
        if let p = ponto, let a = antes, let depois = linhasAteALeitura(p.caractere) {
            medidor.nota(String(format: "pulo_linhas=%.2f", depois - a))
        }
        if let g = geometria {
            DiarioDoTeleprompter.dizer(String(format: "layout: trocado em %.1f ms na principal (diagramado em %.0f ms "
                                              + "fora dela, %.0f ms depois do pedido; texto %d bytes, %d linhas, "
                                              + "fonte %.1f, linha %.1f pt, vista %.0fx%.0f, percurso %.0f pt)",
                                              (fim - inicio) * 1000, d.custoMs, (fim - pedidoEm) * 1000, d.bytes,
                                              d.tabela.quantas, d.fonte, g.alturaDaLinha, bounds.width,
                                              bounds.height, g.percurso))
        }
    }

    /// A linha de leitura ou a altura da vista mudou: o diagrama serve, a geometria não.
    private func refazerGeometria(motivo: String) {
        guard diagrama != nil else { return }
        let inicio = CACurrentMediaTime()
        montarGeometria(ponto: pontoDeLeituraAgora(), diagramaNovo: false)
        let fim = CACurrentMediaTime()
        medidor.etapa("geometria", ms: (fim - inicio) * 1000, agora: fim)
        fimDoLayout = fim
    }

    /// Monta a geometria do diagrama atual e põe o ponto de leitura na linha de leitura (ou, sem
    /// diagrama anterior, a fração que a vista tinha — um salto pedido antes do primeiro layout).
    ///
    /// `diagramaNovo`: os blocos são do diagrama que saiu, e são pintados de novo. Sem diagrama novo
    /// (a altura da vista ou a linha de leitura mudou), os blocos são os mesmos e só **mudam de
    /// lugar**. Medido no giro do iPhone X (14/09): o SwiftUI anima o tamanho da vista num giro, e
    /// ela recebe ~18 tamanhos em ~0,35 s; repintando os blocos a cada um, eram 128–292 ms de
    /// desenho na principal durante a animação.
    private func montarGeometria(ponto: PontoDeLeitura?, diagramaNovo: Bool) {
        guard let d = diagrama, bounds.height > 1 else { return }
        let g = GeometriaDoRoteiro(alturaDaVista: Double(bounds.height), alturaDaLinha: d.tabela.alturaDaLinha,
                                   alturaDoTexto: max(d.tabela.alturaDoTexto, d.tabela.alturaDaLinha),
                                   linhaDeLeitura: linhaDeLeitura)
        geometria = g
        let tamanho = CGSize(width: bounds.width, height: CGFloat(g.folgaDeCima + g.alturaDoTexto + g.folgaDeBaixo))
        if diagramaNovo {
            descartarBlocos()
        } else {
            moverBlocos(d, g)
        }
        palco.frame = CGRect(origin: .zero, size: tamanho)
        rolador.contentSize = tamanho
        if let p = ponto {
            y = g.deslocamento(leituraNoTexto: d.tabela.noTexto(paraPonto: p))
        } else {
            y = g.deslocamento(posicao: posicaoAtual)
        }
        posicaoAtual = g.posicao(deslocamento: y)
        aplicarDeslocamento()
        posicionarBlocos()
        desenharMarcador(g)
        vazio.isHidden = !conteudo.isEmpty
        ultimoRelato = -1
        relatar(posicaoAtual)
    }

    // --- os blocos ------------------------------------------------------------------------------

    func scrollViewDidScroll(_ scrollView: UIScrollView) { posicionarBlocos() }

    /// Os blocos da tela e de meia tela antes e depois: cria os que faltam (pintados no commit) e
    /// solta o resto. Rolar não redesenha nada — os blocos vão junto com o conteúdo do rolador.
    private func posicionarBlocos() {
        guard let d = diagrama, let g = geometria, d.tabela.quantas > 0 else { descartarBlocos(); return }
        let L = d.tabela.alturaDaLinha
        let porBloco = max(1, Int(VistaDoRoteiroUIKit.alturaDoBloco / L))
        let H = Double(bounds.height)
        let topo = Double(rolador.contentOffset.y) - g.folgaDeCima
        let faixa = d.tabela.linhas(de: topo - H / 2, ate: topo + H * 1.5)
        guard let primeira = faixa.first, let ultima = faixa.last else { descartarBlocos(); return }
        let blocosVisiveis = (primeira / porBloco)...(ultima / porBloco)
        guard blocosVisiveis != faixaDosBlocos else { return }
        faixaDosBlocos = blocosVisiveis
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, b) in blocos where !blocosVisiveis.contains(k) {
            b.removeFromSuperlayer()
            blocos[k] = nil
        }
        let x = xDaColuna
        for k in blocosVisiveis where blocos[k] == nil {
            let a = k * porBloco
            let z = min(d.tabela.quantas, a + porBloco)
            guard a < z else { continue }
            let b = BlocoDoRoteiro()
            b.linhas = d.linhas(a..<z)
            b.alturaDaLinha = CGFloat(L)
            b.base = d.base
            b.larguraDaColuna = d.largura
            b.contentsScale = escala
            b.frame = CGRect(x: x - 1, y: CGFloat(g.folgaDeCima + Double(a) * L),
                             width: d.largura + 2, height: CGFloat(Double(z - a) * L))
            b.setNeedsDisplay()
            palco.layer.addSublayer(b)
            blocos[k] = b
        }
        CATransaction.commit()
    }

    /// Os blocos que já estão pintados, no lugar da geometria nova — sem pintar nada.
    private func moverBlocos(_ d: DiagramaDoRoteiro, _ g: GeometriaDoRoteiro) {
        guard !blocos.isEmpty else { return }
        let L = d.tabela.alturaDaLinha
        let porBloco = max(1, Int(VistaDoRoteiroUIKit.alturaDoBloco / L))
        let x = xDaColuna
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, b) in blocos {
            b.frame.origin = CGPoint(x: x - 1, y: CGFloat(g.folgaDeCima + Double(k * porBloco) * L))
        }
        CATransaction.commit()
    }

    private func descartarBlocos() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for b in blocos.values { b.removeFromSuperlayer() }
        CATransaction.commit()
        blocos.removeAll()
        faixaDosBlocos = nil
    }

    /// Dois triângulos nas bordas, na altura da linha de leitura, e um fio entre eles.
    private func desenharMarcador(_ g: GeometriaDoRoteiro) {
        let r = CGFloat(g.r)
        let w = bounds.width
        let lado: CGFloat = 12
        let caminho = UIBezierPath()
        caminho.move(to: CGPoint(x: 0, y: r - lado / 2))
        caminho.addLine(to: CGPoint(x: lado, y: r))
        caminho.addLine(to: CGPoint(x: 0, y: r + lado / 2))
        caminho.close()
        caminho.move(to: CGPoint(x: w, y: r - lado / 2))
        caminho.addLine(to: CGPoint(x: w - lado, y: r))
        caminho.addLine(to: CGPoint(x: w, y: r + lado / 2))
        caminho.close()
        caminho.move(to: CGPoint(x: lado, y: r))
        caminho.addLine(to: CGPoint(x: w - lado, y: r))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marcador.frame = conteiner.bounds
        marcador.path = caminho.cgPath
        CATransaction.commit()
    }

    /// O que o VoiceOver lê: a linha de leitura e as duas seguintes.
    private func textoNaLeitura() -> String? {
        guard let d = diagrama, let g = geometria, d.tabela.quantas > 0 else { return nil }
        let i = d.tabela.linha(noTexto: g.leituraNoTexto(deslocamento: y))
        return d.textoDas(i..<(i + 3), em: conteudo)
    }

    // --- o dedo -----------------------------------------------------------------------------------

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { terminouOArrasto() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { terminouOArrasto() }

    /// O arrasto acabou: o relógio retoma **de onde o dedo deixou**, preso ao trilho.
    private func terminouOArrasto() {
        guard let g = geometria else { return }
        y = min(g.y1, max(g.y0, Double(rolador.contentOffset.y)))
        posicaoAtual = g.posicao(deslocamento: y)
        ultimoInstante = 0
        relatar(posicaoAtual)
    }
}

/// O rolador do roteiro: um `UIScrollView` que o VoiceOver lê como texto — o `UITextView` de antes
/// era lido de graça, e os blocos pintados não são.
final class RoladorDoRoteiro: UIScrollView {
    var textoParaLer: () -> String? = { nil }

    override var isAccessibilityElement: Bool {
        get { true }
        set {}
    }

    override var accessibilityLabel: String? {
        get { tr("Roteiro") }
        set {}
    }

    override var accessibilityValue: String? {
        get { textoParaLer() }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { .staticText }
        set {}
    }
}

/// O número do pedido de diagrama mais novo, lido da fila do diagrama e da principal.
final class ContadorDePedidos {
    private let trava = NSLock()
    private var n = 0

    func proximo() -> Int {
        trava.lock(); defer { trava.unlock() }
        n += 1
        return n
    }

    var atual: Int {
        trava.lock(); defer { trava.unlock() }
        return n
    }
}

/// A vista do roteiro para o SwiftUI.
struct VistaDoRoteiro: UIViewRepresentable {
    @ObservedObject var modelo: ModeloDoTeleprompter
    /// Os ajustes deste aparelho que mexem no desenho do texto (o enquadramento).
    @ObservedObject var ajustes: AjustesLocais
    var aoTocar: () -> Void = {}

    func makeUIView(context: Context) -> VistaDoRoteiroUIKit {
        let v = VistaDoRoteiroUIKit(frame: .zero)
        let m = modelo
        v.aoRelatarPosicao = { m.relatarPosicao($0) }
        v.aoChegarAoFim = { m.chegouAoFim() }
        v.caixaDeSalto = m.caixaDeSalto
        return v
    }

    func updateUIView(_ v: VistaDoRoteiroUIKit, context: Context) {
        v.aoTocar = aoTocar
        v.aplicar(texto: modelo.texto, versao: modelo.versaoDoTexto, estado: modelo.estado,
                  enquadramentos: ajustes.enquadramentos)
    }

    static func dismantleUIView(_ v: VistaDoRoteiroUIKit, coordinator: ()) {
        v.parar()
    }
}
