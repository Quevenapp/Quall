import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Abre a câmera virtual **pelo AVFoundation** — o mesmo caminho que Zoom, Meet e Chrome usam —
/// e grava um PNG.
///
/// Não substitui a testemunha externa (o `ffprobe` enumera e lê pelo mesmo AVFoundation, e é
/// programa de terceiro). Serve para o que o `ffprobe` não faz: **produzir a imagem**, para que o
/// contador desenhado na placa possa ser lido por olho humano e dois quadros distintos provem
/// movimento. "A câmera aparece na lista" não prova que ela entrega quadro.
enum Testemunha {
    static func correr(saida: String, segundos: Double) -> Int32 {
        // Pedir, não só olhar. Ler o estado nunca fez o sistema perguntar nada — ver `Permissao`.
        if Permissao.pedirCamera() != .authorized {
            dizer("sem permissão de Câmera a sessão abre e entrega zero quadro, sem erro nenhum.")
            return 8
        }

        // `.external` e `.continuityCamera` só existem no macOS 14+, e é como um dispositivo de
        // extensão CMIO se apresenta lá. O alvo de implantação é 13.0, então a lista é montada em
        // tempo de execução — cair para `.builtInWideAngleCamera` num macOS 13 encontra o
        // dispositivo do mesmo jeito, que é como ele aparecia antes.
        var tipos: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { tipos.append(contentsOf: [.external, .continuityCamera]) }
        let achados = AVCaptureDevice.DiscoverySession(deviceTypes: tipos, mediaType: .video, position: .unspecified).devices
        dizer("o AVFoundation enxerga \(achados.count) câmera(s); nomes e UID omitidos")

        let alvo = Identidade.idDoDispositivo.uuidString.lowercased()
        guard let camera = achados.first(where: { $0.uniqueID.lowercased() == alvo })
                ?? achados.first(where: { $0.localizedName == Identidade.nomeDaCamera }) else {
            dizer("a câmera Quall NÃO aparece no AVFoundation")
            return 4
        }
        dizer("câmera Quall encontrada; nome e UID omitidos")

        let sessao = AVCaptureSession()
        guard let entrada = try? AVCaptureDeviceInput(device: camera), sessao.canAddInput(entrada) else {
            dizer("não deu para abrir a entrada")
            return 5
        }
        sessao.addInput(entrada)

        let coletor = Coletor()
        let saidaDeVideo = AVCaptureVideoDataOutput()
        saidaDeVideo.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        saidaDeVideo.alwaysDiscardsLateVideoFrames = true
        saidaDeVideo.setSampleBufferDelegate(coletor, queue: DispatchQueue(label: "testemunha"))
        guard sessao.canAddOutput(saidaDeVideo) else { dizer("não deu para adicionar a saída"); return 5 }
        sessao.addOutput(saidaDeVideo)

        sessao.startRunning()
        Thread.sleep(forTimeInterval: segundos)
        sessao.stopRunning()

        dizer("quadros recebidos pelo AVFoundation: \(coletor.quantos)")
        guard let ultimo = coletor.ultimo else {
            dizer("nenhum quadro chegou")
            return 6
        }
        dizer("dimensão=\(CVPixelBufferGetWidth(ultimo))x\(CVPixelBufferGetHeight(ultimo)) formato=\(fourcc(CVPixelBufferGetPixelFormatType(ultimo)))")
        dizer("primárias=\(atributo(ultimo, kCVImageBufferColorPrimariesKey)) matriz=\(atributo(ultimo, kCVImageBufferYCbCrMatrixKey))")

        guard gravarPNG(ultimo, em: saida) else {
            dizer("não deu para gravar o PNG")
            return 7
        }
        dizer("PNG gravado; caminho omitido")
        return 0
    }

    private final class Coletor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private(set) var quantos = 0
        private(set) var ultimo: CVPixelBuffer?

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            quantos += 1
            if let b = CMSampleBufferGetImageBuffer(sampleBuffer) { ultimo = b }
        }
    }

    private static func gravarPNG(_ buffer: CVPixelBuffer, em caminho: String) -> Bool {
        let contexto = CIContext()
        let imagem = CIImage(cvPixelBuffer: buffer)
        guard let cg = contexto.createCGImage(imagem, from: imagem.extent) else { return false }
        let url = URL(fileURLWithPath: caminho)
        guard let destino = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destino, cg, nil)
        return CGImageDestinationFinalize(destino)
    }

    private static func atributo(_ b: CVPixelBuffer, _ chave: CFString) -> String {
        guard let v = CVBufferCopyAttachment(b, chave, nil) else { return "ausente" }
        return String(describing: v)
    }

    private static func fourcc(_ v: OSType) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }

}
