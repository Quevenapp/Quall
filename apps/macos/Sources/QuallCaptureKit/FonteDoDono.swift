import CoreMedia
import Foundation

/// **A câmera já aberta, vista pela `TransmissaoAoVivo` como uma fonte qualquer** (R5 fase 4, G1).
///
/// A transmissão continua pedindo quadros a um `FrameSource`, e não sabe de dono nenhum: com esta
/// fonte, `discoverTarget` devolve o tamanho que o dono entrega (sem abrir nada), `beginCapture`
/// **assina** o vídeo do dono, e `stop` **desassina**. A câmera não é tocada em nenhum dos três: é o
/// que deixa um receptor entrar, cair e voltar sem a prévia piscar e sem a gravação notar.
///
/// Sem som: o microfone vai por fora da transmissão, direto do dono ao núcleo (`docs/teleprompter-
/// com-camera.md` §8.9, a releitura adversarial: a `TransmissaoAoVivo` só sabe o som do SCK).
final class FonteDoDono: FrameSource {
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    let capturaAudioDeSistema = false
    var onStop: ((Error?) -> Void)?
    let captureAPIName = "AVCaptureSession (dono da câmera)"
    let colorRange: ColorRange = .limited

    private let dono: DonoDaCamera
    private let nome: String
    private let trava = NSLock()
    private var ficha: FichaDoDono?

    init(dono: DonoDaCamera, nome: String) {
        self.dono = dono
        self.nome = nome
    }

    /// O tamanho do último quadro do dono. A câmera tem de estar entregando: uma transmissão que
    /// pendura num dono parado não teria com que montar o encoder, e esperar aqui prenderia a sessão.
    /// Espera até 2 s pelo primeiro quadro (o receptor pode parear no instante em que a tela abre).
    func discoverTarget(width: Int?, height: Int?) async throws -> (width: Int, height: Int) {
        let limite = Date().addingTimeInterval(2)
        while Date() < limite {
            let d = dono.dimensaoRecebida
            if d.largura > 0, d.altura > 0 { return (d.largura, d.altura) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CameraCaptureError.configurationFailed("a câmera do dono não entregou imagem em 2 s")
    }

    func beginCapture(fps: Int32, sampleHandlerQueue: DispatchQueue) async throws {
        // A câmera perdida derruba a transmissão (a revisão de 25/09: sem isto o receptor ficava
        // com a imagem parada e a sessão de pé).
        let f = dono.assinar(nome: nome, video: { [weak self] amostra, _ in
            self?.onFrame?(amostra)
        }, perdeu: { [weak self] motivo in
            self?.onStop?(CameraCaptureError.configurationFailed(motivo))
        })
        trava.withLock { ficha = f }
    }

    func stop() async {
        let f: FichaDoDono? = trava.withLock {
            defer { ficha = nil }
            return ficha
        }
        if let f { dono.desassinar(f) }
    }
}
