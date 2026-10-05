# Quall Studio para iOS e iPadOS

O produto está em [Quall](Quall/README.md). É um app Swift com extensão ReplayKit, piso
iOS/iPadOS 15 e núcleo Rust compartilhado. O app recebe vídeo, captura câmera, grava localmente
e oferece teleprompter; a extensão transmite tela em processo separado.

| Pasta | Finalidade |
|---|---|
| `Quall` | App de produto e extensão `Difusao`. |
| `PortaoQuall` | Projeto mínimo de diagnóstico da toolchain iOS. |
| `PortaoAppex` | Harness de app/extensão e contratos de transmissão. |
| `PortaoOpus` | Harness de áudio Opus. |

Os harnesses não são variantes de release nem substituem testes no produto. Não distribua
instrumentos de diagnóstico como app de usuário. As receitas e seus limites estão em
[compilação](../../docs/compilar.md) e [validação](../../docs/limites.md).

Projetos são gerados de `project.yml` com XcodeGen. A
[configuração de exemplo](../../Signing.local.xcconfig.example) não contém equipe pessoal;
configure suas próprias identidades/perfis para executar, sem commitar dados pessoais.
Compartilhar tela exige o controle ReplayKit e a interação prevista pelo sistema.
Simulador não comprova sensores, permissões, transmissão ou ciclo de vida em aparelho.
