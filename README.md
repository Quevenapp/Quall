# Quall Studio

Quall Studio é um estúdio gratuito para Windows, macOS, Android e iOS/iPadOS. Compartilha tela
ou câmera entre aparelhos, recebe vídeo, oferece teleprompter e gravação local no emissor.
No desktop, o vídeo recebido pode alimentar uma câmera virtual ou uma fonte nativa do OBS.

Este repositório publica fontes sem o histórico anterior nem mídia, logs ou relatos privados de
desenvolvimento. A preparação das lojas reúne as alterações dos apps e do plugin OBS, as receitas
de empacotamento e os recursos de marca autorizados para reprodução técnica dos pacotes. Os
recursos de marca têm termos próprios; modificações de código continuam sob suas licenças.
Consulte o [escopo](LICENSE-SCOPE.md) e os documentos de proveniência de cada plataforma.
Publicar o fonte não certifica builds, testes, segurança ou aprovação nas lojas. Os pacotes precisam
corresponder à revisão de fonte identificada em sua proveniência; a base histórica isolada não
representa as novas builds.

## Recursos

| Recurso | Alcance |
|---|---|
| Espelhar e exibir | Tela existente ou câmera como origem; uma origem por sessão. |
| Pareamento | PIN na primeira conexão e pares persistidos localmente; endereço manual quando necessário. |
| Teleprompter | Texto local, controle remoto e composição com câmera. |
| Gravação | No emissor; controles e formatos dependem da plataforma. O receptor não tem gravação própria. |
| Câmera virtual | Integrações macOS e Windows com instalação e permissões próprias; a edição Microsoft Store usa somente exibição interna e não inclui a câmera virtual externa. |
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
- [Pareamento, descoberta e sinalização v3](docs/seguranca-protocolo-v3.md)
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
