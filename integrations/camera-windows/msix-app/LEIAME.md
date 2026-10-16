# Receita MSIX da edição Microsoft Store

Esta edição conserva Mirror, recepção de vídeo, câmeras físicas, teleprompter e
gravação. A saída de câmera virtual é opcional e usa o componente externo já
instalado no Windows. O pacote Store não inclui nem instala esse componente;
sua instalação separada pode exigir administrador. Os recursos principais do
Quall Studio funcionam sem ele.

A edição empacotada é compilada com `net,loja,msix`. `msix` inclui `loja` e exclui
o instalador administrativo da câmera, mesmo se o EXE for iniciado fora do pacote.
`loja` também é usada pelo MSI do site e, sozinha, não identifica a edição MSIX.
A API `MFCreateVirtualCamera` permanece disponível para usar o componente externo.
Os caminhos de pasta, licenças, privacidade e suporte usam as associações do
Windows por `Windows.System.Launcher`.

Fontes próprios desta receita: MPL-2.0, conforme LICENSE e LICENSE-SCOPE.md na raiz.
Os insumos originais em brand/windows conservam os direitos reservados e a permissão
de reprodução técnica para compilar, testar e relinkar esta versão documentados
nessa pasta. Isso não identifica versões modificadas como oficiais nem altera
direitos de terceiros. Fixtures são dados de teste, nunca insumos de release.

## Construção e insumos atuais

Use o checkout da revisão correspondente, MSVC x64 e SDK Windows. Registre revisão,
rustc/cargo/MSVC/SDK, locks, configuração e logs efetivos. `rust-toolchain.toml` usa
stable; não se promete igualdade binária entre builds. O cache offline deve conter
as versões dos locks; num checkout novo, obtenha primeiro essas dependências.

Em um prompt x64 das ferramentas nativas, a partir da raiz:

```bat
cd apps\windows
set QUALL_CAMERA_FONTE_DLL=nao
set CARGO_BUILD_JOBS=3
cargo build --release --locked --offline --bin quall-app --features net,loja,msix --target-dir target\release-sem-monitor
```

A feature `msix` impede a incorporação da DLL até quando a variável de ambiente
aponta para um arquivo. Compile somente `quall-app`; não habilite
`tela-estendida-futura` nem inclua instaladores auxiliares no payload.

Para a versão 1.0.29.0, siga a [receita específica](../../../release/windows-store-1.0.29.0/BUILD-AND-PACK.md),
seu manifesto e sua proveniência. Copie apenas o EXE dessa build, os avisos legais
e os assets previstos. Não copie DLLs, certificados, chaves ou logs para o MSIX.
`apps/windows/quall.ico` deve coincidir com `brand/windows/quall.ico`.

Cargo e recursos PE mantêm a versão do produto 1.0.0; a versão do pacote é
`Identity.Version` no manifesto específico. Não substitua esse manifesto pelo
protótipo 1.0.0.0 desta pasta. Verificações PE/CRT e MakeAppx não substituem
instalação, teste funcional e WACK do pacote efetivamente produzido.

## Helper histórico

`preparar_msix.py`, `testar_preparo.py`, `ORIGEM-ARTEFATOS.schema.json` e o manifesto
genérico registram uma receita anterior. O helper ainda exige
`store-without-virtual-camera`, features `net,loja` e ausência de
`MFCreateVirtualCamera`; essas guardas não representam a edição 1.0.29.0.
Não use esse helper para empacotá-la nem enfraqueça suas guardas apenas para fazê-la
passar. A receita específica descreve a montagem direta e as verificações atuais.

## Identidade e limites

Identidade existente Quven.Quall, produto Microsoft Store 9P8G0RLXSJH3; publisher
CN=4EAB9D59-8495-46DE-A09A-46666F12757F. Mínimo Windows 11 build 22000. O manifesto
declara somente runFullTrust, webcam e microphone, sem driver, registro COM ou
capacidade de compatibilidade elevada. `AppxManifest.com-usuario-experimental.xml`
permanece uma fixture histórica, fora do payload.

A edição da Store não depende da instalação de câmera externa para seus recursos
principais. Guardas e schema aprovados não provam runtime, consentimento,
atualização/remoção ou certificação WACK/Store. Assinatura de QA, teste de produto,
revisão da ficha e envio final são etapas separadas.

Antes de distribuir, disponibilize os fontes cobertos correspondentes e suas
modificações em https://github.com/Quevenapp/Quall, mantendo avisos e dependências.
Use a branch de fontes da versão; a main pública geral não representa sozinha o
binário MSIX atual.
