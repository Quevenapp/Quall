# Compilar por plataforma

Execute a partir da raiz do repositório. As receitas descrevem o fonte; não foram executadas
nesta preparação documental. Build não instala integrações, concede permissões ou assina distribuição.

## Núcleo

Requer Rust compatível com os manifests (piso declarado 1.85), compilador C/C++, CMake e
ferramentas das dependências nativas. Preserve os lockfiles de cada workspace.

```sh
cargo build --locked -p quall-ffi --release
cargo test --locked --workspace
```

O workspace raiz não compila as interfaces e integrações. Use `--offline` apenas com cache
abastecido; não mude o lockfile para contornar cache incompleto. Mantenha o header correspondente.

## macOS

Requer macOS 13+, Xcode/SDK, Swift e dependências do núcleo. SwiftPM linka `target/release/libquall.a`.

```sh
MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_PROFILE_RELEASE_LTO=false \
  cargo build --locked -p quall-ffi --release
(cd apps/macos && swift build -c release --product quall-app)
```

Preserve LTO desativado neste núcleo Apple e não reutilize objetos de outro alvo/perfil.
Empacotamento e assinatura são separados; veja [macOS](../apps/macos/README.md).

## iOS/iPadOS

Requer macOS, Xcode/SDK iOS, XcodeGen e alvo Rust `aarch64-apple-ios`; piso iOS 15.
O projeto é gerado de `project.yml`; app e extensão linkam o núcleo do alvo iOS.

```sh
IPHONEOS_DEPLOYMENT_TARGET=15.0 CARGO_PROFILE_RELEASE_LTO=false \
  cargo build --locked -p quall-ffi --release --target aarch64-apple-ios
(cd apps/ios/Quall && xcodegen generate && \
  xcodebuild -project Quall.xcodeproj -scheme Quall -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath DD \
    IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO build)
```

Unsigned não é instalável como distribuição. Para executar, configure suas identidades/perfis,
App Group e extensão. Simulador exige alvo Rust e caminho de biblioteca próprios; a biblioteca
de aparelho não serve por substituição. Veja [iOS](../apps/ios/Quall/README.md).

## Android

O projeto declara JDK 17, AGP 8.7.0, SDK 36, NDK 27.2.12479018 e CMake 3.22.1.
Use Gradle compatível e alvos Rust armv7/arm64. Configure `ANDROID_HOME` e `ANDROID_NDK_HOME`.
O minSDK do app/JNI é 28; o ambiente Rust usa API 30 por padrão. Preserve ambos e confira imports.

```sh
bash apps/android/tools/compila-nucleo.sh
gradle -p apps/android assembleDebug
```

O helper prepara `jniLibs` nas duas ABIs. Esta receita usa Gradle externo; `--offline` exige cache
abastecido. Release/AAB, assinatura, alinhamento de 16 KiB e USB/DVD têm conferências próprias.
Veja [Android](../apps/android/README.md).

## Windows

Execute em Windows 11 x64 com Rust MSVC, ferramentas C/C++ e Windows SDK.
App e câmera têm workspaces/lockfiles próprios.

```powershell
cargo build --manifest-path apps/windows/Cargo.toml --locked --release --features net --bin quall-app
cargo build --manifest-path integrations/camera-windows/Cargo.toml --locked --release
```

A variante Store usa `net,loja`; não habilite `tela-estendida-futura` na primeira release.
MSI, recursos, DLLs e assinatura exigem conferência nativa, ainda pendente para este snapshot.
Veja [Windows](../apps/windows/README.md).

## Portão e integrações

`tools/portao.sh --lista` enumera superfícies. O portão público executa sequencialmente,
com cache offline e limite de dois jobs; cache incompleto deve falhar explicitamente.
Windows usa `tools/portao.ps1` localmente e nunca SSH. Ele não é um build universal em qualquer host.
Consulte [câmera macOS](../integrations/camera-macos/README.md),
[câmera Windows](../integrations/camera-windows/README.md), [OBS](../plugins/obs/README.md)
e [limites](limites.md).
