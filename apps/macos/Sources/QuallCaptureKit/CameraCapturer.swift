import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

public enum CameraCaptureError: Error, CustomStringConvertible {
    case noCamera
    case permissionDenied
    case permissionNotDetermined
    case configurationFailed(String)

    public var description: String {
        switch self {
        case .noCamera:
            return "Nenhuma câmera encontrada neste aparelho."
        case .permissionDenied:
            return
                "Permissão de Câmera (AVCaptureDevice / TCC) negada para este binário. Abra "
                + "Ajustes do Sistema > Privacidade e Segurança > Câmera, habilite o binário que "
                + "está rodando este processo e rode de novo."
        case .permissionNotDetermined:
            return
                "Permissão de Câmera ainda não decidida (notDetermined) para este binário. O "
                + "AVFoundation pediria o diálogo do sistema (Permitir/Não Permitir) — em uma "
                + "sessão automatizada sem um usuário para clicar, esse diálogo não pode ser "
                + "respondido, então esta captura para aqui em vez de ficar pendurada esperando. "
                + "É preciso rodar este binário uma vez interativamente (fora de automação) para "
                + "que alguém clique 'Permitir' no diálogo do sistema."
        case .configurationFailed(let reason):
            return "Falha ao configurar AVCaptureSession: \(reason)"
        }
    }
}

/// Captura de câmera via AVCaptureSession — escopo M4 ("se sobrar fôlego"), implementado como
/// segunda fonte de frames além da tela. Exige permissão TCC de Câmera concedida pelo usuário; ao
/// contrário da tela, o AVFoundation pode *pedir* essa permissão via `requestAccess`, mas ainda
/// assim depende de um clique humano no diálogo do sistema — não há como automatizar esse clique
/// aqui, então tratamos `notDetermined` como bloqueio explícito em vez de ficar pendurados
/// esperando indefinidamente por uma resposta que nunca chega numa sessão sem usuário.
final class CameraCapturer: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// **Nunca chamado aqui.** O áudio de sistema do macOS vem do ScreenCaptureKit; uma
    /// `AVCaptureSession` de câmera não tem de onde tirá-lo. O **microfone** da câmera (R5 fase 4,
    /// `docs/audio.md` §8.2) não passa por este capturador: ele é do `DonoDaCamera`, numa sessão só
    /// dele, aberta pelo botão, e vai à track `MICROPHONE` por fora da transmissão.
    var onAudio: ((CMSampleBuffer) -> Void)?
    let capturaAudioDeSistema = false
    var onStop: ((Error?) -> Void)?

    private let session = AVCaptureSession()
    private var output: AVCaptureVideoDataOutput?
    private var resolvedWidth = 0
    private var resolvedHeight = 0

    /// `uniqueID` da câmera escolhida no seletor. `nil` mantém o comportamento do binário de
    /// bancada (a câmera padrão do sistema). O app de produto sempre passa um id: um Mac com
    /// câmera interna, Continuity Camera do iPhone e uma webcam USB tem três, e "a padrão" não é
    /// escolha da pessoa.
    private let uniqueIDDesejado: String?

    /// Quando `true`, `discoverTarget` chama `AVCaptureDevice.requestAccess` diante de
    /// `notDetermined` em vez de falhar. **Só o app de produto passa `true`** — ver o comentário
    /// de tipo abaixo e `docs/regras-de-frente.md`, "Ler o estado de uma permissão não é pedi-la".
    private let podePedirPermissao: Bool

    init(uniqueID: String? = nil, podePedirPermissao: Bool = false) {
        self.uniqueIDDesejado = uniqueID
        self.podePedirPermissao = podePedirPermissao
        super.init()
    }

    let captureAPIName = "AVCaptureSession"
    // Mesma escolha e mesmo raciocínio do ScreenCapturer: faixa limitada, não full-range — ver o
    // videoSettings do AVCaptureVideoDataOutput abaixo e a nota em ScreenCapturer.swift.
    let colorRange: ColorRange = .limited

    /// Não tenta forçar `width`/`height` — usa o formato ativo (padrão) do dispositivo de
    /// câmera escolhido e reporta a resolução real. Forçar uma resolução arbitrária numa câmera
    /// via AVCaptureSession pede escolha de `AVCaptureDevice.Format` e não é essencial para
    /// provar que o caminho de câmera funciona.
    func discoverTarget(width: Int?, height: Int?) async throws -> (width: Int, height: Int) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            // Consultar não é pedir: sem `requestAccess` a linha do Quall nunca aparece no painel
            // de Privacidade e a `AVCaptureSession` abriria entregando **zero quadro**, sem erro
            // em lugar nenhum. O binário de bancada continua falhando aqui de propósito (não há
            // humano para clicar no diálogo numa sessão automatizada); o app pede.
            guard podePedirPermissao else {
                throw CameraCaptureError.permissionNotDetermined
            }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw CameraCaptureError.permissionDenied
            }
        case .denied, .restricted:
            throw CameraCaptureError.permissionDenied
        @unknown default:
            throw CameraCaptureError.permissionDenied
        }

        let device: AVCaptureDevice
        if let desejado = uniqueIDDesejado {
            // Mesma regra do monitor: câmera que sumiu (iPhone que saiu de perto, USB
            // desconectada) não vira "a padrão" em silêncio.
            guard let achado = AVCaptureDevice(uniqueID: desejado) else {
                throw CameraCaptureError.noCamera
            }
            device = achado
        } else {
            guard
                let padrao = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                    ?? AVCaptureDevice.default(for: .video)
            else {
                throw CameraCaptureError.noCamera
            }
            device = padrao
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        resolvedWidth = Int(dimensions.width)
        resolvedHeight = Int(dimensions.height)

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CameraCaptureError.configurationFailed("canAddInput retornou false para \(device.localizedName)")
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            output.alwaysDiscardsLateVideoFrames = true
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CameraCaptureError.configurationFailed("canAddOutput retornou false")
            }
            session.addOutput(output)
            session.commitConfiguration()
            self.output = output
        } catch let error as CameraCaptureError {
            throw error
        } catch {
            throw CameraCaptureError.configurationFailed("\(error)")
        }

        return (resolvedWidth, resolvedHeight)
    }

    func beginCapture(fps: Int32, sampleHandlerQueue: DispatchQueue) async throws {
        guard let output else {
            throw CameraCaptureError.configurationFailed("beginCapture chamado antes de discoverTarget")
        }
        output.setSampleBufferDelegate(self, queue: sampleHandlerQueue)
        session.startRunning()
    }

    func stop() async {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        onFrame?(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Descartado (ex.: encoder não acompanhando) — não é um erro fatal, só um frame a menos.
    }
}
