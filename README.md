# Quall Studio — fontes Windows MSIX 1.0.29.0

Este snapshot reúne os fontes próprios cobertos e os insumos locais da edição Windows
MSIX **1.0.29.0**. É uma publicação **de código-fonte**, não uma release do aplicativo,
um instalador, uma submissão à Microsoft ou uma aprovação de certificação.

**English:** This is the corresponding Windows source snapshot for MSIX 1.0.29.0.
It contains source code and build inputs, not an application release or a Store approval.
The optional virtual-camera output uses a separately installed component. This Store package does not embed or install that component.

## Escopo

- Aplicativo em `apps/windows`: implementação, manifests, ícone, Cargo.toml e Cargo.lock.
- Workspaces locais: os cinco crates da raiz e a integração Windows de câmera usada como
  dependência Rust. A inclusão dos fontes dessa integração **não** significa inclusão
  de sua DLL no pacote.
- Cópia modificada de `vendor/datachannel-sys`, subdependências presentes e Opus vendorizado,
  preservando patches, fontes e avisos de terceiros.
- Recursos de marca Windows, gerador de ícones e textos/avisos de licenciamento.
  Fontes locais de terceiros e modificações estão nas árvores `vendor` e `crates` correspondentes.
- [Receita e limitações da build](release/windows-store-1.0.29.0/BUILD-AND-PACK.md),
  manifesto exato do pacote e proveniência sem credenciais.

A correção desta versão separa `msix` de `loja`, exclui o instalador administrativo
do pacote e usa `Windows.System.Launcher` para pastas, arquivos e páginas.
Os fontes alterados e documentos Markdown/JSON usam UTF-8 com LF. O manifesto
conserva os bytes exatos do payload, conforme `.gitattributes`. O inventário
`release/windows-store-1.0.29.0/SOURCE-INVENTORY.json` considera os bytes dos blobs
Git publicados, preservando as regras de `.gitattributes` dos materiais de terceiros.
Conversões de fim de linha no checkout podem alterar hashes; o arquivo do commit
conserva os blobs. A normalização não implica identidade binária entre builds.

## Build da edição

A receita usa `cargo build --release --locked --offline --bin quall-app
--features net,loja,msix`, com `QUALL_CAMERA_FONTE_DLL=nao`, `CARGO_BUILD_JOBS=3` e
target separado `apps/windows/target/release-sem-monitor`.

Build, 14 testes dirigidos, check de compatibilidade MSI, PE/CRT e MakeAppx
concluíram com sucesso. Abertura do app, associações e recusa de instalação
administrativa foram conferidas. O WACK completo retornou **WARNING**:
23 PASS, zero FAIL e um WARNING não opcional de DPI; não é PASS geral.
Consulte o registro específico da versão antes de usar estes fontes. Não há promessa
de reprodutibilidade binária bit a bit nem de build offline sem cache do Cargo.

## O que não está incluído

- Instaladores, executáveis, DLLs compiladas, pacotes MSIX, material de assinatura ou credenciais.
- Dados de usuário, capturas, registros privados de bancada e metadados Git da máquina de origem.
- Apps Android/Apple, plugin OBS e ferramentas de bancada não necessárias a essa build Windows.
- Payload de driver SudoVDA/tela estendida, recurso não habilitado nessa edição.
- Arquivos históricos de `docs/distribuicao/licencas/fontes`, redundantes ou de outras
  plataformas. Os fontes modificados efetivamente usados estão nas árvores locais acima;
  dependências de registro permanecem identificadas e travadas nos arquivos Cargo.lock.
  Links desses avisos históricos para materiais fora do escopo não são uma receita desta build.
- Dois certificados temporários de testes UWP de libdatachannel, fora do caminho de build
  do aplicativo (`test/uwp/benchmark/Windows_TemporaryKey.pfx` e
  `test/uwp/tests/Windows_TemporaryKey.pfx`). Os respectivos exemplos UWP não são um alvo
  completo de distribuição deste snapshot.

`preparar_msix.py` e sua documentação histórica conservam guardas de uma edição antiga
sem API de câmera virtual. Não descrevem integralmente a receita da 1.0.29.0.
Use a receita específica desta versão; uma falha dessas guardas não equivale,
por si só, a uma decisão de certificação da Microsoft.

## Licenciamento

O código próprio coberto conserva a MPL-2.0; terceiros, marcas e recursos gráficos
mantêm seus próprios termos. Consulte `LICENSE`, `LICENSE-SCOPE.md`, `NOTICE.txt`,
`THIRD_PARTY_NOTICES.txt` e os avisos de cada dependência.

`LICENSE-SCOPE.md` e os avisos acompanham os mesmos bytes do pacote compilado e contêm
anotações históricas sobre uma publicação então pendente. O escopo e o estado deste
snapshot são descritos aqui; as anotações históricas não são atestado de certificação
nem declaração de nova licença sobre código ou recursos de terceiros.

## Validação local e limites

O pacote 1.0.29.0 foi instalado e teve sua abertura funcional conferida.
O teste WACK de Executáveis bloqueados passou. O aviso DPIAwarenessValidation
permanece: falha ao processar o binário e reconhecimento de DPI não identificado.
O [resumo WACK](release/windows-store-1.0.29.0/WACK-SUMMARY.json) preserva
`OverallResult=WARNING`, `PartialRun=FALSE` e `Passed=false`. Uma sonda separada
encontrou processo/janela PerMonitorV2 e DPI 120; isso não anula o aviso do WACK.
O histórico 1.0.28.0 permanece na pasta de sua versão;
seus resultados não são atribuídos ao pacote novo.

Não se alega teste em máquina limpa. A saída opcional de câmera virtual depende de
um componente separado, cuja instalação pode exigir administrador. Os recursos
principais funcionam sem ele. O pacote Store não embute essa DLL nem drivers de
tela estendida; disponibilizar fontes não certifica o aplicativo ou a elegibilidade
de seus recursos na Store.
