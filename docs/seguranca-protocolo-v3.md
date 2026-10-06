# Protocolo de segurança v3

Esta revisão usa `opaque-ke = 4.0.1` (OPAQUE-3DH) para autenticar o PIN ou um segredo de
retomada. O código anterior de pareamento e a sinalização v1/v2 não são aceitos. Todos os
aparelhos de uma sessão precisam usar uma build v3; os pacotes anteriores devem ser reconstruídos.

OPAQUE é publicado no [RFC 9807](https://www.rfc-editor.org/rfc/rfc9807.html), documento
CFRG de categoria Informational. A escolha desse protocolo e de `opaque-ke` não constitui
auditoria independente da integração Quall.

## Sequência de conexão

1. O convidado envia `Probe` com versão, nonce aleatório e papel funcional. O anfitrião responde
   `Challenge` com nonce, token aleatório por conexão, papel e 128 hints de retomada. Os slots
   não usados contêm valores aleatórios. Esses frames não carregam ID ou nome persistente.
2. `Hello`, `Ack` e `Confirm` do pareamento transportam KE1/KE2/KE3. O contexto autenticado
   inclui versão, modo PIN/retomada, papéis, token e os dois nonces. Host/Guest têm identificadores
   criptográficos distintos. PIN explícito escolhe novo pareamento; sem PIN, a tabela local
   procura um segredo v3 que corresponda aos hints desta conexão.
3. Os IDs reais são enviados em confirmações AEAD. Na retomada, o ID precisa ser o associado
   ao segredo selecionado. Nenhuma ponta devolve sucesso antes de conferir a confirmação remota.
4. O canal é transferido ao `Link` preservando os contadores usados nas confirmações. Os anúncios
   `Hello`/`Welcome` da sinalização são enviados cifrados; ID e papel precisam corresponder aos
   valores autenticados no pareamento. Só então nasce o transporte de mídia.

Não confundir `PairFrame::Hello` (KE1) com `SignalMessage::Hello` (anúncio pessoal cifrado).

## Canal e limites

O canal usa ChaCha20-Poly1305 com chaves direcionais derivadas por HKDF-SHA256. Cabeçalho,
direção e contador são autenticados. Repetição, alteração, reflexão, salto de sequência ou
mensagem aberta depois da autenticação encerram a conexão. Todas as variantes pós-pareamento
— anúncios, SDP/fingerprints, ICE, métricas, erros e despedida — passam por esse canal, inclusive
as mensagens enfileiradas pelos callbacks do transporte. Não há fallback para JSON aberto.

A sinalização limita mensagens a 256 KiB e frames de pareamento a 16 KiB. Uma autenticação
aceita no máximo 12 frames e tem prazo de até 30 segundos, limitado também pelo prazo global
e cancelamento. Há um candidato ativo por espera. O handshake WebSocket tem prazo de 2 segundos.
Um erro de escrita após consumir um contador também invalida a conexão.

O PIN usa Argon2id com 19 MiB, duas passagens e uma lane. A execução do KSF é serializada para
conter o uso concorrente de memória. Retomada usa segredo de 32 bytes, nunca o PIN no modo de
KSF rápido. Uma tentativa PIN que chega a KE1/KE2 consome a espera mesmo se o convidado detectar
PIN incorreto e desconectar antes de KE3; a interface precisa gerar outro PIN. Probe/Challenge
sem tentativa PAKE podem ser descartados sem trocar o PIN. Isso não elimina negação de serviço
por tráfego de rede; o prazo global mantém a operação limitada.

## Descoberta e identidade

mDNS anuncia uma instância genérica `Quall <token32>`, hostname `quall-<token32>.local.` e TXT
`v=3,t=<token32>,p=<porta>,c=<capacidades>` com `pa=<papel>` opcional. O token aleatório é novo
a cada início do anunciante. TXT com `id`/`n`, versão antiga, token inválido ou porta zero é
recusado. Endereços IP, porta, presença do serviço e capacidades/papéis funcionais continuam
visíveis na LAN por serem necessários à descoberta. Eles não autenticam o destino.

O navegador devolve ID `discovery-<token32>`, rótulo genérico e
`identity_authenticated: false`. Esses valores não devem ser persistidos como pares nem usados
para perguntar se um aparelho já é confiável. Depois da autenticação, `Ready.peer` e
`quall_session_peer_json` devolvem a identidade real, com `identity_authenticated: true` na FFI.
A identidade local persistente não muda. IP manual usa a mesma sequência segura.

`Advertiser::discovery_label()` e a FFI `quall_advertiser_label` devolvem o rótulo real
`Quall <primeiros8hex>` do anunciante ativo, igual ao decodificado no navegador. As telas de
espera usam esse alias para permitir selecionar entre vários anfitriões anônimos. O nome
pessoal local é conservado e aparece ao par somente depois da autenticação. Na FFI, o tamanho
retornado inclui NUL; buffer ausente/curto informa o tamanho sem escrita, e handle inválido
retorna `-1`.

## Migração dos vínculos

Entradas antigas permanecem no JSON, mas não habilitam retomada. Um novo PIN cria um vínculo
marcado `security_version: 3`. `PairedPeers::has_secure_peers()` e a FFI
`quall_known_peers_has_secure` indicam a presença de vínculos modernos válidos; a FFI retorna
`1`, `0` ou `-1` para erro. Isso permite tentar retomada sem tratar o ID efêmero como confiável.
Até 128 vínculos elegíveis entram na seleção automática; os demais continuam armazenados e
podem usar PIN explícito. O segredo persistido continua sendo material de chave cuja proteção
em disco é responsabilidade de cada plataforma.

Os testes de protocolo e loopback são evidências do comportamento implementado. Não constituem
auditoria independente da integração, aprovação de loja ou prova de uma build antiga.

## Transporte de mídia e builds

O alvo nativo desta revisão é OpenSSL 4.0.3, fornecido por `openssl-src = 400.0.2`;
o componente estático precisa ser reconstruído. A configuração DTLS exige no mínimo
DTLS 1.2, verifica o retorno de `SSL_CTX_set_min_proto_version` e falha se a exigência
não puder ser aplicada. A mídia continua usando DTLS-SRTP; o canal de dados WebRTC usa
DTLS. A sinalização AEAD autentica SDP e fingerprints antes de criar o transporte.

Testes anteriores com OpenSSL 3.6.3 são históricos. Em 06/10/2026, a revisão fonte v3
compilou nativamente no macOS com 4.0.3 e passou 539 testes do core, 100 da FFI, uma
integração de áudio e um doctest; três testes de benchmark/estresse ficaram ignorados.
A execução usou uma thread para evitar interferência nos relógios. Os testes incluem
PAKE/AEAD e transporte de mídia em TCP/WebRTC loopback, indicadores de migração e o
getter do alias com UTF-8/NUL/capacidade. Isso não é prova de mídia nos aparelhos.

Rebuilds de cada plataforma, correspondência dos artefatos com o commit congelado e prova
final de mídia/interface nos aparelhos continuam pendentes. Nenhum teste do protocolo
transfere validade a pacotes antigos nem declara estes gates concluídos.
