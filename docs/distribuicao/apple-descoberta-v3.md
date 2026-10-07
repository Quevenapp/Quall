# Descoberta Apple v3

Antes da autenticação, os registros públicos contêm apenas `v=3`, `t` com
32 caracteres hexadecimais minúsculos aleatórios por início, `p` com porta
não zero, `c` obrigatório com capacidades s/c/k e `pa` opcional com o papel
teleprompter. Não publicar nome/modelo/ID persistente em TXT, instância ou
hostname do serviço Quall. A instância é `Quall <token completo>` e o host é
`quall-<token>.local.`. A lista e o emissor mostram o mesmo alias
`Quall <primeiros oito caracteres>`. Identidade real só vem da sessão
autenticada, cifrada por PAKE/AEAD. O alias não é um ID de par persistente.

## API iOS

AnuncianteBonjour usa DNSServiceRegister com host explícito e A/AAAA próprios
por DNSServiceRegisterRecord, através do daemon do sistema. O uso do campo
host requer que o cliente registre o endereço correspondente, conforme a
[documentação pública Apple](https://developer.apple.com/documentation/dnssd/1804733-dnsserviceregister?preferredLanguage=occ).
Publica apenas em interfaces locais en* ativas, excluindo loopback, VPN e
celular; os endereços IPv6 mantêm escopo pela interface. Mudança de endereços
refaz os registros. Erros e encerramento removem serviços e a conexão dos
registros; deallocation ocorre na mesma fila dos callbacks.

Não abre socket multicast próprio, não altera o nome do computador/aparelho
e não pede entitlement multicast especial. O serviço `_quall._tcp` já está
declarado em NSBonjourServices e o consentimento Rede Local continua sendo
do usuário. A [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
distingue o serviço Bonjour declarado de uso de multicast e navegação por
tipos arbitrários. Simulador não comprova a política de privacidade de rede.

## Prova de implementação

Em 6/10/2026 uma fixture com o AnuncianteBonjour de produção, conteúdo
sintético e apenas um stub da versão FFI 3 executou em iPad A16 físico. Um
resolver Mac de API pública consultou somente sua instância conhecida: SRV
apontou para o host efêmero, TXT foi exatamente o contrato acima, resolução
IPv4 e IPv6 passou e a retirada do SRV após parar foi observada. O app anterior
foi restaurado. A fixture não comprova PAKE, mídia ou memória ReplayKit; esses
gates pertencem ao novo binário completo. Os testes puros de token/instância
estão em apps/ios/Quall/Testes e os tipos Swift foram conferidos com SDK iOS.

O macOS anuncia pelo núcleo e usa quall_advertiser_label para mostrar o alias
real, mantendo o handle protegido pela trava. As cascas Apple contam somente
pares seguros v3 pelo FFI quall_known_peers_has_secure. Arquivos legados são
preservados e não produzem a promessa de retomada segura sem novo PIN.

Endereços IP e tráfego de descoberta permanecem públicos na rede. O sistema
ou outros aplicativos podem anunciar outros serviços com nomes próprios; esta
implementação limita os registros Quall e não promete ocultar todo o aparelho
na LAN. Redesenho de permissões, ausência de multicast ou isolamento do Wi-Fi
pode impedir descoberta; conexão manual por endereço permanece disponível.
