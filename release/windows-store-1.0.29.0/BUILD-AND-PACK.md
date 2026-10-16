# Build e empacotamento — Windows Store 1.0.29.0

Build, testes dirigidos, verificações PE/CRT, empacotamento e abertura funcional
foram conferidos. O WACK completo retornou **WARNING**, com 23 PASS, zero FAIL e
um WARNING não opcional de DPI. Este registro não declara PASS geral, aprovação
Microsoft ou reprodutibilidade binária bit a bit.

## Mudança em relação à 1.0.28.0

O feature `msix` inclui `loja`, impede a incorporação da DLL da câmera e remove o
instalador administrativo dessa edição, inclusive fora da identidade do pacote.
O MSI separado pode continuar usando `loja` sem `msix`. A saída opcional de câmera
virtual continua dependendo de um componente instalado separadamente; o pacote
não instala esse componente nem drivers. Os recursos principais funcionam sem ele.

A abertura de pastas, arquivos de licenças e páginas usa `Windows.System.Launcher`
em uma thread WinRT MTA. As chamadas diretas do app a `explorer.exe`,
`ShellExecuteW` e ao auxiliar elevado foram retiradas desses caminhos. A ausência
dos imports administrativos verificados e o resultado WACK foram medidos no EXE
final e estão registrados abaixo.

## Ambiente e compilação

Use Windows x64, Rust/Cargo, as ferramentas C++ x64 do Visual Studio e Windows SDK.
`rust-toolchain.toml` usa `stable` móvel e também pede targets Apple/Android; não
fixa o compilador. As dependências nativas exigem CMake, libclang/bindgen e as
ferramentas necessárias às versões travadas de OpenSSL/datachannel.

Em um prompt x64 das ferramentas nativas, a partir da raiz deste snapshot:

```bat
cd apps\windows
set QUALL_CAMERA_FONTE_DLL=nao
set CARGO_BUILD_JOBS=3
cargo build --release --locked --offline --bin quall-app --features net,loja,msix --target-dir target\release-sem-monitor
```

A build original concluiu com código 0 em 3m04s, com avisos do compilador.
Seu comando e os hashes dos scripts efetivamente usados estão em
`SOURCE-PROVENANCE.json`; os scripts locais não são publicados por conterem
caminhos da máquina. A receita acima registra os passos pertinentes.
`--offline` exige o cache das dependências; num ambiente novo, obtenha primeiro as
versões de Cargo.lock, por exemplo com `cargo fetch --locked` nesse workspace.
Não habilite `tela-estendida-futura` nem compile os alvos avulsos de instalação.
Os workspaces locais e patches vendorizados fazem parte destes fontes.

## Payload da versão

O manifesto final `AppxManifest.xml` ao lado deste documento foi conferido
com o payload gerado. Sua única alteração em relação à 1.0.28.0 é a versão.
Preserve `Quven.Quall`, versão `1.0.29.0`, arquitetura `x64` e
PFN esperado `Quven.Quall_4bed071cmhnq6`.

Monte uma pasta nova `payload` contendo somente:

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

Copie o EXE de `apps/windows/target/release-sem-monitor/release`, os quatro textos
legais da raiz e os três PNGs de `brand/windows`. Não use fixtures de prototipagem,
não copie a DLL da câmera e não inclua material de assinatura QA.
Os hashes em `SOURCE-PROVENANCE.json` correspondem ao payload efetivamente medido.

## Verificações e MakeAppx

```text
python -X utf8 integrations/camera-windows/msix-app/verificar_pe.py --app --expected-icon brand/windows/quall.ico <payload>/quall-app.exe
python integrations/camera-windows/msix-app/verificar_crt.py --payload <pasta-apenas-com-o-exe> --framework <pasta-do-VCLibs-x64-instalado> --edition store --saida <saida>/CRT.json
makeappx.exe pack /d <payload> /p <saida>/QuallStudio-1.0.29.0-x64.msix /h SHA256 /o
```

Substitua os parâmetros entre `<...>` pelos caminhos locais. O manifesto declara
`Microsoft.VCLibs.140.00.UWPDesktop` x64. A verificação CRT não cobre toda a cadeia
transitiva nem substitui máquina limpa. O pacote para envio fica sem assinatura
local; a cópia de QA pode ser assinada e instalada separadamente. Certificados,
chaves e scripts locais de assinatura não integram esta publicação.

O helper genérico `preparar_msix.py` conserva a receita histórica
`store-sem-camera-virtual-v3`, incompatível com esta edição. Use a montagem direta
acima e o manifesto específico. Não interprete uma guarda histórica como resultado
de certificação.

## Resultados e limites

Build, PE/CRT e MakeAppx concluíram com código 0. A verificação estática do EXE
não encontrou os imports administrativos bloqueados nem a string `cmd.exe` em
ASCII/UTF-16; encontrou o marcador MSIX e `MFCreateVirtualCamera`. O MSIX sem
assinatura local tem 7.230.141 bytes; seus hashes estão na proveniência.

Os 14 testes dirigidos passaram: um teste da recusa administrativa MSIX e 13
testes das regras de instalação da câmera. `cargo check --release --locked
--offline --bin quall-app --features net,loja` também concluiu com código 0,
verificando a compatibilidade de compilação do MSI. A cópia QA 1.0.29.0 foi
instalada e seu EXE instalado corresponde ao hash do payload.

Na cópia instalada, passaram a primeira abertura, abertura da pasta de registros,
dos avisos de terceiros, da URL de privacidade e da página externa da câmera.
O app não ofereceu instalação administrativa da câmera e encerrou por Alt+F4.
As entradas CLI de instalar/desinstalar foram recusadas com o código esperado 2.

O WACK completo (`PartialRun=FALSE`) retornou **WARNING**: 23 PASS, zero FAIL
e um WARNING não opcional. O teste 88, Executáveis bloqueados, passou. O teste
92, DPIAwarenessValidation, informou falha ao processar o binário e ausência de
reconhecimento de DPI; esse aviso permanece sem resolução. `Passed=false` é
preservado. O estado de falha do helper local decorre de sua exigência de PASS
geral e não representa um resultado FAIL entre os 24 testes.

`WACK-SUMMARY.json` contém o resumo sanitizado, versão do WACK, hash do relatório
original e hash do EXE. Uma sonda separada e somente de leitura encontrou
processo e janela PerMonitorV2, awareness 2 e DPI de janela 120, sem alterar o
pacote ou as configurações. Esse resultado **não anula o WARNING do WACK**.
Os logs, caminhos da máquina, certificados e binários
não são publicados. O FAIL opcional histórico da 1.0.28.0 não se repetiu nesta
execução. Não foi feito teste em máquina limpa nem se alega aprovação ou envio
à Store.

Os fontes alterados e os novos documentos Markdown/JSON usam UTF-8 com LF.
O AppxManifest.xml conserva os bytes exatos do payload (CRLF), com `-text` em
`.gitattributes`. O
inventário considera os bytes canônicos dos blobs Git que serão publicados,
preservando as regras de `.gitattributes` dos materiais de terceiros. Essa
normalização de texto não declara identidade binária entre builds. Clientes Git
podem converter finais de linha no checkout; o arquivo do commit conserva os blobs.
O inventário corresponde ao snapshot público Windows, não à árvore privada completa.

Não se promete `cargo test --workspace` completo: certos testes OBS em `quall-ffi`
incluem `plugins/obs/src/som.c`, fora deste recorte Windows Store. Essa dependência
de teste não participa da compilação release indicada acima.
