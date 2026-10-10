# Fontes e receita da release Apple

O app e núcleo seguem o escopo MPL-2.0 de LICENSE-SCOPE.md. O módulo OBS é um
produto separado; libOBS e componentes FFmpeg GPL não integram os aplicativos
Apple. Publicar os fontes modificados correspondentes antes de distribuir os
binários. Os avisos de terceiros são recursos do app e da extensão.

## Dependências e privacidade

A receita tools/distribuicao/construir-nucleo-apple.sh fixa Rust 1.98.0
(88d9e12ae, 2026-08-18), o componente oficial rust-src de 2026-08-20 e seu
Cargo.lock. Instale a toolchain e rust-src em uma área de compilação isolada; não
é necessário trocar a toolchain de outros projetos. Informe o caminho absoluto
da toolchain por QUALL_RUST_APPLE_TOOLCHAIN. As dependências precisam ser
obtidas conforme os locks antes da execução offline.

rust-src oficial: https://static.rust-lang.org/dist/2026-08-20/rust-src-1.98.0.tar.xz

SHA256: 0e977492aed5ff137815bf9b4b796e8a85b80fb2367ed64e82d5c5839870f2bf

A biblioteca padrão é reconstruída com build-std e lista de features vazia,
sem backtrace e panic-unwind. O perfil Release mantém panic=abort e o hook do
produto. Isso elimina a simbolização padrão que consultaria arquivos do sistema
fora dos dados próprios do app. build-std é experimental no Cargo; o uso de
RUSTC_BOOTSTRAP está restrito ao processo de compilação com versão fixa e não
altera configurações globais. Esta dependência experimental é uma limitação
concreta da receita e deve ser revalidada antes de atualizar Rust.

O OpenSSL vem do Cargo.lock. Sua receita Apple desativa configuração, console,
entropia e armazenamento baseados em arquivos; mantém certificados/chaves em
memória e o gerador seguro CCRandomGenerateBytes da plataforma. O patch local
do provedor de arquivos falha de forma fechada para URIs de arquivo quando
essas funcionalidades estão desativadas; BIOs de memória continuam disponíveis.
Essa mudança não substitui algoritmos criptográficos. Validar conexão real
DTLS/SCTP/SRTP além dos portões de compilação.

O objeto oficial os_version_check.c.o do compiler-rt fornecido pelo Xcode é
linkado antes do núcleo, para substituir o fallback de disponibilidade do
Rust. A receita não altera esse objeto; seus avisos e licença upstream são
preservados em THIRD_PARTY_NOTICES.txt.

Referências: [build-std](https://doc.rust-lang.org/cargo/reference/unstable.html#build-std),
[features da std](https://doc.rust-lang.org/cargo/reference/unstable.html#build-std-features).

## Marca da versão comercial

O ícone placeholder do snapshot público não é a arte aprovada para a loja.
Os direitos de marca Quall Studio e as imagens PNG/ICNS permanecem fora da
licença MPL-2.0; o código e suas modificações mantêm MPL-2.0. O titular fornece um
overlay correspondente que contém AppIcon-1024.png e Quall.icns, junto de sua licença separada, origem e hashes. Inclui o patch das geometrias
aplicadas nas interfaces, com caminhos relativos. Informe QUALL_MARCA_APPLE_DIR na receita para aplicar esse overlay.
tools/distribuicao/conferir-marca-apple.sh exige os hashes aprovados e impede uma
release comercial com o placeholder. Esse controle não impede terceiros de
compilar ou distribuir o código aberto com sua própria marca e identidade;
eles devem adaptar a receita de publicação e observar LICENSE-SCOPE.md.

O código do patch de interface e de marca.py conserva a licença MPL-2.0 dos
fontes. Imagens PNG/ICNS e direitos de marca têm licença separada que permite
reprodução e relink dos arquivos correspondentes, sem endosso. Marcas não são
convertidas em propriedade livre por essa concessão técnica. Nenhum certificado, perfil, chave privada ou Signing.local.xcconfig faz
parte do patch público.

## Alvo de segurança e versão

A release alvo é 1.0.0/build 2, com protocolo 3 e OpenSSL 4.0.3 fixado no
Cargo.lock. Não reaproveitar libcrypto/libssl 3.6.3 ou núcleos de protocolo 2.
A configuração e geração de cabeçalhos não substituem a compilação, auditoria
de APIs Required Reason e teste de mídia do binário final. O manifesto SDK
vazio depende da auditoria das fatias exatas recompiladas. O manifesto do app
e da extensão continua separado e descreve as APIs dos respectivos alvos.

A descoberta iOS usa as APIs públicas DNS-SD do daemon Bonjour com instância e
host efêmeros; ver [contrato e prova](apple-descoberta-v3.md). Nenhuma receita
cria credencial, assina declaração regulatória ou submete o app à loja.
