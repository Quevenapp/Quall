# Quall Studio

Quall Studio é um estúdio gratuito para Windows, macOS, Android e iOS/iPadOS. Compartilha tela
ou câmera entre aparelhos, recebe vídeo, oferece teleprompter e gravação local no emissor.
No desktop, o vídeo recebido pode alimentar uma câmera virtual ou uma fonte nativa do OBS.

Este repositório publica um snapshot do fonte, sem o histórico anterior nem mídia, logs ou relatos
privados de desenvolvimento. Os ícones substitutos identificam apenas este snapshot público de
desenvolvimento. Não são um pacote comercial final nem um redesign autorizado da marca.
Não representam capturas de uma release ou capacidades adicionais. Publicar o fonte não certifica
builds, testes ou aprovação nas lojas.

## Plugin para OBS — download

O **Quall Studio OBS 1.0.0** está disponível para Windows x64 e macOS Apple Silicon.
Consulte o [guia de instalação e requisitos](docs/obs.md), baixe os pacotes na
[release oficial](https://github.com/Quevenapp/Quall/releases/tag/obs-v1.0.0) ou visite
[o site do Quall](https://queven.com.br/quall/obs/).
A release identifica a fonte correspondente e os limites de validação de cada plataforma.

## Recursos

| Recurso | Alcance |
|---|---|
| Espelhar e exibir | Tela existente ou câmera como origem; uma origem por sessão. |
| Pareamento | PIN na primeira conexão e pares persistidos localmente; endereço manual quando necessário. |
| Teleprompter | Texto local, controle remoto e composição com câmera. |
| Gravação | No emissor; controles e formatos dependem da plataforma. O receptor não tem gravação própria. |
| Câmera virtual | Integrações macOS e Windows com instalação e permissões próprias. |
| OBS | Plugin separado para macOS e Windows; gravação e composição são recursos do OBS. |
| USB e DVD | Exclusivos Android: exigem Android 11+, arm64, acessórios e hardware compatíveis. |
| Idiomas | Português e inglês. |

Monitor/Tela estendida, sudoVda, crop e video wall estão fora da primeira release.
Espelhar uma tela física existente continua no escopo; câmera virtual e OBS são integrações distintas.

## Plataformas

| Plataforma | Piso do produto | Limite |
|---|---|---|
| Windows | Windows 11 x64, build 22000+ | Build, execução nativa e instalador finais ainda precisam de validação. |
| macOS | macOS 13+ | Conferir arquitetura, permissões e assinatura do pacote distribuído. |
| iOS/iPadOS | iOS/iPadOS 15+ | App e extensão ReplayKit precisam de build e assinatura compatíveis. |
| Android | Android 9 / API 28+, armv7 e arm64 | USB/DVD têm requisitos adicionais; conferir bibliotecas e alinhamento do pacote. |

Pisos declarados não são uma lista de sistemas fisicamente testados. Este snapshot não comprova
paridade entre plataformas ou compatibilidade com todo aparelho e acessório.

## Começar

- [Uso e permissões](docs/uso.md)
- [Compilar por plataforma](docs/compilar.md)
- [Arquitetura](docs/arquitetura.md)
- [Limites e validação](docs/limites.md)
- [Contribuir](CONTRIBUTING.md) e [relatar segurança](SECURITY.md)

O núcleo usa Rust com dependências C/C++; as interfaces usam APIs nativas.
`cargo test --workspace` não compila as interfaces, extensão iOS, câmeras virtuais ou plugin OBS.

## Licenças e contato

O código próprio autorizado usa **MPL-2.0**; plugin/combinação OBS usa **GPL-3.0-or-later**.
Terceiros conservam suas licenças e avisos. Consulte [LICENSE](LICENSE),
[escopo e exclusões](LICENSE-SCOPE.md), [NOTICE](NOTICE.txt),
[avisos de terceiros](THIRD_PARTY_NOTICES.txt) e [inventário](docs/distribuicao/licencas.md).
Esses termos não concedem direitos sobre marcas ou material alheio. Distribua as fontes
correspondentes exigidas pelo conjunto efetivamente empacotado.

**Veneri & Quellis Ltda.** é a responsável pela distribuição.
Contato informado: [suporte@queven.com.br](mailto:suporte@queven.com.br).
