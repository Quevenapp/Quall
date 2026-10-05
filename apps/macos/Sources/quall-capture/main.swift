import Foundation
import QuallCaptureKit

// quall-capture — binário de teste da Frente 3 (captura + encode macOS).
//
// Captura a tela por N segundos via ScreenCaptureKit, codifica em H.264 baseline por
// VideoToolbox (hardware, se disponível) e escreve:
//   - <out>.h264  — elementary stream Annex-B
//   - <out>.json  — sidecar no formato canônico de docs/contrato-sidecar.md; validar com
//                    tools/valida-sidecar.py <out>.json
//
// Uso:
//   quall-capture [--duration N] [--source screen|camera] [--preset screen|camera] [--fps N] [--out prefixo]
//
// Exige permissão TCC de Gravação de Tela concedida ao binário que roda este processo — ver
// apps/macos/README.md se isso falhar.

struct CLIOptions {
    var duration: Double = 10.0
    var source: CaptureSourceKind = .screen
    var preset: CapturePreset = .screen
    var fps: Int32 = 30
    var outPrefix: String = "quall-capture-output"
    // Resolução de saída pedida ao ScreenCaptureKit. Por padrão 1080p — a resolução lógica atual
    // do display da bancada (escala "mais espaço") não bate com nenhum padrão redondo, então sem
    // isso "captura a 1080p" não seria medida de fato.
    var width: Int = 1920
    var height: Int = 1080
}

func parseArguments(_ arguments: [String]) -> CLIOptions {
    var options = CLIOptions()
    var iterator = arguments.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--duration":
            if let value = iterator.next(), let parsed = Double(value) { options.duration = parsed }
        case "--source":
            if let value = iterator.next(), let parsed = CaptureSourceKind(rawValue: value) {
                options.source = parsed
            } else {
                FileHandle.standardError.write("quall-capture: --source precisa ser 'screen' ou 'camera'\n".data(using: .utf8)!)
                exit(64)
            }
        case "--preset":
            if let value = iterator.next(), let parsed = CapturePreset(rawValue: value) {
                options.preset = parsed
            } else {
                FileHandle.standardError.write("quall-capture: --preset precisa ser 'screen' ou 'camera'\n".data(using: .utf8)!)
                exit(64)
            }
        case "--fps":
            if let value = iterator.next(), let parsed = Int32(value) { options.fps = parsed }
        case "--out":
            if let value = iterator.next() { options.outPrefix = value }
        case "--width":
            if let value = iterator.next(), let parsed = Int(value) { options.width = parsed }
        case "--height":
            if let value = iterator.next(), let parsed = Int(value) { options.height = parsed }
        case "--help", "-h":
            print(
                "Uso: quall-capture [--duration N] [--source screen|camera] [--preset screen|camera] "
                    + "[--fps N] [--width N] [--height N] [--out prefixo]"
            )
            exit(0)
        default:
            FileHandle.standardError.write("quall-capture: argumento desconhecido '\(arg)'\n".data(using: .utf8)!)
            exit(64)
        }
    }
    return options
}

func formatBytes(_ bytes: Int) -> String {
    String(format: "%.2f MB", Double(bytes) / 1_000_000)
}

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))
let h264URL = URL(fileURLWithPath: "\(options.outPrefix).h264")
let jsonURL = URL(fileURLWithPath: "\(options.outPrefix).json")

print(
    "quall-capture: source=\(options.source.rawValue) preset=\(options.preset.rawValue) fps=\(options.fps) "
        + "resolução=\(options.width)x\(options.height) duração=\(options.duration)s"
)
print("quall-capture: saída .h264 = \(h264URL.path)")
print("quall-capture: saída .json = \(jsonURL.path)")

let session = CaptureSession(
    source: options.source,
    preset: options.preset,
    targetFps: options.fps,
    outputH264URL: h264URL,
    outputJSONURL: jsonURL,
    requestedWidth: options.width,
    requestedHeight: options.height
)

do {
    let result = try await session.run(durationSeconds: options.duration)

    print("")
    print("=== resultado ===")
    print("resolução: \(result.width)x\(result.height)")
    print("encoder: \(result.encoderName) (\(result.encoderBackend.rawValue))")
    print("color range: \(result.colorRange.rawValue)")
    print("frames: \(result.frameCount) (\(result.idrCount) IDR)")
    print("bytes totais: \(formatBytes(result.totalBytes))")
    print("wall clock: \(String(format: "%.3f", result.wallClockSeconds))s")
    print(
        "cpu do processo: user=\(String(format: "%.3f", result.cpuUserSeconds))s "
            + "sys=\(String(format: "%.3f", result.cpuSystemSeconds))s "
            + "(\(String(format: "%.1f", result.cpuPercentOfOneCore))% de um núcleo)"
    )
    if result.latency.count > 0 {
        print(
            "latência captura->pacote H.264 (submissão ao encoder -> outputHandler), "
                + "n=\(result.latency.count): "
                + "média=\(String(format: "%.0f", result.latency.meanUs))us "
                + "p50=\(result.latency.p50Us)us "
                + "p95=\(result.latency.p95Us)us "
                + "min=\(result.latency.minUs)us "
                + "max=\(result.latency.maxUs)us"
        )
    } else {
        print("latência: nenhuma amostra (nenhum frame foi codificado)")
    }
} catch {
    FileHandle.standardError.write("quall-capture: falhou — \(error)\n".data(using: .utf8)!)
    exit(1)
}
