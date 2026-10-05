import AppKit
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import CoreImage
import ImageIO
import ScreenCaptureKit
import VidroComum

// =====================================================================================
// vidro-receptor — recebe o Annex-B pelo fio, decodifica, lê o cronômetro de volta **nos
// pixels decodificados** e mostra numa janela própria.
//
// A mesma regra dura vale aqui: a conferência opcional de composição captura **apenas a
// janela que este processo criou**, com dupla tranca (windowNumber próprio + owningApplication
// == getpid()). Nenhum quadro é gravado em disco: a origem é padrão sintético nosso e assim
// permanece, mas gravar imagem não é necessário para medir e portanto não se faz.
// =====================================================================================

struct Opcoes {
    var saida: String = "."
    var soquete: String = ""
    var hzApresentacao: Int = 0
    var conferirComposicao = true
    var recorte: Codigo.Regiao = .inteira
    var salvarQuadro: String? = nil
    var procurarFaixa = false

    static func analisar() -> Opcoes {
        var o = Opcoes()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        func exigir(_ nome: String) -> String {
            guard let v = it.next() else {
                FileHandle.standardError.write(Data("vidro-receptor: \(nome) exige valor\n".utf8))
                exit(64)
            }
            return v
        }
        func numero<T: LosslessStringConvertible>(_ nome: String, _ t: T.Type) -> T {
            let bruto = exigir(nome)
            guard let v = T(bruto) else {
                FileHandle.standardError.write(Data("vidro-receptor: \(nome) inválido: \(bruto)\n".utf8))
                exit(64)
            }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--saida": o.saida = exigir(arg)
            case "--soquete": o.soquete = exigir(arg)
            case "--hz-apresentacao": o.hzApresentacao = numero(arg, Int.self)
            case "--sem-conferir-composicao": o.conferirComposicao = false
            // Onde a faixa caiu dentro do quadro, em fração de 0 a 1. Só faz sentido quando o
            // quadro vem de uma CÂMERA apontada para a tela: aí sobra moldura e mesa em volta.
            case "--recorte":
                guard let r = Codigo.Regiao(texto: exigir(arg)) else {
                    FileHandle.standardError.write(Data("--recorte quer x,y,l,a em fração de 0 a 1\n".utf8))
                    exit(2)
                }
                o.recorte = r
            // Grava UM quadro decodificado como PNG e sai. É como se descobre o `--recorte`:
            // sem ver onde a faixa caiu, o número que sair é chute.
            case "--salvar-quadro": o.salvarQuadro = exigir(arg)
            // Acha a faixa sozinho no primeiro quadro que der, e trava nela.
            case "--procurar-faixa": o.procurarFaixa = true
            case "--ajuda", "-h":
                print("""
                    uso: vidro-receptor [opções]
                      --saida DIR                   diretório dos registros
                      --soquete CAMINHO             soquete unix do emissor
                      --hz-apresentacao N           taxa do display link (0 = nativa do painel, padrão)
                      --sem-conferir-composicao     não capturar a própria janela para confirmar
                    """)
                exit(0)
            default:
                FileHandle.standardError.write(Data("vidro-receptor: argumento desconhecido '\(arg)'\n".utf8))
                exit(64)
            }
        }
        // `sun_path` tem 104 bytes; caminho dentro do worktree estoura. Padrão curto e fixo.
        if o.soquete.isEmpty { o.soquete = "/tmp/quall-vidro.sock" }
        return o
    }
}

final class VistaDeSaida: NSView {
    let camadaDeVideo = CALayer()
    override var isFlipped: Bool { true }
    func montar() {
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        camadaDeVideo.contentsGravity = .resize
        camadaDeVideo.isOpaque = true
        camadaDeVideo.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(camadaDeVideo)
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        camadaDeVideo.frame = bounds
        CATransaction.commit()
    }
}

/// Grava um quadro decodificado em PNG, para descobrir onde a faixa caiu no enquadramento.
///
/// Sem isto o `--recorte` seria chute. O arquivo sai do vídeo que a câmera da bancada filmou da
/// tela da bancada — padrão sintético nosso, o mesmo caso que `docs/medir-vidro-a-vidro.md`
/// declara seguro de abrir. Um quadro, e o processo sai: não é gravador.
func salvarPNG(_ pixelBuffer: CVPixelBuffer, em caminho: String) {
    let ci = CIImage(cvPixelBuffer: pixelBuffer)
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(ci, from: ci.extent),
          let destino = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: caminho) as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destino, cg, nil)
    CGImageDestinationFinalize(destino)
}

/// Procura a faixa dentro do quadro, sem ninguém olhar um PNG e calcular à mão.
///
/// **Aceitar o primeiro candidato que lê é fraco demais, e isso foi medido.** Em 03/09 duas
/// corridas do mesmo enquadramento travaram em recortes diferentes — `l=0,90 a=0,30` leu 89 % dos
/// quadros, `l=0,70 a=0,35` leu 15 % e devolveu latências de ±100 s, que é ruído passando por
/// paridade. As quatro conferências de `Codigo.ler` reprovam chute na maioria dos quadros, mas
/// não em TODOS: num quadro só, um recorte errado passa de vez em quando.
///
/// O que separa de verdade é o **índice**: a faixa avança ~1 por desenho, então leituras
/// consecutivas de um recorte certo CRESCEM, e as de um recorte errado saltam a esmo. Por isso a
/// busca aqui é em duas fases — o primeiro quadro levanta os candidatos, os quadros seguintes os
/// pontuam por acerto e por crescimento, e só então trava.
struct BuscaDaFaixa {
    /// Quantos quadros pontuar antes de travar. A 30 fps são ~2/3 de segundo.
    static let quadrosDeProva = 20

    private var candidatos: [Codigo.Regiao] = []
    private var acertos: [Int] = []
    private var crescimentos: [Int] = []
    private var ultimo: [UInt32?] = []
    private var provados = 0
    private(set) var travada: Codigo.Regiao?

    /// Todos os recortes que leem neste quadro. Grade grossa em fração; a maior primeiro.
    private static func candidatosDe(_ pb: CVPixelBuffer) -> [Codigo.Regiao] {
        let passo = 0.05
        var lados: [Double] = []
        var l = 0.30
        while l <= 1.0001 { lados.append(l); l += passo }
        var achados: [Codigo.Regiao] = []
        for larg in lados.reversed() {
            for alt in lados.reversed() {
                var x = 0.0
                while x + larg <= 1.0001 {
                    var y = 0.0
                    while y + alt <= 1.0001 {
                        let r = Codigo.Regiao(x: x, y: y, largura: larg, altura: alt)
                        if case .success = Codigo.ler(de: pb, regiao: r) { achados.append(r) }
                        y += passo
                    }
                    x += passo
                }
            }
        }
        return achados
    }

    /// Devolve `true` quando acabou de travar.
    mutating func alimentar(_ pb: CVPixelBuffer) -> Bool {
        guard travada == nil else { return false }
        if candidatos.isEmpty {
            candidatos = Self.candidatosDe(pb)
            acertos = Array(repeating: 0, count: candidatos.count)
            crescimentos = Array(repeating: 0, count: candidatos.count)
            ultimo = Array(repeating: nil, count: candidatos.count)
            return false
        }
        for (k, r) in candidatos.enumerated() {
            guard case .success(let leitura) = Codigo.ler(de: pb, regiao: r) else { continue }
            acertos[k] += 1
            if let ant = ultimo[k] {
                // Crescimento plausível: a faixa anda ~1 por desenho e o quadro chega a ~30 fps.
                let d = Int(leitura.indice) - Int(ant)
                if d > 0 && d < 240 { crescimentos[k] += 1 }
            }
            ultimo[k] = leitura.indice
        }
        provados += 1
        guard provados >= Self.quadrosDeProva, !candidatos.isEmpty else { return false }
        // Ganha quem cresceu mais; empate desempata por acerto, e depois por área (faixa maior
        // tem mais pixel por célula).
        let melhor = (0..<candidatos.count).max {
            (crescimentos[$0], acertos[$0], candidatos[$0].largura * candidatos[$0].altura)
                < (crescimentos[$1], acertos[$1], candidatos[$1].largura * candidatos[$1].altura)
        }
        guard let k = melhor, crescimentos[k] >= Self.quadrosDeProva / 2 else {
            // Ninguém convenceu: recomeça em vez de travar em ruído.
            candidatos = []; provados = 0
            return false
        }
        travada = candidatos[k]
        return true
    }

    var resumo: [String: Any] {
        guard let t = travada else { return [:] }
        let k = candidatos.firstIndex { $0.x == t.x && $0.y == t.y && $0.largura == t.largura && $0.altura == t.altura }
        return [
            "x": t.x, "y": t.y, "largura": t.largura, "altura": t.altura,
            "candidatos": candidatos.count,
            "acertos": k.map { acertos[$0] } as Any,
            "crescimentos": k.map { crescimentos[$0] } as Any,
            "quadros_de_prova": provados,
        ]
    }
}

final class Receptor: NSObject, SCStreamOutput, SCStreamDelegate {
    let opcoes: Opcoes
    private var salvou = false
    /// A busca da faixa. Trava depois de pontuar candidatos; ver `BuscaDaFaixa`.
    private var busca = BuscaDaFaixa()
    let registro: Registro
    let registroDeQuadros: Registro
    let registroDeApresentacao: Registro

    private var janela: NSWindow!
    private var vista: VistaDeSaida!
    private var displayLink: CADisplayLink?
    private var decodificador: Decodificador!
    private var fd: Int32 = -1
    private var streamDeConferencia: SCStream?
    private let filaDeConferencia = DispatchQueue(label: "br.com.queven.quall.vidro.conferencia")

    private let trava = NSLock()
    private var pendenteParaMostrar: (indice: UInt32, superficie: IOSurfaceRef, decodificadoNs: UInt64)?
    private var mostrandoIndice: UInt32?
    private var retencaoDeQuadros = 0

    private(set) var recebidos = 0
    private(set) var bytesRecebidos = 0
    private(set) var lidosNoDecode = 0
    private(set) var falhasDeLeitura: [String: Int] = [:]
    private(set) var divergenciasDeIndice = 0
    private(set) var semIOSurface = 0
    private(set) var apresentados = 0
    private(set) var conferidosNaComposicao = 0
    private(set) var recapturados = 0
    private(set) var recapturadosIlegiveis = 0
    private(set) var conferenciaTentada = false
    private var indicesApresentados = Set<UInt32>()
    private let travaApresentados = NSLock()

    private var deslocamentoContinuoNs: Int64 = 0
    private var terminou = false

    init(opcoes: Opcoes) throws {
        self.opcoes = opcoes
        try FileManager.default.createDirectory(atPath: opcoes.saida, withIntermediateDirectories: true)
        registro = try Registro(caminho: (opcoes.saida as NSString).appendingPathComponent("receptor.ndjson"))
        registroDeQuadros = try Registro(
            caminho: (opcoes.saida as NSString).appendingPathComponent("receptor-quadros.ndjson"))
        registroDeApresentacao = try Registro(
            caminho: (opcoes.saida as NSString).appendingPathComponent("receptor-apresentacao.ndjson"))
        super.init()
        decodificador = Decodificador { [weak self] pixelBuffer, pts in
            self?.aoDecodificar(pixelBuffer: pixelBuffer, pts: pts)
        }
    }

    func abrirJanela(largura: Int, altura: Int) {
        let quadro = NSRect(x: 780, y: 80, width: CGFloat(largura), height: CGFloat(altura))
        janela = NSWindow(contentRect: quadro, styleMask: [.borderless], backing: .buffered, defer: false)
        janela.title = "Quall · receptor de vidro a vidro (pid \(getpid()))"
        janela.isOpaque = true
        janela.backgroundColor = .black
        vista = VistaDeSaida(frame: NSRect(origin: .zero, size: quadro.size))
        vista.montar()
        janela.contentView = vista
        janela.orderFrontRegardless()
    }

    func ligarDisplayLink() {
        let link = vista.displayLink(target: self, selector: #selector(aoQuadroDeTela(_:)))
        // 0 = não mexer, e o display link roda na taxa nativa do painel. É o que se quer no
        // receptor: quanto mais frequente a chance de acender, menor a quantização que eu
        // acrescento à medição. `minimum: 0` é faixa inválida e derruba o processo.
        if opcoes.hzApresentacao > 0 {
            let hz = Float(opcoes.hzApresentacao)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func conectar() throws {
        fd = try Fio.conectar(em: opcoes.soquete)
        deslocamentoContinuoNs = Relogio.deslocamentoContinuoNs()
        registro.linha([
            "evento": "cabecalho",
            "papel": "receptor",
            "pid": getpid(),
            "hz_apresentacao": opcoes.hzApresentacao,
            "deslocamento_continuo_ns": deslocamentoContinuoNs,
            "desvio_mediatime_ns": Relogio.desvioMediaTimeNs(),
            "refresh_hz": refreshDaTela(),
            "carga_inicio": Carga.retrato(),
            "t_ns": Relogio.agoraNs(),
        ])
    }

    private func refreshDaTela() -> Double {
        guard let tela = janela?.screen ?? NSScreen.main,
            let numero = tela.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let modo = CGDisplayCopyDisplayMode(CGDirectDisplayID(numero.uint32Value))
        else { return 0 }
        let taxa = modo.refreshRate
        return taxa > 0 ? taxa : (tela.maximumFramesPerSecond > 0 ? Double(tela.maximumFramesPerSecond) : 0)
    }

    // MARK: - Laço de leitura do fio

    func laco() {
        while !terminou {
            do {
                guard let cabecalhoBruto = try Fio.lerTudo(fd, Fio.tamanhoDoCabecalho) else { break }
                guard let cabecalho = Fio.Cabecalho.desserializar(cabecalhoBruto) else {
                    FileHandle.standardError.write(Data("vidro-receptor: cabeçalho inválido no fio\n".utf8))
                    break
                }
                guard let corpo = try Fio.lerTudo(fd, Int(cabecalho.tamanho)) else { break }
                let chegadaNs = Relogio.agoraNs()
                recebidos += 1
                bytesRecebidos += corpo.count
                atual = (cabecalho, chegadaNs)
                decodificador.alimentar(corpo, ptsUs: cabecalho.capturaNs / 1000, idr: cabecalho.idr)
            } catch {
                FileHandle.standardError.write(Data("vidro-receptor: fio: \(error)\n".utf8))
                break
            }
        }
        DispatchQueue.main.async { [weak self] in self?.encerrar() }
    }

    /// O decode é síncrono para o nosso uso (uma submissão, um retorno antes da próxima leitura
    /// do fio), então guardar o cabeçalho corrente numa variável é seguro e evita um dicionário
    /// no caminho quente. Se um dia o decode virar assíncrono, isto vira defeito — e é por isso
    /// que confiro o índice lido nos pixels contra o índice do cabeçalho e conto a divergência.
    private var atual: (Fio.Cabecalho, UInt64)?

    private func aoDecodificar(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let decodificadoNs = Relogio.agoraNs()
        guard let (cabecalho, chegadaNs) = atual else { return }

        var indiceLido: UInt32?
        var margem = Double.nan
        // **Salva e SEGUE.** Sair aqui custava uma sessão inteira: o PIN do app vale uma conexão,
        // e o emissor iOS não volta a atender depois dela (`docs/bancada.md` §8.12). E o quadro de
        // uma câmera apontada para a tela pega a área de trabalho junto — `regras-de-frente.md`
        // não permite guardar isso, então o normal é NÃO passar `--salvar-quadro`: quem acha a
        // faixa é `--procurar-faixa`, que não renderiza nada.
        if let caminho = opcoes.salvarQuadro, !salvou {
            salvou = true
            salvarPNG(pixelBuffer, em: caminho)
            FileHandle.standardError.write(Data("quadro salvo em \(caminho)\n".utf8))
        }
        if opcoes.procurarFaixa, busca.travada == nil {
            if busca.alimentar(pixelBuffer) {
                var linha = busca.resumo
                linha["evento"] = "faixa_encontrada"
                registro.linha(linha)
                FileHandle.standardError.write(Data("faixa travada: \(linha)\n".utf8))
            }
            // Enquanto procura, não há leitura para publicar: o recorte ainda não existe.
            return
        }
        switch Codigo.ler(de: pixelBuffer, regiao: busca.travada ?? opcoes.recorte) {
        case .success(let leitura):
            lidosNoDecode += 1
            indiceLido = leitura.indice
            margem = leitura.margemMinima
            if leitura.indice != cabecalho.indice { divergenciasDeIndice += 1 }
        case .failure(let falha):
            falhasDeLeitura[falha.rawValue, default: 0] += 1
        }

        registroDeQuadros.linha([
            "indice_cabecalho": Int(cabecalho.indice),
            "indice_decodificado": indiceLido.map(Int.init) as Any,
            "margem_minima": margem.isNaN ? NSNull() : margem,
            "desenho_ns": cabecalho.desenhoNs,
            "commit_ns": cabecalho.commitNs,
            "captura_ns": cabecalho.capturaNs,
            "pts_ns": cabecalho.ptsNs,
            "encode_ns": cabecalho.encodeNs,
            "envio_ns": cabecalho.envioNs,
            "chegada_ns": chegadaNs,
            "decodificado_ns": decodificadoNs,
            "bytes": Int(cabecalho.tamanho),
            "idr": cabecalho.idr,
        ])

        guard let indiceLido else { return }
        guard let superficie = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            semIOSurface += 1
            return
        }
        trava.lock()
        pendenteParaMostrar = (indiceLido, superficie, decodificadoNs)
        trava.unlock()
    }

    @objc func aoQuadroDeTela(_ link: CADisplayLink) {
        trava.lock()
        let pendente = pendenteParaMostrar
        pendenteParaMostrar = nil
        trava.unlock()

        guard let pendente else {
            if mostrandoIndice != nil { retencaoDeQuadros += 1 }
            return
        }
        let alvoNs = Relogio.nsDeMediaTime(link.targetTimestamp)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        vista.camadaDeVideo.contents = pendente.superficie
        CATransaction.commit()
        CATransaction.flush()
        let commitNs = Relogio.agoraNs()

        if let anterior = mostrandoIndice {
            registroDeApresentacao.linha([
                "evento": "retencao",
                "indice": Int(anterior),
                "quadros_de_tela": retencaoDeQuadros + 1,
            ])
        }
        retencaoDeQuadros = 0
        mostrandoIndice = pendente.indice
        apresentados += 1
        travaApresentados.lock()
        indicesApresentados.insert(pendente.indice)
        travaApresentados.unlock()

        registroDeApresentacao.linha([
            "evento": "acendeu",
            "indice": Int(pendente.indice),
            "decodificado_ns": pendente.decodificadoNs,
            "apresentacao_alvo_ns": alvoNs,
            "apresentacao_commit_ns": commitNs,
        ])
    }

    // MARK: - Conferência de composição (a própria janela, nunca a tela)

    func ligarConferencia() async {
        guard opcoes.conferirComposicao else { return }
        conferenciaTentada = true
        let meuPid = getpid()
        let meuId = CGWindowID(janela.windowNumber)
        guard meuId != 0 else { return }
        do {
            var alvo: SCWindow?
            let limite = Date().addingTimeInterval(6)
            while Date() < limite {
                let conteudo = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if let w = conteudo.windows.first(where: { $0.windowID == meuId }) { alvo = w; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let alvo, let dono = alvo.owningApplication, dono.processID == meuPid else {
                registro.linha([
                    "evento": "conferencia_recusada",
                    "motivo": "janela não casou com este processo",
                    "t_ns": Relogio.agoraNs(),
                ])
                return
            }
            let filtro = SCContentFilter(desktopIndependentWindow: alvo)
            let escala = filtro.pointPixelScale
            let config = SCStreamConfiguration()
            config.width = Int((filtro.contentRect.width * CGFloat(escala)).rounded())
            config.height = Int((filtro.contentRect.height * CGFloat(escala)).rounded())
            config.minimumFrameInterval = CMTime(value: 1, timescale: 10)  // 10 fps bastam
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = false
            config.capturesAudio = false
            config.queueDepth = 3
            config.shouldBeOpaque = true
            config.backgroundColor = .black
            let s = SCStream(filter: filtro, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: filaDeConferencia)
            try await s.startCapture()
            streamDeConferencia = s
        } catch {
            registro.linha([
                "evento": "conferencia_falhou",
                "erro": "\(error)",
                "t_ns": Relogio.agoraNs(),
            ])
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        recapturados += 1
        guard case .success(let leitura) = Codigo.ler(de: pb) else {
            recapturadosIlegiveis += 1
            return
        }
        travaApresentados.lock()
        let conhecido = indicesApresentados.contains(leitura.indice)
        travaApresentados.unlock()
        if conhecido { conferidosNaComposicao += 1 }
    }

    // MARK: - Encerramento

    func encerrar() {
        guard !terminou else { return }
        terminou = true
        displayLink?.invalidate()
        displayLink = nil
        if let s = streamDeConferencia {
            let grupo = DispatchGroup()
            grupo.enter()
            Task { try? await s.stopCapture(); grupo.leave() }
            _ = grupo.wait(timeout: .now() + 3)
        }
        decodificador.encerrar()
        registro.linha([
            "evento": "resumo",
            "recebidos": recebidos,
            "bytes_recebidos": bytesRecebidos,
            "decodificados": decodificador.decodificados,
            "decode_recusados": decodificador.recusados,
            "decode_sem_parametros": decodificador.semParametros,
            "decode_sessoes": decodificador.sessoesCriadas,
            "decode_hardware": decodificador.emHardware,
            "lidos_no_decode": lidosNoDecode,
            "falhas_de_leitura": falhasDeLeitura,
            "divergencias_de_indice": divergenciasDeIndice,
            "sem_iosurface": semIOSurface,
            "apresentados": apresentados,
            "conferencia_tentada": conferenciaTentada,
            "conferidos_na_composicao": conferidosNaComposicao,
            "recapturados": recapturados,
            "recapturados_ilegiveis": recapturadosIlegiveis,
            "carga_fim": Carga.retrato(),
            "t_ns": Relogio.agoraNs(),
        ])
        registro.fechar()
        registroDeQuadros.fechar()
        registroDeApresentacao.fechar()
        if fd >= 0 { close(fd) }

        print("""
            === receptor ===
            recebidos do fio      \(recebidos)
            decodificados         \(decodificador.decodificados)  (hardware=\(decodificador.emHardware))
            decode recusados      \(decodificador.recusados)
            lidos no decode       \(lidosNoDecode)
            falhas de leitura     \(falhasDeLeitura)
            divergência de índice \(divergenciasDeIndice)
            apresentados          \(apresentados)
            conferidos na composição \(conferidosNaComposicao) (tentada=\(conferenciaTentada))
            """)
        exit(0)
    }
}

// MARK: - Entrada

let opcoes = Opcoes.analisar()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let receptor: Receptor
do {
    receptor = try Receptor(opcoes: opcoes)
} catch {
    FileHandle.standardError.write(Data("vidro-receptor: \(error)\n".utf8))
    exit(1)
}
receptor.abrirJanela(largura: 640, altura: 360)
do {
    try receptor.conectar()
} catch {
    FileHandle.standardError.write(Data("vidro-receptor: \(error)\n".utf8))
    exit(1)
}
receptor.ligarDisplayLink()
Task { await receptor.ligarConferencia() }
Thread.detachNewThread { receptor.laco() }
app.run()
