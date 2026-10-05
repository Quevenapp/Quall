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

O snapshot não certifica instalação, consumo ou compatibilidade universal. Windows nativo e
instalador finais estão pendentes; confira também avisos e conteúdo dos pacotes.
Veja [app Windows](../../apps/windows/README.md) e [limites](../../docs/limites.md).
