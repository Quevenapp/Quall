// swift-tools-version:5.9
import PackageDescription

// Arnês de latência vidro a vidro — método "laço fechado de janela, um relógio só".
// Pacote independente de propósito: `apps/macos/Package.swift` não declara `products` e usa
// `.unsafeFlags` num alvo, o que o torna impossível de consumir como dependência SwiftPM.
// Nada aqui toca `apps/**`, `crates/**` ou `plugins/**`.
let package = Package(
    name: "VidroAVidro",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "VidroComum", path: "Fontes/Comum"),
        .executableTarget(
            name: "vidro-emissor",
            dependencies: ["VidroComum"],
            path: "Fontes/vidro-emissor"
        ),
        .executableTarget(
            name: "vidro-receptor",
            dependencies: ["VidroComum"],
            path: "Fontes/vidro-receptor"
        ),
    ]
)
