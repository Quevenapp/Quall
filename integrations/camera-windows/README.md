# Câmera virtual Windows

Integração Windows 11 x64 baseada em Media Foundation. O workspace contém a fonte
`quall-camera-fonte` e a sonda `quall-camera-sonda`. Expõe vídeo a consumidores compatíveis;
não é o driver de monitor sudoVda e não cria telas estendidas.

Em Windows, com Rust MSVC e Windows SDK, a partir da raiz:

```powershell
cargo build --manifest-path integrations/camera-windows/Cargo.toml --locked --release
```

Preserve o perfil deste workspace: a DLL da fonte desativa LTO. Build não registra DLL,
cria câmera ou instala pacote. Instalação/remoção, registro, assinatura e execução no consumidor
precisam ser revisados e autorizados no ambiente escolhido. Não remova dispositivos por categoria
genérica nem altere componentes de terceiros para testar esta integração.

## Instalador avulso `quall-camera.exe`

Para quem não vai compilar, a fonte é instalada pelo `quall-camera.exe`
(`apps/windows/src/bin/quall_camera.rs`): um executável só, que pede o UAC ao abrir, leva a
`quall_camera_fonte.dll` dentro dele e oferece Instalar ou Remover. Instalar copia a DLL para
`%ProgramFiles%\Quall`, registra a classe `{5C75FE52-9204-45F6-B143-58B1AC8048E5}` em
`HKLM\SOFTWARE\Classes\CLSID` e cria o diário em `%ProgramData%\Quall`. Remover apaga o registro e
o arquivo; se o Frame Server ainda estiver com a DLL carregada, ela é renomeada e sai no próximo
reinício. Nenhuma câmera é criada pelo instalador: quem cria é o app do Quall, por sessão
(`MFVirtualCameraLifetime_Session`), enquanto recebe vídeo de um aparelho.

Compilar, conferir o artefato e gravar o recibo (SHA-256, commit e os avisos de licença ao lado):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File apps/windows/scripts/construir-quall-camera.ps1 -Saida C:\saida\quall-camera
```

O exe não é assinado: o Windows mostra o aviso do SmartScreen ao abrir o arquivo baixado.

O snapshot não certifica instalação, consumo ou compatibilidade universal. Windows nativo e
instalador finais estão pendentes; confira também avisos e conteúdo dos pacotes.
Veja [app Windows](../../apps/windows/README.md) e [limites](../../docs/limites.md).
