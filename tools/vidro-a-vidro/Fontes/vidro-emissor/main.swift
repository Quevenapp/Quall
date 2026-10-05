import AppKit
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import ScreenCaptureKit
import VidroComum

// =====================================================================================
// vidro-emissor — o lado que desenha o cronômetro e o captura.
//
// REGRA DURA DESTE ARQUIVO: este processo captura **apenas a janela que ele mesmo criou**.
// O `CGWindowID` não vem de enumeração nem de argumento: vem do `NSWindow.windowNumber` da
// janela construída algumas linhas acima. Antes de abrir o stream ainda confiro que o
// `SCWindow` casado tem `owningApplication.processID == getpid()`. Se qualquer uma das duas
// conferências falhar, o processo aborta sem capturar nada.
//
// Não existe, e não deve passar a existir, nenhum `SCContentFilter(display:)` nesta árvore.
// O MacBook é a máquina de trabalho do usuário.
// =====================================================================================

struct Opcoes {
    var segundos: Double = 20
    var hzDesenho: Int = 60
    var fpsCaptura: Int = 60
    var larguraPt: Int = 640
    var alturaPt: Int = 360
    var saida: String = "."
    var soquete: String = ""
    var bitrate: Int = 4_000_000
    var esperaDeConexao: Double = 30

    static func analisar() -> Opcoes {
        var o = Opcoes()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        func exigir(_ nome: String) -> String {
            guard let v = it.next() else {
                FileHandle.standardError.write(Data("vidro-emissor: \(nome) exige valor\n".utf8))
                exit(64)
            }
            return v
        }
        func numero<T: LosslessStringConvertible>(_ nome: String, _ t: T.Type) -> T {
            let bruto = exigir(nome)
            guard let v = T(bruto) else {
                // Falhar alto. O CLI vizinho ignora valor inválido em silêncio e roda com o
                // padrão; numa medição isso produz um número certo para a corrida errada.
                FileHandle.standardError.write(Data("vidro-emissor: \(nome) inválido: \(bruto)\n".utf8))
                exit(64)
            }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--segundos": o.segundos = numero(arg, Double.self)
            case "--hz-desenho": o.hzDesenho = numero(arg, Int.self)
            case "--fps-captura": o.fpsCaptura = numero(arg, Int.self)
            case "--largura": o.larguraPt = numero(arg, Int.self)
            case "--altura": o.alturaPt = numero(arg, Int.self)
            case "--saida": o.saida = exigir(arg)
            case "--soquete": o.soquete = exigir(arg)
            case "--bitrate": o.bitrate = numero(arg, Int.self)
            case "--espera-conexao": o.esperaDeConexao = numero(arg, Double.self)
            case "--ajuda", "-h":
                print("""
                    uso: vidro-emissor [opções]
                      --segundos N         duração da medição (padrão 20)
                      --hz-desenho N       taxa de desenho do cronômetro (padrão 60)
                      --fps-captura N      teto de quadros do ScreenCaptureKit (padrão 60)
                      --largura N          largura da janela em pontos (padrão 640)
                      --altura N           altura da janela em pontos (padrão 360)
                      --saida DIR          diretório dos registros
                      --soquete CAMINHO    soquete unix para o receptor
                      --bitrate BPS        bitrate alvo do H.264 (padrão 4000000)
                      --espera-conexao S   quanto esperar o receptor (padrão 30)
                    """)
                exit(0)
            default:
                FileHandle.standardError.write(Data("vidro-emissor: argumento desconhecido '\(arg)'\n".utf8))
                exit(64)
            }
        }
        // `sun_path` tem 104 bytes; caminho dentro do worktree estoura. Padrão curto e fixo.
        if o.soquete.isEmpty { o.soquete = "/tmp/quall-vidro.sock" }
        return o
    }
}

final class VistaDoCronometro: NSView {
    private(set) var camadas: [CALayer] = []

    override var isFlipped: Bool { true }

    func montar() {
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.isGeometryFlipped = true
        for _ in 0..<Codigo.totalCelulas {
            let c = CALayer()
            c.backgroundColor = CGColor(gray: 0, alpha: 1)
            c.isOpaque = true
            c.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(c)
            camadas.append(c)
        }
        posicionar()
    }

    override func layout() {
        super.layout()
        posicionar()
    }

    private func posicionar() {
        let l = bounds.width / CGFloat(Codigo.colunas)
        let a = bounds.height / CGFloat(Codigo.linhas)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<camadas.count {
            let coluna = CGFloat(i % Codigo.colunas)
            let linha = CGFloat(i / Codigo.colunas)
            camadas[i].frame = CGRect(x: coluna * l, y: linha * a, width: l, height: a)
        }
        CATransaction.commit()
    }
}

final class Emissor: NSObject, SCStreamOutput, SCStreamDelegate {
    let opcoes: Opcoes
    let registro: Registro
    let registroDeQuadros: Registro
    /// Um carimbo por DESENHO, capturado ou não.
    ///
    /// **`registroDeQuadros` só escreve quando o quadro é capturado E enviado**, porque foi escrito
    /// para o laço fechado, onde as duas coisas sempre acontecem. O método da câmera não tem laço:
    /// quem lê a faixa é um sensor do outro lado do vidro, e o que ele vê é o que está na TELA —
    /// capturado ou não. Em 03/09 a captura parou aos 16 s de uma corrida de 200 s enquanto o
    /// desenho seguia, e o casamento por índice deu zero de 3.466 leituras boas. Este registro é o
    /// conserto: ele não depende de captura, de socket nem de receptor.
    let registroDeDesenhos: Registro

    private var janela: NSWindow!
    private var vista: VistaDoCronometro!
    private var displayLink: CADisplayLink?
    private var stream: SCStream?
    private var codificador: Codificador?

    private let branco = CGColor(gray: 1, alpha: 1)
    private let preto = CGColor(gray: 0, alpha: 1)

    // Registro de desenho: índice -> instante previsto de varredura.
    private let trava = NSLock()
    private var desenhos: [UInt32: (alvoNs: UInt64, commitNs: UInt64)] = [:]
    private var indiceAtual: UInt32 = 0

    private var deslocamentoContinuoNs: Int64 = 0
    private var fd: Int32 = -1
    private var ouvinte: Int32 = -1
    private let filaDeCaptura = DispatchQueue(label: "br.com.queven.quall.vidro.captura")
    private let filaDeEnvio = DispatchQueue(label: "br.com.queven.quall.vidro.envio")

    // Correlação encoder: pts em microssegundos -> dados do quadro capturado.
    private let travaPendentes = NSLock()
    private var pendentes: [Int64: (indice: UInt32, desenhoNs: UInt64, commitNs: UInt64, capturaNs: UInt64, ptsNs: UInt64)] = [:]

    // Contadores. Perda silenciosa vira número, não some.
    private(set) var desenhados = 0
    private(set) var capturados = 0
    private(set) var lidosNaCaptura = 0
    private(set) var falhasDeLeitura: [String: Int] = [:]
    private(set) var orfaos = 0
    private(set) var submissoesRecusadas = 0
    private(set) var codificados = 0
    private(set) var enviados = 0
    private(set) var verificado = false
    private var acertosSeguidos = 0
    private var inicioDaMedicaoNs: UInt64 = 0
    private var medindo = false

    init(opcoes: Opcoes) throws {
        self.opcoes = opcoes
        try FileManager.default.createDirectory(
            atPath: opcoes.saida, withIntermediateDirectories: true)
        registro = try Registro(caminho: (opcoes.saida as NSString).appendingPathComponent("emissor.ndjson"))
        registroDeDesenhos = try Registro(
            caminho: (opcoes.saida as NSString).appendingPathComponent("emissor-desenhos.ndjson"))
        registroDeQuadros = try Registro(
            caminho: (opcoes.saida as NSString).appendingPathComponent("emissor-quadros.ndjson"))
        super.init()
    }

    // MARK: - Janela

    func abrirJanela() {
        let quadro = NSRect(x: 80, y: 80, width: CGFloat(opcoes.larguraPt), height: CGFloat(opcoes.alturaPt))
        // SEM barra de título, de propósito: com `.titled`, o `SCContentFilter` de janela
        // devolve o quadro INTEIRO da janela (medido: 1280x784 para 640x360 pt de conteúdo), e a
        // grade de células deixa de coincidir com a imagem capturada. Borderless faz
        // `contentRect` == conteúdo, e a geometria da leitura passa a ser exata em vez de
        // aproximadamente certa.
        janela = NSWindow(
            contentRect: quadro, styleMask: [.borderless], backing: .buffered, defer: false)
        janela.title = "Quall · cronômetro de vidro a vidro (pid \(getpid()))"
        janela.isOpaque = true
        janela.backgroundColor = .black
        janela.level = .normal
        vista = VistaDoCronometro(frame: NSRect(origin: .zero, size: quadro.size))
        vista.montar()
        janela.contentView = vista
        janela.orderFrontRegardless()
        desenhar(indice: 0, alvoNs: Relogio.agoraNs())
    }

    private func desenhar(indice: UInt32, alvoNs: UInt64) {
        let celulas = Codigo.celulas(paraIndice: indice)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<Codigo.totalCelulas {
            vista.camadas[i].backgroundColor = celulas[i] ? branco : preto
        }
        CATransaction.commit()
        CATransaction.flush()
        let commitNs = Relogio.agoraNs()
        trava.lock()
        desenhos[indice] = (alvoNs, commitNs)
        trava.unlock()
        desenhados += 1
        // Depois de `commitNs`, nunca antes: `Registro.linha` é assíncrono, mas a serialização do
        // dicionário custa, e ela não pode entrar na conta do desenho que estamos carimbando.
        registroDeDesenhos.linha(["indice": Int(indice), "alvo_ns": alvoNs, "commit_ns": commitNs])
    }

    @objc func aoQuadroDeTela(_ link: CADisplayLink) {
        let alvo = Relogio.nsDeMediaTime(link.targetTimestamp)
        indiceAtual = (indiceAtual &+ 1) % Codigo.modulo
        desenhar(indice: indiceAtual, alvoNs: alvo)
    }

    func ligarDisplayLink() {
        let link = vista.displayLink(target: self, selector: #selector(aoQuadroDeTela(_:)))
        let hz = Float(opcoes.hzDesenho)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // MARK: - Captura, só da própria janela

    func prepararCaptura() async throws {
        let meuPid = getpid()
        let meuId = CGWindowID(janela.windowNumber)
        guard meuId != 0 else { throw ErroDoEmissor.janelaSemId }

        var alvo: SCWindow?
        let limite = Date().addingTimeInterval(10)
        while Date() < limite {
            let conteudo = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            if let w = conteudo.windows.first(where: { $0.windowID == meuId }) {
                alvo = w
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let alvo else { throw ErroDoEmissor.janelaNaoApareceu(meuId) }

        // Segunda tranca: o dono da janela tem de ser este processo.
        guard let dono = alvo.owningApplication, dono.processID == meuPid else {
            throw ErroDoEmissor.janelaDeOutroProcesso(
                alvo.owningApplication?.processID ?? -1, alvo.owningApplication?.bundleIdentifier ?? "?")
        }

        let filtro = SCContentFilter(desktopIndependentWindow: alvo)
        let escala = filtro.pointPixelScale
        let largura = Int((filtro.contentRect.width * CGFloat(escala)).rounded())
        let altura = Int((filtro.contentRect.height * CGFloat(escala)).rounded())

        let config = SCStreamConfiguration()
        config.width = largura
        config.height = altura
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(opcoes.fpsCaptura))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false  // um cursor por cima das células corromperia a leitura
        config.capturesAudio = false
        config.queueDepth = 3
        config.scalesToFit = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = true
        config.backgroundColor = .black

        codificador = try Codificador(
            largura: Int32(largura), altura: Int32(altura), fps: Int32(opcoes.fpsCaptura),
            bitrateBps: opcoes.bitrate)

        registro.linha([
            "evento": "cabecalho",
            "papel": "emissor",
            "pid": meuPid,
            "window_id": Int(meuId),
            "dono_pid": dono.processID,
            "dono_bundle": dono.bundleIdentifier,
            "janela_titulo_confere": alvo.title == janela.title,
            "captura_largura": largura,
            "captura_altura": altura,
            "point_pixel_scale": escala,
            "hz_desenho": opcoes.hzDesenho,
            "fps_captura": opcoes.fpsCaptura,
            "bitrate_bps": opcoes.bitrate,
            "encoder": codificador?.nome ?? "?",
            "encoder_hardware": codificador?.emHardware ?? false,
            "deslocamento_continuo_ns": deslocamentoContinuoNs,
            "desvio_mediatime_ns": Relogio.desvioMediaTimeNs(),
            "refresh_hz": refreshDaTela(),
            "carga_inicio": Carga.retrato(),
            "t_ns": Relogio.agoraNs(),
        ])

        let s = SCStream(filter: filtro, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: filaDeCaptura)
        try await s.startCapture()
        stream = s
    }

    private func refreshDaTela() -> Double {
        guard let tela = janela.screen ?? NSScreen.main,
            let numero = tela.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let modo = CGDisplayCopyDisplayMode(CGDirectDisplayID(numero.uint32Value))
        else { return 0 }
        let taxa = modo.refreshRate
        return taxa > 0 ? taxa : (tela.maximumFramesPerSecond > 0 ? Double(tela.maximumFramesPerSecond) : 0)
    }

    // MARK: - Fio

    func abrirFio() throws {
        ouvinte = try Fio.ouvir(em: opcoes.soquete)
    }

    func aceitarReceptor() throws {
        var conjunto = pollfd(fd: ouvinte, events: Int16(POLLIN), revents: 0)
        let r = poll(&conjunto, 1, Int32(opcoes.esperaDeConexao * 1000))
        guard r > 0 else { throw ErroDoEmissor.receptorNaoConectou }
        fd = try Fio.aceitar(ouvinte)
    }

    // MARK: - Quadro capturado

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let chegadaNs = Relogio.agoraNs()
        guard let anexos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let bruto = anexos.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: bruto), status == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        capturados += 1

        // O pts do ScreenCaptureKit é da base CONTÍNUA. Trago para a base canônica com o
        // deslocamento medido no início — nunca subtraio bases diferentes.
        let ptsContinuoNs = UInt64(
            max(0, (CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1_000_000_000).rounded()))
        let ptsNs = UInt64(max(0, Int64(bitPattern: ptsContinuoNs) - deslocamentoContinuoNs))

        switch Codigo.ler(de: pixelBuffer) {
        case .failure(let falha):
            falhasDeLeitura[falha.rawValue, default: 0] += 1
            return
        case .success(let leitura):
            lidosNaCaptura += 1
            trava.lock()
            let desenho = desenhos[leitura.indice]
            trava.unlock()
            guard let desenho else {
                orfaos += 1
                return
            }
            // Verificação de geometria no fluxo: só começo a medir depois de N leituras
            // seguidas que casam com o registro de desenho. Se a grade estivesse fora de
            // lugar, a paridade e as referências reprovariam e eu nunca chegaria aqui.
            if !verificado {
                acertosSeguidos += 1
                if acertosSeguidos >= 30 {
                    verificado = true
                    medindo = true
                    inicioDaMedicaoNs = chegadaNs
                    registro.linha([
                        "evento": "geometria_verificada",
                        "leituras_seguidas": acertosSeguidos,
                        "margem_minima": leitura.margemMinima,
                        "ref_branco": leitura.referenciaBranco,
                        "ref_preto": leitura.referenciaPreto,
                        "t_ns": chegadaNs,
                    ])
                }
                return
            }
            guard medindo else { return }

            var ptsUs = Int64(chegadaNs / 1000)
            travaPendentes.lock()
            while pendentes[ptsUs] != nil { ptsUs += 1 }
            pendentes[ptsUs] = (leitura.indice, desenho.alvoNs, desenho.commitNs, chegadaNs, ptsNs)
            travaPendentes.unlock()

            let pts = CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000)
            let duracao = CMTime(value: 1, timescale: CMTimeScale(opcoes.fpsCaptura))
            let ok = codificador?.codificar(pixelBuffer, pts: pts, duracao: duracao) { [weak self] annexB, ptsSaida, idr in
                self?.aoCodificar(annexB: annexB, pts: ptsSaida, idr: idr)
            } ?? false
            if !ok {
                submissoesRecusadas += 1
                travaPendentes.lock()
                pendentes.removeValue(forKey: ptsUs)
                travaPendentes.unlock()
            }
        }
    }

    private func aoCodificar(annexB: Data, pts: CMTime, idr: Bool) {
        let encodeNs = Relogio.agoraNs()
        let chave = Int64((pts.seconds * 1_000_000).rounded())
        travaPendentes.lock()
        let info = pendentes.removeValue(forKey: chave)
        travaPendentes.unlock()
        guard let info else { return }
        codificados += 1

        filaDeEnvio.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            let envioNs = Relogio.agoraNs()
            let cabecalho = Fio.Cabecalho(
                indice: info.indice, desenhoNs: info.desenhoNs, commitNs: info.commitNs,
                capturaNs: info.capturaNs, ptsNs: info.ptsNs, encodeNs: encodeNs, envioNs: envioNs, idr: idr,
                tamanho: UInt32(annexB.count))
            do {
                try Fio.escreverTudo(self.fd, cabecalho.serializar())
                try Fio.escreverTudo(self.fd, annexB)
                self.enviados += 1
                self.registroDeQuadros.linha([
                    "indice": Int(info.indice),
                    "desenho_ns": info.desenhoNs,
                    "commit_ns": info.commitNs,
                    "captura_ns": info.capturaNs,
                    "pts_ns": info.ptsNs,
                    "encode_ns": encodeNs,
                    "envio_ns": envioNs,
                    "bytes": annexB.count,
                    "idr": idr,
                ])
            } catch {
                FileHandle.standardError.write(Data("vidro-emissor: fio quebrou: \(error)\n".utf8))
                self.fd = -1
            }
        }
    }

    // MARK: - Encerramento

    func encerrar() async {
        medindo = false
        displayLink?.invalidate()
        displayLink = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        codificador?.encerrar()
        filaDeEnvio.sync {}
        registro.linha([
            "evento": "resumo",
            "desenhados": desenhados,
            "capturados": capturados,
            "lidos_na_captura": lidosNaCaptura,
            "falhas_de_leitura": falhasDeLeitura,
            "orfaos": orfaos,
            "submissoes_recusadas": submissoesRecusadas,
            "codificados": codificados,
            "enviados": enviados,
            "geometria_verificada": verificado,
            "carga_fim": Carga.retrato(),
            "t_ns": Relogio.agoraNs(),
        ])
        registro.fechar()
        registroDeQuadros.fechar()
        registroDeDesenhos.fechar()
        if fd >= 0 { close(fd) }
        if ouvinte >= 0 { close(ouvinte) }
        unlink(opcoes.soquete)

        print("""
            === emissor ===
            desenhados          \(desenhados)
            capturados (SCK)    \(capturados)
            lidos na captura    \(lidosNaCaptura)
            falhas de leitura   \(falhasDeLeitura)
            órfãos              \(orfaos)
            submissões recusadas \(submissoesRecusadas)
            codificados         \(codificados)
            enviados            \(enviados)
            """)
    }

    func medirDeslocamento() {
        deslocamentoContinuoNs = Relogio.deslocamentoContinuoNs()
    }
}

enum ErroDoEmissor: Error, CustomStringConvertible {
    case janelaSemId
    case janelaNaoApareceu(CGWindowID)
    case janelaDeOutroProcesso(pid_t, String)
    case receptorNaoConectou
    var description: String {
        switch self {
        case .janelaSemId: return "a janela não tem windowNumber"
        case .janelaNaoApareceu(let id):
            return "a janela \(id) não apareceu em SCShareableContent — sem alvo isolado, não capturo"
        case .janelaDeOutroProcesso(let pid, let bundle):
            return "RECUSADO: a janela casada pertence ao pid \(pid) (\(bundle)), não a este processo"
        case .receptorNaoConectou: return "o receptor não conectou no soquete dentro do prazo"
        }
    }
}

// MARK: - Entrada

let opcoes = Opcoes.analisar()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let emissor: Emissor
do {
    emissor = try Emissor(opcoes: opcoes)
} catch {
    FileHandle.standardError.write(Data("vidro-emissor: \(error)\n".utf8))
    exit(1)
}
emissor.medirDeslocamento()
emissor.abrirJanela()
do {
    try emissor.abrirFio()
} catch {
    FileHandle.standardError.write(Data("vidro-emissor: \(error)\n".utf8))
    exit(1)
}
print("vidro-emissor: soquete em \(opcoes.soquete)")
fflush(stdout)

Task { @MainActor in
    do {
        try await Task.detached { try emissor.aceitarReceptor() }.value
        emissor.ligarDisplayLink()
        try await emissor.prepararCaptura()
    } catch {
        FileHandle.standardError.write(Data("vidro-emissor: \(error)\n".utf8))
        await emissor.encerrar()
        exit(1)
    }
    // Uma janela de graça para a verificação de geometria acontecer antes do relógio de corrida.
    try? await Task.sleep(nanoseconds: UInt64((opcoes.segundos + 3) * 1_000_000_000))
    await emissor.encerrar()
    exit(emissor.verificado ? 0 : 2)
}

app.run()
