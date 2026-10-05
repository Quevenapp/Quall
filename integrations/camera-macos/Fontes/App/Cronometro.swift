import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// **A medição do caminho inteiro.** Abre a câmera virtual `Quall` pelo AVFoundation — o mesmo
/// caminho que Zoom, Meet e Chrome usam — e lê, dos pixels que chegaram, o relógio que o emissor
/// desenhou dentro do quadro.
///
/// O número que sai daqui é o tempo entre **o quadro sair do emissor** e **ele estar disponível ao
/// app consumidor**, atravessando: encode em VideoToolbox, pacotização RTP, transporte
/// DTLS-SRTP, remontagem, decode em VideoToolbox, o `CMSimpleQueue` do CoreMediaIO, o processo da
/// extensão e a entrega do AVFoundation.
///
/// **O que ele não cobre**, e isso precisa vir junto do número (regra de `medir-vidro-a-vidro.md`):
/// não há captura de tela no começo nem varredura de painel no fim. Não é latência de vidro a
/// vidro; é do conteúdo existir no emissor até ele estar na mão do consumidor.
enum Cronometro {
    static func correr(segundos: Double, saidaPNG: String?) -> Int32 {
        if Permissao.pedirCamera() != .authorized {
            dizer("sem permissão de Câmera não há medição: a sessão abre e não entrega quadro.")
            return 8
        }

        var tipos: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { tipos.append(contentsOf: [.external, .continuityCamera]) }
        let achados = AVCaptureDevice.DiscoverySession(deviceTypes: tipos, mediaType: .video, position: .unspecified).devices
        let alvo = Identidade.idDoDispositivo.uuidString.lowercased()
        guard let camera = achados.first(where: { $0.uniqueID.lowercased() == alvo })
                ?? achados.first(where: { $0.localizedName == Identidade.nomeDaCamera }) else {
            dizer("a câmera Quall NÃO aparece no AVFoundation")
            return 4
        }
        dizer("consumindo câmera Quall; nome e UID omitidos")

        let sessao = AVCaptureSession()
        guard let entrada = try? AVCaptureDeviceInput(device: camera), sessao.canAddInput(entrada) else {
            dizer("não deu para abrir a entrada")
            return 5
        }
        sessao.addInput(entrada)

        let coletor = Coletor()
        let saida = AVCaptureVideoDataOutput()
        saida.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        saida.alwaysDiscardsLateVideoFrames = true
        saida.setSampleBufferDelegate(coletor, queue: DispatchQueue(label: "cronometro", qos: .userInteractive))
        guard sessao.canAddOutput(saida) else { dizer("não deu para adicionar a saída"); return 5 }
        sessao.addOutput(saida)

        sessao.startRunning()
        Thread.sleep(forTimeInterval: segundos)
        sessao.stopRunning()

        return coletor.relatar(saidaPNG: saidaPNG)
    }

    private final class Coletor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let trava = NSLock()
        private var atrasos: [UInt64] = []
        private var intervalos: [UInt64] = []
        private var vistos = Set<UInt64>()
        private var quadros: UInt64 = 0
        private var semFaixa: UInt64 = 0
        private var repetidos: UInt64 = 0
        private var ultimoValor: UInt64?
        private var ultimaChegadaUs: UInt64 = 0
        private var ultimo: CVPixelBuffer?
        private var dimensao = ""

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            let chegadaUs = Medidas.agoraUs()
            guard let imagem = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let valor = Faixa.ler(de: imagem)

            trava.lock()
            quadros += 1
            ultimo = imagem
            if dimensao.isEmpty {
                dimensao = "\(CVPixelBufferGetWidth(imagem))x\(CVPixelBufferGetHeight(imagem))"
            }
            if ultimaChegadaUs > 0, intervalos.count < 100_000 {
                intervalos.append(chegadaUs - ultimaChegadaUs)
            }
            ultimaChegadaUs = chegadaUs
            if let valor {
                // Diferença em milissegundos no módulo da faixa. Latência aqui é de dezenas de ms
                // e o módulo é de 17,5 min: não há ambiguidade de volta.
                let agoraMs = chegadaUs / 1_000
                let atraso = (agoraMs &+ Faixa.modulo &- valor) % Faixa.modulo
                if atrasos.count < 100_000 { atrasos.append(atraso) }
                if valor == ultimoValor { repetidos += 1 }
                ultimoValor = valor
                vistos.insert(valor)
            } else {
                semFaixa += 1
            }
            trava.unlock()
        }

        func relatar(saidaPNG: String?) -> Int32 {
            trava.lock(); defer { trava.unlock() }
            dizer("quadros entregues pelo AVFoundation=\(quadros) dimensão=\(dimensao)")
            dizer("com faixa de relógio=\(atrasos.count) sem faixa=\(semFaixa) (placa da extensão ou vídeo sem instrumento)")
            dizer("valores distintos do emissor que acenderam no consumidor=\(vistos.count); quadros repetidos=\(repetidos)")
            if !intervalos.isEmpty {
                let o = intervalos.sorted()
                dizer("intervalo entre quadros: média=\(intervalos.reduce(0, +) / UInt64(intervalos.count))us p50=\(o[o.count / 2])us p95=\(o[min(o.count - 1, Int(Double(o.count) * 0.95))])us max=\(o.last!)us")
            }
            guard !atrasos.isEmpty else {
                dizer("NENHUM quadro trouxe a faixa: não há latência de ponta a ponta para reportar")
                if let saidaPNG, let ultimo { _ = gravarPNG(ultimo, em: saidaPNG) }
                return 6
            }
            let o = atrasos.sorted()
            let media = atrasos.reduce(0, +) / UInt64(atrasos.count)
            dizer("LATÊNCIA emissor→consumidor: n=\(o.count) min=\(o.first!)ms média=\(media)ms p50=\(o[o.count / 2])ms p95=\(o[min(o.count - 1, Int(Double(o.count) * 0.95))])ms max=\(o.last!)ms")
            if let saidaPNG, let ultimo, gravarPNG(ultimo, em: saidaPNG) {
                dizer("PNG do último quadro gravado; caminho omitido")
            }
            return 0
        }

        private func gravarPNG(_ buffer: CVPixelBuffer, em caminho: String) -> Bool {
            let contexto = CIContext()
            let imagem = CIImage(cvPixelBuffer: buffer)
            guard let cg = contexto.createCGImage(imagem, from: imagem.extent) else { return false }
            guard let destino = CGImageDestinationCreateWithURL(URL(fileURLWithPath: caminho) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(destino, cg, nil)
            return CGImageDestinationFinalize(destino)
        }
    }
}
