# Portão de toolchain iOS

Projeto mínimo para diagnosticar build, assinatura e execução iOS. Não é o Quall Studio
de produto e não constitui prova de mídia, permissões ou compatibilidade de toda a aplicação.
Piso declarado: iOS 15; projeto gerado de `project.yml`.

Nesta pasta, para compilar sem assinar:

```sh
xcodegen generate
xcodebuild -project PortaoQuall.xcodeproj -scheme PortaoQuall -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath DD \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO build
```

Para instalar/depurar, configure sua assinatura e escolha um aparelho autorizado no Xcode.
Não há identificador de aparelho ou equipe pessoal fornecido por esta documentação.
Este snapshot não declara que o harness foi compilado ou executado.
Veja [produto](../Quall/README.md) e [limites](../../../docs/limites.md).
