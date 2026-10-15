# Build e empacotamento — Windows Store 1.0.28.0

Este documento registra a receita usada na origem e separa-a do helper histórico
`integrations/camera-windows/msix-app/preparar_msix.py`. Não é uma afirmação de
compilação reproduzível bit a bit nem de aprovação da Microsoft.

## Ambiente e compilação

A origem usou Windows x64, Rust/Cargo, as ferramentas C++ x64 do Visual Studio 2022
Build Tools e Windows SDK 10.0.26100.0. A sonda sobre a cópia exportada encontrou
`rustc 1.98.0`, host `x86_64-pc-windows-msvc`, LLVM 22.1.8.
Isso registra a ferramenta observada, não prova uma reconstrução bit a bit. O arquivo
original `rust-toolchain.toml` usa `stable` móvel e também pede targets Apple/Android;
não fixa essa versão do compilador. O grafo de dependências inclui código nativo:
prepare também CMake, libclang/bindgen e as ferramentas exigidas pelas versões travadas
de OpenSSL/datachannel. Este snapshot não redistribui o SDK, toolchain ou o cache do Cargo.

Em um prompt x64 das ferramentas nativas, a partir da raiz deste snapshot:

```bat
cd apps\windows
set QUALL_CAMERA_FONTE_DLL=nao
set CARGO_BUILD_JOBS=3
cargo build --release --locked --offline --bin quall-app --features net,loja --target-dir target\release-sem-monitor
```

`--offline` só funciona com as dependências de registro já em cache. Em uma máquina nova,
obtenha primeiro as dependências das versões de Cargo.lock por um meio confiável
(por exemplo, `cargo fetch --locked` nesse workspace); só depois execute a receita offline.
A origem chamou `vcvars64.bat` do Visual Studio antes de executar Cargo.

O comando compila apenas `quall-app`. Não habilite `tela-estendida-futura`, não compile
os alvos avulsos de instalação e não remova `QUALL_CAMERA_FONTE_DLL=nao` esperando obter
a mesma edição. A API MFCreateVirtualCamera permanece no app; o componente COM/DLL externo
não está embutido. Os workspaces locais e patches vendorizados são fornecidos.

## Payload exato da versão

O manifesto em `AppxManifest.xml` ao lado deste documento é o manifesto final do MSIX,
não o protótipo versionado como 1.0.0.0 no helper histórico. Preserve a identidade:

- Name: `Quven.Quall`
- Version: `1.0.28.0`
- Arquitetura: `x64`
- PFN esperado: `Quven.Quall_4bed071cmhnq6`

Monte uma pasta nova `payload` contendo apenas:

```text
AppxManifest.xml
quall-app.exe
LICENSE
LICENSE-SCOPE.md
NOTICE.txt
THIRD_PARTY_NOTICES.txt
Assets/Square44x44Logo.png
Assets/Square150x150Logo.png
Assets/StoreLogo.png
```

Copie o EXE de `apps/windows/target/release-sem-monitor/release`, os quatro textos legais
da raiz e os três PNGs de `brand/windows`. Não substitua os assets por fixtures de
prototipagem, não copie a DLL da câmera e não inclua material de assinatura QA.

A receita efetivamente usada leu o manifesto anterior 1.0.11.0 e alterou apenas
`Identity.Version` para 1.0.28.0. O resultado exato está incluído aqui. O inventário de
payload em `SOURCE-PROVENANCE.json` permite conferir seus bytes e os recursos/textos legais.

## Verificações e MakeAppx

A execução original fez verificações PE/ícone e CRT antes do empacotamento:

```text
python -X utf8 integrations/camera-windows/msix-app/verificar_pe.py --app --expected-icon brand/windows/quall.ico <payload>/quall-app.exe
python integrations/camera-windows/msix-app/verificar_crt.py --payload <pasta-apenas-com-o-exe> --framework <pasta-do-VCLibs-x64-instalado> --edition store --saida <saida>/CRT.json
```

Substitua os parâmetros entre `<...>` pelos caminhos locais. A origem verificou contra
`Microsoft.VCLibs.140.00.UWPDesktop` x64 14.0.33728.0; o manifesto declara o framework.
As duas verificações retornaram código 0 na execução registrada. Não tratam toda a cadeia
de dependências transitivas nem substituem teste em máquina limpa.

No SDK 10.0.26100.0, a execução de empacotamento foi:

```text
makeappx.exe pack /d <payload> /p <saida>/QuallStudio-1.0.28.0-x64.msix /h SHA256 /o
```

MakeAppx retornou código 0. O pacote destinado à Store ficou **sem assinatura local**.
A cópia de QA foi assinada e instalada separadamente; não é o pacote enviado ao rascunho.
Nenhum certificado, chave, segredo ou script de assinatura de QA integra estes fontes.

`SOURCE-PROVENANCE.json` guarda hashes do EXE, MSIX e script de empacotamento efetivamente
executado. O script original tinha caminhos específicos da máquina e não é apresentado
como um novo programa portátil aqui. A sequência acima e o manifesto final registram os
insumos, comandos e diferenças relevantes sem expor esses caminhos de usuário.

## Guardas históricas e resultados

O helper genérico `preparar_msix.py` ainda exige a política antiga
`store-sem-camera-virtual-v3` e rejeita o import MFCreateVirtualCamera. A 1.0.28.0 usa
`release-sem-monitor-v2`, sem DLL/driver embutido e com a API de câmera virtual presente.
Não foi alterado código funcional para fazer uma guarda histórica passar. Esta divergência
é registrada, não escondida e não interpretada como uma decisão da Microsoft.

WACK: execução completa, OVERALL_RESULT=WARNING; 22 PASS, um FAIL opcional de executáveis
bloqueados (CreateProcessW/ShellExecuteW/ShellExecuteExW/cmd) e um WARNING DPI não opcional;
nenhum FAIL obrigatório identificado. Teste de vídeo em rede realizado; máquina limpa não
testada. O computador de teste já possuía a fonte externa de câmera virtual.

## Limite da validação dos fontes

O layout exportado passou em `cargo metadata --no-deps --locked --offline` para os
features `net,loja`; essa checagem não compilou novamente o aplicativo. O cache deve
estar provisionado antes de usar `--offline` numa outra máquina.

Não se promete `cargo test --workspace` completo: certos testes OBS em `quall-ffi`
incluem `plugins/obs/src/som.c`, componente deliberadamente fora deste snapshot Windows
Store. Essa dependência de teste não participa da compilação release indicada acima.

Nenhuma aprovação de certificação, publicação de app ou teste em máquina limpa é alegada.
