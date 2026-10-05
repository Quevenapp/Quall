# Licença do plugin OBS e da combinação Quall Studio

O código próprio deste plugin é disponibilizado sob a **GNU General Public License, versão 3
ou, a seu critério, qualquer versão posterior** — `GPL-3.0-or-later`. O texto integral da
versão 3 está em [LICENSE](LICENSE). A opção “ou posterior” faz parte deste aviso; a presença
do texto da versão 3 não limita a licença a `GPL-3.0-only`.

Você pode redistribuir e modificar esse código nos termos da GPL acima. Ele é fornecido sem
garantia, inclusive sem garantia implícita de comercialização ou adequação a uma finalidade
específica; consulte a licença integral para conhecer os termos e as obrigações.

## Combinação distribuída com o OBS

O artefato combinado do plugin — código próprio desta pasta, ligação com libobs e código
incorporado pelo núcleo estático — é distribuído sob **GPL-3.0-or-later**, respeitando os avisos
e os termos aplicáveis a cada componente.

A licença padrão do código próprio dos apps e do núcleo Quall é **MPL-2.0**, conforme os
avisos da raiz. Para esta combinação, o código próprio MPL incorporado é disponibilizado
adicionalmente sob GPL-3.0-or-later nos termos da seção 3.3 da MPL-2.0. Os avisos MPL permanecem
nos arquivos e a opção MPL dos arquivos cobertos é preservada; a combinação maior recebe GPL.
Isso não muda a licença padrão dos apps ou do núcleo quando distribuídos separadamente.
O aviso de incompatibilidade com licenças secundárias do Exhibit B da MPL não é aplicado ao
código próprio Quall nessa opção. [Texto MPL-2.0](https://www.mozilla.org/MPL/2.0/).

Uma distribuição deve fornecer o fonte correspondente do artefato efetivamente entregue,
incluindo núcleo estático incorporado, patches, recursos, scripts e configurações de build
necessários, além de cumprir os avisos e as demais obrigações aplicáveis. Apenas publicar
`plugins/obs/src` ou incluir este texto de licença não cumpre, por si só, essa obrigação.

## Componentes de terceiros e autoria

Este aviso rege o código próprio e a combinação indicada. **Não substitui** licenças,
copyrights ou atribuições de terceiros. `.libobs/` é cache de fontes upstream e está excluído
da licença própria desta pasta. Os avisos e as cópias de textos legais de terceiros também
ficam excluídos dessa aplicação de licença própria. Preserve os avisos das dependências e consulte o
`THIRD_PARTY_NOTICES.txt` do candidato correspondente.

`bancada/prova-remendo-sps.c` está **excluído desta nova aplicação de GPL/SPDX**: a proveniência
integral dos literais da fixture ainda não foi demonstrada. O arquivo foi omitido deste
snapshot público. Sua inclusão futura exige revisão/autorização; ausência de aviso externo
nos arquivos revisados não é certificação de autoria ou titularidade.

Veneri & Quellis Ltda. é a responsável pelo produto e por sua preparação para distribuição.
Essa identificação não afirma titularidade ou cessão de direitos de todos os arquivos.
Avisos existentes e a proveniência de contribuições e fixtures devem ser preservados e
conferidos antes de uma distribuição pública.

## Documentos dos novos candidatos

O empacotamento deve incluir, byte a byte:

- `LICENSE`: GPLv3 integral, deste diretório, com a opção or-later definida neste aviso;
- `LICENSE-SCOPE.md`: este escopo;
- `LICENSE-MPL-2.0.txt`: texto integral MPL-2.0 copiado de `LICENSE` da raiz;
- `THIRD_PARTY_NOTICES.txt`: avisos atuais da raiz auditada.

No macOS, ficam em `quall-obs.plugin/Contents/Resources/`; no Windows, em `build/data/`,
que acompanha a DLL no pacote. Arquivos e ZIPs produzidos anteriormente não são atualizados
por esta alteração de fontes: precisam de nova preparação e conferência autorizadas.

O GPLv3 integral foi copiado, sem alterar bytes, de
[GNU](https://www.gnu.org/licenses/gpl-3.0.txt); este aviso declara a opção or-later aprovada.

Este snapshot fonte destina-se a https://github.com/Quevenapp/Quall, repositório público da
organização Quevenapp. Sua publicação foi autorizada; nenhum texto desta pasta certifica
build, assinatura, teste em aparelho ou correspondência automática a um plugin binário antigo.
