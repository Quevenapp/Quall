# Manifesto do OpenSSL na distribuição Apple

OpenSSL é um dos SDKs da [lista oficial Apple](https://developer.apple.com/support/third-party-SDK-requirements/)
que requer manifesto próprio, inclusive quando recompilado a partir de fontes.
OpenSSL_Privacy.bundle é copiado como recurso do app iOS, da extensão ReplayKit e
do aplicativo macOS. Não contém executável ou SDK binário baixado.

Este manifesto destina-se ao OpenSSL 4.0.3 configurado pela receita
tools/distribuicao/construir-openssl-apple.sh e seu patch: sem configuração,
entropia, console ou provedores de armazenamento baseados em arquivos; sem
autoload de configuração e sem módulos/DSO. As chaves/certificados são tratados
em memória. O OpenSSL não envia dados a servidores do fornecedor nem faz
rastreamento. A receita impõe a ausência de APIs de arquivo/disco da lista de
Required Reason APIs por meio de gates de macros e imports dos arquivos estáticos.
O patch, a configuração e as macros de CSRNG passaram no preflight 4.0.3; a
confirmação dos imports exige os novos archives compilados. Não reutilizar o
resultado da auditoria 3.6.3 como se comprovasse o novo binário.

As APIs do restante do app/núcleo são declaradas nos respectivos manifestos do
app e da extensão. O manifesto do SDK não substitui essa auditoria. Conferir o
binário final e seu relatório de privacidade antes do envio. A exigência de
assinatura upstream para SDK adotado como dependência binária não é uma
declaração de assinatura pronta deste produto: o SDK é compilado dos fontes
fixos e o aplicativo final ainda deve receber sua assinatura de distribuição.
