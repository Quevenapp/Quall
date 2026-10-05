# Quall Studio para macOS

App SwiftPM para macOS 13+, com captura ScreenCaptureKit, câmera/áudio nativos, recepção,
teleprompter e gravação local. A câmera virtual é uma [integração separada](../../integrations/camera-macos/README.md).
Monitor/Tela estendida, sudoVda, crop e video wall ficam fora da primeira release.

Da raiz do repositório, com Xcode e toolchains configurados:

```sh
MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_PROFILE_RELEASE_LTO=false \
  cargo build --locked -p quall-ffi --release
(cd apps/macos && swift build -c release --product quall-app)
```

SwiftPM linka `target/release/libquall.a`; mantenha biblioteca e header em sincronia.
O executável fica em `.build/release/quall-app` dentro desta pasta. Um executável SwiftPM
não substitui o pacote `.app` com recursos, permissões, entitlements e assinatura.

Tela, câmera e microfone exigem autorizações do macOS. Empacotamento, sandbox, assinatura,
notarização e distribuição Store têm conferências próprias. Não use scripts de instalação
para apenas verificar um build. Este snapshot não certifica execução nativa ou arquiteturas não testadas.
Veja [compilação](../../docs/compilar.md), [uso](../../docs/uso.md) e [limites](../../docs/limites.md).
