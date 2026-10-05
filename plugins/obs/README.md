# Plugin Quall Studio para OBS

Fonte nativa OBS para receber mídia pelo núcleo Quall. O código do plugin integra diretamente
a API libobs e incorpora o núcleo Rust; não é uma aplicação independente do OBS. Os caminhos
de build desta árvore são para Windows e macOS. Este pacote de fontes não certifica execução,
compatibilidade com uma instalação OBS específica, assinatura ou testes em aparelhos.

## Licença

O plugin e sua combinação são **GPL-3.0-or-later**, conforme [LICENSE-SCOPE.md](LICENSE-SCOPE.md)
e [LICENSE](LICENSE). O núcleo tem MPL-2.0 como licença padrão e é disponibilizado também pela
via secundária aplicável na combinação. Avisos e licenças de libobs/dependências são preservados;
`.libobs` é cache upstream e não recebe a licença própria do plugin. A fixture
`bancada/prova-remendo-sps.c` não integra este snapshot. Responsável pela distribuição:
Veneri & Quellis Ltda.; isso não declara cessão geral de direitos de autores/terceiros.

Uma distribuição binária precisa de todo o fonte correspondente da combinação, núcleo,
patches e instruções necessários, não somente `src/`. Consulte
[avisos terceiros](../../THIRD_PARTY_NOTICES.txt) e [licenças/fontes](../../docs/distribuicao/licencas.md).

## Build local sem instalar

São necessários Rust, CMake, Ninja, ferramentas C/C++ e uma instalação OBS compatível com
arquitetura/alvo. No Windows, as receitas usam ferramentas MSVC; no macOS, ferramentas Apple.
As receitas consultam a versão instalada e obtêm fontes/headers upstream; usar uma tag não
comprova compatibilidade de runtime. Examine os scripts antes de executá-los.

```sh
cd plugins/obs
./construir.sh --sem-instalar
```

No PowerShell Windows:

```powershell
cd plugins/obs
./construir.ps1 -SemInstalar
```

Essas opções produzem arquivos em `build/` sem copiar para a instalação OBS. Os documentos
GPL/MPL e avisos acompanham o candidato. A inspeção do pacote e a carga no OBS são etapas
separadas. **Sem essas opções, os scripts também instalam localmente o plugin**: use esse modo
somente quando desejar alterar sua instalação OBS, após revisar caminhos e conteúdo.
A assinatura ad-hoc local macOS, quando realizada pela receita, não equivale à assinatura
de distribuição ou certificação em loja.

O destino dos fontes é [Quevenapp/Quall](https://github.com/Quevenapp/Quall). A publicação desta
seleção foi autorizada; nenhum teste ou artefato histórico é transferido para este snapshot.
