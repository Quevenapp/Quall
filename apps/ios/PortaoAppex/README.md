# Harness de extensão ReplayKit

Projeto de diagnóstico com app `PortaoAppex`, extensão `Difusao` e alvo de testes de interface.
Exercita contratos de transmissão e ciclo de vida; não é uma release do produto.
Piso iOS 15, projetos gerados com XcodeGen.

Prepare primeiro a biblioteca estática iOS conforme a [receita comum](../../../docs/compilar.md).
O projeto usa `target/aarch64-apple-ios/release/libquall.a` e o header do mesmo checkout.
Nesta pasta:

```sh
xcodegen generate
xcodebuild -project PortaoAppex.xcodeproj -scheme PortaoAppex -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath DD \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO build
```

App/extensão precisam de capacidades e assinatura próprias para execução. Iniciar ReplayKit
e autorizar transmissão são ações do sistema, não provas produzidas por um build unsigned.
Use mídia sintética em testes autorizados e revise qualquer automação antes de executá-la.
Nenhum resultado privado de aparelho acompanha este snapshot. Veja [limites](../../../docs/limites.md).
