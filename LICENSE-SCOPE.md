# Licenciamento do Quall Studio

O código próprio autorizado dos apps, núcleo e demais frentes do Quall Studio, exceto o plugin
OBS separado, é disponibilizado sob **Mozilla Public License 2.0 (SPDX: MPL-2.0)**, conforme o
texto integral em [LICENSE](LICENSE). Este aviso aplica a MPL aos fontes assim identificados
abaixo; o plugin tem o escopo GPL indicado na tabela. Não se aplica o
aviso de incompatibilidade com licenças secundárias do Exhibit B. Sua presença como modelo
dentro do texto integral da MPL não é uma aplicação desse aviso ao código do projeto.

**Veneri & Quellis Ltda.** é a responsável confirmada pela distribuição. Esta identificação não
declara cessão de direitos de todos os autores, nem substitui os titulares e avisos existentes.
Somente direitos sobre código próprio cuja concessão tenha sido autorizada são concedidos.

## Escopo próprio

| Fontes e materiais próprios autorizados | Licença |
|---|---|
| `crates/quall-core`, `quall-ffi`, `quall-rtc`, `quall-opus` e `quall-probe`, excluídos seus terceiros | MPL-2.0 |
| Código próprio dos apps em `apps/android`, `apps/ios`, `apps/macos` e `apps/windows` | MPL-2.0 |
| Código próprio das câmeras e outras integrações em `integrations` | MPL-2.0 |
| Ferramentas, fixtures sintéticas, configuração de build e documentação próprios incluídos | MPL-2.0 |
| Novos placeholders geométricos descritos em `tools/icones/README.md`, seu gerador e saídas correspondentes deste snapshot | MPL-2.0 |
| Código próprio autorizado do plugin separado em `plugins/obs` | GPL-3.0-or-later, com [escopo próprio](plugins/obs/LICENSE-SCOPE.md) e [texto GPL](plugins/obs/LICENSE) |

Esta tabela não altera as exceções e limitações seguintes. Os manifests Cargo próprios declaram
MPL-2.0 diretamente ou por herança do workspace. A licença também alcança modificações e novos
arquivos que contenham código coberto, nos termos da MPL; arquivos independentes podem ter outros
termos. Manter todo o código próprio aberto é a política deste projeto, além do mínimo exigido
pela licença.

## Recursos da preparação das lojas

As descrições de exclusões e placeholders deste documento se referem à base pública
`3172b188c29a010cd161c56bbeeb2cbcefbb220a`. A preparação das lojas inclui os recursos aprovados
de marca Android, Apple e Windows, os geradores e as modificações de interface necessários para
reproduzir os pacotes. Os termos de reprodução técnica dos recursos estão em
`tools/icones/DIREITOS-DA-MARCA.txt`, `brand/apple/DIREITOS-DA-MARCA.txt` e
`brand/windows/DIREITOS.md`. Eles permitem a reprodução prevista nesses documentos
sem conceder uma nova identidade de marca, atribuir autoria ou transformar os assets em
placeholders MPL. Geradores e modificações dos arquivos de código cobertos continuam MPL-2.0.
As receitas Windows/MSIX e OBS, os avisos Apple e a proveniência Android documentam a
preparação e suas limitações. Antes da distribuição pública, disponibilizar os fontes cobertos
correspondentes e suas modificações; o commit da base pública, isoladamente, não representa
as novas builds. A presença de uma receita ou evidência anterior não certifica um pacote novo.

## Terceiros, recursos e direitos pendentes

Não recebem nova licença ou atribuição de autoria por este aviso:

- `vendor/**`, `crates/quall-opus/vendor/**`, dependências dos gerenciadores de pacotes e seus
  patches/avisos. Alterações sobre fontes terceiros continuam sujeitas às licenças desses fontes.
- `plugins/obs/.libobs/**`, SDKs, headers e runtimes terceiros. libobs, SIMDe e w32-pthreads
  mantêm seus próprios termos; a combinação OBS é tratada no escopo do plugin.
- `apps/windows/terceiros/sudovda/**`: a nova licença própria não autoriza redistribuir o driver.
- FFmpeg, headers e bibliotecas em `apps/android/app/src/main/jniLibsDv/{include,lib}` e runtimes
  como `jniLibs/*/libc++_shared.so`, regidos pelos termos terceiros do inventário.
- Imagens, fontes, símbolos e outros assets terceiros. Os antigos 44 vetores Material não
  integram este snapshot. Os 46 `ic_q_*` são placeholders originais,
  sem paths Material, e recebem a MPL própria conforme `tools/icones/README.md`.
- Textos de licenças, atribuições, inventários e avisos terceiros copiados no checkout, inclusive
  [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt). Cópias de textos legais conservam seus termos.
- Imagens, ícones, coelho/tartaruga originais, capturas e mídia cujos direitos específicos não
  estejam confirmados permanecem omitidos. Os recursos aprovados identificados na seção de
  preparação acima têm seus termos próprios. A licença dos placeholders novos não
  concede direitos sobre a marca Quall Studio/Quéven nem reinterpreta os direitos dos assets antigos.
- `tools/espiao-dv-s24/teste-mesa/stub/**` e `plugins/obs/bancada/prova-remendo-sps.c`: proveniência
  e autorização específicas pendentes; estes caminhos foram omitidos deste snapshot.
- Recursos/keys de testes upstream omitidos de `vendor/datachannel-sys`, documentados em
  `vendor/datachannel-sys/PUBLIC-SOURCE.md`; a suíte upstream não é oferecida completa.
- Dados e conteúdo de usuários, registros privados de bancada e objetos/metadados Git.

A autorização para licenciar o código próprio selecionado não declara cessão à empresa de
direitos de todos os autores. Direitos e avisos de terceiros são preservados. Material alheio
sem autorização comprovada fica fora deste snapshot até consentimento ou substituição autorizada.
O inventário e os avisos [de terceiros](docs/distribuicao/licencas.md) continuam aplicáveis.

## Apps e combinação OBS

Nos apps, a MPL preserva a reciprocidade dos arquivos cobertos. Disponibilizar seus fontes
correspondentes, inclusive alterações, e informar ao destinatário como obtê-los é obrigatório
quando o executável for distribuído. Os termos do executável podem ser distintos, preservando
os direitos sobre os fontes (MPL §3.2). Licenciar o código próprio não relicencia OpenSSL,
libdatachannel, Opus, FFmpeg ou qualquer outro componente.

O plugin OBS é distribuído separadamente. Sua combinação com libobs e o núcleo incorporado é
tratada sob GPL-3.0-or-later. Para os fontes MPL que participarem dessa combinação, a via da MPL
§3.3 exige disponibilizá-los também sob a licença secundária aplicável, preservando a opção MPL
e seus avisos quando cabível. Isso não transforma os apps independentes em programas GPL, nem
remove as licenças originais de terceiros. O pacote do plugin precisa oferecer todo o fonte
correspondente da combinação, não apenas `plugins/obs/src`.

## Estado da distribuição

O destino confirmado é o repositório público da organização
[Quevenapp/Quall](https://github.com/Quevenapp/Quall). A publicação desta seleção limpa de fontes
foi autorizada. Este documento não confirma a execução de upload, release binária, certificação
em loja, build ou teste em aparelho. O repositório e seus fontes selecionados não correspondem
automaticamente aos artefatos históricos de FFmpeg, driver ou apps.

Antes de distribuir um executável, conferir os fontes e as dependências efetivamente incorporados,
oferecer o conjunto correspondente por meios acessíveis e informar seu endereço junto dos avisos.
Artefatos e assinaturas anteriores não são atualizados nem revalidados por esta publicação de fontes.
