# Instaladores do plugin do OBS

Dois roteiros, um por sistema. Nenhum dos dois instala: eles montam o pacote, e quem testa instala.

| | Windows | macOS |
|---|---|---|
| roteiro | `construir-msi.ps1` (WiX v5 + Util, o mesmo do app) | `construir-pkg.sh` (`pkgbuild` + `productbuild`) |
| pacote | `saida\QuallOBS-<versão>-x64.msi` | `QuallOBS-<versão>-macos-arm64.pkg` em `/Volumes/Dev/code/quall-scratch/obs-instalador/macos/` |
| destino | `C:\ProgramData\obs-studio\plugins\quall-obs\` (todos os usuários, pede UAC) | `~/Library/Application Support/obs-studio/plugins/quall-obs.plugin` (só o usuário) |
| assinatura | nenhuma (falta certificado de código) | plugin: Developer ID Application, hardened runtime; pacote: Developer ID Installer; notarizado e grampeado com o perfil `quall-notarizacao` |
| OBS aberto | Anular/Repetir/Ignorar; com `/qn`, recusa | recusa ao abrir o instalador |
| OBS ausente | recusa (`QUALL_SEM_CONFERIR_OBS=1` pula, para OBS portátil/Steam) | avisa e deixa continuar (o OBS pode estar fora de /Applications) |
| OBS velho | recusa abaixo do major.minor dos cabeçalhos | recusa abaixo do major.minor dos cabeçalhos |
| atualização | MajorUpgrade: a versão maior tira a menor, a menor recusa | o bundle é substituído (`BundleOverwriteAction upgrade`, sem relocação) |
| desinstalar | "Aplicativos instalados" > Quall Studio OBS plugin | fechar o OBS e mover o `quall-obs.plugin` para o Lixo |
| textos | inglês e português na mesma mensagem | pelo idioma do Mac (`macos/en.lproj`, `macos/pt.lproj`) |

## Windows (no Dell)

    powershell -NoProfile -ExecutionPolicy Bypass -File plugins\obs\instalador\construir-msi.ps1 -Plugin <windows-x64.zip publicado>
    powershell -NoProfile -ExecutionPolicy Bypass -File plugins\obs\instalador\construir-msi.ps1     # compila esta árvore

`-Plugin` aceita o ZIP publicado ou uma pasta `quall-obs` (com `bin\64bit` e `data`). Sem ele, o
roteiro chama `..\construir.ps1 -SemInstalar`. `-Versao` sai do `CMakeLists.txt`; `-ObsMinimo`, do
`obs-config.h` em `..\.libobs` (passe `-ObsMinimo 32.2` se a pasta não existir). A lista de arquivos
do `windows\QuallOBS.wxs` é fechada, e o roteiro recusa um plugin com arquivo a mais ou a menos.

## macOS

    plugins/obs/instalador/construir-pkg.sh --plugin <quall-obs.plugin> --obs-minimo 32.2.0
    plugins/obs/instalador/construir-pkg.sh          # compila esta árvore (../construir.sh --sem-instalar)

Um plugin que já vem com Developer ID do time, runtime e carimbo (o publicado) é mantido como veio;
`--reassinar` força. Há dois "Developer ID Application" com o mesmo nome nas Chaves, e o `codesign`
recusa nome ambíguo: o padrão é o SHA-1 `05A31ECC…` (vale até 2031; `QUALL_ID_APLICACAO` troca).
Sem o perfil do `notarytool`, o roteiro para depois de assinar e diz os dois comandos que faltam;
`--sem-notarizar` pula de propósito.

O molde é o do obs-plugintemplate (`create-package.cmake.in` e `distribution.in`): domínio do
usuário só, sem personalizar, sem script. A mais: `BundleIsRelocatable` desligado (senão o Installer
atualiza uma cópia do plugin achada em `build/` ou no scratch, e não a do OBS) e o `installCheck()`
do OBS aberto e da versão.

## Armadilhas

- **Protocolo.** Desde 13/10 o main também é protocolo 3, com o código de 4 dígitos, o QR e a
  sessão salva. O plugin 1.0.0 publicado é v3 só com PIN. A 1.0.29 sai da árvore do main, alinhada
  ao Windows 1.0.29.0.
- **`._*` no payload do .pkg.** São o `com.apple.provenance` que o macOS 26+ pendura em arquivo
  escrito por processo rastreado e que nem `xattr -c` tira. O Installer os devolve como atributo.
- **`MinVersion` do MSI** recebe uma versão abaixo do mínimo (32.1.65535.65535 para 32.2), para não
  depender de a comparação com versão igual ser estrita.
