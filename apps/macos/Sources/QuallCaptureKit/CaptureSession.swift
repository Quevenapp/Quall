import Foundation
import CoreMedia
import CoreVideo

/// Estatísticas de latência interna: quanto tempo passa entre submeter um frame capturado ao
/// encoder e o pacote H.264 codificado estar pronto na mão. Não faz parte do contrato do sidecar
/// (esse é fixo — número, timestamp, bytes, IDR); é medido à parte e reportado no fim da execução.
public struct LatencyStats {
    public let samples: [Int64]

    public var count: Int { samples.count }

    private func percentile(_ p: Double) -> Int64 {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.down))))
        return sorted[index]
    }

    public var meanUs: Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.reduce(0, +)) / Double(samples.count)
    }
    public var p50Us: Int64 { percentile(0.50) }
    public var p95Us: Int64 { percentile(0.95) }
    public var maxUs: Int64 { samples.max() ?? 0 }
    public var minUs: Int64 { samples.min() ?? 0 }
}

public struct CaptureRunResult {
    public let width: Int
    public let height: Int
    public let targetFps: Int
    public let preset: CapturePreset
    public let encoderBackend: EncoderBackend
    public let encoderName: String
    public let colorRange: ColorRange
    public let frameCount: Int
    public let idrCount: Int
    public let totalBytes: Int
    public let wallClockSeconds: Double
    public let cpuUserSeconds: Double
    public let cpuSystemSeconds: Double
    /// CPU consumida pelo processo (getrusage) como percentual de um núcleo, ao longo do wall
    /// clock medido. Ver `ResourceUsage` para o porquê disso ser evidência de hardware vs. software.
    public let cpuPercentOfOneCore: Double
    public let latency: LatencyStats
}

public enum CaptureSessionError: Error, CustomStringConvertible {
    case outputFileCreationFailed(URL)

    public var description: String {
        switch self {
        case .outputFileCreationFailed(let url):
            return "Não consegui criar o arquivo de saída em \(url.path)."
        }
    }
}

/// Orquestra captura de tela (ScreenCaptureKit) -> encode (VideoToolbox H.264) -> escrita em
/// disco (Annex-B + sidecar JSON), medindo latência de captura+encode e CPU do processo.
public final class CaptureSession {
    private let preset: CapturePreset
    private let targetFps: Int32
    private let outputH264URL: URL
    private let outputJSONURL: URL
    private let requestedWidth: Int?
    private let requestedHeight: Int?

    private let capturer: FrameSource
    private var encoder: H264Encoder?

    // Todo estado mutável abaixo só é tocado dentro de `sessionQueue` — os callbacks do
    // ScreenCaptureKit e do VideoToolbox podem vir de filas diferentes.
    private let sessionQueue = DispatchQueue(label: "quall.capture.session")
    private var fileHandle: FileHandle?
    private var frameNumber = 0
    private var frameRecords: [FrameRecord] = []
    private var latencySamplesUs: [Int64] = []
    private var pendingSubmitNs: [Int64: UInt64] = [:]
    private var width = 0
    private var height = 0

    public init(
        source: CaptureSourceKind = .screen,
        preset: CapturePreset,
        targetFps: Int32,
        outputH264URL: URL,
        outputJSONURL: URL,
        requestedWidth: Int? = nil,
        requestedHeight: Int? = nil
    ) {
        self.preset = preset
        self.targetFps = targetFps
        self.outputH264URL = outputH264URL
        self.outputJSONURL = outputJSONURL
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight

        switch source {
        case .screen: self.capturer = ScreenCapturer()
        case .camera: self.capturer = CameraCapturer()
        }

        capturer.onFrame = { [weak self] sampleBuffer in
            self?.sessionQueue.async { self?.handleCapturedFrame(sampleBuffer) }
        }
        capturer.onStop = { error in
            if let error {
                FileHandle.standardError.write("quall-capture: SCStream parou com erro: código=\((error as NSError).code)\n".data(using: .utf8)!)
            }
        }
    }

    public func run(durationSeconds: Double) async throws -> CaptureRunResult {
        let target = try await capturer.discoverTarget(width: requestedWidth, height: requestedHeight)
        width = target.width
        height = target.height

        let encoder = try H264Encoder(width: Int32(target.width), height: Int32(target.height), fps: targetFps, preset: preset)
        self.encoder = encoder

        guard FileManager.default.createFile(atPath: outputH264URL.path, contents: nil) else {
            throw CaptureSessionError.outputFileCreationFailed(outputH264URL)
        }
        fileHandle = try FileHandle(forWritingTo: outputH264URL)

        let rusageStart = ResourceUsage.current()
        let wallStartNs = MonotonicClock.nowNanoseconds()

        try await capturer.beginCapture(fps: targetFps, sampleHandlerQueue: sessionQueue)

        try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))

        await capturer.stop()
        encoder.finish()

        let wallEndNs = MonotonicClock.nowNanoseconds()
        let rusageEnd = ResourceUsage.current()

        // Sincroniza com a fila de sessão para garantir que todo callback pendente já foi
        // processado antes de ler o estado acumulado.
        try sessionQueue.sync {
            try fileHandle?.close()
        }

        let header = CaptureSidecarHeader(
            width: width,
            height: height,
            targetFps: Int(targetFps),
            preset: preset.rawValue,
            captureApi: capturer.captureAPIName,
            encoder: encoder.encoderName,
            encoderIsHardware: encoder.backend == .hardware,
            targetBitrateBps: encoder.targetBitrateBps,
            gopFrames: encoder.gopFrames,
            colorRange: capturer.colorRange.rawValue,
            videoFile: outputH264URL.lastPathComponent
        )
        let sidecar = CaptureSidecar(header: header, frames: frameRecords)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try jsonEncoder.encode(sidecar)
        try jsonData.write(to: outputJSONURL)

        let wallSeconds = Double(wallEndNs - wallStartNs) / 1_000_000_000
        let cpuUser = rusageEnd.userSeconds - rusageStart.userSeconds
        let cpuSystem = rusageEnd.systemSeconds - rusageStart.systemSeconds
        let cpuPercent = wallSeconds > 0 ? ((cpuUser + cpuSystem) / wallSeconds) * 100 : 0

        return CaptureRunResult(
            width: width,
            height: height,
            targetFps: Int(targetFps),
            preset: preset,
            encoderBackend: encoder.backend,
            encoderName: encoder.encoderName,
            colorRange: capturer.colorRange,
            frameCount: frameRecords.count,
            idrCount: frameRecords.filter { $0.idr }.count,
            totalBytes: frameRecords.reduce(0) { $0 + $1.bytes },
            wallClockSeconds: wallSeconds,
            cpuUserSeconds: cpuUser,
            cpuSystemSeconds: cpuSystem,
            cpuPercentOfOneCore: cpuPercent,
            latency: LatencyStats(samples: latencySamplesUs)
        )
    }

    // MARK: - Callbacks (rodam em sessionQueue)

    private func handleCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let encoder, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsUs = MonotonicClock.microseconds(from: pts)
        let submitNs = MonotonicClock.nowNanoseconds()
        pendingSubmitNs[ptsUs] = submitNs

        encoder.encode(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: targetFps)
        ) { [weak self] data, outputPts, isKeyframe in
            let outputPtsUs = MonotonicClock.microseconds(from: outputPts)
            self?.sessionQueue.async {
                self?.handleEncodedFrame(data: data, ptsUs: outputPtsUs, isKeyframe: isKeyframe)
            }
        }
    }

    private func handleEncodedFrame(data: Data, ptsUs: Int64, isKeyframe: Bool) {
        fileHandle?.write(data)

        // encode_latency_us é campo obrigatório do contrato (docs/contrato-sidecar.md), não só
        // uma média reportada no fim — cada quadro carrega a própria latência de captura+encode.
        let latencyUs: Int64
        if let submitNs = pendingSubmitNs.removeValue(forKey: ptsUs) {
            let outputNs = MonotonicClock.nowNanoseconds()
            latencyUs = Int64((outputNs - submitNs) / 1000)
            latencySamplesUs.append(latencyUs)
        } else {
            // Não deveria acontecer (todo frame submetido tem uma entrada correspondente), mas
            // não inventamos um número — 0 é visivelmente um valor sentinela, e avisamos.
            latencyUs = 0
            FileHandle.standardError.write(
                "quall-capture: aviso — frame em pts=\(ptsUs)us saiu do encoder sem correspondência de submissão; encode_latency_us gravado como 0\n"
                    .data(using: .utf8)!
            )
        }

        let record = FrameRecord(number: frameNumber, timestampUs: ptsUs, bytes: data.count, idr: isKeyframe, encodeLatencyUs: latencyUs)
        frameRecords.append(record)
        frameNumber += 1
    }
}
