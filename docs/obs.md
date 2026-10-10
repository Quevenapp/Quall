# Quall Studio para OBS — 1.0.0

Receba uma tela ou câmera do Quall Studio como fonte nativa do OBS. O plugin é
separado do aplicativo Quall e precisa de um emissor compatível com protocolo 3.

## Downloads

| Pacote | Requisitos |
| --- | --- |
| [Windows x64](https://github.com/Quevenapp/Quall/releases/download/obs-v1.0.0/quall-studio-obs-1.0.0-windows-x64.zip) | Windows 11 x64, build 22000+, e OBS Studio 64 bits; carga verificada com libobs 32.2.1. |
| [macOS Apple Silicon](https://github.com/Quevenapp/Quall/releases/download/obs-v1.0.0/quall-studio-obs-1.0.0-macos-arm64.zip) | macOS 13+ e OBS Studio ARM64; interface e vídeo verificados com OBS 32.2.2. |
| [Fonte correspondente completa](https://github.com/Quevenapp/Quall/releases/download/obs-v1.0.0/quall-studio-obs-1.0.0-source-f5e2d64f.tar.gz) | Snapshot público `f5e2d64f`, com núcleo, plugin, dependências, recursos e receitas de compilação. |
| [SHA256 dos pacotes](https://github.com/Quevenapp/Quall/releases/download/obs-v1.0.0/SHA256SUMS.txt) | Verificação de integridade dos downloads. |

[Notas da versão](https://github.com/Quevenapp/Quall/releases/tag/obs-v1.0.0) ·
[Site oficial](https://queven.com.br/quall/obs/)

A fonte exata desta versão é o commit
[`f5e2d64f1cf8f5c51352ebd55b93ea87806cbdd1`](https://github.com/Quevenapp/Quall/tree/f5e2d64f1cf8f5c51352ebd55b93ea87806cbdd1).
Use esse snapshot para compilar a versão publicada; outras branches podem representar versões diferentes.
Não há pacote Intel ou Linux nesta versão.

## Instalar no Windows

1. Feche o OBS Studio e extraia o ZIP.
2. Copie a pasta **quall-obs** para `%ProgramData%\obs-studio\plugins\`
   (normalmente `C:\ProgramData\obs-studio\plugins\`). Crie `plugins` se necessário.
   O Windows pode solicitar permissão para copiar.
3. Confirme que existem `quall-obs\bin\64bit\quall-obs.dll` e `quall-obs\data\`
   dentro da pasta de plugins. Preserve as pastas `bin` e `data` juntas.
4. Abra o OBS. Em **Fontes → +**, escolha **Quall Studio (espelhamento da LAN)**.

A DLL não tem assinatura digital de distribuição. O plugin usa as bibliotecas do próprio
OBS, incluindo `w32-pthreads.dll`; não substitua arquivos da instalação do OBS.

## Instalar no macOS

1. Feche o OBS Studio e extraia o ZIP.
2. No Finder, abra **Ir → Ir para a pasta** e informe
   `~/Library/Application Support/obs-studio/plugins/`. Crie `plugins` se necessário.
3. Copie o pacote inteiro **quall-obs.plugin** para essa pasta.
4. Abra o OBS. Em **Fontes → +**, escolha **Quall Studio (espelhamento da LAN)**.

Use a versão ARM64 do OBS. O pacote tem assinatura **Developer ID de Veneri & Quellis Ltda.**,
notarização Apple aceita e ticket anexado. A assinatura e o ticket foram verificados
novamente depois de extrair o ZIP de distribuição.

## Conectar

1. Abra o Quall no aparelho emissor, escolha uma tela ou câmera e inicie a transmissão.
2. Nas propriedades da fonte no OBS, escolha o aparelho ou informe seu endereço.
3. No primeiro pareamento, digite o PIN exibido pelo Quall e clique em **Conectar**.
4. Use os controles do próprio OBS para gravar a composição ou transmitir.

Os aparelhos precisam alcançar um ao outro na rede. Se o aparelho não aparecer na
lista, use o endereço mostrado pelo Quall. Verifique que o emissor usa protocolo 3.

Para desinstalar, feche o OBS e remova somente a pasta `quall-obs` (Windows) ou o
pacote `quall-obs.plugin` (macOS) que foi copiado durante a instalação.

## Validação e limites desta versão

No macOS, o binário original foi exercitado na interface do OBS 32.2.2:
pareamento novo por PIN, vídeo 1920×1080 e retomada do par em uma segunda sessão
com atualização manual do endereço. Foram publicados 1.536 e 3.972 quadros, sem
descarte na fila do plugin. Emissor e receptor estavam no mesmo Mac. Isso não
valida recuperação automática, áudio ou todos os aparelhos em rede. A assinatura de
distribuição foi aplicada depois desse teste, preservando o código executável;
a execução no OBS não foi repetida após assinar.

A carga técnica passou 13 verificações no Windows/libobs 32.2.1 e 12 no
macOS/libobs 32.2.2, cobrindo carga, traduções, registro e encerramento.
Interface e mídia no Windows, áudio, recuperação automática e runtime Intel
não têm validação registrada nesta release.

Os ZIPs incluem `README.txt`, `PROVENIENCIA.json`, traduções PT/EN e textos legais.
O código executável foi preservado a partir dos artefatos cuja correspondência de
70 arquivos do plugin e 2.965 insumos nativos foi conferida. O arquivo de fonte
contém os 4.692 arquivos do commit público correspondente.

## Licenças e suporte

Plugin e combinação: **GPL-3.0-or-later**. O núcleo tem **MPL-2.0** como licença
padrão e a via secundária aplicável à combinação OBS. Os textos integrais, escopo
e avisos de terceiros acompanham os pacotes e a fonte correspondente.

Distribuição: **Veneri & Quellis Ltda.** · [suporte@queven.com.br](mailto:suporte@queven.com.br)
