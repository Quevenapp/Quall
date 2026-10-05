# Quall Studio para Android

App Kotlin/JNI para Android 9 / API 28+, com armv7 e arm64. Usa MediaProjection,
CameraX/Camera2, MediaCodec e o núcleo Rust. Gravação própria ocorre no emissor.
USB e DVD são exceções que exigem Android 11+, arm64, acessórios e formatos compatíveis.
Monitor/Tela estendida, sudoVda, crop e video wall ficam fora da primeira release.

Requisitos do projeto: JDK 17, Gradle compatível com AGP 8.7.0, SDK 36,
NDK 27.2.12479018 e CMake 3.22.1. Configure `ANDROID_HOME` e `ANDROID_NDK_HOME`.
Da raiz do repositório:

```sh
bash apps/android/tools/compila-nucleo.sh
gradle -p apps/android assembleDebug
```

O helper compila/prepara `jniLibs` para `armeabi-v7a` e `arm64-v8a`. O ambiente Rust usa
API 30 por padrão; app/JNI têm piso 28. Conferir imports e closure das bibliotecas é necessário
para manter esse piso. O projeto usa Gradle externo; builds offline exigem cache abastecido.

Não troque `.so` ou ABIs silenciosamente. Release/AAB e assinatura exigem configuração própria,
avisos e fontes correspondentes dos terceiros. Confira ELF/ZIP e execução em páginas de 16 KiB,
além de permissões de captura, áudio, câmera, armazenamento e acessórios.
O snapshot não inclui APK/AAB aprovado ou certificado de distribuição.
Veja [uso](../../docs/uso.md), [compilação](../../docs/compilar.md),
[limites](../../docs/limites.md) e [licenças](../../docs/distribuicao/licencas.md).
