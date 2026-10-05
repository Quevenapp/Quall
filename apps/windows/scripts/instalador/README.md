# Instalador do Quall Studio para Windows

O MSI contém o app e a fonte de mídia da câmera virtual Windows. O alvo desta versão é Windows 11 x64, build 22000 ou posterior. A câmera virtual usa APIs do Windows; ela não depende do driver de monitor SudoVDA.

A primeira versão permite espelhar uma tela existente. Não oferece monitor/tela estendida, recorte ou parede de vídeo. Este snapshot não contém payloads de driver nem certificados. A feature `tela-estendida-futura` é recusada explicitamente pelo build; `--all-features` não é um alvo suportado.

## Construir

Use um ambiente Windows x64 com Rust/MSVC, ferramentas C/C++, SDK do Windows, .NET SDK e WiX 5.0.2 com as extensões Util e Firewall da mesma versão. Cada workspace Cargo deve usar seu próprio `Cargo.lock`.

```powershell
powershell -NoProfile -File apps\windows\scripts\instalador\construir-msi.ps1 -Loja -Versao 0.1.0
```

O script compila `quall-app` em `apps/windows` com `net,loja`, usando `target\release-sem-monitor`, e compila `quall-camera-fonte` no workspace `integrations/camera-windows`. Ambos os builds usam lockfile e dois jobs. `-Loja` seleciona os diretórios de estágio/saída reservados à preparação do pacote para revisão. A opção não envia o pacote à Microsoft Store.

`-SoEmpacotar` reutiliza artefatos já construídos. As verificações permanecem: arquitetura x64, subsistema PE GUI do app, marcador `quall-distribuicao: release-sem-monitor-v2`, ausência dos nomes de payloads e de entradas de instalação do driver. Essas verificações detectam misturas conhecidas e não substituem a revisão do pacote concreto. Uma pasta de saída com `quall-driver.exe` é recusada. O empacotamento não lê os arquivos retirados do SudoVDA.

O MSI leva `LICENSE`, `LICENSE-SCOPE.md`, `NOTICE.txt` e `THIRD_PARTY_NOTICES.txt`. O código próprio do app segue MPL-2.0 nos limites descritos na raiz; terceiros conservam seus termos.

## Verificação e manutenção

| Arquivo | Função |
| --- | --- |
| `Quall.wxs` | Receita WiX do pacote |
| `construir-msi.ps1` | Builds e empacotamento, sem assinatura ou instalação |
| `camera-desinstalar.ps1` | Limpeza de nós da câmera virtual com verificação de titularidade |
| `estado-instalacao.ps1` | Inventário local, somente leitura |
| `prova-gemea.ps1` | Gera um MSI de teste com identidade separada; imprime comandos e não instala |

O portão local `tools/portao.ps1` cobre código, testes, scripts e pacote. Use `-Lista` ou `-So app,camera` para selecionar as etapas; o OBS exige `-ComObs`. Automação remota e configuração da bancada privada não integram este snapshot.

A limpeza da câmera virtual procura classes de interface e verifica o resultado no registro. Não deve remover dispositivos atribuídos a outro fornecedor nem dispositivos de dono desconhecido por decisão automática. Logs e inventários podem conter nomes e identificadores da máquina; revise-os antes de compartilhar.

## Estado da distribuição

Este snapshot foi preparado em macOS. Não constitui prova de build nativo, instalação, desinstalação, funcionamento ou captura visual no Windows. O MSI final ainda exige testes em Windows x64, assinatura autorizada e revisão das exigências da Microsoft Store. Nenhum driver de monitor é requisito ou download oferecido nesta versão.

`integrations/camera-windows/scripts/empacotar-msix.ps1` preserva um protótipo separado de empacotamento do componente de câmera. Esse protótipo usa a sonda como executável; não é a receita de distribuição do app Quall Studio.
