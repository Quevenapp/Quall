# Quall Studio — app e extensão iOS

Produto iOS/iPadOS 15+ com os alvos `Quall` e `Difusao`. O primeiro apresenta a interface,
recebe vídeo e captura câmera; o segundo compartilha tela usando ReplayKit.
App e extensão linkam separadamente o núcleo estático e compartilham dados pelo App Group.

Da raiz, com Xcode/SDK, XcodeGen e alvo Rust iOS instalados:

```sh
IPHONEOS_DEPLOYMENT_TARGET=15.0 CARGO_PROFILE_RELEASE_LTO=false \
  cargo build --locked -p quall-ffi --release --target aarch64-apple-ios
(cd apps/ios/Quall && xcodegen generate && \
  xcodebuild -project Quall.xcodeproj -scheme Quall -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath DD \
    IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO build)
```

`project.yml` usa `target/aarch64-apple-ios/release/libquall.a` da raiz. Não misture
biblioteca macOS/simulador nem substitua ligação estática por uma dylib do host.
O build unsigned é uma conferência de compilação; execução requer configuração própria de
assinatura, capacidades e App Group nos dois alvos. Não habilite provisionamento automático
ou instale sem revisar o efeito dessas operações no seu ambiente.

Compartilhar tela exige interação ReplayKit. Permissões de câmera, microfone e rede local,
segundo plano e interrupções devem ser testados fisicamente. O piso iOS 15 não afirma prova
em iOS 15.0 exato. Monitor/Tela estendida, sudoVda, crop e video wall estão fora da primeira release.
Veja [uso](../../../docs/uso.md) e [limites](../../../docs/limites.md).
