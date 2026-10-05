import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import Darwin
import QuallReceptorKit
import ScreenCaptureKit

/// **A janela de vídeo recapturada**: o T1 do `docs/som-no-receptor.md` §9.4 completo (a S7).
///
/// As testemunhas A e B da S4 põem a imagem na hora em que a camada **aceitou** o quadro, mais um
/// refresh declarado. Entre aceitar e aparecer há a próxima passada do compositor (0 a 1 refresh),
/// e é isso que esta testemunha mede: o ScreenCaptureKit recaptura a janela do próprio app **no
/// dobro da taxa do painel** (na taxa do painel ele entregou de 0 a 2 refreshes atrasado, §20.6),
/// a régua é lida em cada imagem composta, e o `presentationTimeStamp` do SCK — a
/// hora do compositor, um refresh antes da varredura (`medir-vidro-a-vidro.md`) — mais um refresh
/// declarado é o lado da imagem do Δ.
///
/// # O que ela nunca faz
///
/// - **Nunca captura outra coisa que a janela do próprio processo**, com as duas trancas do vidro a
///   vidro (`medir-vidro-a-vidro.md`, "Regra dura de captura"): o `CGWindowID` vem do `NSWindow`
///   que mostra a camada deste processo — não de enumeração nem de argumento —, e a janela achada
///   no SCK tem de ter `owningApplication.processID == getpid()`; senão, nada é capturado. O
///   filtro é `SCContentFilter(desktopIndependentWindow:)`: nenhum `display` em lugar nenhum.
/// - **Nunca pede permissão.** Antes de tocar no SCK, `CGPreflightScreenCaptureAccess()` (que não
///   abre diálogo) tem de dizer que o app já tem Gravação de Tela; se não tiver, a testemunha fica
///   desligada e o diário diz por quê.
/// - **Nenhum pixel sai daqui**: cada imagem vira um inteiro (a régua) e uma hora. Nada é gravado.
/// - Só roda com `--recapturar-janela` **e** `--claquete`, que são de bancada.
final class RecapturaDaJanela: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Onde a régua cai na imagem capturada, como **fração** da janela: o SCK pode entregar a
    /// imagem noutra escala que a pedida, e a fração vale em qualquer uma.
    struct Geometria {
        let janela: CGWindowID
        let larguraPt: Double
        let alturaPt: Double
        let escala: Double
        /// O canto de cima à esquerda do vídeo, em frações da janela (origem em cima à esquerda).
        let x0: Double
        let y0: Double
        /// O lado de um bloco da régua, em frações da largura da janela.
        let lado: Double
    }

    struct Resumo {
        var imagens: UInt64 = 0
        var incompletas: UInt64 = 0
        var semRegua: UInt64 = 0
        var trocasDeRegua: UInt64 = 0
        /// A entrega do SCK (a hora da chamada menos o `pts` trazido à base do app), em µs: a
        /// conferência de que a base do `pts` foi convertida certo. Horas aqui seriam o sono
        /// acumulado desde o boot disfarçado de latência (`tools/vidro-a-vidro`, `Relogio.swift`).
        var entregas: [Int64] = []
    }

    private let geometria: Geometria
    private let fila = DispatchQueue(label: "quall.receptor.recaptura", qos: .userInteractive)
    private let trava = NSLock()
    private var stream: SCStream?
    private var lidas: [(r: Int, hostUs: UInt64)] = []
    private var ultimaLida: Int?
    private var resumo = Resumo()
    private let registrar: (String) -> Void

    private init(geometria: Geometria, registrar: @escaping (String) -> Void) {
        self.geometria = geometria
        self.registrar = registrar
    }

    /// A geometria, lida **na main**: a janela que mostra `camada`, e onde o vídeo cai nela.
    @MainActor
    static func geometria(camada: AVSampleBufferDisplayLayer, largura: Int, altura: Int) -> Geometria? {
        // A vista é o delegado da camada que carrega a `camada` (`VistaDeVideo.Vista`), e a janela
        // é a dela: a primeira tranca é esta — o id vem do nosso `NSWindow`, e não de uma lista.
        guard largura > 0, altura > 0,
              let vista = camada.superlayer?.delegate as? NSView,
              let janela = vista.window else { return nil }
        let quadro = janela.frame
        let naJanela = vista.convert(vista.bounds, to: nil)
        let caixa = camada.frame
        guard quadro.width > 0, quadro.height > 0, caixa.width > 0, caixa.height > 0 else { return nil }
        // `resizeAspect`: o vídeo cabe inteiro na camada, centrado.
        let k = min(caixa.width / CGFloat(largura), caixa.height / CGFloat(altura))
        let (lv, av) = (CGFloat(largura) * k, CGFloat(altura) * k)
        let esquerda = naJanela.minX + caixa.minX + (caixa.width - lv) / 2
        // A camada não é invertida (`VistaDeVideo`): o alto do vídeo é o `maxY` dela.
        let topoDeBaixo = naJanela.minY + caixa.minY + (caixa.height + av) / 2
        let topo = quadro.height - topoDeBaixo
        return Geometria(janela: CGWindowID(janela.windowNumber),
                         larguraPt: Double(quadro.width), alturaPt: Double(quadro.height),
                         escala: Double(janela.backingScaleFactor),
                         x0: Double(esquerda / quadro.width), y0: Double(topo / quadro.height),
                         lado: Double(CGFloat(Marca.lado) * k / quadro.width))
    }

    /// Liga a recaptura, ou devolve `nil` com o motivo no diário. Nunca pede permissão.
    static func iniciar(geometria g: Geometria, hz: Int,
                        registrar: @escaping (String) -> Void) async -> RecapturaDaJanela? {
        guard CGPreflightScreenCaptureAccess() else {
            registrar("recaptura: sem a permissão de Gravação de Tela; nada foi pedido e a janela não é recapturada")
            return nil
        }
        let conteudo: SCShareableContent
        do {
            conteudo = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            registrar("recaptura: o SCK não listou as janelas: \(error.localizedDescription)")
            return nil
        }
        // A segunda tranca: a janela achada tem de ser **deste processo**.
        guard let alvo = conteudo.windows.first(where: { $0.windowID == g.janela }) else {
            registrar("recaptura: a janela \(g.janela) não está na lista do SCK; nada capturado")
            return nil
        }
        guard alvo.owningApplication?.processID == getpid() else {
            registrar("recaptura: !! a janela \(g.janela) não é deste processo; nada capturado")
            return nil
        }
        let filtro = SCContentFilter(desktopIndependentWindow: alvo)
        let config = SCStreamConfiguration()
        config.width = Int((g.larguraPt * g.escala).rounded())
        config.height = Int((g.alturaPt * g.escala).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(hz, 1)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 6
        config.capturesAudio = false
        let r = RecapturaDaJanela(geometria: g, registrar: registrar)
        let stream = SCStream(filter: filtro, configuration: config, delegate: r)
        do {
            try stream.addStreamOutput(r, type: .screen, sampleHandlerQueue: r.fila)
            try await stream.startCapture()
        } catch {
            registrar("recaptura: o SCK não começou: \(error.localizedDescription)")
            return nil
        }
        r.guardar(stream)
        registrar(String(format: "recaptura: a janela %u (deste processo, pid %d), %d×%d px a %d Hz; "
                         + "a régua em (%.4f, %.4f) da janela, bloco de %.4f da largura",
                         g.janela, getpid(), config.width, config.height, hz, g.x0, g.y0, g.lado))
        return r
    }

    /// As leituras novas desde a última chamada: o índice da régua **na primeira imagem composta
    /// em que ele apareceu**, e a hora do compositor dela, no relógio do app (`Medidas.agoraUs`).
    func tirar() -> [(r: Int, hostUs: UInt64)] {
        trava.lock(); defer { trava.unlock() }
        let l = lidas
        lidas.removeAll(keepingCapacity: true)
        return l
    }

    func retrato() -> Resumo {
        trava.lock(); defer { trava.unlock() }
        return resumo
    }

    func parar() async {
        try? await soltar()?.stopCapture()
    }

    private func guardar(_ s: SCStream) {
        trava.lock(); stream = s; trava.unlock()
    }

    private func soltar() -> SCStream? {
        trava.lock(); defer { trava.unlock() }
        let s = stream
        stream = nil
        return s
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer amostra: CMSampleBuffer,
                of tipo: SCStreamOutputType) {
        guard tipo == .screen, amostra.isValid else { return }
        let chamadaUs = Medidas.agoraUs()
        if let anexos = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let bruto = anexos.first?[.status] as? Int,
           let estado = SCFrameStatus(rawValue: bruto), estado != .complete {
            trava.lock(); resumo.incompletas &+= 1; trava.unlock()
            return
        }
        guard let imagem = CMSampleBufferGetImageBuffer(amostra) else { return }
        // O `pts` do SCK é da base **contínua** (`mach_continuous_time`); o relógio do app é a
        // absoluta (`CLOCK_UPTIME_RAW`). A diferença é o sono desde o boot, lida agora.
        let pts = CMSampleBufferGetPresentationTimeStamp(amostra)
        guard pts.isValid else { return }
        let ptsNs = Int64((CMTimeGetSeconds(pts) * 1e9).rounded())
        let sonoNs = Self.continuoMenosAbsolutoNs()
        let hostUs = UInt64(max(0, (ptsNs - sonoNs) / 1000))

        CVPixelBufferLockBaseAddress(imagem, .readOnly)
        let largura = CVPixelBufferGetWidth(imagem)
        let altura = CVPixelBufferGetHeight(imagem)
        var lido: Int?
        if let base = CVPixelBufferGetBaseAddress(imagem) {
            let g = geometria
            lido = Marca.ler(bgra: base, bytesPorLinha: CVPixelBufferGetBytesPerRow(imagem),
                             largura: largura, altura: altura,
                             x0: g.x0 * Double(largura), y0: g.y0 * Double(altura),
                             lado: g.lado * Double(largura))
        }
        CVPixelBufferUnlockBaseAddress(imagem, .readOnly)

        trava.lock()
        resumo.imagens &+= 1
        if resumo.entregas.count < 20_000 { resumo.entregas.append(Int64(chamadaUs) - Int64(hostUs)) }
        if let r = lido {
            if r != ultimaLida {
                resumo.trocasDeRegua &+= 1
                if lidas.count < 100_000 { lidas.append((r, hostUs)) }
            }
            ultimaLida = r
        } else {
            resumo.semRegua &+= 1
        }
        trava.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError erro: Error) {
        registrar("recaptura: o SCK parou: \(erro.localizedDescription)")
    }

    /// `mach_continuous_time − mach_absolute_time`, em ns: o sono acumulado desde o boot.
    private static func continuoMenosAbsolutoNs() -> Int64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let a1 = mach_absolute_time()
        let c = mach_continuous_time()
        let a2 = mach_absolute_time()
        let a = a1 / 2 + a2 / 2
        let d = Int64(bitPattern: c &- a)
        return d * Int64(info.numer) / Int64(max(info.denom, 1))
    }
}
