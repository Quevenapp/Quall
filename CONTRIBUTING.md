# Contribuir com Quall Studio

Envie mudanças por pull request com problema, comportamento esperado/observado, plataformas
afetadas e verificações executadas. Informe os testes não executados. Preserve contratos de
protocolo, armazenamento e fronteira C; explique migrações necessárias.

O código próprio autorizado segue MPL-2.0; plugin/combinação OBS segue GPL-3.0-or-later.
Respeite o [escopo](LICENSE-SCOPE.md), licenças e avisos de terceiros. Confirme que tem os direitos
necessários para oferecer código, assets ou traduções sob os termos do componente.
Explique alterações em vendor e sua relação com o upstream. Não há DCO ou CLA separado adotado aqui.

Consulte [compilação](docs/compilar.md) e [limites](docs/limites.md). Escolha verificações que
exercitem a mudança: testes Rust não substituem build/link nativo ou execução física.
Preserve lockfiles, alvos, perfis e requisitos mínimos; não atualize dependências silenciosamente.
Mudanças no header devem manter os consumidores em sincronia.

Não inclua credenciais, chaves, certificados privados, identificadores de aparelhos, PINs reais,
pares persistidos, conteúdo pessoal, gravações ou dumps integrais. Use dados sintéticos e logs
mínimos revisados. Teste somente sistemas e dados autorizados.

Para vulnerabilidades, siga [SECURITY.md](SECURITY.md). Não há promessa de prazo de revisão,
aceitação da contribuição ou inclusão em uma release.
