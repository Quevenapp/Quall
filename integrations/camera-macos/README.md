# Câmera virtual macOS

Integração macOS 13+ com app hospedeiro `QuallCamera` e extensão CoreMediaIO `QuallCameraExtensao`.
Expõe vídeo recebido a consumidores compatíveis. É distinta de Monitor/Tela estendida e sudoVda.

O projeto é gerado de `project.yml` com XcodeGen. A receita atual aponta o núcleo estático
arm64 em `target/aarch64-apple-darwin/release/libquall.a`; mantenha arquitetura e header compatíveis.
Da raiz, para compilar sem instalar ou ativar:

```sh
MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_PROFILE_RELEASE_LTO=false \
  cargo build --locked -p quall-ffi --release --target aarch64-apple-darwin
(cd integrations/camera-macos && xcodegen generate && \
  xcodebuild -project QuallCamera.xcodeproj -scheme QuallCamera -configuration Release \
    -derivedDataPath DD CODE_SIGNING_ALLOWED=NO build)
```

Execução exige assinatura/capacidades próprias e ativação pelo sistema. `construir.sh` também
instala/ativa componentes; não o use como simples teste de build. O build unsigned acima não
prova que a câmera pode ser instalada ou consumida. Intel requer uma receita correspondente,
sem reutilizar biblioteca arm64. Consulte [limites](../../docs/limites.md) e
[licenças](../../docs/distribuicao/licencas.md).
