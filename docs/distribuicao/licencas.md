# Licenças e fontes do Quall Studio

A seleção de fontes destina-se ao repositório público da organização
[Quevenapp/Quall](https://github.com/Quevenapp/Quall); sua publicação foi autorizada.
Este snapshot contém fontes e documentação. Não comprova upload, build, teste em aparelho,
assinatura, aprovação de loja ou correspondência automática a binários históricos.

O código próprio autorizado dos apps/núcleo usa **MPL-2.0**; o plugin OBS e sua combinação
usam **GPL-3.0-or-later**. Consulte [LICENSE-SCOPE.md](../../LICENSE-SCOPE.md).
Veneri & Quellis Ltda. é responsável pela distribuição; isso não declara cessão geral de
direitos. Não foi aplicado Exhibit B ao código próprio. Terceiros conservam seus titulares.

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
Estar no lock não comprova incorporação no binário. Os
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

MPL exige oferecer fontes correspondentes, inclusive modificações, e informar como obtê-los.
A via §3.3 permite a combinação GPL quando os arquivos não estiverem marcados como
incompatíveis, preservando a opção MPL aplicável. Exhibit B dentro do texto integral não é
um aviso aplicado. [MPL](https://www.mozilla.org/MPL/2.0/),
[FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/).
OpenSSL Apache-2.0 é compatível com GPLv3, não GPLv2-only. O pacote OBS deve oferecer o fonte
correspondente da combinação, incluindo núcleo e instruções; só `plugins/obs/src` é insuficiente.
[Apache/GPL](https://www.apache.org/licenses/GPL-compatibility.html).

Os novos placeholders geométricos são originais MPL, conforme
[tools/icones/README.md](../../tools/icones/README.md). Os 46 `ic_q_*` atuais não usam paths
Material. Os recursos de marca aprovados para Android, Apple e Windows têm os termos de
reprodução técnica indicados em [LICENSE-SCOPE.md](../../LICENSE-SCOPE.md). Geradores e
modificações de código cobertos continuam sob MPL-2.0. Antigos vetores Material, animais
originais, mídias, capturas e fixtures com proveniência indefinida permanecem omitidos, sem
reinterpretar seus direitos. Fontes/símbolos de
sistema continuam regidos pelos termos da plataforma. Driver sudoVda não integra esta seleção.

O [manifesto](licencas/fontes/manifesto.json) identifica fontes realmente presentes.
O antigo archive do fork, com assets/containers omitidos, não é incluído: use a árvore selecionada,
locks, patches e avisos. A suíte upstream não é oferecida completa.

Antes de distribuir executáveis, conferir fontes e dependências efetivamente incorporados,
versões/hashes, receitas e avisos finais. FFmpeg exige também créditos IJG e termos internos,
modificação/engenharia reversa para depuração e substituição conforme LGPL. A troca da biblioteca
no pacote final não foi testada nesta revisão. [FFmpeg](https://ffmpeg.org/legal.html).
Uma URL de repositório, sozinha, não cumpre todas as obrigações de uma futura release binária.
