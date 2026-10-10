# Reprodução e proveniência — Android Quall Studio 1.0.0

Esta receita acompanha o código público baseado em `3172b188` e as correções Android da publicação 1.0.0. Os insumos de marca aprovados estão incluídos em `tools/icones/overlays/quall-studio-1.0.0/`, com hashes, destinos e direitos explícitos. Não é necessário material privado omitido para compilar o app. Código próprio: MPL-2.0; marca: aviso separado em `tools/icones/DIREITOS-DA-MARCA.txt`. FFmpeg dinâmico: LGPL-2.1-or-later, sem GPL/nonfree; avisos e oferta do fonte acompanham o app.

## Ambiente utilizado

- JDK 21.0.10; Gradle 8.10.2; Android Gradle Plugin 8.7.0; Kotlin 2.0.21.
- Android SDK plataforma 36, build-tools 36.0.0; NDK 27.2.12479018; CMake 3.22.1.
- Rust 1.98.0 (88d9e12ae, 2026-08-18). O `rust-toolchain.toml` da base usa stable; para repetir esta versão, fixar `RUSTUP_TOOLCHAIN=1.98.0` e instalar os targets abaixo.
- Cargo.lock, catálogo Gradle e fontes de dependências vendorizadas são os da base pública. CameraX 1.4.2 e runtime libc++ oficial do NDK, sem remendos adicionais.
- FFmpeg 9.0.1 oficial: SHA256 do tarball `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`, fixado em `compila-ffmpeg-dv.sh`.

## Compilar a partir do fonte

Configurar `ANDROID_HOME`, `ANDROID_NDK_HOME` e `JAVA_HOME` para o ambiente local. `apps/android/local.properties`, quando utilizado, é configuração local do SDK. Gradle 8.10.2 deve estar no PATH; a receita não distribui uma instalação local do SDK nem chaves de assinatura.

Na raiz do repositório:

```sh
rustup toolchain install 1.98.0
rustup target add --toolchain 1.98.0 aarch64-linux-android armv7-linux-androideabi
export RUSTUP_TOOLCHAIN=1.98.0
python3 tools/icones/aplicar-marca-oficial.py
apps/android/tools/compila-nucleo.sh
apps/android/tools/compila-ffmpeg-dv.sh
cd apps/android
gradle --max-workers=2 --console=plain -PquallVersionName=1.0.0 -PquallVersionCode=1 assembleRelease bundleRelease assembleDebug testDebugUnitTest
```

Os scripts geram e instalam as bibliotecas nativas antes do Gradle; as pastas `jniLibs/` e `jniLibsDv/` não são entradas binárias obrigatórias do Git. `compila-nucleo.sh` recompila ambas ABIs e verifica os símbolos JNI. FFmpeg é compilado para arm64/API30 e oferecido somente nos fluxos compatíveis; o aplicativo principal é minSdk28, targetSdk36, armv7/arm64. O fonte FFmpeg é oficial e não modificado; a configuração e os flags estão integralmente no script. Os flags max/common-page-size 16384 constam dos scripts e do CMake.

A marca usada nos três vetores do launcher e no PNG Play 512 é o overlay exato preservado, não uma reconstrução aproximada. O código `marca.py` também permite gerar variantes; versões diferentes de Pillow/zlib podem alterar a codificação do PNG. O overlay não restaura paths Material ou muda os controles geométricos `ic_q_*` da base pública.

## Proveniência da saída de publicação

A comparação de 4544 arquivos tracked da base, incluindo 3219 arquivos core/vendor/locks e 419 Android, confirmou que core, dependências vendorizadas e locks usados no build permanecem idênticos ao código público. As alterações Android estão presentes neste repositório; não existe fonte de dependência remendado à parte. SDK/NDK/CMake/Gradle oficiais, o tarball FFmpeg e as bibliotecas geradas são os insumos externos descritos acima.

Nesta preparação, arm64 core, FFmpeg e shim JNI/qualldv foram reconstruídos. O core armv7 foi reaproveitado do build de preparação de 5 de outubro de 2026. A comparação adicional com o fonte daquele build identificou diferenças em nove arquivos Rust limitadas a comentários e testes: o trecho de produção antes dos módulos de teste, ignorando linhas exclusivamente de comentário, é igual. Essa conferência é uma heurística de fonte, não uma prova por parser nem uma afirmação de build bit-identical. Os hashes do binário armv7, log histórico e demais bibliotecas constam de `proveniencia-android-1.0.0.json`. A receita acima reconstrói ambas ABIs sem exigir aquele cache.

Depois deste AAB, a árvore pública canônica incorporou correções Apple em `vendor/datachannel-sys/build.rs` e `vendor/datachannel-sys/libdatachannel/src/impl/tls.cpp`. A conferência de 3637 arquivos Android/core/vendor contra essa árvore encontrou somente essas duas diferenças: o script seleciona uma receita OpenSSL para targets Apple e corrige o bindgen do simulador; o C++ acrescenta opções sob `__APPLE__`. No Android, os ramos de OpenSSL e bindgen preservam o comportamento anterior. Essa inspeção não identifica mudança de comportamento Android, mas não se afirma que esses dois fontes posteriores sejam byte a byte os insumos deste AAB. O JSON registra a distinção.

O AAB final foi assinado com a chave de upload existente Quall. Foram comparados 1040 arquivos do payload do AAB assinado e não assinado: permanecem idênticos; somente metadados de assinatura JAR foram adicionados. Os hashes e certificado público constam do JSON. A chave e sua senha não fazem parte do código aberto. A reprodução funcional não garante um arquivo final bit-identical, por metadata de toolchain, caminhos/tempo e assinatura.

## Validação e limites

O build final passou lintVital e 516 testes JVM em 67 suites. Bundletool 1.18.3 validou o AAB assinado e confirmou PAGE_ALIGNMENT_16K. Todas as 14 bibliotecas nativas, incluindo nove arm64, passaram alinhamento ELF LOAD 16KiB; não foram encontradas colisões reais entre RELRO arredondado e seções graváveis fora dele. As bibliotecas oficiais mantêm seus flags de proteção. A orientação oficial exige também teste em runtime16KiB; a inspeção estrutural isolada não o substitui. Os Samsung físicos usados nesta preparação utilizam páginas 4KiB, API30/API36. Runtime16KiB e API28 físico ainda não foram verificados.

Referências: [guia Android para páginas 16KiB](https://developer.android.com/guide/practices/page-sizes), [loader Bionic e arredondamento RELRO](https://android.googlesource.com/platform/bionic/+/refs/heads/main/linker/linker_phdr.cpp), [fonte oficial FFmpeg](https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz).

Não publicar caches, SDK, builds temporários, chaves, backups de aparelhos ou evidências com dados pessoais. A geração técnica do pacote não significa envio, aprovação ou publicação na loja.
