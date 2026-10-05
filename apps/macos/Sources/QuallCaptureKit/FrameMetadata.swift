import Foundation

/// Formato do sidecar `.json` — contrato canônico fixado em `docs/contrato-sidecar.md` depois de
/// a primeira rodada do M1 ter produzido dois sidecars incompatíveis (macOS e Windows escolheram
/// nomes de chave diferentes). **Não solte campo novo nem renomeie sem atualizar aquele
/// documento e `tools/valida-sidecar.py`** — são a fonte de verdade, não este comentário.
///
/// ```json
/// {
///   "header": {
///     "width": 1920,
///     "height": 1080,
///     "target_fps": 30,
///     "preset": "screen",
///     "capture_api": "ScreenCaptureKit",
///     "encoder": "Apple H.264",
///     "encoder_is_hardware": true,
///     "target_bitrate_bps": 4000000,
///     "gop_frames": 30,
///     "color_range": "limited",
///     "video_file": "captura.h264"
///   },
///   "frames": [
///     { "number": 0, "timestamp_us": 123456789012, "bytes": 5321, "idr": true, "encode_latency_us": 13991 },
///     { "number": 1, "timestamp_us": 123456822345, "bytes": 812,  "idr": false, "encode_latency_us": 12845 }
///   ]
/// }
/// ```
///
/// `timestamp_us` é o timestamp de captura do frame (relógio monotônico — vem do
/// `presentationTimeStamp` que o ScreenCaptureKit/AVFoundation atribui com base no host time /
/// mach continuous time), em microssegundos. `encoder_is_hardware` é separado de `encoder` de
/// propósito: `encoder` é o nome do encoder que de fato rodou (via
/// `kVTCompressionPropertyKey_EncoderID` + `VTCopyVideoEncoderList`), `encoder_is_hardware`
/// confirma independentemente via `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`
/// — os dois consultados na sessão já criada, não presumidos do que foi pedido.
public struct CaptureSidecarHeader: Codable {
    public let width: Int
    public let height: Int
    public let targetFps: Int
    public let preset: String
    public let captureApi: String
    public let encoder: String
    public let encoderIsHardware: Bool
    public let targetBitrateBps: Int
    public let gopFrames: Int
    public let colorRange: String
    public let videoFile: String

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case targetFps = "target_fps"
        case preset
        case captureApi = "capture_api"
        case encoder
        case encoderIsHardware = "encoder_is_hardware"
        case targetBitrateBps = "target_bitrate_bps"
        case gopFrames = "gop_frames"
        case colorRange = "color_range"
        case videoFile = "video_file"
    }

    public init(
        width: Int,
        height: Int,
        targetFps: Int,
        preset: String,
        captureApi: String,
        encoder: String,
        encoderIsHardware: Bool,
        targetBitrateBps: Int,
        gopFrames: Int,
        colorRange: String,
        videoFile: String
    ) {
        self.width = width
        self.height = height
        self.targetFps = targetFps
        self.preset = preset
        self.captureApi = captureApi
        self.encoder = encoder
        self.encoderIsHardware = encoderIsHardware
        self.targetBitrateBps = targetBitrateBps
        self.gopFrames = gopFrames
        self.colorRange = colorRange
        self.videoFile = videoFile
    }
}

public struct FrameRecord: Codable {
    public let number: Int
    public let timestampUs: Int64
    public let bytes: Int
    public let idr: Bool
    public let encodeLatencyUs: Int64

    enum CodingKeys: String, CodingKey {
        case number
        case timestampUs = "timestamp_us"
        case bytes
        case idr
        case encodeLatencyUs = "encode_latency_us"
    }

    public init(number: Int, timestampUs: Int64, bytes: Int, idr: Bool, encodeLatencyUs: Int64) {
        self.number = number
        self.timestampUs = timestampUs
        self.bytes = bytes
        self.idr = idr
        self.encodeLatencyUs = encodeLatencyUs
    }
}

public struct CaptureSidecar: Codable {
    public let header: CaptureSidecarHeader
    public let frames: [FrameRecord]

    public init(header: CaptureSidecarHeader, frames: [FrameRecord]) {
        self.header = header
        self.frames = frames
    }
}
