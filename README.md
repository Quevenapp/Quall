# Quall Studio — fontes Windows MSIX 1.0.28.0

Este snapshot reúne os fontes próprios cobertos e os insumos locais da edição Windows
MSIX **1.0.28.0**. É uma publicação **de código-fonte**, não uma release do aplicativo,
um instalador, uma submissão à Microsoft ou uma aprovação de certificação.

**English:** This is the corresponding Windows source snapshot for MSIX 1.0.28.0.
It contains source code and build inputs, not an application release or a Store approval.
The virtual-camera component is not embedded in this Store package.

## Escopo

- Aplicativo em `apps/windows`: implementação, manifests, ícone, Cargo.toml e Cargo.lock.
- Workspaces locais: os cinco crates da raiz e a integração Windows de câmera usada como
  dependência Rust. A inclusão dos fontes dessa integração **não** significa inclusão
  de sua DLL no pacote.
- Cópia modificada de `vendor/datachannel-sys`, subdependências presentes e Opus vendorizado,
  preservando patches, fontes e avisos de terceiros.
- Recursos de marca Windows, gerador de ícones e textos/avisos de licenciamento.
  Fontes locais de terceiros e modificações estão nas árvores `vendor` e `crates` correspondentes.
- [Receita e limitações da build](release/windows-store-1.0.28.0/BUILD-AND-PACK.md),
  manifesto exato do pacote e proveniência sem credenciais.

Os arquivos de implementação foram copiados sem alterações funcionais. O inventário
`release/windows-store-1.0.28.0/SOURCE-INVENTORY.json` registra hashes SHA-256 para
conferir os arquivos deste snapshot, exceto o próprio inventário. Alterações de fim
  de linha feitas pelo cliente Git podem afetar hashes; o arquivo ZIP do commit conserva
os bytes dos blobs publicados.

## Build efetivamente usada

A compilação original executou `cargo build --release --locked --offline --bin quall-app
--features net,loja`, com `QUALL_CAMERA_FONTE_DLL=nao`, `CARGO_BUILD_JOBS=3` e target separado
`apps/windows/target/release-sem-monitor`. O processo terminou com código 0.

O `.d` produzido pela compilação registra 161 entradas locais únicas: os arquivos de
origem estão presentes; `bindings.rs` em OUT_DIR é gerado pelo build de datachannel-sys.
Não há promessa de reprodutibilidade **binária** bit a bit nem de build offline em uma
máquina sem o cache das dependências do Cargo.

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
sem API de câmera virtual. Não descrevem integralmente a receita da 1.0.28.0.
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

A build foi instalada em sessão interativa e recebeu vídeo real de um iPhone na rede.
O WACK completo retornou **WARNING**, não PASS limpo: 22 testes PASS, um FAIL opcional de
executáveis bloqueados e um WARNING de análise DPI, sem FAIL obrigatório identificado.
Uma sonda separada encontrou processo/janela PerMonitorV2; isso não elimina o aviso do WACK.

Não foi executado teste em máquina limpa. O computador de teste já tinha um componente
externo de câmera virtual. O pacote Store não embute essa DLL nem drivers de tela estendida;
a API de câmera virtual continua presente no executável. Disponibilizar fontes não
certifica o aplicativo, seus recursos opcionais ou sua elegibilidade na Store.
