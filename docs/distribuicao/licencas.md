# Licenças e avisos do Quall Studio

Revisão: **05/10/2026**, checkout inicialmente em `1104cf39`. Quall Studio continua gratuito.
**Decisão aprovada por Bruno:** MPL-2.0 como padrão do código próprio dos apps/núcleo e
GPL-3.0-or-later para o plugin e a combinação OBS. A aplicação local nos fontes, metadados e
receitas foi concluída e validada documentalmente; binários finais e fontes públicas ainda
estão pendentes. Publicação, snapshot e distribuição dependem dos gates abaixo. O núcleo próprio não
receberá a declaração Exhibit B de incompatibilidade com Secondary Licenses.

**Responsável pela distribuição confirmado: Veneri & Quellis Ltda.** Isso não atribui à empresa
o copyright de todo o código, assets ou contribuições. A conferência de direitos está em andamento,
e as licenças e avisos dos terceiros permanecem conforme seu escopo. Destino público desejado:
`Quevenapp/Quall`, com existência e controle ainda sujeitos à conferência da coordenação.

A concessão própria deve alcançar somente o código próprio autorizado. Arquivos de terceiros,
assets e contribuições com direitos/proveniência pendentes não recebem essa licença por mera
presença no checkout. `tools/espiao-dv-s24/teste-mesa/stub` e
`plugins/obs/bancada/prova-remendo-sps.c` permanecem fora da concessão própria até fechar
proveniência/direitos. Se for identificada contribuição alheia sem autorização compatível,
resolver o direito antes de publicar ou distribuir o trecho afetado; aliases e autoria Git
não comprovam, sozinhos, identidade ou cessão.

## Resultado e alcance
O [inventário JSON](licencas/inventario.json) e o [CSV](licencas/inventario.csv) registram
versões, locks, licenças e hashes. Incluem runtime potencial, construção e testes. Os grafos
anteriores estão identificados como históricos; não houve nova resolução para esta seleção.
Na preparação da revisão de segurança v3, o [delta do lock atual](licencas/crypto-v3-lock.json)
registra os crates adicionados e removidos em relação à base pública. Os textos legais de cada
crate adicionado foram conferidos contra o archive oficial e seu checksum no lock, preservados
em `licencas/textos/crypto-v3/` e acrescentados aos avisos completos. A ferramenta
`tools/distribuicao/atualizar-licencas-crypto-v3.py` reproduz essa conferência. O inventário anterior
continua sendo referência da base, com seus próprios hashes; a revisão v3 exige novas builds e
verificação das dependências efetivamente incorporadas por plataforma.
Acréscimo de 2026-10-14, pela conexão por QR: `qrcode` 0.14.1 (Rust, MIT OR Apache-2.0, só
`apps/windows/Cargo.lock`, a matriz do QR que o Windows desenha) e `com.google.zxing:core` 3.5.3
(Android, Apache-2.0, o leitor). O `.crate` do `qrcode` foi conferido pelo checksum do lock e os dois
textos contra o tarball; o ZXing entrou em `licencas/complementos.json`, com a licença do POM pai
`zxing-parent` 3.5.3 (o JAR não traz LICENSE nem NOTICE). Os dois foram postos à mão no formato do
gerador, que os reproduz numa nova rodada. Comparados os três locks, `build.gradle.kts`,
`Package.swift` e `project.yml` com o inventário de 05/10 e o delta v3, não há outro componente sem
crédito. Estar no lock não comprova incorporação no binário. Os
[avisos completos](../../THIRD_PARTY_NOTICES.txt) preservam os corpos legais, copyrights e
emails públicos legítimos upstream, sem relatórios privados de bancada.

| Componente | Fonte e licença |
|---|---|
| datachannel 0.16.1, webrtc-sdp 0.3.14/0.3.15 | MPL-2.0; crates oficiais conferidos pelos checksums dos locks em `licencas/fontes/`. |
| datachannel-sys, libdatachannel e libjuice | MPL-2.0; árvore selecionada em `vendor/datachannel-sys/`, com patches/avisos e exclusões em `PUBLIC-SOURCE.md`. |
| OpenSSL 4.0.3, revisão preparada | Apache-2.0 e avisos internos; `openssl-src` 400.0.2+4.0.3 e seu checksum estão fixados nos locks. Avisos do wrapper, biblioteca e gerador de build estão no delta v3. A base 3.6.3 é histórica; a nova revisão ainda exige build e teste em cada plataforma. |
| libsrtp, usrsctp, plog, picohash | BSD, MIT e declaração de domínio público por arquivo; fontes/avisos na árvore vendor. |
| Opus 1.5.2 | BSD-3-Clause e avisos internos/patentes; fonte em `crates/quall-opus/vendor/opus/`. |
| Crates Rust e dependências Android | Versões nos locks/inventários; MIT, Apache, BSD, ISC, Unicode e MPL por componente. `OR` é alternativa; `AND` exige ambas. |
| FFmpeg 9.0.1 | Archive oficial completo e licenças em `licencas/fontes/`; a receita Android seleciona LGPL sem componentes GPL/nonfree. O archive conserva também os termos de fontes opcionais não selecionados. |
| libobs e dependências OBS | Obtidos separadamente pelas receitas do plugin; GPL-2.0-or-later, MIT e LGPL/avisos específicos. `.libobs` não é código próprio nem cache publicado. |

O inventário está em [`licencas/inventario.csv`](licencas/inventario.csv) e
[`licencas/inventario.json`](licencas/inventario.json). Os avisos preservados estão em
[`../../THIRD_PARTY_NOTICES.txt`](../../THIRD_PARTY_NOTICES.txt). O gerador
[`../../tools/distribuicao/gerar-licencas.py`](../../tools/distribuicao/gerar-licencas.py) pode ser
rodado offline, sem compilar ou resolver versões novas:

```sh
python3 tools/distribuicao/gerar-licencas.py --date 2026-10-05
```
Os novos placeholders geométricos são originais MPL, conforme
[tools/icones/README.md](../../tools/icones/README.md). Os 46 `ic_q_*` atuais não usam paths
Material. Os recursos de marca aprovados para Android, Apple e Windows têm os termos de
reprodução técnica indicados em [LICENSE-SCOPE.md](../../LICENSE-SCOPE.md). Geradores e
modificações de código cobertos continuam sob MPL-2.0. Antigos vetores Material, animais
originais, mídias, capturas e fixtures com proveniência indefinida permanecem omitidos, sem
reinterpretar seus direitos. Fontes/símbolos de
sistema continuam regidos pelos termos da plataforma. Driver sudoVda não integra esta seleção.

Foram lidos todos os **três lockfiles rastreados**: raiz, Windows e sonda Windows R5. A união tem
**192 versões de crates do registro**, além do fork local `datachannel-sys`. Cada tarball `.crate`
da cache foi conferido contra o checksum do lock; os textos de licença usados da cache foram
comparados com os textos no tarball. `cargo metadata --locked --offline` e os grafos de dependências
normais de iOS, macOS, Android arm64/armv7 e Windows Store x64 foram consultados. O CSV marca quais
componentes aparecem nesses grafos. Estar num lock ou grafo **não comprova** que o código ficou no
binário final: há construção, testes, sondas e alvos que não serão enviados. O arquivo de avisos
único inclui esse conjunto maior expressamente identificado.

O agregado final tem **305 entradas** e **253 textos distintos**. Não há lacunas de texto para
componentes cuja licença foi identificada. Os dois recursos de sistema/assets com direitos
específicos ou limites de uso são sinalizados expressamente; a existência de um aviso não resolve os
bloqueios de fonte, termos e assinatura descritos adiante.

Também foram auditadas bibliotecas nativas, os módulos transitivos do `releaseRuntimeClasspath`
Android, fontes e símbolos do sistema, ícones, recursos da árvore vendor, integração OBS e o
instalador separado sudoVda. As evidências Android/FFmpeg estão em
[`licencas/android-ffmpeg.md`](licencas/android-ffmpeg.md); a auditoria do driver está em
[`licencas/sudovda.md`](licencas/sudovda.md). Não foram abertos pixels das capturas antigas.

Os dois manifests SwiftPM rastreados (macOS e ferramenta vidro-a-vidro) não declaram `.package`
externa; não há `Package.resolved`, Podfile ou Cartfile rastreado. Os projetos Apple usam frameworks
de plataforma e a biblioteca Rust própria. A ferramenta Android `espiao-dv-s24` não declara
dependências externas de runtime; todas as coordenadas e versões fixadas da sonda Android R5 já
constam do inventário do app. Esses manifests foram comparados, sem afirmar resolução nova ou
execução das sondas.

## Bibliotecas e obrigações por produto

| Componente | Onde entra | Licença e preparação necessária |
|---|---|---|
| Crates Rust, inclusive `mdns-sd`, `tungstenite`, `serde`, criptografia e bindings Windows | Núcleo e cascas; versão exata por lock no CSV | Predominam MIT/Apache-2.0, com BSD, ISC, Unicode-3.0 e MPL. Expressões `OR` são alternativas; `AND` requer ambas. Preservar textos/avisos. |
| `datachannel` 0.16.1, `datachannel-sys` 0.23.0+0.23.2, libdatachannel 0.23.2, libjuice 1.6.1, `webrtc-sdp` 0.3.14 | Transporte dos quatro apps e integrações que usam o núcleo | MPL-2.0. Disponibilizar os fontes correspondentes, inclusive alterações Quall, informar como obtê-los e preservar avisos. |
| OpenSSL 3.6.3, via `openssl-src` 300.6.1+3.6.3 | Compilado estaticamente no transporte vendorizado | Apache-2.0 para a biblioteca; avisos BSD alternativos/adicionais dos arquivos também preservados. Licença MIT/Apache do crate de construção é um componente distinto. Não tratar como OpenSSL 1.x. |
| libsrtp 2.7.0 e usrsctp, snapshot da libdatachannel | Transporte de mídia/SCTP | BSD por arquivo. O agregado preserva LICENSE gerais e avisos adicionais dos fontes, inclusive titulares que não constam da licença geral. |
| plog 1.1.10 | Logging da libdatachannel | MIT, texto preservado. |
| picohash, snapshot em libjuice 1.6.1 | Hash/HMAC usados pela libjuice | Declaração de domínio público por arquivo, com créditos completos preservados. |
| libopus 1.5.2, fonte podado | `quall-opus`, núcleo padrão e app Windows | BSD-3-Clause e avisos de arquivos, preservados. `COPYING` também referencia declarações de patentes do codec; não equivale a autorização de outros codecs. |
| Rust standard library 1.98.0 e dependências internas | Toolchain do build atual | MIT/Apache e licenças internas. `COPYRIGHT-library.html` do toolchain foi convertido integralmente a texto e preservado, sem selecionar só a licença principal. Conferir toolchain dos binários finais. |
| AndroidX, Material Components, Kotlin, Guava e transitivas resolvidas | Android | Textos Apache-2.0; CameraX inclui libyuv BSD. Inventário por módulo e avisos recebidos dos AAR/JAR em `android-ffmpeg.md`. |
| FFmpeg 9.0.1: libavcodec, libavutil, libavformat e componentes internos | Android arm64, DV/MJPEG/DVD | LGPL-2.1-or-later e permissivas internas. `.so` separadas; levar licença, crédito IJG, fontes exatos e instruções de substituição. As condições completas ainda precisam constar dos termos do app. |
| libc++_shared do Android NDK | Android arm64/armv7 | Runtime redistribuído, separado das APIs de sistema. Preservar avisos da versão do NDK efetivamente empacotada; ver complemento Android. |
| libobs 32.2.2, SIMDe v0.8.2 e w32-pthreads | **Plugin OBS separado**, não os quatro apps | libobs GPL-2.0-or-later; SIMDe MIT/avisos por arquivo; w32-pthreads 2.9.1.0 fonte OBS: COPYING declara LGPL-2.1 e pthread.h versão 2 ou posterior. Decisão própria aprovada: plugin/combinação GPL-3.0-or-later. Conferir direitos, fonte correspondente e a DLL contra o OBS Windows alvo antes de distribuir; avisos dos terceiros preservados. |
| sudoVda 1.10.9.289 | **Instalador separado** para Windows x64 | Alterações SudoMaker MIT/CC0/domínio público; base Microsoft MS-PL; rastreabilidade EDID e cadeia binário/fonte pendentes. A assinatura/trust atual não é liberação de distribuição pública. |

O fonte alterado da libdatachannel e do build do `datachannel-sys` está documentado em
[`../../vendor/datachannel-sys/QUALL-PATCH.md`](../../vendor/datachannel-sys/QUALL-PATCH.md). Copyleft
MPL é por arquivo: a combinação não impõe MPL a todo o código independente do Quall, mas exige
que as partes MPL correspondentes, alteradas ou não, sejam obtíveis pelos destinatários do binário.
[MPL §3](https://www.mozilla.org/en-US/MPL/2.0/),
[FAQ oficial, perguntas 8–11](https://www.mozilla.org/en-US/MPL/2.0/FAQ/).

Os fontes MPL exatos foram preparados localmente em `licencas/fontes/`, com hashes e manifesto.
**Não foram publicados**. Não basta apontar o usuário somente ao upstream sem as alterações
Quall. A frente do site deve receber os arquivos, os textos e uma URL estável para os fontes;
somente depois essa URL pode ser colocada no aviso do app. Crates de construção MPL, como
`cbindgen`, também constam do inventário, separados da evidência de dependências normais.

`cpp_build`/`cpp_common` 0.5.11 omitem LICENSE no pacote publicado: seus textos MIT e Apache foram
recuperados do commit `ac7272466d0927f630c2a926a63a98af9c2623c3` indicado pelo próprio crate.
`r-efi` 5.3.0/6.0.0 declara alternativas MIT/Apache/LGPL no README e manifest e não fornece arquivo
LICENSE nem nas árvores correspondentes. Para esses dois foi incluído o texto padrão Apache-2.0,
uma alternativa declarada, com nota de procedência; nenhum aparece nos cinco grafos normais dos apps.

## Ícones, fontes e demais assets

| Recurso | Evidência | Tratamento |
|---|---|---|
| Marca Quall, launcher Android, AppIcon iOS, ICNS macOS, ICO Windows, ícone da Play | Geometria em `tools/icones/marca.py`, geração em `tools/icones/gerar.py` | Não há glifo ou fonte externo na construção. Isso não declara a titularidade jurídica da marca ou dos desenhos. Bruno deve confirmá-la antes de envio. |
| 44 vetores Android `ic_q_*.xml` | `docs/telas-android-como-ios.md` atribui Material; 12 arquivos têm comentário explícito | Material Icons Apache-2.0, incluído nos avisos. `coelho` e `tartaruga` são descritos como próprios, fora dessa contagem. [Fonte Google](https://developers.google.com/fonts/docs/material_icons). |
| Fontes/símbolos de sistema | Nenhum TTF, OTF ou WOFF rastreado; Apple `.system`/SF Symbols, Windows Segoe/Fluent/MDL2, Android sans-serif/monospace | Não são redistribuições de arquivos de fonte. Não exportar SF Symbols para marca ou ícone do app nem copiar fontes Windows sem direitos próprios. [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/sf-symbols), [Microsoft FAQ](https://learn.microsoft.com/en-us/typography/fonts/font-faq). |
| 19 PNG/SVG na libdatachannel/plog | Documentação web, screenshot de plog e assets de testes UWP | Não há cópia pelos scripts de empacotamento dos apps. Licença/atribuição específica de cada asset não foi comprovada; preservar como fontes recebidos e não reutilizar em material comercial sem esclarecimento. |
| 10 capturas antigas `integrations/bancada/provas/*.png` | Artefatos de bancada | Não reutilizar para loja sem confirmar origem, aparelho, versão e ausência de conteúdo do usuário. A auditoria não inspecionou pixels nem afirmou autoria/direitos de tudo que aparece. |

O repositório não contém pacote de música, vídeos de demonstração ou fontes externas rastreados.
Isso não prova que um futuro arquivo de release, uma captura ou um asset da frente do site não os
inclua: conferir a lista de arquivos do artefato final, além dos manifests do fonte.

## FFmpeg: o que os avisos não substituem

A tela Android já exibe a LGPL, versão e hash de fonte. Isso não elimina as outras obrigações:
oferecer o **fonte exato** com receita/configuração de compilação; não proibir modificação do
programa para uso próprio nem engenharia reversa para depurar a biblioteca modificada; garantir
a substituição das `.so` e preservar créditos internos. O crédito exigido pelo IJG foi encontrado
nos objetos compilados e adicionado aos avisos desta revisão. Há detalhes de proveniência e
eventuais lacunas no relatório Android. [Checklist oficial FFmpeg](https://ffmpeg.org/legal.html).

Não há prova nova nesta auditoria de troca das `.so`, assinatura/reinstalação de APK modificado ou
aceitação desse fluxo na distribuição final da Play. Não declarar essas etapas testadas. Também
não declarar liberação universal de patentes H.264/AAC/AC-3/DV/MJPEG por causa da licença do fonte:
a página legal do FFmpeg distingue patentes da licença de copyright.

## Distribuição separada do driver

**Atualização final de escopo (05/10/2026):** Bruno retirou Tela estendida da primeira release
das quatro plataformas. Driver/instalador e download foram adiados; não devem estar no app ou
MSI dessa release. O inventário conserva o componente futuro e seus avisos, identificado como
tal. A descrição abaixo registra a decisão anterior de separação, sem autorizar distribuição.

O instalador do **app** será enviado à Microsoft Store. **sudoVda não será instalado pelo pacote
da Store**; Bruno pretende oferecê-lo separadamente na página Quall Studio do site Quéven, depois
de resolver os bloqueios em [`licencas/sudovda.md`](licencas/sudovda.md). Ele é necessário somente
para criar as telas estendidas virtuais no Windows; espelhar tela, usar câmeras, receber vídeo e
teleprompter têm caminhos independentes. Não apresentar o driver como pré-requisito para todo o app.

`textos/SudoVDA-NOTICES.txt` contém MIT para as alterações declaradas e MS-PL completa com avisos
Microsoft. Deve acompanhar o instalador avulso e ser acessível sem iniciar a instalação. O arquivo
é um conjunto de avisos para revisão; não prova autorização sobre o binário específico, código
EDID, assinatura aceita em Windows limpo ou adequação de alterar confiança do sistema.

## Decisão aprovada e obrigações de fonte

A decisão de abrir todo o código próprio substitui os cenários anteriores de interfaces
proprietárias, núcleo MIT ou GPL ampla para todos os apps. O padrão aprovado é **MPL-2.0** para
apps/núcleo e demais componentes próprios fora do plugin; o **plugin e a combinação OBS** ficam
sob **GPL-3.0-or-later**. Textos LICENSE, manifests/headers e receitas de empacotamento foram
aplicados localmente nos fontes e passaram revisão documental independente. Isso não comprova
o conteúdo de binários finais nem disponibiliza o fonte público, que permanecem pendentes.

O núcleo próprio permanece identificado como MPL-2.0, **sem aplicar o aviso Exhibit B**; o texto
completo da MPL mantém seus exhibits. Na combinação OBS GPL3+, os arquivos MPL elegíveis podem
ser distribuídos adicionalmente sob GPL3+ conforme §3.3, preservando avisos, fonte e direitos MPL.
O trabalho combinado deve cumprir as condições GPL3+ aplicáveis. Isso não apaga
licenças de origem nem autoriza relicenciar automaticamente arquivos de terceiros. Conferir
os arquivos MPL efetivamente incorporados e sua elegibilidade antes de distribuir o conjunto.
[Texto oficial MPL-2.0, §§3.1–3.3 e Exhibit B](https://www.mozilla.org/en-US/MPL/2.0/),
[FAQ oficial de compatibilidade](https://www.mozilla.org/en-US/MPL/2.0/FAQ/).

A libobs auditada permite GPL-2.0 **ou posterior**; a decisão GPL3+ usa essa opção porque
o núcleo incorpora OpenSSL 3.6.3 Apache-2.0. Apache-2.0 pode integrar uma combinação GPL3, mas
não GPL2-only. A aplicação ao artefato exato ainda exige conferência dos headers e demais
componentes; não é opção de dispensar obrigações.
[Compatibilidade Apache/GPL, fonte oficial](https://www.apache.org/licenses/GPL-compatibility.html).

A GPL não cobra royalty de licença por cópia. O custo prático é preparar e manter o fonte
correspondente de cada plugin distribuído: núcleo estático incorporado, patches, scripts,
configuração e instruções; avisos/licença e acesso ao fonte sem custo adicional ao download,
preservando os direitos de modificar/redistribuir. Publicar só `plugins/obs/src` é insuficiente.
O canal separado do plugin não decide automaticamente a independência das obras: os apps
MPL devem continuar sem incorporar código GPL do OBS de forma incompatível. Não impor restrições
incompatíveis aos destinatários do conjunto GPL.
[Texto GPL3 §§1, 5 e 6](https://spdx.org/licenses/GPL-3.0-or-later.html).

MPL e FFmpeg LGPL nos apps continuam exigindo fontes/avisos e termos apropriados. A abertura
dos apps não dispensa essas obrigações nem a substituição/engenharia reversa para depurar
a biblioteca LGPL nos termos aplicáveis. Não há cálculo de custo de
patentes, contas de loja, assinatura ou assessoria nesta recomendação; gratuidade/copyright
não resolve esses temas. Três decisões de dados/processo estão em
[privacidade-factual.md](privacidade-factual.md).

1. A aplicação local da decisão MPL-2.0/GPL-3.0-or-later nos fontes/receitas foi concluída e
   validada documentalmente, mantendo gratuidade e responsável pela distribuição já confirmados.
   Conferir binários finais e disponibilizar fontes públicas. Fechar direitos de contribuição e
   marca/desenhos sem presumir titularidade integral da empresa a partir dessa responsabilidade.
2. Fornecer destino público para fontes MPL e FFmpeg, instruções de obtenção e termos compatíveis
   com LGPL. A frente do site recebe os arquivos preparados; esta frente não editou nem publicou site.
3. Em frente futura, resolver assinatura/procedência sudoVda e fluxo de instalação antes de oferecer download público.
   A opção atual de importar certificado autoemitido em Root/TrustedPublisher não está liberada
   por esta revisão. Nenhum driver, certificado ou ajuste de segurança foi instalado.
4. Para plugin/combinação OBS GPL3+, preparar a disponibilização completa do fonte correspondente,
   conferir a condição MPL §3.3 e confirmar w32-pthreads da versão Windows alvo antes de distribuí-lo.
5. Conferir que os avisos agregados entram e ficam acessíveis nas quatro distribuições finais,
   inclusive extensão iOS quando aplicável. Os responsáveis de código/packaging fazem essa
   integração; criação do arquivo no repositório sozinha não comprova conteúdo no pacote.
6. Gerar inventário de **arquivos reais** para cada release, conferir versões/hashes, fontes
   correspondentes, símbolos/fontes que venham embutidos por toolchain e quaisquer novos assets.
   Não houve build Windows limpo, instalação pública ou validação jurídica abrangente nesta auditoria.

Os bloqueios são específicos; o inventário e os avisos podem ser integrados e revisados enquanto
as fontes, termos e assinatura são resolvidos. Nenhuma submissão, publicação, push ou alteração de
credenciais ocorreu nesta frente.
